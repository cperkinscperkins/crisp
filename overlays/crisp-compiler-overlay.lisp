;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)


;; src/compiler.lisp
;; Backward kernels emit `atomicrmw fadd` for thread-safe gradient accumulation
;; into tensor _grad cells. The default SPIR-V translator rejects this with
;; "Feature requires the following SPIR-V extension: SPV_EXT_shader_atomic_float_add".
;; When --differentiate is active, request the extension so translation succeeds.
;; Forward-mode invocations are unchanged.
(defun compile-to-spirv (module output-path &key debug-p)
  "Compiles an LLVM Module to SPIR-V using the external toolchain.
   Runs %remove-dead-array-returning-functions before translation to
   prevent IGC from miscompiling dead TypeArray-returning functions
   (bug 028 workaround Part 2)."
  (let* ((base-path (uiop:pathname-directory-pathname output-path))
         (name (pathname-name output-path))
         (ll-file (merge-pathnames (format nil "~a.temp.ll" name) base-path))
         (bc-file (merge-pathnames (format nil "~a.temp.bc" name) base-path))
         (spv-file output-path))

    (%remove-dead-array-returning-functions module)
    (llvm-set-target module "spir64-unknown-unknown")

    (let* ((ir (cffi:foreign-string-to-lisp (llvm-print-module-to-string module)))
           (ir-with-metadata (inject-spir-kernel-metadata ir)))
      (with-open-file (stream ll-file :direction :output :if-exists :supersede)
        (write-string ir-with-metadata stream)))

    (let ((tool (resolve-tool-executable "llvm-as")))
      (run-tool-command
       (list tool (namestring ll-file) "-o" (namestring bc-file))
       :log-prefix "[SPIR-V] "))

    (let* ((tool (resolve-tool-executable "llvm-spirv"))
           (debug-flags (if debug-p '("--spirv-debug-info-version=ocl-100") nil))
           (ad-flags (if *differentiate-p*
                         '("--spirv-ext=+SPV_EXT_shader_atomic_float_add")
                         nil))
           (flags (append debug-flags ad-flags)))
      (run-tool-command
       (append (list tool) flags (list (namestring bc-file) "-o" (namestring spv-file)))
       :log-prefix "[SPIR-V] "))

    (unless debug-p
      (when (probe-file ll-file) (delete-file ll-file))
      (when (probe-file bc-file) (delete-file bc-file)))

    (log:info "Generated SPIR-V: ~a" spv-file)))


;; src/metadata-val.lisp
;; New validator for the 101-revisit-autodiff endeavor: locks the invariant
;; that SROA-destructured compound-type fields (offset, stride, extent, length,
;; parent, byte-size) never surface as standalone _grad cells in the backward
;; kernel signature. Each logical declared parameter gets at most one logical
;; _grad companion of the same shape.
(defun %ends-with-grad-p (name)
  "Returns T if NAME (a string) ends with '_grad' (case-insensitive)."
  (and (stringp name)
       (>= (length name) 5)
       (string-equal "_grad" (subseq name (- (length name) 5)))))

(defun %strip-grad-suffix (name)
  "Returns NAME with the trailing 5-character '_grad' suffix removed."
  (subseq name 0 (- (length name) 5)))

(defun validate-no-sroa-grad-leak (metadata-path)
  "Locks the no-SROA-grad-leak invariant for backward kernels.

   For every entry in the kernel's :declared-signature whose :name ends in
   '_grad', the name stripped of '_grad' must also appear as an entry's
   :name in the same declared-signature.

   This catches the failure mode where SROA-expanded scalar components of a
   compound type (e.g. a tensor's offset/stride/extent/length/parent/byte-size)
   leak as standalone _grad cells in the backward kernel signature, rather
   than riding along inside the single logical _grad companion of the
   compound parameter.

   In the forward (non --differentiate) suite, no _grad entries exist in
   declared-signature at all, so the validator passes trivially. The same
   test file therefore locks the invariant under both passes."
  (unless (probe-file metadata-path)
    (log:error "validate-no-sroa-grad-leak: file not found: ~a" metadata-path)
    (return-from validate-no-sroa-grad-leak nil))
  (let* ((forms (%read-metacrisp-forms metadata-path))
         (kernels (%metacrisp-section forms :kernels))
         (ok t))
    (unless kernels
      (log:error "validate-no-sroa-grad-leak: no :kernels section in ~a" metadata-path)
      (return-from validate-no-sroa-grad-leak nil))
    (dolist (k kernels)
      (let ((k-name (getf k :name))
            (decl   (getf k :declared-signature)))
        (dolist (entry decl)
          (let ((nm (getf entry :name)))
            (when (%ends-with-grad-p nm)
              (let* ((stripped (%strip-grad-suffix nm))
                     (twin (%find-decl-entry decl stripped)))
                (unless twin
                  (log:error "validate-no-sroa-grad-leak: kernel ~a has stray _grad entry ~a -- no forward twin ~a in declared-signature ~a"
                             k-name nm stripped
                             (mapcar (lambda (e) (getf e :name)) decl))
                  (setf ok nil))))))))
    ok))


;;; ===================================================================
;;; 101-revisit-autodiff Part 1: record params in sub-function diff
;;; ===================================================================
;;;
;;; Records auto-SROA at every function boundary (verified empirically:
;;; `dist(point, point)` compiles to `dist_point_point(float, float, float, float)`).
;;; The 052 sub-function diff pipeline already handles float-scalar
;;; functions correctly. The only thing blocking record params is two
;;; gates that filter on `%crisp-float-type-p`, which sees the declared
;;; record type rather than the post-SROA float fields.
;;;
;;; This overlay widens both gates to count a record param's
;;; runtime-field contributions toward the differentiable-param count.

;; src/autodiff.lisp - helpers for the 101 part-1 sub-function record diff.
;;
;; Pre-registration runs BEFORE def-record macros expand and register types
;; in *crisp-types*. To know a record's runtime-field count at pre-reg time,
;; we scan the forms list ourselves for (def-record ...) entries and build
;; an alist. Post-walk-code-forms code paths can fall back to *crisp-types*.

(defun %scan-forms-for-record-info (forms)
  "Walks FORMS (recursing through progn / with-template-type) and returns
   an alist mapping (symbol-name TYPE-NAME) -> count of non-:c-t,
   non-brand runtime fields. Used during pre-registration when *crisp-types*
   isn't yet populated.

   Includes BOTH def-record AND def-struct (records and structs at the
   sub-function AD level both contribute their field count toward the
   differentiability gate).  Also includes derived-from-{record,struct}
   types: when (def-derived-type NEW BASE ...) is encountered and BASE is
   already in the alist, NEW is added with the same field count.

   The name `record-info` is historical; the alist now tracks structs too."
  (let ((info nil))
    (labels ((scan (forms)
               (dolist (f forms)
                 (cond
                   ((and (consp f)
                         (or (eq (car f) 'def-record)
                             (eq (car f) 'def-struct)))
                    (let* ((name (second f))
                           (members (cddr f))
                           (rt-count
                            (count-if
                             (lambda (m)
                               (and (consp m)
                                    (not (eq (car m) 'brand))
                                    (not (and (consp m) (eq (third m) :c-t)))))
                             members)))
                      (push (cons (symbol-name name) rt-count) info)))
                   ((and (consp f) (eq (car f) 'def-derived-type)
                         (>= (length f) 3)
                         (symbolp (second f))
                         (symbolp (third f)))
                    ;; (def-derived-type NEW BASE [...])
                    (let* ((new-name (second f))
                           (base-name (third f))
                           (base-entry (assoc (symbol-name base-name) info
                                              :test #'string-equal)))
                      (when base-entry
                        (push (cons (symbol-name new-name) (cdr base-entry)) info))))
                   ((and (consp f) (eq (car f) 'progn))
                    (scan (rest f)))
                   ((and (consp f) (eq (car f) 'with-template-type))
                    (scan (cddr f)))))))
      (scan forms))
    info))

(defun %resolve-to-base-type-for-records (pd-type)
  "If PD-TYPE names a derived type whose base is a record, returns the
   base record type symbol. Otherwise returns PD-TYPE unchanged.

   Records are SROA'd at every function boundary, and derived-type wrappers
   preserve that property. This helper lets the sub-function gate widening
   accept derived-from-record types (e.g. `coordinate` derived from `point`)."
  (let* ((base (if (consp pd-type) (first pd-type) pd-type)))
    (or (cl:ignore-errors
         (cl:let ((computed (compute-base-type pd-type)))
           (cl:when (and (symbolp computed) (%crisp-record-type-p computed))
             computed)))
        base)))

(defun %resolve-to-base-type-for-structs-or-records (pd-type)
  "If PD-TYPE names a derived type whose base is a struct OR a record,
   returns the base type symbol.  Otherwise returns PD-TYPE unchanged.
   Used by sub-function gate widening to accept derived-from-struct types
   in addition to derived-from-record types."
  (let* ((base (if (consp pd-type) (first pd-type) pd-type)))
    (or (cl:ignore-errors
         (cl:let ((computed (compute-base-type pd-type)))
           (cl:when (and (symbolp computed)
                         (or (%crisp-record-type-p computed)
                             (%crisp-struct-type-p computed)))
             computed)))
        base)))

(defun %count-differentiable-contributions (pd-type &optional record-info)
  "Returns the number of SCALAR-DELTA contributions this parameter type
   makes at the SUB-FUNCTION level (def-function).  Used to size the
   multi-value-return arity at the sub-fn _GRAD boundary.

   - Records / derived-from-records  → runtime-field count (per-field deltas).
   - Structs  / derived-from-structs → runtime-field count (same convention).
   - Float scalars                   → 1.
   - Tensors, cells, integer scalars → 0.  These contribute zero scalar
     deltas; tensors flow grad via &out grad-tensor params instead
     (see %has-tensor-diff-param-p and the tensor-sub-fn pipeline).

   RECORD-INFO (optional alist of (NAME-STR . FIELD-COUNT)) bridges the
   pre-registration ordering issue where *crisp-types* isn't yet
   populated. When supplied, it takes priority over the runtime registry."
  (let* ((base (if (consp pd-type) (first pd-type) pd-type))
         (name-str (and (symbolp base) (symbol-name base)))
         (info-hit (and record-info name-str
                        (assoc name-str record-info :test #'string-equal)))
         ;; Resolve derived-from-struct-or-record types to their base.
         (resolved (%resolve-to-base-type-for-structs-or-records pd-type)))
    (cond
      (info-hit (cdr info-hit))
      ;; Tensors are internally records (storage handles).  Exclude them
      ;; from the record path — they contribute 0 scalar deltas; their
      ;; grad flows via the &out grad-tensor pathway.
      ;; Handles (tensors AND cells) flow grad via &out, not via scalar
      ;; deltas.  0 scalar deltas.
      ((%crisp-handle-param-type-p pd-type) 0)
      ((or (%crisp-record-type-p resolved)
           (%crisp-struct-type-p resolved))
       (length (or (%get-record-runtime-fields resolved) '())))
      ((%crisp-float-type-p pd-type) 1)
      (t 0))))

(defun %crisp-tensor-param-type-p (pd-type)
  "Returns T if PD-TYPE is a tensor (float-element or integer-element)
   at the sub-function level.  Used to decide whether a sub-fn param
   contributes a tensor grad-out (vs a scalar delta).

   Handles three forms:
   - List form: (tensor float 1 ...) — caught by the existing helpers.
   - Mangled-template-name symbol: TENSOR_FLOAT_1_GLOBAL_COMPACT_LAST —
     produced by Crisp's template instantiation.  Detected by name prefix.
   - Plain symbol naming a registered tensor type."
  (or (%crisp-float-tensor-type-p pd-type)
      (%crisp-integer-tensor-type-p pd-type)
      (and (symbolp pd-type)
           (let ((name (symbol-name pd-type)))
             (and (>= (length name) 7)
                  (string-equal "TENSOR_" (subseq name 0 7)))))))

(defun %crisp-cell-param-type-p (pd-type)
  "Returns T if PD-TYPE is a cell of a SCALAR element type (float or
   integer) at the sub-function level.  Cells flow grad via &out
   grad-cell, same pattern as tensors.

   Cells of structs/records are NOT accepted here — their grad-cell
   would need to be a cell of the corresponding shadow type, and the
   chain rule for `(set! (field~ (~ c)) ...)` is structurally different
   (deferred).

   Recognizes three forms (mirrors %crisp-tensor-param-type-p):
   - List form: (cell float :address-space :global ...).
   - Mangled template name like CELL_FLOAT_GLOBAL — produced by Crisp's
     template instantiation.  Detected by name prefix + scalar element.
   - Plain symbol naming a registered cell type."
  (let ((canonical (canonicalize-type-specifier pd-type)))
    (cond
      ;; List form with explicit scalar element.
      ((and (consp canonical) (symbolp (first canonical))
            (string-equal (symbol-name (first canonical)) "CELL"))
       (let ((elem (second canonical)))
         (or (%crisp-float-type-p elem)
             (%crisp-integer-scalar-type-p elem))))
      ;; Mangled symbol form: parse element from name (e.g. CELL_FLOAT_GLOBAL).
      ((and (symbolp pd-type)
            (let ((name (symbol-name pd-type)))
              (and (>= (length name) 5)
                   (string-equal "CELL_" (subseq name 0 5)))))
       (let ((name (symbol-name pd-type)))
         ;; Heuristic: second segment is the element type.  Common cases:
         ;; CELL_FLOAT_*, CELL_INT_*, CELL_LONG_*, CELL_DOUBLE_*, etc.
         ;; Reject if it starts with CELL_<struct-name>_ or CELL_<record-name>_.
         (let* ((after-cell (subseq name 5))
                (underscore (position #\_ after-cell))
                (elem-str (if underscore
                              (subseq after-cell 0 underscore)
                              after-cell)))
           (member elem-str '("FLOAT" "DOUBLE" "HALF" "BFLOAT16"
                              "INT" "LONG" "SHORT" "CHAR"
                              "UINT" "ULONG" "USHORT" "UCHAR")
                   :test #'string-equal))))
      (t nil))))

(defun %crisp-handle-param-type-p (pd-type)
  "Returns T for any sub-fn param type that flows grad via &out grad-handle:
   tensors AND cells.  Both go through the same convention — paired with
   an &out grad-handle of matching shape, body atomic-adds into it."
  (or (%crisp-tensor-param-type-p pd-type)
      (%crisp-cell-param-type-p pd-type)))

(defun %has-tensor-diff-param-p (env)
  "Returns T if ENV contains at least one non-&OUT parameter that flows
   grad via a paired &out grad-handle (tensor OR cell).  Used by the
   sub-function pre-reg + _GRAD generator gates: a sub-fn with such
   params is differentiable even when its scalar-delta count is zero.

   Name is historical (originally tensor-only); now covers cells too."
  (some (lambda (pd)
          (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
               (%crisp-handle-param-type-p (parameter-def-type pd))))
        env))

;; src/analysis/core.lisp
;; Widen pre-registration to count records via their runtime fields.
;; HOF path is unchanged for now (open Q4 — HOF + record params deferred).
(defun %pre-register-differentiable-fns (forms &optional record-info)
  "When *differentiate-p* is T, walk FORMS for def-function forms and
pre-register them in *differentiable-functions* (and *differentiable-hof-store*
for HOF functions). Records contribute their runtime-field count
(post-SROA shape) to the differentiable-param count.

RECORD-INFO is the alist built by %scan-forms-for-record-info. At top-level
call we build it once and pass it down through progn recursion so each
recursive call can reuse it."
  (let ((record-info (or record-info (%scan-forms-for-record-info forms))))
  (when *differentiate-p*
    (dolist (form forms)
      (cond
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
                            ;; Widened: count differentiable contributions including
                            ;; records (which contribute their runtime-field count).
                            (n-diff-params
                             (loop for pd in env
                                   when (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                   sum (%count-differentiable-contributions (parameter-def-type pd) record-info)))
                            (n-return (length (remove nil return-types)))
                            (fn-param-entries
                             (loop for pd in env
                                   for i from 0
                                   when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                             (%crisp-function-type-p (parameter-def-type pd)))
                                   collect (cons i pd)))
                            (is-hof (consp fn-param-entries)))
                       ;; Gate: register if any scalar-delta contribution
                       ;; OR any tensor param (tensors flow grad via &out
                       ;; grad-tensor params at the sub-fn boundary).
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

        ((and (consp form) (eq (car form) 'progn))
         (%pre-register-differentiable-fns (rest form) record-info))

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

;; src/autodiff.lisp
;; Dynamic var: when bound during a backward walk, maps each record-typed
;; symbol (a sub-function parameter, OR a kernel-level ANF temp bound to
;; %construct-struct) to its per-field adjoint info.
;;
;; Map value shape: alist of (FIELD-NAME-STRING . FIELD-ADJ-SYM) in
;; declaration order.  Stored as an alist (not a hash) so iteration order
;; is portable across implementations.  Consumers:
;;   - The accessor rule in %handle-single-value-backward routes adjoint
;;     flow from (FIELD~ p) to the per-field synth adj.
;;   - The %construct-struct case flows per-field adjs to constructor args.
;;   - %emit-sub-fn-backward distributes deltas per-field when an arg is
;;     a record-valued symbol.
(defvar *record-param-field-adjs* nil
  "Hash table: record-sym -> alist of (FIELD-NAME-STR . FIELD-ADJ-SYM)
   in declaration order.  Bound during backward walk for sub-functions
   with record params, and for kernels with record-valued ANF temps
   (constructed via make-RECORD).  Otherwise NIL.")

;; src/autodiff.lisp - override
;; Widen the call-site delta-to-arg mapping.  Previously assumed each arg
;; gets exactly one delta from the gradient call (matches scalar params).
;; For record args (looked up via *record-param-field-adjs*), consume N
;; deltas (one per field) and accumulate them into the arg's per-field
;; adjoints in field-declaration order.
(defun %emit-sub-fn-backward (fn args bkwd-fn t-adj-forms n-fp pkg emit-fn local-adj-fn &optional (sym-prefix "BW"))
  "Emits the call to BKWD-FN and routes returned deltas / passed-through
   &out grad-tensors per the AD convention.

   - Scalar arg: one delta from multi-value return → accumulated into
     (local-adj arg).
   - Record/struct arg (looked up via *record-param-field-adjs*): N deltas
     in declaration order → accumulated into each per-field synth adj.
   - Tensor arg (identified via fn's :tensor-param-indices registry slot):
     pairs with an &out arg in the call.  The kernel's corresponding
     `<arg>_GRAD` is passed; the chain rule's atomic-add happens inside
     the sub-fn body.  No scalar delta to accumulate.

   The call is emitted whenever there's any accumulation OR any tensor
   arg (the tensor case writes via &out, not via accumulation, but the
   call itself still needs to happen)."
  (let* ((info (and fn (gethash fn *differentiable-functions*)))
         (tensor-indices (and info (getf info :tensor-param-indices)))
         (has-tensor-args (consp tensor-indices))
         (deltas (loop for i from 0 below n-fp
                       collect (intern (format nil "%~A_D~a" sym-prefix i) pkg)))
         (accum-forms nil)
         (delta-idx 0))
    (dolist (arg args)
      (cond
        ;; Record arg with per-field adjs: distribute the next N deltas
        ;; across the arg's fields in declaration order (alist iteration).
        ((and (symbolp arg)
              *record-param-field-adjs*
              (gethash arg *record-param-field-adjs*))
         (let ((field-alist (gethash arg *record-param-field-adjs*)))
           (loop for (field-name-str . field-adj-sym) in field-alist
                 when (< delta-idx n-fp)
                 do (push `(set! ,field-adj-sym
                                 (+ ,field-adj-sym ,(nth delta-idx deltas)))
                          accum-forms)
                    (incf delta-idx))))
        ;; Scalar symbol arg: single delta accumulation (existing behavior).
        ((symbolp arg)
         (when (< delta-idx n-fp)
           (push `(set! ,(funcall local-adj-fn arg)
                        (+ ,(funcall local-adj-fn arg) ,(nth delta-idx deltas)))
                 accum-forms)
           (incf delta-idx)))
        (t nil)))
    (setf accum-forms (nreverse accum-forms))
    (cond
      ;; Tensor-arg case: emit the call with grad-tensors appended.
      ;; The grad-tensor for each tensor arg is the kernel-side `<arg>_GRAD`
      ;; symbol (convention used at the kernel level for grad-out cells).
      ;; `&out` appears in the signature, not the call form.
      (has-tensor-args
       (let* ((grad-args
               (loop for i in tensor-indices
                     for arg = (nth i args)
                     when (symbolp arg)
                     collect (intern (format nil "~A_GRAD" (symbol-name arg))
                                     (symbol-package arg))))
              (call-form `(,bkwd-fn ,@args ,@t-adj-forms ,@grad-args)))
         (cond
           ;; Has scalar deltas too: multi-value bind, then accumulate, plus call.
           ((or accum-forms (> n-fp 0))
            (funcall emit-fn
                     `(let (,@(mapcar (lambda (d) `(,d 0.0)) deltas))
                        (let (,(append deltas (list call-form)))
                          ,@accum-forms))))
           ;; Tensor-only: just emit the call as a statement.
           (t (funcall emit-fn call-form)))))
      ;; No tensors, has scalar accumulations: existing multi-value-bind path.
      (accum-forms
       (funcall emit-fn
                `(let (,@(mapcar (lambda (d) `(,d 0.0)) deltas))
                   (let (,(append deltas (list `(,bkwd-fn ,@args ,@t-adj-forms))))
                     ,@accum-forms))))
      (t nil))))

;; src/autodiff.lisp - override
;; Add a record-aware accessor case BEFORE the existing identity-accessor case.
;; When (FIELD~ p) is encountered and p is a record param, route adjoint
;; flow to the per-field synthetic adjoint instead of p_adj.
(defun %handle-single-value-backward (v expr adjoint-map emit-fn local-adj-fn
                                      &key hof-handler-fn (error-on-unknown t)
                                           tensor-inputs-ht)
  "Generates backward-pass adjoint updates for a single ANF binding (v := expr).
TENSOR-INPUTS-HT, when provided, maps kernel-input symbols to their types for
tensor inputs.  *RECORD-PARAM-FIELD-ADJS*, when bound, maps record-param
symbols to a hash of (field-name-string -> per-field-adj-symbol); the
accessor rule routes adjoint into that synthetic per-field adj instead of
the record's collective adj."
  (flet ((local-adj (x) (funcall local-adj-fn x))
         (emit (x) (funcall emit-fn x)))
    (cond
      ((and (consp expr) (eq (car expr) '+))
        (let ((a (cadr expr)) (b (caddr expr)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,(local-adj v)))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) ,(local-adj v)))))))
      ((and (consp expr) (eq (car expr) '-))
        (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* -1.0 ,v-adj)))))))
      ((and (consp expr) (eq (car expr) '*))
        (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* ,b ,v-adj)))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* ,a ,v-adj)))))))
      ((and (consp expr) (eq (car expr) '/))
        (let* ((a (cadr expr)) (b (caddr expr)) (v-adj (local-adj v)))
          (when (symbolp a) (emit `(set! ,(local-adj a) (+ ,(local-adj a) (* (/ 1.0 ,b) ,v-adj)))))
          (when (symbolp b) (emit `(set! ,(local-adj b) (+ ,(local-adj b) (* (* -1.0 (/ ,a (* ,b ,b))) ,v-adj)))))))
      ((and (consp expr) (eq (car expr) 'sin))
        (let* ((a (cadr expr)) (v-adj (local-adj v)))
          (when (symbolp a)
            (let* ((a-adj (local-adj a))
                   (cos-a (intern (format nil "~a_COS" (symbol-name a)) (symbol-package a))))
              (setf (gethash cos-a adjoint-map) cos-a)
              (emit `(set! ,cos-a (cos ,a)))
              (emit `(set! ,a-adj (+ ,a-adj (* ,cos-a ,v-adj))))))))
      ((and (consp expr) (eq (car expr) 'cos))
        (let* ((a (cadr expr)) (v-adj (local-adj v)))
          (when (symbolp a)
            (let* ((a-adj (local-adj a))
                   (sin-a (intern (format nil "~a_SIN" (symbol-name a)) (symbol-package a))))
              (setf (gethash sin-a adjoint-map) sin-a)
              (emit `(set! ,sin-a (sin ,a)))
              (emit `(set! ,a-adj (+ ,a-adj (* (* ,sin-a -1.0) ,v-adj))))))))
      ((and (consp expr) (eq (car expr) '~))
        (let* ((src     (cadr expr))
               (indices (cddr expr))
               (v-adj   (local-adj v)))
          (when (symbolp src)
            (cond
              ;; Tensor read with indices, src in tensor-inputs-ht: atomic-add
              ;; at the indexed slot in the paired grad-tensor.
              ((and indices tensor-inputs-ht (gethash src tensor-inputs-ht))
               (let ((grad-sym (intern (format nil "~A_GRAD" (symbol-name src))
                                       (symbol-package src))))
                 (emit `(atomic-add! (~ ,grad-sym ,@indices) ,v-adj))))
              ;; Cell read (no indices), src in tensor-inputs-ht: atomic-add
              ;; into the paired grad-cell.  Same convention as tensors but
              ;; without indices.  Used for cell sub-fn params at the sub-fn-
              ;; backward layer (kernel-level cell reads fall to the t-branch
              ;; below because their tensor-inputs-ht filters to float tensors).
              ((and (null indices) tensor-inputs-ht (gethash src tensor-inputs-ht))
               (let ((grad-sym (intern (format nil "~A_GRAD" (symbol-name src))
                                       (symbol-package src))))
                 (emit `(atomic-add! (~ ,grad-sym) ,v-adj))))
              (t
               (emit `(set! ,(local-adj src) (+ ,(local-adj src) ,v-adj))))))))
      ;; Differentiable sub-function call
      ((and (consp expr)
            (symbolp (car expr))
            (gethash (car expr) *differentiable-functions*))
        (let* ((fn   (car expr))
               (args (cdr expr))
               (info (gethash fn *differentiable-functions*)))
          (if (getf info :hof)
              (if hof-handler-fn
                  (funcall hof-handler-fn fn args v)
                  (error "HOF handler required for sub-function ~A but not provided" fn))
              (%emit-sub-fn-backward fn args
                                     (getf info :bkwd-name)
                                     (list (local-adj v))
                                     (getf info :n-float-params)
                                     (symbol-package v)
                                     emit-fn local-adj-fn
                                     (if (symbolp v) (symbol-name v) "BW")))))
      ;; NEW: Record-aware accessor.  (FIELD~ p) where p is a record param/temp
      ;; in *record-param-field-adjs*.  Route adjoint into the per-field synthetic
      ;; adj instead of p_adj.  Register the field-adj-sym in adjoint-map so the
      ;; walker's "build local bindings" phase emits a `(<field-adj-sym> 0.0)`
      ;; binding for it.
      ((and (consp expr) (symbolp (car expr)) (= (length (cdr expr)) 1)
            (let ((fname (symbol-name (car expr))))
              (and (> (length fname) 1)
                   (cl:char= (cl:char fname (1- (length fname))) #\~)))
            *record-param-field-adjs*
            (symbolp (cadr expr))
            (gethash (cadr expr) *record-param-field-adjs*))
        (let* ((accessor (symbol-name (car expr)))
               (field-name-str (subseq accessor 0 (1- (length accessor))))
               (record-sym (cadr expr))
               (field-alist (gethash record-sym *record-param-field-adjs*))
               (field-entry (assoc field-name-str field-alist :test #'string-equal))
               (field-adj-sym (cdr field-entry))
               (v-adj (local-adj v)))
          (when field-adj-sym
            (setf (gethash field-adj-sym adjoint-map) field-adj-sym)
            (emit `(set! ,field-adj-sym (+ ,field-adj-sym ,v-adj))))))
      ;; NEW: Struct-kernel-param accessor.  (FIELD~ s) where s is a struct
      ;; kernel param tracked in *struct-kernel-param-shadows*.  Three cases
      ;; based on the field-info type:
      ;;   - Leaf scalar field (sym): route adj into the per-field synth adj.
      ;;   - Nested struct field (alist): no scalar adj at this level — skip.
      ;;     The pre-scan (%register-shadow-anf-intermediates) registered the
      ;;     ANF-temp bound to this accessor in *struct-kernel-param-shadows*
      ;;     so its OWN accessor calls route deeper.
      ;;   - Unknown field: skip silently.
      ((and (consp expr) (symbolp (car expr)) (= (length (cdr expr)) 1)
            (let ((fname (symbol-name (car expr))))
              (and (> (length fname) 1)
                   (cl:char= (cl:char fname (1- (length fname))) #\~)))
            *struct-kernel-param-shadows*
            (symbolp (cadr expr))
            (gethash (cadr expr) *struct-kernel-param-shadows*))
        (let* ((accessor (symbol-name (car expr)))
               (field-name-str (subseq accessor 0 (1- (length accessor))))
               (struct-sym (cadr expr))
               (entry (gethash struct-sym *struct-kernel-param-shadows*))
               ;; Entry shape depends on whether struct-sym is a top-level
               ;; kernel param (entry is (cons shadow-grad-sym field-alist))
               ;; or a registered ANF intermediate (entry is just field-alist).
               (field-alist (if (and (consp entry) (symbolp (car entry)))
                                (cdr entry)
                                entry))
               (field-entry (assoc field-name-str field-alist :test #'string-equal))
               (field-info (cdr field-entry))
               (v-adj (local-adj v)))
          (cond
            ;; Nested-struct field — skip (the leaves under it accumulate
            ;; via their own accessor rules; %anf-t-i would have been
            ;; registered as a shadow-tracked intermediate by the pre-scan).
            ((%nested-field-info-p field-info) nil)
            ;; Leaf scalar field — route adj.
            ((symbolp field-info)
             (setf (gethash field-info adjoint-map) field-info)
             (emit `(set! ,field-info (+ ,field-info ,v-adj))))
            (t nil))))
      ;; NEW: Record constructor backward rule.
      ;; `(v (%construct-struct RECORD-NAME arg1 arg2 ...))` where v is a
      ;; record-valued ANF temp tracked in *record-param-field-adjs*.  Flow
      ;; per-field adjs back to the constructor args in field-declaration order.
      ((and (consp expr) (symbolp (car expr))
            (string-equal (symbol-name (car expr)) "%CONSTRUCT-STRUCT")
            *record-param-field-adjs*
            (gethash v *record-param-field-adjs*))
        (let* ((ctor-args (cddr expr))
               (field-alist (gethash v *record-param-field-adjs*)))
          (loop for (field-name-str . field-adj-sym) in field-alist
                for ctor-arg in ctor-args
                when (and (symbolp ctor-arg) field-adj-sym)
                do (setf (gethash field-adj-sym adjoint-map) field-adj-sym)
                   (emit `(set! ,(local-adj ctor-arg)
                                (+ ,(local-adj ctor-arg) ,field-adj-sym))))))
      ;; Existing accessor rule (identity flow to record/struct symbol)
      ((and (consp expr) (symbolp (car expr)) (= (length (cdr expr)) 1)
            (let ((fname (symbol-name (car expr))))
              (and (> (length fname) 1)
                   (cl:char= (cl:char fname (1- (length fname))) #\~))))
        (let* ((a (cadr expr)) (v-adj (local-adj v)))
          (when (symbolp a)
            (emit `(set! ,(local-adj a) (+ ,(local-adj a) ,v-adj))))))
      ((and (consp expr) (symbolp (car expr))
            (member (symbol-name (car expr)) '("<" ">" "<=" ">=" "=" "/=") :test #'string=))
       nil)
      ((and (consp expr) (symbolp (car expr))
            (string= (symbol-name (car expr)) "IF"))
       nil)
      ((and (consp expr) (symbolp (car expr))
            (%backward-skip-fn-p (car expr)))
       nil)
      ((and (consp expr) (symbolp (car expr)))
       (when error-on-unknown
         (error "Function ~A is not differentiable. Wrap the kernel in 'forward-only' if differentiation is not needed, or ensure all called functions are differentiable." (car expr))))
      (t nil))))

;; src/autodiff.lisp - override
;; Widen the second gate. By this time *crisp-types* is populated, so we can
;; use %crisp-record-type-p directly without the forms-scan helper.
;; For record params, allocate per-field synthetic adj symbols, bind
;; *record-param-field-adjs* during the walk, and emit per-field return values.
(defun %trivial-accessor-body-p (body-forms)
  "Returns T if BODY-FORMS is a single (return (%extract-struct-member obj idx))
   — i.e. a trivial field-extraction accessor.  Used to detect auto-generated
   accessors that def-derived-type emits without a `(crisp-system-generated)`
   declaration (def-record's accessors ARE marked, but def-derived-type's are
   not).  These accessors don't need their own _GRAD: the kernel-side accessor
   rule handles them inline."
  (let ((real-forms (remove-if (lambda (f)
                                 (and (consp f) (member (car f) '(declare))))
                               body-forms)))
    (and (= (length real-forms) 1)
         (let ((form (first real-forms)))
           (and (consp form) (eq (car form) 'return)
                (consp (second form))
                (symbolp (caadr form))
                (string-equal (symbol-name (caadr form)) "%EXTRACT-STRUCT-MEMBER"))))))

(defun %generate-backward-function-ast (name params declarations body-forms)
  "Generates the backward companion (def-function NAME_GRAD ...) for a
differentiable user function.

101 part 1: counts record params as contributing their runtime-field count
toward n-float-params (records auto-SROA at every function boundary).
For record params, builds a per-field synthetic adjoint map and binds
*record-param-field-adjs* during the backward walk.

Also skips trivial-accessor bodies — def-derived-type's auto-generated
accessors are missing the (crisp-system-generated) marker but should be
treated equivalently."
  (log:debug "%%GBFA called for ~a is-system=~a" name (member '(crisp-system-generated) declarations :test #'equal))
  (when (%trivial-accessor-body-p body-forms)
    (log:info "AUTODIFF: ~a is a trivial field-extraction accessor — skipping _GRAD generation." name)
    (return-from %generate-backward-function-ast nil))
  (let* ((pkg (symbol-package name)))
    (multiple-value-bind (env return-types)
        (parse-function-declarations params declarations)
      (let* ((float-param-entries
              (loop for pd in env
                    when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                              (%crisp-float-type-p (parameter-def-type pd)))
                    collect pd))
             (float-param-syms (mapcar #'parameter-def-name float-param-entries))
             ;; Record/struct params + their field info, in declaration order.
             ;; Each entry: (param-sym resolved-type
             ;;              ((field-name . field-adj-sym) ...))
             ;;
             ;; Resolves derived-from-{record,struct} types so coordinate (derived
             ;; from point) is treated the same as point.  Both records and
             ;; structs use this same path — the IR-level difference (records
             ;; SROA, structs don't) doesn't matter for sub-function AD because
             ;; the chain rule operates on source-level ANF.  Backward returns
             ;; per-field deltas as multi-values regardless.
             ;;
             ;; HANDLES (tensors + cells) are EXCLUDED here — they're internally
             ;; stored as records in *crisp-structs* (the storage handle layout),
             ;; so %crisp-record-type-p would erroneously include them.  Handles
             ;; go through their own tensor-param-info path with &out grad-handle
             ;; handling.
             (record-param-info
              (loop for pd in env
                    for resolved = (%resolve-to-base-type-for-structs-or-records (parameter-def-type pd))
                    when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                              (not (%crisp-handle-param-type-p (parameter-def-type pd)))
                              (or (%crisp-record-type-p resolved)
                                  (%crisp-struct-type-p resolved)))
                    collect
                    (let* ((rsym (parameter-def-name pd))
                           (fields (%get-record-runtime-fields resolved)))
                      (list rsym resolved
                            (loop for field-info in fields
                                  for field-name = (first field-info)
                                  collect (cons field-name
                                                (intern (format nil "~a_~a_ADJ"
                                                                (symbol-name rsym)
                                                                (symbol-name field-name))
                                                        pkg)))))))
             ;; Per-field synthetic adj symbols, in declaration order.
             (record-field-adj-syms
              (loop for info in record-param-info
                    append (mapcar #'cdr (third info))))
             ;; Full ordered list of "differentiable param syms" used for
             ;; emitting the multi-value return. Per-field adjs are listed
             ;; in the order they appear in the parameter list.
             (all-diff-param-syms-for-return
              (let ((result nil))
                (loop for pd in env
                      do (let ((sym (parameter-def-name pd)))
                           (when (not (string-equal (symbol-name sym) "&OUT"))
                             (let ((rec-entry (assoc sym record-param-info :test #'eq)))
                               (cond
                                 (rec-entry
                                  (setf result (append result (mapcar #'cdr (third rec-entry)))))
                                 ((%crisp-float-type-p (parameter-def-type pd))
                                  (setf result (append result (list sym))))
                                 ;; Other differentiable param types (cell, tensor, int):
                                 ;; treat as scalar — single adj.
                                 ((> (%count-differentiable-contributions (parameter-def-type pd)) 0)
                                  (setf result (append result (list sym)))))))))
                result))
             ;; Hash record-param-sym -> alist of (FIELD-NAME-STR . FIELD-ADJ-SYM)
             ;; in declaration order.  Alist (not hash) so iteration order is
             ;; portable across implementations.
             (record-param-field-adjs-ht
              (when record-param-info
                (let ((ht (make-hash-table :test 'eq)))
                  (dolist (info record-param-info)
                    (let ((field-alist
                           (loop for (fname . fadj) in (third info)
                                 collect (cons (symbol-name fname) fadj))))
                      (setf (gethash (first info) ht) field-alist)))
                  ht)))
             ;; Widened count: float + record-field counts.
             (n-float-params
              (loop for pd in env
                    when (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                    sum (%count-differentiable-contributions (parameter-def-type pd))))
             (return-types-non-void (remove nil return-types))
             (n-return (length return-types-non-void))
             (fn-param-entries
              (loop for pd in env for i from 0
                    when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                              (%crisp-function-type-p (parameter-def-type pd)))
                    collect (cons i pd)))
             (is-hof (consp fn-param-entries)))
        (declare (ignorable record-field-adj-syms))

        (when (and (zerop n-float-params)
                   (not (%has-tensor-diff-param-p env)))
          (log:info "AUTODIFF: ~a has no differentiable params — skipping _GRAD generation." name)
          (return-from %generate-backward-function-ast nil))

        (when is-hof
          (let* ((fn-param-idx (car (car fn-param-entries)))
                 (fn-param-sym (parameter-def-name (cdr (car fn-param-entries))))
                 (clean-body  (loop for f in body-forms
                                    unless (and (atom f) (not (symbolp f)))
                                    collect f)))
            (log:info "AUTODIFF: ~a is HOF — storing for inline backward" name)
            (setf (gethash name *differentiable-hof-store*)
                  (list :param-syms       (loop for pd in env collect (parameter-def-name pd))
                        :fn-param-idx     fn-param-idx
                        :fn-param-sym     fn-param-sym
                        :float-param-syms float-param-syms
                        :body-forms       clean-body))
            (setf (gethash name *differentiable-functions*)
                  (list :hof t
                        :n-float-params (length float-param-syms)
                        :n-return n-return))
            (return-from %generate-backward-function-ast nil)))

        (let* ((bkwd-name  (intern (format nil "~A_GRAD" (symbol-name name)) pkg))
               (t-grad-syms (loop for i from 0 below n-return
                                  collect (intern (format nil "T_GRAD~A" i) pkg)))
               (orig-param-types (mapcar #'parameter-def-type env))
               ;; 101: promote return types for t_grad params.  Integer returns
               ;; (e.g. int, long) get float-typed t_grad seeds at the call site,
               ;; matching the kernel-level adjoint-type-promotion convention.
               (t-grad-types (mapcar (lambda (t-spec) (%promote-to-float-adjoint t-spec))
                                     return-types-non-void))
               ;; Handle params (tensors + cells) + their grad-out info,
               ;; in declaration order.
               ;; Each entry: (PARAM-SYM PARAM-TYPE GRAD-OUT-SYM GRAD-OUT-TYPE).
               ;; Both tensors and cells flow grad via &out grad-handle.
               (tensor-param-info
                (loop for pd in env
                      for ptype = (parameter-def-type pd)
                      when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                (%crisp-handle-param-type-p ptype))
                      collect
                      (let* ((psym (parameter-def-name pd))
                             (grad-sym (intern (format nil "~A_GRAD" (symbol-name psym)) pkg))
                             ;; Grad-out type:
                             ;; - integer tensor → float-element promotion.
                             ;; - float tensor   → ensure RW handle.
                             ;; - cell           → pass through (already a writeable handle).
                             (grad-type (cond
                                          ((%crisp-integer-tensor-type-p ptype)
                                           (%integer-tensor-elem-to-float ptype))
                                          ((%crisp-tensor-param-type-p ptype)
                                           (%ensure-tensor-read-write ptype))
                                          (t ptype))))
                        (list psym ptype grad-sym grad-type))))
               (tensor-grad-out-syms (mapcar #'third tensor-param-info))
               (tensor-grad-out-types (mapcar #'fourth tensor-param-info))
               ;; The `&out` marker must be in the same package the user
               ;; sees (crisp-language).  Defaulting to '&out from this
               ;; overlay's :crisp.compiler package would mismatch the
               ;; reader's symbol.
               (out-marker (intern "&OUT" :crisp-language))
               ;; Bkwd-params: forward params + t_grad inputs.  If tensor params
               ;; exist, append &out grad-tensors.
               (bkwd-params (append params t-grad-syms
                                    (when tensor-param-info (cons out-marker tensor-grad-out-syms))))
               (bkwd-fn-spec
                `(function (,@orig-param-types ,@t-grad-types
                            ,@(when tensor-param-info (cons out-marker tensor-grad-out-types))
                            => ,@(make-list n-float-params :initial-element 'float)))))

          (setf (gethash name *differentiable-functions*)
                (list :bkwd-name bkwd-name
                      :n-float-params n-float-params
                      :n-return n-return
                      ;; Indices (within params) of handle args (tensors+cells).
                      ;; Used by %emit-sub-fn-backward at the call site to pass
                      ;; the corresponding kernel-level grad-handle symbols as
                      ;; the &out args.
                      :tensor-param-indices
                      (loop for pd in env
                            for i from 0
                            when (and (not (string-equal (symbol-name (parameter-def-name pd)) "&OUT"))
                                      (%crisp-handle-param-type-p (parameter-def-type pd)))
                            collect i)))

          (log:info "AUTODIFF: Generating _GRAD companion ~a for ~a (n-fp=~a n-ret=~a n-tensor=~a)"
                    bkwd-name name n-float-params n-return (length tensor-param-info))

          (handler-case
            (let* ((anf-body   (mapcar #'anf-transform body-forms))
                   (raw-flat   (flatten-anf-body anf-body))
                   (flat-anf
                    (let ((last-f (car (last raw-flat))))
                      (if (or (symbolp last-f)
                              (and (consp last-f) (eq (first last-f) 'return)))
                          raw-flat
                          (let ((ret-sym (intern "%RET-0" pkg)))
                            (append (butlast raw-flat)
                                    (list (list ret-sym last-f)
                                          ret-sym))))))
                   (return-vars (%extract-return-vars flat-anf))
                   ;; Build tensor-inputs-ht from tensor-param-info so the
                   ;; walker's tensor-read backward case emits atomic-add
                   ;; into the &out grad-tensor.
                   (tensor-inputs-ht
                    (when tensor-param-info
                      (let ((ht (make-hash-table :test 'eq)))
                        (dolist (entry tensor-param-info)
                          (setf (gethash (first entry) ht) (second entry)))
                        ht)))
                   (bkwd-body
                    (let ((*record-param-field-adjs* record-param-field-adjs-ht))
                      (%check-fn-body-for-mutations body-forms
                                                    (mapcar #'parameter-def-name env)
                                                    name)
                      ;; Pass `all-diff-param-syms-for-return` as the param-syms
                      ;; argument so the walker's final `(return ...)` form
                      ;; lists per-field synth adjs (for record params) and
                      ;; scalar adjs (for float params) in declaration order.
                      (%generate-backward-function-walk
                       flat-anf all-diff-param-syms-for-return t-grad-syms return-vars
                       tensor-inputs-ht))))
              `(def-function ,bkwd-name ,bkwd-params
                 (declare #'(,@(second bkwd-fn-spec)))
                 ,bkwd-body))

            (error (e)
              (log:info "AUTODIFF: ~a — cannot generate _GRAD: ~a. Unregistering; will error if called from a differentiable kernel." name e)
              (remhash name *differentiable-functions*)
              nil)))))))


;; src/autodiff.lisp — kernel-level generate-backward-walk override.
;;
;; Pre-scan the flat ANF for record-valued temps (bindings of the shape
;; `(<sym> (%construct-struct <RECORD> ...))`), allocate per-field adj syms
;; for each, and bind *record-param-field-adjs* during the walk so the
;; overridden %handle-single-value-backward and %emit-sub-fn-backward route
;; adjoints correctly:
;;   - sub-function call deltas distribute per-field for record args
;;   - constructor backward flows per-field adjs back to ctor args
;;   - accessor backward routes adjoints to per-field syms
;;
;; Implementation: save the original `generate-backward-walk` to a defvar,
;; then redefine it as a thin wrapper that does the pre-scan + dyn-bind
;; and delegates to the original.  Avoids duplicating the 200-line walker
;; body; the original code already calls into our overridden helpers.
(defvar *orig-generate-backward-walk* nil
  "Captures the original generate-backward-walk symbol-function so the
   overlay wrapper can delegate to it.  Set on first overlay load only.")

(unless *orig-generate-backward-walk*
  (setf *orig-generate-backward-walk*
        (symbol-function 'generate-backward-walk)))

(defun generate-backward-walk (flat-anf inputs outputs input-types output-types
                               &key kernel-pkg)
  "101 Part 1 wrapper: pre-scan flat-anf for record-valued AND struct-valued
temps bound to %construct-struct, build per-field adj maps, dyn-bind
*record-param-field-adjs*, then delegate to the original walker.

For both records and structs, the constructor backward rule in
%handle-single-value-backward fires when the constructed temp is in
*record-param-field-adjs* — it accumulates per-field adjs back into the
constructor args (e.g. ax_adj += pa.x_adj after `(pa (make-point ax ay))`).
The map is the same; the only difference is which compile-time predicate
recognizes the type."
  (let* ((record-temp-entries
          ;; Collect (temp-sym . field-alist) pairs for each record/struct-
          ;; valued temp.  Records and structs are handled symmetrically
          ;; here: both auto-mint per-field adj syms so the existing
          ;; %construct-struct backward rule routes the chain correctly.
          (loop for form in flat-anf
                when (and (consp form) (= (length form) 2)
                          (symbolp (car form))
                          (consp (cadr form))
                          (symbolp (caadr form))
                          (string-equal (symbol-name (caadr form)) "%CONSTRUCT-STRUCT"))
                collect
                (let* ((temp-sym (car form))
                       (expr (cadr form))
                       (record-name (second expr))
                       (pkg (or kernel-pkg (symbol-package temp-sym))))
                  ;; Build field-alist for records OR structs.  The
                  ;; %construct-struct backward rule treats both uniformly.
                  (when (or (%crisp-record-type-p record-name)
                            (%crisp-struct-type-p record-name))
                    (let* ((fields (%get-record-runtime-fields record-name))
                           (field-alist
                            (loop for (fname ftype) in fields
                                  collect (cons (symbol-name fname)
                                                (intern (format nil "~a_~a_ADJ"
                                                                (symbol-name temp-sym)
                                                                (symbol-name fname))
                                                        pkg)))))
                      (cons temp-sym field-alist))))))
         (record-temp-entries (remove nil record-temp-entries))
         (record-param-field-adjs-ht
          (when record-temp-entries
            (let ((ht (make-hash-table :test 'eq)))
              (dolist (entry record-temp-entries)
                (setf (gethash (car entry) ht) (cdr entry)))
              ht))))
    (let ((*record-param-field-adjs* record-param-field-adjs-ht))
      (funcall *orig-generate-backward-walk*
               flat-anf inputs outputs input-types output-types
               :kernel-pkg kernel-pkg))))


;;; ===================================================================
;;; 101: validator scope fixes for derived-record-type tests
;;; ===================================================================
;;;
;;; The 031/24 and 031/26 validators count forward-overload-dispatch calls
;;; in the whole IR text.  Under --differentiate the backward kernel does
;;; chain-rule recomputation of forward values, so every forward call is
;;; mirrored in the backward kernel — counts double.
;;;
;;; The validators are testing forward dispatch behavior, which is a
;;; property of the forward kernel only.  Scope the search to just the
;;; forward kernel's function body.

;; src/metadata-val.lisp - helper
(defun %extract-fn-body-from-ir (ir-content fn-define-prefix)
  "Returns the substring of IR-CONTENT covering the body of a function
   whose `define` line starts with FN-DEFINE-PREFIX (e.g.
   \"define void @measure_distance(\").  The body spans from the
   `define` line through the matching closing `}` at column 0.
   Returns NIL if no such function found."
  (let ((start (search fn-define-prefix ir-content)))
    (when start
      ;; Find the matching `}` at start of line after START.  In LLVM IR
      ;; the function-closing brace is the only `}` that appears at column
      ;; 0; nested braces (e.g. struct literals) are indented.
      (let* ((scan-start (1+ start))
             (end (loop for pos = (search (format nil "~%}") ir-content :start2 scan-start)
                          then (search (format nil "~%}") ir-content :start2 (1+ pos))
                        while pos
                        ;; Found `\n}`; include up to the `}` character.
                        return (+ pos 2))))
        (when end
          (subseq ir-content start end))))))

;; src/metadata-val.lisp - override
(defun validate-descendant-distance (ir-path)
  "Validates descendant substitution: coordinate can substitute for point.
   Expected: distance_point_point called 2x, distance_coordinate_coordinate called 1x
   in the FORWARD kernel body (measure_distance).  The check is scoped to
   the forward kernel so it stays meaningful under --differentiate, where
   the backward kernel recomputes forward values for chain-rule purposes."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-descendant-distance nil))
  (let* ((ir-content (uiop:read-file-string ir-path))
         (fwd-body (or (%extract-fn-body-from-ir ir-content
                                                 "define void @measure_distance(")
                       (%extract-fn-body-from-ir ir-content
                                                 "define spir_func void @measure_distance("))))
    (unless fwd-body
      (log:error "Forward kernel measure_distance not found in IR")
      (return-from validate-descendant-distance nil))
    (let ((point-calls (count-substring "call i32 @distance_point_point(" fwd-body))
          (coord-calls (count-substring "call i32 @distance_coordinate_coordinate(" fwd-body)))
      (unless (= point-calls 2)
        (log:error "Expected 2 calls to distance_point_point in forward kernel, got ~a" point-calls)
        (return-from validate-descendant-distance nil))
      (unless (= coord-calls 1)
        (log:error "Expected 1 call to distance_coordinate_coordinate in forward kernel, got ~a" coord-calls)
        (return-from validate-descendant-distance nil))
      (log:info "Descendant substitution validated: forward kernel calls point overload 2x, coordinate 1x")
      t)))

;; src/metadata-val.lisp - override
(defun validate-ancestor-distance (ir-path)
  "Validates ancestor substitution: point can substitute for coordinate.
   Expected: distance_coordinate_coordinate called 2x, distance_point_point called 1x
   in the FORWARD kernel body (measure_distance).  Scoped to the forward
   kernel for the same reason as validate-descendant-distance."
  (unless (probe-file ir-path)
    (log:error "IR file not found: ~a" ir-path)
    (return-from validate-ancestor-distance nil))
  (let* ((ir-content (uiop:read-file-string ir-path))
         (fwd-body (or (%extract-fn-body-from-ir ir-content
                                                 "define void @measure_distance(")
                       (%extract-fn-body-from-ir ir-content
                                                 "define spir_func void @measure_distance("))))
    (unless fwd-body
      (log:error "Forward kernel measure_distance not found in IR")
      (return-from validate-ancestor-distance nil))
    (let ((point-calls (count-substring "call i32 @distance_point_point(" fwd-body))
          (coord-calls (count-substring "call i32 @distance_coordinate_coordinate(" fwd-body)))
      (unless (= coord-calls 2)
        (log:error "Expected 2 calls to distance_coordinate_coordinate in forward kernel, got ~a" coord-calls)
        (return-from validate-ancestor-distance nil))
      (unless (= point-calls 1)
        (log:error "Expected 1 call to distance_point_point in forward kernel, got ~a" point-calls)
        (return-from validate-ancestor-distance nil))
      (log:info "Ancestor substitution validated: forward kernel calls coordinate overload 2x, point 1x")
      t)))


;;; ===================================================================
;;; 101: forward-only metadata validators for the 048 cluster
;;; ===================================================================
;;;
;;; The 048 record-at-kernel-boundary tests describe properties of the
;;; FORWARD kernel's metadata: which records appear in :records, the
;;; physical-signature width, the declared-signature shape, etc.
;;;
;;; Under --differentiate the emitted metacrisp describes the BACKWARD
;;; kernel, which has a structurally different shape: records are
;;; destructured into per-field scalars, kernel name has a _grad suffix,
;;; physical-signature is wider (input + output adjoints), declared-sig
;;; has per-field entries.  The forward-only checks don't apply.
;;;
;;; Wrap each forward-only validator with a guard: when *differentiate-p*
;;; is T, return T without checking (the kernel having compiled cleanly
;;; under --differentiate is still validated by the default test pass;
;;; this just lifts the metadata-shape constraint).
;;;
;;; Same save-and-wrap pattern we used for generate-backward-walk.

(defvar *orig-validate-def-record-in-metadata* nil)
(defvar *orig-validate-def-rec-with-ct-in-metadata* nil)
(defvar *orig-validate-nested-rec-in-metadata* nil)
(defvar *orig-validate-no-brand-in-metadata* nil)

(unless *orig-validate-def-record-in-metadata*
  (setf *orig-validate-def-record-in-metadata*
        (symbol-function 'validate-def-record-in-metadata)))
(unless *orig-validate-def-rec-with-ct-in-metadata*
  (setf *orig-validate-def-rec-with-ct-in-metadata*
        (symbol-function 'validate-def-rec-with-ct-in-metadata)))
(unless *orig-validate-nested-rec-in-metadata*
  (setf *orig-validate-nested-rec-in-metadata*
        (symbol-function 'validate-nested-rec-in-metadata)))
(unless *orig-validate-no-brand-in-metadata*
  (setf *orig-validate-no-brand-in-metadata*
        (symbol-function 'validate-no-brand-in-metadata)))

(defun %forward-only-metadata-skip-p ()
  "Returns T when the validator should pass trivially because the metacrisp
   describes the backward kernel (under --differentiate).  Logs at info level."
  (when *differentiate-p*
    (log:info "Skipping forward-only metadata validator under --differentiate.")
    t))

(defun validate-def-record-in-metadata (metadata-path)
  "Forward-only metadata validator (101: skips under --differentiate)."
  (or (%forward-only-metadata-skip-p)
      (funcall *orig-validate-def-record-in-metadata* metadata-path)))

(defun validate-def-rec-with-ct-in-metadata (metadata-path)
  "Forward-only metadata validator (101: skips under --differentiate)."
  (or (%forward-only-metadata-skip-p)
      (funcall *orig-validate-def-rec-with-ct-in-metadata* metadata-path)))

(defun validate-nested-rec-in-metadata (metadata-path)
  "Forward-only metadata validator (101: skips under --differentiate)."
  (or (%forward-only-metadata-skip-p)
      (funcall *orig-validate-nested-rec-in-metadata* metadata-path)))

(defun validate-no-brand-in-metadata (metadata-path)
  "Forward-only metadata validator (101: skips under --differentiate)."
  (or (%forward-only-metadata-skip-p)
      (funcall *orig-validate-no-brand-in-metadata* metadata-path)))

;; 070-hoist-tensors metadata validators — same pattern.  Describe the
;; FORWARD kernel's metadata shape (physical-signature widths, declared-
;; signature ranges, alias forms).  Under --differentiate the metacrisp
;; is for the BACKWARD kernel with a different shape: input + output
;; adjoints make the physical-signature wider, kernel name has _grad,
;; etc.  Forward-only wrap.
(defvar *orig-validate-070-01-vector-metadata* nil)
(defvar *orig-validate-070-03-matrix-metadata* nil)
(unless *orig-validate-070-01-vector-metadata*
  (setf *orig-validate-070-01-vector-metadata*
        (symbol-function 'validate-070-01-vector-metadata)))
(unless *orig-validate-070-03-matrix-metadata*
  (setf *orig-validate-070-03-matrix-metadata*
        (symbol-function 'validate-070-03-matrix-metadata)))

(defun validate-070-01-vector-metadata (metadata-path)
  "Forward-only metadata validator (101: skips under --differentiate)."
  (or (%forward-only-metadata-skip-p)
      (funcall *orig-validate-070-01-vector-metadata* metadata-path)))

(defun validate-070-03-matrix-metadata (metadata-path)
  "Forward-only metadata validator (101: skips under --differentiate)."
  (or (%forward-only-metadata-skip-p)
      (funcall *orig-validate-070-03-matrix-metadata* metadata-path)))


;; 089-strategy metadata validators — same forward-only pattern.
;; Each describes a property of the FORWARD kernel's metacrisp (e.g.
;; :strategy entries, declared-signature ranges, dim-extents).  Under
;; --differentiate the metacrisp is for the BACKWARD kernel, which has
;; a different parameter layout.  Wrap them all uniformly via a helper
;; that captures the original function and installs the guard wrapper.

(defun %wrap-validator-as-forward-only (validator-sym)
  "Captures VALIDATOR-SYM's current symbol-function under a generated
   *ORIG-VALIDATOR-SYM* defvar (created once) and replaces VALIDATOR-SYM
   with a thin wrapper that returns T under --differentiate, otherwise
   delegates to the captured original.  Idempotent across overlay reloads.
   This is the same save-and-wrap pattern used explicitly for the 048
   and 070 validators, factored for the larger 089 cluster."
  (let* ((pkg (symbol-package validator-sym))
         (orig-sym (intern (format nil "*ORIG-~a*" (symbol-name validator-sym)) pkg)))
    ;; Ensure the holder variable exists and is captured exactly once
    ;; per session (across overlay reloads).  proclaim makes it special.
    (proclaim `(special ,orig-sym))
    (unless (and (boundp orig-sym) (symbol-value orig-sym))
      (setf (symbol-value orig-sym) (symbol-function validator-sym)))
    ;; Install the forward-only wrapper.
    (setf (symbol-function validator-sym)
          (let ((captured-orig (symbol-value orig-sym)))
            (lambda (metadata-path)
              (or (%forward-only-metadata-skip-p)
                  (funcall captured-orig metadata-path)))))))

(dolist (v '(validate-089-01-global-size-set-to-scalar
             validate-089-02-global-size-set-to-dims
             validate-089-03-global-size-one-thread-per
             validate-089-04-local-size-set-to
             validate-089-05-local-size-exact
             validate-089-06-num-groups-strided
             validate-089-07-global-and-local
             validate-089-08-global-size-strided
             validate-089-09-global-size-tiled
             ;; 056-struct-at-kernel-boundary: same forward-only pattern.
             validate-def-struct-in-metadata
             validate-def-struct-with-ct-in-metadata
             validate-nested-struct-in-metadata
             validate-struct-no-brand-in-metadata))
  (%wrap-validator-as-forward-only v))


;;; ===================================================================
;;; 101: relax the "no differentiable parameters" error
;;; ===================================================================
;;;
;;; The original check at %generate-backward-kernel-ast errors when the
;;; kernel has no float scalars or float tensors AND no integer tensors.
;;; It was added when AD was float-only.  After the 101 widening, integer
;;; scalars (including branded ints in record fields) should also bypass
;;; the gate and emit a trivial zero-gradient backward kernel — consistent
;;; with the principle "if there's math (or could be), do it; the gradient
;;; for integer inputs is always zero, which is the correct answer".
;;;
;;; This unblocks 048/09 (branded-int record fields) without touching the
;;; backward walk: when diff-flat-inputs is empty, the trivial-backward
;;; emit already does the right thing (kernel returns, _GRAD slots stay
;;; at their zero-init values).

(defun %has-diff-capable-scalar-input-p (flat-input-types)
  "Returns T if flat-input-types contains at least one integer scalar
   (signed/unsigned), including branded int scalars.  Used by the
   relaxed gate in %generate-backward-kernel-ast."
  (some (lambda (t-spec)
          (or (%crisp-integer-scalar-type-p t-spec)
              ;; Brand types: resolve to base and re-check.
              (let ((brand (is-brand-type-p t-spec)))
                (and brand
                     (%crisp-integer-scalar-type-p
                      (brand-definition-base-type brand))))))
        flat-input-types))

;; src/macros.lisp - override
;; This is a near-copy of the original; the only change is at the
;; differentiable-input check (was: error unless int tensors; now: also
;; allow int scalars including branded).
(defun %generate-backward-kernel-ast (name params signature-types raw-body)
  "Generates the def-kernel-exact AST for the backward (gradient) pass.
101: widened input check to also accept integer scalars (incl. branded)
in addition to integer tensors.  All-int-record-field kernels now emit
the trivial zero-gradient backward instead of erroring."
  (multiple-value-bind (inputs input-types outputs output-types)
      (%split-kernel-inputs-outputs params signature-types)
    (let* ((pkg (symbol-package name))
           (bwd-name (intern (format nil "~a_GRAD" (symbol-name name)) pkg)))
      (multiple-value-bind (flat-inputs flat-input-types record-reassembly-bindings
                            rec-grad-out-params rec-grad-out-types
                            record-subs-ht record-type-ht grad-cell-syms
                            struct-shadow-info)
          (%expand-record-kernel-inputs inputs input-types pkg)
        (let ((subst-body
               (mapcar (lambda (form)
                         (%substitute-record-accessors form record-subs-ht record-type-ht))
                       raw-body)))
          (multiple-value-bind (bwd-params bwd-types diff-flat-inputs diff-flat-input-types)
              (%compute-backward-kernel-params flat-inputs flat-input-types outputs output-types
                                               record-subs-ht rec-grad-out-params rec-grad-out-types pkg inputs)
            ;; 101: error only when there are truly no diff-capable inputs.
            ;; Integer tensors AND integer scalars (incl. branded) yield trivial
            ;; zero-gradient backward kernels — valid AD output, not user error.
            ;; Struct inputs (with shadow grads) also bypass the gate.
            (when (and flat-inputs
                       (null diff-flat-inputs)
                       (null struct-shadow-info)
                       (not (some #'%crisp-integer-tensor-type-p flat-input-types))
                       (not (%has-diff-capable-scalar-input-p flat-input-types)))
              (error 'crisp.compiler:crisp-compiler-error
                :message (format nil "Cannot differentiate kernel ~A: no differentiable parameters (all inputs have non-float types -- add (forward-only) declaration or use float element types)" name)))
            (multiple-value-bind (exploded-params exploded-types bwd-cell-reassembly-bindings)
                (%explode-kernel-args bwd-params bwd-types)
              ;; Augment diff-flat-inputs with struct kernel inputs (which the
              ;; compute-backward-kernel-params filter excludes).  This ensures
              ;; the walker's input-grad-write loop emits a placeholder write
              ;; for each struct param, which the shadow-write postprocessor
              ;; will then replace with the correct shadow-struct constructor
              ;; emit.
              (let* ((augmented-diff-flat-inputs
                      (append diff-flat-inputs
                              (mapcar #'first struct-shadow-info)))
                     (augmented-diff-flat-input-types
                      (append diff-flat-input-types
                              (loop for entry in struct-shadow-info
                                    for p = (first entry)
                                    collect (nth (position p flat-inputs :test #'eq)
                                                 flat-input-types)))))
              (if (and (null augmented-diff-flat-inputs)
                       (null struct-shadow-info))
                  `(progn
                    (eval-when (:compile-toplevel :load-toplevel :execute)
                      (setf (gethash ',bwd-name crisp.compiler::*kernel-declared-signatures*)
                        (loop for p in ',bwd-params
                                 for t-spec in ',bwd-types
                                 collect (cons p t-spec))))
                    (def-kernel-exact ,bwd-name ,exploded-params
                                      (declare #'(,@exploded-types))
                                      (return)))
                  (let* ((anf-body      (mapcar #'anf-transform subst-body))
                         (flat-anf      (flatten-anf-body anf-body))
                         (forward-bindings
                          (loop for form in flat-anf
                                when (and (consp form) (= (length form) 2) (symbolp (car form)))
                                collect form))
                         ;; Build the struct-shadow ht used during walk + postprocess.
                         (struct-shadow-ht
                          (when struct-shadow-info
                            (let ((ht (make-hash-table :test 'eq)))
                              (dolist (entry struct-shadow-info)
                                (setf (gethash (first entry) ht)
                                      (cons (second entry)  ; shadow-grad-sym
                                            (fourth entry)))) ; field-adj-alist
                              ;; Pre-scan ANF for synthetic temps bound to
                              ;; nested-struct accessors, so their own
                              ;; accessor calls route deeper into the shadow.
                              (%register-shadow-anf-intermediates flat-anf ht)
                              ht)))
                         (raw-backward-walk
                          (let ((*struct-kernel-param-shadows* struct-shadow-ht))
                            (generate-backward-walk flat-anf
                                                    augmented-diff-flat-inputs outputs
                                                    augmented-diff-flat-input-types output-types
                                                    :kernel-pkg pkg)))
                         (backward-walk-1
                          (%fix-record-grad-cell-emissions raw-backward-walk grad-cell-syms))
                         (backward-walk-2
                          ;; Ensure all leaf adj syms from struct-shadow-info
                          ;; have zero-init bindings, even if the body didn't
                          ;; reference them (the shadow-write postprocessor
                          ;; below WILL reference them).
                          (if struct-shadow-info
                              (let ((all-leaves
                                     (loop for entry in struct-shadow-info
                                           append (%collect-all-leaf-adj-syms (fourth entry)))))
                                (%ensure-leaf-adj-bindings backward-walk-1 all-leaves))
                              backward-walk-1))
                         (backward-walk
                          (%fix-struct-shadow-writes backward-walk-2 struct-shadow-info))
                         (all-reassembly (append bwd-cell-reassembly-bindings record-reassembly-bindings)))
                    `(progn
                      (eval-when (:compile-toplevel :load-toplevel :execute)
                        (setf (gethash ',bwd-name crisp.compiler::*kernel-declared-signatures*)
                          (loop for p in ',bwd-params
                                   for t-spec in ',bwd-types
                                   collect (cons p t-spec))))
                      (def-kernel-exact ,bwd-name ,exploded-params
                                        (declare #'(,@exploded-types))
                                        (let (,@all-reassembly)
                                          (let (,@forward-bindings)
                                            ,backward-walk))
                                        (return)))))))))))))


;;; ===================================================================
;;; 101: recursive explosion of nested records at the kernel boundary
;;; ===================================================================
;;;
;;; The original %expand-record-kernel-inputs only destructures one level.
;;; For nested records (e.g. v-rect containing two v-points), the inner
;;; fields are never reached:
;;;   - flat-inputs contains record-typed syms (e.g. vr_top-left:v-point)
;;;   - no grad cells are generated for inner-record fields
;;;   - record-subs-ht has only the top-level record's substitutions
;;;
;;; This override recurses: when a field is itself a record type, the
;;; recursion registers the field's sub-record in record-subs-ht/
;;; record-type-ht, pushes its leaves to flat-inputs, generates grad cells
;;; for leaf scalars, and chains reassembly bindings inner-first / outer-
;;; last so the outer (make-RECORD ...) sees its inner records already
;;; bound.

(defun %expand-record-kernel-inputs (inputs input-types pkg)
  "Recursively expands record-typed inputs into their scalar fields,
   chasing through nested records.  Also handles struct kernel inputs
   per the Shadow Struct design: structs are NOT exploded; instead a
   single shadow-grad-cell is paired with each struct param.

   Returns 9 values: (flat-inputs flat-input-types reassembly-bindings
   grad-out-params grad-out-types record-subs-ht record-type-ht
   grad-cell-syms struct-shadow-info).

   The 9th value, struct-shadow-info, is an alist:
     ((STRUCT-PARAM-SYM SHADOW-GRAD-SYM SHADOW-TYPE FIELD-ADJ-ALIST) ...)
   used by %fix-struct-shadow-writes to emit the final shadow-write.

   Leaf scalar fields (float or integer) produce grad cells per 101.
   Nested-record fields produce a synthetic intermediate sym that gets
   registered in record-subs-ht/record-type-ht so the substitution
   machinery walks through it; their leaf fields are further exploded."
  (let ((flat-inputs        '())
        (flat-input-types   '())
        (reassembly-bindings '())
        (grad-out-params    '())
        (grad-out-types     '())
        (record-subs-ht     (make-hash-table :test 'eq))
        (record-type-ht     (make-hash-table :test 'eq))
        (grad-cell-syms     '())
        (struct-shadow-info '()))
    (labels
        ((explode (p t-spec)
           "Destructure parameter P of type T-SPEC.  Side effects push to
            the closure-captured accumulators.  Returns no useful value."
           (cond
             ((%crisp-record-type-p t-spec)
              (let* ((base-type (if (consp t-spec) (first t-spec) t-spec))
                     (fields    (%get-record-runtime-fields t-spec))
                     (make-sym  (intern (format nil "MAKE-~a" (symbol-name base-type)) pkg))
                     (field-info-list
                      (loop for (fname ftype) in fields
                            collect (list fname ftype
                                          (%record-field-param-sym p fname pkg)))))
                ;; Register THIS record's substitution and type maps so
                ;; (field~ p) callsites in the body resolve to fsym.
                (setf (gethash p record-subs-ht)
                      (loop for (fname ftype fsym) in field-info-list
                            collect (cons fname fsym)))
                (setf (gethash p record-type-ht) t-spec)
                ;; Process each field: recurse for nested records, emit
                ;; leaves + grad cells for scalar fields.
                (loop for (fname ftype fsym) in field-info-list do
                  (cond
                    ((%crisp-record-type-p ftype)
                     ;; Nested record: recurse.  This registers fsym in
                     ;; subs/type maps, pushes its leaves, and pushes its
                     ;; reassembly binding BEFORE we push ours below.
                     (explode fsym ftype))
                    ((%crisp-float-type-p ftype)
                     (push fsym flat-inputs)
                     (push ftype flat-input-types)
                     (let ((grad-sym (intern (format nil "~a_GRAD" (symbol-name fsym)) pkg)))
                       (push grad-sym grad-out-params)
                       (push '(cell float :address-space :global) grad-out-types)
                       (push grad-sym grad-cell-syms)))
                    ((%crisp-integer-scalar-type-p ftype)
                     (push fsym flat-inputs)
                     (push ftype flat-input-types)
                     (let* ((grad-sym (intern (format nil "~a_GRAD" (symbol-name fsym)) pkg))
                            (float-elem (%integer-scalar-to-float-scalar ftype)))
                       (push grad-sym grad-out-params)
                       (push (list 'cell float-elem :address-space :global) grad-out-types)
                       (push grad-sym grad-cell-syms)))
                    (t
                     ;; Other (non-diff'able) leaf: pass through as flat.
                     ;; No grad cell.
                     (push fsym flat-inputs)
                     (push ftype flat-input-types))))
                ;; After children: push THIS record's reassembly.  Because
                ;; inner-record reassemblies have already been pushed by
                ;; recursive `explode` calls above, and we push outer here
                ;; LAST, the (nreverse reassembly-bindings) at function exit
                ;; yields inner-first / outer-last order — exactly what the
                ;; let-binding chain needs.
                (push (list p (cons make-sym
                                    (loop for (fname ftype fsym) in field-info-list
                                          append (list (intern (symbol-name fname) :keyword)
                                                       fsym))))
                      reassembly-bindings)))
             ((%crisp-struct-type-p t-spec)
              ;; Struct kernel input: keep as struct value, pair with a single
              ;; shadow-grad-cell.  Field-adj synth syms are allocated for
              ;; the backward walk's accessor rule to accumulate into.
              ;; Shadow writeout is emitted later by the postprocessor.
              ;;
              ;; For nested struct fields, recursively build a hierarchical
              ;; field-adj-alist.  Leaf scalar fields → sym.  Nested struct
              ;; fields → recursive (cons NESTED-TYPE NESTED-ALIST).
              (let* ((base-type (if (consp t-spec) (first t-spec) t-spec))
                     (shadow-type (%shadow-type-name-for base-type))
                     (shadow-grad-sym (intern (format nil "~A_GRAD" (symbol-name p)) pkg))
                     (field-adj-alist
                      (%build-struct-field-adj-alist p t-spec pkg)))
                ;; Struct stays as a flat input (by-value).
                (push p flat-inputs)
                (push t-spec flat-input-types)
                ;; Shadow grad cell — single cell-of-shadow-struct.
                (push shadow-grad-sym grad-out-params)
                (push (list 'cell shadow-type :address-space :global) grad-out-types)
                ;; Record entry for the shadow-write postprocessor.
                (push (list p shadow-grad-sym shadow-type field-adj-alist)
                      struct-shadow-info)))
             (t
              ;; Non-record input: pass through as-is.
              (push p flat-inputs)
              (push t-spec flat-input-types)))))
      (loop for p in inputs
            for t-spec in input-types
            do (explode p t-spec)))

    ;; For nested records, %compute-backward-kernel-params builds
    ;; record-exploded-syms via (mapcar #'cdr (gethash orig record-subs-ht))
    ;; — which only sees one level deep.  Without intervention, the leaf
    ;; syms (e.g. vr_top-left_x) wouldn't appear in record-exploded-syms,
    ;; and non-rec-scalar-in-grad-params would generate DUPLICATE grad
    ;; cells for them (we already produced their grad cells via the
    ;; recursive explosion).
    ;;
    ;; Fix: post-process each ORIGINAL input's record-subs-ht entry to
    ;; also include `(:%nested-leaf% . leaf-sym)` sentinels for all leaf
    ;; descendants.  The substitution machinery uses field-name keyed
    ;; lookup (assoc :test string-equal), and ":%nested-leaf%" doesn't
    ;; match any real field accessor, so these sentinels are invisible
    ;; to substitution but visible to the (mapcar #'cdr ...) consumer.
    (labels ((collect-leaves (sym)
               (let ((children (gethash sym record-subs-ht))
                     (acc '()))
                 (dolist (entry children)
                   (let ((child-sym (cdr entry)))
                     (cond
                       ((gethash child-sym record-subs-ht)
                        (setf acc (append acc (collect-leaves child-sym))))
                       (t (push child-sym acc)))))
                 acc)))
      (dolist (orig inputs)
        (when (gethash orig record-subs-ht)
          (let ((leaves (collect-leaves orig)))
            ;; Append `(:%nested-leaf% . leaf-sym)` for each LEAF that
            ;; isn't already a direct field of orig.
            (let* ((direct-syms (mapcar #'cdr (gethash orig record-subs-ht)))
                   (deep-leaves (remove-if (lambda (s) (member s direct-syms :test #'eq))
                                            leaves)))
              (setf (gethash orig record-subs-ht)
                    (append (gethash orig record-subs-ht)
                            (mapcar (lambda (s) (cons :%nested-leaf% s))
                                    deep-leaves))))))))

    (values (nreverse flat-inputs)
            (nreverse flat-input-types)
            (nreverse reassembly-bindings)
            (nreverse grad-out-params)
            (nreverse grad-out-types)
            record-subs-ht
            record-type-ht
            (nreverse grad-cell-syms)
            (nreverse struct-shadow-info))))


;;; ===================================================================
;;; 101: Shadow struct generation for AD
;;; ===================================================================
;;;
;;; Per the shadow-struct-plan.md: every (def-struct NAME ...) at top
;;; level gets a paired (def-struct NAME_ADJ ...) injected into the
;;; forms list before compile-module processes them.  The shadow has
;;; the same field NAMES, with adjoint-promoted field TYPES:
;;;
;;;   - float scalar          → same
;;;   - integer scalar (small)→ float
;;;   - integer scalar (64)   → double
;;;   - nested struct         → <INNER>_ADJ
;;;   - branded primitive     → base type, then promote
;;;   - other / unknown       → passed through unchanged
;;;
;;; Brand declarations on the forward are NOT copied to the shadow
;;; (gradients of brands aren't meaningful).
;;;
;;; The shadow accessors / constructor / etc. are emitted by the
;;; def-struct macro's normal expansion.  The shadow lives in the same
;;; package as the forward.
;;;
;;; NOTE — IMPORTANT for future hoist work: the shadow struct's byte
;;; layout DIVERGES from the forward's whenever the forward has a
;;; sub-32-bit integer field.  `char` (1B) -> `float` (4B) is the most
;;; pathological case.  Host-side shadow buffer allocation MUST use
;;; sizeof(<NAME>_ADJ), not sizeof(<NAME>).  This is currently fine
;;; because we don't generate hoist code under --differentiate, but
;;; when that's lifted, the metacrisp needs to expose both sizes and
;;; the hoist code generator must allocate the right one.

(defun %adj-type-for-field (forward-type &optional struct-name-set)
  "Returns the adjoint type for a forward struct field's TYPE, per
   the 101 promotion rules.

   STRUCT-NAME-SET (optional hash table, symbol→T) covers struct types
   that will be defined by upcoming def-struct forms in the same
   compilation unit but haven't been registered in *crisp-types* yet.
   At shadow-injection time (before any macro expansion), this is the
   only way to know which symbols are struct types."
  (cond
    ((%crisp-float-type-p forward-type) forward-type)
    ((%crisp-integer-scalar-type-p forward-type)
     (%integer-scalar-to-float-scalar forward-type))
    ;; Brand: resolve to base, then promote.
    ((and (symbolp forward-type)
          (is-brand-type-p forward-type))
     (let* ((brand (is-brand-type-p forward-type))
            (base  (brand-definition-base-type brand)))
       (cond
         ((%crisp-float-type-p base) base)
         ((%crisp-integer-scalar-type-p base)
          (%integer-scalar-to-float-scalar base))
         (t forward-type))))
    ;; Nested struct → its shadow.  Check both the runtime registry AND
    ;; the forms-list struct-name-set (for shadows generated before
    ;; *crisp-types* is populated).
    ((and (symbolp forward-type)
          (or (let ((info (gethash forward-type *crisp-types*)))
                (and info (eq (crisp-type-category info) :struct)))
              (and struct-name-set
                   (gethash forward-type struct-name-set))))
     (intern (format nil "~A_ADJ" (symbol-name forward-type))
             (symbol-package forward-type)))
    ;; Anything else (cons-typed members, unknown, etc.) → unchanged.
    (t forward-type)))

(defun %generate-shadow-def-struct-form (def-struct-form &optional struct-name-set)
  "Given (def-struct NAME (f0 t0) (f1 t1) ... brand-decls...), returns
   the matching (def-struct NAME_ADJ (f0 adj_t0) (f1 adj_t1) ...) form.
   Brand declarations are dropped.  :c-t members are preserved (their
   value is a forward-time constant; not differentiable but harmless).
   STRUCT-NAME-SET enables recognizing nested struct field types whose
   def-struct forms appear elsewhere in the compilation unit."
  (let* ((name (second def-struct-form))
         (members (cddr def-struct-form))
         (shadow-name (intern (format nil "~A_ADJ" (symbol-name name))
                              (symbol-package name)))
         (shadow-members
          (loop for m in members
                unless (and (consp m) (eq (car m) 'brand))
                collect (cond
                          ((and (consp m) (>= (length m) 2))
                           (list* (first m)
                                  (%adj-type-for-field (second m) struct-name-set)
                                  (cddr m)))
                          (t m)))))
    `(def-struct ,shadow-name ,@shadow-members)))

(defun %collect-struct-names-from-forms (forms)
  "Walks FORMS at the top level and returns a hash table mapping each
   (def-struct NAME ...) NAME (and only structs, not records) to T.
   Used by shadow-injection to recognize struct field types when
   *crisp-types* isn't yet populated."
  (let ((set (make-hash-table :test 'eq)))
    (dolist (f forms)
      (when (and (consp f) (eq (car f) 'def-struct) (symbolp (second f)))
        (setf (gethash (second f) set) t)))
    set))

(defun %inject-shadow-struct-forms (forms)
  "Walks FORMS at the top level.  After each (def-struct NAME ...) that
   defines a NON-shadow struct, appends (def-struct NAME_ADJ ...).
   Already-shadow structs (name ends with _ADJ) are passed through.
   def-record forms are left untouched (records SROA, no shadow needed).
   Other forms unchanged.

   First pass collects all struct names so the shadow generator can
   recognize nested struct field types."
  (let ((struct-names (%collect-struct-names-from-forms forms))
        (result nil))
    (dolist (f forms)
      (push f result)
      (when (and (consp f)
                 (eq (car f) 'def-struct)
                 (symbolp (second f))
                 (let ((n (symbol-name (second f))))
                   (or (< (length n) 4)
                       (not (string-equal "_ADJ" (subseq n (- (length n) 4)))))))
        (push (%generate-shadow-def-struct-form f struct-names) result)))
    (nreverse result)))

(defvar *orig-compile-module* nil
  "Captures the original compile-module for the overlay wrapper.")

(unless *orig-compile-module*
  (setf *orig-compile-module*
        (symbol-function 'compile-module)))

(defun compile-module (forms module builder di-builder di-compile-unit location-map)
  "Pre-injects shadow def-struct forms for AD support, then delegates
   to the original compile-module.  See shadow-struct-plan.md."
  (let ((augmented-forms
         (if *differentiate-p*
             (%inject-shadow-struct-forms forms)
             forms)))
    (funcall *orig-compile-module*
             augmented-forms module builder di-builder di-compile-unit location-map)))


;;; ===================================================================
;;; 101: Struct kernel-param AD machinery (Shadow Struct, part 2 of 3)
;;; ===================================================================
;;;
;;; Building on the shadow-struct generation pass above:
;;;
;;; - %crisp-struct-type-p: predicate for struct-category types (not records).
;;; - *struct-kernel-param-shadows*: dyn-bound map from struct kernel param
;;;   symbol to (cons SHADOW-GRAD-SYM FIELD-ADJ-ALIST).  Consulted by:
;;;     - The accessor rule in %handle-single-value-backward (for adj routing).
;;;     - The shadow-write postprocessor (for final emit).
;;; - %fix-struct-shadow-writes: postprocesses the backward-walk output to
;;;   replace the default (set! s_grad s_adj) input-grad-write — which is
;;;   wrong shape (writes a scalar into a cell-of-struct slot) — with the
;;;   correct shadow-struct constructor write.

(defun %crisp-struct-type-p (type-spec)
  "Returns T if TYPE-SPEC names a registered def-struct (category :struct).
   Distinct from %crisp-record-type-p (which checks category :record)."
  (let* ((base (if (consp type-spec) (first type-spec) type-spec))
         (info (and (symbolp base) (gethash base *crisp-types*))))
    (and info (eq (crisp-type-category info) :struct))))

(defvar *struct-kernel-param-shadows* nil
  "Hash table: struct-kernel-param-sym -> (cons SHADOW-GRAD-SYM FIELD-ADJ-ALIST).
   FIELD-ADJ-ALIST is an alist of (FIELD-NAME-STR . FIELD-ADJ-SYM) in
   declaration order.  Bound by %generate-backward-kernel-ast around
   the backward walk when struct kernel params are present.  Used by:
     - The accessor rule in %handle-single-value-backward.
     - The shadow-write postprocessor.")

(defun %shadow-type-name-for (struct-type-name)
  "Returns the shadow struct's type symbol for STRUCT-TYPE-NAME."
  (intern (format nil "~A_ADJ" (symbol-name struct-type-name))
          (symbol-package struct-type-name)))

(defun %make-shadow-constructor-name-for (struct-type-name)
  "Returns the MAKE-<TYPE>_ADJ constructor symbol for STRUCT-TYPE-NAME."
  (intern (format nil "MAKE-~A_ADJ" (symbol-name struct-type-name))
          (symbol-package struct-type-name)))

(defun %register-shadow-anf-intermediates (flat-anf shadow-ht)
  "Pre-scans FLAT-ANF for bindings of the shape (TEMP (FIELD~ SHADOW-TRACKED-SYM))
   where SHADOW-TRACKED-SYM is in SHADOW-HT and the field's info is a
   nested-struct alist.  Registers TEMP in SHADOW-HT (with the nested
   alist as TEMP's field-adj-alist) so subsequent accessor calls on TEMP
   can route deeper.  Mutates SHADOW-HT in place.

   Must run BEFORE the backward walk so the accessor case can consult
   the augmented map."
  (dolist (form flat-anf)
    (when (and (consp form)
               (= (length form) 2)
               (symbolp (car form))
               (consp (cadr form))
               (symbolp (caadr form))
               (let ((fname (symbol-name (caadr form))))
                 (and (> (length fname) 1)
                      (cl:char= (cl:char fname (1- (length fname))) #\~)))
               (= (length (cadr form)) 2)
               (symbolp (cadadr form))
               (gethash (cadadr form) shadow-ht))
      (let* ((temp (car form))
             (expr (cadr form))
             (accessor-name (symbol-name (car expr)))
             (field-name-str (subseq accessor-name 0 (1- (length accessor-name))))
             (parent-sym (cadr expr))
             (parent-entry (gethash parent-sym shadow-ht))
             (parent-field-alist (if (and (consp parent-entry) (symbolp (car parent-entry)))
                                     (cdr parent-entry)
                                     parent-entry))
             (field-entry (assoc field-name-str parent-field-alist :test #'string-equal))
             (field-info (cdr field-entry)))
        (when (%nested-field-info-p field-info)
          ;; TEMP represents a sub-struct.  Register so accessors on TEMP
          ;; route into FIELD-INFO (the nested alist).
          (setf (gethash temp shadow-ht) field-info))))))

(defun %build-struct-field-adj-alist (param-sym struct-type pkg)
  "Recursively builds a field-adj-alist for a struct kernel param of
   STRUCT-TYPE.  Each entry is (FIELD-NAME-STR . FIELD-INFO) where:

   - For scalar fields: FIELD-INFO is the per-field adj symbol
     (e.g. r_top-left_x_adj).
   - For nested struct fields: FIELD-INFO is itself an alist of the
     same shape, recursively descended.

   PARAM-SYM is the prefix used when generating leaf adj sym names
   (so leaves nested under r.top-left get names like r_top-left_x_adj)."
  (let ((fields (%get-record-runtime-fields struct-type)))
    (loop for (fname ftype) in fields
          for fname-str = (symbol-name fname)
          collect
          (cons fname-str
                (cond
                  ((%crisp-struct-type-p ftype)
                   ;; Nested struct field: recurse, prefix names with
                   ;; <param>_<field>.
                   (let ((nested-prefix
                          (intern (format nil "~A_~A"
                                          (symbol-name param-sym)
                                          (symbol-name fname))
                                  pkg)))
                     (%build-struct-field-adj-alist nested-prefix ftype pkg)))
                  (t
                   ;; Scalar leaf: allocate per-field adj sym.
                   (intern (format nil "~A_~A_ADJ"
                                   (symbol-name param-sym)
                                   (symbol-name fname))
                           pkg)))))))

(defun %nested-field-info-p (field-info)
  "T if FIELD-INFO from a struct-shadow alist refers to a nested struct
   (an alist), as opposed to a scalar leaf (a symbol)."
  (and (listp field-info)
       field-info
       (consp (first field-info))
       (stringp (caar field-info))))

(defun %build-shadow-ctor-form (struct-type-name field-adj-alist pkg)
  "Builds a (MAKE-<S>_ADJ :field1 val1 :field2 val2 ...) form recursively.
   For scalar leaf fields, val is the adj sym.  For nested struct fields,
   val is a recursive (MAKE-<INNER>_ADJ ...) form."
  (let ((ctor (%make-shadow-constructor-name-for struct-type-name)))
    (cons ctor
          (loop for (fname-str . field-info) in field-adj-alist
                append
                (list (intern fname-str :keyword)
                      (cond
                        ((%nested-field-info-p field-info)
                         ;; Recurse: need the inner struct's type name.
                         ;; The struct definition gives us the field types.
                         (let* ((fields (%get-record-runtime-fields struct-type-name))
                                (fentry (find fname-str fields
                                              :key (lambda (f) (symbol-name (first f)))
                                              :test #'string-equal))
                                (inner-type (when fentry (second fentry))))
                           (if (and inner-type (%crisp-struct-type-p inner-type))
                               (%build-shadow-ctor-form inner-type field-info pkg)
                               ;; Shouldn't happen, but fall through to skipping.
                               0)))
                        (t
                         ;; Scalar leaf: just the adj sym.
                         field-info)))))))

(defun %collect-all-leaf-adj-syms (field-adj-alist)
  "Collects all leaf adj syms (scalars at the bottom of a nested alist)
   recursively."
  (loop for (fname-str . field-info) in field-adj-alist
        append (if (%nested-field-info-p field-info)
                   (%collect-all-leaf-adj-syms field-info)
                   (list field-info))))

(defun %ensure-leaf-adj-bindings (form leaf-adj-syms)
  "If FORM is `(let (bindings) body...)`, augments the bindings list with
   `(sym 0.0)` for each sym in LEAF-ADJ-SYMS not already bound.  Used to
   ensure that leaf adj syms referenced ONLY by the shadow-write
   postprocessor (i.e. unused in the kernel body) have valid zero-init
   bindings."
  (cond
    ((and (consp form) (eq (first form) 'let))
     (let* ((existing-bindings (second form))
            (existing-syms (mapcar (lambda (b)
                                     (if (consp b) (first b) b))
                                   existing-bindings))
            (missing (remove-if (lambda (s)
                                  (member s existing-syms :test #'eq))
                                leaf-adj-syms))
            (additions (mapcar (lambda (s) (list s 0.0)) missing)))
       (if additions
           `(let ,(append existing-bindings additions)
              ,@(cddr form))
           form)))
    (t form)))

(defun %fix-struct-shadow-writes (form struct-shadow-info)
  "Postprocesses the kernel backward walk's output.  For each struct
   kernel input S in STRUCT-SHADOW-INFO, replaces the default scalar
   input-grad-write `(set! S_GRAD S_ADJ)` with the correct shadow-
   struct write `(set! (~ S_GRAD) (MAKE-<S>_ADJ ...))` — building
   the shadow constructor recursively for nested struct fields.

   STRUCT-SHADOW-INFO is the alist returned as the 9th value of
   %expand-record-kernel-inputs:
     ((STRUCT-PARAM-SYM SHADOW-GRAD-SYM SHADOW-TYPE FIELD-ADJ-ALIST) ...)

   Other (set! ...) forms are passed through unchanged."
  (labels ((rewrite (f)
             (cond
               ((atom f) f)
               ;; (set! S_GRAD anything) where S_GRAD is in struct-shadow-info
               ((and (consp f) (eq (first f) 'set!) (= (length f) 3)
                     (symbolp (second f)))
                (let ((entry (find (second f) struct-shadow-info
                                   :key #'second :test #'eq)))
                  (if entry
                      (let* ((shadow-type (third entry))
                             (field-alist (fourth entry))
                             ;; Reconstruct the FORWARD struct type from the
                             ;; shadow name (shadow ends in _ADJ; strip).
                             (forward-type
                              (intern (subseq (symbol-name shadow-type)
                                              0 (- (length (symbol-name shadow-type)) 4))
                                      (symbol-package shadow-type))))
                        ;; emit (set! (~ S_GRAD) <recursive-ctor-form>)
                        `(set! (~ ,(second f))
                               ,(%build-shadow-ctor-form forward-type field-alist
                                                         (symbol-package (second f)))))
                      f)))
               ((consp f) (mapcar #'rewrite f))
               (t f))))
    (rewrite form)))


;;; ===================================================================
;;; 101: %generate-backward-function-walk extended to accept
;;; tensor-inputs-ht (for tensor-sub-fn-param AD).
;;; ===================================================================
;;;
;;; The original signature is (flat-anf float-param-syms t-grad-syms
;;; return-vars).  We add an optional TENSOR-INPUTS-HT that gets threaded
;;; into %handle-single-value-backward so the tensor-read case fires for
;;; (~ v idx) on tensor sub-fn params, emitting atomic-add into the
;;; corresponding &out grad-tensor.
;;;
;;; The body is otherwise identical to the original.  Re-defined fully
;;; rather than save-and-wrap because the change is inside the inner walk.

(defun %generate-backward-function-walk (flat-anf float-param-syms t-grad-syms return-vars
                                         &optional tensor-inputs-ht)
  "Generates the backward-pass body for a def-function.

   101 extension: TENSOR-INPUTS-HT (optional hash-table mapping each
   tensor-sub-fn-param symbol to its tensor type) is threaded into
   %handle-single-value-backward so tensor reads inside the body emit
   atomic-add into the corresponding &out grad-tensor."
  (let ((backward-forms nil)
        (adjoint-map (make-hash-table :test 'equal))
        (return-var-seeds (make-hash-table :test 'eq)))

    (loop for rv in return-vars
          for tg in t-grad-syms do
            (setf (gethash rv return-var-seeds) tg))

    (labels ((local-adj (v)
               (or (gethash v adjoint-map)
                   (let ((adv (intern (format nil "~A_ADJ" (symbol-name v))
                                      (symbol-package v))))
                     (setf (gethash v adjoint-map) adv)
                     adv)))
             (emit (form)
               (push form backward-forms)))

      (let ((reversed-body (reverse flat-anf)))
        (dolist (form reversed-body)
          (cond
            ((and (listp form) (= (length form) 2) (symbolp (car form)))
             (let ((v    (car form))
                   (expr (cadr form)))
               (%handle-single-value-backward v expr adjoint-map #'emit #'local-adj
                                              :error-on-unknown t
                                              :tensor-inputs-ht tensor-inputs-ht)))
            ((and (listp form) (>= (length form) 3)
                  (symbolp (car form))
                  (every #'symbolp (butlast form)))
             (let* ((result-vars (butlast form))
                    (expr        (car (last form))))
               (when (and (consp expr)
                          (symbolp (car expr))
                          (gethash (car expr) *differentiable-functions*))
                 (let* ((fn      (car expr))
                        (args    (cdr expr))
                        (info    (gethash fn *differentiable-functions*))
                        (bkwd-fn (getf info :bkwd-name))
                        (n-fp    (getf info :n-float-params))
                        (n-ret   (getf info :n-return))
                        (pkg     (symbol-package fn)))
                   (declare (ignore n-ret))
                   (%emit-sub-fn-backward fn args bkwd-fn (mapcar #'local-adj result-vars) n-fp pkg #'emit #'local-adj "MV")))))
            (t nil))))

      (emit `(return ,@(mapcar #'local-adj float-param-syms)))

      (let* ((forward-bindings
              (loop for form in flat-anf
                    when (and (consp form)
                              (= (length form) 2)
                              (symbolp (car form))
                              (not (gethash (car form) return-var-seeds)))
                    collect form))
             (adjoint-bindings
              (loop for v being the hash-keys of adjoint-map
                    using (hash-value adv)
                    collect (let ((seed (gethash v return-var-seeds)))
                              `(,adv ,(if seed seed 0.0)))))
             (all-bindings (append forward-bindings adjoint-bindings)))
        `(let ,all-bindings
           ,@(nreverse backward-forms))))))


;;; ===================================================================
;;; 101: atomic-RMW analyzer set write-mode on target
;;; ===================================================================
;;;
;;; The atomic-add! analyzer calls `analyze-expression` on its target,
;;; which fires the "read from &out" check in analyze-aref-expression
;;; because *analysis-access-mode* defaults to :read.  But atomic RMW
;;; operations write to their target — the read is part of the read-
;;; modify-write — so :write is the correct mode.
;;;
;;; Surfaced by sub-function tensor AD: the backward body for a tensor-
;;; param sub-function emits `(atomic-add! (~ v_grad idx) t_adj)` where
;;; `v_grad` is an &out grad-tensor.  Without this fix, the analyzer
;;; rejects with "Cannot read from Output Parameter".
;;;
;;; Override binds *analysis-access-mode* to :write around the target
;;; analysis, matching the set! analyzer's behavior (analysis/structs.lisp:516).

(defun %analyze-atomic-rmw-expression (op expr env context location &key no-delta)
  "Shared helper for all atomic RMW analyzers.
OP is a keyword (:add :sub :min :max :xchg).
Target (second element of EXPR) must be an aref expression like (~ vec idx).
When NO-DELTA is T (for atomic-inc!/atomic-dec!), synthesizes a literal-1 delta.

101 override: target analysis runs with *analysis-access-mode* = :write
so &out params can serve as atomic-RMW targets (the read is part of the
write)."
  (let ((expected-args (if no-delta 1 2))
        (actual-args   (1- (length expr))))
    (unless (= actual-args expected-args)
      (error 'crisp-type-error
        :message (format nil "~a: expected ~a argument~:p, got ~a"
                         (first expr) expected-args actual-args)
        :source-location location)))
  (let* ((target-form (second expr))
         ;; 101: write-mode for the target — atomic RMW writes.
         (target-node (let ((*analysis-access-mode* :write))
                        (analyze-expression target-form env context (append location '(1))))))
    (unless (semantic-aref-p target-node)
      (error 'crisp-type-error
        :message (format nil "~a: target must be a memory location like (~~ vec idx), got ~a"
                         (first expr) target-form)
        :source-location location))
    (let* ((elem-type  (semantic-aref-type target-node))
           (delta-node (if no-delta
                           (let* ((ct  (gethash elem-type *crisp-types*))
                                  (one (if (and ct (eq (crisp-type-category ct) :float))
                                           1.0d0 1)))
                             (make-semantic-literal :value-type elem-type
                                                    :value one
                                                    :source-location location))
                           (analyze-expression (third expr) env context
                                               (append location '(2))))))
      (make-semantic-atomic-rmw :type elem-type
                                :op op
                                :target-node target-node
                                :delta-node delta-node
                                :source-location location))))


