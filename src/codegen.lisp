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

(defun get-or-create-di-type (crisp-type di-builder di-type-cache)
  "Gets a DIBasicType from a cache or creates it if it doesn't exist."
  (if crisp-type
      ;; It's a known, simple type.
      (or (gethash (crisp-type-name crisp-type) di-type-cache)
          (let* ((name-str (string-downcase (crisp-type-name crisp-type)))
                 (encoding (ecase (crisp-type-category crisp-type)
                             (:signed-int 5) ; DW_ATE_signed
                             (:unsigned-int 7) ; DW_ATE_unsigned
                             (:float 4))) ; DW_ATE_float
                 (di-type (llvm-di-builder-create-basic-type
                           di-builder name-str (length name-str)
                           (crisp-type-size crisp-type) encoding 0)))
            (setf (gethash (crisp-type-name crisp-type) di-type-cache) di-type)
            di-type))
      ;; It's an unknown or parameterized type. Create a placeholder.
      (or (gethash :unspecified di-type-cache)
          (let ((di-type (llvm-di-builder-create-basic-type di-builder "unspecified" (length "unspecified") 0 0 0)))
            (setf (gethash :unspecified di-type-cache) di-type)
            di-type))))

(defun get-llvm-return-type (module return-type-names)
  "Determines the LLVM return type from a list of Crisp type names.
  Handles single values, void, and multiple values (by creating a struct)."
  (log:debug "get-llvm-return-type: ~s" return-type-names)
  (cond
   ;; Case 1: Multiple return values. Create a struct.
   ((> (length return-type-names) 1)
     (let* ((context (llvm-get-module-context module))
            (count (length return-type-names))
            (type-array (cffi:foreign-alloc 'llvm-type-ref :count count))
            (packed nil))
       (loop for i from 0 for type-name in return-type-names
             do (setf (cffi:mem-aref type-array 'llvm-type-ref i)
                  (crisp-type-to-llvm-type type-name module)))
       (prog1 (llvm-struct-type-in-context context type-array count packed)
         (cffi:foreign-free type-array))))
   ;; Case 2: Single return value.
   ((= (length return-type-names) 1) (crisp-type-to-llvm-type (first return-type-names) module))
   ;; Case 3: Should not happen, but treat as void.
   (t (llvm-void-type))))

(defun mangle-type-spec (type-spec)
  "Creates a string representation of a type spec for name mangling."
  (cond
   ((symbolp type-spec) (string-downcase (symbol-name type-spec)))
   ((listp type-spec) (format nil "~{~a~^_~}" (mapcar #'mangle-type-spec type-spec)))
   (t (error "Cannot mangle unknown type specifier: ~a" type-spec))))

(defun crisp-type-to-llvm-type (type-spec module)
  "Resolves a Crisp type specifier (simple or parameterized) to an LLVM type."
  (cond
   ;; Simple type like 'int
   ((symbolp type-spec)
     (let ((crisp-type (gethash type-spec *crisp-types*)))
       (unless crisp-type
         (error "Internal codegen error: Unknown simple type ~a" type-spec))
       (funcall (crisp-type-llvm-type-fn crisp-type))))
   ;; Parameterized type like '(cell int)
   ((listp type-spec)
     (let ((base-type (first type-spec)))
       (cond
        ((eq base-type 'cell)
          ;; A cell is a struct { ptr, i64 }.
          ;; We use get-expanded-types to get the component types.
          (let* ((context (llvm-get-module-context module))
                 (element-types (get-expanded-types type-spec module))
                 (element-count (length element-types))
                 (type-array (cffi:foreign-alloc 'llvm-type-ref :count element-count)))
            (loop for i from 0 for type in element-types
                  do (setf (cffi:mem-aref type-array 'llvm-type-ref i) type))
            (llvm-struct-type-in-context context type-array element-count nil)))
        (t (error "Internal codegen error: Unknown parameterized type ~a" base-type)))))
   (t (error "Internal codegen error: Invalid type specifier ~a" type-spec))))

(defun get-expanded-types (type-spec module)
  "Returns a list of LLVM types for a given Crisp type spec.
   For 'cell', returns (ptr i64). For others, returns (type)."
  (if (listp type-spec)
      (let ((base-type (first type-spec)))
        (cond
         ((eq base-type 'cell)
           (list (llvm-int8-ptr-type (llvm-int8-type) 0)
                 (llvm-int64-type)))
         (t (error "Internal codegen error: Unknown parameterized type ~a" base-type))))
      (list (crisp-type-to-llvm-type type-spec module))))

(defun explode-value (builder agg-val type-spec)
  "Extracts components from an aggregate value if necessary.
   Returns a list of LLVM values."
  (if (listp type-spec)
      (let ((base-type (first type-spec)))
        (cond
         ((eq base-type 'cell)
           (list (llvm-build-extract-value builder agg-val 0 "cell_ptr")
                 (llvm-build-extract-value builder agg-val 1 "cell_size")))
         (t (error "Internal codegen error: Unknown parameterized type ~a" base-type))))
      (list agg-val)))

(defun implode-value (builder components type-spec module)
  "Combines components into an aggregate value if necessary.
   Returns a single LLVM value."
  (if (listp type-spec)
      (let ((base-type (first type-spec)))
        (cond
         ((eq base-type 'cell)
           (let* ((struct-type (crisp-type-to-llvm-type type-spec module))
                  (undef (llvm-get-undef struct-type))
                  (val-0 (llvm-build-insert-value builder undef (first components) 0 "cell_ptr")))
             (llvm-build-insert-value builder val-0 (second components) 1 "cell_size")))
         (t (error "Internal codegen error: Unknown parameterized type ~a" base-type))))
      (first components)))

(defun create-llvm-function-type (module return-types param-nodes)
  "Calculates the LLVM function type, handling parameter explosion."
  (let* ((return-type (get-llvm-return-type module return-types))
         (expanded-param-types (mapcan (lambda (p) (get-expanded-types (semantic-param-type p) module)) param-nodes))
         (param-count (length expanded-param-types))
         (param-types-array (cffi:foreign-alloc 'llvm-type-ref :count param-count)))
    (loop for i from 0
          for type in expanded-param-types
          do (setf (cffi:mem-aref param-types-array 'llvm-type-ref i) type))
    (llvm-function-type return-type param-types-array param-count nil)))

(defun generate-debug-info (di-builder di-compile-unit func fn-name fn-loc return-type param-nodes location-map)
  "Generates and attaches DWARF debug info for the function."
  (when di-builder
    (let* ((di-type-cache (make-hash-table))
           (di-file (when di-compile-unit (llvm-di-builder-create-file di-builder "test.crisp" (length "test.crisp") "/tmp/" (length "/tmp/")))) ; Placeholder
           (line-num (if location-map (gethash fn-loc location-map) 0))
           (di-return-type (get-or-create-di-type (gethash return-type *crisp-types*) di-builder di-type-cache))
           (di-param-types (cons di-return-type
                                 (loop for param in param-nodes
                                       collect (get-or-create-di-type
                                                (gethash (semantic-param-type param) *crisp-types*)
                                                di-builder di-type-cache))))
           (di-param-array (cffi:foreign-alloc :pointer :count (length di-param-types)))
           (_ (loop for i from 0 for type in di-param-types
                    do (setf (cffi:mem-aref di-param-array :pointer i) type)))
           (di-fn-type (llvm-di-builder-create-subroutine-type
                        di-builder di-file di-param-array (length di-param-types) 0))
           (subprogram (llvm-di-builder-create-function
                        di-builder di-compile-unit fn-name (length fn-name) fn-name (length fn-name)
                        di-file line-num di-fn-type nil t 0 0 nil)))
      (llvm-set-subprogram func subprogram)
      subprogram)))

(defun initialize-function-parameters (builder func param-nodes module var-env)
  "Allocates stack space and stores function parameters."
  (let ((llvm-param-index 0))
    (loop for param-node in param-nodes
          for param-name = (semantic-param-name param-node)
          for type-spec = (semantic-param-type param-node)
          do (let* ((expanded-types (get-expanded-types type-spec module))
                    (num-expanded (length expanded-types))
                    (components (loop for i from 0 below num-expanded
                                      collect (llvm-get-param func (+ llvm-param-index i))))
                    (imploded-val (implode-value builder components type-spec module))
                    (alloca (llvm-build-alloca builder (crisp-type-to-llvm-type type-spec module) (string-downcase param-name))))
               (llvm-build-store builder imploded-val alloca)
               (setf (gethash param-name var-env) alloca)
               (incf llvm-param-index num-expanded)))))

(defun generate-llvm-ir (semantic-function module builder di-builder di-compile-unit location-map)
  "Top-level function to generate LLVM IR for a given semantic function."
  (let* ((return-types (semantic-function-return-type semantic-function))
         (crisp-return-type (first return-types)) ; For single-value logic for now
         (base-name (semantic-function-name semantic-function))
         (param-type-specs (mapcar #'semantic-param-type (semantic-function-param-list semantic-function)))
         (mangled-name (format nil "~a~{_~a~}" base-name (mapcar #'mangle-type-spec param-type-specs)))
         (fn-name (substitute #\_ #\- (string-downcase mangled-name)))
         (fn-loc (semantic-function-source-location semantic-function))
         (param-nodes (semantic-function-param-list semantic-function)))
    
    (log:debug "Attempting to get LLVM type for: ~s" return-types)

    ;; --- 1. Define the Function Type ---
    (let ((fn-type (create-llvm-function-type module return-types param-nodes)))
      
      ;; --- 2. Create the Function ---
      (let ((func (llvm-add-function module fn-name fn-type)))
        (log:debug "finished llvm-add-function for ~a, creating debug info..." fn-name)
        
        (let ((di-subprogram (generate-debug-info di-builder di-compile-unit func fn-name fn-loc crisp-return-type param-nodes location-map)))
          
          ;; --- 3. Create the Code Block ---
          (let ((entry-block (llvm-append-basic-block func "entry"))
                (var-env (make-hash-table)))
            (log:debug "Positioning builder at entry block...")
            (llvm-position-builder-at-end builder entry-block)

            ;; --- 4. Allocate and Store Parameters ---
            (initialize-function-parameters builder func param-nodes module var-env)

            ;; --- 5. Generate the Body ---
            (let* ((body-node (first (semantic-function-body semantic-function)))
                   (is-void-return (equal return-types '(nil))))
              (multiple-value-bind (value di-location)
                  (generate-expression-ir builder module var-env di-builder di-subprogram location-map body-node)
                (let ((ret-inst (if is-void-return
                                    (llvm-build-ret-void builder)
                                    (llvm-build-ret builder value))))
                  (when di-location (llvm-instruction-set-debug-loc ret-inst di-location)))))))))))

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
       (let* ((struct-type (get-llvm-return-type module return-types))
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
  (let* ((type-spec (semantic-literal-value-type node))
         (value (semantic-literal-value node))
         (llvm-type (crisp-type-to-llvm-type type-spec module))
         (result (cond
                  ;; Handle our new cell type as a placeholder
                  ((listp type-spec)
                    (if (eq (first type-spec) 'cell)
                        (let* ((ptr-name '__storage_ptr)
                               (size-name '__storage_size)
                               (ptr-alloca (gethash ptr-name var-env))
                               (size-alloca (gethash size-name var-env)))
                          (unless (and ptr-alloca size-alloca)
                            (error "Missing implicit arguments for make-scratch-cell. Environment keys: ~s" (alexandria:hash-table-keys var-env)))

                          (let* ((ptr-val (llvm-build-load2 builder (llvm-int64-type) ptr-alloca "storage_ptr_raw"))
                                 (size-val (llvm-build-load2 builder (llvm-int64-type) size-alloca "storage_size"))
                                 ;; Cast i64 ptr to ptr (i8*)
                                 (ptr-casted (llvm-build-int-to-ptr builder ptr-val (llvm-int8-ptr-type (llvm-int8-type) 0) "storage_ptr"))
                                 ;; Create struct
                                 (struct-undef (llvm-get-undef llvm-type))
                                 (struct-0 (llvm-build-insert-value builder struct-undef ptr-casted 0 "cell_ptr"))
                                 (struct-1 (llvm-build-insert-value builder struct-0 size-val 1 "cell_size")))
                            struct-1))
                        (error "Codegen not implemented for literal of type ~a" type-spec)))
                  ;; Handle simple types
                  ((symbolp type-spec)
                    (let ((crisp-type (gethash type-spec *crisp-types*)))
                      (cond
                       ((member (crisp-type-category crisp-type) '(:signed-int :unsigned-int)) (llvm-const-int llvm-type value nil))
                       ((eq (crisp-type-category crisp-type) :float) (llvm-const-real llvm-type (coerce value 'double-float)))
                       (t (error "Codegen for literal of unknown type category: ~a" type-spec)))))
                  (t (error "Codegen not implemented for literal of type ~a" type-spec))))
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
         (alloca (gethash var-name var-env)))
    (let* ((type (crisp-type-to-llvm-type (semantic-var-read-type node) module))
           (loaded-name (string-downcase (format nil "~a" var-name)))
           (current-block (llvm-get-insert-block builder))
           (parent-fn (llvm-get-basic-block-parent current-block)))
      (values (llvm-build-load2 builder type alloca loaded-name)
        nil))))

;; -- addition --
(defun build-cast-if-needed (builder from-val from-type-name to-type-name)
  "Builds an LLVM cast instruction if the types differ."
  (if (eq from-type-name to-type-name)
      (progn
       (log:debug "build-cast-if-needed: No cast needed for ~s" from-type-name)
       from-val)
      (let* ((from-type (gethash from-type-name *crisp-types*))
             (to-type (gethash to-type-name *crisp-types*))
             (to-llvm-type (funcall (crisp-type-llvm-type-fn to-type))))
        (log:debug "build-cast-if-needed: Casting from ~s to ~s" from-type-name to-type-name)
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
             (lhs-type-name (get-single-value-type (semantic-add-left-arg node)))
             (rhs-type-name (get-single-value-type (semantic-add-right-arg node)))
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
    (let* ((from-type-name (get-single-value-type (semantic-value-cast-arg node)))
           (to-type-name (semantic-value-cast-type node))
           (cast-val (build-cast-if-needed builder arg-val from-type-name to-type-name)))
      ;; NOTE: This will need to be expanded to handle more `to-` conversions.
      ;; For now, it relies on the implicit promotion logic.
      (values cast-val nil))))

(defmethod generate-node-ir ((node semantic-bitcast) builder module var-env di-builder di-scope location-map)
  "Generates IR for a bitcast."
  (multiple-value-bind (arg-val arg-loc) (generate-node-ir (semantic-bitcast-arg node) builder module var-env di-builder di-scope location-map)
    (declare (ignore arg-loc))
    (let* ((to-type-spec (semantic-bitcast-type node))
           (to-llvm-type (crisp-type-to-llvm-type to-type-spec module))
           (cast-val (llvm-build-bit-cast builder arg-val to-llvm-type "bitcast")))
      (values cast-val nil))))

(defmethod generate-node-ir ((node semantic-fp-truncate-cast) builder module var-env di-builder di-scope location-map)
  "Generates IR for a float-to-integer truncation cast."
  (multiple-value-bind (arg-val arg-loc) (generate-node-ir (semantic-fp-truncate-cast-arg node) builder module var-env di-builder di-scope location-map)
    (declare (ignore arg-loc))
    (let* ((to-type-spec (semantic-fp-truncate-cast-type node))
           (to-llvm-type (crisp-type-to-llvm-type to-type-spec module))
           ;; NOTE: This assumes a signed conversion. We'll need to check the
           ;; crisp-type category to select fptosi vs fptoui in the future.
           (cast-val (llvm-build-fp-to-si builder arg-val to-llvm-type "fptosi")))
      (values cast-val nil))))

(defmethod generate-node-ir ((node semantic-call) builder module var-env di-builder di-scope location-map)
  "Generates IR for a function call."
  (declare (ignore di-builder di-scope location-map))
  (let* ((sig (semantic-call-signature node))
         (return-type-names (function-signature-return-types sig))
         (has-return-value (not (null (remove 'nil return-type-names))))
         (llvm-return-type (get-llvm-return-type module return-type-names))

         ;; 3. Build the LLVM function *type* (the signature)
         (param-nodes (function-signature-parameters sig))
         (expanded-param-types (mapcan (lambda (p) (get-expanded-types p module)) param-nodes))
         (param-count (length expanded-param-types))
         (param-types-array (cffi:foreign-alloc 'llvm-type-ref :count param-count)))
    
    ;; Fill param types array
    (loop for i from 0
          for type in expanded-param-types
          do (setf (cffi:mem-aref param-types-array 'llvm-type-ref i) type))

    (let* (;; The name of the function in LLVM IR is mangled with its types
           (mangled-name (format nil "~a~{_~a~}" (semantic-call-name node)
                           (mapcar #'mangle-type-spec (function-signature-parameters sig))))
           (callee-name (substitute #\_ #\- (string-downcase mangled-name)))
           (llvm-fn-type (llvm-function-type llvm-return-type param-types-array param-count nil))

           ;; 4. Get the LLVM function *value* (the callable function)
           (callee (or (llvm-get-named-function module callee-name)
                       ;; If not in this module, declare it
                       (llvm-add-function module callee-name llvm-fn-type)))

           (arg-nodes (semantic-call-args node))
           (args-array (cffi:foreign-alloc 'llvm-value-ref :count param-count)))
      
      (let ((idx 0))
        (loop for arg-node in arg-nodes
              for param-type in param-nodes
              do (multiple-value-bind (arg-val arg-loc) (generate-node-ir arg-node builder module var-env di-builder di-scope location-map)
                   (declare (ignore arg-loc))
                   ;; Use explode-value to handle both simple and complex types uniformly
                   (let ((exploded-vals (explode-value builder arg-val param-type)))
                     (dolist (val exploded-vals)
                       (setf (cffi:mem-aref args-array 'llvm-value-ref idx) val)
                       (incf idx))))))

      (let ((call-inst (llvm-build-call2 builder
                                         llvm-fn-type
                                         callee
                                         args-array
                                         param-count
                                         (if has-return-value "call_tmp" "")))
            (di-location (when (and di-builder di-scope location-map)
                               (let* ((loc (semantic-node-source-location node))
                                      (line (gethash loc location-map 0)))
                                 (llvm-di-builder-create-debug-location (llvm-get-module-context module)
                                                                        line 0 di-scope (cffi:null-pointer))))))
        (when di-location
              (llvm-instruction-set-debug-loc call-inst di-location))
        (values call-inst di-location)))))

(defmethod generate-node-ir ((node semantic-extract-value) builder module var-env di-builder di-scope location-map)
  "Generates IR for extracting a value from an aggregate."
  (multiple-value-bind (agg-val agg-loc)
      (generate-node-ir (semantic-extract-value-aggregate-node node) builder module var-env di-builder di-scope location-map)
    (declare (ignore agg-loc))
    (let ((index (semantic-extract-value-index node))
          (extract-val (llvm-build-extract-value builder agg-val index (format nil "extract_~a" index))))
      ;; TODO: Should this have a debug location? It corresponds to a variable binding,
      ;; but not a distinct expression in the source.
      (values extract-val nil))))

(defmethod generate-node-ir ((node semantic-let) builder module var-env di-builder di-scope location-map)
  "Generates IR for a let expression."
  ;; Create a new environment for the let block that inherits from the outer one.
  ;; We don't actually need to copy, we'll just add to it and the new bindings
  ;; will shadow outer ones if names conflict.
  (let ((let-env (alexandria:copy-hash-table var-env))
        (memoized-aggregates (make-hash-table :test 'eq)))
    ;; 1. Generate code for each binding.
    (dolist (binding (semantic-let-bindings node))
      (let* ((var-name (car binding))
             (val-node (cdr binding))
             (llvm-type-name (get-single-value-type val-node)))

        (let ((val-ir
               (if (typep val-node 'semantic-extract-value)
                   ;; If it's an extract, check if we've already generated the aggregate.
                   (let* ((agg-node (semantic-extract-value-aggregate-node val-node))
                          (agg-val (or (gethash agg-node memoized-aggregates)
                                       ;; If not, generate and memoize it.
                                       (let ((new-agg-val (generate-expression-ir builder module let-env di-builder di-scope location-map agg-node)))
                                         (setf (gethash agg-node memoized-aggregates) new-agg-val)
                                         new-agg-val)))
                          (index (semantic-extract-value-index val-node)))
                     (llvm-build-extract-value builder agg-val index (format nil "extract_~a" index)))
                   ;; Otherwise, it's a simple binding, generate as before.
                   (generate-expression-ir builder module let-env di-builder di-scope location-map val-node))))

          ;; Now that we have the correct value (val-ir), allocate and store it.
          (let ((alloca (llvm-build-alloca builder (crisp-type-to-llvm-type llvm-type-name module) (string-downcase var-name))))
            (llvm-build-store builder val-ir alloca)
            (setf (gethash var-name let-env) alloca)))))

    ;; 2. Generate code for the body, using the extended environment.
    ;; The result of the let is the result of the last expression in the body.
    (loop for body-node in (semantic-let-body node)
          finally (return (generate-expression-ir builder module let-env di-builder di-scope location-map body-node)))))