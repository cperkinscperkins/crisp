;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Late-binding overrides for CRISP.COMPILER.
;;;;
;;;; EMPTY BY DESIGN.  Definitions live here only while a feature or bug fix is in
;;;; flight; once it settles they are folded back into their home file in src/ so
;;;; that the source of truth is one place.  Folded 2026-08-02 (endeavour 145).
;;;;
;;;; To add one: APPEND a complete definition with a `;; src/<file>.lisp` comment
;;;; above it saying where it belongs.  Do not patch definitions already here.
;;;; Note that macros and structs CANNOT be overridden this way -- they are not
;;;; late-bound -- and must be patched in src/ directly.

(in-package :crisp.compiler)


;;; ===================================================================
;;; Endeavor 146 Gap 4 — the adjoint of a REGISTER OPERAND tile must be
;;; addressable memory, not another register tile.
;;;
;;; Symptom: 142/00, /01, /11 failed under --differentiate with
;;;     Unknown variable A-TILE_ADJ.
;;;
;;; This is NOT an AD bug.  A forward-only probe with no differentiation
;;; anywhere fails identically:
;;;     (let ((T-tile (make-register-tile float (16 8) 0.0)))
;;;       (workgroup-stride T-tile (m k) (set! (~ T-tile m k) 1.0)))
;;;     => Unknown variable T-TILE.
;;; %explode-register-tiles replaces the whole-tile symbol with per-lane
;;; fragment vars, so a whole-tile reference outside an MMA / store-tile
;;; form cannot resolve.
;;;
;;; Every consumer of an OPERAND adjoint wants addressable memory:
;;;   - scalar lowering  (%mma-vjp-scalar-lowering, src/autodiff.lisp:3447)
;;;       (workgroup-stride a-adj ...) + (~ a-adj m k)
;;;   - MMA fast path    (%mma-via-tile-backward,  src/autodiff.lisp:3278)
;;;       (store-tile da-reg a-adj (0 0))  -- a-adj is the DESTINATION
;;;   - downstream scatter  %load-tile-at-bwd, which reads it element-wise
;;; Only %mma-ad-adj-init made it a register tile, by blindly mirroring the
;;; forward constructor.
;;;
;;; 145 never hit this because its specs staged operands through
;;; make-scratch-matrix + load-tile-at, so operand adjoints were ALREADY
;;; scratch.  142 Phase A introduced register-resident operands via the
;;; load-tile overload, and this allocator never learned about them.
;;;
;;; NOT a new derivative: dA = dC.B^T and dB = A^T.dC are unchanged and both
;;; lowerings already computed them correctly.  This decides only WHERE the
;;; result is allocated, and makes the register-operand case consistent with
;;; the scratch-operand case that already worked.
;;; ===================================================================

;; src/autodiff.lisp
(defun %mma-ad-register-operand-tile-p (init-form)
  "T when INIT-FORM is a make-register-tile carrying an :operand key — i.e. an MMA
   A/B operand tile (endeavor 142's register-resident load-tile overload) rather than
   an accumulator.

   Scans by symbol-name rather than comparing to a keyword object: the form is read in
   the kernel's package, and this stays correct if :operand ever arrives as a non-keyword
   symbol.  The scan starts past the dims/init positions so a literal init value can
   never be mistaken for the key."
  (and (consp init-form)
       (loop for x in (cdddr init-form)
             thereis (and (symbolp x)
                          (string-equal (symbol-name x) "OPERAND")))))

;; src/autodiff.lisp
(defun %mma-ad-adj-init (init-form)
  "Endeavor 145 P3b: the adjoint allocator paired with a forward tile binding.

   Scratch tiles keep the existing behaviour (%promote-scratch-init-for-ad, which also
   promotes e.g. ulong -> double).

   Endeavor 146 Gap 4: a register tile's adjoint depends on WHICH ROLE the tile plays.

     ACCUMULATOR  (no :operand)  -> a same-shaped register tile zeroed to 0.0.
        Correct as before: the C adjoint is filled by %load-register-tile-acc from
        C_GRAD and then staged to SLM by the VJP itself.

     OPERAND      (:operand :a/:b) -> a same-shaped SCRATCH MATRIX.
        Its every consumer indexes it as memory (see the overlay header above), and a
        register tile cannot be written element-wise at all.  Shape is the forward
        tile's own (Mt Kt) / (Kt Nt), which is exactly what both lowerings write.

   Element type is FLOAT in both register cases: fragments are fp32 and an adjoint
   always starts at zero."
  (if (and (consp init-form) (symbolp (car init-form))
           (string-equal (symbol-name (car init-form)) "MAKE-REGISTER-TILE"))
      (let ((cl-pkg (find-package :crisp-language)))
        (if (%mma-ad-register-operand-tile-p init-form)
            (list (intern "MAKE-SCRATCH-MATRIX" cl-pkg)
                  (intern "FLOAT" cl-pkg)
                  (third init-form))
            (list (intern "MAKE-REGISTER-TILE" cl-pkg)
                  (intern "FLOAT" cl-pkg)
                  (third init-form)
                  0.0)))
      (%promote-scratch-init-for-ad init-form)))


;;; ===================================================================
;;; Endeavor 146 Gap 4, part 2 — the staging ORIGIN must not read a
;;; register tile's runtime extents.
;;;
;;; With the adjoint allocation fixed above, 142/00,01,11 moved on to
;;;     Unknown variable B-TILE.
;;; Same root cause, second site.  load-tile records its origin in GRID
;;; coordinates and the rewrite scales them by the tile's extent:
;;;     (* (to-ulong G) (~ (extents~ B-TILE) 0))
;;; For a SCRATCH tile that read is fine.  For a REGISTER tile there is
;;; nothing to read -- %explode-register-tiles has already replaced the
;;; whole-tile symbol with per-lane fragment vars, so `extents~ B-TILE`
;;; cannot resolve.  (%mma-ad-unscale-tile-origin's docstring says exactly
;;; this; that helper simply is not on this path.)
;;;
;;; The extent is a COMPILE-TIME fact the scalar lowering is already handed:
;;; the A operand is (Mt x Kt) and the B operand is (Kt x Nt).  So substitute
;;; the literal for the runtime read.  For a scratch operand this is the same
;;; value constant-folded, which is why the substitution is keyed on the
;;; operand symbol and not on the tile's storage kind.
;;;
;;; Still not calculus: dA = dC.B^T and dB = A^T.dC are untouched.  This
;;; decides how an ADDRESS is computed.
;;; ===================================================================

;; src/autodiff.lisp
(defun %mma-ad-devirtualize-extent (form tile-sym dims)
  "Replace every `(~ (extents~ TILE-SYM) I)` inside FORM with the compile-time
   extent (nth I DIMS).  Any other form is returned structurally unchanged.

   TILE-SYM is matched by identity, so an origin mentioning a DIFFERENT tile is
   left alone -- important because a ring or multi-operand origin can name more
   than one tile."
  (cond
    ((not (consp form)) form)
    ((and (= (length form) 3)
          (symbolp (first form))
          (string-equal (symbol-name (first form)) "~")
          (consp (second form))
          (symbolp (first (second form)))
          (string-equal (symbol-name (first (second form))) "EXTENTS~")
          (eq (second (second form)) tile-sym)
          (integerp (third form))
          (nth (third form) dims))
     (nth (third form) dims))
    (t (mapcar (lambda (f) (%mma-ad-devirtualize-extent f tile-sym dims)) form))))

;; src/autodiff.lisp
(defun %mma-vjp-scalar-lowering (mt nt kt c-adj a-op b-op a-adj b-adj
                                 a-src aoy aox b-src boy box pkg)
  "The shape-agnostic scalar backward for a tile multiply.  Emitted as ordinary Crisp source,
   so it lowers through the normal path on either backend and at ANY tile shape.

   dC is materialised from the register accumulator into SLM once, then two collective loops
   accumulate into the operand adjoints.  Index arithmetic is coerced with to-int because a
   staging origin can be a ULONG extent expression while the collective's loop vars are INT.

   Endeavor 146 Gap 4: A-OP and B-OP are no longer ignored.  A staging origin recorded from a
   grid-coordinate load carries `(~ (extents~ OP) i)`, which cannot resolve when OP is a
   register tile.  Their extents are compile-time here -- A is (Mt x Kt), B is (Kt x Nt) --
   so the runtime read is replaced by the literal before the origin is used."
  (let* ((cl (find-package :crisp-language))
         (let* (intern "LET" cl))      (msm  (intern "MAKE-SCRATCH-MATRIX" cl))
         (flt  (intern "FLOAT" cl))    (st   (intern "STORE-TILE" cl))
         (sync (intern "SYNC-WORKGROUP" cl))
         (ws   (intern "WORKGROUP-STRIDE" cl))  (dt (intern "DOTIMES" cl))
         (aref (intern "~" cl))        (set! (intern "SET!" cl))
         (plus (intern "+" cl))        (mul  (intern "*" cl))
         (ti   (intern "TO-INT" cl))
         (dc   (intern (format nil "~A_VJPDC" (symbol-name c-adj)) pkg))
         (m (intern "%VJP_M" cl)) (n (intern "%VJP_N" cl)) (k (intern "%VJP_K" cl))
         ;; Gap 4: devirtualize each origin against ITS OWN operand's static shape.
         (aoy (%mma-ad-devirtualize-extent aoy a-op (list mt kt)))
         (aox (%mma-ad-devirtualize-extent aox a-op (list mt kt)))
         (boy (%mma-ad-devirtualize-extent boy b-op (list kt nt)))
         (box (%mma-ad-devirtualize-extent box b-op (list kt nt))))
    (flet ((ix (base off) (list plus (list ti base) (list ti off))))
      (list let* (list (list dc (list msm flt (list mt nt))))
            (list st c-adj dc (list 0 0))
            (list sync)
            ;; dA[m,k] += sum_n dC[m,n] * B[k,n]
            (list ws a-adj (list m k)
                  (list dt (list n nt)
                        (list set! (list aref a-adj m k)
                              (list plus (list aref a-adj m k)
                                    (list mul (list aref dc m n)
                                          (list aref b-src (ix boy k) (ix box n)))))))
            ;; dB[k,n] += sum_m A[m,k] * dC[m,n]
            (list ws b-adj (list k n)
                  (list dt (list m mt)
                        (list set! (list aref b-adj k n)
                              (list plus (list aref b-adj k n)
                                    (list mul (list aref a-src (ix aoy m) (ix aox k))
                                          (list aref dc m n))))))
            (list sync)))))


;;; Endeavor 146 Gap 4, part 2a — the substituted extent must be ULONG.
;;;
;;; The first cut substituted a bare integer and got
;;;     Type mismatch for operator '*'. Cannot operate on ULONG and INT.
;;; because the origin it lands in is `(* (to-ulong G) <extent>)` and an extent
;;; read is ULONG, while an integer literal is INT.  Wrap the literal.
;;; (Appended rather than edited above, per the overlay convention.)

;; src/autodiff.lisp
(defun %mma-ad-devirtualize-extent (form tile-sym dims)
  "Replace every `(~ (extents~ TILE-SYM) I)` inside FORM with the compile-time
   extent (nth I DIMS), emitted as `(to-ulong N)`.

   The ULONG wrap is required, not cosmetic: `extents~` yields ULONG and the origin
   expression multiplies it by a ULONG tile id, whereas a Lisp integer literal reads
   as Crisp INT.  Substituting the bare literal produces
   `Type mismatch for operator '*'. Cannot operate on ULONG and INT.`

   TILE-SYM is matched by identity, so an origin mentioning a DIFFERENT tile is left
   alone -- important because a ring or multi-operand origin can name more than one."
  (let ((tu (intern "TO-ULONG" (find-package :crisp-language))))
    (labels ((walk (f)
               (cond
                 ((not (consp f)) f)
                 ((and (= (length f) 3)
                       (symbolp (first f))
                       (string-equal (symbol-name (first f)) "~")
                       (consp (second f))
                       (symbolp (first (second f)))
                       (string-equal (symbol-name (first (second f))) "EXTENTS~")
                       (eq (second (second f)) tile-sym)
                       (integerp (third f))
                       (nth (third f) dims))
                  (list tu (nth (third f) dims)))
                 (t (mapcar #'walk f)))))
      (walk form))))


;;; ===================================================================
;;; Endeavor 146 Gap 4, CONSOLIDATED — one normalization pass replaces the
;;; per-site patches.
;;;
;;; Patching each emitter was the wrong shape.  THREE independent emitters
;;; put a whole-tile `(~ (extents~ TILE) i)` into the backward:
;;;   1. %mma-vjp-scalar-lowering  -- the dA/dB loop origins
;;;   2. %mma-via-tile-backward    -- %mma-ad-transposed-stage origins
;;;   3. the load-tile-at backward -- %load-tile-at-bwd scatter origins
;;; and a fourth would do it again.
;;;
;;; WHY IT BREAKS ONLY FOR REGISTER TILES.  The AD walk is source-to-source
;;; over flat ANF and runs BEFORE semantic analysis; %explode-register-tiles
;;; runs later, from the LET analyzer.  The backward replays the forward's
;;; BINDINGS but not its STATEMENTS, and a register tile's binding does not
;;; survive into that scope -- so `extents~ B-TILE` in the backward has no
;;; B-TILE to read.  A scratch tile's binding does survive, which is why 145
;;; never saw this.
;;;
;;; THE FIX.  A register tile's extents are a COMPILE-TIME fact: they are the
;;; literal dims of its make-register-tile.  Substitute them once, on the flat
;;; ANF going into the walk, and every emitter downstream is correct by
;;; construction.  Scoped to register tiles only, so the 963 specs that pass
;;; today see byte-identical input.
;;;
;;; Still not calculus.  dA = dC.B^T and dB = A^T.dC are untouched; this only
;;; decides how an ADDRESS is computed.
;;; ===================================================================

;; src/autodiff.lisp
(defun %ad-register-tile-dims-map (flat-anf)
  "Alist SYM -> (d0 d1 ...) for every `(V (make-register-tile T (D0 D1) INIT ...))`
   binding anywhere in FLAT-ANF, including nested bodies.

   Deliberately NARROWER than %mma-ad-tile-dims-map: only register tiles, because only
   they lose their binding before the backward is analysed.  Scratch tiles keep their
   runtime extents~ and must be left exactly as they are."
  (let ((acc nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (= (length form) 2) (symbolp (first form))
                  (consp (second form)) (symbolp (first (second form)))
                  (string-equal (symbol-name (first (second form))) "MAKE-REGISTER-TILE")
                  (let ((d (third (second form))))
                    (and (listp d) d (every #'integerp d)))
                  (not (assoc (first form) acc)))
         (push (cons (first form) (third (second form))) acc))))
    (nreverse acc)))

;; src/autodiff.lisp
(defun %ad-normalize-register-extents (form reg-dims)
  "Replace every `(~ (extents~ TILE) I)` where TILE is a register tile in REG-DIMS
   with its compile-time extent, emitted as `(to-ulong N)`.

   The ULONG wrap is required: extents~ yields ULONG and these reads sit inside
   `(* (to-ulong G) <extent>)`, while a Lisp integer literal reads as Crisp INT --
   a bare literal gives `Cannot operate on ULONG and INT`.

   Any form that does not match is returned structurally unchanged, so this is a
   no-op for every kernel with no register tiles."
  (if (null reg-dims)
      form
      (let ((tu (intern "TO-ULONG" (find-package :crisp-language))))
        (labels ((static-extent (f)
                   (and (consp f) (= (length f) 3)
                        (symbolp (first f))
                        (string-equal (symbol-name (first f)) "~")
                        (consp (second f))
                        (symbolp (first (second f)))
                        (string-equal (symbol-name (first (second f))) "EXTENTS~")
                        (symbolp (second (second f)))
                        (integerp (third f))
                        (nth (third f) (cdr (assoc (second (second f)) reg-dims)))))
                 (walk (f)
                   (cond ((not (consp f)) f)
                         ((static-extent f) (list tu (static-extent f)))
                         (t (mapcar #'walk f)))))
          (walk form)))))

;; src/autodiff.lisp -- wrapper.  Captures the ORIGINAL definition at overlay load
;; time, so redefining the symbol below does not recurse.  defvar (not defparameter)
;; so a reload keeps the genuine original rather than capturing the wrapper.
(defvar *ad-orig-generate-backward-walk* (symbol-function (quote generate-backward-walk)))

;; src/autodiff.lisp
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types
                                        &key kernel-pkg)
  "Endeavor 146 Gap 4: normalize register-tile extent reads in FLAT-ANF, then run the
   walk unchanged.  See the overlay header above for why this is the single correct
   seam -- every backward emitter reads its origins from this ANF, so fixing it here
   fixes all of them, and any emitter added later is correct without knowing about it."
  (funcall *ad-orig-generate-backward-walk*
           (%ad-normalize-register-extents flat-anf (%ad-register-tile-dims-map flat-anf))
           inputs outputs input-types output-types
           :kernel-pkg kernel-pkg))

;;; Endeavor 146 Gap 4: RESTORED to its src/autodiff.lisp form.  The per-site
;;; devirtualization added earlier in this overlay is now redundant -- the ANF
;;; reaching this function no longer contains a register tile's extents~ read.
;;; Restored rather than left in place so there is exactly ONE mechanism to reason
;;; about.  (Overlay convention is append-only, hence a re-append rather than an edit.)

;; src/autodiff.lisp
(defun %mma-vjp-scalar-lowering (mt nt kt c-adj a-op b-op a-adj b-adj
                                 a-src aoy aox b-src boy box pkg)
  "The shape-agnostic scalar backward for a tile multiply.  Emitted as ordinary Crisp source,
   so it lowers through the normal path on either backend and at ANY tile shape.

   dC is materialised from the register accumulator into SLM once, then two collective loops
   accumulate into the operand adjoints.  Index arithmetic is coerced with to-int because a
   staging origin can be a ULONG extent expression while the collective's loop vars are INT."
  (declare (ignore a-op b-op))
  (let* ((cl (find-package :crisp-language))
         (let* (intern "LET" cl))      (msm  (intern "MAKE-SCRATCH-MATRIX" cl))
         (flt  (intern "FLOAT" cl))    (st   (intern "STORE-TILE" cl))
         (sync (intern "SYNC-WORKGROUP" cl))
         (ws   (intern "WORKGROUP-STRIDE" cl))  (dt (intern "DOTIMES" cl))
         (aref (intern "~" cl))        (set! (intern "SET!" cl))
         (plus (intern "+" cl))        (mul  (intern "*" cl))
         (ti   (intern "TO-INT" cl))
         (dc   (intern (format nil "~A_VJPDC" (symbol-name c-adj)) pkg))
         (m (intern "%VJP_M" cl)) (n (intern "%VJP_N" cl)) (k (intern "%VJP_K" cl)))
    (flet ((ix (base off) (list plus (list ti base) (list ti off))))
      (list let* (list (list dc (list msm flt (list mt nt))))
            (list st c-adj dc (list 0 0))
            (list sync)
            ;; dA[m,k] += sum_n dC[m,n] * B[k,n]
            (list ws a-adj (list m k)
                  (list dt (list n nt)
                        (list set! (list aref a-adj m k)
                              (list plus (list aref a-adj m k)
                                    (list mul (list aref dc m n)
                                          (list aref b-src (ix boy k) (ix box n)))))))
            ;; dB[k,n] += sum_m A[m,k] * dC[m,n]
            (list ws b-adj (list k n)
                  (list dt (list m mt)
                        (list set! (list aref b-adj k n)
                              (list plus (list aref b-adj k n)
                                    (list mul (list aref a-src (ix aoy m) (ix aox k))
                                          (list aref dc m n))))))
            (list sync)))))
