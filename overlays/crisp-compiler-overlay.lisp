;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Late-binding overrides for CRISP.COMPILER.
;;;;
;;;; EMPTY BY DESIGN.  Definitions live here only while a feature or bug fix is in
;;;; flight; once it settles they are folded back into their home file in src/ so
;;;; that the source of truth is one place.  Folded 2026-08-02 (endeavour 145),
;;;; again 2026-08-09 (endeavour 146), and again 2026-08-14 (endeavour 149).
;;;;
;;;; To add one: APPEND a complete definition with a `;; src/<file>.lisp` comment
;;;; above it saying where it belongs.  Do not patch definitions already here.
;;;; Note that macros and structs CANNOT be overridden this way -- they are not
;;;; late-bound -- and must be patched in src/ directly.
;;;;
;;;; A NOTE ON WRAPPERS, learned the hard way in 146.  Capturing an original with
;;;;     (defvar *orig-foo* (symbol-function 'foo))
;;;; and then redefining FOO works beautifully in an overlay and does NOT survive
;;;; copy-paste into src/ -- there is no "original" there to capture.  Each such
;;;; wrapper has to be MERGED INTO the real function body when it is folded back.
;;;; If you reach for that pattern, note in the header which src function the
;;;; wrapper's body ultimately belongs inside.


(in-package :crisp.compiler)


;; src/metadata.lisp
;;
;; BUG 042.  The no-FORMS fallback enumerated *FUNCTION-TABLE*, i.e. it treated
;; EVERY FUNCTION as a kernel.  Under --single-pass (the one caller that passes
;; no forms, because main.lisp's CAPTURED-FORMS is only set in the multi-pass
;; branch) that turned tests/spec/028-metadata/01-aliases.crisp -- one kernel --
;; into NINETEEN .metacrisp files, eighteen of them compiler internals
;; (01-aliases_die, 01-aliases_make-cell%dispatch, 01-aliases_~parent~, ...).
;;
;; The visible crash was downstream: the spec runner passes a PATHNAME when one
;; metacrisp exists and a LIST when several do, so the bogus fan-out handed a
;; LIST to VALIDATE-01-ALIASES, which PROBE-FILEs its argument and died on the
;; type check -- killing the whole --single-pass phase at 028-metadata.
;;
;; That runner convention is CORRECT and is deliberately left alone: 028/12 and
;; 028/14 are genuinely two-kernel specs whose validators take a list and find
;; each file by name.  Only the fan-out was lying about how many kernels there
;; were.
;;
;; This function is documented to emit "sidecar files for each kernel", so the
;; fallback now enumerates KERNELS.  *COMPILED-KERNELS* is exactly that list and
;; is pushed by the DEF-KERNEL macro itself (src/macros.lisp), so it is populated
;; identically in single-pass and multi-pass.  REVERSE restores source order,
;; since the macro accumulates with PUSHNEW.
;;
;; NOTE (unchanged, and NOT a regression of this fix): EXTRACT-DEFINED-KERNELS
;; matches DEF-KERNEL literally, so DEF-KERNEL-EXACT still yields no metadata on
;; the forms path -- that is BUG 019, separate from this one.
;;
;; SECOND ROUND.  *COMPILED-KERNELS* is not a drop-in for the forms path: under
;; --differentiate it also contains the AD-MINTED BACKWARD twins (K and K_GRAD
;; both), which reading the source forms never yields.  Left unfiltered that emits
;; a spurious second sidecar per kernel -- e.g.
;; 03-record-at-boundary_grad_non_overloadable_accessor_k_grad.metacrisp -- whose
;; :kernels section is EMPTY, because this function then looks up K_GRAD_GRAD,
;; which does not exist.  %ONLY-FORWARD-KERNELS drops a name only when its own
;; forward is present in the same list, so it removes exactly the minted twins and
;; leaves a hypothetical user kernel called FOO_GRAD (with no FOO) alone.
(defun %only-forward-kernels (names)
  "Removes AD-minted backward twins from NAMES.

   A name is dropped only when it is <OTHER>_GRAD *and* <OTHER> is itself in
   NAMES -- i.e. it is the backward companion of a kernel we are already
   emitting.  This keeps the forms path and the *COMPILED-KERNELS* fallback
   producing the same set of sidecars.  See BUG 042."
  (remove-if (lambda (k)
               (let ((n (symbol-name k)))
                 (and (> (length n) 5)
                      (string= "_GRAD" (subseq n (- (length n) 5)))
                      (find (subseq n 0 (- (length n) 5)) names
                            :key #'symbol-name :test #'string=))))
             names))
(defun generate-metadata-for-file (input-path output-path &key (output-targets nil) (source-file nil) (forms nil))
  "Generates .metacrisp sidecar files for each kernel in INPUT-PATH.
   In differentiate mode (*differentiate-p*), generates metadata for the backward
   (_GRAD) kernel rather than the forward kernel, while preserving the file-name
   convention established by main.lisp (output-path already carries the _grad prefix).

   When FORMS is supplied the kernel list is read from the source forms.  When it
   is not (the --single-pass path), it falls back to *COMPILED-KERNELS* -- the
   kernels registered by the DEF-KERNEL macro -- NOT to *FUNCTION-TABLE*, which
   holds every function including compiler internals and produced one bogus
   .metacrisp per accessor.  That fallback is filtered through
   %ONLY-FORWARD-KERNELS so AD-minted K_GRAD twins do not each get a sidecar of
   their own.  See BUG 042."
  (let ((kernel-names (if forms
                          (extract-defined-kernels forms)
                          (%only-forward-kernels (reverse *compiled-kernels*))))
        (generated-files nil))

    (let ((src-path (or source-file
                        (namestring input-path))))

      (when (null kernel-names)
        (multiple-value-bind (aliases structs)
            (collect-kernel-dependencies nil)
          (declare (ignore aliases structs))
          (with-open-file (stream output-path :direction :output :if-exists :supersede)
            (format stream ";; generated by crisp-compile~%~%")))
        (push output-path generated-files))

      (dolist (k kernel-names)
        ;; In differentiate mode, look up the backward kernel (k_GRAD) for all content.
        ;; The file name still uses k, because output-path already has the _grad prefix
        ;; added by main.lisp, giving e.g. "01-multiply_grad_cell_mult.metacrisp".
        (let* ((effective-k (if *differentiate-p*
                                (intern (format nil "~a_GRAD" (symbol-name k))
                                        (symbol-package k))
                                k))
               (final-path (make-pathname
                             :name (format nil "~a_~a"
                                           (pathname-name output-path)
                                           (string-downcase (symbol-name k)))
                             :type "metacrisp"
                             :defaults output-path)))

          ;; Fix up backward kernel's declared types before serialization:
          ;; resolve aliases to inline types and correct cell access modes.
          (when *differentiate-p*
            (%bwd-fixup-declared-types effective-k))

          (multiple-value-bind (aliases structs)
              (collect-kernel-dependencies (list effective-k))
            (with-open-file (stream final-path :direction :output :if-exists :supersede)
              (format stream ";; generated by crisp-compile~%~%")
              (serialize-aliases stream aliases)
              (serialize-structs stream structs)
              ;; Endeavor 130 Phase 5: carry the ACTIVE hardware profile (only the
              ;; selected one) into the metacrisp for the hoist / runtime compilation.
              (%hp-serialize-active-profile stream)
              (serialize-kernels stream (list effective-k)
                                 :source src-path
                                 :output-targets output-targets)))

          (push final-path generated-files)))

      (nreverse generated-files))))


;; src/mma.lisp
;;
;; BUG 035.  A `:contiguous-term :col-major` operand was loaded RowMajor.
;;
;; The declared layout was NOT being lost -- that was the standing theory and it is
;; wrong.  Traced leg by leg, :col-major canonicalises to :FIRST, survives the
;; def-type alias, and survives into the kernel parameter's MANGLED type, which at
;; the load site really is TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST.  The stride operand
;; in the emitted SPIR-V already responded to it correctly.
;;
;; The defect was one call: this function used CANONICALIZE-TYPE-SPECIFIER, which
;; does not know how to expand a MANGLED tensor symbol and simply wraps it --
;; (TENSOR_FLOAT_2_GLOBAL_COMPACT_FIRST), a ONE-element list.  %GET-TENSOR-CT then
;; read index 5 of that and, finding nothing, returned its documented default :LAST.
;; Layout 0.  Silently.
;;
;; %GET-TENSOR-CT is left alone deliberately: its docstring promises only to read
;; "a canonical tensor type 6-tuple", which is exactly what it does.  The caller was
;; violating that contract.  %TS-CANONICALIZE-TENSOR-TYPE (src/analysis/control.lisp)
;; is the canonicaliser that already resolves all three shapes -- alias, list form,
;; and mangled symbol via UNMANGLE-TEMPLATE-STRUCT-NAME -- so this is reuse, not a
;; second implementation.
;;
;; THE KEYWORD NORMALISATION IS LOAD-BEARING, not defensive dressing.
;; UNMANGLE-TEMPLATE-STRUCT-NAME returns PLAIN SYMBOLS (FIRST, GLOBAL, COMPACT), not
;; keywords, so (eq raw :first) is NIL even once the c-t is correctly recovered and
;; the bug would survive the fix.  src/macros.lisp:699 already carries this same
;; cond for the same reason on the tensor-stride path.
;;
;; ...AND THEN THE HARDWARE SAID NO.  Emitting the declared layout faithfully turns a
;; silently-wrong answer into an un-buildable module, which is not obviously better.
;; Measured on BMG (driver 32.0.101.8864), all three cases, not assumed:
;;
;;   col-major A operand  -> zeModuleCreate 0x70000004, IGC build log:
;;       undefined reference to `__builtin_spriv_OpJointMatrixLoadINTEL_
;;         PackedA_ColumnMajor_SG16_8x8_i32_4_global_v8i8_pi32_i32'
;;   col-major B operand  -> same, PackedB_ColumnMajor_SG16_8x16_i32_8_...
;;   col-major C (accum)  -> BUILDS (IGC does ship a ColumnMajor accumulator store)
;;                           but computes the WRONG RESULT on metal: MMA_WRONG,
;;                           C[0][1]=12 against a reference of 18.
;;
;; So the operand loads are a genuine IGC gap, and the accumulator store is something
;; else again -- whether OUR stride pairing or IGC's store is at fault is UNDETERMINED
;; (the strides are runtime FunctionParameters, not readable from the SPIR-V).  All
;; three are unusable today, so all three are refused; the C case is refused
;; CONSERVATIVELY and should be revisited if anyone chases that root cause.
;;
;; Refusing at compile time with a sentence beats failing at zeModuleCreate with a
;; mangled builtin name, and beats silently transposing the operand behind the user's
;; back (which would quietly change the performance characteristics of a kernel --
;; exactly the class of invisible magic endeavour 143 had to unpick).
(defun %coop-refuse-col-major (tensor-node)
  "Signals the BUG 035 refusal for a :col-major cooperative-matrix operand on SPIR-V.

   Split out from %COOP-LAYOUT-OF so the message lives in one place and the
   negative spec has a stable substring to match."
  (error 'crisp-compiler-error
         :message
         (concatenate 'string
           "Intel cooperative-matrix (MMA) operands cannot be :col-major "
           "(:contiguous-term :first). IGC ships no PackedA_ColumnMajor / "
           "PackedB_ColumnMajor load builtin, so such a kernel fails to build on the "
           "device, and a ColumnMajor accumulator computes incorrectly. "
           "Declare the operand :row-major, or stage an explicit transpose into "
           "scratch and feed the MMA from there. (NVIDIA/PTX is unaffected.)")
         :source-location (ignore-errors (semantic-node-source-location tensor-node))))
(defun %coop-layout-of (tensor-node)
  "The coop load/store MemoryLayout for an operand, derived from its tensor type's
   :contiguous-term (NOT hardcoded): :last (row-major) -> 0 (RowMajor); :first (col-major)
   -> 1 (ColMajor).  So the layout matches how the matrix is actually stored — the stride
   in %coop-tensor-ptr+stride follows (s0 for RowMajor, s1 for ColMajor).

   Resolves the operand type with %TS-CANONICALIZE-TENSOR-TYPE rather than
   CANONICALIZE-TYPE-SPECIFIER: at a load site the operand is usually a kernel
   parameter carrying a MANGLED type symbol, which only the former can expand.
   The result is normalised to a keyword because the unmangler yields plain
   symbols.  Unresolvable types keep the historical :last / RowMajor default.

   On :spirv a resolved :first (col-major) is REFUSED at compile time rather than
   emitted — see %COOP-REFUSE-COL-MAJOR for the measurements behind that.
   See BUG 035."
  (let* ((canon (%ts-canonicalize-tensor-type (get-single-value-type tensor-node)))
         (raw   (and canon (%get-tensor-ct canon)))
         (ct    (cond ((keywordp raw) raw)
                      ((symbolp raw)  (intern (symbol-name raw) :keyword))
                      (t :last))))
    (cond
      ((not (eq ct :first)) 0)
      ((eq *target-backend* :spirv) (%coop-refuse-col-major tensor-node))
      (t 1))))


;; src/mma.lisp
;;
;; BUG 040.  An MMA whose operands are RING SLOTS computed the WRONG RESULT on BMG.
;;
;; NOT an addressing bug.  The entry's standing theory was that "the fragment loads may be
;; ignoring that offset (or the slot stride)" -- it says UNVERIFIED, and it is wrong.  The
;; operand's K EXTENT simply was not compile-time resolvable, so %MMA-K-STEPS took its
;; documented fallback of ONE native K-step and the MMA contracted over K=0..7 of 0..15.
;; It computed HALF the dot product, which is why the entry's own observation -- "the wrong
;; values are not garbage, they are small and plausible" -- was the real clue.
;;
;; Measured, by wrapping %MMA-OPERAND-EXTENT / %MMA-K-STEPS and compiling both kernels:
;;
;;     plain scratch tiles   A cols=16  B rows=16  -> 2 K-steps   (4 coop loads emitted)
;;     ring slots            A cols=NIL B rows=NIL -> 1 K-step    (2 coop loads emitted)
;;
;; This is the SAME silent-data-drop endeavour 145 P3a was written to kill -- its header says
;; "Stage anything WIDER and the surplus was silently ignored - no error, no warning, a wrong
;; answer."  P3a covered MAKE-SCRATCH-MATRIX; rings were never covered.  TWO gaps, both
;; required, which is why neither alone would have shown up in testing:
;;
;;   1. %MMA-SCRATCH-TILE-DIMS-FROM-BINDINGS matched only "MAKE-SCRATCH-MATRIX", so a
;;      (V (make-scratch-matrix-ring float (R C) :ring-count N)) binding recorded NOTHING.
;;   2. %MMA-OPERAND-EXTENT's scratch arm required (symbolp ref), but a ring operand is the
;;      FORM (ring-get RING SLOT).
;;
;; BACKEND-AGNOSTIC, despite the entry's "may well be Intel-specific": this is analyzer code,
;; shared by SPV and PTX.  NVIDIA escaped it only because 138/04 stages Kt = K_n = 8, exactly
;; one native K-step, so the fallback happened to be correct there.
;;
;; THE SLOT INDEX IS DELIBERATELY IGNORED.  Every slot of a ring has the same per-slot shape,
;; so the K extent does not depend on WHICH slot -- and unlike the GRF, SLM *is* runtime
;; indexable, so requiring a compile-time slot here would refuse legitimate pipelined kernels.
;; (%RESOLVE-TILE-REF does demand a constant slot, but only for REGISTER rings; for an SLM ring
;; its ring-entry lookup misses and it returns NIL without erroring, which is what lets the
;; scratch arm below run at all.)
(defun %mma-scratch-tile-dims-from-bindings (bindings)
  "Endeavor 145 P3a: the (SYM ROWS COLS) dims of every compile-time-shaped
   (V (make-scratch-matrix <elem> (ROWS COLS))) binding in BINDINGS.

   BUG 040: also records (V (make-scratch-matrix-ring <elem> (ROWS COLS) :ring-count N)),
   whose PER-SLOT shape sits at the same argument position.  Without it an MMA reading from
   a ring slot could not learn its operand's K extent and silently contracted over one
   native K-step.  Only the MATRIX ring is recognised -- vector and tensor rings are not
   valid 2-D MMA operands -- and the 2-integer-list guard filters anything else.

   Only literal integer 2-lists are recorded; a scratch tile whose shape is derived from another
   tensor contributes nothing and falls back to the one-K-step assumption."
  (loop for b in bindings
          when (and (consp b) (= (length b) 2) (symbolp (first b))
                    (consp (second b))
                    (or (%head-name-eq (first (second b)) "MAKE-SCRATCH-MATRIX")
                        (%head-name-eq (first (second b)) "MAKE-SCRATCH-MATRIX-RING"))
                    (let ((d (third (second b))))
                      (and (listp d) (= (length d) 2) (every #'integerp d))))
        collect (list (first b)
                      (first (third (second b)))
                      (second (third (second b))))))

(defun %mma-operand-extent (ref tiles which)
  "Endeavor 145 P3a: the compile-time extent (WHICH = :rows | :cols) of an
   mma-accumulate-via-tile operand REF, or NIL if not compile-time known.

   Handles both operand flavours: a register tile / ring slot (normalized to
   (V m n syms ...) by %resolve-tile-ref) and an SLM scratch tile (via
   *mma-scratch-tile-dims*).

   BUG 040: an SLM ring slot arrives as the FORM (ring-get RING SLOT) rather than a bare
   symbol, so it is unwrapped to RING before the *mma-scratch-tile-dims* lookup.  SLOT is
   intentionally not inspected: every slot has the same shape, so the extent does not depend
   on it, and demanding a compile-time slot would reject runtime-indexed SLM pipelines."
  (let ((rt (%resolve-tile-ref ref tiles)))
    (if rt
        (ecase which (:rows (second rt)) (:cols (third rt)))
        (let* ((sym (cond ((symbolp ref) ref)
                          ((and (consp ref)
                                (%head-name-eq (first ref) "RING-GET")
                                (>= (length ref) 2)
                                (symbolp (second ref)))
                           (second ref))
                          (t nil)))
               (sd (and sym (assoc sym *mma-scratch-tile-dims*))))
          (when sd
            (ecase which (:rows (second sd)) (:cols (third sd))))))))
