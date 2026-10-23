;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;;
;;;; INSTRUCTIONS:
;;;; 1. APPEND new/fixed function definitions to the end of this file.
;;;; 2. Add a comment naming the original file (e.g. ;; src/compiler.lisp).
;;;; 3. Do not modify the original file in src/ until cleanup time.
;;;;
;;;; EMPTY as of 2026-10-13 -- the "/=" entry in *unsupported-form-hints* folded into src/errors.lisp.
;;;; Before that, 2026-10-12 (later) -- endeavour 185 (math-ops) folded into src/:
;;;;   * overrides          -> analyze-let-expression (src/analysis/control.lisp); register-ops-analyzers,
;;;;                           analyze-mod-expression, analyze-rem-expression (src/analysis/ops.lisp);
;;;;                           %handle-single-value-backward (src/autodiff.lisp); semantic-div written out
;;;;                           in place of its def-binary-op-codegen line (src/codegen.lisp)
;;;;   * analyzers          -> the %185-* / analyze-185-* block before register-ops-analyzers (src/analysis/ops.lisp)
;;;;   * lowering           -> the %185-* block + %hw-lower methods after %hw-sat-interior (src/codegen.lisp)
;;;;   * AD                 -> %185-math-backward (src/autodiff.lisp)
;;;;   * bindings           -> select xor srem urem ashr not enum-attribute frem (src/llvm-bindings.lisp)
;;;; EMPTY as of 2026-10-12 -- adversarial sweep (tests/adversarial/issues.md, Resolved) folded:
;;;;   * c-t struct values (ADV-018) -> validate-and-reorder-struct-args, %split-ct-props-args,
;;;;                                  %member-access-struct-name (src/structs.lisp); analyze-struct-construction,
;;;;                                  analyze-extract/insert-struct-member-expression, get-struct-member-index
;;;;                                  (src/analysis/structs.lisp); generate-node-ir semantic-struct-construction
;;;;                                  (src/codegen.lisp); %generate-struct-accessor (src/macros.lisp);
;;;;                                  types-compatible-p (src/type-checker.lisp); types-assignable-p +
;;;;                                  %ct-qualified-arg-fits-bare-param-p (src/types/hierarchy.lisp)
;;;;   * enums (ADV-005/007)       -> ensure-template-instantiation, %keyword-literal-type->enum (src/templates.lisp);
;;;;                                  ensure-branch-compatibility, %enum-type-for-branch (src/analysis/control.lisp);
;;;;                                  %promote-to-float-adjoint, %ad-enum-type-p, %backward-value-expr (src/autodiff.lisp);
;;;;                                  crisp-unsupported-form-error + *unsupported-form-hints* (src/errors.lisp)
;;;;   * kernel boundary (014/015/019/020) -> %validate-kernel-parameters, marshall-cell/-tensor + helpers
;;;;                                  (src/macros.lisp); %instantiate-callable-template, initialize-templates,
;;;;                                  *explicit-instantiation-names* (src/templates.lisp)
;;;;   * c-t-output (ADV-006)      -> src/macros.lisp
;;;;   * shadowed lets in AD (ADV-001/002) -> anf-transform + %alpha-rename-shadowed-lets (src/anf-transform.lisp)
;;;; Before that, 2026-10-10 -- endeavour 183 (last-man fence; BUG 082) folded: %warp-spec-check-sync
;;;;   (src/analysis/control.lisp) and the three last-man lowerings (src/analysis/ops.lisp).
;;;; Before that, 2026-10-08 -- endeavours 181 (last-man sweep) and 182 (NVIDIA register budget)
;;;; folded into src/:
;;;;   * strided final sweep      -> %181-strided-sweep-form (new), %grid-reduce-last-man-expand,
;;;;                                  %fused-grid-reduce-form, %fused-grid-reduce-dependent-form,
;;;;                                  %implicit-scratch-alloc-form (:match-num-workgroups) (src/analysis/ops.lisp)
;;;;   * profile key              -> *hardware-profile-schema* :stream-occupancy-target (src/hardware-profile.lisp)
;;;;   * occupancy target         -> *kernel-occupancy-targets*, *stream-functions*, *analyzing-function*
;;;;                                  (src/compiler.lisp); %declared-local-size-dims, %parse-occupancy-target-decl,
;;;;                                  internal-def-function binds/parses (src/analysis/core.lisp);
;;;;                                  %expand-loop-vector-stride-form marks the stream (src/analysis/control.lisp)
;;;;   * launch bounds            -> %effective-occupancy-target, %apply-occupancy-bound, called beside
;;;;                                  %apply-cluster-dims-attribute (src/codegen.lisp)
;;;;   * spec validators          -> %ptx-minnctapersm, validate-ptx-minnctapersm-4/-2, validate-ptx-no-minnctapersm
;;;;                                  (src/mma.lisp)

(in-package :crisp.compiler)

;; src/codegen.lisp -- REPLACES ensure-opencl-kernel-metadata (endeavour 190: BUG 066 on PTX -- a _GRAD kernel inherits its forward kernel's launch geometry on EVERY backend, not only inside the SPIR-V subgroup emitter)
(defun ensure-opencl-kernel-metadata (func semantic-function module)
  "Marks a function as a SPIR-V/PTX kernel if it's an entry point.
   Sets the appropriate calling convention (76 for SPIR-V, 71 for PTX).
   Endeavor 126: also stamps the denormal-fp-math attribute (all functions).
   Endeavor 152: stamps cluster dimensions on capable PTX entry points, and records
   the EFFECTIVE extent (warning on degrade) for every entry point on every backend.
   Endeavour 156: pins the SPIR-V subgroup size to the profile's :simd-width.

   NOTE: Kernel argument metadata (address space, access qualifiers, etc.) is added
   as text during IR printing for SPIR-V."
  (%apply-denormal-attribute func module)
  (when (semantic-function-is-entry-point semantic-function)
        (log:info "Marking function ~a as Kernel for backend ~a"
                  (semantic-function-name semantic-function) *target-backend*)
        ;; Endeavour 190 (BUG 066 on PTX): a _GRAD kernel inherits its forward kernel's launch
        ;; geometry on EVERY backend.  It used to happen only inside the SPIR-V subgroup emitter
        ;; below, so on PTX every gradient kernel's .metacrisp carried no global/local size and a
        ;; caller had to guess.  Measured before the change: the PTX of all 903 specs that compile
        ;; with --differentiate is byte-identical; only the metadata of 379 _grad kernels changes.
        ;; (The SPIR-V call below stays -- the inherit only fills a missing entry, so it is a no-op.)
        (%173-ensure-grad-dispatch-decls semantic-function)

        (case *target-backend*
          (:spirv
           ;; calling convention spir_kernel (76)
           (llvm-set-function-call-conv func 76)
           ;; Endeavor 126: denormal handling reaches SPIR-V only via an execution mode.
           (%emit-spirv-denorm-execution-mode func module)
           ;; Endeavour 156 Phase 0: so does the subgroup size, and for the same reason --
           ;; the function attribute does not survive the translator.
           (%emit-spirv-subgroup-size-execution-mode func module semantic-function))
          (:ptx
           ;; Use ptx_kernel calling convention (71) so llc emits .entry
           ;; If this crashes on Windows, we will need to revisit nvvm attributes.
           (log:info "Setting CC 71 (ptx_kernel) for function ~a" (semantic-function-name semantic-function))
           (llvm-set-function-call-conv func 71))
          (t
           ;; Default to C calling convention (0) for generic/unknown
           (log:warn "Using default CC (0) for kernel in backend ~a" *target-backend*)
           (llvm-set-function-call-conv func 0)))

        ;; Endeavor 152: OUTSIDE the case on purpose.  This must run for every entry
        ;; point on every backend -- it is what records the effective cluster extent
        ;; and warns when a declared cluster could not be formed.  Gating it per
        ;; backend is what let the SPIR-V degrade go silent.
        (%apply-cluster-dims-attribute func semantic-function module)
        ;; Endeavour 182: launch bounds for the kernel's occupancy target (PTX only; a no-op elsewhere).
        (%apply-occupancy-bound func (semantic-function-name semantic-function) module))

  (unless (semantic-function-is-entry-point semantic-function)
    (case *target-backend*
      (:spirv
       ;; Use SPIR_FUNC (75) for non-kernel functions
       (llvm-set-function-call-conv func 75)))))



;;; ---------------------------------------------------------------------------------------------
;;; Endeavour 190 / BUG 133: a def-record's ARRAY member is split into one kernel parameter per
;;; element (k_ra (counts (array int 4)) takes four i32), but the metacrisp listed it as ONE
;;; (ARRAY INT 4) slot -- :physical-signature and every :range after it were short by N-1.  The
;;; compile API reported 4 slots for a 7-parameter kernel and the source-mode launcher indexed its
;;; slot map past the end (H100 segfault, 060-array/16).  def-structs are untouched: they really
;;; are one aggregate parameter.
;;; ---------------------------------------------------------------------------------------------

;; src/metadata-val.lisp
(defun %physical-array-split (type-spec)
  "When TYPE-SPEC (or the def-type alias it names) is (ARRAY ELEM N) with an integer N, returns
   (VALUES ELEM N); otherwise NIL.  Used by %enumerate-physical-types to split a record's array
   member into one physical slot per element, as codegen does."
  (let ((resolved (if (symbolp type-spec)
                      (or (ignore-errors (resolve-type-alias type-spec)) type-spec)
                      type-spec)))
    (when (and (consp resolved)
               (symbolp (first resolved))
               (string-equal (symbol-name (first resolved)) "ARRAY"))
      (let ((elem (second resolved))
            (n (third resolved)))
        (if (integerp n)
            (values elem n)
            (progn
              (log:warn "%physical-array-split: array ~s has no integer length; recorded as one physical slot"
                        resolved)
              nil))))))

;; src/metadata-val.lisp
(defun %enumerate-physical-types (type-spec)
  "Returns a flat list of primitive Crisp type-specs for TYPE-SPEC.
   Records are recursively flattened to their runtime members (excluding :c-t members).
   List forms like (v-point :earnestness 3.0) use the base record type.
   Brand-typed members are resolved to their base types.
   BUG 133 (endeavour 190): an (ARRAY ELEM N) -- a record's array member -- is N copies of ELEM's
   own flattening, because codegen passes each element as its own kernel parameter."
  (multiple-value-bind (arr-elem arr-n) (%physical-array-split type-spec)
    (when arr-n
      (log:debug "%enumerate-physical-types: splitting ~s into ~d x ~s" type-spec arr-n arr-elem)
      (return-from %enumerate-physical-types
        (loop repeat arr-n append (%enumerate-physical-types arr-elem)))))
  (let* ((base-sym (cond
                     ((and (consp type-spec) (symbolp (car type-spec))
                           (not (%storage-handle-type-p type-spec)))
                      (car type-spec))
                     ((symbolp type-spec) type-spec)
                     (t nil)))
         (struct-def (when (and base-sym (symbolp base-sym))
                       (lookup-struct-definition base-sym)))
         (type-rec (when (and base-sym (symbolp base-sym))
                     (or (gethash base-sym *crisp-types*)
                         (gethash (intern (symbol-name base-sym) :crisp-language)
                                  *crisp-types*)))))
    (if (and type-rec (eq (crisp-type-category type-rec) :record) struct-def)
        ;; Record: flatten runtime members recursively
        (let* ((all-members (crisp-struct-definition-members struct-def))
               (runtime-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t)))
                                           all-members)))
          (mapcan (lambda (m) (%enumerate-physical-types (second m))) runtime-members))
        ;; Not a record: resolve brand to base type if applicable
        (let* ((brand-def (and (symbolp type-spec) (is-brand-type-p type-spec)))
               (final-type (if brand-def (brand-definition-base-type brand-def) type-spec)))
          (list final-type)))))


;; src/metadata.lisp  (BUG 133: array parameters -- REPLACES get-physical-width)
(defun get-physical-width (type)
  "Returns the number of physical ABI slots for TYPE.
   Cell -> 3, Storage -> 2, user-defined records -> recursively counted, others -> 1.
   BUG 133 (endeavour 190): an (ARRAY ELEM N) parameter is N x ELEM's width -- codegen passes each
   element as its own kernel parameter."
  (cond
   ((%storage-handle-type-p type)
     (let* ((canonical (canonicalize-type-specifier type))
            (base (if (consp canonical) (first canonical) canonical)))
       (cond
        ((and (symbolp base) (string-equal (symbol-name base) "CELL"))
          3)
        ((and (symbolp base) (string-equal (symbol-name base) "TENSOR"))
          ;; 2 (ptr + byte-size) + 3N (offsets, strides, extents) + 1 (length) = 3N+3
          (let ((n (if (integerp (third canonical))
                       (third canonical)
                       (parse-integer (symbol-name (third canonical))))))
            (+ 3 (* 3 n))))
        (t 1))))
   ((or (and (symbolp type) (string-equal (symbol-name type) "STORAGE"))
        (and (consp type) (string-equal (symbol-name (car type)) "STORAGE")))
     2)
   ((%user-record-type-p type)
     (length (%enumerate-physical-types type)))
   ((nth-value 1 (%physical-array-split type))
     (length (%enumerate-physical-types type)))
   (t 1)))




;; src/metadata.lisp  (BUG 133: array parameters -- REPLACES generate-physical-signature)
(defun generate-physical-signature (sig-or-params)
  "Generates the physical ABI signature from kernel parameters.
   Records are flattened to primitive scalar entries.
   Fixed: tensor address-space is at (fourth canonical) in the positional 6-tuple.
   BUG 133 (endeavour 190): an (ARRAY ELEM N) parameter is flattened like a record's array member --
   one entry per element, as codegen passes them."
  (let ((params (if (typep sig-or-params 'function-signature)
                    (append (function-signature-implicit-parameters sig-or-params)
                      (function-signature-parameters sig-or-params))
                    sig-or-params))
        (physical-args nil)
        (current-index 0))
    (dolist (param params)
      (let ((type (if (typep param 'parameter-def)
                      (parameter-def-type param)
                      param)))
        (unless (and (symbolp type) (string-equal (symbol-name type) "&OUT"))
          (cond
           ((or (and (symbolp type) (string-equal (symbol-name type) "STORAGE"))
                (and (consp type) (string-equal (symbol-name (car type)) "STORAGE")))
             (push (list current-index (strip-package-qualifiers '(c-pointer address-space global))) physical-args)
             (incf current-index)
             (push (list current-index (strip-package-qualifiers 'ulong)) physical-args)
             (incf current-index))
           ((%storage-handle-type-p type)
             (let* ((canonical (canonicalize-type-specifier type))
                    (base (if (consp canonical) (first canonical) canonical)))
               (cond
                ((and (symbolp base) (string-equal (symbol-name base) "CELL"))
                  (push (list current-index (strip-package-qualifiers 'ulong)) physical-args)
                  (incf current-index)
                  (push (list current-index (strip-package-qualifiers 'voidp)) physical-args)
                  (incf current-index)
                  (push (list current-index (strip-package-qualifiers 'ulong)) physical-args)
                  (incf current-index))
                ((and (symbolp base) (string-equal (symbol-name base) "TENSOR"))
                  ;; ABI: PTR, BYTE_SIZE, OFF_0..N-1, STR_0..N-1, EXT_0..N-1, LENGTH
                  (let* ((n (if (integerp (third canonical))
                                (third canonical)
                                (parse-integer (symbol-name (third canonical)))))
                         ;; 6-tuple: (tensor elem N ADDR aln ct) — addr positionally at index 3
                         (as (or (fourth canonical) :global))
                         (ptr-type (strip-package-qualifiers `(c-pointer :address-space ,as))))
                    (push (list current-index ptr-type) physical-args) (incf current-index)
                    (push (list current-index (strip-package-qualifiers 'ulong)) physical-args) (incf current-index)
                    (dotimes (_ n)
                      (push (list current-index (strip-package-qualifiers 'ulong)) physical-args) (incf current-index))
                    (dotimes (_ n)
                      (push (list current-index (strip-package-qualifiers 'ulong)) physical-args) (incf current-index))
                    (dotimes (_ n)
                      (push (list current-index (strip-package-qualifiers 'ulong)) physical-args) (incf current-index))
                    (push (list current-index (strip-package-qualifiers 'ulong)) physical-args) (incf current-index)))
                (t
                  (push (list current-index (strip-package-qualifiers type)) physical-args)
                  (incf current-index)))))
           ((or (%user-record-type-p type)
                (nth-value 1 (%physical-array-split type)))
             (dolist (prim-type (%enumerate-physical-types type))
               (push (list current-index (strip-package-qualifiers prim-type)) physical-args)
               (incf current-index)))
           (t
             (push (list current-index (strip-package-qualifiers type)) physical-args)
             (incf current-index))))))
    (nreverse physical-args)))
