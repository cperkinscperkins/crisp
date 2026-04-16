;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;;; =========================================================
;;; Scratch Tensor / Vector / Matrix — Side Channel Support
;;; =========================================================
;;
;; Appended to: src/types/registry.lisp (conceptually)
;; Extend *side-channel-originators* to include the tensor scratch forms.

(setf *side-channel-originators*
      '(make-scratch-cell make-scratch-vector make-scratch-matrix make-scratch-tensor))


;;; =========================================================
;;; inject-implicit-arguments — pass type through unchanged
;;; =========================================================
;;
;; Appended to: src/environment.lisp
;;
;; *implicit-arg-map* now stores MANGLED SYMBOLS for tensor types
;; (done at registration time in %register-scratch-tensor-implicit and
;; analyze-scratch-tensor-expression).  Cell types remain as canonical
;; list specs so that hoist metadata serialization can extract the
;; address-space / access keyword fields.
;;
;; The previous redef called parse-type-specifier here, which converted
;; cell canonical lists to mangled symbols — breaking the hoist C++ generator
;; which uses the type as a C++ identifier (e.g. cell_int_global_read_write).
;;
;; Reverted to simple passthrough: types are already in the correct form.

(defun inject-implicit-arguments (name explicit-env)
  "Injects implicit arguments into the environment for carrier functions.
   Types in *implicit-arg-map* are already in the correct form:
   mangled symbols for tensors (no integers to mangle-type-spec),
   canonical lists for cells (preserved for hoist metadata)."
  (let* ((implicit-info (gethash name *implicit-arg-map*))
         (implicit-env
          (when implicit-info
            (loop for (param-name . param-type) in implicit-info
                  collect (make-parameter-def
                           :name param-name
                           :type param-type
                           :kind :in)))))
    (append implicit-env explicit-env)))


;;; =========================================================
;;; Pass 1 Scan Operators
;;; =========================================================
;;
;; Appended to: src/analysis/core.lisp
;;
;; %scratch-tensor-canonical-spec resolves both forms of the tensor scratch
;; syntax to a canonical (tensor elem N addr access align) type spec:
;;
;;   Form 1 (elem-type + N): (make-scratch-tensor float 3 :match-workgroup-size ...)
;;   Form 2 (type-alias):    (make-scratch-tensor scratch-float-t3 :match-workgroup-size ...)
;;
;; For make-scratch-vector N=1 is implicit; for make-scratch-matrix N=2.

(defun %scratch-tensor-canonical-spec (op args)
  "Resolves the type arguments of a make-scratch-{vector,matrix,tensor} form
   to a canonical (tensor elem N addr access align) spec.

   OP is the operator symbol.  ARGS is the rest of the form (everything after
   the operator).  Returns the canonical spec or NIL if resolution fails.

   Dual-syntax disambiguation for make-scratch-tensor:
     - If the second positional arg (after the first type-ish arg) is an integer
       AND the first arg is NOT a registered tensor/vector/matrix type alias,
       we treat it as Form 1: (elem-type N sizeExpr ...).
     - Otherwise Form 2: (tensor-type sizeExpr ...)."
  (unless args
    (return-from %scratch-tensor-canonical-spec nil))
  (let* ((op-name (symbol-name op))
         ;; Implicit N from the operator name for vector/matrix
         (implicit-n (cond ((string-equal op-name "MAKE-SCRATCH-VECTOR") 1)
                           ((string-equal op-name "MAKE-SCRATCH-MATRIX") 2)
                           (t nil))) ; tensor: N from args
         (arg1 (first args)))

    (cond
      ;; ── make-scratch-vector / make-scratch-matrix ─────────────────────────
      ;; N is fixed by the operator; arg1 is elem-type or tensor-type alias.
      (implicit-n
       (let* ((is-tensor-alias
               ;; A def-type alias is in *crisp-type-aliases* (not *crisp-types*),
               ;; so we check resolve-type-alias directly — it returns the original
               ;; spec list for aliases whose value is a storage-handle type.
               (and (symbolp arg1)
                    (let ((resolved (resolve-type-alias arg1)))
                      (and (consp resolved)
                           (member (symbol-name (first resolved))
                                   '("TENSOR" "VECTOR" "MATRIX")
                                   :test #'string-equal)))))
              (raw-spec
               (if is-tensor-alias
                   ;; Form 2: use the alias directly
                   (resolve-type-alias arg1)
                   ;; Form 1: wrap bare element type
                   (list 'tensor arg1 implicit-n))))
         (expand-storage-handle-type-specifier
          ;; Normalize: force address-space :local (scratch default) if not set
          (if (and (consp raw-spec)
                   (string-equal (symbol-name (first raw-spec)) "TENSOR")
                   (= (length raw-spec) 3))   ; only elem + N, no addr/access/align yet
              (append raw-spec '(:address-space :local :access :read-write :align :compact))
              raw-spec))))

      ;; ── make-scratch-tensor ───────────────────────────────────────────────
      ;; Disambiguate Form 1 vs Form 2 by inspecting the second positional arg.
      (t
       (let* ((arg2 (second args))
              ;; Form 1 if arg2 is an integer AND arg1 is not a tensor type alias
              (is-tensor-alias
               (and (symbolp arg1)
                    (let ((resolved (resolve-type-alias arg1)))
                      (and (consp resolved)
                           (member (symbol-name (first resolved))
                                   '("TENSOR" "VECTOR" "MATRIX")
                                   :test #'string-equal)))))
              (form-1-p (and (integerp arg2) (not is-tensor-alias)))
              (raw-spec
               (if form-1-p
                   ;; Form 1: (make-scratch-tensor elem N sizeExpr ...)
                   (list 'tensor arg1 arg2)
                   ;; Form 2: (make-scratch-tensor tensor-type sizeExpr ...)
                   (if is-tensor-alias
                       (resolve-type-alias arg1)
                       (list 'tensor arg1)))))     ; degenerate: will error at expand
         (expand-storage-handle-type-specifier
          (if (and (consp raw-spec)
                   (string-equal (symbol-name (first raw-spec)) "TENSOR")
                   (= (length raw-spec) 3))
              (append raw-spec '(:address-space :local :access :read-write :align :compact))
              raw-spec)))))))


(defun %register-scratch-tensor-implicit (op args)
  "Shared logic for scan-operator methods on make-scratch-{vector,matrix,tensor}.
   Marks the current function as an originator and records the mangled symbol type
   in *implicit-arg-map* under a deterministic unique name.

   IMPORTANT: stores the MANGLED SYMBOL (not the canonical list) in *implicit-arg-map*
   so that all consumers — inject-implicit-arguments, analyze-function-call — can pass
   the type through mangle-type-spec without hitting integers in the canonical list."
  (setf *scan-is-originator* t)
  (when args
    (let ((canonical-spec (%scratch-tensor-canonical-spec op args)))
      (when canonical-spec
        (let* ((binding-name (or (compiler-context-current-binding-name *compiler-context*)
                                 '__storage))
               (fn-name (compiler-context-scanning-function-name *compiler-context*))
               (counter (incf *scratch-cell-counter*))
               (unique-name-str (format nil "~a_FROM_~a_~d" binding-name fn-name counter))
               (unique-name (intern unique-name-str (symbol-package binding-name)))
               ;; Convert canonical list to mangled symbol so mangle-type-spec works on it.
               (mangled-type (handler-case (parse-type-specifier canonical-spec)
                               (error () canonical-spec))))

          (log:info "Pass 1: ~a ~a -> implicit: ~a (type: ~a, mangled: ~a)"
                    op binding-name unique-name canonical-spec mangled-type)

          (let ((new-entry (cons unique-name mangled-type)))
            (push new-entry (gethash fn-name *implicit-arg-map*))))))))


(defmethod scan-operator ((op (eql 'make-scratch-vector)) args)
  "Scans make-scratch-vector and registers the implicit tensor (N=1) arg."
  (%register-scratch-tensor-implicit op args)
  (dolist (arg args) (scan-form arg)))

(defmethod scan-operator ((op (eql 'make-scratch-matrix)) args)
  "Scans make-scratch-matrix and registers the implicit tensor (N=2) arg."
  (%register-scratch-tensor-implicit op args)
  (dolist (arg args) (scan-form arg)))

(defmethod scan-operator ((op (eql 'make-scratch-tensor)) args)
  "Scans make-scratch-tensor and registers the implicit tensor (N from args) arg."
  (%register-scratch-tensor-implicit op args)
  (dolist (arg args) (scan-form arg)))


;;; =========================================================
;;; Pass 2 Analysis
;;; =========================================================
;;
;; Appended to: src/analysis/structs.lisp

(defun analyze-scratch-tensor-expression (expr env context location)
  "Analyzes a (make-scratch-{vector,matrix,tensor} ...) expression.
   Marks the current function as a side-channel originator in both analysis
   modes, validates the type, and returns a semantic-literal node whose
   value-type is the canonical (tensor ...) spec.

   The sizeExpression and keyword args are stored for metadata/hoisting use
   but are not needed for IR generation."
  (declare (ignore env))
  (let* ((op (first expr))
         (args (rest expr)))

    (unless args
      (error "Malformed ~a form: expected at least a type argument." op))

    ;; Resolve to canonical spec — validates syntax and fills defaults.
    (let ((canonical-spec (%scratch-tensor-canonical-spec op args)))
      (unless canonical-spec
        (error "Could not resolve type spec for ~a form: ~a" op expr))

      ;; Originator detection: register in *implicit-arg-map* if not already there.
      ;; (In two-pass mode this mirrors what Pass 1 did; in single-pass mode this
      ;;  is the authoritative registration.)
      ;; Store the MANGLED SYMBOL (not canonical list) so mangle-type-spec works on it.
      (let* ((fn-name (compiler-context-current-compiling-function context))
             (implicit-name (or (compiler-context-current-binding-name context) '__storage))
             (existing (gethash fn-name *implicit-arg-map*))
             (mangled-type (handler-case (parse-type-specifier canonical-spec)
                             (error () canonical-spec))))
        (if existing
            (log:warn "Structs: implicit-arg-map already has entries for ~a: ~a (adding ~a)"
                      fn-name existing implicit-name)
            (progn
             (log:warn "Structs: Detected ~a in ~a (implicit name: ~a, type: ~a, mangled: ~a)"
                       op fn-name implicit-name canonical-spec mangled-type)
             (setf (gethash fn-name *implicit-arg-map*)
               (list (cons implicit-name mangled-type))))))

      ;; Ensure the template is instantiated.
      (unless (valid-parameterized-type-p canonical-spec)
        (error "Failed to instantiate template for ~a (from ~a)" canonical-spec expr))

      (log:debug "analyze-scratch-tensor-expression: ~a -> ~a" op canonical-spec)

      (make-semantic-literal :value-type canonical-spec
                             :value nil
                             :source-location location))))


;; Re-register all expression analyzers including the three new scratch forms.
;; src/analysis/structs.lisp — register-struct-analyzers

(defun register-struct-analyzers ()
  "Registers all struct/storage-handle expression analyzers.
   Redefines the original to add make-scratch-{vector,matrix,tensor}."
  (def-expression-analyzer %construct-struct analyze-struct-construction)
  (def-expression-analyzer %extract-struct-member analyze-extract-struct-member-expression)
  (def-expression-analyzer %insert-struct-member analyze-insert-struct-member-expression)
  (def-expression-analyzer make-scratch-cell analyze-scratch-expression)
  (def-expression-analyzer make-scratch-vector analyze-scratch-tensor-expression)
  (def-expression-analyzer make-scratch-matrix analyze-scratch-tensor-expression)
  (def-expression-analyzer make-scratch-tensor analyze-scratch-tensor-expression)
  (def-expression-analyzer %make-ct-array analyze-%make-ct-array)

  (def-expression-analyzer aref analyze-aref-expression)
  (def-expression-analyzer ~ref~ analyze-aref-expression)
  (def-expression-analyzer ~ analyze-aref-expression)

  (def-expression-analyzer set! analyze-set!-expression))


;;; =========================================================
;;; Pass 2 Codegen
;;; =========================================================
;;
;; Appended to: src/codegen.lisp

(defun %generate-tensor-scratch-literal-ir (builder module var-env type-spec value)
  "Generates IR for a scratch tensor/vector/matrix literal.

   Unlike scratch cells, scratch tensors use Option B (full SROA): the host
   passes every field of the tensor record individually (ptr, bytesize, each
   offset, stride, extent, and length).  The SROA/reconstruction machinery
   in internal-compile-function therefore delivers a fully-assembled tensor
   record value into var-env under the unique implicit-arg name.

   All we need to do here is:
     1. Reconstruct the deterministic unique name (same counter + ordering as Pass 1).
     2. Look up the tensor alloca in var-env.
     3. Load and return the tensor value."
  (declare (ignore value))
  (let* ((context *compiler-context*)
         (binding-name (or (compiler-context-current-binding-name context) '__storage))
         (fn-name (and context (compiler-context-current-compiling-function context)))
         (counter (incf *scratch-cell-counter*))
         (unique-name-str (format nil "~a_FROM_~a_~d" binding-name fn-name counter))
         (unique-name (intern unique-name-str (symbol-package binding-name)))
         (tensor-alloca (gethash unique-name var-env)))

    (log:info "Pass 2: scratch tensor ~a -> implicit: ~a (found? ~a)"
              binding-name unique-name (not (null tensor-alloca)))

    (unless tensor-alloca
      (error "Missing implicit argument ~a for ~a. var-env keys: ~s"
             unique-name type-spec (alexandria:hash-table-keys var-env)))

    ;; The alloca holds the fully-assembled tensor record (all fields provided
    ;; by the host via SROA expansion).  Load and return the value.
    (let* ((mangled-name (mangle-template-struct-name (first type-spec) (rest type-spec)))
           (tensor-struct-type (ensure-struct-llvm-type mangled-name))
           (tensor-val (llvm-build-load2 builder tensor-struct-type tensor-alloca "scratch_tensor_val")))
      tensor-val)))


;; Redefine generate-node-ir for semantic-literal to dispatch tensor scratch
;; forms to the new helper.
;;
;; src/codegen.lisp — generate-node-ir (semantic-literal)

(defmethod generate-node-ir ((node semantic-literal) builder module var-env
                             di-builder di-scope location-map)
  "Generates IR for a literal value.
   Extended to handle scratch tensor/vector/matrix literals."
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

                ;; Cell literals (scratch cell)
                ((eq base-type 'cell)
                  (%generate-cell-literal-ir builder module var-env type-spec value))

                ;; Tensor/vector/matrix scratch literals
                ((string-equal (symbol-name base-type) "TENSOR")
                  (%generate-tensor-scratch-literal-ir builder module var-env type-spec value))

                (t
                  (error "Codegen not implemented for literal of type ~a" type-spec)))))

           ;; Simple or singleton types
           ((or (symbolp type-spec)
                (and (consp type-spec) (member (first type-spec) '(keyword symbol quote))))
             (let ((type-sym (if (consp type-spec) (first type-spec) type-spec)))
               (cond
                ;; Enums
                ((or (gethash type-spec *crisp-enums*)
                     (member type-sym '(keyword symbol quote)))
                  (%generate-enum-literal-ir builder value llvm-type))
                ;; Scalars (int/float/etc.)
                (t
                  (let ((crisp-type (gethash type-sym *crisp-types*)))
                    (unless crisp-type
                      (error "Codegen: Literal type ~a not found in *crisp-types* or *crisp-enums*"
                             type-spec))
                    (%generate-scalar-literal-ir builder value llvm-type crisp-type))))))

           (t
             (error "Codegen not implemented for literal of type ~a" type-spec))))

         (di-location
          (when (and di-builder di-scope location-map)
                (let* ((loc (semantic-node-source-location node))
                       (line (gethash loc location-map 0)))
                  (llvm-di-builder-create-debug-location
                   (llvm-get-module-context module) line 0 di-scope (cffi:null-pointer))))))
    (values result di-location)))


;;; =========================================================
;;; resolve-type-to-llvm — normalize VECTOR/MATRIX before dispatch
;;; =========================================================
;;
;; Appended to: src/types/validation.lisp
;;
;; Two paths cause "Cannot resolve type to LLVM: VECTOR":
;;
;;   Path A — Type Alias branch:
;;     (def-type local-float-vec (vector float ...))
;;     resolve-type-to-llvm local-float-vec
;;       → type alias branch: resolve-type-to-llvm (vector float ...)
;;         → Generic List Wrapper: resolve-type-to-llvm VECTOR → ERROR
;;
;;   Path B — direct (vector ...) cons input:
;;     Any caller that passes a raw (vector ...) spec.
;;
;; Root cause: VECTOR and MATRIX are not registered templates in
;; *template-registry*; they are sugar for (tensor T N).
;; resolve-type-to-llvm's "Parameterized Structs" branch uses
;; (find-template-robust (first type-spec)) which returns NIL for
;; VECTOR/MATRIX, so it falls through to the "Generic List Wrapper"
;; which strips to the bare symbol VECTOR/MATRIX and errors.
;;
;; Fix: (1) Add an early normalizer at the top of resolve-type-to-llvm
;;     that converts VECTOR/MATRIX cons forms to TENSOR via
;;     expand-storage-handle-type-specifier before the main dispatch.
;; (2) In the Type Alias branch, canonicalize the alias value so that
;;     aliases storing (vector ...) are normalized before recursion.

(defun resolve-type-to-llvm (type-spec)
  "Resolves a Crisp type specifier to an LLVM type reference.
   Extended to handle (array T N) → LLVM [N x T_llvm].
   Extended to normalize VECTOR/MATRIX sugar to TENSOR before dispatch,
   and to canonicalize type alias values before recursing."
  (cl:let ((*resolve-depth* (1+ *resolve-depth*)))
    (cl:when (> *resolve-depth* 50)
      (cl:error "Infinite recursion detected in resolve-type-to-llvm for ~s" type-spec))

    ;; ── Early-out: VECTOR/MATRIX sugar → TENSOR ──────────────────────────────
    ;; VECTOR and MATRIX are not in *template-registry*, so the normal
    ;; "Parameterized Structs" branch cannot handle them.  Expand to TENSOR first
    ;; so the rest of the dispatch sees a canonical (tensor ...) form.
    (cl:when (cl:and (cl:consp type-spec)
                     (cl:symbolp (cl:first type-spec))
                     (cl:member (cl:symbol-name (cl:first type-spec))
                                '("VECTOR" "MATRIX") :test #'cl:string-equal))
      (log:info "resolve-type-to-llvm: expanding ~a sugar to TENSOR" (cl:first type-spec))
      (cl:return-from resolve-type-to-llvm
        (resolve-type-to-llvm (expand-storage-handle-type-specifier type-spec))))

    (cl:cond
      ;; (array T N) → [N x T_llvm]
      ((%array-type-p type-spec)
       (cl:let* ((elem-type (cl:second type-spec))
                 (count-raw (cl:third type-spec))
                 (count (etypecase count-raw
                          (integer count-raw)
                          (symbol  (parse-integer (symbol-name count-raw))))))
         (log:info "resolve-type-to-llvm: (array ~a ~a) -> [~a x ...]" elem-type count count)
         (crisp.llvm-bindings::llvm-array-type (resolve-type-to-llvm elem-type) count)))

      ;; Derived Type - resolve to base type (MUST come before *crisp-types* check)
      ((cl:and (cl:symbolp type-spec)
         (cl:let* ((node-direct (cl:gethash type-spec *type-derivation-graph*))
                   (node-alt (cl:when (not node-direct)
                               (cl:gethash (cl:intern (cl:symbol-name type-spec)
                                                      (cl:find-package :crisp-language))
                                           *type-derivation-graph*)))
                   (node (or node-direct node-alt)))
           (and node (type-node-original-type node))))
       (cl:let* ((node-direct (cl:gethash type-spec *type-derivation-graph*))
                 (node-alt (cl:when (not node-direct)
                             (cl:gethash (cl:intern (cl:symbol-name type-spec)
                                                    (cl:find-package :crisp-language))
                                         *type-derivation-graph*)))
                 (actual-type (if node-direct type-spec
                                  (cl:intern (cl:symbol-name type-spec)
                                             (cl:find-package :crisp-language))))
                 (base-type (get-type-base actual-type)))
         (resolve-type-to-llvm base-type)))

      ;; Built-in Scalar
      ((cl:and (cl:symbolp type-spec) (cl:gethash type-spec *crisp-types*))
       (cl:funcall (crisp-type-llvm-type-fn (cl:gethash type-spec *crisp-types*))))

      ;; Type Alias (Symbol) — canonicalize alias value before recursing so that
      ;; aliases pointing to (vector ...) / (matrix ...) are normalized to TENSOR.
      ((cl:and (cl:symbolp type-spec) (cl:gethash type-spec *crisp-type-aliases*))
       (resolve-type-to-llvm
        (canonicalize-type-specifier (cl:gethash type-spec *crisp-type-aliases*))))

      ;; C-Pointer with properties: e.g. (c-pointer :address-space :global)
      ((cl:and (cl:consp type-spec) (cl:eq (cl:first type-spec) 'c-pointer))
       (cl:let* ((args (cl:rest type-spec))
                 (as-key (cl:getf args :address-space))
                 (as-val (encode-address-space as-key)))
         (llvm-pointer-type (llvm-int8-type) as-val)))

      ;; Struct (Pre-existing)
      ((cl:and (cl:symbolp type-spec) (find-struct-definition-by-name type-spec))
       (ensure-struct-llvm-type type-spec))

      ;; Enumerations (map to i32)
      ((cl:and (cl:symbolp type-spec) (cl:gethash type-spec *crisp-enums*))
       (llvm-int32-type))

      ;; Keyword/Symbol/Quote (map to i32)
      ((cl:or (cl:member type-spec '(keyword symbol quote))
         (cl:and (cl:consp type-spec) (cl:member (cl:first type-spec) '(keyword symbol quote))))
       (llvm-int32-type))

      ;; Parameterized Structs (On-Demand Instantiation) OR Mangled Symbols
      ((cl:or (cl:and (cl:consp type-spec)
                (valid-type-p type-spec)
                (find-template-robust (cl:first type-spec)))
         (cl:and (cl:symbolp type-spec)
           (cl:let ((parts (unmangle-template-struct-name type-spec)))
             (cl:and parts (cl:consp parts) (find-template-robust (cl:first parts))))))
       (cl:let* ((canonical (canonicalize-type-specifier type-spec))
                 (is-cons (cl:consp canonical))
                 (unmangled (cl:if is-cons canonical (unmangle-template-struct-name canonical)))
                 (base (cl:first unmangled))
                 (raw-args (cl:rest unmangled))
                 (mangled (mangle-template-struct-name base raw-args)))
         (cl:unless (find-struct-definition-by-name mangled)
           (cl:let ((crisp.compiler::*defer-struct-validation* nil))
             (ensure-template-instantiation base raw-args
                                            (cl:lambda (form location)
                                              (cl:eval form)
                                              (cl:when (cl:and (boundp '*current-module*) *current-module*)
                                                (compile-toplevel-form form location
                                                                       *current-module*
                                                                       *current-builder*
                                                                       *current-di-builder*
                                                                       *current-di-compile-unit*
                                                                       *current-location-map*))))))
         (cl:unless (find-struct-definition-by-name mangled)
           (cl:error "Type Resolution: FAILED to instantiate struct ~a" mangled))
         (resolve-type-to-llvm mangled)))

      ;; Generic List Wrapper
      ((cl:consp type-spec)
       (resolve-type-to-llvm (cl:first type-spec)))

      (t
       (cl:let ((alias-match (cl:loop for k being the hash-keys of *crisp-type-aliases*
                               when (cl:string-equal (cl:symbol-name k) (cl:symbol-name type-spec))
                               return k)))
         (cl:if alias-match
                ;; Canonicalize before recursing (same fix as Type Alias branch above)
                (resolve-type-to-llvm
                 (canonicalize-type-specifier (cl:gethash alias-match *crisp-type-aliases*)))
                (cl:error "Cannot resolve type to LLVM: ~a" type-spec)))))))


;;; =========================================================
;;; Fix 1: mangle-type-spec — handle integer arity in canonical tensor list
;;; =========================================================
;;
;; Appended to: src/mangling.lisp
;;
;; (tensor int 1 :local :read-write :compact) contains an integer arity.
;; mangle-type-spec must stringify integers instead of erroring.
;; src/mangling.lisp:155

(cl:defun mangle-type-spec (type-spec)
  "Creates a string representation of a type spec for name mangling.
   Extended to handle integers (e.g. tensor arity N in canonical list form)."
  (log:debug "mangle-type-spec: ~s (type-of: ~a)" type-spec (cl:type-of type-spec))
  (cl:cond
   ((cl:symbolp  type-spec) (cl:string-downcase (cl:symbol-name type-spec)))
   ((cl:integerp type-spec) (cl:format nil "~a" type-spec))
   ((cl:listp    type-spec) (cl:format nil "~{~a~^_~}" (cl:mapcar #'mangle-type-spec type-spec)))
   (cl:t (cl:error "Cannot mangle unknown type specifier: ~a" type-spec))))


;;; =========================================================
;;; Fix 2: *implicit-scratch-size-expr-map* — side table for size expressions
;;; =========================================================
;;
;; Stores the user-supplied sizeExpression for each scratch tensor implicit param.
;; Key: param-name symbol (e.g. SV_FROM_FUN-C_1).  Value: the raw size-expr form.
;; Kept separate from *implicit-arg-map* to avoid touching analyze-function-call.

(defvar *implicit-scratch-size-expr-map* (make-hash-table)
  "Maps implicit scratch tensor param-name → size-expr form as written by the user
   (e.g. :match-warp-tile, 1, 4).  Used by generate-implicit-signature for metadata.")


;;; =========================================================
;;; Fix 3: wrap-initialize-compiler — clear the new side table
;;; =========================================================
;;
;; Rather than redefining initialize-compiler (which has a complex body
;; already maintained in src/compiler.lisp), we wrap it via an :around
;; method approach — impossible for plain defun.  Instead, store the
;; original function and install a wrapper.
;;
;; We define a helper that register-builtins calls, hooking into the
;; existing flow without duplicating the full initialize-compiler body.
;;
;; The simplest correct approach: redefine initialize-compiler with the
;; FULL correct signature and body, including the new map clear.
;; src/compiler.lisp:449

(defun initialize-compiler (&key (log-level :off) (runtime-checks nil) (differentiate nil))
  "Initializes the compiler state.
   Extended to also clear *implicit-scratch-size-expr-map* for scratch tensor support."
  (setf *runtime-checks-enabled* runtime-checks)
  (setf *differentiate-p* differentiate)
  (cffi:use-foreign-library crisp.llvm-bindings::libllvm)

  (if (eq log-level :off)
      (log:config :off)
      (log:config :sane :stream *error-output* log-level))

  (initialize-crisp-types)
  (initialize-crisp-types)
  (initialize-type-hierarchy)
  (clrhash *function-table*)
  (clrhash *crisp-structs*)
  (clrhash *crisp-type-aliases*)
  (clrhash *crisp-template-aliases*)
  (clrhash *generic-functions*)
  (clrhash *kernel-declared-signatures*)
  (when (boundp '*record-definitions*) (clrhash *record-definitions*))

  (setf *compiled-kernels* nil)

  (clrhash *differentiable-functions*)
  (clrhash *differentiable-hof-store*)

  (initialize-expression-analyzers)
  (clrhash *implicit-arg-map*)
  (initialize-advisements)

  (setf (gethash 'die *function-table*)
        (list (make-function-signature :name 'die :parameters nil :return-types '(nil))))

  (setf (symbol-function 'truncate) #'cl:truncate)
  (setf (symbol-function 'floor) #'cl:floor)
  (setf (symbol-function 'ceil) #'cl:ceiling)
  (setf (symbol-function 'round) #'cl:round)

  (if (fboundp 'initialize-templates)
      (funcall 'initialize-templates)
      (log:warn "Template system not loaded/initialized."))

  (when (boundp '*brand-definitions*) (clrhash *brand-definitions*))
  (when (boundp '*brand-instance-cache*) (clrhash *brand-instance-cache*))
  (when (boundp '*brand-instance-types*) (clrhash *brand-instance-types*))

  (when (boundp '*partial-template-instantiations*)
        (loop for template-name being the hash-keys of *partial-template-instantiations*
              do (let ((dispatch-sym (intern (format nil "MAKE-~a%DISPATCH" template-name)
                                             (symbol-package template-name))))
                   (when (macro-function dispatch-sym)
                         (fmakunbound dispatch-sym))))
        (clrhash *partial-template-instantiations*))

  (when (boundp '*struct-mutating-functions*)
        (clrhash *struct-mutating-functions*))

  ;; NEW: clear scratch tensor size-expr side table
  (clrhash *implicit-scratch-size-expr-map*)

  (register-builtins)

  (log:info "Compiler initialized. differentiate=~a" differentiate))


;;; =========================================================
;;; Fix 4: %extract-scratch-size-expr — pull sizeExpression from args
;;; =========================================================
;;
;; Returns the raw size-expr form as the user wrote it.
;; For make-scratch-vector/matrix: size-expr = second positional arg.
;; For make-scratch-tensor form 1 (elem N size-expr): size-expr = third arg.
;; For make-scratch-tensor form 2 (alias size-expr):  size-expr = second arg.

(defun %extract-scratch-size-expr (op args)
  "Extracts the user-supplied size expression from make-scratch-* args."
  (case op
    ((make-scratch-vector make-scratch-matrix)
     ;; (make-scratch-vector elem-or-alias size-expr &key ...)
     (second args))
    (make-scratch-tensor
     (let* ((arg1 (first args))
            (arg2 (second args))
            ;; Form 1 if arg2 is an integer and arg1 is not a tensor alias
            (is-tensor-alias (and (symbolp arg1)
                                  (let ((resolved (resolve-type-alias arg1)))
                                    (and (consp resolved)
                                         (member (symbol-name (first resolved))
                                                 '("TENSOR" "VECTOR" "MATRIX")
                                                 :test #'string-equal)))))
            (form-1-p (and (integerp arg2) (not is-tensor-alias))))
       (if form-1-p
           (third args)    ; (make-scratch-tensor elem N size-expr ...)
           (second args)))) ; (make-scratch-tensor alias size-expr ...)
    (t nil)))


;;; =========================================================
;;; Fix 5: %register-scratch-tensor-implicit — store canonical list + size-expr
;;; =========================================================
;;
;; Appended to: src/analysis/structs.lisp
;;
;; CHANGED: stores canonical LIST (not mangled symbol) in *implicit-arg-map*.
;; This makes %storage-handle-type-p recognize it as a tensor, enabling correct
;; physical-signature explosion and correct :type in metadata.
;; Also stores the size-expr in *implicit-scratch-size-expr-map*.

(defun %register-scratch-tensor-implicit (op args)
  "Shared logic for scan-operator methods on make-scratch-{vector,matrix,tensor}.
   Marks the current function as an originator and records the canonical-list type
   in *implicit-arg-map* and the size-expr in *implicit-scratch-size-expr-map*."
  (setf *scan-is-originator* t)
  (when args
    (let ((canonical-spec (%scratch-tensor-canonical-spec op args)))
      (when canonical-spec
        (let* ((binding-name (or (compiler-context-current-binding-name *compiler-context*)
                                 '__storage))
               (fn-name (compiler-context-scanning-function-name *compiler-context*))
               (counter (incf *scratch-cell-counter*))
               (unique-name-str (format nil "~a_FROM_~a_~d" binding-name fn-name counter))
               (unique-name (intern unique-name-str (symbol-package binding-name)))
               (size-expr (%extract-scratch-size-expr op args)))

          (log:info "Pass 1: ~a ~a -> implicit: ~a (type: ~a, size-expr: ~a)"
                    op binding-name unique-name canonical-spec size-expr)

          (push (cons unique-name canonical-spec) (gethash fn-name *implicit-arg-map*))
          (when size-expr
            (setf (gethash unique-name *implicit-scratch-size-expr-map*) size-expr)))))))


;;; =========================================================
;;; Fix 6: analyze-scratch-tensor-expression — store canonical list + size-expr
;;; =========================================================
;;
;; Appended to: src/analysis/structs.lisp
;;
;; CHANGED: stores canonical LIST (not mangled symbol) for the same reasons as Fix 5.

(defun analyze-scratch-tensor-expression (expr env context location)
  "Analyzes a (make-scratch-{vector,matrix,tensor} ...) expression.
   Stores canonical-list type in *implicit-arg-map* and size-expr in
   *implicit-scratch-size-expr-map*."
  (declare (ignore env))
  (let* ((op (first expr))
         (args (rest expr)))

    (unless args
      (error "Malformed ~a form: expected at least a type argument." op))

    (let ((canonical-spec (%scratch-tensor-canonical-spec op args)))
      (unless canonical-spec
        (error "Could not resolve type spec for ~a form: ~a" op expr))

      ;; Register in *implicit-arg-map* if not already there (single-pass or two-pass pass 2).
      (let* ((fn-name (compiler-context-current-compiling-function context))
             (implicit-name (or (compiler-context-current-binding-name context) '__storage))
             (existing (gethash fn-name *implicit-arg-map*))
             (size-expr (%extract-scratch-size-expr op args)))
        (if existing
            (log:warn "Structs: implicit-arg-map already has entries for ~a: ~a (adding ~a)"
                      fn-name existing implicit-name)
            (progn
              (log:warn "Structs: Detected ~a in ~a (implicit name: ~a, type: ~a, size-expr: ~a)"
                        op fn-name implicit-name canonical-spec size-expr)
              (setf (gethash fn-name *implicit-arg-map*)
                    (list (cons implicit-name canonical-spec)))
              (when size-expr
                (setf (gethash implicit-name *implicit-scratch-size-expr-map*) size-expr)))))

      (unless (valid-parameterized-type-p canonical-spec)
        (error "Failed to instantiate template for ~a (from ~a)" canonical-spec expr))

      (log:debug "analyze-scratch-tensor-expression: ~a -> ~a" op canonical-spec)

      (make-semantic-literal :value-type canonical-spec
                             :value nil
                             :source-location location))))


;;; =========================================================
;;; Fix 7: generate-implicit-signature — TENSOR addr-space/access + :size-expr
;;; =========================================================
;;
;; Appended to: src/metadata.lisp
;;
;; Extended to:
;;   - Extract :address-space and :access from TENSOR canonical lists
;;     (the original code only handled CELL).
;;   - Include :size-expr in the output entry, looked up from
;;     *implicit-scratch-size-expr-map*.

(defun generate-implicit-signature (sig declared-params)
  "Generates the :implicit-params plist for metadata serialization.
   Handles CELL canonical lists (positional addr-space/access) and
   TENSOR canonical lists (keyword addr-space/access), and includes
   :size-expr from *implicit-scratch-size-expr-map*."
  (declare (ignore declared-params))
  (let ((implicit-args nil)
        (phys-index 0)
        (implicit-params (function-signature-implicit-parameters sig)))

    (dolist (param-def implicit-params)
      (let* ((name (parameter-def-name param-def))
             (type (parameter-def-type param-def))
             (width (get-physical-width type))
             (start phys-index)
             (end (+ phys-index width -1))
             (type-head (when (consp type) (symbol-name (first type))))
             ;; Extract address-space: CELL uses positional (nth 2), TENSOR uses keyword
             (address-space
              (cond
                ((and (consp type) (string-equal type-head "CELL") (>= (length type) 3))
                 (nth 2 type))
                ((and (consp type) (member type-head '("TENSOR" "VECTOR" "MATRIX")
                                           :test #'string-equal))
                 (or (second (member :address-space type)) :local))
                (t :local)))
             ;; Extract access: CELL uses positional (nth 3), TENSOR uses keyword
             (access
              (cond
                ((and (consp type) (string-equal type-head "CELL") (>= (length type) 4))
                 (nth 3 type))
                ((and (consp type) (member type-head '("TENSOR" "VECTOR" "MATRIX")
                                           :test #'string-equal))
                 (or (second (member :access type)) :read-write))
                (t :read-write)))
             ;; Look up size-expr from side table (nil for non-tensor implicit params)
             (size-expr (gethash name *implicit-scratch-size-expr-map*)))
        (let ((entry (list :name (string-downcase (symbol-name name))
                           :type (strip-package-qualifiers type)
                           :size-expr size-expr
                           :address-space address-space
                           :access access
                           :range (list start end))))
          (push entry implicit-args))
        (incf phys-index width)))
    (nreverse implicit-args)))


;;; =========================================================
;;; Fix: %try-inline-struct-array-field-ptr — handle canonical list types
;;; =========================================================
;;
;; Appended to: src/codegen.lisp
;;
;; The `%try-inline-struct-array-field-ptr` function checks `(symbolp struct-type-sym)`
;; to determine if it can bypass the accessor function call with a direct GEP.
;; This check fails when the argument type is a canonical tensor list
;; `(tensor int 2 :local :read-write :compact)` instead of the mangled symbol
;; `TENSOR_INT_2_LOCAL_READ-WRITE_COMPACT`.
;;
;; This happens for scratch tensors created via make-scratch-matrix/vector/tensor —
;; their binding type is the canonical list (not the mangled symbol). As a result,
;; `extents~(mat)` falls through to a function call that is only DECLARED but never
;; DEFINED in the module, causing ZE_RESULT_ERROR_INVALID_MODULE_UNLINKED.
;;
;; Fix: before the (symbolp struct-type-sym) check, resolve canonical TENSOR/VECTOR/MATRIX
;; list types to their mangled symbol form.

(defun %try-inline-struct-array-field-ptr
    (array-node builder module var-env di-builder di-scope location-map)
  "Bypass for array-returning struct field accessors (e.g. extents~, strides~).
   Extended to resolve canonical tensor list types to mangled symbols so that
   scratch tensors (with list type) get the same GEP treatment as named tensors.

   Returns a GEP pointer to the array field, or NIL if the pattern is not matched."
  (when (and (semantic-call-p array-node)
             (= (cl:length (semantic-call-args array-node)) 1))
    (let* ((call-type (semantic-call-type array-node))
           (raw-type  (if (and (listp call-type)
                               (= (cl:length call-type) 1)
                               (listp (cl:first call-type)))
                          (cl:first call-type)
                          call-type)))
      (when (%array-type-p (resolve-type-alias raw-type))
        (let* ((call-name    (semantic-call-name array-node))
               (name-str     (symbol-name call-name)))
          (when (and (> (cl:length name-str) 1)
                     (cl:char= (cl:char name-str (1- (cl:length name-str))) #\~))
            (let* ((field-name-str  (subseq name-str 0 (1- (cl:length name-str))))
                   (arg-node        (cl:first (semantic-call-args array-node)))
                   (raw-type-sym    (semantic-node-type arg-node))
                   ;; NEW: resolve canonical TENSOR/VECTOR/MATRIX list to mangled symbol
                   (struct-type-sym
                    (if (and (consp raw-type-sym)
                             (symbolp (cl:first raw-type-sym))
                             (member (symbol-name (cl:first raw-type-sym))
                                     '("TENSOR" "VECTOR" "MATRIX") :test #'string-equal))
                        (intern (mangle-template-struct-name
                                 (cl:first raw-type-sym) (cl:rest raw-type-sym))
                                (symbol-package (cl:first raw-type-sym)))
                        raw-type-sym))
                   (struct-def      (when (symbolp struct-type-sym)
                                      (lookup-struct-definition struct-type-sym))))
              (when struct-def
                (let ((physical-index (%lookup-field-physical-index struct-def field-name-str)))
                  (when physical-index
                    (log:info "028-fix: inlining struct accessor ~a (field '~a' idx=~a) to avoid array-returning fn"
                              call-name field-name-str physical-index)
                    (let* ((struct-llvm-type (ensure-struct-llvm-type struct-type-sym))
                           (struct-ptr
                             (if (semantic-var-read-p arg-node)
                                 (let ((alloca (gethash (semantic-var-read-name arg-node) var-env)))
                                   (log:info "028-fix: using alloca for var ~a" (semantic-var-read-name arg-node))
                                   alloca)
                                 (multiple-value-bind (sv _loc global-ptr)
                                     (generate-node-ir arg-node builder module var-env
                                                       di-builder di-scope location-map)
                                   (declare (ignore _loc))
                                   (if (and global-ptr (not (cffi:null-pointer-p global-ptr)))
                                       (progn
                                         (log:info "029-fix: cell-of-struct accessor: using global ptr directly")
                                         global-ptr)
                                       (let ((spill (llvm-build-alloca builder struct-llvm-type "struct_spill")))
                                         (log:info "028-fix: spilling struct value to local alloca")
                                         (llvm-build-store builder sv spill)
                                         spill))))))
                      (cffi:with-foreign-object (gep-indices :pointer 2)
                        (setf (cffi:mem-aref gep-indices :pointer 0)
                              (llvm-const-int (llvm-int32-type) 0 nil))
                        (setf (cffi:mem-aref gep-indices :pointer 1)
                              (llvm-const-int (llvm-int32-type) physical-index nil))
                        (llvm-build-in-bounds-gep2
                         builder struct-llvm-type struct-ptr gep-indices 2 "arr_field_ptr")))))))))))))

;;; Fix (v2): %try-inline-struct-array-field-ptr — also resolve type aliases
;;;
;; Appended to: src/codegen.lisp
;;
;; The prior fix (above) resolved canonical TENSOR/VECTOR/MATRIX list types.
;; But when a scratch tensor parameter has a def-type alias (e.g. sc-int-mat),
;; semantic-node-type returns the alias symbol (SC-INT-MAT), not the canonical list.
;; We must resolve the alias and expand the storage-handle spec to get the
;; canonical (tensor ...) form before mangling.
;;
;; Fix: call resolve-type-alias + expand-storage-handle-type-specifier on
;; raw-type-sym before deciding whether to mangle.

(defun %try-inline-struct-array-field-ptr
    (array-node builder module var-env di-builder di-scope location-map)
  "Bypass for array-returning struct field accessors (e.g. extents~, strides~).
   Resolves type aliases and canonical list types to mangled symbols so that
   scratch tensors (with def-type alias or with list type) get the same GEP
   treatment as named tensors.

   Returns a GEP pointer to the array field, or NIL if the pattern is not matched."
  (when (and (semantic-call-p array-node)
             (= (cl:length (semantic-call-args array-node)) 1))
    (let* ((call-type (semantic-call-type array-node))
           (raw-type  (if (and (listp call-type)
                               (= (cl:length call-type) 1)
                               (listp (cl:first call-type)))
                          (cl:first call-type)
                          call-type)))
      (when (%array-type-p (resolve-type-alias raw-type))
        (let* ((call-name    (semantic-call-name array-node))
               (name-str     (symbol-name call-name)))
          (when (and (> (cl:length name-str) 1)
                     (cl:char= (cl:char name-str (1- (cl:length name-str))) #\~))
            (let* ((field-name-str  (subseq name-str 0 (1- (cl:length name-str))))
                   (arg-node        (cl:first (semantic-call-args array-node)))
                   (raw-type-sym    (semantic-node-type arg-node))
                   ;; NEW v2: resolve alias then expand storage handle spec,
                   ;; then mangle if it's a tensor/vector/matrix family.
                   (struct-type-sym
                    (cl:let* (;; 1. Resolve type alias (e.g. SC-INT-MAT -> (matrix int ...))
                              (resolved-alias (resolve-type-alias raw-type-sym))
                              ;; 2. Expand storage handle (e.g. (matrix ...) -> (tensor ... 2 ...))
                              (expanded (if (consp resolved-alias)
                                            (expand-storage-handle-type-specifier resolved-alias)
                                            resolved-alias))
                              ;; 3. Check for tensor-family canonical head
                              (head (when (consp expanded) (cl:first expanded))))
                      (if (and head
                               (symbolp head)
                               (cl:member (symbol-name head)
                                          '("TENSOR" "VECTOR" "MATRIX") :test #'string-equal))
                          ;; Mangle to symbol (result interned in same pkg as head)
                          (mangle-template-struct-name head (cl:rest expanded))
                          ;; Otherwise keep original (already-mangled symbol or non-tensor type)
                          raw-type-sym)))
                   (struct-def      (when (symbolp struct-type-sym)
                                      (lookup-struct-definition struct-type-sym))))
              (when struct-def
                (let ((physical-index (%lookup-field-physical-index struct-def field-name-str)))
                  (when physical-index
                    (log:info "028-fix v2: inlining struct accessor ~a (field '~a' idx=~a, resolved from ~a)"
                              call-name field-name-str physical-index raw-type-sym)
                    (let* ((struct-llvm-type (ensure-struct-llvm-type struct-type-sym))
                           (struct-ptr
                             (if (semantic-var-read-p arg-node)
                                 (let ((alloca (gethash (semantic-var-read-name arg-node) var-env)))
                                   (log:info "028-fix v2: using alloca for var ~a" (semantic-var-read-name arg-node))
                                   alloca)
                                 (multiple-value-bind (sv _loc global-ptr)
                                     (generate-node-ir arg-node builder module var-env
                                                       di-builder di-scope location-map)
                                   (declare (ignore _loc))
                                   (if (and global-ptr (not (cffi:null-pointer-p global-ptr)))
                                       (progn
                                         (log:info "029-fix v2: cell-of-struct accessor: using global ptr directly")
                                         global-ptr)
                                       (let ((spill (llvm-build-alloca builder struct-llvm-type "struct_spill")))
                                         (log:info "028-fix v2: spilling struct value to local alloca")
                                         (llvm-build-store builder sv spill)
                                         spill))))))
                      (cffi:with-foreign-object (gep-indices :pointer 2)
                        (setf (cffi:mem-aref gep-indices :pointer 0)
                              (llvm-const-int (llvm-int32-type) 0 nil))
                        (setf (cffi:mem-aref gep-indices :pointer 1)
                              (llvm-const-int (llvm-int32-type) physical-index nil))
                        (llvm-build-in-bounds-gep2
                         builder struct-llvm-type struct-ptr gep-indices 2 "arr_field_ptr")))))))))))))