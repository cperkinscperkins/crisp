;;; src/analysis/core.lisp
(in-package :crisp.compiler)

(defvar *analysis-access-mode* :read)


(defvar *in-dispatch-context* nil
  "T when the analyzer is inside a def-kernel/def-grid-function body.
   Used to restrict GPU built-in calls to kernel entry points only.")


(defvar *in-grid-level-context* nil
  "T when the analyzer is currently inside a (declare (grid-level)) let/progn scope.
   Grid-level contexts cannot be nested inside each other.")

(defvar *in-workgroup-level-context* nil
  "T when the analyzer is currently inside a (declare (workgroup-level)) let/progn scope.
   Workgroup-level contexts cannot be nested inside each other.")


(defun %dvec-integral-type-p (type-sym)
  "Returns T if TYPE-SYM is a registered integer (signed or unsigned) Crisp type."
  (let ((ct (gethash type-sym *crisp-types*)))
    (and ct (member (crisp-type-category ct) '(:signed-int :unsigned-int)))))

(defun %dvec-float-type-p (type-sym)
  "Returns T if TYPE-SYM is a registered floating-point Crisp type."
  (let ((ct (gethash type-sym *crisp-types*)))
    (and ct (eq (crisp-type-category ct) :float))))

(defun %dvec-infer-comp-type (elem-node location)
  "Returns the component type symbol for a device vector element node.
   Plain int literals -> 'int, plain float literals -> 'float,
   typed literals -> their explicit type.
   Signals crisp-compiler-error for device-vector or unknown types."
  (let ((ty (semantic-node-type elem-node)))
    (cond
      ((eq ty 'int)   'int)
      ((eq ty 'float) 'float)
      ((and (gethash ty *crisp-types*)
            (not (eq (crisp-type-category (gethash ty *crisp-types*)) :device-vector)))
       ty)
      ((eq (crisp-type-category (gethash ty *crisp-types*)) :device-vector)
       (error 'crisp-compiler-error
              :message "##(...) elements cannot themselves be device vectors"
              :source-location location))
      (t
       (error 'crisp-compiler-error
              :message (format nil "##(...) first element has unrecognised type ~a" ty)
              :source-location location)))))

(defun %dvec-element-compatible-p (elem-type comp-type)
  "Returns T if ELEM-TYPE (of a subsequent element) is compatible with COMP-TYPE
   under the first-term coercion rule:
   - Exact match always passes.
   - Plain 'int is coercible to any integral comp-type.
   - Plain 'float is coercible to any float comp-type."
  (or (eq elem-type comp-type)
      (and (eq elem-type 'int)   (%dvec-integral-type-p comp-type))
      (and (eq elem-type 'float) (%dvec-float-type-p    comp-type))))

(defun analyze-crisp-dvec-literal (expr env context location)
  "Analyzes (crisp-vec-literal e1 e2 ...) -- produced by the ##(...) reader macro.
   Infers the component type from the first element, validates width (2-4) and
   element type compatibility, then returns a semantic-device-vec-literal node."
  (let* ((raw-elements (rest expr))
         (width        (length raw-elements)))
    ;; Width check
    (unless (member width '(2 3 4))
      (error 'crisp-compiler-error
             :message (format nil "##(...) must have 2, 3, or 4 elements; got ~a" width)
             :source-location location))
    ;; Analyze all elements
    (let* ((analyzed  (mapcar (lambda (e) (analyze-expression e env context location))
                              raw-elements))
           (comp-type (%dvec-infer-comp-type (first analyzed) location)))
      ;; Validate remaining elements
      (dolist (elem (rest analyzed))
        (let ((et (semantic-node-type elem)))
          (unless (%dvec-element-compatible-p et comp-type)
            (error 'crisp-compiler-error
                   :message (format nil "##(...) has mixed element types: component type is ~a but got ~a"
                                    comp-type et)
                   :source-location location))))
      ;; Look up the NxT type (e.g. float4, int3) in :crisp-language
      (let* ((vec-name (intern (format nil "~a~a" (symbol-name comp-type) width)
                               (find-package :crisp-language)))
             (vec-ct   (gethash vec-name *crisp-types*)))
        (unless vec-ct
          (error 'crisp-compiler-error
                 :message (format nil "##(...) no registered device vector type ~a" vec-name)
                 :source-location location))
        (log:debug "analyze-crisp-dvec-literal: ~a width=~a comp=~a -> ~a"
                   expr width comp-type vec-name)
        (make-semantic-device-vec-literal
         :vec-type     vec-name
         :element-type comp-type
         :width        width
         :elements     analyzed
         :source-location location)))))




;; 110 — warp helper builtins.  Three zero-arg builtins returning uint:
;;   (warp-id)    → SPIR-V SubgroupId
;;   (warp-lane)  → SPIR-V SubgroupLocalInvocationId
;;   (warp-count) → SPIR-V NumSubgroups
;;
;; They register the same analyzer (%analyze-gpu-builtin) used by other GPU
;; builtins; their return-type metadata lives in %gpu-builtin-info (overridden
;; below).  Codegen lives in the %call-spirv-uint-global-builtin helper plus
;; new cases in generate-node-ir for semantic-gpu-builtin.

(defun register-warp-builtins ()
  "Registers the warp-id / warp-lane / warp-count GPU builtins in
   *expression-analyzers* for both :crisp-language and :crisp.compiler."
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry '(("WARP-ID"    :warp-id)
                     ("WARP-LANE"  :warp-lane)
                     ("WARP-COUNT" :warp-count)))
      (let* ((name-str (first entry))
             (kw       (second entry))
             (fn       (let ((kw0 kw) (ns0 name-str))
                         (lambda (expr env context location)
                           (%analyze-gpu-builtin kw0 ns0 expr env context location))))
             (sym-cl (intern name-str cl-pkg))
             (sym-cc (intern name-str cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) fn)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) fn))))))


(defun %gpu-builtin-info (builtin-kw)
  "Returns (base-return-type accepts-dim-p) for a GPU builtin keyword.
   BASE-RETURN-TYPE: return type when called with no args (nil = void).
   ACCEPTS-DIM-P: T if the builtin accepts a scalar dimension arg 0/1/2."
  (case builtin-kw
    ((:get-global-id :get-local-id :get-workgroup-id :get-num-groups
      :get-local-work-size :get-global-work-size :get-global-offset
      :get-global-id-abs)
     (list 'ulong3 t))
    (:get-work-dim          (list 'uint  nil))
    ((:get-local-linear-id :get-local-linear-size
      :get-global-linear-id :get-global-linear-size
      :get-total-threads :get-total-groups)
     (list 'ulong nil))
    ((:sync-workgroup :sync-warp :mem-fence)
     (list nil nil))
    ;; 110 — warp helpers (scalar uint, no dim arg)
    ((:warp-id :warp-lane :warp-count)
     (list 'uint nil))
    (t (error "Unknown GPU builtin: ~a" builtin-kw))))

;;; ----- Analyzer -----

(defun %analyze-gpu-builtin (builtin-kw name-str expr env context location)
  "Analyzer for all GPU built-in function forms."
  (declare (ignore env context))
  (unless *in-dispatch-context*
    (error "GPU built-in '~a' is only valid inside a kernel (dispatch context)" name-str))
  (when (member builtin-kw '(:sync-workgroup :sync-warp :mem-fence))
    (%tlc-check-not-divergent name-str location))
  (let* ((info     (%gpu-builtin-info builtin-kw))
         (base-ty  (first info))
         (acc-dim  (second info))
         (args     (rest expr)))
    (cond
      ((null args)
       (make-semantic-gpu-builtin :builtin-name builtin-kw
                                  :dimension nil
                                  :type base-ty
                                  :source-location location))
      ((= (length args) 1)
       (let ((dim-arg (first args)))
         (unless acc-dim
           (error "GPU built-in '~a' does not accept a dimension argument" name-str))
         (unless (integerp dim-arg)
           (error "GPU built-in '~a': dimension must be a compile-time integer constant (0, 1, or 2), got: ~a"
                  name-str dim-arg))
         (unless (member dim-arg '(0 1 2))
           (error "GPU built-in '~a': dimension ~a is out of valid range (must be 0, 1, or 2)"
                  name-str dim-arg))
         (make-semantic-gpu-builtin :builtin-name builtin-kw
                                    :dimension dim-arg
                                    :type 'ulong
                                    :source-location location)))
      (t
       (error "GPU built-in '~a' takes 0 or 1 arguments, got ~a" name-str (length args))))))



;; ==========================================================================
;; IGC SROA-aliasing workaround (endeavor 103 phase B, 2026-05-16):
;;   %volatile-read pseudo-op
;;
;; Symptom: when the shadow-struct write at the end of a backward kernel reads
;; two (or more) sibling float adjoint allocas (e.g. P_X_ADJ and P_Y_ADJ) into
;; a {float, float} aggregate that is then stored to addrspace(1), Intel/IGC
;; coalesces the allocas — both reads return the value of one of them.  E.g.
;; the canonical 056/01 case wrote {4.0, 4.0} instead of the IR-correct
;; {4.0, 3.0}.  The same LLVM IR translated to PTX (NVPTX backend) produces
;; the correct output, so the IR itself is well-formed — see
;; put_temp_files_here/igc-bug-report/ for the minimal reproducer.
;;
;; Workaround: emit each leaf adjoint read in the shadow-write as
;; `load volatile`, which inhibits SROA promotion of the alloca and avoids
;; the miscompilation.  We do this surgically — only the loads that feed the
;; shadow constructor — not all loads in the backward kernel.
;;
;; Implementation:
;;   1. A new Crisp pseudo-op `%volatile-read` whose analyzer is a no-op on
;;      semantics but records the underlying semantic-var-read in a side
;;      table (*volatile-var-reads*).
;;   2. The var-read codegen consults that side table and, if present,
;;      calls LLVMSetVolatile on the emitted load.
;;   3. %build-shadow-ctor-form wraps each leaf adj-sym in (%volatile-read ...).
;;
;; Remove the wrap (and ideally this whole block) once IGC ships the fix.

(defvar *volatile-var-reads*
  (make-hash-table :test 'eq :weakness :key)
  "Set of semantic-var-read nodes whose load should be emitted as volatile.
   Weak-keyed so entries vanish when the kernel's AST is GC'd.")

(defun analyze-%volatile-read-expression (expr env context location)
  "Analyzes (%volatile-read SYM): produces the same semantic node as a plain
   var-read for SYM, but tags the node in *volatile-var-reads* so codegen
   emits the load as volatile.  IGC SROA-aliasing workaround."
  (let ((inner (analyze-expression (second expr) env context
                                   (append location '(1)))))
    (setf (gethash inner *volatile-var-reads*) t)
    inner))

(defun initialize-expression-analyzers ()
  "Registers all expression analyzers; extended for 087-gpu-builtins.
   Endeavor 103 phase B: adds %volatile-read for the IGC workaround."
  (clrhash *expression-analyzers*)
  (register-ops-analyzers)
  (register-control-analyzers)
  (register-struct-analyzers)
  ;; ##(...) device vector literal
  (setf (gethash 'crisp-vec-literal *expression-analyzers*)
        #'analyze-crisp-dvec-literal)
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    ;; Component accessors x~ / y~ / z~ / w~
    (dolist (name '("X~" "Y~" "Z~" "W~"))
      (let ((sym-cl (intern name cl-pkg))
            (sym-cc (intern name cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) #'analyze-dvec-component-ref)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) #'analyze-dvec-component-ref))))
    ;; 083 matrix helpers: transpose, col, row, transpose!
    (dolist (entry `(("TRANSPOSE"  . ,#'analyze-transpose-expression)
                     ("COL"        . ,#'analyze-col-expression)
                     ("ROW"        . ,#'analyze-row-expression)
                     ("TRANSPOSE!" . ,#'analyze-transpose-bang-expression)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg))
            (fn     (cdr entry)))
        (setf (gethash sym-cl *expression-analyzers*) fn)
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) fn))))
    ;; 087 GPU built-in functions
    (dolist (entry '(("GET-GLOBAL-ID"          :get-global-id)
                     ("GET-LOCAL-ID"            :get-local-id)
                     ("GET-WORKGROUP-ID"        :get-workgroup-id)
                     ("GET-NUM-GROUPS"          :get-num-groups)
                     ("GET-LOCAL-WORK-SIZE"     :get-local-work-size)
                     ("GET-GLOBAL-WORK-SIZE"    :get-global-work-size)
                     ("GET-GLOBAL-OFFSET"       :get-global-offset)
                     ("GET-GLOBAL-ID-ABS"       :get-global-id-abs)
                     ("GET-WORK-DIM"            :get-work-dim)
                     ("GET-LOCAL-LINEAR-ID"     :get-local-linear-id)
                     ("GET-LOCAL-LINEAR-SIZE"   :get-local-linear-size)
                     ("GET-GLOBAL-LINEAR-ID"    :get-global-linear-id)
                     ("GET-GLOBAL-LINEAR-SIZE"  :get-global-linear-size)
                     ("GET-TOTAL-THREADS"       :get-total-threads)
                     ("GET-TOTAL-GROUPS"        :get-total-groups)
                     ("SYNC-WORKGROUP"          :sync-workgroup)
                     ("SYNC-WARP"               :sync-warp)
                     ("MEM-FENCE"               :mem-fence)))
      (let* ((name-str (first entry))
             (kw       (second entry))
             (fn       (let ((kw0 kw) (ns0 name-str))
                         (lambda (expr env context location)
                           (%analyze-gpu-builtin kw0 ns0 expr env context location)))))
        (let ((sym-cl (intern name-str cl-pkg))
              (sym-cc (intern name-str cc-pkg)))
          (setf (gethash sym-cl *expression-analyzers*) fn)
          (unless (eq sym-cl sym-cc)
            (setf (gethash sym-cc *expression-analyzers*) fn)))))
    ;; IGC SROA-aliasing workaround (endeavor 103 phase B): %volatile-read
    (setf (gethash '%volatile-read *expression-analyzers*)
          #'analyze-%volatile-read-expression)))

;; ---------------------------------
;; The Brain (Semantic Analyzer)
;; ---------------------------------

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Multi-Pass Orchestration
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defvar *implicit-arg-map* (make-hash-table)
        "Map of function-name -> list of implicit argument requirements.")

(defvar *scratch-cell-counter* 0
        "Monotonic counter for disambiguating scratch cells.
         Used TWICE per module:
         1. During Analysis Scan (Pass 1) to generate Implicit Arguments.
         2. During Codegen (Pass 2) to generate LLVM IR.
         MUST BE RESET TO 0 BETWEEN PASSES.")

(defun compile-module (forms module builder di-builder di-compile-unit location-map)
  "Orchestrates the multi-pass compilation of a list of top-level forms.
   When --differentiate is enabled, pre-injects shadow def-struct forms for
   AD support before any of the passes see the forms list."
  (log:debug "*crisp-types*: ~s~%*expression-analyzers*: ~s"
             (alexandria:hash-table-keys *crisp-types*)
             (alexandria:hash-table-keys *expression-analyzers*))

  (let ((forms (if *differentiate-p*
                   (%inject-shadow-struct-forms forms)
                   forms)))
    ;; Pass 1: Gather all function signatures and build the call graph.
    (let ((*call-graph* (make-hash-table))
          (*originator-functions* (make-hash-table))
          (*implicit-arg-map* (make-hash-table)) ; Rebind for a clean state per module.
          (*scratch-cell-counter* 0)) ; Reset counter for deterministic naming
      (let ((*defer-struct-validation* t)
            (*pending-struct-definitions* nil))
        (analyze-signatures-pass forms)
        ;; Now finalize any structs that were deferred
        (finalize-struct-definitions))

      ;; Pass 1.5: Propagate implicit argument requirements up the call graph.
      (propagate-implicit-arguments)

      ;; Pass 2: Now that all signatures are known, compile the function bodies.
      ;; Reset counter so codegen (Pass 2) generates the same unique IDs as Pass 1
      (setf *scratch-cell-counter* 0)
      (log:info "Reset *scratch-cell-counter* to 0 for Pass 2 Codegen")
      (compile-forms-pass forms module builder di-builder di-compile-unit location-map)
      (check-for-recursion-cycles))))


(defun propagate-implicit-arguments ()
  "Phase 4: Traverses the call graph backwards from originators to find all carriers."
  (log:info "OVERLAY: propagate-implicit-arguments called with ~a originators"
            (hash-table-count *originator-functions*))
  (let ((worklist '()))
    ;; 1. Seed the worklist with all originator functions.
    ;; NOTE: Don't set their *implicit-arg-map* here - analyze-scratch-expression already did
    (loop for fn-name being the hash-keys of *originator-functions*
          do (progn
              (log:info "OVERLAY: Originator ~a has implicit-args: ~a"
                        fn-name (gethash fn-name *implicit-arg-map*))
              (push fn-name worklist)))

    ;; 2. Process the worklist until it's empty.
    (loop while worklist
          do (let* ((callee (pop worklist))
                    (callee-implicit (gethash callee *implicit-arg-map*))
                    ;; Find all functions that call the current callee.
                    (callers (loop for caller being the hash-keys of *call-graph*
                                   using (hash-value callees)
                                     when (member callee callees)
                                   collect caller)))
               (log:debug "OVERLAY: Processing callee ~a with implicit ~a, callers: ~a"
                          callee callee-implicit callers)
               (dolist (caller callers)
                 (let* ((existing (gethash caller *implicit-arg-map*))
                        ;; Use UNION to merge requirements. TEST=EQUAL ensures (name . type) pairs are unique keys.
                        (merged (union existing callee-implicit :test #'equal)))
                   (when (> (length merged) (length existing))
                         (log:info "OVERLAY: Propagating implicit args to ~a (Merged ~d -> ~d)"
                                   caller (length existing) (length merged))
                         (setf (gethash caller *implicit-arg-map*) merged)
                         (pushnew caller worklist))))))))

;; --- Generic Dependency Scanner ---


(defun multi-pass-mode-p ()
  "Returns T if in multi-pass compilation mode, NIL if in single-pass mode.

   Multi-pass mode builds a call graph, propagates implicit arguments, and
   allows forward references. Single-pass requires dependency-ordered code."
  (not (null *call-graph*)))

(defun single-pass-mode-p ()
  "Returns T if in single-pass compilation mode, NIL if in multi-pass mode.

   Single-pass mode compiles each form immediately as read, requiring functions
   to be defined before use (no forward references). Used for fast JIT compilation."
  (null *call-graph*))

(defvar *scanning-function-name* nil
        "The name of the function currently being scanned in Pass 1.")

(defvar *scratch-cell-counter* 0
        "Monotonic counter for disambiguating scratch cells.")

(defvar *scan-callees* nil)
(defvar *scan-is-originator* nil)

(defgeneric scan-form (form)
  (:documentation "Scans a form to find dependencies and side-channel originators."))

(defmethod scan-form ((form t))
  ;; Base case: Atoms (symbols, numbers, etc) don't have dependencies we care about here
  nil)

(defmethod scan-form ((form cons))
  (let ((op (car form)))
    (if (symbolp op)
        (scan-operator op (cdr form))
        ;; Lambda expression or other cons-car? Walk elements.
        (dolist (f form) (scan-form f)))))

(defgeneric scan-operator (op args)
  (:documentation "Handles specific operators for dependency scanning."))

;; Default Handler (Function Calls & Macros)
(defmethod scan-operator (op args)
  (cond
   ((and (symbolp op)
         (not (gethash op *expression-analyzers*))
         (macro-function op))
    ;; Expand macro and scan the result
    (handler-case
        (let ((expanded (macroexpand-1 (cons op args))))
          (scan-form expanded))
      (error ()
        ;; If macroexpansion fails, fall back to scanning arguments.
        ;; This allows the analyzer in Pass 2 to generate the proper compiler error.
        (dolist (arg args) (scan-form arg)))))
   ((member op *side-channel-originators*)
    (setf *scan-is-originator* t))
   (t
    (when (and (symbolp op) (not (macro-function op)) (not (special-operator-p op)))
          (pushnew op *scan-callees*))
    (dolist (arg args) (scan-form arg)))))

;; Special Form Handlers
(defmethod scan-operator ((op (eql 'declare)) args) nil)
(defmethod scan-operator ((op (eql 'quote)) args) nil)
(defmethod scan-operator ((op (eql 'function)) args) nil)

(defmethod scan-operator ((op (eql 'let)) args)
  (let ((bindings (first args))
        (body (rest args)))
    (let ((old-binding (compiler-context-current-binding-name *compiler-context*)))
      (dolist (b bindings)
        ;; Bindings can be (var val) or var
        (when (consp b)
              ;; Set the current binding name for deep scanning
              (let ((var-name (first b)))
                (log:debug "Pass 1: Scanning let binding for ~a" var-name)
                (setf (compiler-context-current-binding-name *compiler-context*) var-name)
                (scan-form (second b))
                ;; Restore after scanning the value form
                (setf (compiler-context-current-binding-name *compiler-context*) old-binding))))
      (dolist (f body) (scan-form f)))))


(defmethod scan-operator ((op (eql 'let*)) args)
  (scan-operator 'let args))

(defmethod scan-operator ((op (eql 'cl:let)) args)
  (scan-operator 'let args))

(defmethod scan-operator ((op (eql 'cl:let*)) args)
  (scan-operator 'let args))

(defmethod scan-operator ((op (eql 'if)) args)
  (dolist (arg args) (scan-form arg)))

(defmethod scan-operator ((op (eql 'go)) args) (scan-operator 'progn args))
(defmethod scan-operator ((op (eql 'return-from)) args) (scan-operator 'progn args))
(defmethod scan-operator ((op (eql 'semantic-return)) args) (scan-operator 'progn args))
(defmethod scan-operator ((op (eql 'explicit-return)) args) (scan-operator 'progn args))
(defmethod scan-operator ((op (eql 'semantic-explicit-return)) args) (scan-operator 'progn args))
(defmethod scan-operator ((op (eql 'progn)) args)
  (dolist (arg args) (scan-form arg)))

;; This specialized scan-operator method handles make-scratch-cell specifically
(defmethod scan-operator ((op (eql 'make-scratch-cell)) args)
  "Scans make-scratch-cell and extracts the type for *implicit-arg-map*."
  (setf *scan-is-originator* t)

  ;; Extract the type argument: (make-scratch-cell TYPE)
  ;; Per design: scratch cells default to :address-space :local in absence of
  ;; an explicit user-supplied address-space.
  (when args
        (let* ((arg1 (first args))
               (address-space (if (and (>= (length args) 3) (eq (second args) :address-space))
                                  (third args)
                                  :local))
               (raw-spec (cond
                           ((and (consp arg1) (eq (first arg1) 'cell))
                            ;; User wrote (cell elem ...).  Inject :local if
                            ;; no address-space is present.
                            (if (or (member :address-space arg1)
                                    (some (lambda (x)
                                            (and (symbolp x)
                                                 (member (symbol-name x)
                                                         '("GLOBAL" "LOCAL" "PRIVATE" "CONSTANT" "GENERIC")
                                                         :test #'string-equal)))
                                          (rest arg1)))
                                arg1
                                (append arg1 '(:address-space :local))))
                           (t (list 'cell arg1 :address-space address-space))))
               (canonical-spec (expand-storage-handle-type-specifier raw-spec)))
          ;; Store in *implicit-arg-map* for this function
          ;; Unique Naming: varName_from_FnName_N
          (let* ((binding-name (or (compiler-context-current-binding-name *compiler-context*) '__storage))
                 (fn-name (compiler-context-scanning-function-name *compiler-context*))
                 (counter (incf *scratch-cell-counter*))
                 (unique-name-str (format nil "~a_FROM_~a_~d" binding-name fn-name counter))
                 (unique-name (intern unique-name-str (symbol-package binding-name))))

            (log:info "Pass 1: make-scratch-cell ~a -> implicit: ~a" binding-name unique-name)

            (let* ((existing (gethash fn-name *implicit-arg-map*))
                   (match (find canonical-spec existing :key #'cdr :test #'equal)))
              (declare (ignore match))
              (cond
               (t
                 (let ((new-entry (cons unique-name canonical-spec)))
                   (push new-entry (gethash fn-name *implicit-arg-map*)))))))))

  ;; Continue scanning arguments
  (dolist (arg args) (scan-form arg)))

(defmethod scan-operator ((op (eql 'make-async-barrier)) args)
  "Scans make-async-barrier and delegates to make-scratch-cell to allocate an 8-byte mbarrier object."
  (declare (ignore args))
  (scan-operator 'make-scratch-cell '(ulong)))



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

(defun shallow-analyze-body (forms)
  "Performs a shallow, recursive walk of a function's body.
  Returns two values:
  1. A boolean indicating if a side-channel originator was found.
  2. A list of all unique symbols found in the 'car' of lists (potential function calls)."
  (let ((*scan-callees* nil)
        (*scan-is-originator* nil))
    (dolist (form forms)
      (scan-form form))
    (values *scan-is-originator* *scan-callees*)))

(defun visit-toplevel-form (form location visitor-fn)
  "Recursively visits a top-level form, handling macros and progn.
   Visitor-fn is called as (visitor-fn form location) for def-function forms.
   Other forms are evaluated if they are not special forms handled by the walker."
  (cond
   ;; Case 1: def-function -> Visit it
   ((and (consp form) (eq (car form) 'def-function))
     (funcall visitor-fn form location))

   ;; Case 2: progn -> Recurse
   ((and (consp form) (eq (car form) 'progn))
     (loop for sub-form in (cdr form)
           for i from 0
           do (visit-toplevel-form sub-form (append location (list i)) visitor-fn)))

   ;; Case 3: Macro -> Expand and Recurse
   ((and (consp form) (symbolp (car form)) (macro-function (car form)))
     (visit-toplevel-form (macroexpand-1 form) location visitor-fn))

   ;; Case 4: Other -> Eval (for side effects like defmacro, register-template)
   (t
     (eval form))))


(defun %compile-standard-function (form location module builder di-builder di-compile-unit location-map)
  "Helper: Compiles a standard (non-generic) function definition."
  (let* ((name (second form))
         (context *compiler-context*))
    (setf (compiler-context-current-compiling-function context) name)
    ;; PATCHED: Removed push/pop of single-pass-call-stack
    (unwind-protect
        (let* ((form-with-location (append form (list :source-location `',location)))
               (expanded-form (macroexpand-1 form-with-location))
               (semantic-node (eval expanded-form)))
          ;; Handle implicit templates which return nil
          (when semantic-node
                (log:info "Generating IR for function ~a in module ~a" name module)
                (generate-llvm-ir semantic-node module builder di-builder di-compile-unit location-map)))
      ;; Cleanup: clear current function (replaces pop of stack)
      (setf (compiler-context-current-compiling-function context) nil))))



;;; Fix: compile-def-function -- Option A: wrap backward companion compilation
;;; in handler-case. If the generated _GRAD def-function fails to compile
;;; (e.g. type mismatch for double/derived-type gradients), catch the error,
;;; unregister the function from *differentiable-functions*, log info, and
;;; continue. The kernel backward walk (GBW) will error if this function is
;;; actually called in a differentiable context.
;;; src/analysis/core.lisp
(defun compile-def-function (form location module builder di-builder di-compile-unit location-map)
  "Compiles a single def-function form. Handles optional parameters by generating
overloaded variants. When *differentiate-p* is T, also generates and compiles
the _GRAD backward companion after the forward function."
  ;; In single-pass mode, the signature won't be registered yet.
  (unless (gethash (second form) *function-table*)
    (register-function-signature form location))

  (let* ((name (second form))
            (params (third form))
            (body-and-loc (cdddr form))
            ;; Extract declarations manually to check for optional args and system flag.
            (declare-forms (loop for f in body-and-loc
                                    while (and (listp f) (eq (car f) 'declare))
                                    collect f))
            (declarations (loop for f in declare-forms append (rest f)))
            (is-system (member '(crisp-system-generated) declarations :test #'equal)))

    (multiple-value-bind (explicit-env return-types optional-idx defaults key-idx)
        (parse-function-declarations params declarations)
      (declare (ignore explicit-env return-types defaults))

      (cond
       ;; --- OPTIONAL/KEY PARAMETERS: Lazy Instantiation (Generic Template) ---
       ((or optional-idx key-idx)
         (log:info "Skipping eager compilation for GENERIC function template: ~a. Variants will be compiled on demand." name))

       ;; --- STANDARD Compilation (No Optionals) ---
       (t
         (%compile-standard-function form location module builder di-builder di-compile-unit location-map)
         ;; Feature 052: After compiling the forward function, generate and compile
         ;; the _GRAD backward companion when differentiating.
         (when (and *differentiate-p*
                    (not (%fn-name-is-grad-p name))
                    (not is-system))
           (let* ((body-forms (nthcdr (length declare-forms) body-and-loc))
                     (bkwd-form (%generate-backward-function-ast name params declarations body-forms)))
             (when bkwd-form
               (log:info "AUTODIFF: Compiling backward companion for ~a" name)
               (handler-case
                 (compile-def-function bkwd-form location module builder
                                       di-builder di-compile-unit location-map)
                 (error (e)
                   (log:info "AUTODIFF: ~a _GRAD compilation failed: ~a. Unregistering; will error if called from a differentiable kernel." name e)
                   (remhash name *differentiable-functions*)))))))))))

(defun walk-code-forms (forms visitor-fn)
  "Walks top-level forms, handling macros and progn, and calling visitor-fn on def-function."
  (loop for form in forms
        for i from 0
        do (visit-toplevel-form form (list i) visitor-fn)))





(defun analyze-signatures-pass (forms)
  "Pass 1: Pre-register differentiable functions, then iterate through forms
to find and register all function signatures and build the call graph.
Pre-registration ensures *differentiable-functions* is populated before
def-kernel macros expand and call generate-backward-walk (feature 052).
Also scans *template-registry* for HOF templates after walk-code-forms.

Endeavor 120: also captures each function's macro-expanded params/body and
runs infer-param-uniformity once the call graph is complete."
  ;; Endeavor 120: reset per-module uniformity/inert state.
  (clrhash *inert-functions*)
  (clrhash *fn-normalized-info*)
  (clrhash *inferred-param-uniformity*)
  ;; Step 1: Pre-populate from top-level def-function forms.
  (%pre-register-differentiable-fns forms)
  ;; Step 2: Walk all forms (registers templates, signatures, etc.)
  (walk-code-forms forms
                   (lambda (form location)
                     (let* ((name (second form))
                               (body (cdddr form))
                               (body-forms (loop for f in body
                                                 unless (and (listp f) (eq (car f) 'declare))
                                                 collect f))
                               (decls (loop for f in body
                                            when (and (listp f) (eq (car f) 'declare))
                                            append (rest f)))
                               (entry-point-p (loop for d in decls
                                                    thereis (and (listp d) (symbolp (first d))
                                                                 (string-equal (symbol-name (first d)) "ENTRY-POINT")))))
                       ;; Endeavor 120: capture normalized info for inference.
                       (setf (gethash name *fn-normalized-info*)
                             (list :params (third form) :body body-forms :entry-point-p entry-point-p))
                       (register-function-signature form location)
                       (let ((*compiler-context* (make-compiler-context)))
                         (setf (compiler-context-scanning-function-name *compiler-context*) name)
                         (multiple-value-bind (is-originator callees)
                             (shallow-analyze-body body)
                           (when is-originator
                             (setf (gethash name *originator-functions*) t))
                           (setf (gethash name *call-graph*) callees))))))
  ;; Step 3: After walk-code-forms, scan template registry for HOF templates.
  (%pre-register-hof-templates)
  ;; Endeavor 120: interprocedural uniformity inference (call graph is ready).
  (infer-param-uniformity))



(defun %uni-param-names (params)
  "Extract ordered parameter names from a def-function parameter list,
   handling both plain symbols and (name type ...) interleaved specs."
  (loop for p in params
        collect (if (consp p) (first p) p)))

(defun %uni-combine (states)
  "Taint-max over a list of uniformity STATES. :divergent dominates, then
   :unknown, otherwise :uniform. (Empty list -> :uniform.)"
  (cond ((null states) :uniform)
        ((member :divergent states) :divergent)
        ((member :unknown states) :unknown)
        (t :uniform)))

(defun %uni-builtin-state (op)
  "Return :uniform or :divergent if OP is a recognized GPU builtin operator,
   else NIL. Matched by symbol-name so it is package-agnostic."
  (let ((n (symbol-name op)))
    (cond ((member n '("GET-LOCAL-ID" "GET-GLOBAL-ID") :test #'string=) :divergent)
          ((member n '("GET-WORKGROUP-ID" "GET-WORKGROUP-SIZE" "GET-WARP-SIZE"
                       "GET-GLOBAL-SIZE" "GET-NUM-GROUPS" "GET-LOCAL-WORK-SIZE"
                       "GET-GLOBAL-WORK-SIZE" "GET-GLOBAL-OFFSET")
                   :test #'string=) :uniform)
          (t nil))))

(defun %uni-contribute (callee param-name state)
  "Meet STATE into *uni-meet-table*[CALLEE][PARAM-NAME]."
  (let ((tbl (or (gethash callee *uni-meet-table*)
                 (setf (gethash callee *uni-meet-table*) (make-hash-table :test 'eq)))))
    (multiple-value-bind (existing present) (gethash param-name tbl)
      (setf (gethash param-name tbl)
            (if present (%uni-combine (list existing state)) state)))))

(defun %uni-analyze-let (form env)
  "Uniformity walk of a (let (bindings...) body...) form. Crisp let is
   let*-like, so bindings extend ENV sequentially. Multi-value bindings bind
   each var to :unknown (conservative). Returns the state of the last body
   form."
  (let ((bindings (second form))
        (body (cddr form))
        (new-env env))
    (dolist (b bindings)
      (cond
       ((and (consp b) (= (length b) 2) (symbolp (first b)))
        (let ((st (%uni-analyze (second b) new-env)))
          (setf new-env (acons (first b) st new-env))))
       ((consp b)
        ;; multi-value bind: walk the init (last element) for nested calls;
        ;; the bound vars are conservatively :unknown.
        (%uni-analyze (car (last b)) new-env)
        (dolist (vv (butlast b))
          (when (symbolp vv) (setf new-env (acons vv :unknown new-env)))))
       (t nil)))
    (let ((last-state :uniform))
      (dolist (f body last-state)
        (setf last-state (%uni-analyze f new-env))))))

(defun %uni-analyze (form env)
  "Lightweight uniformity walk of a raw body FORM under ENV (an alist
   name -> state). Returns FORM's uniformity state; as a side effect,
   contributes call-site argument states to *uni-meet-table* for every call
   to a known user function (see infer-param-uniformity)."
  (cond
   ((null form) :uniform)
   ((integerp form) :uniform)
   ((floatp form) :uniform)
   ((keywordp form) :uniform)
   ((symbolp form)
    (let ((cell (assoc form env)))
      (if cell (cdr cell) :unknown)))
   ((consp form)
    (let* ((op (car form))
           ;; Compute builtin state up front. NOTE: crisp.compiler's `cond`
           ;; macro drops the value of a clause that has only a test and no
           ;; body, so we must NOT rely on the bare `((%uni-builtin-state op))`
           ;; idiom — give the builtin clause an explicit body (`(bs bs)`).
           (bs (and (symbolp op) (%uni-builtin-state op))))
      (cond
       ((not (symbolp op))
        ;; e.g. ((lambda ...) ...) — just recurse for nested calls.
        (dolist (a (cdr form)) (when (consp a) (%uni-analyze a env)))
        :unknown)
       ;; let / let* : sequential scoping
       ((string-equal (symbol-name op) "LET")
        (%uni-analyze-let form env))
       ;; arithmetic / comparison contagion
       ((member (symbol-name op)
                '("+" "-" "*" "/" "SIN" "COS"
                  "<" ">" "<=" ">=" "=" "/=" "MOD" "REM")
                :test #'string=)
        (%uni-combine (mapcar (lambda (a) (%uni-analyze a env)) (cdr form))))
       ;; forced-uniform constructs
       ((member (symbol-name op) '("TO-WARP-UNIFORM" "TO-WORKGROUP-UNIFORM") :test #'string=)
        (dolist (a (cdr form)) (%uni-analyze a env))
        :uniform)
       ;; type conversions are uniformity-transparent (Endeavor 120 gap #6).
       ;; (to-*-uniform handled above, so a TO-/AS- prefix here is a cast.)
       ((and (> (length (symbol-name op)) 3)
             (or (string= (subseq (symbol-name op) 0 3) "TO-")
                 (string= (subseq (symbol-name op) 0 3) "AS-")))
        (%uni-combine (mapcar (lambda (a) (%uni-analyze a env)) (cdr form))))
       ;; GPU builtins (uniform / divergent roots). Explicit body required —
       ;; see the cond-quirk note above.
       (bs bs)
       ;; call to a known user function: contribute argument uniformities
       ((gethash op *fn-normalized-info*)
        (let* ((callee-params (%uni-param-names (getf (gethash op *fn-normalized-info*) :params)))
               (args (cdr form))
               (arg-states (mapcar (lambda (a) (%uni-analyze a env)) args)))
          ;; Only contribute when arity matches positionally — exploded
          ;; storage-handle calls or arity mismatches are left uninferred
          ;; (safe: callee param stays :unknown).
          (when (= (length args) (length callee-params))
            (loop for pname in callee-params
                  for st in arg-states
                  do (%uni-contribute op pname st)))
          :unknown))
       ;; anything else: recurse to discover nested calls; value :unknown
       (t
        (dolist (a (cdr form)) (when (consp a) (%uni-analyze a env)))
        :unknown))))
   (t :unknown)))

(defun %uni-topo-order (nodes)
  "Topological order of NODES (function-name symbols) by *call-graph* edges
   caller->callee, callers first. Recursion is banned so this is a DAG; any
   leftover (cyclic) nodes are appended at the end."
  (let ((indeg (make-hash-table :test 'eq))
        (succ (make-hash-table :test 'eq))
        (nodeset (make-hash-table :test 'eq)))
    (dolist (n nodes)
      (setf (gethash n nodeset) t)
      (setf (gethash n indeg) 0))
    (dolist (caller nodes)
      (let ((callees (remove-duplicates
                      (loop for c in (gethash caller *call-graph*)
                            when (and (gethash c nodeset) (not (eq c caller)))
                            collect c))))
        (setf (gethash caller succ) callees)
        (dolist (c callees) (incf (gethash c indeg)))))
    (let ((queue (loop for n in nodes when (zerop (gethash n indeg)) collect n))
          (order '()))
      (loop while queue do
        (let ((n (pop queue)))
          (push n order)
          (dolist (c (gethash n succ))
            (when (zerop (decf (gethash c indeg)))
              (push c queue)))))
      (dolist (n nodes)
        (unless (member n order) (push n order)))
      (nreverse order))))

(defun infer-param-uniformity ()
  "Endeavor 120 (Option 1): conservative interprocedural uniformity inference.
   Seeds kernel (entry-point) parameters as :uniform, then propagates argument
   uniformity down the call graph (callers processed before callees). A
   function parameter is inferred :uniform only when EVERY observed call site
   passes a provably-uniform argument. Results are stored in
   *inferred-param-uniformity* and applied (upgrade-only) to the
   body-compilation environment by inject-implicit-arguments.

   Generic/template functions are skipped: their call sites can be created
   lazily during Pass 2, so the pre-pass cannot see all of them, and an
   incorrectly-inferred :uniform would be unsafe."
  (let ((nodes (loop for k being the hash-keys of *fn-normalized-info* collect k)))
    (let ((*uni-meet-table* (make-hash-table :test 'eq))
          (order (%uni-topo-order nodes)))
      (dolist (name order)
        (let* ((info (gethash name *fn-normalized-info*))
               (params (%uni-param-names (getf info :params)))
               (entry-point-p (getf info :entry-point-p))
               (body (getf info :body))
               (lazy-p (or (and (boundp '*generic-functions*) (gethash name *generic-functions*))
                           (and (boundp '*template-registry*) (gethash name *template-registry*))))
               (param-states
                (cond
                 (entry-point-p
                  (loop for p in params collect (cons p :uniform)))
                 (lazy-p
                  (loop for p in params collect (cons p :unknown)))
                 (t
                  (let ((tbl (gethash name *uni-meet-table*)))
                    (loop for p in params
                          collect (cons p (if tbl
                                              (multiple-value-bind (s present) (gethash p tbl)
                                                (if present s :unknown))
                                              :unknown))))))))
          (setf (gethash name *inferred-param-uniformity*) param-states)
          ;; Walk the body to contribute argument uniformities to callees,
          ;; using this function's own resolved parameter environment.
          (let ((env param-states))
            (dolist (f body)
              (%uni-analyze f env)))))
      (log:debug "Endeavor 120 inferred param uniformity: ~s"
                 (loop for k being the hash-keys of *inferred-param-uniformity*
                       using (hash-value vv) collect (cons k vv))))))

(defun compile-forms-pass (forms module builder di-builder di-compile-unit location-map)
  "Pass 2: Iterates through forms to perform full analysis and codegen."
  (let ((*compiler-session* (make-compiler-session :module module
                                                   :builder builder
                                                   :di-builder di-builder
                                                   :di-compile-unit di-compile-unit
                                                   :location-map location-map))
        (*compiler-context* (make-compiler-context))) ; <--- Context

    ;; Pre-Pass: Ensure all templates instantiated during Pass 1 (signatures only) 
    ;; are now fully compiled to IR/Structs in this module.
    (maphash (lambda (key status)
               (when (eq status :analyzed)
                     (let ((name (car key))
                           (types (cdr key)))
                       (log:info "Pass 2: Rehydrating/Compiling template instance: ~a ~a" name types)
                       (funcall *template-instantiator-fn* name types
                         (lambda (form location)
                           (compile-toplevel-form form location module builder di-builder di-compile-unit location-map))))))
             *instantiated-templates*)

    (walk-code-forms forms
                     (lambda (form location)
                       (compile-toplevel-form form location module builder di-builder di-compile-unit location-map)))))

  
  
(defun compile-toplevel-form (form location module builder di-builder di-compile-unit location-map)
  "Analyzes and compiles a single top-level form (used in Pass 2 and single-pass mode).
When *differentiate-p* is T, also calls %pre-register-hof-templates after each form
so that with-template-type HOF definitions are available before kernel backward walks
in single-pass mode."
  (log:debug "Compiling top-level form at ~a: ~s" location form)

  (let ((*compiler-session* (make-compiler-session :module module
                                                   :builder builder
                                                   :di-builder di-builder
                                                   :di-compile-unit di-compile-unit
                                                   :location-map location-map))
        (*compiler-context* (make-compiler-context)))
    (prog1
      (visit-toplevel-form form location
                           (lambda (form location)
                             (compile-def-function form location module builder di-builder di-compile-unit location-map)))
      ;; After processing any form, re-scan the template registry for HOF templates.
      ;; This ensures that HOFs registered by with-template-type are available to
      ;; kernel backward walks in single-pass mode before the next form is processed.
      (when *differentiate-p*
        (%pre-register-hof-templates)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Recursion Cycle Detection
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun check-for-recursion-cycles ()
  "Iterates through the call graph to find any recursive cycles."
  (log:debug "Checking for recursion cycles in call graph: ~s" *call-graph*)
  (let ((visited (make-hash-table)))
    (loop for caller being the hash-keys of *call-graph*
          do (unless (gethash caller visited)
               (detect-cycle-from-node caller visited (make-hash-table))))))

(defun detect-cycle-from-node (node visited visiting)
  "Performs a DFS from the given node to detect a cycle."
  (setf (gethash node visiting) t)

  (let ((callees (gethash node *call-graph*)))
    (dolist (callee callees)
      (cond
       ;; If the callee is in the current 'visiting' path, we found a cycle.
       ((gethash callee visiting)
         (let ((sig (first (gethash callee *function-table*))))
           (error 'crisp-recursion-error
             :form callee
             :source-location (when sig (function-signature-source-location sig)))))

       ;; If the callee has not been visited at all yet, recurse.
       ((not (gethash callee visited))
         (detect-cycle-from-node callee visited visiting)))))

  ;; We're done with this node's path. Remove it from 'visiting'
  ;; and add it to 'visited' so we don't check it again.
  (remhash node visiting)
  (setf (gethash node visited) t))

(defun find-variable-in-env (name env)
  "Finds a variable definition in the environment."
  (find name env :key #'parameter-def-name))


(defun validate-return-types (name body env context declared-return-types location)
  "Analyzes the function body and validates return types.
   Fixes: A 1-element list whose sole element is a symbol (e.g. (TOKEN-T)) is always
   treated as a return-types list, never as a parameterized type. This prevents
   double-wrapping when the type name is a type alias."
  (declare (ignore name))
  ;; Handle the case where a function promises a return value but has no body.
  (when (and (not (equal declared-return-types '(nil))) (null body))
        (error 'crisp-type-error :expected declared-return-types :inferred '(nil) :source-location location))

  (let* ((body-nodes (analyze-body-expressions body env context location))
         (return-node (first (last body-nodes)))
         (inferred-types (if return-node
                             (let ((node-type (semantic-node-type return-node)))
                               ;; If the node-type is a list, we need to distinguish between
                               ;; a multi-value return type like '(int int) and a single
                               ;; parameterized type like '(cell int).
                               ;; A 1-element list of a symbol (e.g. (TOKEN-T)) is always a
                               ;; return-types list - no parameterized type has 0 args.
                               (if (and (listp node-type)
                                        (or (not (valid-type-p node-type))
                                            (and (= (length node-type) 1)
                                                 (symbolp (first node-type)))))
                                   node-type ; It's a list of return values, use as-is.
                                   (list node-type))) ; It's a single value, wrap it in a list.
                             '(nil))))

    (log:debug "Analyzed body nodes: ~s~% Return node: ~s~% Inferred types: ~s~% Declared return types: ~s" body-nodes return-node inferred-types declared-return-types)

    (log:debug "Type Check. Inferred: ~s (is list: ~s)~% Declared: ~s (is list: ~s)"
               inferred-types (listp inferred-types)
               declared-return-types (listp declared-return-types))

    ;; Check Types. This allows for a function returning multiple values
    ;; to be used in a context that expects fewer values (the extras are dropped).
    (let* ((num-declared (length declared-return-types))
           (num-inferred (length inferred-types))
           ;; Take the first N inferred types, where N is the number of declared types.
           (inferred-subset (if (>= num-inferred num-declared)
                                (subseq inferred-types 0 num-declared)
                                inferred-types)))
      (unless (and (>= num-inferred num-declared)
                   ;; Fix for Regression in 30-derived-numeric-types:
                   ;; Instead of strict equivalence, we check if the inferred type is assignable
                   ;; to the declared type (e.g. EQ-WEAK is assignable to FLOAT).
                   (every #'types-assignable-p inferred-subset declared-return-types))
        (error 'crisp-type-error
          :expected declared-return-types
          :inferred inferred-types
          :source-location (if return-node
                               (semantic-node-source-location return-node)
                               location))))
    (values body-nodes inferred-types)))

(defun internal-compile-function (name explicit-env return-type params body declarations location context)
  "Core compilation logic for a function, accepting a pre-parsed environment."
  (log:info "COMPILE: ~s (single-pass: ~a)" name (single-pass-mode-p))
  (log:info "COMPILE: ~s (env keys for ~s: ~s)" name name (mapcar #'car (gethash name *implicit-arg-map*)))

  ;; 0-a. Reserved Name Validation (Accessors ~x~ are not overloadable unless system generated)
  (let ((name-str (symbol-name name)))
    (when (and (> (cl:length name-str) 2)
               (cl:char= (cl:char name-str 0) #\~)
               (cl:char= (cl:char name-str (1- (length name-str))) #\~))
          (unless (find 'crisp-system-generated declarations :key (lambda (x) (if (listp x) (car x) x)))
            (error 'crisp-compiler-error
              :source-location location
              :message (format nil "Function name '~a' is reserved (accessors ending in ~~ are not overloadable)." name)))))

  ;; 0-b. Implicit Template Detection
  (when (detect-and-register-implicit-template name explicit-env return-type params body declarations)
        (return-from internal-compile-function nil))

  ;; 1. Single-Pass Carrier Look-ahead
  (scan-for-carriers name body)

  ;; 2. Implicit Argument Handling
  (let ((env (inject-implicit-arguments name explicit-env)))
    ;; Save old declarations to restore after (for nested definitions support)
    (let ((old-declarations (compiler-context-declarations context)))
      (setf (compiler-context-declarations context) declarations)
      (let ((compilation-result
             (unwind-protect
                 ;; 3. Analyze Body and Validate Return Types
               (multiple-value-bind (body-nodes inferred-return-types)
                   (validate-return-types name body env context return-type location)

                 ;; Update the function registry if we inferred a return type and none was declared.
                 (when (and (or (null return-type) (equal return-type '(nil)))
                            (not (equal inferred-return-types '(nil))))
                       (log:info "Updating signature for ~a with inferred return types: ~a" name inferred-return-types)
                       (let* ((param-types (mapcar #'parameter-def-type explicit-env))
                              (sig (find-if (lambda (s) (equal (mapcar #'parameter-def-type (function-signature-parameters s)) param-types))
                                       (gethash name *function-table*))))
                         (when sig
                               (setf (function-signature-return-types sig) inferred-return-types))))

                 ;; Update implicit parameters in recursive registry
                 (let* ((num-explicit (length explicit-env))
                        (num-total (length env)))
                   (when (> num-total num-explicit)
                         (let* ((implicit-count (- num-total num-explicit))
                                (implicit-params (subseq env 0 implicit-count))
                                ;; Find the signature again (or reuse if I refactor, but robust to find it)
                                (param-types (mapcar #'parameter-def-type explicit-env))
                                (sig (find-if (lambda (s) (equal (mapcar #'parameter-def-type (function-signature-parameters s)) param-types))
                                         (gethash name *function-table*))))
                           (when sig
                                 (log:info "Persisting implicit parameters for ~a: ~s" name implicit-params)
                                 (setf (function-signature-implicit-parameters sig) implicit-params)))))

                 ;; 4. Build and return the "blueprint"
                 (let ((return-node (first (last body-nodes))))
                   (make-semantic-function
                    :name name
                    :param-list (loop for param in env
                                      collect (make-semantic-param :name (parameter-def-name param)
                                                                   :type (parameter-def-type param)
                                                                   :source-location location))
                    :return-type (cond
                                  ((or (null return-type) (equal return-type '(nil)))
                                    inferred-return-types)
                                  (t
                                    return-type))
                    :body (cond
                           ((null return-node)
                             (list (make-semantic-return :return-type '(nil) :value-node nil)))
                           ((typep return-node 'semantic-explicit-return)
                             body-nodes)
                           (t
                             (append (butlast body-nodes)
                               (list (make-semantic-return
                                      :return-type (let ((nt (semantic-node-type return-node)))
                                                     (if (and (listp nt) (not (valid-type-p nt)))
                                                         nt
                                                         (list nt)))
                                      ;; TRUNCATION LOGIC FOR IMPLICIT RETURN
                                      :value-node (let* ((nt (semantic-node-type return-node))
                                                         (val-types (if (and (listp nt) (not (valid-type-p nt))) nt (list nt)))
                                                         (target-types (cond ((or (null return-type) (equal return-type '(nil))) inferred-return-types)
                                                                             (t return-type)))
                                                         (target-list (if (and (listp target-types) (not (valid-type-p target-types))) target-types (list target-types))))

                                                    (cond
                                                     ;; Case: 1 value needed, >1 provided. Extract index 0.
                                                     ((and (= (length target-list) 1) (> (length val-types) 1))
                                                       (log:info "Implicit Return Truncation: ~a -> ~a" val-types target-list)
                                                       (make-semantic-extract-value
                                                        :type (first target-list)
                                                        :aggregate-node return-node
                                                        :index 0
                                                        :source-location (if return-node (semantic-node-source-location return-node) location)))

                                                     ;; TODO: Handle N -> M (where M > 1 and N > M) case if needed.
                                                     ;; For now return original node.
                                                     (t return-node)))

                                      :source-location (if return-node (semantic-node-source-location return-node) location))))))
                    :is-entry-point (loop for decl in declarations
                                            thereis (and (listp decl) (eq (first decl) 'entry-point)))
                    :source-location location)))
               ;; Cleanup
               (setf (compiler-context-declarations context) old-declarations))))
        (log:info "INTERNAL-COMPILE-FUNCTION RESULT ~s" (type-of compilation-result))
        compilation-result))))





;;; ============================================================
;;; Struct Immutability at Kernel Boundary
;;; src/analysis/core.lisp, src/analysis/structs.lisp
;;; ============================================================
;;; def-struct parameters at the kernel boundary are semantically
;;; immutable (SPIR-V constant memory). Two dynamic variables and
;;; checks in the analysis phase enforce this.
;;;
;;; *boundary-struct-params* -- list of uppercase param-name strings
;;;   for def-struct-typed parameters of the current entry-point kernel.
;;;   Nil when compiling regular functions.
;;;
;;; *struct-mutating-functions* -- hash table mapping uppercase
;;;   function names -> T for functions that (directly or indirectly)
;;;   mutate a struct-typed :in parameter.
;;;
;;; Enforcement paths:
;;;   1. Direct: (set! (x~ p) val) in kernel where p is boundary -> error
;;;   2. Indirect: (f p) in kernel where f is struct-mutating -> error
;;;   3. Propagation: f mutates :in param -> register f as struct-mutating
;;; ============================================================

(defvar *divergent-scope-depth* 0
  "Tracks the depth of nested divergent control flow constructs (if, when, etc.
   with divergent conditions) during semantic analysis.")

(defvar *boundary-struct-params* nil
  "Dynamic variable: list of uppercase param name strings that are def-struct
   params at the current kernel boundary. Non-nil only when compiling an
   entry-point kernel body. Nil in regular functions.")

(defvar *struct-mutating-functions* (make-hash-table :test #'equal)
  "Maps uppercase function name (string) -> T for functions that directly or
   indirectly mutate a struct-typed :in parameter.")

;; Helper: check if a type symbol names a registered def-struct (not def-record, package-safe)
(defun %boundary-struct-type-p (type)
  "Returns T if TYPE is a symbol naming a registered def-struct (category :struct)
   in *crisp-structs*. Returns NIL for def-record types (category :record).
   Uses string-equal for package-agnostic comparison."
  (when (symbolp type)
    (let ((type-name (symbol-name type)))
      (loop for k being the hash-keys of *crisp-structs*
            thereis (and (symbolp k)
                         (string-equal (symbol-name k) type-name)
                         ;; Only match actual def-struct entries (not def-record)
                         (let ((ct (gethash k *crisp-types*)))
                           (and ct (eq (crisp-type-category ct) :struct))))))))

;; Helper: enforce immutability or mark current function as struct-mutating
(defun %check-struct-boundary-mutation (struct-node env context location)
  "Called when a struct member update is about to be emitted.
   In kernel context (*boundary-struct-params* bound): error if the struct
   being mutated is a kernel boundary parameter.
   In function context: mark the current function as struct-mutating if it is
   mutating an :in parameter."
  (when (semantic-var-read-p struct-node)
    (let* ((vname     (semantic-var-read-name struct-node))
           (vname-str (string-upcase (symbol-name vname))))
      (if *boundary-struct-params*
          ;; Kernel context: check if this var is a boundary struct param
          (when (member vname-str *boundary-struct-params* :test #'string=)
            (error 'crisp-compiler-error
                   :message (format nil "Cannot mutate struct parameter '~a': struct parameters at kernel boundary are immutable"
                                    vname)
                   :source-location location))
          ;; Regular function context: mark as struct-mutating if mutating :in param
          (let ((var-info (find-variable-in-env vname env)))
            (when (and var-info (eq (parameter-def-kind var-info) :in))
              (let ((fn-name (compiler-context-current-compiling-function context)))
                (when fn-name
                  (log:debug "Marking ~a as struct-mutating (mutates :in param ~a)" fn-name vname)
                  (setf (gethash (string-upcase (symbol-name fn-name)) *struct-mutating-functions*) t)))))))))

;; Helper: check if a function call passes a boundary struct to a mutating function
(defun %check-struct-mutating-call (op explicit-arg-nodes env context location)
  "Called during function call analysis when OP is in *struct-mutating-functions*.
   Kernel context: error if any arg is a boundary struct param.
   Function context: propagate struct-mutating mark if any :in struct param is passed."
  (when (and (symbolp op)
             (gethash (string-upcase (symbol-name op)) *struct-mutating-functions*))
    (dolist (arg-node explicit-arg-nodes)
      (when (semantic-var-read-p arg-node)
        (let* ((vname     (semantic-var-read-name arg-node))
               (vname-str (string-upcase (symbol-name vname))))
          (if *boundary-struct-params*
              ;; Kernel context: error if passing a boundary param to struct-mutating fn
              (when (member vname-str *boundary-struct-params* :test #'string=)
                (error 'crisp-compiler-error
                       :message (format nil "Cannot pass boundary struct '~a' to '~a' which mutates its struct argument: struct parameters at kernel boundary are immutable"
                                        vname op)
                       :source-location location))
              ;; Regular function context: propagate struct-mutating mark
              (let ((var-info (find-variable-in-env vname env)))
                (when (and var-info
                           (eq (parameter-def-kind var-info) :in)
                           (%boundary-struct-type-p (parameter-def-type var-info)))
                  (let ((fn-name (compiler-context-current-compiling-function context)))
                    (when fn-name
                      (log:debug "Marking ~a as struct-mutating (passes :in param ~a to ~a)" fn-name vname op)
                      (setf (gethash (string-upcase (symbol-name fn-name)) *struct-mutating-functions*) t)))))))))))


;;; src/analysis/core.lisp
(defvar *boundary-array-params* nil
  "Dynamic variable: list of uppercase param name strings that are (array T N)
   params at the current kernel boundary. Non-nil only when compiling an
   entry-point kernel. Nil in regular functions.")

;;; src/analysis/core.lisp
(defun %check-aref-boundary-mutation (aref-node location)
  "Called when a semantic-aref is the target of a set!.
   Error 01: If the array-node is a direct var-read in *boundary-array-params*, error.
   Error 02: If the array-node is a call (accessor) whose first arg is a boundary struct, error."
  (when (semantic-aref-p aref-node)
    (let ((array-node (semantic-aref-array-node aref-node)))
      ;; Error 01: direct kernel boundary array param
      (when (and *boundary-array-params* (semantic-var-read-p array-node))
        (let ((vname-str (string-upcase (symbol-name (semantic-var-read-name array-node)))))
          (when (member vname-str *boundary-array-params* :test #'string=)
            (error 'crisp-compiler-error
                   :message (format nil "Cannot write to array parameter '~(~a~)': (array T N) parameters at kernel boundary are immutable"
                                    vname-str)
                   :source-location location))))
      ;; Error 02: array extracted from a boundary struct param
      (when (and *boundary-struct-params* (semantic-call-p array-node))
        (dolist (arg (semantic-call-args array-node))
          (when (semantic-var-read-p arg)
            (let ((vname-str (string-upcase (symbol-name (semantic-var-read-name arg)))))
              (when (member vname-str *boundary-struct-params* :test #'string=)
                (error 'crisp-compiler-error
                       :message (format nil "Cannot write to array member of boundary struct '~(~a~)': struct parameters at kernel boundary are immutable"
                                        vname-str)
                       :source-location location)))))))))




;;; Removes the ANF pre-processing step from the FORWARD compilation pass.
;;; That step was causing (declare (grid-level/workgroup-level)) inside let bodies to:
;;;   (a) be stripped before semantic analysis → context enforcement bypassed, or
;;;   (b) land in malformed let-binding positions → analyze-expression crash.
;;;
;;; The backward pass (%generate-backward-function-ast) does its own anf-transform
;;; separately, so forward compilation does not need to pre-ANF the body.
;;; The %anf-transform redef above handles ctx-declare stripping for the backward pass.

;; src/analysis/core.lisp

(defun internal-def-function (name params declarations body location)
  "Wrapper around internal-compile-function. Detects kernel entry-points and
   binds *boundary-struct-params*, *boundary-array-params*, and
   *in-dispatch-context* to enforce kernel-boundary rules.
   Extended to capture global-size/local-size/num-groups dispatch declarations.
   Extended (091) to handle (grid-function) declaration: sets dispatch context,
   validates void return type.
   Note: ANF pre-processing removed from forward pass — backward pass applies
   its own anf-transform in %generate-backward-function-ast."
  (log:info "Analyzing function ~s" name)

  (multiple-value-bind (explicit-env return-type)
      (parse-function-declarations params declarations)
    (let* ((*compiler-context* (or *compiler-context* (make-compiler-context)))
           (is-entry-p (loop for d in declarations
                             thereis (and (listp d)
                                          (symbolp (first d))
                                          (string-equal (symbol-name (first d)) "ENTRY-POINT"))))
           (is-grid-fn-p (loop for d in declarations
                               thereis (and (listp d)
                                            (symbolp (first d))
                                            (string-equal (symbol-name (first d)) "GRID-FUNCTION"))))
           (*in-dispatch-context* (or is-entry-p is-grid-fn-p))
           (*boundary-struct-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%boundary-struct-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-struct-params*))
           (*boundary-array-params*
             (if is-entry-p
                 (loop for param in explicit-env
                       when (%array-type-p (parameter-def-type param))
                       collect (string-upcase (symbol-name (parameter-def-name param))))
                 *boundary-array-params*)))
      (when (and is-entry-p *boundary-struct-params*)
            (log:debug "Kernel ~a has boundary struct params: ~a" name *boundary-struct-params*))
      (when (and is-entry-p *boundary-array-params*)
            (log:debug "Kernel ~a has boundary array params: ~a" name *boundary-array-params*))

      ;; Void return type enforcement for grid functions
      (when is-grid-fn-p
        (log:info "Compiling grid function ~a (dispatch context)" name)
        (%validate-grid-function-return-type return-type))

      ;; Extract and store dispatch declarations for entry-point kernels
      (when is-entry-p
        (let ((global-size-decl (find "GLOBAL-SIZE" declarations
                                      :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                      :test #'string-equal))
              (local-size-decl  (find "LOCAL-SIZE" declarations
                                      :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                      :test #'string-equal))
              (num-groups-decl  (find "NUM-GROUPS" declarations
                                      :key (lambda (x) (when (consp x) (symbol-name (car x))))
                                      :test #'string-equal)))
          (when (or global-size-decl local-size-decl num-groups-decl)
            (let ((dispatch-plist
                    (append (when global-size-decl (list :global-size global-size-decl))
                            (when local-size-decl  (list :local-size  local-size-decl))
                            (when num-groups-decl  (list :num-groups  num-groups-decl)))))
              (log:info "Kernel ~a: storing dispatch declarations ~a" name dispatch-plist)
              (setf (gethash name *kernel-dispatch-declarations*) dispatch-plist)))))

      (internal-compile-function name explicit-env return-type params body declarations location *compiler-context*))))



(defun calculate-uniformity-state (node env)
  "Recursively determines the uniformity state of an analyzed semantic AST node.
   Returns :uniform, :divergent, or :unknown.
   - Literals are :uniform.
   - Variables are looked up in the env for their stored uniformity. If env lookup
     fails or missing, defaults to :unknown. Kernel arguments are initialized to :uniform.
   - GPU Builtins: per-work-item ids (get-global-id/get-local-id/*-linear-id/
     get-global-id-abs) are :divergent; ids/sizes/offsets constant across the
     workgroup (get-workgroup-id, get-num-groups, get-*-work-size, get-global-offset,
     get-work-dim, get-*-linear-size, get-total-*) are :uniform.
   - Math operations (add, sub, mul, etc): if all args are :uniform, it is :uniform.
     If any arg is :divergent, it is :divergent. Otherwise :unknown.
   - Casts/conversions (to-*, as-*) are passthrough: same uniformity as the operand.
   - Memory reads (aref) are :divergent (or :unknown) unless explicitly cast."
  (etypecase node
    (semantic-literal :uniform)
    (semantic-device-vec-literal
     (let ((states (mapcar (lambda (el) (calculate-uniformity-state el env))
                           (semantic-device-vec-literal-elements node))))
       (cond
         ((some (lambda (s) (eq s :divergent)) states) :divergent)
         ((every (lambda (s) (eq s :uniform)) states) :uniform)
         (t :unknown))))
    (semantic-var-read
     (let ((v (find-variable-in-env (semantic-var-read-name node) env)))
       (if v
           (parameter-def-uniformity v)
           :unknown)))
    (semantic-add
     (let ((ls (calculate-uniformity-state (semantic-add-left-arg node) env))
           (rs (calculate-uniformity-state (semantic-add-right-arg node) env)))
       (cond ((or (eq ls :divergent) (eq rs :divergent)) :divergent)
             ((and (eq ls :uniform) (eq rs :uniform)) :uniform)
             (t :unknown))))
    (semantic-sub
     (let ((ls (calculate-uniformity-state (semantic-sub-left-arg node) env))
           (rs (calculate-uniformity-state (semantic-sub-right-arg node) env)))
       (cond ((or (eq ls :divergent) (eq rs :divergent)) :divergent)
             ((and (eq ls :uniform) (eq rs :uniform)) :uniform)
             (t :unknown))))
    (semantic-mul
     (let ((ls (calculate-uniformity-state (semantic-mul-left-arg node) env))
           (rs (calculate-uniformity-state (semantic-mul-right-arg node) env)))
       (cond ((or (eq ls :divergent) (eq rs :divergent)) :divergent)
             ((and (eq ls :uniform) (eq rs :uniform)) :uniform)
             (t :unknown))))
    (semantic-div
     (let ((ls (calculate-uniformity-state (semantic-div-left-arg node) env))
           (rs (calculate-uniformity-state (semantic-div-right-arg node) env)))
       (cond ((or (eq ls :divergent) (eq rs :divergent)) :divergent)
             ((and (eq ls :uniform) (eq rs :uniform)) :uniform)
             (t :unknown))))
    (semantic-sin
     (calculate-uniformity-state (semantic-sin-arg node) env))
    (semantic-cos
     (calculate-uniformity-state (semantic-cos-arg node) env))
    ;; Endeavor 120: casts/conversions (to-*, as-*) are passthrough. Covers all
    ;; semantic-cast subtypes (value-cast, bitcast, fp-truncate-cast, truncate).
    (semantic-cast
     (calculate-uniformity-state (semantic-cast-arg node) env))
    ((or semantic-lt semantic-gt semantic-le semantic-ge semantic-eq semantic-neq)
     (let ((ls (calculate-uniformity-state (slot-value node 'left-arg) env))
           (rs (calculate-uniformity-state (slot-value node 'right-arg) env)))
       (cond ((or (eq ls :divergent) (eq rs :divergent)) :divergent)
             ((and (eq ls :uniform) (eq rs :uniform)) :uniform)
             (t :unknown))))
    (semantic-if
     (let ((cs (calculate-uniformity-state (semantic-if-condition-node node) env))
           (ts (calculate-uniformity-state (semantic-if-then-node node) env))
           (es (calculate-uniformity-state (semantic-if-else-node node) env)))
       (cond ((or (eq cs :divergent) (eq ts :divergent) (eq es :divergent)) :divergent)
             ((and (eq cs :uniform) (eq ts :uniform) (eq es :uniform)) :uniform)
             (t :unknown))))
    (semantic-let
     :unknown)
    (semantic-gpu-builtin
     (let ((name (semantic-gpu-builtin-builtin-name node)))
       (cond
         ;; Per-work-item: differ across the workgroup.
         ((member name '(:get-global-id :get-local-id :get-global-id-abs
                         :get-local-linear-id :get-global-linear-id))
          :divergent)
         ;; Constant across the workgroup: ids/sizes/offsets/dims/totals.
         ((member name '(:get-workgroup-id :get-num-groups
                         :get-local-work-size :get-global-work-size
                         :get-global-offset :get-work-dim
                         :get-local-linear-size :get-global-linear-size
                         :get-total-threads :get-total-groups))
          :uniform)
         (t :unknown))))
    (semantic-to-workgroup-uniform :uniform)
    (semantic-to-warp-uniform :uniform)
    ;; Memory reads and anything else
    (t :unknown)))

(defun analyze-body-expressions (body-list env context location)
  "Recursively analyzes a list of expressions."
  (loop for expr in body-list
        for i from 0
          unless (null expr)
        collect (analyze-expression expr env context (append location (list i)))))


(defun analyze-expression (expr env context location)
  "Recursively analyzes a *single* expression."
  (log:debug "analyze-expression expr: ~s location: ~s" expr location)
  ;; Handle empty body case, which `read` can return as NIL
  (when (null expr)
        (return-from analyze-expression (make-semantic-progn :type '(nil) :body nil :source-location location)))

  (let ((res
         (cond
          ;; Case 1: It's a literal, like 7
          ((integerp expr)
            (make-semantic-literal :value-type 'int :value expr :source-location location))

          ;; Case 1.1: It's a float literal, like 3.14
          ((floatp expr)
            ;; For now, all floating point literals default to the 'float' type.
            (make-semantic-literal :value-type 'float :value expr :source-location location))

          ;; Case 1.5: It's a keyword symbol, like :foo
          ((keywordp expr)
            (make-semantic-literal :value-type (list 'keyword expr) :value expr :source-location location))

          ;; Case 2: It's a typed numeric literal (e.g. 255uc, 1000UL, 1.5f) or a variable.
          ;; Try the literal parser first; fall through to env lookup if it doesn't match.
          ((symbolp expr)
            (let ((literal-node (%try-parse-typed-literal expr location)))
              (if literal-node
                  literal-node
                  (let ((found (find-variable-in-env expr env)))
                    (if found
                        (let ((type-val (parameter-def-type found)))
                          (log:warn "ANALYZE-EXPR VAR: ~a -> Type: ~a" expr type-val)
                          (make-semantic-var-read :name expr :type type-val :source-location location))
                        (progn
                         (log:error "Unknown Variable Lookup: ~a (pkg: ~a)" expr (package-name (symbol-package expr)))
                         (log:error "Env Keys: ~a" (mapcar (lambda (p) (let ((s (parameter-def-name p))) (if (symbolp s) (format nil "~a (pkg: ~a)" s (package-name (symbol-package s))) (format nil "NON-SYMBOL-KEY: ~a" s)))) env))
                         (error 'crisp-unknown-variable
                           :name expr
                           :source-location location)))))))

          ;; Case 3: It's a function call, like '(+ a b)'
          ((listp expr) (let ((op (first expr)))
                          (log:warn "analyze-expression list op: ~a (pkg: ~a) macro-function: ~a" op (package-name (symbol-package op)) (macro-function op))
                          (when (eq op 'quote)
                                (log:warn "ANALYZE-EXPR (NEW): QUOTE check. Analyzer: ~a" (gethash op *expression-analyzers*)))
                          (log:debug "analyze-expression list op: ~a~%  *expression-analyzers*: ~a~% *function-table*: ~a~%" op *expression-analyzers* *function-table*)

                          ;; HOISTED CHECK: Try incomplete accessor first
                          (let ((hook-res (analyze-incomplete-type-accessor op expr env context location)))
                            (if hook-res
                                hook-res
                                ;; Otherwise continue with standard checks
                                (cond ;; Case 3a: Is there a specific handler for this operator (e.g., '+', 'to-char')?
                                     ((gethash op *expression-analyzers*)
                                       (funcall (gethash op *expression-analyzers*) expr env context location))
                                     ;; Case 3b: Is it a macro?
                                     ((macro-function op)
                                       (let ((expanded (macroexpand-1 expr)))
                                         (log:warn "ANALYZE-EXPR MACRO: ~s -> ~s" expr expanded)
                                         (analyze-expression expanded env context location)))
                                     ;; Case 3c: Is it a call to a known user-defined function?
                                     ;; Also check implicit *template-registry* for overloading
                                     ;; AND *generic-functions* for lazy instantiation
                                     ((or (gethash op *function-table*)
                                          (gethash op *template-registry*)
                                          (gethash op *generic-functions*))
                                       (analyze-function-call op expr env context location))
                                     ;; Case 3e: Otherwise, we don't know what this is.
                                     (t
                                       (let ((pkg (symbol-package op)))
                                         (log:debug "  UNSUPPORTED FORM: ~s (pkg: ~a)" op (if pkg (package-name pkg) "NIL"))
                                         (log:debug "  Macro Function? ~a" (macro-function op))
                                         (log:debug "  Bound Function? ~a" (fboundp op)))
                                       (log:debug "  Function Table Keys: ~a" (alexandria:hash-table-keys *function-table*))
                                       (error 'crisp-unsupported-form-error
                                         :form op
                                         :source-location (append location '(0)))))))))
          (t (error 'crisp-unsupported-form-error
               :form expr
               :source-location location)))))
    res))





(defun analyze-function-call (op expr env context location)
  "Analyzes a function call expression.
   Checks for struct immutability violations via %check-struct-mutating-call.
   Extended (091): grid functions can only be called from a dispatch context."
  (log:debug "Analyzing function call to ~s. Current function: ~s" op (compiler-context-current-compiling-function context))

  ;; Recursion / call-graph tracking
  (if (multi-pass-mode-p)
      (when (compiler-context-current-compiling-function context)
            (pushnew op (gethash (compiler-context-current-compiling-function context) *call-graph*)))
      (when (eq op (compiler-context-current-compiling-function context))
            (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

  ;; Grid function dispatch-context check
  (when (and (gethash op *grid-functions*)
             (not *in-dispatch-context*))
    (error 'crisp-compiler-error
      :message (format nil "Grid function '~(~a~)' cannot be called outside a dispatch context. Use def-kernel or def-grid-function to provide a dispatch context." op)
      :source-location location))

  ;; Implicit args
  (let ((implicit-args-required (gethash op *implicit-arg-map*)))
    (when (and (single-pass-mode-p) implicit-args-required)
          (setf (gethash (compiler-context-current-compiling-function context) *implicit-arg-map*) implicit-args-required))

    (let* ((arg-forms (rest expr))
           (explicit-arg-nodes (loop for arg-form in arg-forms
                                     for i from 1
                                     collect (analyze-expression arg-form env context (append location (list i)))))
           (explicit-arg-types (mapcar #'get-single-value-type explicit-arg-nodes))
           (signature (resolve-best-signature op explicit-arg-types context)))

      ;; Struct mutating function check
      (%check-struct-mutating-call op explicit-arg-nodes env context location)

      (let ((final-arg-nodes
             (if implicit-args-required
                 (let ((implicit-arg-nodes
                        (loop for (param-name . param-type) in implicit-args-required
                              collect (let ((found (find-variable-in-env param-name env)))
                                        (if found
                                            (make-semantic-var-read :name param-name :type (parameter-def-type found) :source-location location)
                                            (error "Compiler bug: Carrier function ~s is missing implicit argument ~s."
                                              (compiler-context-current-compiling-function context) param-name))))))
                   (append implicit-arg-nodes explicit-arg-nodes))
                 explicit-arg-nodes)))

        (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
          (error 'crisp-signature-arity-error
            :expected (length (function-signature-parameters signature))
            :inferred (length explicit-arg-types)
            :source-location location))

        ;; === Uniformity Constraint Checking ===
        (let ((sig-params (function-signature-parameters signature)))
          (loop for param in sig-params
                for arg-node in explicit-arg-nodes
                do (when (eq (parameter-def-uniformity param) :uniform)
                     (let ((arg-uniformity (calculate-uniformity-state arg-node env)))
                       (unless (eq arg-uniformity :uniform)
                         (error 'crisp-compiler-error
                           :message (format nil "Function ~a requires parameter ~a to be :uniform, but inferred state was ~a. Use (to-workgroup-uniform ...) if you must."
                                            (function-signature-name signature)
                                            (parameter-def-name param)
                                            arg-uniformity)
                           :source-location location))))))

        (let ((augmented-signature
               (if implicit-args-required
                   (let ((implicit-params (loop for (param-name . param-type) in implicit-args-required
                                                collect (make-parameter-def :name param-name :type param-type :kind :in))))
                     (make-function-signature
                      :name (function-signature-name signature)
                      :parameters (append implicit-params (function-signature-parameters signature))
                      :return-types (function-signature-return-types signature)
                      :source-location (function-signature-source-location signature)
                      :is-template-p (function-signature-is-template-p signature)
                      :template-params (function-signature-template-params signature)))
                   signature)))

          ;; === Brand Instance Type Checking (when --differentiate is active) ===
          (let ((refined-return-types (function-signature-return-types augmented-signature)))

            (when *differentiate-p*
              (let ((sig-params (function-signature-parameters augmented-signature)))

                ;; 1. Brand parameter type checking
                (loop for param in sig-params
                      for arg-node in final-arg-nodes
                      for param-type = (parameter-def-type param)
                      do (let ((brand-def (is-brand-type-p param-type)))
                           (when (and brand-def (brand-active-p brand-def))
                             (let ((owner-var (%find-brand-owner-var (brand-definition-brand-name brand-def)
                                                                        sig-params final-arg-nodes)))
                               (when owner-var
                                 (let* ((expected-type (resolve-brand-type param-type owner-var))
                                           (actual-type (get-single-value-type arg-node)))
                                   (unless (or (eq actual-type expected-type)
                                               (is-substitutable-for? actual-type expected-type))
                                     (error 'crisp-type-error
                                       :expected (list expected-type)
                                       :inferred (list actual-type)
                                       :source-location location))))))))

                ;; 2. Brand return type refinement
                (setf refined-return-types
                  (loop for ret-type in (function-signature-return-types augmented-signature)
                        collect (let ((brand-def (is-brand-type-p ret-type)))
                                  (if (and brand-def (brand-active-p brand-def))
                                      (let ((owner-var (%find-brand-owner-var (brand-definition-brand-name brand-def)
                                                                                 sig-params final-arg-nodes)))
                                        (if owner-var
                                            (resolve-brand-type ret-type owner-var)
                                            ret-type))
                                      ret-type))))))

            (make-semantic-call :name (function-signature-name augmented-signature)
                                :type refined-return-types
                                :args final-arg-nodes
                                :signature augmented-signature
                                :source-location location)))))))

;; --- Helper to get the type from any node ---


(defun semantic-node-type (node)
  "Returns the Crisp type of a semantic node.
   Extended for 092-dotimes and 114 Phase B (semantic-nvvm-cp-async-*)."
  (etypecase node
    (semantic-to-workgroup-uniform (semantic-to-workgroup-uniform-type node))
    (semantic-to-warp-uniform (semantic-to-warp-uniform-type node))
    (semantic-dotimes (semantic-dotimes-type node))
    (semantic-literal (semantic-literal-value-type node))
    (semantic-device-vec-literal (semantic-device-vec-literal-vec-type node))
    (semantic-var-read (semantic-var-read-type node))
    (semantic-add (semantic-add-type node))
    (semantic-sub (semantic-sub-type node))
    (semantic-mul (semantic-mul-type node))
    (semantic-div (semantic-div-type node))
    (semantic-sin (semantic-sin-type node))
    (semantic-cos (semantic-cos-type node))
    (semantic-lt 'int)
    (semantic-gt 'int)
    (semantic-le 'int)
    (semantic-ge 'int)
    (semantic-eq 'int)
    (semantic-neq 'int)
    (semantic-if (semantic-if-type node))
    (semantic-set! 'void)
    (semantic-aref (semantic-aref-type node))
    (semantic-value-cast (semantic-value-cast-type node))
    (semantic-let (semantic-let-type node))
    (semantic-bitcast (semantic-bitcast-type node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-type node))
    (semantic-truncate (semantic-truncate-type node))
    (semantic-explicit-return (semantic-explicit-return-type node))
    (semantic-call (semantic-call-type node))
    (semantic-funcall (semantic-funcall-type node))
    (semantic-extract-value (semantic-extract-value-type node))
    (semantic-insert-value (semantic-insert-value-type node))
    (semantic-struct-construction (semantic-struct-construction-type node))
    (semantic-ct-array (semantic-ct-array-type node))
    (semantic-progn (semantic-progn-type node))
    (semantic-struct-member-update (semantic-struct-member-update-type node))
    (semantic-sizeof (semantic-sizeof-type node))
    (semantic-make-view (semantic-make-view-type node))
    (semantic-atomic-rmw (semantic-atomic-rmw-type node))
    (semantic-stride-view (semantic-stride-view-type node))
    (semantic-gpu-builtin (semantic-gpu-builtin-type node))
    (semantic-nvvm-cp-async-tile-copy (semantic-nvvm-cp-async-tile-copy-type node))
    (semantic-make-async-barrier      (semantic-make-async-barrier-type node))
    (semantic-nvvm-cp-async-wait      (semantic-nvvm-cp-async-wait-type node))))

(defun semantic-node-source-location (node)
  "Returns the source location of a semantic node.
   Extended for 092-dotimes and 114 Phase B."
  (etypecase node
    (semantic-dotimes (semantic-dotimes-source-location node))
    (semantic-literal (semantic-literal-source-location node))
    (semantic-device-vec-literal (semantic-device-vec-literal-source-location node))
    (semantic-var-read (semantic-var-read-source-location node))
    (semantic-value-cast (semantic-value-cast-source-location node))
    (semantic-bitcast (semantic-bitcast-source-location node))
    (semantic-let (semantic-let-source-location node))
    (semantic-fp-truncate-cast (semantic-fp-truncate-cast-source-location node))
    (semantic-truncate (semantic-truncate-source-location node))
    (semantic-add (semantic-add-source-location node))
    (semantic-sub (semantic-sub-source-location node))
    (semantic-mul (semantic-mul-source-location node))
    (semantic-div (semantic-div-source-location node))
    (semantic-sin (semantic-sin-source-location node))
    (semantic-cos (semantic-cos-source-location node))
    (semantic-lt (semantic-lt-source-location node))
    (semantic-gt (semantic-gt-source-location node))
    (semantic-le (semantic-le-source-location node))
    (semantic-ge (semantic-ge-source-location node))
    (semantic-eq (semantic-eq-source-location node))
    (semantic-neq (semantic-neq-source-location node))
    (semantic-if (semantic-if-source-location node))
    (semantic-set! (semantic-set!-source-location node))
    (semantic-aref (semantic-aref-source-location node))
    (semantic-explicit-return (semantic-explicit-return-source-location node))
    (semantic-call (semantic-call-source-location node))
    (semantic-funcall (semantic-funcall-source-location node))
    (semantic-extract-value (semantic-extract-value-source-location node))
    (semantic-insert-value (semantic-insert-value-source-location node))
    (semantic-struct-construction (semantic-struct-construction-source-location node))
    (semantic-ct-array (semantic-ct-array-source-location node))
    (semantic-progn (semantic-progn-source-location node))
    (semantic-struct-member-update (semantic-struct-member-update-source-location node))
    (semantic-sizeof (semantic-sizeof-source-location node))
    (semantic-make-view (semantic-make-view-source-location node))
    (semantic-atomic-rmw (semantic-atomic-rmw-source-location node))
    (semantic-stride-view (semantic-stride-view-source-location node))
    (semantic-gpu-builtin (semantic-gpu-builtin-source-location node))
    (semantic-nvvm-cp-async-tile-copy (semantic-nvvm-cp-async-tile-copy-source-location node))
    (semantic-make-async-barrier      (semantic-make-async-barrier-source-location node))
    (semantic-nvvm-cp-async-wait      (semantic-nvvm-cp-async-wait-source-location node))))

;; --- Helper to get the type from a node expected to be a single value ---
(defun get-single-value-type (node)
  "Returns the type of a semantic node, assuming a single-value context.
  If the node's type is a list (e.g., from a multi-value function call),
  this returns the first type in the list. Otherwise, it returns the type as-is."
  ;; Safety: Ensure we have a semantic node, not a type specifier
  (when (and (listp node) (not (typep node 'structure-object)))
        (log:warn "get-single-value-type called with list (likely a type spec): ~a. Treating as type." node)
        (labels ((unwrap (t-spec)
                         (if (and (listp t-spec) (= (length t-spec) 1) (valid-type-p t-spec)
                                  (symbolp (first t-spec))
                                  (not (get-template-arity (first t-spec))))
                             (unwrap (first t-spec))
                             t-spec)))
          (return-from get-single-value-type (unwrap node))))

  (let ((type (semantic-node-type node)))
    (labels ((unwrap (t-spec)
                     (if (and (listp t-spec) (= (length t-spec) 1) (valid-type-p t-spec)
                              (symbolp (first t-spec))
                              (not (get-template-arity (first t-spec))))
                         (unwrap (first t-spec))
                         t-spec)))
      (if (and (listp type) (not (valid-type-p type))
               (not (eq (first type) 'keyword))) ;; Preserve keyword literal values
          (unwrap (first type))
          (unwrap type)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; DWARF Location Mapping
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun walk-and-map-locations (expr location map counter)
  "Recursively walks an S-expression, populating a map from location paths to line numbers."
  ;; Add the current expression's location to the map
  (setf (gethash location map) (incf counter))

  ;; For lists, recurse on children, but with a special check for `declare`.
  (when (listp expr)
        (loop for sub-expr in expr
              for i from 0
              do (setf counter
                   (if (and (eq (first expr) 'declare) (listp sub-expr))
                       ;; For forms inside a `declare` block (like `(return-type int)`),
                       ;; map them but do not recurse into them.
                       (progn
                        (setf (gethash (append location (list i)) map) (incf counter))
                        counter)
                       ;; For everything else, recurse normally.
                       (walk-and-map-locations sub-expr (append location (list i)) map counter)))))
  counter)

(defun generate-location-map (forms)
  "Creates a map from S-expression location paths to virtual line numbers."
  (let ((location-map (make-hash-table :test 'equal)) ; Use 'equal' for list keys
                                                     (line-counter 0))
    (loop for form in forms
          for i from 0
          do (setf line-counter (walk-and-map-locations form (list i) location-map line-counter)))
    location-map))

(defun compile-crisp-form-to-ir-string (crisp-form &key (debug-p nil))
  "Takes a single Crisp s-expression (like a def-function form),
  compiles it, and returns its LLVM IR as a string.
  This is a developer utility for REPL use and testing."
  (let* ((module (llvm-module-create "repl-module"))
         (builder (llvm-create-builder))
         (di-builder (when debug-p (llvm-create-di-builder module)))
         (location-map (when debug-p (generate-location-map (list crisp-form))))
         (di-compile-unit (when debug-p
                                (let* ((f "repl.crisp") (d "/tmp/")
                                                        (di-file (llvm-di-builder-create-file di-builder f (length f) d (length d))))
                                  (llvm-di-builder-create-compile-unit di-builder 32768 di-file "Crisp" 5 nil "" 0 0 "" 0 1 0 nil nil "" 0 "" 0)))))
    (unwind-protect
        (progn
         (let* ((*compiler-context* (make-compiler-context))
                (*compiler-session* (make-compiler-session :module module :builder builder :di-builder di-builder :di-compile-unit di-compile-unit :location-map location-map))
                (form-with-location (append crisp-form (list :source-location ''(0))))
                (expanded-form (macroexpand-1 form-with-location))
                (semantic-fn (progn
                                (format *error-output* "~&DEBUG CONTEXT is: ~s type: ~s~%" *compiler-context* (type-of *compiler-context*))
                                (format *error-output* "~&DEBUG EXPANSION: ~s~%" expanded-form)
                                (let ((val (eval expanded-form)))
                                  (format *error-output* "~&DEBUG EVAL RESULT: ~s~%" val)
                                  val))))
           (generate-llvm-ir semantic-fn module builder di-builder di-compile-unit location-map))
         (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
      ;; Cleanup.
      (when di-builder (llvm-di-builder-finalize di-builder))
      (when di-builder (llvm-dispose-di-builder di-builder))
      (llvm-dispose-builder builder)
      (llvm-dispose-module module))))



;; src/analysis/core.lisp
(defun %try-parse-typed-literal (expr location)
  "If EXPR is a symbol whose name matches <integer><suffix> or <number><suffix>,
   returns a semantic-literal node with the appropriate Crisp type and value.
   Suffixes (symbols are already upcased by the SBCL reader):
     BF -> bfloat16   UC -> uchar   UL -> ulong   US -> ushort
     U  -> uint       S  -> short   L  -> long     C  -> char
     H  -> half       F  -> float   D  -> double
   Multi-character suffixes are tested first to avoid BF matching F,
   UL matching L, etc.  Returns NIL if EXPR does not match."
  (unless (symbolp expr)
    (return-from %try-parse-typed-literal nil))
  (let ((name (symbol-name expr)))
    (flet ((try-int (suffix type)
             (let ((slen (length suffix)))
               (when (and (> (length name) slen)
                          (string= name suffix :start1 (- (length name) slen)))
                 (let ((num-str (subseq name 0 (- (length name) slen))))
                   (multiple-value-bind (val end)
                       (parse-integer num-str :junk-allowed t)
                     (when (and val (= end (length num-str)))
                       (log:debug "%try-parse-typed-literal: ~a -> (~a ~a)" name type val)
                       (make-semantic-literal :value-type type
                                              :value val
                                              :source-location location)))))))
           (try-float (suffix type)
             (let ((slen (length suffix)))
               (when (and (> (length name) slen)
                          (string= name suffix :start1 (- (length name) slen)))
                 (let* ((num-str (subseq name 0 (- (length name) slen)))
                        (val (ignore-errors
                               (let ((v (with-input-from-string (in num-str)
                                          (read in nil nil))))
                                 (when (realp v) v)))))
                   (when val
                     (log:debug "%try-parse-typed-literal: ~a -> (~a ~a)" name type val)
                     (make-semantic-literal :value-type type
                                            :value val
                                            :source-location location)))))))
      ;; Multi-char suffixes first to prevent substring ambiguity
      (or (try-float "BF" 'bfloat16)
          (try-int   "UC" 'uchar)
          (try-int   "UL" 'ulong)
          (try-int   "US" 'ushort)
          (try-int   "U"  'uint)
          (try-int   "S"  'short)
          (try-int   "L"  'long)
          (try-int   "C"  'char)
          (try-float "H"  'half)
          (try-float "F"  'float)
          (try-float "D"  'double)))))





(defun %extract-fn-body-and-declarations (body-and-loc)
  "Helper: Splits the body-and-loc of a function into declare-forms, flat declarations, and the actual fn-body."
  (let* ((declare-forms (loop for f in body-and-loc
                              while (and (listp f)
                                         (symbolp (first f))
                                         (string-equal (symbol-name (first f)) "DECLARE"))
                              collect f))
         (declarations (loop for f in declare-forms append (rest f)))
         (fn-body (nthcdr (length declare-forms) body-and-loc)))
    (values declare-forms declarations fn-body)))

(defun %detect-hof-param-via-funcall (params fn-body)
  "Helper: Scans parameters for one that is funcall'd in the body.
   Returns (values fn-param-idx fn-param-sym float-param-syms)."
  (let (fn-param-idx fn-param-sym)
    (loop for p in params
          for i from 0
          do (when (%tree-has-funcall-p fn-body p)
               (setf fn-param-idx i)
               (setf fn-param-sym p)
               (cl:return)))
    (let ((float-param-syms (when fn-param-idx
                              (loop for p in params
                                    for i from 0
                                    unless (= i fn-param-idx)
                                    collect p))))
      (values fn-param-idx fn-param-sym float-param-syms))))

(defun %register-hof-entry (name type-desc params fn-param-idx fn-param-sym float-param-syms clean-body n-float-params n-return)
  "Helper: Registers a HOF in *differentiable-hof-store* and *differentiable-functions*."
  (log:info "AUTODIFF: Pre-registering HOF ~a ~a (fn-param=~a idx=~a)" type-desc name fn-param-sym fn-param-idx)
  (setf (gethash name *differentiable-hof-store*)
        (list :param-syms       params
              :fn-param-idx     fn-param-idx
              :fn-param-sym     fn-param-sym
              :float-param-syms float-param-syms
              :body-forms       clean-body))
  (setf (gethash name *differentiable-functions*)
        (list :hof t
              :n-float-params n-float-params
              :n-return n-return)))

(defun %register-standard-differentiable-entry (name type-desc n-float-params n-return &key optimistic-p)
  "Helper: Registers a non-HOF function in *differentiable-functions*."
  (let* ((pkg (symbol-package name))
         (bkwd-name (intern (format nil "~A_GRAD" (symbol-name name)) pkg)))
    (if optimistic-p
        (log:info "AUTODIFF: Pre-registering non-HOF ~a ~a (n-params=~a, optimistic)" type-desc name n-float-params)
        (log:info "AUTODIFF: Pre-registering ~a ~a -> ~a (n-fp=~a n-ret=~a)" type-desc name bkwd-name n-float-params n-return))
    (setf (gethash name *differentiable-functions*)
          (list :bkwd-name bkwd-name
                :n-float-params n-float-params
                :n-return n-return))))

(defun %pre-register-differentiable-fns (forms &optional record-info)
  "When *differentiate-p* is T, walk FORMS for def-function forms and
pre-register them in *differentiable-functions* (and *differentiable-hof-store*
for HOF functions). Handles top-level def-function, progn, and with-template-type.
Guards parse-function-declarations against unknown-type errors from brand types
that are not yet registered at pre-registration time.

101 widening: records / structs / derived-from-record-or-struct contribute
their runtime-field count to the differentiable-param count, and a function
with any tensor or cell parameter is differentiable (handle-grad pathway).

RECORD-INFO is an alist of (NAME-STR . FIELD-COUNT) built by
%scan-forms-for-record-info at top-level call.  Recursive calls reuse it."
  (let ((record-info (or record-info (%scan-forms-for-record-info forms))))
    (when *differentiate-p*
      (dolist (form forms)
        (cond
          ;; Top-level def-function: existing HOF-aware logic, widened gate.
          ((and (consp form) (eq (car form) 'def-function))
           (let* ((name (second form))
                  (params (third form))
                  (body-and-loc (cdddr form)))
             (multiple-value-bind (declare-forms declarations fn-body)
                 (%extract-fn-body-and-declarations body-and-loc)
               (declare (ignore declare-forms))
               (let ((is-system (member '(crisp-system-generated) declarations :test #'equal)))
                 (unless (or is-system (%fn-name-is-grad-p name))
                   (handler-case
                       (multiple-value-bind (env return-types)
                           (parse-function-declarations params declarations)
                         (let* ((float-param-entries
                                 (loop for pd in env
                                       when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                                 (%crisp-float-type-p (parameter-def-type pd)))
                                       collect pd))
                                ;; 101: widened — counts record/struct field
                                ;; contributions and float scalars; handle types
                                ;; (tensors, cells) contribute 0 here and flow
                                ;; grad via the &out grad-handle pathway instead.
                                (n-diff-params
                                 (loop for pd in env
                                       when (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                       sum (%count-differentiable-contributions
                                            (parameter-def-type pd) record-info)))
                                (n-return (length (remove nil return-types)))
                                (fn-param-entries
                                 (loop for pd in env
                                       for i from 0
                                       when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                                 (%crisp-function-type-p (parameter-def-type pd)))
                                       collect (cons i pd)))
                                (is-hof (consp fn-param-entries)))
                           ;; Gate: register if any scalar-delta contribution
                           ;; OR any handle (tensor/cell) param.
                           (when (or (> n-diff-params 0)
                                     (%has-tensor-diff-param-p env))
                             (if is-hof
                                 ;; HOF path unchanged — open Q4 deferred.
                                 (let* ((fn-param-idx (car (car fn-param-entries)))
                                        (fn-param-sym (parameter-def-name (cdr (car fn-param-entries))))
                                        (float-param-syms (mapcar #'parameter-def-name float-param-entries))
                                        (clean-body  (loop for f in fn-body
                                                           unless (and (atom f) (not (symbolp f)))
                                                           collect f))
                                        (param-syms (loop for pd in env collect (parameter-def-name pd))))
                                   (%register-hof-entry name "definition" param-syms fn-param-idx fn-param-sym float-param-syms clean-body (length float-param-entries) n-return))
                                 (%register-standard-differentiable-entry name "definition" n-diff-params n-return)))))
                     (error (e)
                       (log:debug "AUTODIFF: Skipping pre-registration of ~a -- type parse error: ~a" name e))))))))

          ;; progn: recurse, passing record-info through
          ((and (consp form) (eq (car form) 'progn))
           (%pre-register-differentiable-fns (rest form) record-info))

          ;; with-template-type: walk body for def-functions using funcall scanning.
          ;; Cannot use parse-function-declarations here -- types contain T placeholder.
          ;; HOF branch: funcall detected -> register in *differentiable-hof-store*.
          ;; Non-HOF branch: register optimistically; concrete instantiation will update
          ;;   the entry with accurate counts before the backward walk runs.
          ((and (consp form) (eq (car form) 'with-template-type))
           (dolist (bform (cddr form))
             (when (and (consp bform) (eq (car bform) 'def-function))
               (let* ((name   (second bform))
                      (params (third bform))
                      (body-and-loc (cdddr bform)))
                 (multiple-value-bind (declare-forms declarations fn-body)
                     (%extract-fn-body-and-declarations body-and-loc)
                   (declare (ignore declare-forms declarations))
                   (multiple-value-bind (fn-param-idx fn-param-sym float-param-syms)
                       (%detect-hof-param-via-funcall params fn-body)
                     (cond
                       ((and fn-param-idx (not (gethash name *differentiable-functions*)))
                        (%register-hof-entry name "template via with-template-type" params fn-param-idx fn-param-sym float-param-syms fn-body (1- (length params)) 1))
                       ((not (gethash name *differentiable-functions*))
                        (let ((n-params (count-if (lambda (p) (not (string-equal (symbol-name p) "&OUT"))) params)))
                          (%register-standard-differentiable-entry name "template via with-template-type" n-params 1 :optimistic-p t)))))))))))))))

(defun %pre-register-hof-templates ()
  "When *differentiate-p* is T, scan *template-registry* for def-function templates
that use (funcall <param> ...) in their body, indicating a HOF parameter. Pre-register
each such template in *differentiable-hof-store* and *differentiable-functions*.
Must be called after walk-code-forms so *template-registry* is populated."
  (when *differentiate-p*
    (maphash
     (lambda (name templates)
       (dolist (tmpl templates)
         (let* ((body (template-data-body tmpl)))
           ;; Only process def-function templates (not def-kernel, def-struct, etc.)
           (when (and (consp body)
                      (symbolp (first body))
                      (string-equal (symbol-name (first body)) "DEF-FUNCTION"))
             (let* ((params (third body))
                       (body-and-loc (nthcdr 3 body)))
               (multiple-value-bind (declare-forms declarations fn-body)
                   (%extract-fn-body-and-declarations body-and-loc)
                 (declare (ignore declare-forms declarations))
                 (multiple-value-bind (fn-param-idx fn-param-sym float-param-syms)
                     (%detect-hof-param-via-funcall params fn-body)
                   ;; If found and not already registered, pre-register as HOF
                   (when (and fn-param-idx (not (gethash name *differentiable-functions*)))
                     (%register-hof-entry name "template" params fn-param-idx fn-param-sym float-param-syms fn-body (1- (length params)) 1)))))))))
     *template-registry*)))




(defun %tree-has-funcall-p (tree target-sym)
  "Returns T if any subtree in TREE contains (funcall TARGET-SYM ...)."
  (cond
    ((null tree) nil)
    ((atom tree) nil)
    ;; Is this a (funcall target ...) form?
    ((and (symbolp (first tree))
          (string= (symbol-name (first tree)) "FUNCALL")
          (eq (second tree) target-sym))
     t)
    ;; Recurse into sub-trees
    (t (some (lambda (sub) (%tree-has-funcall-p sub target-sym)) tree))))




;; src/analysis/core.lisp
(defun %dvec-type-lookup (type-sym)
  "Returns the crisp-type entry for TYPE-SYM if it is a registered device-vector
   type, trying both :crisp-language and :crisp.compiler packages.
   Returns NIL when TYPE-SYM is not a device-vector type."
  (when (symbolp type-sym)
    (or (gethash type-sym *crisp-types*)
        (let ((alt (intern (symbol-name type-sym) (find-package :crisp.compiler))))
          (gethash alt *crisp-types*)))))

;; src/analysis/core.lisp
(defun %dvec-check-cell-write-access (aref-node location)
  "Signals crisp-compiler-error if the cell accessed through AREF-NODE is
   read-only.  The check examines the mangled struct name for 'READ-ONLY'."
  (let* ((cell-type (semantic-node-type (semantic-aref-array-node aref-node)))
         (resolved  (resolve-type-alias cell-type))
         (canon     (canonicalize-type-specifier resolved))
         (cell-spec (when (and (listp canon) (eq (first canon) 'cell)) canon)))
    (when cell-spec
      (let ((mangled (mangle-template-struct-name (first cell-spec) (rest cell-spec))))
        (when (search "READ-ONLY" (symbol-name mangled))
          (error 'crisp-compiler-error
                 :message (format nil
                   "Cannot write through read-only cell of type ~a" cell-type)
                 :source-location location))))))




(defun analyze-dvec-component-ref (expr env context location)
  "Analyzes (x~ v), (y~ v), (z~ v), (w~ v) -- device-vector component accessors.
   The operator symbol determines the 0-based LLVM element index (0..3).
   Returns a semantic-extract-value node whose type is the scalar component type.

   Brand-instance gensyms (e.g. VALUE-T-204 derived from float2) are resolved
   to their concrete device-vector base type via *type-derivation-graph* before
   width and component-scalar extraction.

   In :write mode (inside a set! target), also validates that a cell-deref
   aggregate is not read-only."
  (let* ((op       (first expr))
         (op-name  (symbol-name op))
         (index    (cond ((string= op-name "X~") 0)
                         ((string= op-name "Y~") 1)
                         ((string= op-name "Z~") 2)
                         ((string= op-name "W~") 3)
                         (t (error "analyze-dvec-component-ref: unknown accessor ~a" op))))
         ;; Always read the aggregate; the write context is on the component, not the vector.
         (arg-node (let ((*analysis-access-mode* :read))
                     (analyze-expression (second expr) env context
                                         (append location '(1)))))
         (arg-type (semantic-node-type arg-node))
         (ct       (%dvec-type-lookup arg-type)))

    ;; If the argument is NOT a device-vector:
    ;; - When ct is nil (user-defined struct/record not in *crisp-types*), or
    ;;   ct is a struct/record category -- fall back to the function call path
    ;;   so that user-defined x~/y~/z~/w~ struct accessors still work.
    ;; - For clearly non-aggregate built-in types (scalar, void, pointer, meta)
    ;;   signal a type error immediately so the user gets a clear message.
    (unless (and ct (eq (crisp-type-category ct) :device-vector))
      (let ((should-fallback
             (or (null ct)
                 (member (crisp-type-category ct) '(:struct :record)))))
        (if should-fallback
            (return-from analyze-dvec-component-ref
              (analyze-function-call op expr env context location))
            (error 'crisp-compiler-error
                   :message (format nil "~a requires a device-vector argument; got ~a"
                                    (string-downcase op-name) arg-type)
                   :source-location location))))

    ;; Resolve brand-instance / derived types to their concrete device-vector
    ;; base type for width and component-scalar extraction.
    ;; e.g. VALUE-T-204 (descendant of float2) -> float2 -> width 2, comp "FLOAT"
    (let* ((dvec-type (let ((node (gethash arg-type *type-derivation-graph*)))
                        (if node (type-node-base-type node) arg-type)))
           (type-name (symbol-name dvec-type))
           (width     (digit-char-p (cl:char type-name (1- (length type-name))))))

      ;; Validate: component index must be in range for this vector width.
      (unless (and width (< index width))
        (error 'crisp-compiler-error
               :message (format nil
                 "~a is out of range for ~a (width ~a); valid accessors: ~a"
                 (string-downcase op-name) arg-type width
                 (subseq '("x~" "y~" "z~" "w~") 0 (or width 0)))
               :source-location location))

      ;; In write mode: check that a cell-dereference aggregate is writable.
      (when (and (eq *analysis-access-mode* :write) (semantic-aref-p arg-node))
        (%dvec-check-cell-write-access arg-node location))

      ;; Component scalar type: strip trailing width digit(s) from the CONCRETE type name.
      ;; e.g.  "FLOAT2" -> "FLOAT",  "USHORT4" -> "USHORT",  "HALF3" -> "HALF"
      (let* ((base-name (string-right-trim "1234" type-name))
             (comp-sym  (intern base-name (find-package :crisp-language))))
        (log:debug "analyze-dvec-component-ref: ~a on ~a (dvec ~a) -> index ~a, comp ~a"
                   op-name arg-type dvec-type index comp-sym)
        (make-semantic-extract-value
         :type           comp-sym
         :aggregate-node arg-node
         :index          index
         :source-location location)))))


(defun %mv-resolve-src-type (src-type)
  "Resolve a source storage-handle type to a canonical list.
   Handles type aliases, mangled symbols (e.g. TENSOR_INT_1_...),
   (vector ...) / (matrix ...) sugar, and already-canonical lists.
   Returns (CELL elem addr access) or (TENSOR elem N addr access align), or NIL."
  (labels ((fully-expand (x)
                "Recursively resolve alias or unmangle, then expand sugar."
                (let* ((r  (resolve-type-alias x))
                           (ex (cond
                                 ;; Already a canonical list
                                 ((consp r)
                                  (let ((h (symbol-name (first r))))
                                    (cond
                                      ((string-equal h "CELL")   r)
                                      ((string-equal h "TENSOR") r)
                                      ((or (string-equal h "VECTOR")
                                           (string-equal h "MATRIX"))
                                       (expand-storage-handle-type-specifier r))
                                      (t r))))
                                 ;; Symbol: try unmangle first (for mangled names like
                                 ;; TENSOR_INT_1_GLOBAL_READ-WRITE_COMPACT), then alias expand
                                 ((symbolp r)
                                  (let* ((unmangled (unmangle-template-struct-name r))
                                             ;; unmangle returns a list like (TENSOR INT 1 ...) or nil
                                             (unm-head  (and (consp unmangled)
                                                             (symbolp (first unmangled))
                                                             (symbol-name (first unmangled)))))
                                    (cond
                                      ;; Successfully unmangled to a TENSOR or CELL form
                                      ((and unm-head (string-equal unm-head "TENSOR"))
                                       ;; reconstruct canonical 6-tuple from unmangled args
                                       (expand-storage-handle-type-specifier unmangled))
                                      ((and unm-head (string-equal unm-head "CELL"))
                                       (expand-storage-handle-type-specifier unmangled))
                                      ;; Not a mangled name -- try normal expansion
                                      (t
                                       (let ((e (expand-storage-handle-type-specifier r)))
                                         (if (consp e) (fully-expand e) r))))))
                                 (t r))))
                  ex)))
    (let ((result (fully-expand src-type)))
      (when (consp result) result))))
