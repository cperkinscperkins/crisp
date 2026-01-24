;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.


;; src/codegen.lisp
(in-package :crisp.compiler)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


(defun get-or-create-di-type (crisp-type di-builder di-type-cache)
  "Gets a DIBasicType from a cache or creates it if it doesn't exist."
  (if crisp-type
      ;; It's a known, simple type.
      (or (gethash (crisp-type-name crisp-type) di-type-cache)
          (let* ((name-str (string-downcase (crisp-type-name crisp-type)))
                 (encoding (ecase (crisp-type-category crisp-type)
                             (:signed-int 5) ; DW_ATE_signed
                             (:unsigned-int 7) ; DW_ATE_unsigned
                             (:float 4) ; DW_ATE_float
                             (:struct 7) ; Fallback: Treat struct as unsigned blob for now
                             (:record 7) ; Treat record as struct/unsigned for now
                             (:pointer 7)
                             (:void (return-from get-or-create-di-type (cffi:null-pointer)))))
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


(defun generate-debug-info (di-builder di-compile-unit func fn-name fn-loc return-type param-nodes location-map)
  "Generates and attaches DWARF debug info for the function."
  (when di-builder
        (let ((di-type-cache (make-hash-table)))
          ;; File info
          (let* ((di-file (when di-compile-unit
                                (llvm-di-builder-create-file di-builder
                                                             "test.crisp" (length "test.crisp")
                                                             "/tmp/" (length "/tmp/"))))
                 (line-num (if location-map (or (gethash fn-loc location-map) 0) 0)))

            ;; Type info
            (let* ((di-return-type (get-or-create-di-type (gethash return-type *crisp-types*)
                                                          di-builder
                                                          di-type-cache))
                   (di-param-types (cons di-return-type
                                         (loop for param in param-nodes
                                               collect (get-or-create-di-type
                                                        (gethash (semantic-param-type param) *crisp-types*)
                                                        di-builder
                                                        di-type-cache)))))

              ;; Parameter array
              (let* ((di-param-array (let ((ptr (cffi:foreign-alloc :pointer :count (length di-param-types))))
                                       (loop for i from 0
                                             for type in di-param-types
                                             do (setf (cffi:mem-aref ptr :pointer i) type))
                                       ptr))
                     ;; Function type
                     (di-fn-type (llvm-di-builder-create-subroutine-type
                                  di-builder di-file di-param-array (length di-param-types) 0))
                     ;; Subprogram
                     (subprogram (llvm-di-builder-create-function
                                  di-builder di-compile-unit
                                  fn-name (length fn-name)
                                  fn-name (length fn-name)
                                  di-file line-num di-fn-type nil t 0 0 nil)))

                (llvm-set-subprogram func subprogram)
                subprogram))))))

(defun initialize-function-parameters (builder func param-nodes module var-env)
  "Allocates stack space and stores function parameters."
  (let ((llvm-param-index 0))
    (loop for param-node in param-nodes
          for param-name = (semantic-param-name param-node)
          for type-spec = (semantic-param-type param-node)
          do
            (log:debug "Init-func-params: param-name='~s' (type: ~a) type-spec='~s'"
                       param-name (type-of param-name) type-spec)
            (log:debug "Cached INT32: ~a" *cached-int32-type*)
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

;; Patch to add SPIR-V kernel metadata functions to codegen.lisp
;; Insert BEFORE the line: (defun generate-function-prototype

(defun ensure-opencl-kernel-metadata (func semantic-function module)
  "Marks a function as a SPIR-V/PTX kernel if it's an entry point.
   Sets the appropriate calling convention (76 for SPIR-V, 71 for PTX).
   
   NOTE: Kernel argument metadata (address space, access qualifiers, etc.) is added
   as text during IR printing for SPIR-V."
  (when (semantic-function-is-entry-point semantic-function)
        (log:info "Marking function ~a as Kernel for backend ~a"
                  (semantic-function-name semantic-function) *target-backend*)

        (case *target-backend*
          (:spirv
           ;; calling convention spir_kernel (76)
           (llvm-set-function-call-conv func 76))
          (:ptx
           ;; Use ptx_kernel calling convention (71) so llc emits .entry
           ;; If this crashes on Windows, we will need to revisit nvvm attributes.
           (log:info "Setting CC 71 (ptx_kernel) for function ~a" (semantic-function-name semantic-function))
           (llvm-set-function-call-conv func 71))
          (t
           ;; Default to C calling convention (0) for generic/unknown
           (log:warn "Using default CC (0) for kernel in backend ~a" *target-backend*)
           (llvm-set-function-call-conv func 0))))

  (unless (semantic-function-is-entry-point semantic-function)
    (case *target-backend*
      (:spirv
       ;; Use SPIR_FUNC (75) for non-kernel functions
       (llvm-set-function-call-conv func 75)))))

(defun %check-existing-function (existing fn-name di-builder di-compile-unit func crisp-return-type param-nodes location-map fn-loc module fn-type)
  "Helper: Handles redefinition or forward declaration of existing functions."
  (cond
   ;; Case 1: Redefinition (Function has a body already). We must Replace it.
   ((> (llvm-count-basic-blocks existing) 0)
     (log:warn "Redefining function ~a (replacing existing definition)." fn-name)
     (llvm-delete-function existing)
     (let ((new-func (llvm-add-function module fn-name fn-type)))
       (let ((di-subprogram (generate-debug-info di-builder di-compile-unit new-func fn-name fn-loc crisp-return-type param-nodes location-map)))
         (values new-func di-subprogram))))

   ;; Case 2: Forward Declaration (Function has no body). Reuse it.
   (t
     (values existing nil)))) ; TODO: Debug info for definition of forward decl?

(defun %create-new-function (fn-name fn-type module di-builder di-compile-unit crisp-return-type param-nodes location-map fn-loc)
  "Helper: Creates a new function and its debug info."
  (let ((func (llvm-add-function module fn-name fn-type)))
    (let ((di-subprogram (generate-debug-info di-builder di-compile-unit func fn-name fn-loc crisp-return-type param-nodes location-map)))
      (values func di-subprogram))))

(defun generate-function-prototype (semantic-function module di-builder di-compile-unit location-map)
  "Generates the LLVM function prototype and debug info."
  (let* ((return-types (semantic-function-return-type semantic-function))
         (crisp-return-type (first return-types))
         (base-name (semantic-function-name semantic-function))
         (is-entry-point (semantic-function-is-entry-point semantic-function))

         ;; For Entry Points (Kernels): Use the exact name (case-insensitive/downcased per convention)
         ;; For Functions: Mangle with parameter types to support overloading.
         (mangled-name (if is-entry-point
                           (string-downcase (symbol-name base-name))
                           (let ((param-type-specs (mapcar #'semantic-param-type (semantic-function-param-list semantic-function))))
                             (format nil "~a~{_~a~}" base-name (mapcar #'mangle-type-spec param-type-specs)))))

         (fn-name (substitute #\_ #\~ (substitute #\_ #\- (string-downcase mangled-name))))
         (fn-loc (semantic-function-source-location semantic-function))
         (param-nodes (semantic-function-param-list semantic-function))
         (fn-type (create-llvm-function-type module return-types param-nodes)))

    (log:info "llvm-add-function: ~a Module: ~a" fn-name module)

    ;; Cache common types using GLOBAL context (Context-aware types seem to crash ConstInt)
    (setf *cached-int32-type* (llvm-int32-type))
    (setf *cached-int64-type* (llvm-int64-type))
    (log:debug "Cached INT32 (Global): ~a" *cached-int32-type*)

    ;; FILTER: On PTX, skip functions that return structs by value to avoid llc crash.
    (when (eq *target-backend* :ptx)
          (let ((type-obj (gethash crisp-return-type *crisp-types*)))
            (when (and type-obj (member (crisp-type-category type-obj) '(:struct :record)))
                  (log:warn "Skipping generation of function ~a on PTX due to struct return value (unsupported)." fn-name)
                  (return-from generate-function-prototype (values nil nil)))))

    ;; Check if already exists (forward declaration or redefinition)
    (let ((existing (llvm-get-named-function module fn-name)))
      (if (and existing (not (cffi:null-pointer-p existing)))
          ;; Handle existing function (redefinition or forward decl)
          (%check-existing-function existing fn-name di-builder di-compile-unit
                                    (llvm-add-function module fn-name fn-type) ;; This is just for the prototype signature
                                    crisp-return-type param-nodes location-map fn-loc module fn-type)

          ;; Create new function
          (%create-new-function fn-name fn-type module di-builder di-compile-unit
                                crisp-return-type param-nodes location-map fn-loc)))))

(defun generate-function-body (semantic-function func di-subprogram builder module di-builder location-map)
  "Generates the body of the function."
  (let ((entry-block (llvm-append-basic-block func "entry"))
        (var-env (make-hash-table))
        (param-nodes (semantic-function-param-list semantic-function))
        (return-types (semantic-function-return-type semantic-function)))

    (log:debug "Positioning builder at entry block...")
    (llvm-position-builder-at-end builder entry-block)

    (initialize-function-parameters builder func param-nodes module var-env)

    (let* ((body-nodes (semantic-function-body semantic-function))
           (is-void-return (or (null return-types)
                               (equal return-types '(nil))
                               (and (consp return-types) (symbolp (first return-types)) (string-equal (first return-types) "VOID"))))
           (last-val nil)
           (last-loc nil))
      (dolist (node body-nodes)
        (multiple-value-bind (val loc)
            (generate-expression-ir builder module var-env di-builder di-subprogram location-map node)
          (setf last-val val)
          (setf last-loc loc)))

      (let ((ret-inst (if is-void-return
                          (llvm-build-ret-void builder)
                          (let* ((ret-type-spec (first return-types))
                                 (expected-type (crisp-type-to-llvm-type ret-type-spec module))
                                 (actual-type (llvm-type-of last-val)))
                            ;; Handle implicit dereference (Handle -> Value)
                            (if (and (llvm-type-kind-is-pointer? actual-type)
                                     (not (llvm-type-kind-is-pointer? expected-type)))
                                (llvm-build-ret builder (llvm-build-load2 builder expected-type last-val "ret_val"))
                                (llvm-build-ret builder last-val))))))
        (when last-loc (llvm-instruction-set-debug-loc ret-inst last-loc))))))

(defun generate-llvm-ir (semantic-function module builder di-builder di-compile-unit location-map)
  "Top-level function to generate LLVM IR for a given semantic function."
  (log:warn "GENERATE-LLVM-IR: ~a Params: ~a Ret: ~a"
            (semantic-function-name semantic-function)
            (semantic-function-param-list semantic-function)
            (semantic-function-return-type semantic-function))
  (log:warn "BODY: ~a" (semantic-function-body semantic-function))

  (multiple-value-bind (func di-subprogram)
      (generate-function-prototype semantic-function module di-builder di-compile-unit location-map)
    (when func
          ;; Attach SPIR-V/PTX kernel metadata if this is an entry point
          (ensure-opencl-kernel-metadata func semantic-function module)
          (generate-function-body semantic-function func di-subprogram builder module di-builder location-map))))

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

(defun resolve-keyword-constant (kw)
  "Resolves a keyword to its integer value by searching all registered enumerations."
  (if (integerp kw) kw
      (progn
       (maphash (lambda (name enum-def)
                  (declare (ignore name))
                  (let ((memb (assoc kw (crisp.compiler::enumeration-def-members enum-def))))
                    (when memb (return-from resolve-keyword-constant (cdr memb)))))
                *crisp-enums*)
       ;; Fallback: Hash the keyword for generic usage (e.g. &key tags)
       (ldb (byte 32 0) (sxhash kw)))))

;; -- literal value --

(defun %generate-keyword-literal-ir (value)
  "Helper: Generates IR for keyword/symbol/quote literals."
  (let ((ival (resolve-keyword-constant value)))
    (llvm-const-int (llvm-int32-type) ival nil)))

(defun %generate-cell-literal-ir (builder module var-env type-spec value)
  "Helper: Generates IR for cell literals (scratch cells)."
  (declare (ignore value))
  (let* ((base-type (first type-spec))
         (storage-var-name (or (when (gethash '__sc var-env) '__sc) '__storage))
         (storage-alloca (gethash storage-var-name var-env)))

    (unless storage-alloca
      (error "Missing implicit argument ~a for make-scratch-cell. Environment keys: ~s"
        storage-var-name (alexandria:hash-table-keys var-env)))

    (let* ((storage-type (crisp-type-to-llvm-type 'storage module))
           (storage-val (llvm-build-load2 builder storage-type storage-alloca "storage_val"))
           (mangled-name (mangle-template-struct-name base-type (rest type-spec)))
           (cell-struct-type (ensure-struct-llvm-type mangled-name))
           (cell-undef (llvm-get-undef cell-struct-type))
           (cell-0 (llvm-build-insert-value builder cell-undef storage-val 0 "parent"))
           (cell-1 (llvm-build-insert-value builder cell-0
                                            (llvm-const-int (llvm-int64-type) 0 nil)
                                            1 "offset"))
           (cell-handle (llvm-build-alloca builder cell-struct-type "cell_lit_handle")))
      (llvm-build-store builder cell-1 cell-handle)
      ;; RETURN THE VALUE (cell-1), NOT THE POINTER (cell-handle).
      ;; The alloca above is still useful if this literal is being bound to a variable 
      ;; (the caller's let-binding logic might expect an alloca to be available in var-env, 
      ;; but generate-expression-ir returns the VALUE). 
      ;; Wait, let-binding logic uses the returned value to store into ITS own alloca. 
      ;; So returning the value is correct.
      cell-1)))

(defun %generate-enum-literal-ir (builder value llvm-type)
  "Helper: Generates IR for enum literals."
  (let* ((val (resolve-keyword-constant value))
         (target-type (or llvm-type (llvm-int32-type)))
         (val-i64 (llvm-const-int (llvm-int64-type) (ldb (byte 64 0) val) nil)))
    (llvm-build-trunc builder val-i64 target-type "enum_trunc")))

(defun %generate-scalar-literal-ir (builder value llvm-type crisp-type)
  "Helper: Generates IR for scalar (int/float) literals."
  (cond
   ;; Integer types
   ((member (crisp-type-category crisp-type) '(:signed-int :unsigned-int))
     (if (zerop value)
         (llvm-const-null llvm-type)
         (let ((val-i64 (llvm-const-int (llvm-int64-type) (ldb (byte 64 0) value) nil)))
           (if (= (crisp-type-size crisp-type) 64)
               val-i64
               (llvm-build-trunc builder val-i64 llvm-type "int_trunc")))))

   ;; Float types
   ((eq (crisp-type-category crisp-type) :float)
     (llvm-const-real llvm-type (coerce value 'double-float)))

   ;; Void
   ((eq (crisp-type-category crisp-type) :void)
     nil)

   (t
     (error "Codegen for literal of unknown type category: ~a" (crisp-type-name crisp-type)))))

(defmethod generate-node-ir ((node semantic-literal) builder module var-env di-builder di-scope location-map)
  "Generates IR for a literal value."
  (let* ((type-spec (semantic-literal-value-type node))
         (value (semantic-literal-value node))
         (llvm-type (unless (member type-spec '(keyword symbol quote))
                      (crisp-type-to-llvm-type type-spec module)))
         (result
          (cond
           ;; Keywords/symbols/quotes (simple case)
           ((or (eq type-spec 'keyword) (eq type-spec 'symbol) (eq type-spec 'quote))
             (%generate-keyword-literal-ir value))

           ;; Parameterized types (lists)
           ((listp type-spec)
             (let ((base-type (first type-spec)))
               (cond
                ;; Function literals
                ((or (eq base-type :function-literal) (eq base-type :function-type))
                  (llvm-get-undef llvm-type))

                ;; Keywords/symbols in list form
                ((or (eq base-type 'keyword) (eq base-type 'symbol))
                  (%generate-keyword-literal-ir value))

                ;; Cell literals
                ((eq base-type 'cell)
                  (%generate-cell-literal-ir builder module var-env type-spec value))

                (t
                  (error "Codegen not implemented for literal of type ~a" type-spec)))))

           ;; Simple or singleton types
           ((or (symbolp type-spec)
                (and (consp type-spec) (member (first type-spec) '(keyword symbol quote))))
             (let ((type-sym (if (consp type-spec) (first type-spec) type-spec)))
               (cond
                ;; Enums or keywords
                ((or (gethash type-spec *crisp-enums*)
                     (member type-sym '(keyword symbol quote)))
                  (%generate-enum-literal-ir builder value llvm-type))

                ;; Scalars (int/float)
                (t
                  (let ((crisp-type (gethash type-sym *crisp-types*)))
                    (unless crisp-type
                      (error "Codegen: Literal type ~a not found in *crisp-types* or *crisp-enums*" type-spec))
                    (%generate-scalar-literal-ir builder value llvm-type crisp-type))))))

           (t
             (error "Codegen not implemented for literal of type ~a" type-spec))))

         (di-location
          (when (and di-builder di-scope location-map)
                (let* ((loc (semantic-node-source-location node))
                       (line (gethash loc location-map 0)))
                  (llvm-di-builder-create-debug-location (llvm-get-module-context module)
                                                         line 0 di-scope (cffi:null-pointer))))))
    (values result di-location)))


;; -- reading a variable --
(defmethod generate-node-ir ((node semantic-var-read) builder module var-env di-builder di-scope location-map)
  "Generates IR for reading a variable."
  (declare (ignore di-builder di-scope location-map))
  (log:debug "Generating IR for var-read: ~s" (semantic-var-read-name node))
  (let* ((var-name (semantic-var-read-name node))
         (alloca (gethash var-name var-env)))
    (when (null alloca)
          (log:error "CRITICAL: Var ~a not found in var-env!" var-name)
          (log:error "Var-env keys: ~a" (alexandria:hash-table-keys var-env)))
    (let* ((type (crisp-type-to-llvm-type (semantic-var-read-type node) module))
           (loaded-name (string-downcase (format nil "~a" var-name))))
      (log:info "Var-read: ~a. Alloca: ~a. Type: ~a" var-name alloca type)
      (values (llvm-build-load2 builder type alloca loaded-name)
        nil))))

;; -- addition --
(defun get-type-cat-safe (type-name type-obj)
  (cond
   (type-obj (crisp-type-category type-obj))
   ((and (consp type-name) (eq (first type-name) 'c-pointer)) :pointer)
   (t nil)))


(defun build-cast-if-needed (builder module from-val from-type-name to-type-name)
  "Builds LLVM cast instruction if types differ, with alias resolution.
   MODULE is required to resolve types correctly."
  ;; Resolve aliases first
  (cl:let ((from-type-name (resolve-type-alias from-type-name))
           (to-type-name (resolve-type-alias to-type-name)))
    (if (equal from-type-name to-type-name)
        (progn
         (log:debug "build-cast-if-needed: No cast needed for ~s" from-type-name)
         from-val)
        (let* ((from-type (if (symbolp from-type-name) (gethash from-type-name *crisp-types*) nil))
               (to-type (if (symbolp to-type-name) (gethash to-type-name *crisp-types*) nil))
               (to-llvm-type (crisp-type-to-llvm-type to-type-name module))
               (from-cat (get-type-cat-safe from-type-name from-type))
               (to-cat (get-type-cat-safe to-type-name to-type)))
          (log:debug "build-cast-if-needed: Casting from ~s to ~s" from-type-name to-type-name)
          (cond
           ((and (member from-cat (quote (:signed-int :unsigned-int)))
                 (eq to-cat (quote :float)))
             (if (eq from-cat (quote :signed-int))
                 (llvm-build-si-to-fp builder from-val to-llvm-type "si2fp_cast")
                 (llvm-build-ui-to-fp builder from-val to-llvm-type "ui2fp_cast")))
           ((and (member from-cat (quote (:signed-int :unsigned-int)))
                 (member to-cat (quote (:signed-int :unsigned-int))))
             (let ((from-size (crisp-type-size from-type))
                   (to-size (crisp-type-size to-type)))
               (cond
                ((< to-size from-size)
                  (llvm-build-trunc builder from-val to-llvm-type "trunc_cast"))
                ((> to-size from-size)
                  (if (eq from-cat (quote :signed-int))
                      (llvm-build-sext builder from-val to-llvm-type "sext_cast")
                      (llvm-build-zext builder from-val to-llvm-type "zext_cast")))
                (t from-val))))
           ((and (eq from-cat (quote :float)) (eq to-cat (quote :float)))
             (let ((from-size (crisp-type-size from-type))
                   (to-size (crisp-type-size to-type)))
               (cond
                ((< to-size from-size)
                  (llvm-build-fp-trunc builder from-val to-llvm-type "fptrunc_cast"))
                ((> to-size from-size)
                  (llvm-build-fp-ext builder from-val to-llvm-type "fpext_cast"))
                (t from-val))))
           ((and (eq from-cat (quote :float)) (member to-cat (quote (:signed-int :unsigned-int))))
             (if (eq to-cat (quote :signed-int))
                 (llvm-build-fp-to-si builder from-val to-llvm-type "fp2si_cast")
                 (llvm-build-fp-to-ui builder from-val to-llvm-type "fp2ui_cast")))
           ((and (member from-cat (quote (:signed-int :unsigned-int)))
                 (eq to-cat (quote :pointer)))
             ;; INT -> PTR
             ;; Check Address Space of target
             (let ((as (llvm-get-pointer-address-space to-llvm-type)))
               (if (= as 0)
                   (llvm-build-int-to-ptr builder from-val to-llvm-type "int2ptr_cast")
                   ;; If target is NOT Generic (0), we must cast Int -> GenericPtr -> TargetPtr
                   ;; to ensure LLVM emits `cvta` (Convert Address) or valid bits.
                   ;; Direct Int -> GlobalPtr just reinterprets bits, which fails if Generic != Global.
                   (let* ((generic-ptr-type (crisp-type-to-llvm-type '(c-pointer) module))
                          (tmp-ptr (llvm-build-int-to-ptr builder from-val generic-ptr-type "int2generic")))
                     (llvm-build-addrspace-cast builder tmp-ptr to-llvm-type "generic2as_cast")))))
           ((and (eq from-cat (quote :pointer))
                 (member to-cat (quote (:signed-int :unsigned-int))))
             (llvm-build-ptr-to-int builder from-val to-llvm-type "ptr2int_cast"))
           ((and (eq from-cat (quote :pointer))
                 (eq to-cat (quote :pointer)))
             (let ((from-as (llvm-get-pointer-address-space (llvm-type-of from-val)))
                   (to-as (llvm-get-pointer-address-space to-llvm-type)))
               (if (= from-as to-as)
                   (llvm-build-bit-cast builder from-val to-llvm-type "ptr2ptr_cast")
                   (llvm-build-addrspace-cast builder from-val to-llvm-type "ptr2ptr_ascast"))))
           (t
             (log:error "CODEGEN CAST ERROR: ~a -> ~a" from-type-name to-type-name)
             (log:error "  From Type: ~a (cat: ~a)" from-type from-cat)
             (log:error "  To Type:   ~a (cat: ~a)" to-type to-cat)
             (log:error "  Value dump: ~a" (llvm-print-value-to-string from-val))
             (error "Unsupported value cast from ~a to ~a" from-type-name to-type-name)))))))

(defmacro def-binary-op-codegen (node-type int-inst float-inst accessor-prefix)
  (let ((left-accessor (intern (format nil "~a-LEFT-ARG" accessor-prefix)))
        (right-accessor (intern (format nil "~a-RIGHT-ARG" accessor-prefix)))
        (type-accessor (intern (format nil "~a-TYPE" accessor-prefix))))
    `(defmethod generate-node-ir ((node ,node-type) builder module var-env di-builder di-scope location-map)
       ,(format nil "Generates IR for ~a." node-type)
       (multiple-value-bind (lhs lhs-loc) (generate-node-ir (,left-accessor node) builder module var-env di-builder di-scope location-map)
         (declare (ignore lhs-loc))
         (multiple-value-bind (rhs rhs-loc) (generate-node-ir (,right-accessor node) builder module var-env di-builder di-scope location-map)
           (declare (ignore rhs-loc))
           (let* ((result-type-name (,type-accessor node))
                  (lhs-type-name (get-single-value-type (,left-accessor node)))
                  (rhs-type-name (get-single-value-type (,right-accessor node)))
                  ;; Ensure MVR structs are unpacked
                  (lhs-raw (extract-primary-value builder lhs (semantic-node-type (,left-accessor node))))
                  (rhs-raw (extract-primary-value builder rhs (semantic-node-type (,right-accessor node))))
                  (casted-lhs (build-cast-if-needed builder module lhs-raw lhs-type-name result-type-name))
                  (casted-rhs (build-cast-if-needed builder module rhs-raw rhs-type-name result-type-name))
                  (crisp-type (gethash result-type-name *crisp-types*))
                  (inst (if (eq (crisp-type-category crisp-type) :float)
                            (,float-inst builder casted-lhs casted-rhs "fop_tmp")
                            (,int-inst builder casted-lhs casted-rhs "iop_tmp")))
                  (di-location (when (and di-builder di-scope location-map)
                                     (let* ((loc (semantic-node-source-location node))
                                            (line (gethash loc location-map 0)))
                                       (llvm-di-builder-create-debug-location (llvm-get-module-context module)
                                                                              line
                                                                              0 ; column
                                                                              di-scope
                                                                              (cffi:null-pointer))))))
             (when di-location (llvm-instruction-set-debug-loc inst di-location))
             (values inst di-location)))))))

(def-binary-op-codegen semantic-add llvm-build-add llvm-build-fadd "SEMANTIC-ADD")
(def-binary-op-codegen semantic-sub llvm-build-sub llvm-build-fsub "SEMANTIC-SUB")
(def-binary-op-codegen semantic-mul llvm-build-mul llvm-build-fmul "SEMANTIC-MUL")
;; Note: Div logic might need special handling for signed/unsigned later (sdiv vs udiv),
;; but simpler macro assumes sdiv for now or that llvm-build-sdiv is distinct.
;; Assuming signed integers for now as per initialized types.
(def-binary-op-codegen semantic-div llvm-build-sdiv llvm-build-fdiv "SEMANTIC-DIV")

;; -- comparisons --
(defun generate-comparison-ir (builder module var-env di-builder di-scope location-map node op-node-int op-node-float)
  "Helper to generate IR for comparison operators (<, >, =, etc)."
  (let (;; Oops, semantic-lt etc don't store signature effectively in common way, 
        ;; but they do store left-arg and right-arg. Let's assume standard accessors.
        (left-arg (slot-value node 'left-arg))
        (right-arg (slot-value node 'right-arg)))

    (multiple-value-bind (lhs lhs-loc) (generate-node-ir left-arg builder module var-env di-builder di-scope location-map)
      (declare (ignore lhs-loc))
      (multiple-value-bind (rhs rhs-loc) (generate-node-ir right-arg builder module var-env di-builder di-scope location-map)
        (declare (ignore rhs-loc))
        (let* ((lhs-type-name (get-single-value-type left-arg))
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
                  ;; Ensure MVR structs are unpacked (comparing primary values)
                  (lhs (extract-primary-value builder lhs (semantic-node-type (,left-accessor node))))
                  (rhs (extract-primary-value builder rhs (semantic-node-type (,right-accessor node))))
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

(defun prepare-call-arguments (builder module var-env di-builder di-scope location-map arg-nodes param-types param-count)
  "Prepares arguments for a function call by generating IR, exploding values, and filling a CFFI array."
  (let ((args-array (cffi:foreign-alloc 'llvm-value-ref :count param-count))
        (idx 0))
    (loop for arg-node in arg-nodes
          for param-type-spec in param-types ; param-types is already a list of type-specs
          do (multiple-value-bind (arg-val arg-loc) (generate-node-ir arg-node builder module var-env di-builder di-scope location-map)
               (declare (ignore arg-loc))
               (let* ((arg-type-spec (semantic-node-type arg-node))
                      (prim-val (extract-primary-value builder arg-val arg-type-spec))
                      (exploded-vals (explode-value builder prim-val param-type-spec)))
                 (dolist (val exploded-vals)
                   (setf (cffi:mem-aref args-array 'llvm-value-ref idx) val)
                   (incf idx)))))
    args-array))

(defmethod generate-node-ir ((node semantic-value-cast) builder module var-env di-builder di-scope location-map)
  "Generates IR for a value-preserving cast."
  (multiple-value-bind (arg-val arg-loc) (generate-node-ir (semantic-value-cast-arg node) builder module var-env di-builder di-scope location-map)
    (declare (ignore arg-loc))
    (let* ((arg-type (semantic-node-type (semantic-value-cast-arg node)))
           (arg-val (extract-primary-value builder arg-val arg-type))
           (from-type-name (get-single-value-type (semantic-value-cast-arg node)))
           (to-type-name (semantic-value-cast-type node))
           (cast-val (build-cast-if-needed builder module arg-val from-type-name to-type-name)))
      ;; NOTE: This will need to be expanded to handle more `to-` conversions.
      ;; For now, it relies on the implicit promotion logic.
      (values cast-val nil))))

(defmethod generate-node-ir ((node semantic-bitcast) builder module var-env di-builder di-scope location-map)
  "Generates IR for a bitcast."
  (multiple-value-bind (arg-val arg-loc) (generate-node-ir (semantic-bitcast-arg node) builder module var-env di-builder di-scope location-map)
    (declare (ignore arg-loc))
    (let* ((arg-type (semantic-node-type (semantic-bitcast-arg node)))
           (arg-val (extract-primary-value builder arg-val arg-type))
           (to-type-spec (semantic-bitcast-type node))
           (to-llvm-type (crisp-type-to-llvm-type to-type-spec module))
           (cast-val (llvm-build-bit-cast builder arg-val to-llvm-type "bitcast")))
      (values cast-val nil))))

(defmethod generate-node-ir ((node semantic-fp-truncate-cast) builder module var-env di-builder di-scope location-map)
  "Generates IR for a float-to-integer truncation cast."
  (multiple-value-bind (arg-val arg-loc) (generate-node-ir (semantic-fp-truncate-cast-arg node) builder module var-env di-builder di-scope location-map)
    (declare (ignore arg-loc))
    (let* ((arg-type (semantic-node-type (semantic-fp-truncate-cast-arg node)))
           (arg-val (extract-primary-value builder arg-val arg-type))
           (to-type-spec (semantic-fp-truncate-cast-type node))
           (to-llvm-type (crisp-type-to-llvm-type to-type-spec module))
           ;; NOTE: This assumes a signed conversion. We'll need to check the
           ;; crisp-type category to select fptosi vs fptoui in the future.
           (cast-val (llvm-build-fp-to-si builder arg-val to-llvm-type "fptosi")))
      (values cast-val nil))))

(defmethod generate-node-ir ((node semantic-truncate) builder module var-env di-builder di-scope location-map)
  "Generates IR for (truncate val) -> (values int rem)."
  (multiple-value-bind (arg-val arg-loc) (generate-node-ir (semantic-truncate-arg node) builder module var-env di-builder di-scope location-map)
    (declare (ignore arg-loc))
    (let* ((result-types (semantic-truncate-type node)) ; (int float)
                                                       (quot-type (or *cached-int32-type* (llvm-int32-type)))
                                                       (rem-type (llvm-float-type)) ;; Assuming float input for now
                                                       ;; 1. Calculate Quotient: fptosi
                                                       (quot-val (llvm-build-fp-to-si builder arg-val quot-type "quot"))
                                                       ;; 2. Calculate Remainder: val - (float quot)
                                                       (quot-float (llvm-build-si-to-fp builder quot-val rem-type "quot_f"))
                                                       (rem-val (llvm-build-fsub builder arg-val quot-float "rem"))
                                                       ;; 3. Build Struct
                                                       (struct-type (get-llvm-return-type module result-types))
                                                       (agg-undef (llvm-get-undef struct-type))
                                                       (agg-0 (llvm-build-insert-value builder agg-undef quot-val 0 "res_q"))
                                                       (agg-1 (llvm-build-insert-value builder agg-0 rem-val 1 "res_r")))
      (values agg-1 nil))))


(defun %handle-die-intrinsic (builder module)
  "Helper: Handles the compiler intrinsic DIE (llvm.trap)."
  (let ((trap-name "llvm.trap"))
    (let ((f (llvm-get-named-function module trap-name)))
      (when (cffi:null-pointer-p f)
            (let ((ft (llvm-function-type (llvm-void-type) (cffi:null-pointer) 0 nil)))
              (setf f (llvm-add-function module trap-name ft))))
      (llvm-build-call2 builder
                        (llvm-function-type (llvm-void-type) (cffi:null-pointer) 0 nil)
                        f
                        (cffi:null-pointer)
                        0
                        ""))
    (values nil nil)))

(defun %build-function-call (builder module var-env di-builder di-scope location-map node sig callee-name llvm-fn-type param-nodes param-count return-type-names)
  "Helper: Builds the actual function call instruction."
  (let* ((arg-nodes (semantic-call-args node))
         (args-array (prepare-call-arguments builder module var-env di-builder di-scope location-map
                                             arg-nodes param-nodes param-count))
         (call-inst (llvm-build-call2 builder
                                      llvm-fn-type
                                      (let ((f (llvm-get-named-function module callee-name)))
                                        (if (cffi:null-pointer-p f)
                                            (llvm-add-function module callee-name llvm-fn-type)
                                            f))
                                      args-array
                                      param-count
                                      (if (or (null return-type-names)
                                              (equal return-type-names '(nil))
                                              (and (consp return-type-names) (eq (first return-type-names) 'void)))
                                          ""
                                          "call_tmp")))
         (di-location (when (and di-builder di-scope location-map)
                            (let* ((loc (semantic-node-source-location node))
                                   (line (gethash loc location-map 0)))
                              (llvm-di-builder-create-debug-location (llvm-get-module-context module)
                                                                     line 0 di-scope (cffi:null-pointer))))))
    (when di-location
          (llvm-instruction-set-debug-loc call-inst di-location))
    (values call-inst di-location)))

(defmethod generate-node-ir ((node semantic-call) builder module var-env di-builder di-scope location-map)
  "Generates IR for a function call."

  ;; Special handling for compiler intrinsic DIE
  (when (eq (semantic-call-name node) 'die)
        (return-from generate-node-ir (%handle-die-intrinsic builder module)))

  (let* ((sig (semantic-call-signature node))
         (return-type-names (function-signature-return-types sig))
         (llvm-return-type (get-llvm-return-type module return-type-names))

         ;; Build the LLVM function *type* (the signature)
         (param-nodes (mapcar #'parameter-def-type (function-signature-parameters sig)))
         (expanded-param-types (mapcan (lambda (p) (get-expanded-types p module)) param-nodes))
         (param-count (length expanded-param-types))
         (param-types-array (cffi:foreign-alloc 'llvm-type-ref :count param-count)))

    ;; Fill param types array
    (loop for i from 0
          for type in expanded-param-types
          do (setf (cffi:mem-aref param-types-array 'llvm-type-ref i) type))

    (let* (;; The name of the function in LLVM IR is mangled with its types
           (mangled-name (format nil "~a~{_~a~}" (semantic-call-name node)
                           (mapcar #'mangle-type-spec (mapcar #'parameter-def-type (function-signature-parameters sig)))))
           (callee-name (substitute #\_ #\~ (substitute #\_ #\- (string-downcase mangled-name))))
           (llvm-fn-type (llvm-function-type llvm-return-type param-types-array param-count nil)))

      ;; Build and return the call
      (%build-function-call builder module var-env di-builder di-scope location-map node sig
                            callee-name llvm-fn-type param-nodes param-count return-type-names))))

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

(defmethod generate-node-ir ((node semantic-progn) builder module var-env di-builder di-scope location-map)
  "Generates IR for a progn expression."
  (let ((last-val nil))
    (dolist (sub-node (semantic-progn-body node))
      (setf last-val (generate-node-ir sub-node builder module var-env di-builder di-scope location-map)))
    (values last-val nil)))


(defun %generate-let-binding (binding builder module let-env di-builder di-scope location-map memoized-aggregates)
  "Helper: Generates IR for a single let binding.
   Updates let-env with the new binding and returns the alloca."
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

      ;; Allocate and store
      (let ((alloca (llvm-build-alloca builder (crisp-type-to-llvm-type llvm-type-name module) (string-downcase var-name))))
        (llvm-build-store builder val-ir alloca)
        (setf (gethash var-name let-env) alloca)
        alloca))))

(defmethod generate-node-ir ((node semantic-let) builder module var-env di-builder di-scope location-map)
  "Generates IR for a let expression."
  ;; Create a new environment for the let block that inherits from the outer one.
  (let ((let-env (alexandria:copy-hash-table var-env))
        (memoized-aggregates (make-hash-table :test 'eq)))

    ;; Generate code for each binding
    (dolist (binding (semantic-let-bindings node))
      (%generate-let-binding binding builder module let-env di-builder di-scope location-map memoized-aggregates))

    ;; Generate code for the body, using the extended environment.
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
           (args-array (prepare-call-arguments builder module var-env di-builder di-scope location-map
                                               arg-nodes param-types param-count)))

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
               (unless (or (null result-type-spec)
                           (eq result-type-spec :void)
                           (eq result-type-spec 'void)
                           (equal result-type-spec '(nil)))
                 (let ((type (crisp-type-to-llvm-type result-type-spec module)))
                   (llvm-build-alloca builder type "if_result")))))

          ;; --- Create Conditional Branch ---
          (llvm-build-cond-br builder cond-bool then-block else-block)

          ;; --- Then Block ---
          (llvm-position-builder-at-end builder then-block)
          (if (semantic-if-then-node node)
              (multiple-value-bind (then-val then-loc)
                  (generate-node-ir (semantic-if-then-node node) builder module var-env di-builder di-scope location-map)
                (declare (ignore then-loc))
                (when result-alloca
                      (llvm-build-store builder then-val result-alloca)))
              ;; No then clause (e.g. unless). Treat as void/nil.
              nil)

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

    (log:info "Struct Construction: ~a" type-name)
    (log:info "  LLVM Type: ~a" (llvm-print-type-to-string llvm-type))
    (log:info "  Agg Val Type: ~a" (llvm-print-type-to-string (llvm-type-of agg-val)))

    (loop for arg in args
          for member in original-members
          for i from 0
          for field-name = (first member)
          for field-idx = (gethash field-name field-indices)
          do (let ((val (generate-node-ir arg builder module var-env di-builder di-scope location-map)))
               (setf agg-val (llvm-build-insert-value builder agg-val val field-idx (format nil "insert_~a" field-name)))))

    ;; Phase 5: If the logical type is a Handle (ptr) (e.g. Cell), but we constructed an Aggregate,
    ;; we must return the Handle (pointer to the aggregate).
    (let ((logical-type (resolve-type-to-llvm type-name)))
      (if (and (llvm-type-kind-is-pointer? logical-type)
               (not (llvm-type-kind-is-pointer? llvm-type)))
          (let ((handle (llvm-build-alloca builder llvm-type "cell_handle")))
            (llvm-build-store builder agg-val handle)
            (values handle nil))
          (values agg-val nil)))))

(defmethod generate-node-ir ((node semantic-extract-value) builder module var-env di-builder di-scope location-map)
  "Generates IR for extracting a value from an aggregate."
  (let* ((agg-node (semantic-extract-value-aggregate-node node))
         (index (semantic-extract-value-index node))
         (agg-val (generate-node-ir agg-node builder module var-env di-builder di-scope location-map)))

    ;; Recursively resolve the aggregate if it is a handle (ptr)
    (let ((final-agg-val
           (if (llvm-type-kind-is-pointer? (llvm-type-of agg-val))
               (let* ((crisp-type (semantic-node-type agg-node))
                      ;; Use ensure-struct-llvm-type for Structs (like Cell)
                      ;; But semantic-node-type might be list (CELL INT).
                      (struct-type (if (and (listp crisp-type) (eq (first crisp-type) 'cell))
                                       (ensure-struct-llvm-type (mangle-template-struct-name 'cell (rest crisp-type)))
                                       (if (symbolp crisp-type)
                                           (ensure-struct-llvm-type crisp-type)
                                           (error "Cannot extract from non-struct/handle type: ~a" crisp-type)))))
                 (llvm-build-load2 builder struct-type agg-val "loaded_agg"))
               agg-val)))

      (let ((val (llvm-build-extract-value builder final-agg-val index (format nil "extract_~d" index))))
        (values val nil)))))

(defmethod generate-node-ir ((node semantic-insert-value) builder module var-env di-builder di-scope location-map)
  "Generates IR for inserting a value into an aggregate."
  (let* ((agg-node (semantic-insert-value-aggregate-node node))
         (index (semantic-insert-value-index node))
         (value-node (semantic-insert-value-value-node node))
         (agg-val (generate-node-ir agg-node builder module var-env di-builder di-scope location-map))
         (value-val (generate-node-ir value-node builder module var-env di-builder di-scope location-map)))

    ;; Recursively resolve the aggregate if it is a handle (ptr)
    (let ((final-agg-val
           (if (llvm-type-kind-is-pointer? (llvm-type-of agg-val))
               (let* ((crisp-type (semantic-node-type agg-node))
                      (struct-type (if (symbolp crisp-type)
                                       (ensure-struct-llvm-type crisp-type)
                                       (error "Cannot insert into non-struct type: ~a" crisp-type))))
                 (llvm-build-load2 builder struct-type agg-val "loaded_agg"))
               agg-val)))

      ;; Extract primary value from the value node if needed
      (let ((final-value-val (extract-primary-value builder value-val (semantic-node-type value-node))))
        (let ((new-agg-val (llvm-build-insert-value builder final-agg-val final-value-val index (format nil "insert_~d" index))))
          (values new-agg-val nil))))))


(defmethod generate-node-ir ((node semantic-set!) builder module var-env di-builder di-scope location-map)
  "Generates IR for (set! target value)."
  (let* ((target-node (semantic-set!-target-node node))
         (value-node (semantic-set!-value-node node))
         (new-val (generate-node-ir value-node builder module var-env di-builder di-scope location-map))
         (new-val (extract-primary-value builder new-val (semantic-node-type value-node))))

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

     ;; Case 2: Array/Pointer assignment (set! (aref x i) v)
     ((semantic-aref-p target-node)
       (multiple-value-bind (val loc ptr)
           (generate-node-ir target-node builder module var-env di-builder di-scope location-map)
         (declare (ignore val loc))
         (unless ptr
           (error "Compiler error in set!: Target ~a did not return an address." target-node))
         (llvm-build-store builder new-val ptr)
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
         (new-member-val-raw (generate-node-ir value-node builder module var-env di-builder di-scope location-map))
         (new-member-val (extract-primary-value builder new-member-val-raw (semantic-node-type value-node)))
         ;; Insert the new value
         (new-struct-val (llvm-build-insert-value builder struct-val new-member-val member-index "struct_update")))
    (values new-struct-val nil)))

(defmethod generate-node-ir ((node semantic-aref) builder module var-env di-builder di-scope location-map)
  "Generates IR for array access (aref). Currently supports CELL types."
  (let* ((array-node (semantic-aref-array-node node))
         (index-node (semantic-aref-index-node node))
         (array-type (semantic-node-type array-node))
         (element-type (semantic-aref-type node))
         (cell-val (generate-node-ir array-node builder module var-env di-builder di-scope location-map))
         (index-val (generate-node-ir index-node builder module var-env di-builder di-scope location-map)))

    (let ((cell-spec (let* ((resolved (resolve-type-alias array-type))
                            (canon (canonicalize-type-specifier resolved)))
                       (cond
                        ;; Case A: Already (CELL ...)
                        ((and (listp canon) (eq (first canon) 'cell)) canon)
                        ;; Case B: (CELL_LONG_...) -> Unmangle content
                        ((and (listp canon) (= (length canon) 1) (symbolp (first canon)))
                          (unmangle-template-struct-name (first canon)))
                        ;; Case C: Symbol CELL_LONG_...
                        ((symbolp canon)
                          (unmangle-template-struct-name canon))
                        (t canon)))))
      (cond
       ;; Case 1: CELL parameterized type
       ((and (listp cell-spec) (eq (first cell-spec) 'cell))
         (let* (;; Use element-type from analysis if reliable, otherwise safe to derive
                (elem-type-spec element-type)
                (elem-llvm-type (crisp-type-to-llvm-type elem-type-spec module))
                (mangled-struct-name (mangle-template-struct-name (first cell-spec) (rest cell-spec))))

           (log:info "semantic-aref: Resolving cell struct: ~a" mangled-struct-name)
           (let ((cell-struct-type (ensure-struct-llvm-type mangled-struct-name)))
             ;; Phase 5: Cell types are now Records passed by value.
             ;; We must EXTRACT members (Parent, Offset) from the aggregate value.
             ;; Do NOT use GEP on the cell value itself.
             (log:info "semantic-aref: Using ExtractValue to access Cell Record members.")

             ;; 1. Get PARENT (index 0) -> STORAGE Value
             (let* ((parent-val (llvm-build-extract-value builder cell-val 0 "parent_val")))

               ;; Extract STORAGE.PTR (index 0 of STORAGE)
               (let* ((base-ptr (llvm-build-extract-value builder parent-val 0 "base_ptr")))

                 ;; 2. Get OFFSET (index 1 of CELL)
                 (let* ((cell-offset (llvm-build-extract-value builder cell-val 1 "cell_offset")))

                   ;; Calculate Element Size
                   (let* ((elem-size (llvm-size-of elem-llvm-type))
                          ;; Extend Index to i64 (assume s64 for now)
                          (index-i64 (llvm-build-sext builder index-val (llvm-int64-type) "index_i64"))
                          ;; Index Bytes = Index * Size
                          (index-bytes (llvm-build-mul builder index-i64 elem-size "index_bytes"))
                          ;; Total Offset = CellOffset + IndexBytes
                          (total-offset (llvm-build-add builder cell-offset index-bytes "total_offset")))

                     ;; Final Pointer = GEP(BasePtr, TotalOffset)
                     (cffi:with-foreign-object (indices :pointer 1)
                                               (setf (cffi:mem-aref indices :pointer 0) total-offset)
                                               (let* ((final-ptr-i8 (llvm-build-in-bounds-gep2 builder (llvm-int8-type) base-ptr indices 1 "final_ptr_i8")))

                                                 ;; Cast to Element and Load
                                                 (let* ((ptr-as (llvm-get-pointer-address-space (llvm-type-of final-ptr-i8)))
                                                        (target-ptr (llvm-build-bit-cast builder final-ptr-i8 (llvm-pointer-type elem-llvm-type ptr-as) "target_ptr"))
                                                        (loaded-val (llvm-build-load2 builder elem-llvm-type target-ptr "val")))

                                                   ;; Return loaded val, nil (loc), AND pointer (for set!)
                                                   (values loaded-val nil target-ptr)))))))))))

       (t (error "generate-node-ir semantic-aref: Unsupported array type: ~a (unmangled: ~a)" array-type cell-spec))))))

(defmethod generate-node-ir ((node semantic-sizeof) builder module var-env di-builder di-scope location-map)
  "Generates IR for a sizeof(T) expression. Returns an i64 constant."
  (declare (ignore builder var-env di-builder di-scope location-map))
  (log:info "Generating SIZEOF IR for type node: ~s" node)
  (let* ((target-type-spec (semantic-sizeof-target-type node))
         (llvm-type (crisp-type-to-llvm-type target-type-spec module))
         (size-val (llvm-size-of llvm-type)))
    ;; size-val is an LLVM Value (ConstantInt), so it's ready to use.
    (values size-val nil)))

(defmethod generate-node-ir ((node null) builder module var-env di-builder di-scope location-map)
  "Explict handler for NIL nodes (e.g. empty body return values or missing value nodes)."
  (declare (ignore builder module var-env di-builder di-scope location-map))
  (values nil))
