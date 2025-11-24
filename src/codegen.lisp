;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.


;; src/codegen.lisp
(in-package :crisp.compiler)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; CFFI Type Definitions for LLVM
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(cffi:defctype llvm-type-ref :pointer)
(cffi:defctype llvm-value-ref :pointer)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Code Generation (Pass 3)
;;
;; This file takes the semantic "blueprint" from the analyzer and generates
;; LLVM IR from it.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun get-or-create-di-type (crisp-type di-builder di-type-cache)
  "Gets a DIBasicType from a cache or creates it if it doesn't exist."
  (or (gethash (crisp-type-name crisp-type) di-type-cache)
      (let* ((name-str (string-downcase (crisp-type-name crisp-type)))
             (encoding (ecase (crisp-type-category crisp-type)
                         (:signed-int 5)   ; DW_ATE_signed
                         (:unsigned-int 7) ; DW_ATE_unsigned
                         (:float 4)))      ; DW_ATE_float
             (di-type (llvm-di-builder-create-basic-type
                       di-builder
                       name-str (length name-str)
                       (crisp-type-size crisp-type)
                       encoding
                       0)))
        (setf (gethash (crisp-type-name crisp-type) di-type-cache) di-type)
        di-type)))

(defun get-llvm-return-type (context return-type-names)
  "Determines the LLVM return type from a list of Crisp type names.
  Handles single values, void, and multiple values (by creating a struct)."
  (cond
    ;; Case 1: Multiple return values. Create a struct.
    ((> (length return-type-names) 1)
     (let* ((count (length return-type-names))
            (type-array (cffi:foreign-alloc 'llvm-type-ref :count count))
            (packed nil))
       (loop for i from 0 for type-name in return-type-names
             do (setf (cffi:mem-aref type-array 'llvm-type-ref i)
                      (llvm-type-for-name type-name)))
       (prog1 (llvm-struct-type-in-context context type-array count packed)
         (cffi:foreign-free type-array))))
    ;; Case 2: Single return value.
    ((= (length return-type-names) 1)
     (llvm-type-for-name (first return-type-names)))
    ;; Case 3: Should not happen, but treat as void.
    (t (llvm-void-type))))

(defun generate-llvm-ir (semantic-function module builder di-builder di-compile-unit location-map)
  "Top-level function to generate LLVM IR for a given semantic function."
  (let* ((return-types (semantic-function-return-type semantic-function))
         (crisp-return-type (first return-types)) ; For single-value logic for now
         (base-name (semantic-function-name semantic-function))
         (param-types (mapcar #'semantic-param-type (semantic-function-param-list semantic-function)))
         (mangled-name (format nil "~a~{_~a~}" base-name param-types))
         (fn-name (substitute #\_ #\- (string-downcase mangled-name)))
         (fn-loc (semantic-function-source-location semantic-function))
         )
    (log:debug "Attempting to get LLVM type for: ~s" (semantic-function-return-type semantic-function))
    ;; --- 1. Define the Function Type ---
    (let* ((return-type (get-llvm-return-type (llvm-get-module-context module) return-types))
           (param-nodes (semantic-function-param-list semantic-function))
           (param-count (length param-nodes))
           ;; Create a C-style array of LLVM types for the parameters
           (param-types-array (cffi:foreign-alloc 'llvm-type-ref :count param-count)))
      (loop for i from 0
            for param-node in param-nodes
            do (setf (cffi:mem-aref param-types-array 'llvm-type-ref i)
                     (llvm-type-for-name (semantic-param-type param-node))))

      (let ((fn-type (llvm-function-type return-type param-types-array param-count nil)))

        ;; --- 2. Create the Function ---
        (let ((func (llvm-add-function module fn-name fn-type)))
          (let ((di-subprogram
                  (when di-builder
                    (let* ((di-type-cache (make-hash-table))
                           (di-file (when di-compile-unit (llvm-di-builder-create-file di-builder "test.crisp" (length "test.crisp") "/tmp/" (length "/tmp/")))) ; Placeholder
                           (line-num (if location-map (gethash fn-loc location-map) 0))
                           ;; Create the DISubroutineType
                           (di-return-type (get-or-create-di-type (gethash crisp-return-type *crisp-types*) di-builder di-type-cache))
                           (di-param-types (cons di-return-type ; Return type is the first element
                                                 (loop for param in param-nodes
                                                       collect (get-or-create-di-type
                                                                (gethash (semantic-param-type param) *crisp-types*)
                                                                di-builder di-type-cache))))
                           (di-param-array (cffi:foreign-alloc :pointer :count (length di-param-types)))
                           (_ (loop for i from 0 for type in di-param-types
                                    do (setf (cffi:mem-aref di-param-array :pointer i) type)))
                           (di-fn-type (llvm-di-builder-create-subroutine-type
                                        di-builder
                                        di-file
                                        di-param-array
                                        (length di-param-types)
                                        0))
                           ;; Create the DISubprogram (the function itself)
                           (subprogram (llvm-di-builder-create-function
                                          di-builder
                                          di-compile-unit ; Scope
                                          fn-name (length fn-name) ; Name
                                          fn-name (length fn-name) ; LinkageName
                                          di-file
                                          line-num
                                          di-fn-type
                                          nil ; IsLocalToUnit
                                          t   ; IsDefinition
                                          0   ; ScopeLine
                                          0   ; Flags (none)
                                          nil ; IsOptimized
                                          )))
                      (llvm-set-subprogram func subprogram)
                      subprogram)))) ; Return the created subprogram
            ;; --- 3. Create the Code Block ---
            (let ((entry-block (llvm-append-basic-block func "entry"))
                  (var-env (make-hash-table)))
              (llvm-position-builder-at-end builder entry-block)

              ;; --- 4. Allocate and Store Parameters ---
              (loop for i from 0
                    for param-node in param-nodes
                    for llvm-param = (llvm-get-param func i) do
                    (let* ((param-name (semantic-param-name param-node)) (alloca (llvm-build-alloca builder (llvm-type-for-name (semantic-param-type param-node)) (string-downcase param-name))))
                         (llvm-build-store builder llvm-param alloca)
                         (setf (gethash param-name var-env) alloca)))

              ;; --- 5. Generate the Body ---
              (let* ((body-node (first (semantic-function-body semantic-function)))
                     (is-void-return (equal return-types '(nil))))
                (multiple-value-bind (value di-location)
                    (generate-expression-ir builder module var-env di-builder di-subprogram location-map body-node)
                  (let ((ret-inst (if is-void-return
                                      (llvm-build-ret-void builder)
                                      (llvm-build-ret builder value))))
                    (when di-location (llvm-instruction-set-debug-loc ret-inst di-location))))))))))))

(defgeneric generate-node-ir (node builder module var-env di-builder di-scope location-map)
  (:documentation "Generates LLVM IR for a single semantic node."))

(defun generate-expression-ir (builder module var-env di-builder di-scope location-map node)
  "Recursively generates IR for a single expression node."
  (generate-node-ir node builder module var-env di-builder di-scope location-map))

(defmethod generate-node-ir ((node semantic-return) builder module var-env di-builder di-scope location-map)
  "Generates IR for an implicit return. The value is just the value of the inner node."
  (generate-node-ir (semantic-return-value-node node) builder module var-env di-builder di-scope location-map))

(defmethod generate-node-ir ((node semantic-explicit-return) builder module var-env di-builder di-scope location-map)
  "Generates IR for an explicit (return ...) form."
  (let* ((return-types (semantic-explicit-return-type node))
         (value-nodes (semantic-explicit-return-value-nodes node)))
    (cond
      ;; Single return value, just generate the value.
      ((= (length return-types) 1)
       (generate-node-ir (first value-nodes) builder module var-env di-builder di-scope location-map))
      ;; Multiple return values, build a struct.
      ((> (length return-types) 1)
       (log:debug "MVR Codegen: Building struct for types: ~s" return-types)
       (let* ((context (llvm-get-module-context module))
              (struct-type (get-llvm-return-type context return-types))
              ;; Start with an undefined struct value. We will build it up.
              (agg-val (llvm-get-undef struct-type)))
         (log:debug "MVR Codegen: Struct type: ~s, initial undef value: ~s" struct-type agg-val)

         ;; Iteratively insert each value into the aggregate.
         ;; Each `insertvalue` returns a *new* aggregate value.
         (loop for i from 0
               for val-node in value-nodes
               do (multiple-value-bind (val-ir val-loc)
                      (generate-node-ir val-node builder module var-env di-builder di-scope location-map)
                    (declare (ignore val-loc))
                    (log:debug "MVR Codegen: Inserting value ~s into index ~a of aggregate ~s" val-ir i agg-val)
                    (setf agg-val (llvm-build-insert-value builder agg-val val-ir i (format nil "mvr_val_~a" i)))))
         (values agg-val nil)))
      ;; No return values (void return)
      (t (values nil nil)))))



;; -- literal value --
(defmethod generate-node-ir ((node semantic-literal) builder module var-env di-builder di-scope location-map)
  "Generates IR for a literal value."
  (declare (ignore var-env))
  (let ((result (llvm-const-int (llvm-type-for-name (semantic-literal-value-type node))
                                (semantic-literal-value node)
                                nil))
        (di-location (when (and di-builder di-scope location-map)
                       (let* ((loc (semantic-node-source-location node))
                              (line (gethash loc location-map 0)))
                         (llvm-di-builder-create-debug-location (llvm-get-module-context module)
                                                                line
                                                                0 ; column
                                                                di-scope
                                                                (cffi:null-pointer)))))) ; InlinedAt
    (values result di-location)))

;; -- reading a variable --
(defmethod generate-node-ir ((node semantic-var-read) builder module var-env di-builder di-scope location-map)
  "Generates IR for reading a variable."
  (declare (ignore module di-builder di-scope location-map))
  (let* ((var-name (semantic-var-read-name node))
         (alloca (gethash var-name var-env))
         (type (llvm-type-for-name (semantic-var-read-type node)))
         (loaded-name (string-downcase (format nil "~a" var-name)))
         (current-block (llvm-get-insert-block builder))
         (parent-fn (llvm-get-basic-block-parent current-block)))
    (values (llvm-build-load2 builder type alloca loaded-name)
            nil)))

;; -- addition --
(defun build-cast-if-needed (builder from-val from-type-name to-type-name)
  "Builds an LLVM cast instruction if the types differ."
  (if (eq from-type-name to-type-name)
      from-val
      (let* ((from-type (gethash from-type-name *crisp-types*))
             (to-type (gethash to-type-name *crisp-types*))
             (to-llvm-type (funcall (crisp-type-llvm-type-fn to-type))))
        (cond
          ;; Integer to Float
          ((and (eq (crisp-type-category from-type) :signed-int) (eq (crisp-type-category to-type) :float))
           (llvm-build-si-to-fp builder from-val to-llvm-type "si2fp_cast"))
          ((and (eq (crisp-type-category from-type) :unsigned-int) (eq (crisp-type-category to-type) :float))
           (llvm-build-ui-to-fp builder from-val to-llvm-type "ui2fp_cast"))
          ;; Integer Extension
          ((and (eq (crisp-type-category from-type) :signed-int) (eq (crisp-type-category to-type) :signed-int))
           (llvm-build-sext builder from-val to-llvm-type "sext_cast"))
          ((and (eq (crisp-type-category from-type) :unsigned-int) (eq (crisp-type-category to-type) :unsigned-int))
           (llvm-build-zext builder from-val to-llvm-type "zext_cast"))
          ;; Float Extension
          ((and (eq (crisp-type-category from-type) :float) (eq (crisp-type-category to-type) :float))
           (llvm-build-fp-ext builder from-val to-llvm-type "fpext_cast"))
          ;; Float to Integer
          ((and (eq (crisp-type-category from-type) :float) (eq (crisp-type-category to-type) :signed-int))
           (llvm-build-fp-to-si builder from-val to-llvm-type "fp2si_cast"))
          ((and (eq (crisp-type-category from-type) :float) (eq (crisp-type-category to-type) :unsigned-int))
           (llvm-build-fp-to-ui builder from-val to-llvm-type "fp2ui_cast"))
          ;; Truncation
          ((and (member (crisp-type-category from-type) '(:signed-int :unsigned-int))
                (member (crisp-type-category to-type) '(:signed-int :unsigned-int)))
           (llvm-build-trunc builder from-val to-llvm-type "trunc_cast"))
          (t (error "Unsupported value cast from ~a to ~a" from-type-name to-type-name))))))

(defmethod generate-node-ir ((node semantic-add) builder module var-env di-builder di-scope location-map)
  "Generates IR for an addition operation."
  (multiple-value-bind (lhs lhs-loc) (generate-node-ir (semantic-add-left-arg node) builder module var-env di-builder di-scope location-map)
    (declare (ignore lhs-loc))
    (multiple-value-bind (rhs rhs-loc) (generate-node-ir (semantic-add-right-arg node) builder module var-env di-builder di-scope location-map)
      (declare (ignore rhs-loc)) 
      (let* ((result-type-name (semantic-add-type node))
             (lhs-type-raw (semantic-node-type (semantic-add-left-arg node)))
             (rhs-type-raw (semantic-node-type (semantic-add-right-arg node)))
             (lhs-type-name (if (listp lhs-type-raw) (first lhs-type-raw) lhs-type-raw))
             (rhs-type-name (if (listp rhs-type-raw) (first rhs-type-raw) rhs-type-raw))
             (casted-lhs (build-cast-if-needed builder lhs lhs-type-name result-type-name))
             (casted-rhs (build-cast-if-needed builder rhs rhs-type-name result-type-name))
             (crisp-type (gethash result-type-name *crisp-types*))
             (add-inst (if (eq (crisp-type-category crisp-type) :float)
                           (llvm-build-fadd builder casted-lhs casted-rhs "fadd_tmp")
                           (llvm-build-add builder casted-lhs casted-rhs "add_tmp")))
            (di-location (when (and di-builder di-scope location-map)
                           (let* ((loc (semantic-node-source-location node))
                                  (line (gethash loc location-map 0)))
                             (llvm-di-builder-create-debug-location (llvm-get-module-context module)
                                                                    line
                                                                    0 ; column
                                                                    di-scope
                                                                    (cffi:null-pointer)))))) ; InlinedAt
                                                                    
        (log:debug "Codegen for ADD: lhs-type: ~s, rhs-type: ~s, result-type: ~s"
                   lhs-type-name rhs-type-name result-type-name)

        (when di-location (llvm-instruction-set-debug-loc add-inst di-location))
        (values add-inst di-location)))))

(defmethod generate-node-ir ((node semantic-value-cast) builder module var-env di-builder di-scope location-map)
  "Generates IR for a value-preserving cast."
  (multiple-value-bind (arg-val arg-loc) (generate-node-ir (semantic-value-cast-arg node) builder module var-env di-builder di-scope location-map)
    (declare (ignore arg-loc))
    (let* ((from-type-name (semantic-node-type (semantic-value-cast-arg node)))
           (to-type-name (semantic-value-cast-type node))
           (cast-val (build-cast-if-needed builder arg-val from-type-name to-type-name)))
      ;; NOTE: This will need to be expanded to handle more `to-` conversions.
      ;; For now, it relies on the implicit promotion logic.
      (values cast-val nil))))

(defmethod generate-node-ir ((node semantic-bitcast) builder module var-env di-builder di-scope location-map)
  "Generates IR for a bitcast."
  (multiple-value-bind (arg-val arg-loc) (generate-node-ir (semantic-bitcast-arg node) builder module var-env di-builder di-scope location-map)
    (declare (ignore arg-loc))
    (let* ((to-type-name (semantic-bitcast-type node))
           (to-llvm-type (llvm-type-for-name to-type-name))
           (cast-val (llvm-build-bit-cast builder arg-val to-llvm-type "bitcast")))
      (values cast-val nil))))

(defmethod generate-node-ir ((node semantic-fp-truncate-cast) builder module var-env di-builder di-scope location-map)
  "Generates IR for a float-to-integer truncation cast."
  (multiple-value-bind (arg-val arg-loc) (generate-node-ir (semantic-fp-truncate-cast-arg node) builder module var-env di-builder di-scope location-map)
    (declare (ignore arg-loc))
    (let* ((to-type-name (semantic-fp-truncate-cast-type node))
           (to-llvm-type (llvm-type-for-name to-type-name))
           ;; NOTE: This assumes a signed conversion. We'll need to check the
           ;; crisp-type category to select fptosi vs fptoui in the future.
           (cast-val (llvm-build-fp-to-si builder arg-val to-llvm-type "fptosi")))
      (values cast-val nil))))

;; -- function call --
(defmethod generate-node-ir ((node semantic-call) builder module var-env di-builder di-scope location-map)
  "Generates IR for a function call."
  (declare (ignore di-builder di-scope location-map))
  (let* ((sig (semantic-call-signature node))

          ;; 1. Get the Lisp return type symbol (e.g. 'I32 or NIL)
          (crisp-return-type (first (function-signature-return-types sig)))

          ;; 2. Get the LLVM return type (handles NIL -> void)
          (llvm-return-type (if crisp-return-type
                              (llvm-type-for-name crisp-return-type)
                              (llvm-void-type)))

          ;; 3. Build the LLVM function *type* (the signature)
          (param-count (length (function-signature-parameters sig)))
          (param-types-array (cffi:foreign-alloc 'llvm-type-ref :count param-count))
          (_ (loop for i from 0 for p-type in (function-signature-parameters sig)
                   do (setf (cffi:mem-aref param-types-array 'llvm-type-ref i)
                            (llvm-type-for-name p-type))))
          ;; The name of the function in LLVM IR is mangled with its types
          ;; to support overloading. e.g., add_two_int_int
          (mangled-name (format nil "~a~{_~a~}" (semantic-call-name node) (function-signature-parameters sig)))
          (callee-name (substitute #\_ #\- (string-downcase mangled-name)))
          (llvm-fn-type (llvm-function-type llvm-return-type param-types-array param-count nil))

          ;; 4. Get the LLVM function *value* (the callable function)
          (callee (or (llvm-get-named-function module callee-name)
                      ;; If not in this module, declare it
                      (llvm-add-function module callee-name llvm-fn-type)))
          
          (arg-nodes (semantic-call-args node))
          (num-args (length arg-nodes))
          (args-array (cffi:foreign-alloc 'llvm-value-ref :count num-args)))
    (loop for i from 0 for arg-node in arg-nodes
          do (multiple-value-bind (arg-val arg-loc) (generate-node-ir arg-node builder module var-env di-builder di-scope location-map)
               (declare (ignore arg-loc))
               (setf (cffi:mem-aref args-array 'llvm-value-ref i) arg-val)))
    (let ((call-inst (llvm-build-call2 builder
                                     llvm-fn-type
                                     callee
                                     args-array
                                     num-args
                                     (if crisp-return-type "call_tmp" "")))
          (di-location (when (and di-builder di-scope location-map)
                         (let* ((loc (semantic-node-source-location node))
                                (line (gethash loc location-map 0)))
                           (llvm-di-builder-create-debug-location (llvm-get-module-context module)
                                                                  line 0 di-scope (cffi:null-pointer))))))
      (when di-location
        (llvm-instruction-set-debug-loc call-inst di-location))
      (values call-inst di-location))))

(defmethod generate-node-ir ((node semantic-let) builder module var-env di-builder di-scope location-map)
  "Generates IR for a let expression."
  ;; Create a new environment for the let block that inherits from the outer one.
  ;; We don't actually need to copy, we'll just add to it and the new bindings
  ;; will shadow outer ones if names conflict.
  (let ((let-env (alexandria:copy-hash-table var-env)))
    ;; 1. Generate code for each binding.
    (dolist (binding (semantic-let-bindings node))
      (let* ((var-name (car binding))
             (val-node (cdr binding))
             (var-type (semantic-node-type val-node)))
        ;; If the value is a multi-return function call, its type is a list.
        ;; For a single `let` binding, we implicitly take the first value's type.
        ;; The analyzer already ensures the variable is typed correctly in the env,
        ;; but we need to handle the type for the alloca instruction here.
        (let ((llvm-type-name (if (listp var-type) (first var-type) var-type)))
        ;; Generate the value for the initializer expression.
        (multiple-value-bind (val-ir val-loc)
            (generate-expression-ir builder module let-env di-builder di-scope location-map val-node)
          (declare (ignore val-loc))
          ;; Allocate stack space for the new variable.
          (let ((alloca (llvm-build-alloca builder (llvm-type-for-name llvm-type-name) (string-downcase var-name))))
            ;; Store the initial value.
            (llvm-build-store builder val-ir alloca)
            ;; Add the variable's pointer to our environment.
            (setf (gethash var-name let-env) alloca))))))

    ;; 2. Generate code for the body, using the extended environment.
    ;; The result of the let is the result of the last expression in the body.
    (loop for body-node in (semantic-let-body node)
          finally (return (generate-expression-ir builder module let-env di-builder di-scope location-map body-node)))))

(defun llvm-type-for-name (type-name)
  "Maps a Crisp type symbol to an LLVM type."
  (let ((crisp-type (gethash type-name *crisp-types*)))
    (if crisp-type
        (funcall (crisp-type-llvm-type-fn crisp-type))
        (error "Unknown type name for LLVM: ~a" type-name))))