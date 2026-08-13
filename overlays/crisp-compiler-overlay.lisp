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
;;; Endeavor 147 — BUG 041: an AD-minted `<tile>_ADJ` scratch tile is never
;;; zero-initialised.
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
;;; Zero or CUDA — guarantees that local/shared memory arrives zeroed, so the
;;; generated backward must not depend on it.  It has simply been masked on
;;; Intel, where each L0 kernel argument gets its own fresh SLM allocation
;;; that happens to read as zero.  Under CUDA there is ONE dynamic shared
;;; window per block, reused across launches, and the forward's tile sits at
;;; exactly the offset the backward's `_ADJ` tile is handed — so the residue
;;; lands precisely on the adjoint.
;;;
;;; The intent was already explicit elsewhere: %mma-ad-adj-init gives a
;;; REGISTER tile adjoint an explicit 0.0 init, with the docstring "an
;;; adjoint always starts at zero".  Scratch adjoints never got the same
;;; treatment because make-scratch-* takes no init argument.  So the zeroing
;;; has to be a body form, and `fill-tile` (endeavor 135) is exactly the
;;; right one: workgroup-collective, lowered through workgroup-stride, and
;;; already the sanctioned way to clear a scratch tile.  fill-tile inserts no
;;; barrier of its own ("the caller syncs before reading") — we are that
;;; caller, so one sync-workgroup follows the whole batch.
;;; ======================================================================

;; src/autodiff.lisp
(defun %ad-scratch-adj-zero-forms (augmented-bindings)
  "Zero-initialisation forms for every AD-minted `<var>_ADJ` scratch binding
   in AUGMENTED-BINDINGS, followed by a single sync-workgroup.

   Only bindings that %AUGMENT-SCRATCH-ADJ-BINDINGS actually added are
   touched: the name must end in _ADJ and the initialiser must be a
   make-scratch-* constructor.  The forward's own tiles are left alone —
   they are fully written by the load that precedes their use, and clearing
   them would be both wasteful and, for a replayed primal, wrong.

   Register tiles are excluded: %mma-ad-adj-init already gives those an
   explicit 0.0 init, and after %explode-register-tiles a register tile has
   no whole-tile symbol left for fill-tile to name.  Rings are excluded for
   the same reason they are excluded from promotion — a ring adjoint is
   allocated elsewhere, and fill-tile does not describe a rank+1 object."
  (let* ((cl-pkg (find-package :crisp-language))
         (fill-sym (intern "FILL-TILE" cl-pkg))
         (sync-sym (intern "SYNC-WORKGROUP" cl-pkg))
         (set-sym  (intern "SET!" cl-pkg))
         (aref-sym (intern "~" cl-pkg))
         (forms nil))
    (dolist (b augmented-bindings)
      (when (and (consp b) (= (length b) 2) (symbolp (car b))
                 (consp (cadr b)) (symbolp (caadr b))
                 ;; Only the minted adjoints.
                 (let ((n (symbol-name (car b))))
                   (and (> (length n) 4)
                        (string= "_ADJ" (subseq n (- (length n) 4))))))
        (let* ((ctor (symbol-name (caadr b)))
               (elem (second (cadr b)))
               (zero (if (and (symbolp elem) (string-equal (symbol-name elem) "DOUBLE"))
                         (%ad-zero t)
                         (%ad-zero nil))))
          (cond
            ((member ctor '("MAKE-SCRATCH-VECTOR" "MAKE-SCRATCH-MATRIX" "MAKE-SCRATCH-TENSOR")
                     :test #'string=)
             (push (list fill-sym (car b) zero) forms))
            ;; A scratch CELL adjoint has the same defect and no fill-tile
            ;; (which requires a tensor); one uniform store covers it.
            ((string= ctor "MAKE-SCRATCH-CELL")
             (push (list set-sym (list aref-sym (car b)) zero) forms))))))
    (when forms
      (append (nreverse forms) (list (list sync-sym))))))

;; src/autodiff.lisp
(defun %gfw-process-let (form emit-fn process-form-fn bindings augmented-bindings body)
  "BUG 037: the replayed primal bindings now read staged tiles from their ORIGINAL GLOBAL source
   instead of from the (empty) tile, and an unrecoverable primal that the backward actually uses
   is a hard error rather than a silent zero.

   BUG 041 (endeavor 147): the AD-minted `<var>_ADJ` scratch tiles this LET
   allocates are now explicitly zeroed before the backward body runs.  See
   the header note above %ad-scratch-adj-zero-forms — shared memory is not
   guaranteed zero on any backend, and under CUDA it demonstrably is not."
  (declare (ignore form))
  (let ((local-forms nil))
    (flet ((local-emit (f) (push f local-forms)))
      (dolist (b (reverse body))
        (funcall process-form-fn b #'local-emit))
      (dolist (b (reverse bindings))
        (when (and (consp b) (= (length b) 2) (symbolp (car b)))
              (funcall process-form-fn b #'local-emit))))
    (let ((backward-body (nreverse local-forms))
          (zero-forms (%ad-scratch-adj-zero-forms augmented-bindings)))
      (%ad-check-unresolved-primals augmented-bindings backward-body)
      (funcall emit-fn `(let ,(%ad-rewrite-primal-bindings augmented-bindings)
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
;;; call %ad-zero-scratch-adjoints directly at generate-backward-walk's exit
;;; (right beside the existing %ad-ensure-ring-adj-bindings call), leaving
;;; the ring function exactly as it was in src/autodiff.lisp:1515.
;;; ----------------------------------------------------------------------

;; src/autodiff.lisp
(defun %ad-zero-scratch-adjoints (backward)
  "Prepend zero-initialisation for every AD-minted `<var>_ADJ` scratch tile
   bound in BACKWARD's outer LET.  Returns BACKWARD unchanged when it is not
   a LET or binds no such adjoint.  See the BUG 041 header above."
  (if (not (and (consp backward) (symbolp (first backward))
                (string-equal (symbol-name (first backward)) "LET")))
      backward
      (let ((zero-forms (%ad-scratch-adj-zero-forms (second backward))))
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

   BUG 041 (endeavor 147): also runs %ad-zero-scratch-adjoints on the way out."
  (%ad-zero-scratch-adjoints
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
