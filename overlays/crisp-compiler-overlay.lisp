;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Late-binding overrides for CRISP.COMPILER.
;;;;
;;;; EMPTY BY DESIGN.  Definitions live here only while a feature or bug fix is in
;;;; flight; once it settles they are folded back into their home file in src/ so
;;;; that the source of truth is one place.  Folded 2026-08-02 (endeavour 145),
;;;; and again 2026-08-09 (endeavour 146).
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

;;; ======================================================================
;;; Endeavor 147 — BUG 041: a BACKWARD kernel's compiler-allocated SLM was
;;; never zero-initialised.
;;;
;;; MEASURED, on an H100, by 147/05-cuda-scratch-tile.  Forward is
;;; C[i] = F*A[i] staged through an SLM tile, so df/dA[k] = F.  The backward
;;; returned, for F = 2 / 3 / 5:
;;;
;;;     analytical = 10.0 / 21.0 / 55.0        (FD, correctly, = 2 / 3 / 5)
;;;
;;; which is exactly (F*A[1] + 1) * F — i.e. the adjoint tile started life
;;; holding the FORWARD launch's leftover `F*A`, not zero.  Confirmed in the
;;; emitted PTX: the only `st.shared …, 0` in the module is inside the
;;; FORWARD entry (load-tile-at's out-of-bounds identity fill).  The backward
;;; entry contains no zero-store to shared at all.
;;;
;;; This is a latent COMPILER bug, not a runner bug.  No API — OpenCL, Level
;;; Zero or CUDA — guarantees that local/shared memory arrives zeroed, and
;;; NO HOST-SIDE FIX IS POSSIBLE: shared memory has no host-visible address,
;;; the launch APIs expose only a byte SIZE (cuLaunchKernel's sharedMemBytes,
;;; clSetKernelArg / zeKernelSetArgumentValue with a null pointer), and the
;;; allocation is per-BLOCK.  Even a hypothetical zero-at-launch would be
;;; insufficient: once a grid has more blocks than fit resident, block N+1
;;; inherits block N's shared memory inside the SAME launch.  Only the kernel
;;; runs per block, so only the kernel can fix it.
;;;
;;; It was masked on Intel, where each L0 kernel argument gets its own fresh
;;; SLM allocation that happens to read as zero.  Under CUDA there is ONE
;;; dynamic shared window per block, reused across launches, and the forward's
;;; tile sits at exactly the offset the backward's `_ADJ` tile is handed — so
;;; the residue lands precisely on the adjoint.
;;;
;;; THE RULE: **the compiler zeroes what the compiler allocates, in the kernel
;;; the compiler wrote.**  Every SLM scratch object bound in a BACKWARD
;;; kernel's LET is zeroed in that LET's prologue.
;;;
;;; Deliberately NOT the narrower rule "zero the things that are read before
;;; they are fully written".  That one is correct but obliges every future
;;; allocation to be classified correctly forever, and BUG 041 *is* that
;;; obligation silently going unmet since endeavor 111.  The uniform rule is
;;; checkable in one place.  It is also cheap — a workgroup-strided write pass
;;; and one barrier, against a backward that does MMA, primal replay and
;;; atomic scatter to global.  Narrowing a correct baseline later is a safe
;;; optimisation; widening a wrong one is this bug.
;;;
;;; FORWARD kernels are untouched, and that is the seam: a forward tile is
;;; user-visible, the user owns accumulator resets there via fill-tile (135's
;;; C-tile contract, BUG 036), and a blanket zero pass would land on the
;;; matmul hot path.
;;;
;;; The intent was already explicit elsewhere: %mma-ad-adj-init gives a
;;; REGISTER tile adjoint an explicit 0.0 init, with the docstring "an
;;; adjoint always starts at zero".  Scratch never got the same treatment
;;; because make-scratch-* takes no init argument.  So the zeroing has to be a
;;; body form, and `fill-tile` (endeavor 135) is exactly the right one:
;;; workgroup-collective, lowered through workgroup-stride, and already the
;;; sanctioned way to clear a scratch tile.  fill-tile inserts no barrier of
;;; its own ("the caller syncs before reading") — we are that caller, so one
;;; sync-workgroup follows the whole batch.
;;; ======================================================================

;; src/autodiff.lisp
(defparameter *ad-slm-scratch-ctors*
  '("MAKE-SCRATCH-VECTOR" "MAKE-SCRATCH-MATRIX" "MAKE-SCRATCH-TENSOR"
    ;; A ring is ONE rank-(1+N) scratch tensor whose dim 0 IS the slot (see
    ;; analyze-ring-get-expression), so it is a tensor like any other and
    ;; fill-tile describes it directly — one pass clears every slot.  An
    ;; earlier cut of this fix excluded rings on the mistaken belief that
    ;; fill-tile could not name a rank+1 object.
    "MAKE-SCRATCH-VECTOR-RING" "MAKE-SCRATCH-MATRIX-RING" "MAKE-SCRATCH-TENSOR-RING")
  "Constructors whose bindings allocate a fill-tile-able SLM TENSOR.

   A WHITELIST on purpose.  The bindings in a backward LET also include
   things that must NOT be filled: make-async-barrier / -ring bindings are
   mbarrier objects with their own initialisation, not tensors, and
   make-register-tile lives in the GRF — it already receives an explicit 0.0
   init from %mma-ad-adj-init, and after %explode-register-tiles there is no
   whole-tile symbol left for fill-tile to name.  A blacklist would silently
   swallow each new allocator as it is added; this fails closed instead.")

(defun %ad-backward-slm-zero-forms (bindings)
  "Prologue forms zeroing every compiler-allocated SLM scratch object in
   BINDINGS, followed by a single sync-workgroup.  NIL when there are none.

   EVERY such object, not only the AD-minted `<var>_ADJ` ones.  See the
   header note: the narrow rule obliges every future allocation to be
   classified correctly forever, and BUG 041 is that obligation going unmet.

   BINDINGS must be the bindings actually being EMITTED (post
   %ad-rewrite-primal-bindings), not the pre-rewrite list: a rewritten primal
   binding may no longer be an SLM allocation at all.

   Safe with respect to primal replay.  These forms run at the head of the
   LET body, before any replay stages data into a tile, and per BUG 037 a
   replayed primal reads from its ORIGINAL GLOBAL source rather than from
   inherited SLM — so nothing downstream depends on the prior contents."
  (let* ((cl-pkg (find-package :crisp-language))
         (fill-sym (intern "FILL-TILE" cl-pkg))
         (sync-sym (intern "SYNC-WORKGROUP" cl-pkg))
         (set-sym  (intern "SET!" cl-pkg))
         (aref-sym (intern "~" cl-pkg))
         (forms nil))
    (dolist (b bindings)
      (when (and (consp b) (= (length b) 2) (symbolp (car b))
                 (consp (cadr b)) (symbolp (caadr b)))
        (let* ((ctor (symbol-name (caadr b)))
               (elem (second (cadr b)))
               (zero (if (and (symbolp elem) (string-equal (symbol-name elem) "DOUBLE"))
                         (%ad-zero t)
                         (%ad-zero nil))))
          (cond
            ((member ctor *ad-slm-scratch-ctors* :test #'string=)
             (push (list fill-sym (car b) zero) forms))
            ;; A scratch CELL has the same defect and no fill-tile (which
            ;; requires a tensor); one uniform store covers it.
            ((string= ctor "MAKE-SCRATCH-CELL")
             (push (list set-sym (list aref-sym (car b)) zero) forms))))))
    (when forms
      (append (nreverse forms) (list (list sync-sym))))))

;; src/autodiff.lisp
(defun %gfw-process-let (form emit-fn process-form-fn bindings augmented-bindings body)
  "BUG 037: the replayed primal bindings now read staged tiles from their ORIGINAL GLOBAL source
   instead of from the (empty) tile, and an unrecoverable primal that the backward actually uses
   is a hard error rather than a silent zero.

   BUG 041 (endeavor 147): every SLM scratch object this LET allocates is
   zeroed before the backward body runs.  See the header note above
   %ad-backward-slm-zero-forms — shared memory is not guaranteed zero on any
   backend, and under CUDA it demonstrably is not."
  (declare (ignore form))
  (let ((local-forms nil))
    (flet ((local-emit (f) (push f local-forms)))
      (dolist (b (reverse body))
        (funcall process-form-fn b #'local-emit))
      (dolist (b (reverse bindings))
        (when (and (consp b) (= (length b) 2) (symbolp (car b)))
              (funcall process-form-fn b #'local-emit))))
    (let* ((backward-body (nreverse local-forms))
           (emitted-bindings (%ad-rewrite-primal-bindings augmented-bindings))
           (zero-forms (%ad-backward-slm-zero-forms emitted-bindings)))
      (%ad-check-unresolved-primals augmented-bindings backward-body)
      (funcall emit-fn `(let ,emitted-bindings
                          ,@zero-forms
                          ,@backward-body)))))

;;; ----------------------------------------------------------------------
;;; BUG 041, part 2: the TOP-LEVEL adjoint allocation site.
;;;
;;; The %gfw-process-let fix above covers a tile bound in a NESTED let.  It
;;; did not fix 147/05, because ANF lifts that kernel's `(let ((tile …)))`
;;; to a top-level flat-anf form, so the adjoint is allocated by the
;;; `scratch-adj-bindings` collection inside generate-backward-walk
;;; (src/autodiff.lisp ~2056) and bound in the backward's OUTER let instead.
;;; Both sites allocate adjoints; both therefore need the zeroing.
;;;
;;; FOLD-BACK NOTE: the new fixup is hung off %ad-ensure-ring-adj-bindings
;;; only because that is the last function generate-backward-walk calls on
;;; its assembled result and is reachable from an overlay.  It does not
;;; belong to rings.  When this is folded into src/, delete the wrapper and
;;; call %ad-zero-backward-slm directly at generate-backward-walk's exit
;;; (right beside the existing %ad-ensure-ring-adj-bindings call), leaving
;;; the ring function exactly as it was in src/autodiff.lisp:1515.
;;; ----------------------------------------------------------------------

;; src/autodiff.lisp
(defun %ad-zero-backward-slm (backward)
  "Prepend SLM zeroing to BACKWARD's outer LET.  Returns BACKWARD unchanged
   when it is not a LET or allocates no SLM scratch.  See the BUG 041 header
   above."
  (if (not (and (consp backward) (symbolp (first backward))
                (string-equal (symbol-name (first backward)) "LET")))
      backward
      (let ((zero-forms (%ad-backward-slm-zero-forms (second backward))))
        (if (null zero-forms)
            backward
            (list* (first backward)
                   (second backward)
                   (append zero-forms (cddr backward)))))))

;; src/autodiff.lisp  (wrapper -- see FOLD-BACK NOTE above)
(defun %ad-ensure-ring-adj-bindings (backward flat-anf kernel-pkg)
  "Add a paired `<RING>_ADJ` binding to BACKWARD's outer LET for every ring the backward
   NAMES but does not BIND.

   Only rings actually mentioned get a binding, so a kernel whose backward never touches
   a ring is returned untouched.

   The adjoint is the forward ring's own constructor, used verbatim: a ring adjoint is a
   ring of identical shape, which is what makes `(ring-get R_ADJ i)` the adjoint of
   `(ring-get R i)` (see %tlc-bwd-adj-name).  Deliberately NOT routed through
   %mma-ad-adj-init -- its %promote-scratch-init-for-ad branch does not understand ring
   constructors and reduces them to the stub type `(TENSOR FLOAT)`.  No promotion is
   needed regardless: these rings are float already.

   BUG 041 (endeavor 147): also runs %ad-zero-backward-slm on the way out."
  (%ad-zero-backward-slm
   (if (not (and (consp backward) (symbolp (first backward))
                 (string-equal (symbol-name (first backward)) "LET")))
       backward
       (let* ((bindings (second backward))
              (bound (mapcar (lambda (b) (if (consp b) (first b) b)) bindings))
              (missing
               (loop for (sym . ctor) in (%ad-ring-ctor-bindings flat-anf)
                     for adj = (intern (format nil "~A_ADJ" (symbol-name sym))
                                       (or kernel-pkg (symbol-package sym)))
                     when (and (not (member adj bound))
                               (%ad-form-mentions-p (cddr backward) adj))
                       collect (list adj ctor))))
         (if (null missing)
             backward
             (list* (first backward)
                    (append missing bindings)
                    (cddr backward)))))))
