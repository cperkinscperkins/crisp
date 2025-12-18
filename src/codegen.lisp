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
   ;; Case 0: Void return (NIL or empty list)
   ((or (null return-type-names) (equal return-type-names '(nil)))
     (llvm-void-type))
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
  (log:debug "mangle-type-spec: ~s (type-of: ~a)" type-spec (type-of type-spec))
  (cond
   ((symbolp type-spec) (string-downcase (symbol-name type-spec)))
   ((listp type-spec) (format nil "~{~a~^_~}" (mapcar #'mangle-type-spec type-spec)))
   (t (error "Cannot mangle unknown type specifier: ~a" type-spec))))

(defun crisp-type-to-llvm-type (type-spec module)
  "Resolves a Crisp type specifier (simple or parameterized) to an LLVM type."
  (cond
   ;; Simple type like 'int
   ((symbolp type-spec)
     (log:debug "Resolving symbol type: ~a" type-spec)
     (when (null type-spec)
           (error "Cannot resolve type to LLVM: NIL"))
     (resolve-type-to-llvm type-spec))
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
        ((or (eq base-type :function-type) (eq base-type :function-literal))
          ;; Functions are passed as opaque pointers (void* / i8*)
          (llvm-int8-ptr-type (llvm-int8-type) 0))

        ;; Case: Templated Struct Instantiation, e.g. (POINT FLOAT)
        ;; We try to mangle it and look it up.
        (t
          (let ((mangled-name (intern (format nil "~a_~{~a~^_~}" base-type (rest type-spec)) (symbol-package base-type))))
            (if (gethash mangled-name *crisp-structs*)
                (resolve-type-to-llvm mangled-name)
                (error "Internal codegen error: Unknown parameterized type ~a (Mangled: ~a)" base-type mangled-name)))))))
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
         ((or (eq base-type :function-type) (eq base-type :function-literal))
           (list (crisp-type-to-llvm-type type-spec module)))
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
         ((or (eq base-type :function-type) (eq base-type :function-literal))
           (list agg-val))
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
         ((or (eq base-type :function-type) (eq base-type :function-literal))
           (first components))
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
        (let* ((di-type-cache (make-hash-table)) (di-file (when di-compile-unit (llvm-di-builder-create-file di-builder "test.crisp" (length "test.crisp") "/tmp/" (length "/tmp/")))) ; Placeholder
                                                 (line-num (if location-map (or (gethash fn-loc location-map) 0) 0))
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
          do
            (log:debug "Init-func-params: param-name='~s' (type: ~a) type-spec='~s'"
              param-name (type-of param-name) type-spec)
            (let* ((expanded-types (get-expanded-types type-spec module))
                   (num-expanded (length expanded-types))
                   (components (loop for i from 0 below num-expanded
                                     for p = (llvm-get-param func (+ llvm-param-index i))
                                     do (log:debug "llvm-get-param ~a -> ~a" (+ llvm-param-index i) p)
                                     collect p))
                   (imploded-val (implode-value builder components type-spec module))
                   (alloca (llvm-build-alloca builder (crisp-type-to-llvm-type type-spec module) (string-downcase param-name))))
              (log:info "imploded-val: ~a, alloca: ~a" imploded-val alloca)
              (unless imploded-val (error "imploded-val is NIL for type ~a" type-spec))
              (unless alloca (error "alloca is NIL for type ~a" type-spec))
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
      (log:info "llvm-add-function: ~a Module: ~a" fn-name module)
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
            (let* ((body-nodes (semantic-function-body semantic-function))
                   (is-void-return (or (null return-types)
                                       (equal return-types '(nil))))
                   (last-val nil)
                   (last-loc nil))
              (dolist (node body-nodes)
                (multiple-value-bind (val loc)
                    (generate-expression-ir builder module var-env di-builder di-subprogram location-map node)
                  (setf last-val val)
                  (setf last-loc loc)))

              (let ((ret-inst (if is-void-return
                                  (llvm-build-ret-void builder)
                                  (llvm-build-ret builder last-val))))
                (when last-loc (llvm-instruction-set-debug-loc ret-inst last-loc))))))))))

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
     ((and return-types (= (length return-types) 1) (not (null (first return-types))))
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
         (result (cond ;; Handle parameterized types
                      ((listp type-spec)
                        (let ((base-type (first type-spec)))
                          (cond
                           ((or (eq base-type :function-literal) (eq base-type :function-type))
                             ;; For zero-cost abstraction, we don't emit a real function pointer.
                             ;; The type system tracks the identity, but at runtime it's a ghost.
                             (llvm-get-undef llvm-type))
                           ((eq base-type 'cell)
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
                                 struct-1)))
                           (t (error "Codegen not implemented for literal of type ~a" type-spec)))))
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
  (declare (ignore di-builder di-scope location-map))
  (log:debug "Generating IR for var-read: ~s" (semantic-var-read-name node))
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

;; -- comparisons --
(defun generate-comparison-ir (builder module var-env di-builder di-scope location-map node op-node-int op-node-float)
  "Helper to generate IR for comparison operators (<, >, =, etc)."
  (let ((lhs-node (funcall (first (function-signature-parameters (semantic-node-type node))) node))
        ;; Oops, semantic-lt etc don't store signature effectively in common way, 
        ;; but they do store left-arg and right-arg. Let's assume standard accessors.
        (left-arg (slot-value node 'left-arg))
        (right-arg (slot-value node 'right-arg)))

    (multiple-value-bind (lhs lhs-loc) (generate-node-ir left-arg builder module var-env di-builder di-scope location-map)
      (declare (ignore lhs-loc))
      (multiple-value-bind (rhs rhs-loc) (generate-node-ir right-arg builder module var-env di-builder di-scope location-map)
        (declare (ignore rhs-loc))
        (let* ((lhs-type-name (get-single-value-type left-arg))
               (rhs-type-name (get-single-value-type right-arg))
               ;; Determine common type (promote to float if mixed, else largest int)
               ;; For simplicity, we enforce strict typing or assume implicit cast logic is handled by semantic analysis?
               ;; Semantic analysis usually inserts casts. Let's assume types match or casts are explicit.
               ;; BUT wait, semantic-add handles implicit casts. Let's reuse build-cast-if-needed logic if possible.
               ;; Wait, semantic-lt structure: type, left-arg, right-arg.
               ;; But type is 'int (result). We need args types.
               (lhs-crisp-type (gethash lhs-type-name *crisp-types*))
               (cmp-inst
                (cond
                 ((member (crisp-type-category lhs-crisp-type) '(:signed-int :unsigned-int))
                   (llvm-build-icmp builder op-node-int lhs rhs "icmp_tmp"))
                 ((eq (crisp-type-category lhs-crisp-type) :float)
                   (llvm-build-fcmp builder op-node-float lhs rhs "fcmp_tmp"))
                 (t (error "Unsupported comparison type: ~a" lhs-type-name)))))

          ;; Convert i1 result to i32 (0 or 1) because Crisp uses int for booleans
          (let ((result (llvm-build-zext builder cmp-inst (llvm-int32-type) "bool_ext")))
            (values result nil)))))))

;; Redefining to be more generic and careful about accessors
(defmacro def-comparison-codegen (type-name int-pred float-pred accessor-prefix)
  (let ((left-accessor (intern (format nil "~a-LEFT-ARG" accessor-prefix)))
        (right-accessor (intern (format nil "~a-RIGHT-ARG" accessor-prefix))))
    `(defmethod generate-node-ir ((node ,type-name) builder module var-env di-builder di-scope location-map)
       (multiple-value-bind (lhs lhs-loc) (generate-node-ir (,left-accessor node) builder module var-env di-builder di-scope location-map)
         (declare (ignore lhs-loc))
         (multiple-value-bind (rhs rhs-loc) (generate-node-ir (,right-accessor node) builder module var-env di-builder di-scope location-map)
           (declare (ignore rhs-loc))
           (let* ((lhs-type-name (get-single-value-type (,left-accessor node)))
                  (lhs-type (gethash lhs-type-name *crisp-types*))
                  ;; Determine predicate based on type. Note: Signed vs Unsigned integers might need different predicates!
                  ;; This is a simplification. Ideally semantic analysis distinguishes signed/unsigned ops
                  ;; or we check the type category here.
                  (is-unsigned (eq (crisp-type-category lhs-type) :unsigned-int))
                  (int-pred-val ,int-pred)
                  ;; Adjust for unsigned if needed (e.g., UGT vs SGT)
                  (final-int-pred (if is-unsigned
                                      (case int-pred-val
                                        (,+llvm-int-sgt+ ,+llvm-int-ugt+)
                                        (,+llvm-int-sge+ ,+llvm-int-uge+)
                                        (,+llvm-int-slt+ ,+llvm-int-ult+)
                                        (,+llvm-int-sle+ ,+llvm-int-ule+)
                                        (t int-pred-val))
                                      int-pred-val))

                  (cmp-inst
                   (cond
                    ((member (crisp-type-category lhs-type) '(:signed-int :unsigned-int))
                      (llvm-build-icmp builder final-int-pred lhs rhs "icmp_tmp"))
                    ((eq (crisp-type-category lhs-type) :float)
                      (llvm-build-fcmp builder ,float-pred lhs rhs "fcmp_tmp"))
                    (t (error "Unsupported comparison type: ~a" lhs-type-name)))))

             (let ((result (llvm-build-zext builder cmp-inst (llvm-int32-type) "bool_ext")))
               (values result nil))))))))

(def-comparison-codegen semantic-eq +llvm-int-eq+ +llvm-real-oeq+ "SEMANTIC-EQ")
(def-comparison-codegen semantic-neq +llvm-int-ne+ +llvm-real-one+ "SEMANTIC-NEQ")
(def-comparison-codegen semantic-lt +llvm-int-slt+ +llvm-real-olt+ "SEMANTIC-LT")
(def-comparison-codegen semantic-le +llvm-int-sle+ +llvm-real-ole+ "SEMANTIC-LE")
(def-comparison-codegen semantic-gt +llvm-int-sgt+ +llvm-real-ogt+ "SEMANTIC-GT")
(def-comparison-codegen semantic-ge +llvm-int-sge+ +llvm-real-oge+ "SEMANTIC-GE")

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
           (progn (log:info "llvm-get-named-function: ~a Module: ~a" callee-name module))
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
    (let ((last-val nil)
          (last-loc nil))
      (dolist (body-node (semantic-let-body node))
        (multiple-value-bind (val loc) (generate-expression-ir builder module let-env di-builder di-scope location-map body-node)
          (setf last-val val)
          (setf last-loc loc)))
      (values last-val last-loc))))

(defmethod generate-node-ir ((node semantic-funcall) builder module var-env di-builder di-scope location-map)
  "Generates IR for an indirect function call (funcall)."
  (declare (ignore di-builder di-scope location-map))
  (let* ((func-node (semantic-funcall-func-node node))
         (func-type-spec (semantic-node-type func-node)) ; (:function-type (ret) :params (p1 p2)) or literals
         (return-type-names (semantic-funcall-type node)) ; (int)
         (has-return-value (not (null (remove 'nil return-type-names))))
         (llvm-return-type (get-llvm-return-type module return-type-names))

         ;; Extract param types from the function type descriptor
         (param-types (cond
                       ((and (listp func-type-spec) (eq (first func-type-spec) :function-type))
                         (getf (cddr func-type-spec) :params))
                       ((and (listp func-type-spec) (eq (first func-type-spec) :function-literal))
                         ;; For literals, we rely on analyze-funcall-expression having verified constraints.
                         ;; We can get the params from the funcall arg types (which match the signature).
                         (mapcar #'semantic-node-type (semantic-funcall-args node)))
                       (t (error "Codegen error: Invalid function type for funcall: ~a" func-type-spec))))

         ;; Build LLVM function type
         (expanded-param-types (mapcan (lambda (p) (get-expanded-types p module)) param-types))
         (param-count (length expanded-param-types))
         (param-types-array (cffi:foreign-alloc 'llvm-type-ref :count param-count)))

    ;; Fill param types array
    (loop for i from 0
          for type in expanded-param-types
          do (setf (cffi:mem-aref param-types-array 'llvm-type-ref i) type))

    (let* ((llvm-fn-type (llvm-function-type llvm-return-type param-types-array param-count nil))

           ;; Generate the function pointer
           (callee (generate-node-ir func-node builder module var-env di-builder di-scope location-map))

           (arg-nodes (semantic-funcall-args node))
           (args-array (cffi:foreign-alloc 'llvm-value-ref :count param-count)))

      ;; Generate arguments
      (let ((idx 0))
        (loop for arg-node in arg-nodes
              for param-type in param-types
              do (multiple-value-bind (arg-val arg-loc) (generate-node-ir arg-node builder module var-env di-builder di-scope location-map)
                   (declare (ignore arg-loc))
                   (let ((exploded-vals (explode-value builder arg-val param-type)))
                     (dolist (val exploded-vals)
                       (setf (cffi:mem-aref args-array 'llvm-value-ref idx) val)
                       (incf idx))))))

      (let ((call-inst (llvm-build-call2 builder
                                         llvm-fn-type
                                         callee
                                         args-array
                                         param-count
                                         (if has-return-value "funcall_tmp" "")))
            (di-location (when (and di-builder di-scope location-map)
                               (let* ((loc (semantic-node-source-location node))
                                      (line (gethash loc location-map 0)))
                                 (llvm-di-builder-create-debug-location (llvm-get-module-context module)
                                                                        line 0 di-scope (cffi:null-pointer))))))
        (when di-location
              (llvm-instruction-set-debug-loc call-inst di-location))
        (values call-inst di-location)))));; --- IF ---
(defun terminator-p (block)
  "Checks if a basic block already has a terminator instruction."
  (not (cffi:null-pointer-p (llvm-get-basic-block-terminator block))))

(defmethod generate-node-ir ((node semantic-if) builder module var-env di-builder di-scope location-map)
  "Generates IR for an if expression."
  ;; 1. Evaluate the condition
  (multiple-value-bind (cond-val cond-loc)
      (generate-node-ir (semantic-if-condition-node node) builder module var-env di-builder di-scope location-map)
    (declare (ignore cond-loc))
    ;; Condition must be i1 (boolean) for cond_br.
    ;; Our language uses i32, so we truncate.
    ;; Note: In strict LLVM, 0 is false, non-zero is usually true. Truncating blindly might lose info
    ;; if the value is like 2 (binary 10), trunc to i1 is 0 (false)!
    ;; Correct logic: icmp ne %val, 0
    (let ((cond-bool (llvm-build-icmp builder +llvm-int-ne+ cond-val (llvm-const-int (llvm-int32-type) 0 nil) "ifcond")))

      (let ((then-block (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "then"))
            (else-block (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "else"))
            (merge-block (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "ifcont"))

            ;; Determine result type and allocate scratch space if needed (alloca trick)
            (result-type-spec (semantic-node-type node)))

        ;; Note: The result type might be 'void (nil).
        (let ((result-alloca
               (unless (or (null result-type-spec) (eq result-type-spec :void))
                 (let ((type (crisp-type-to-llvm-type result-type-spec module)))
                   (llvm-build-alloca builder type "if_result")))))

          ;; --- Create Conditional Branch ---
          (llvm-build-cond-br builder cond-bool then-block else-block)

          ;; --- Then Block ---
          (llvm-position-builder-at-end builder then-block)
          (multiple-value-bind (then-val then-loc)
              (generate-node-ir (semantic-if-then-node node) builder module var-env di-builder di-scope location-map)
            (declare (ignore then-loc))
            (when result-alloca
                  (llvm-build-store builder then-val result-alloca)))

          (unless (terminator-p (llvm-get-insert-block builder))
            (llvm-build-br builder merge-block))

          ;; --- Else Block ---
          (llvm-position-builder-at-end builder else-block)
          (if (semantic-if-else-node node)
              (multiple-value-bind (else-val else-loc)
                  (generate-node-ir (semantic-if-else-node node) builder module var-env di-builder di-scope location-map)
                (declare (ignore else-loc))
                (when result-alloca
                      (llvm-build-store builder else-val result-alloca)))
              ;; No else clause. If result expected, this is undefined behavior or nil.
              nil)
          (unless (terminator-p (llvm-get-insert-block builder))
            (llvm-build-br builder merge-block))

          ;; --- Merge Block ---
          (llvm-position-builder-at-end builder merge-block)
          (if result-alloca
              (let* ((type (crisp-type-to-llvm-type result-type-spec module))
                     (result-val (llvm-build-load2 builder type result-alloca "if_res")))
                (values result-val nil))
              (values nil nil)))))))

(defmethod generate-node-ir ((node semantic-struct-construction) builder module var-env di-builder di-scope location-map)
  (let* ((type-name (semantic-struct-construction-type node))
         (struct-def (gethash type-name *crisp-structs*))
         (llvm-type (ensure-struct-llvm-type type-name))
         (agg-val (llvm-get-undef llvm-type))
         (args (semantic-struct-construction-args node))
         (original-members (crisp-struct-definition-members struct-def))
         (field-indices (crisp-struct-definition-field-indices struct-def)))

    (loop for arg in args
          for member in original-members
          for i from 0
          for field-name = (first member)
          for field-idx = (gethash field-name field-indices)
          do (let ((val (generate-node-ir arg builder module var-env di-builder di-scope location-map)))
               (setf agg-val (llvm-build-insert-value builder agg-val val field-idx (format nil "insert_~a" field-name)))))
    (values agg-val nil)))

(defmethod generate-node-ir ((node semantic-extract-value) builder module var-env di-builder di-scope location-map)
  "Generates IR for extracting a value from an aggregate."
  (let* ((agg-node (semantic-extract-value-aggregate-node node))
         (index (semantic-extract-value-index node))
         (agg-val (generate-node-ir agg-node builder module var-env di-builder di-scope location-map))
         (val (llvm-build-extract-value builder agg-val index (format nil "extract_~d" index))))
    (values val nil)))

(defmethod generate-node-ir ((node semantic-set!) builder module var-env di-builder di-scope location-map)
  "Generates IR for (set! target value)."
  (let* ((target-node (semantic-set!-target-node node))
         (value-node (semantic-set!-value-node node))
         (new-val (generate-node-ir value-node builder module var-env di-builder di-scope location-map)))

    (cond
     ;; Case 1: Variable assignment. We need the ALLOCA, not the loaded value.
     ((semantic-var-read-p target-node)
       (let* ((var-name (semantic-var-read-name target-node))
              (var-ptr (gethash var-name var-env)))
         (unless var-ptr
           (error "Compiler error in set!: Variable ~a not found in environment." var-name))
         (llvm-build-store builder new-val var-ptr)
         ;; set! returns the new value (or void? Common Lisp returns the value)
         (values new-val nil)))

     (t (error "Unsupported target for set! codegen: ~a" target-node)))))

(defmethod generate-node-ir ((node semantic-struct-member-update) builder module var-env di-builder di-scope location-map)
  "Generates IR for updating a struct member: inserts value into struct and returns new struct."
  (let* ((struct-node (semantic-struct-member-update-struct-node node))
         (member-index (semantic-struct-member-update-member-index node))
         (value-node (semantic-struct-member-update-value-node node))
         ;; Generate the ORIGINAL struct value (load it)
         (struct-val (generate-node-ir struct-node builder module var-env di-builder di-scope location-map))
         ;; Generate the NEW member value
         (new-member-val (generate-node-ir value-node builder module var-env di-builder di-scope location-map))
         ;; Insert the new value
         (new-struct-val (llvm-build-insert-value builder struct-val new-member-val member-index "struct_update")))
    (values new-struct-val nil)))
