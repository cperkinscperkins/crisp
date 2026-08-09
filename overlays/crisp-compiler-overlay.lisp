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


;;; ===================================================================
;;; Endeavor 146 Gap 1 — wgmma, canonicalized rather than re-registered.
;;;
;;; 140/03 failed with
;;;     Function MAKE-WGMMA-ACCUMULATOR is not differentiable.
;;; and there is no VJP for WGMMA-ACCUMULATE-VIA-TILE either -- "wgmma"
;;; appears exactly ONCE in all of src/autodiff.lisp, in a comment.
;;;
;;; The obvious fix is to add MAKE-WGMMA-ACCUMULATOR to every register-tile
;;; registry (%backward-skip-fn-p, %augment-scratch-adj-bindings,
;;; %mma-ad-adj-init, %mma-ad-tile-dims-map, the scratch-adj collection in
;;; generate-backward-walk, %ad-register-tile-dims-map) and then write a VJP
;;; for wgmma-accumulate-via-tile.  Six lists and a new VJP -- and the next
;;; MMA instruction would need seven more.
;;;
;;; But that is precisely the mistake this endeavor exists to stop.  wgmma is
;;; Hopper's WARPGROUP-ASYNC way of computing D += A.B.  The asynchrony and the
;;; warpgroup scope are SCHEDULE.  The math is the same matrix multiply that
;;; mma-accumulate-via-tile already has a VJP for.
;;;
;;; So: canonicalize wgmma to the sync MMA on the ANF entering the backward
;;; walk, exactly where Gap 4's extent normalization already runs.  Every
;;; existing register-tile registry then applies unchanged, and the derivative
;;; comes from the ONE VJP that already exists.
;;;
;;; This rewrites only the BACKWARD's view.  The forward is compiled from the
;;; caller's own flat-anf and still emits real wgmma -- 140/00-02 keep proving
;;; that.  A backward is under no obligation to use the same instruction as its
;;; forward; that is the whole content of "the schedule is not the math".
;;; ===================================================================

;; src/autodiff.lisp
(defun %ad-canonicalize-wgmma (form)
  "Rewrite Hopper wgmma forms to their synchronous MMA equivalents for the backward walk.

     (V (make-wgmma-accumulator T (M N) INIT))  ->  (V (make-register-tile T (M N) INIT))
     (wgmma-accumulate-via-tile SHAPE D A B ...) -> (mma-accumulate-via-tile SHAPE D A B ...)

   Trailing keys (:swizzle and friends) are preserved positionally; the via-tile VJP
   destructures (SHAPE C A B &rest ignored) and ignores them.

   Structural no-op for any kernel without wgmma."
  (let* ((cl (find-package :crisp-language))
         (mrt (intern "MAKE-REGISTER-TILE" cl))
         (mvt (intern "MMA-ACCUMULATE-VIA-TILE" cl)))
    (labels ((head-is (f name)
               (and (consp f) (symbolp (first f))
                    (string-equal (symbol-name (first f)) name)))
             (walk (f)
               (cond
                 ((not (consp f)) f)
                 ((head-is f "MAKE-WGMMA-ACCUMULATOR")
                  (cons mrt (mapcar #'walk (rest f))))
                 ((head-is f "WGMMA-ACCUMULATE-VIA-TILE")
                  (cons mvt (mapcar #'walk (rest f))))
                 (t (mapcar #'walk f)))))
      (walk form))))

;; src/autodiff.lisp -- replaces the Gap 4 wrapper; same seam, one more normalization.
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types
                                        &key kernel-pkg)
  "Endeavor 146: normalize the flat ANF before the walk sees it, then run the walk
   unchanged.  Two normalizations, both of the same kind -- they remove a SCHEDULING
   distinction that the derivative does not care about:

     Gap 1: wgmma  -> sync MMA           (%ad-canonicalize-wgmma)
     Gap 4: register-tile extents~ -> compile-time literals
                                         (%ad-normalize-register-extents)

   Order matters: canonicalizing wgmma first turns make-wgmma-accumulator into a
   make-register-tile, so the extent normalization's register-tile map sees it too.

   This is the single seam for anything of this shape.  Every backward emitter reads
   its operands and origins from this ANF, so a normalization here fixes all of them,
   and an emitter added later is correct without knowing this exists."
  (let* ((canonical (%ad-canonicalize-wgmma flat-anf))
         (normalized (%ad-normalize-register-extents
                      canonical
                      (%ad-register-tile-dims-map canonical))))
    (funcall *ad-orig-generate-backward-walk*
             normalized inputs outputs input-types output-types
             :kernel-pkg kernel-pkg)))


;;; ===================================================================
;;; Endeavor 146 Gap 1, part 2 — inline literal SHAPE temps.
;;;
;;; With wgmma canonicalized, 140/03 got as far as the via-tile VJP and then
;;; said "the accumulator tile D has no compile-time (M N)".  The ANF explains
;;; it:
;;;     (%ANF-T-1 (64 64))
;;;     (%ANF-T-2 (64 64 32))
;;;     (D (MAKE-WGMMA-ACCUMULATOR FLOAT %ANF-T-1 0.0))
;;;     (WGMMA-ACCUMULATE-VIA-TILE %ANF-T-2 D A-TILE B-TILE ...)
;;; The shapes were hoisted into ANF temps.  make-register-tile is on the ANF
;;; converter's opaque-argument list so it keeps its literal dims; the wgmma
;;; forms are not, so theirs were flattened.
;;;
;;; Every shape registry in the AD engine (%mma-ad-tile-dims-map and the maps
;;; downstream of it) tests `(every #'integerp dims)` and therefore rejects a
;;; symbol.  A backward emitted with a temp in a shape position would also
;;; reference a variable its own scope never binds.
;;;
;;; Rather than adding wgmma to the ANF converter's opaque list -- a fourth
;;; registry, and the next instruction would want a fifth -- inline the temps.
;;; A binding whose value is a literal list of integers IS a shape or an
;;; origin; substituting it is always safe and always what the consumer wanted.
;;; This is deliberately general: it fixes any construct whose shape gets
;;; hoisted, including ones not written yet.
;;; ===================================================================

;; src/autodiff.lisp
(defun %ad-inline-literal-shape-temps (flat-anf)
  "Substitute every ANF temp bound to a literal list of integers with that literal.

   `(%ANF-T-1 (64 64))` makes %ANF-T-1 a SHAPE, not a value -- the AD engine's shape
   maps require literals and a backward cannot reference a forward-only temp.  A
   binding is only inlined when its value is a non-empty list of integers, which no
   call form can be (a call's head is a symbol).

   The temp's OWN binding is left intact -- rewriting its left-hand side would produce
   the malformed `((64 64) (64 64))`.  Leaving the now-dead binding is harmless: the
   backward contains only what the walk emits."
  (let ((map nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (= (length form) 2) (symbolp (first form)) (first form)
                  (listp (second form)) (second form)
                  (every #'integerp (second form))
                  (not (assoc (first form) map)))
         (push (cons (first form) (second form)) map))))
    (if (null map)
        flat-anf
        (labels ((walk (f)
                   (cond
                     ((and f (symbolp f))
                      (let ((e (assoc f map))) (if e (cdr e) f)))
                     ((not (consp f)) f)
                     ;; a temp's own binding: leave entirely alone
                     ((and (= (length f) 2) (symbolp (first f)) (first f)
                           (assoc (first f) map))
                      f)
                     (t (mapcar #'walk f)))))
          (mapcar #'walk flat-anf)))))

;; src/autodiff.lisp -- the normalization chain, now three steps.
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types
                                        &key kernel-pkg)
  "Endeavor 146: normalize the flat ANF before the walk sees it, then run the walk
   unchanged.  Every step removes a distinction the DERIVATIVE does not care about:

     1. literal shape temps -> inlined     (%ad-inline-literal-shape-temps)
     2. wgmma -> sync MMA                  (%ad-canonicalize-wgmma)
     3. register-tile extents~ -> literals (%ad-normalize-register-extents)

   Order is load-bearing.  (1) must precede (2) and (3) so their shape tests see
   literals; (2) must precede (3) so a wgmma accumulator, by then a make-register-tile,
   is in the register-tile map.

   This is the single seam for anything of this shape.  Every backward emitter reads
   its operands, shapes and origins from this ANF, so a normalization here fixes all
   of them at once, and an emitter added later is correct without knowing it exists."
  (let* ((inlined (%ad-inline-literal-shape-temps flat-anf))
         (canonical (%ad-canonicalize-wgmma inlined))
         (normalized (%ad-normalize-register-extents
                      canonical
                      (%ad-register-tile-dims-map canonical))))
    (funcall *ad-orig-generate-backward-walk*
             normalized inputs outputs input-types output-types
             :kernel-pkg kernel-pkg)))


;;; ===================================================================
;;; Endeavor 146 Gap 1, part 3 — a canonicalized wgmma must also adopt the
;;; native INSTRUCTION shape.
;;;
;;; With the op renamed and the shape temps inlined, 140/03 reached the
;;; backward's own forward-analysis and said
;;;     only tf32 (16 8 8) is supported without a hardware profile, got (64 64 32)
;;;
;;; The reason is a distinction that only matters once wgmma exists.  For a
;;; SYNC mma-accumulate-via-tile the user writes the HARDWARE INSTRUCTION shape
;;; -- (8 16 8) on BMG, (16 8 8) on NVIDIA -- and %mma-via-tile-backward passes
;;; that shape straight through to the MMA forms it emits.  For wgmma the first
;;; argument is the WARPGROUP TILE shape (64 64 32), which no sync instruction
;;; accepts.  Renaming the op therefore left a shape behind that means something
;;; different.
;;;
;;; %spv-mma-shape is the accessor for the active profile's native instruction
;;; shape (profile :mma-shapes, else the NVIDIA (16 8 8) default) and is already
;;; what %mma-vjp-mma-admissible-p consults, so adopting it keeps admissibility
;;; and emission consistent.
;;;
;;; Safe because the VJP never derives dimensions from this argument: Mt and Nt
;;; come from the accumulator's dims-map entry and Kt from the A operand's, so
;;; the tile geometry -- and therefore the derivative -- is untouched.  This
;;; selects which INSTRUCTION the backward is built from, nothing more.
;;; ===================================================================

;; src/autodiff.lisp
(defun %ad-canonicalize-wgmma (form)
  "Rewrite Hopper wgmma forms to their synchronous MMA equivalents for the backward walk.

     (V (make-wgmma-accumulator T (M N) INIT))
       -> (V (make-register-tile T (M N) INIT))

     (wgmma-accumulate-via-tile (WM WN WK) D A B ...)
       -> (mma-accumulate-via-tile (NM NN NK) D A B ...)

   where (NM NN NK) is %spv-mma-shape -- the active profile's NATIVE instruction shape.
   The wgmma argument is a WARPGROUP TILE shape and is not a legal sync-MMA instruction
   shape; substituting the native one is what makes the emitted backward compilable.
   The VJP takes Mt/Nt/Kt from the tiles' dims-map entries, never from this argument,
   so tile geometry and the derivative are unaffected.

   Trailing keys (:swizzle and friends) are preserved; the via-tile VJP destructures
   (SHAPE C A B &rest ignored).

   Structural no-op for any kernel without wgmma."
  (let* ((cl (find-package :crisp-language))
         (mrt (intern "MAKE-REGISTER-TILE" cl))
         (mvt (intern "MMA-ACCUMULATE-VIA-TILE" cl)))
    (labels ((head-is (f name)
               (and (consp f) (symbolp (first f))
                    (string-equal (symbol-name (first f)) name)))
             (native-shape ()
               (multiple-value-bind (m n k) (%spv-mma-shape) (list m n k)))
             (walk (f)
               (cond
                 ((not (consp f)) f)
                 ((head-is f "MAKE-WGMMA-ACCUMULATOR")
                  (cons mrt (mapcar #'walk (rest f))))
                 ((head-is f "WGMMA-ACCUMULATE-VIA-TILE")
                  (list* mvt (native-shape) (mapcar #'walk (cddr f))))
                 (t (mapcar #'walk f)))))
      (walk form))))


;;; ===================================================================
;;; Endeavor 146 Gap 1, part 4 — register-tile RINGS.
;;;
;;; 142/10 and 142/12 failed with
;;;     Function MAKE-REGISTER-TILE-RING is not differentiable.
;;; The SCRATCH rings (vector/matrix/tensor) have been registered since 138;
;;; the REGISTER-tile ring that endeavour 142 added never was.
;;;
;;; Registering it as one more allocator would compile, but it would then hit
;;; Gap 4 all over again: a ring of REGISTER operand tiles has the same problem
;;; a single register operand tile had -- its adjoint is written and read as
;;; memory, and a register tile cannot be.  Gap 4 settled that question: an
;;; MMA OPERAND's adjoint is scratch; only the ACCUMULATOR stays in registers.
;;;
;;; A ring is rank+1 scratch (138), so the same answer one dimension up: a
;;; register-tile ring canonicalizes to a SCRATCH MATRIX RING.  Then
;;; %backward-skip-fn-p, %augment-scratch-adj-bindings and %mma-ad-tile-dims-map
;;; all already know it, `(ring-get R_ADJ i)` is already the adjoint of
;;; `(ring-get R i)` via %tlc-bwd-adj-name, and no new registry entry exists to
;;; forget next time.
;;;
;;; :operand is dropped: it selects a GRF fragment layout for the forward's
;;; block loads, and a scratch ring has no fragments to lay out.  :ring-count is
;;; preserved -- it is the ring's actual depth and %ad-reconcile-ring-origin
;;; needs it.
;;;
;;; Backward-only, like every other step in this chain.  The forward still
;;; allocates real GRF rings; 142/10 and 142/12 keep proving that on their
;;; non-differentiate passes.
;;; ===================================================================

;; src/autodiff.lisp
(defun %ad-canonicalize-register-rings (form)
  "Rewrite `(make-register-tile-ring T (M N) :ring-count N :operand :a)` to
   `(make-scratch-matrix-ring T (M N) :ring-count N)` for the backward walk.

   A ring of MMA operand tiles has the same adjoint requirement a single operand tile
   has (Gap 4): every consumer indexes the adjoint as memory.  A ring being rank+1
   scratch, the scratch matrix ring is that answer one dimension up, and it is a form
   the AD engine has understood since 138.

   :operand is dropped -- it picks a GRF fragment layout, which scratch has no use for.
   :ring-count is kept; it is the ring's real depth.

   Structural no-op for any kernel without register-tile rings."
  (let* ((cl (find-package :crisp-language))
         (msmr (intern "MAKE-SCRATCH-MATRIX-RING" cl)))
    (labels ((drop-operand (keys)
               ;; keys is a flat &key plist tail; drop the :operand pair only.
               (cond ((null keys) nil)
                     ((and (symbolp (first keys))
                           (string-equal (symbol-name (first keys)) "OPERAND"))
                      (drop-operand (cddr keys)))
                     (t (cons (first keys) (drop-operand (rest keys))))))
             (walk (f)
               (cond
                 ((not (consp f)) f)
                 ((and (symbolp (first f))
                       (string-equal (symbol-name (first f)) "MAKE-REGISTER-TILE-RING"))
                  (list* msmr (second f) (third f) (drop-operand (cdddr f))))
                 (t (mapcar #'walk f)))))
      (walk form))))

;; src/autodiff.lisp -- the normalization chain, now four steps.
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types
                                        &key kernel-pkg)
  "Endeavor 146: normalize the flat ANF before the walk sees it, then run the walk
   unchanged.  Every step removes a distinction the DERIVATIVE does not care about:

     1. literal shape temps -> inlined      (%ad-inline-literal-shape-temps)
     2. wgmma -> sync MMA                   (%ad-canonicalize-wgmma)
     3. register-tile ring -> scratch ring  (%ad-canonicalize-register-rings)
     4. register-tile extents~ -> literals  (%ad-normalize-register-extents)

   Order is load-bearing.  (1) must precede the rest so their shape tests see literals.
   (2) must precede (4) so a wgmma accumulator, by then a make-register-tile, is in the
   register-tile map.  (3) must precede (4) for the same reason in reverse: once a ring
   is scratch it keeps its runtime extents~ and must NOT be devirtualized.

   This is the single seam for anything of this shape.  Every backward emitter reads its
   operands, shapes and origins from this ANF, so a normalization here fixes all of them
   at once, and an emitter added later is correct without knowing it exists."
  (let* ((inlined (%ad-inline-literal-shape-temps flat-anf))
         (canonical (%ad-canonicalize-wgmma inlined))
         (deringed (%ad-canonicalize-register-rings canonical))
         (normalized (%ad-normalize-register-extents
                      deringed
                      (%ad-register-tile-dims-map deringed))))
    (funcall *ad-orig-generate-backward-walk*
             normalized inputs outputs input-types output-types
             :kernel-pkg kernel-pkg)))


;;; ===================================================================
;;; Endeavor 146 Gap 1, part 5 — a top-level RING gets no adjoint binding.
;;;
;;; With register rings canonicalized to scratch rings, 142/10 got as far as
;;;     Unknown variable A-RING_ADJ.
;;; and the assembled backward shows exactly why:
;;;
;;;     (LET ((C-TILE_ADJ (MAKE-REGISTER-TILE FLOAT (16 16) 0.0)) (A_ADJ 0.0) (B_ADJ 0.0))
;;;       ...
;;;       (WORKGROUP-STRIDE (RING-GET A-RING_ADJ 1) ...)      ; <- never bound
;;;
;;; There are TWO places that pair an adjoint with a forward allocation:
;;;   - %augment-scratch-adj-bindings, which KNOWS the ring constructors, but only
;;;     runs on LET forms encountered during the walk; and
;;;   - the scratch-adj-bindings collection inside generate-backward-walk, which
;;;     handles the kernel's TOP-LEVEL bindings and lists only
;;;     MAKE-SCRATCH-{VECTOR,MATRIX,TENSOR,CELL} and MAKE-REGISTER-TILE -- no rings.
;;;
;;; So a ring bound at kernel top level silently gets no adjoint.  That is a
;;; pre-existing gap, not something 142 introduced: any top-level ring whose
;;; adjoint the backward actually names would hit it.  138's and 145/18's ring
;;; specs happen not to name one.
;;;
;;; The list lives inside a 500-line function this overlay WRAPS rather than
;;; replaces, so the binding is ensured on the way out instead -- the same shape
;;; as %ensure-leaf-adj-bindings in src/macros.lisp, which fixes up the very same
;;; outer LET for struct shadow leaves.
;;; ===================================================================

;; src/autodiff.lisp
(defun %ad-ring-ctor-bindings (flat-anf)
  "Alist SYM -> CONSTRUCTOR for every ring binding in FLAT-ANF.

   Run on the CANONICALIZED anf, so register-tile rings have already become scratch
   matrix rings and only the scratch ring constructors need matching here."
  (let ((acc nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (= (length form) 2) (symbolp (first form))
                  (consp (second form)) (symbolp (first (second form)))
                  (member (symbol-name (first (second form)))
                          '("MAKE-SCRATCH-VECTOR-RING" "MAKE-SCRATCH-MATRIX-RING"
                            "MAKE-SCRATCH-TENSOR-RING")
                          :test #'string=)
                  (not (assoc (first form) acc)))
         (push (cons (first form) (second form)) acc))))
    (nreverse acc)))

;; src/autodiff.lisp
(defun %ad-form-mentions-p (form sym)
  "T if SYM occurs anywhere in FORM."
  (cond ((eq form sym) t)
        ((not (consp form)) nil)
        (t (some (lambda (f) (%ad-form-mentions-p f sym)) form))))

;; src/autodiff.lisp
(defun %ad-ensure-ring-adj-bindings (backward flat-anf kernel-pkg)
  "Add a paired `<RING>_ADJ` binding to BACKWARD's outer LET for every ring the backward
   NAMES but does not BIND.

   Only rings actually mentioned get a binding, so a kernel whose backward never touches a
   ring is returned untouched.  The adjoint allocator is %mma-ad-adj-init, the same one the
   nested-LET path uses, so a ring adjoint is a ring of identical shape -- which is what
   makes `(ring-get R_ADJ i)` the adjoint of `(ring-get R i)` (see %tlc-bwd-adj-name)."
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
                      collect (list adj (%mma-ad-adj-init ctor)))))
        (if (null missing)
            backward
            (list* (first backward)
                   (append missing bindings)
                   (cddr backward))))))

;; src/autodiff.lisp -- the chain, plus the on-the-way-out fixup.
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types
                                        &key kernel-pkg)
  "Endeavor 146: normalize the flat ANF before the walk sees it, run the walk unchanged,
   then ensure any ring adjoint the walk NAMED actually got BOUND.

   Normalizations, each removing a distinction the DERIVATIVE does not care about:

     1. literal shape temps -> inlined      (%ad-inline-literal-shape-temps)
     2. wgmma -> sync MMA                   (%ad-canonicalize-wgmma)
     3. register-tile ring -> scratch ring  (%ad-canonicalize-register-rings)
     4. register-tile extents~ -> literals  (%ad-normalize-register-extents)

   Order is load-bearing.  (1) must precede the rest so their shape tests see literals.
   (2) must precede (4) so a wgmma accumulator, by then a make-register-tile, is in the
   register-tile map.  (3) must precede (4) for the mirror-image reason: once a ring is
   scratch it keeps its runtime extents~ and must NOT be devirtualized.

   The fixup afterwards covers a gap the walk has independently of any of this: the
   top-level adjoint collection inside it does not know the ring constructors."
  (let* ((inlined (%ad-inline-literal-shape-temps flat-anf))
         (canonical (%ad-canonicalize-wgmma inlined))
         (deringed (%ad-canonicalize-register-rings canonical))
         (normalized (%ad-normalize-register-extents
                      deringed
                      (%ad-register-tile-dims-map deringed))))
    (%ad-ensure-ring-adj-bindings
     (funcall *ad-orig-generate-backward-walk*
              normalized inputs outputs input-types output-types
              :kernel-pkg kernel-pkg)
     normalized
     kernel-pkg)))


;;; Endeavor 146 Gap 1, part 4a — intern the ring constructor where its MACRO lives.
;;;
;;; The first cut interned MAKE-SCRATCH-MATRIX-RING into :crisp-language and the
;;; emitted backward failed with
;;;     Invalid incomplete type specifier: (TENSOR FLOAT).
;;; preceded by `EXPAND-STORAGE-HANDLE: (TENSOR FLOAT)` -- the constructor had not
;;; expanded at all, so the analyzer saw an unknown call and derived a stub type.
;;;
;;; make-scratch-matrix-ring is a DEFMACRO in src/macros.lisp, which is
;;; (in-package :crisp.compiler).  Interning the name into a package that does not
;;; inherit it mints a DIFFERENT, function-less symbol.
;;;
;;; Why the earlier canonicalizations did not care: nearly all of the AD walk matches
;;; constructors by (string-equal (symbol-name ...)), so any package works there.  It
;;; is the ANALYZER compiling the emitted backward that needs the genuine macro
;;; symbol -- and only forms the analyzer must MACROEXPAND are exposed to this.
;;;
;;; So: resolve through the defining package, and fall back to interning there.
;;; (Appended rather than edited, per the overlay convention.)

;; src/autodiff.lisp
(defun %ad-canonicalize-register-rings (form)
  "Rewrite `(make-register-tile-ring T (M N) :ring-count N :operand :a)` to
   `(make-scratch-matrix-ring T (M N) :ring-count N)` for the backward walk.

   A ring of MMA operand tiles has the same adjoint requirement a single operand tile
   has (Gap 4): every consumer indexes the adjoint as memory.  A ring being rank+1
   scratch, the scratch matrix ring is that answer one dimension up, and it is a form
   the AD engine has understood since 138.

   :operand is dropped -- it picks a GRF fragment layout, which scratch has no use for.
   :ring-count is kept; it is the ring's real depth.

   The replacement symbol is resolved in :crisp.compiler, where the defmacro lives, so
   the analyzer actually macroexpands what we emit.

   Structural no-op for any kernel without register-tile rings."
  (let* ((cc (find-package :crisp.compiler))
         (msmr (or (find-symbol "MAKE-SCRATCH-MATRIX-RING" cc)
                   (intern "MAKE-SCRATCH-MATRIX-RING" cc))))
    (labels ((drop-operand (keys)
               ;; keys is a flat &key plist tail; drop the :operand pair only.
               (cond ((null keys) nil)
                     ((and (symbolp (first keys))
                           (string-equal (symbol-name (first keys)) "OPERAND"))
                      (drop-operand (cddr keys)))
                     (t (cons (first keys) (drop-operand (rest keys))))))
             (walk (f)
               (cond
                 ((not (consp f)) f)
                 ((and (symbolp (first f))
                       (string-equal (symbol-name (first f)) "MAKE-REGISTER-TILE-RING"))
                  (list* msmr (second f) (third f) (drop-operand (cdddr f))))
                 (t (mapcar #'walk f)))))
      (walk form))))


;;; ===================================================================
;;; Endeavor 146 Gap 1, part 6 — devirtualize RING-VIEW extents.
;;;
;;; 142/10 still failed, with
;;;     EXPAND-STORAGE-HANDLE: (TENSOR FLOAT)
;;;     Invalid incomplete type specifier: (TENSOR FLOAT).
;;; and the emitted backward shows the cause:
;;;
;;;     (%LOAD-TILE-AT-BWD A_GRAD (RING-GET A-RING_ADJ 0)
;;;       ((* (TO-ULONG 0) (~ (EXTENTS~ (RING-GET A-RING 0)) 0)) ...))
;;;
;;; The ADJOINT ring is bound now, but the ORIGIN still reads the extents of the
;;; FORWARD ring, and A-RING is a register-tile ring whose binding does not survive
;;; into the backward.  The analyzer cannot type the unbound handle, so it derives
;;; the stub `(TENSOR FLOAT)` and rejects it.
;;;
;;; This is Gap 4's defect one indirection deeper.  Gap 4's devirtualizer matches
;;; `(~ (extents~ SYM) i)` -- a bare symbol.  A ring operand appears as
;;; `(~ (extents~ (ring-get SYM i)) j)`, so it never matched.
;;;
;;; Scoped to rings that were REGISTER rings in the ORIGINAL anf.  A genuine scratch
;;; ring keeps its runtime extents~: its binding does survive into the backward (that
;;; is why 138's and 145/18's ring specs work), and rewriting them would be a
;;; behavioural change to specs that already pass for the right reason.
;;; ===================================================================

;; src/autodiff.lisp
(defun %ad-register-ring-dims-map (flat-anf)
  "Alist SYM -> (d0 d1) for every `(make-register-tile-ring T (D0 D1) ...)` binding.

   Must be computed from the ORIGINAL anf, BEFORE %ad-canonicalize-register-rings turns
   these into scratch rings -- afterwards they are indistinguishable from rings the user
   really wrote as scratch, whose extents must be left alone."
  (let ((acc nil))
    (%mma-ad-walk-forms
     flat-anf
     (lambda (form)
       (when (and (= (length form) 2) (symbolp (first form))
                  (consp (second form)) (symbolp (first (second form)))
                  (string-equal (symbol-name (first (second form)))
                                "MAKE-REGISTER-TILE-RING")
                  (let ((d (third (second form))))
                    (and (listp d) d (every #'integerp d)))
                  (not (assoc (first form) acc)))
         (push (cons (first form) (third (second form))) acc))))
    (nreverse acc)))

;; src/autodiff.lisp
(defun %ad-normalize-ring-view-extents (form ring-dims)
  "Replace `(~ (extents~ (ring-get RING I)) J)` with RING's compile-time per-slot extent J,
   emitted as `(to-ulong N)`, for every RING in RING-DIMS.

   Every slot of a ring has the ring's element shape (138), so the slot index is irrelevant
   to the answer and is not examined.  The ULONG wrap is required for the same reason as in
   %ad-normalize-register-extents: these reads sit inside `(* (to-ulong G) <extent>)`.

   No-op when RING-DIMS is empty."
  (if (null ring-dims)
      form
      (let ((tu (intern "TO-ULONG" (find-package :crisp-language))))
        (labels ((ring-base (f)
                   ;; (ring-get SYM i) -> SYM, else NIL
                   (and (consp f) (symbolp (first f))
                        (string-equal (symbol-name (first f)) "RING-GET")
                        (symbolp (second f))
                        (second f)))
                 (static-extent (f)
                   (and (consp f) (= (length f) 3)
                        (symbolp (first f))
                        (string-equal (symbol-name (first f)) "~")
                        (consp (second f))
                        (symbolp (first (second f)))
                        (string-equal (symbol-name (first (second f))) "EXTENTS~")
                        (integerp (third f))
                        (let ((base (ring-base (second (second f)))))
                          (and base
                               (nth (third f) (cdr (assoc base ring-dims)))))))
                 (walk (f)
                   (cond ((not (consp f)) f)
                         ((static-extent f) (list tu (static-extent f)))
                         (t (mapcar #'walk f)))))
          (walk form)))))

;; src/autodiff.lisp -- the chain, now with ring-view extents.
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types
                                        &key kernel-pkg)
  "Endeavor 146: normalize the flat ANF before the walk sees it, run the walk unchanged,
   then ensure any ring adjoint the walk NAMED actually got BOUND.

   Normalizations, each removing a distinction the DERIVATIVE does not care about:

     1. literal shape temps -> inlined       (%ad-inline-literal-shape-temps)
     2. wgmma -> sync MMA                    (%ad-canonicalize-wgmma)
     3. register ring VIEW extents~ -> literals
                                             (%ad-normalize-ring-view-extents)
     4. register-tile ring -> scratch ring   (%ad-canonicalize-register-rings)
     5. register-tile extents~ -> literals   (%ad-normalize-register-extents)

   Order is load-bearing.  (1) first so every shape test below sees literals.  (3) MUST
   precede (4): once a register ring has become a scratch ring it is indistinguishable
   from one the user wrote, whose runtime extents~ must be preserved.  (2) precedes (5)
   so a wgmma accumulator, by then a make-register-tile, is in the register-tile map.

   The fixup afterwards covers a gap the walk has independently of all this: its
   top-level adjoint collection does not know the ring constructors."
  (let* ((inlined (%ad-inline-literal-shape-temps flat-anf))
         (canonical (%ad-canonicalize-wgmma inlined))
         (ring-dims (%ad-register-ring-dims-map canonical))
         (ringfixed (%ad-normalize-ring-view-extents canonical ring-dims))
         (deringed (%ad-canonicalize-register-rings ringfixed))
         (normalized (%ad-normalize-register-extents
                      deringed
                      (%ad-register-tile-dims-map deringed))))
    (%ad-ensure-ring-adj-bindings
     (funcall *ad-orig-generate-backward-walk*
              normalized inputs outputs input-types output-types
              :kernel-pkg kernel-pkg)
     normalized
     kernel-pkg)))


;;; Endeavor 146 Gap 1, part 7 — log the POST-fixup backward.
;;;
;;; generate-backward-walk logs its assembled AST from INSIDE itself, which means
;;; everything this overlay's wrapper does afterwards -- specifically the ring adjoint
;;; bindings from %ad-ensure-ring-adj-bindings -- has been invisible.  Five attempts at
;;; the ring path were made without ever seeing their own output.  Log it.

;; src/autodiff.lisp
(defun generate-backward-walk (flat-anf inputs outputs input-types output-types
                                        &key kernel-pkg)
  "Endeavor 146: normalize the flat ANF before the walk sees it, run the walk unchanged,
   then ensure any ring adjoint the walk NAMED actually got BOUND.

   Normalizations, each removing a distinction the DERIVATIVE does not care about:

     1. literal shape temps -> inlined       (%ad-inline-literal-shape-temps)
     2. wgmma -> sync MMA                    (%ad-canonicalize-wgmma)
     3. register ring VIEW extents~ -> literals
                                             (%ad-normalize-ring-view-extents)
     4. register-tile ring -> scratch ring   (%ad-canonicalize-register-rings)
     5. register-tile extents~ -> literals   (%ad-normalize-register-extents)

   Order is load-bearing.  (1) first so every shape test below sees literals.  (3) MUST
   precede (4): once a register ring has become a scratch ring it is indistinguishable
   from one the user wrote, whose runtime extents~ must be preserved.  (2) precedes (5)
   so a wgmma accumulator, by then a make-register-tile, is in the register-tile map.

   Logs the FINAL backward at debug level.  The engine's own log happens before this
   function's post-processing, so without this the fixup's output cannot be inspected."
  (let* ((inlined (%ad-inline-literal-shape-temps flat-anf))
         (canonical (%ad-canonicalize-wgmma inlined))
         (ring-dims (%ad-register-ring-dims-map canonical))
         (ringfixed (%ad-normalize-ring-view-extents canonical ring-dims))
         (deringed (%ad-canonicalize-register-rings ringfixed))
         (normalized (%ad-normalize-register-extents
                      deringed
                      (%ad-register-tile-dims-map deringed)))
         (raw (funcall *ad-orig-generate-backward-walk*
                       normalized inputs outputs input-types output-types
                       :kernel-pkg kernel-pkg))
         (final (%ad-ensure-ring-adj-bindings raw normalized kernel-pkg)))
    (log:debug "146: ring ctors seen: ~s" (%ad-ring-ctor-bindings normalized))
    (log:debug "146: FINAL backward after overlay fixups:~%~s" final)
    final))


;;; Endeavor 146 Gap 1, part 8 — do not run a RING constructor through the
;;; scratch-tile promoter.
;;;
;;; Found by finally logging the wrapper's own output.  The `146:` log lines never
;;; appeared for 142/10 while appearing 8 times for a succeeding compile, which places
;;; the error INSIDE the wrapper's let* rather than downstream -- and the only new work
;;; there is %ad-ensure-ring-adj-bindings.
;;;
;;; It called %mma-ad-adj-init, which for a non-register-tile delegates to
;;; %promote-scratch-init-for-ad.  That function opens with
;;;     (canonical (%scratch-tensor-canonical-spec op args))
;;; and only knows MAKE-SCRATCH-{VECTOR,MATRIX,TENSOR,CELL}.  Handed a
;;; MAKE-SCRATCH-MATRIX-RING it produces the stub `(TENSOR FLOAT)` -- which is exactly
;;; the `Invalid incomplete type specifier: (TENSOR FLOAT)` that five earlier attempts
;;; kept re-reading as a problem with the emitted CODE.  It was never the code; the
;;; adjoint allocator was signalling while building it.
;;;
;;; A ring adjoint needs no promotion anyway: it is a ring of the SAME shape, and these
;;; rings are float already (they came from register tiles, whose fragments are fp32).
;;; So use the constructor as it stands.
;;;
;;; The lesson is the one CLAUDE.md states outright: log first.  The wrapper's output
;;; was invisible for five iterations because the engine logs its AST from inside
;;; itself, before any of this runs.

;; src/autodiff.lisp
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
   needed regardless: these rings are float already."
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
                   (cddr backward))))))
