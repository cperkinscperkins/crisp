;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; HOT-PATCH OVERLAY for CRISP.COMPILER -- append late definitions here and the build
;;;; picks them up after src/, so a fix can be made without editing src directly.
;;;;
;;;; EMPTY BY DESIGN.  Its 128 definitions were folded into src/ on 2026-08-26.
;;;;
;;;; When you fold future contents back out, two things bite:
;;;;   * VARIABLES belong in src/specials.lisp.  A `let` on a special compiled before its
;;;;     defvar is seen becomes a LEXICAL binding, silently.  Overlay variables are safe
;;;;     only because the overlay loads last; that protection disappears on the way in.
;;;;   * A definition that REPLACES one in src must overwrite it in place, not be
;;;;     appended -- otherwise both are live and ASDF order picks the winner.

(in-package :crisp.compiler)


;; src/codegen.lisp
;;
;; BUG: :xe-native at 32 subgroups computed a WRONG matmul on every Intel runtime newer than
;; NEO 25.18 (verified on NEO 26.27 / IGC 2.38.2 in Docker AND on the Windows host driver
;; 32.0.101.8974).  Only warp (0,0) was correct: rows 0-31 x cols 0-63 exact, every warp with a
;; nonzero row OR column offset wrong.  Same SPIR-V is correct on IGC 2.11.12, so nothing about
;; the emitted coordinates is stale -- what changed is how the newer compiler treats them.
;;
;; WHAT THIS CHANGES.  The warp-sliced LOAD expanded to a STATIC PER-WARP SWITCH: an if-chain of
;; `gm` (or `gn`) arms, each issuing its own block loads with literal coordinates.  It now emits
;; ONE arm whose coordinates carry a runtime warp term -- exactly what %emit-per-frag-store
;; (src/mma.lisp) already does, and for the reason its own docstring gives:
;;
;;     "139 step-4 made this a static per-warp switch, which is right at 2-3 warps and
;;      catastrophic at 32. ... With the 2-D warp grid the address is REGULAR, so one arm suffices"
;;
;; The store was converted to runtime addressing; the load was not.  That is the third time a fix
;; has landed on one side of this pair and not the other (see the FLOOR/MOD note below, and 156
;; Phase 1).  This finishes it.
;;
;; WHY ONE ARM IS EXACTLY EQUIVALENT.  Every arm assigned the SAME fragment slots -- the index is
;; `lr*n-cols+ci` (:a) or `ri*slice+lc` (:b), neither of which mentions the arm `w`.  Only the
;; COORDINATE differed, as `w*slice + lr`.  Substituting the runtime slice index for the literal
;; `w` reproduces every arm's coordinate and nothing else changes, so the register slots stay
;; static and only the address gains a runtime term -- two scalar ops shared by all fragments.
;;
;; NOT A WORKAROUND, and worth keeping even if a future IGC changes back: at the shipped 256x256
;; over 32 subgroups this emitted 64 A-loads + 32 B-loads per k-step (8 arms x 8, 4 arms x 8);
;; one arm needs 8 + 8.  Endeavour 156 exists to attack the INSTRUCTION STREAM, so deleting 80 of
;; 96 loads is on-target rather than incidental.
;;
;; STILL DISPATCHED ON :coop-matrix.  The explosion runs in the ANALYZER
;; (analyze-let-with-tile-explosion), outside the *mma-lowering* binding that generate-llvm-ir
;; establishes, so *mma-lowering* is always the :coop-matrix default here and :xe-native reaches
;; this same method.  That is pre-existing and is why one edit fixes both; giving the analyzer the
;; kernel's real lowering is a separate change and should be made deliberately, not as a side
;; effect of a bug fix.
(defmethod %emit-per-frag-block-load-impl ((lowering (eql :coop-matrix)) src entry coords)
  (declare (ignorable lowering))
  "Endeavor 142 — per-fragment expansion of (load-tile SRC <register-tile> COORDS).

   Endeavour 155 Step 2b: when the tile is WARP-SLICED, each warp loads only its own rows (:a) or
   columns (:b), at global coordinates offset by its grid position.

   The per-warp offset is RUNTIME-ADDRESSED (one arm), not a static per-warp switch.  See the
   overlay comment above: the static form miscomputes on IGC >= 2.38 and costs 6x the loads."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) (operand :acc)) (cdr entry)
    (declare (ignore n-true))
    (let ((cl (find-package :crisp-language)))
      (destructuring-bind (fr . fc) (%frag-mn-for-operand operand (%register-tile-elem-of (first entry)))
        (let* ((frag-fn (ecase operand
                          (:a (intern "LOAD-FRAGMENT-A" cl))
                          (:b (intern "LOAD-FRAGMENT-B" cl))
                          (:acc (error 'crisp-compiler-error
                                  :message "load-tile into an accumulator register-tile is not supported (only :operand :a / :b tiles are load targets)."
                                  :source-location nil))))
               (to-int  (intern "TO-INT" cl))
               (n-rows  (floor m fr))
               (n-cols  (floor n fc))
               (gy      (first coords))
               (gx      (second coords))
               (slice   (%warp-slice-extent entry operand))
               (grid    *warp-grid*))
          (flet ((one (idx row col)
                   `(set! ,(nth idx syms)
                          (,frag-fn ,src
                                    ((+ (* (,to-int ,gy) ,n-rows) ,row)
                                     (+ (* (,to-int ,gx) ,n-cols) ,col))))))
            (if (not (and slice grid))
                `(progn
                   ,@(loop for ri below n-rows append
                           (loop for ci below n-cols
                                 for idx = (+ (* ri n-cols) ci)
                                 collect (one idx ri ci))))
                (let* ((progn-sym (intern "PROGN" cl))
                       (let-sym   (intern "LET" cl))
                       (plus-sym  (intern "+" cl))
                       (minus-sym (intern "-" cl))
                       (div-sym   (intern "/" cl))
                       (times-sym (intern "*" cl))
                       (warp-id   (intern "WARP-ID" cl))
                       (gn        (cdr grid))
                       (wp        (gensym "WP"))
                       (sl        (gensym "SL"))
                       ;; The warp's slice ORIGIN in fragments: sl*slice.  Hoisted into its own
                       ;; binding so all fragments share the multiply rather than repeating it.
                       (org       (gensym "ORG")))
                  `(,let-sym ((,wp (,minus-sym (,to-int (,warp-id)) ,first-true)))
                     ;; 156 Phase 1: INTEGER / and - , not FLOOR/MOD.
                     ;;
                     ;; (intern "FLOOR" :crisp-language) resolves to CRISP.COMPILER:FLOOR, which
                     ;; returns a FLOAT -- %emit-per-frag-store already documents that and moved
                     ;; to / and - for its addresses.  (intern "MOD" :crisp-language) is worse:
                     ;; MOD does not exist there at all, so the intern MINTS a fresh symbol with
                     ;; no operator behind it.
                     ;;
                     ;; This now feeds an ADDRESS, not a comparison.  Under the old if-chain a
                     ;; wrong selector merely picked an arm; here it displaces every load, so the
                     ;; integer forms are load-bearing in the same way %emit-per-frag-store says
                     ;; they are for the store.
                     (,let-sym ((,sl ,(if (eq operand :a)
                                          `(,div-sym ,wp ,gn)
                                          `(,minus-sym ,wp (,times-sym (,div-sym ,wp ,gn) ,gn)))))
                       (,let-sym ((,org (,times-sym ,sl ,slice)))
                         (,progn-sym
                           ,@(if (eq operand :a)
                                 (loop for lr below slice append
                                       (loop for ci below n-cols
                                             for idx = (+ (* lr n-cols) ci)
                                             collect (one idx `(,plus-sym ,org ,lr) ci)))
                                 (loop for ri below n-rows append
                                       (loop for lc below slice
                                             for idx = (+ (* ri slice) lc)
                                             collect (one idx ri `(,plus-sym ,org ,lc)))))))))))))))))
