;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; HOT-PATCH OVERLAY for CRISP.COMPILER -- append late definitions here and the build
;;;; picks them up after src/, so a fix can be made without editing src directly.
;;;;
;;;; EMPTY BY DESIGN.  Its 128 definitions were folded into src/ on 2026-08-26, and
;;;; endeavour 163's 23 definitions were folded in on 2026-09-06 (15 replaced their src
;;;; originals in place, 8 new helpers were appended to their target files, and a
;;;; duplicate *ad-ring-slot-marker* identical to src/autodiff.lisp's was dropped).
;;;;
;;;; When you fold future contents back out, three things bite:
;;;;   * VARIABLES belong in src/specials.lisp.  A `let` on a special compiled before its
;;;;     defvar is seen becomes a LEXICAL binding, silently.  Overlay variables are safe
;;;;     only because the overlay loads last; that protection disappears on the way in.
;;;;   * A definition that REPLACES one in src must overwrite it in place, not be
;;;;     appended -- otherwise both are live and ASDF order picks the winner.
;;;;   * A FORMAT string using ~<newline> continuation works in an LF overlay and DIES
;;;;     when folded into CRLF src/, and the error names the wrong place.  Both files are
;;;;     CRLF today, so this is only a hazard if an overlay is ever written as LF.

(in-package :crisp.compiler)


;;; ===================================================================
;;; Endeavour 165 — a register tile that cannot hold a fragment must REFUSE, not vanish.
;;;
;;; THE DEFECT.  `analyze-make-register-tile` and the store/mma walks size a tile as
;;; (floor m 16) x (floor n 8) fragments, so ANY tile with M < 16 or N < 8 yields ZERO
;;; fragments.  There is nothing to fill, nothing to store and nothing to multiply, so the
;;; kernel legitimately optimises down to `ret;` -- and the compiler reports success.
;;; Demonstrated on the dev box with a plain fp32 8x8 tile (put_temp_files_here/165/probe/):
;;; a fill + store-tile kernel emitted an empty body and exit code 0.
;;;
;;; `%ensure-register-tile-type` ALREADY guards exactly this and says so.  It never fires,
;;; because a LET-bound tile -- which is what every real kernel writes -- goes through
;;; `%explode-register-tiles` instead, and that path never re-checks.  The guard existed and
;;; was bypassed by the only route anyone uses.
;;;
;;; THE FIX.  One shared predicate, called from BOTH paths, so they cannot drift apart again.
;;; It is hooked into `%register-tile-fit-check` rather than into `%explode-register-tiles`
;;; because the fit-check is already invoked exactly once per register-tile binding on that
;;; path and already receives (m n location) -- a 15-line append instead of transcribing a
;;; 124-line function, which is its own class of risk.
;;;
;;; SCOPED TO THE NVIDIA PATH, deliberately.  On PTX `%frag-mn-for-operand` returns a
;;; hardcoded 16x8 for every operand and element type, so the geometry is unambiguous here.
;;; On SPIR-V it is derived per-element from `%spv-mma-shape`, and the fit-check does not
;;; receive the tile's element type or operand role -- guessing :acc would false-refuse a
;;; legitimate A or B tile and break shipped kernels.  SPIR-V can hit the same zero-fragment
;;; case with a mismatched shape; closing it there needs the elem threaded through, and is
;;; left as its own step rather than smuggled in behind a wrong default.
;;;
;;; NOTE FOR THE SRC PATCH: %register-tile-dims-must-divide is new (src/mma.lisp);
;;; %ensure-register-tile-type REPLACES src/mma.lisp:1001; %register-tile-fit-check
;;; REPLACES src/mma.lisp:1307.
;;; ===================================================================

;; src/mma.lisp
(defun %register-tile-dims-must-divide (m n location &optional (fr 16) (fc 8))
  "Refuse a register tile whose dims do not cover at least one whole FR x FC fragment.

   A tile of (M N) holds (floor M FR) x (floor N FC) fragments.  When either floor is zero the
   tile holds NOTHING, and every construct that walks it -- store-tile, fill-tile,
   mma-accumulate-via-tile -- expands to no code, so the kernel compiles clean and does nothing.
   That is the one outcome a compiler must never produce silently, so this is an error and not a
   warning: there is no reading of a zero-fragment tile under which the user got what they asked
   for.

   Endeavour 165.  fp64's only tensor-core shape is m8n8k4, whose accumulator is 8x8 -- under the
   hardcoded 16x8 fragment in BOTH dimensions -- so every fp64 MMA kernel would have walked into
   this.  The defect itself is older and has nothing to do with fp64: a plain fp32 8x8 tile
   reproduces it exactly."
  (unless (and (integerp m) (integerp n) (plusp m) (plusp n)
               (zerop (mod m fr)) (zerop (mod n fc)))
    (error 'crisp-compiler-error
           :message (format nil "make-register-tile: dims (~a ~a) must be multiples of the ~ax~a accumulator fragment. (~a ~a) holds ~a fragments, so the tile would carry no values and every store-tile / fill-tile / mma-accumulate-via-tile over it would expand to no code at all."
                            m n fr fc m n
                            (* (floor m fr) (floor n fc)))
           :source-location location)))




;;; ===================================================================
;;; Endeavour 165 step 2a — thread the ELEMENT TYPE through the register-tile path.
;;;
;;; NO GEOMETRY CHANGES HERE.  %acc-frag-mn returns 16x8 for every element type, so the emitted
;;; code is byte-identical to before; this step only makes the element type REACHABLE at the
;;; sites that will need it.  Step 2b changes %acc-frag-mn alone.
;;;
;;; WHY IT WAS UNREACHABLE.  The store-tile walk and the MMA walk recover a tile's geometry from
;;; *register-tile-dims* keyed by the minted TYPE NAME -- and that name was
;;; REGISTER-TILE-ACC-F32-MxN with only (M N) in the table.  The element type existed at the
;;; binding site and was gone by the time anything needed it.
;;;
;;; THE NAME IS NOW HONEST, and that is not cosmetic: a name that hardcodes F32 makes two tiles
;;; of different element types and identical dims COLLIDE on one record.  That is BUG 055
;;; (%coop-call caching a coop-matrix declaration by name alone) in a second location, and it is
;;; cheaper to not create it than to fix it twice.  Verified safe to rename: the string appears
;;; nowhere outside src/mma.lisp, and autodiff identifies register tiles from the ANF form
;;; (make-register-tile without :operand), never from the type name.
;;;
;;; These four definitions were EXTRACTED VERBATIM from src/mma.lisp by
;;; put_temp_files_here/165/patch2a.py (balanced-paren scan) and edited by exact-match
;;; replacement, each asserted to hit exactly once.  Nothing here was retyped by hand.
;;;
;;; NOTE FOR THE SRC PATCH: %acc-frag-mn is new (src/mma.lisp); %register-tile-type-name
;;; REPLACES src/mma.lisp:994; %ensure-register-tile-type REPLACES the 165 overlay copy above;
;;; analyze-make-register-tile REPLACES src/mma.lisp:1089; analyze-store-tile-mma REPLACES
;;; src/mma.lisp:1121; analyze-mma-accumulate-via-tile REPLACES src/mma.lisp:1182.
;;; ===================================================================


;; src/mma.lisp
(defun %register-tile-type-name (m n &optional (elem 'float))
  "The minted record name for an M x N register tile of element type ELEM.

   Endeavour 165 (step 2a): the name now carries the ELEMENT TYPE.  It used to be
   REGISTER-TILE-ACC-F32-MxN unconditionally, which was a lie the moment a double tile existed
   and -- worse -- a COLLISION: two tiles with the same dims and different element types would
   have shared one record.  That is not hypothetical; it is exactly BUG 055, where %coop-call
   caches the coop-matrix declaration by name alone and two element types in one module silently
   collide.  One instance of that bug is enough.

   ELEM defaults to FLOAT so any caller not yet threading it keeps the pre-165 record."
  (intern (format nil "REGISTER-TILE-ACC-~a-~dX~d" (symbol-name elem) m n)
          (find-package :crisp.compiler)))


;; src/mma.lisp
(defun analyze-make-register-tile (expr env context location)
  "P3a: (make-register-tile T (M N) INIT &key warps) -> a record-of-fragments accumulator tile,
   each fragment initialized to INIT.  Mints the tile type on demand; rewrites to
   %construct-struct of make-register-fragment fields.
   Endeavour 165 (2a): ELEM now reaches the minted tile type and the fragment count.
   Endeavor 139 (decision A): :warps is a flat topology mask of which warps hold the tile.  For a
   single participating warp (or no mask) the tile is the full (M/16)x(N/8) fragment set on that
   warp — the current build.  Distributing across >= 2 participating warps (the occupancy lever)
   is sub-step 2."
  (let* ((args     (cdr expr))
         (elem     (first args))
         (dims     (second args))
         (init     (third args))
         (kwargs   (nthcdr 3 args))
         (warps-in (getf kwargs :warps)))
    (destructuring-bind (m n) dims
      (let* ((tile-name (%ensure-register-tile-type m n elem))
             (fmn       (%acc-frag-mn elem))
             (nfrags    (* (floor m (car fmn)) (floor n (cdr fmn)))))
        (when warps-in
          ;; This (%construct-struct, non-exploded) path is only reached for a make-register-tile
          ;; NOT bound in a let — a let binding is EXPLODED, and %explode-register-tiles does the
          ;; distribution.  Validate here; distribution needs the explosion, so >=2 warps errors.
          (let* ((mask   (%normalize-warp-mask (%warp-mask-unquote warps-in) location))
                 (n-true (%validate-warp-mask mask nfrags (%resolve-workgroup-warp-count context) m n location)))
            (when (> n-true 1)
              (error 'crisp-compiler-error
                :message "make-register-tile with :warps distributing across >= 2 warps must be a let binding (so the compiler can split the fragments)."
                :source-location location))))
        (analyze-expression
         `(%construct-struct ,tile-name
                             ,@(loop repeat nfrags collect `(make-register-fragment 16 8 ,init :elem ,elem)))
         env context location)))))


;; src/mma.lisp
(defun analyze-mma-accumulate-via-tile (expr env context location)
  "P3b-1: (mma-accumulate-via-tile (M N K) C-TILE A B) — walk the register C-tile in
   16x8 fragments and accumulate ONE K-step (K = the shape's K) into each, set!-ing the
   accumulated tile back.  Bodyless (no accum-op / epilogue yet)."
  (destructuring-bind (mma-shape c-tile a b) (cdr expr)
    (%check-mma-shape mma-shape location)
    (let* ((c-node (analyze-expression c-tile env context (append location '(1))))
           (c-type (semantic-node-type c-node)))
      (unless (%register-tile-type-p c-type)
        (error 'crisp-compiler-error
               :message (format nil "mma-accumulate-via-tile: C-tile (2nd arg) must be a register-tile, got type ~a." c-type)
               :source-location location))
      (destructuring-bind (tm tn &optional (elem 'float)) (gethash c-type *register-tile-dims*)
        (let* ((fmn (%acc-frag-mn elem))
               (m-frags (floor tm (car fmn))) (n-frags (floor tn (cdr fmn))))
          (analyze-expression
           `(set! ,c-tile
              (let ((cv ,c-tile))
                (%construct-struct ,c-type
                  ,@(loop for mi below m-frags
                          append (loop for nj below n-frags
                                       for idx = (+ (* mi n-frags) nj)
                                       collect `(mma-accumulate
                                                 (%extract-struct-member cv ,idx)
                                                 (load-fragment-a ,a (,mi 0))
                                                 (load-fragment-b ,b (0 ,nj))))))))
           env context location))))))


;;; ===================================================================
;;; Endeavour 165 step 2b-i (v2) — reach the ELEMENT TYPE from the register-tile emitters.
;;;
;;; STILL NO GEOMETRY CHANGE.  %acc-frag-mn answers 16x8 for every element type; 2b-ii flips it.
;;;
;;; WHAT v1 GOT WRONG, kept here because the correction is the interesting part.  v1 appended
;;; ELEM as a seventh field on the tile ENTRY.  That broke src/codegen.lisp:5477 -- the load-tile
;;; per-fragment expansion -- because the survey had been scoped to src/mma.lisp while the entry
;;; shape is consumed across files.  Three Intel negative specs died with "too many elements ...
;;; to satisfy lambda list (M N SYMS &OPTIONAL (N-TRUE) (FIRST-TRUE) (OPERAND))", and two Intel
;;; on-metal specs failed with them.  A 14-file byte-identical IR check had said the change was
;;; inert; it was inert on the files sampled and not on the suite, which is the difference
;;; between a spot check and a proof.
;;;
;;; v1 was also fighting the design.  That same codegen site already asks the question properly:
;;;     (%frag-mn-for-operand operand (%register-tile-elem-of (first entry)))
;;; -- a side-table lookup keyed by the tile's own symbol, populated into *register-tile-elems*
;;; by %explode-register-tiles.  The entry deliberately does not carry the element type; there is
;;; an established way to ask.  v2 uses it, so the entry shape never changes and no consumer
;;; anywhere needs patching.
;;;
;;; NOTE FOR THE SRC PATCH: %frag-mn REPLACES src/mma.lisp:1268; %emit-per-frag-accumulate
;;; REPLACES :1403; %emit-per-frag-store REPLACES :1491; %emit-per-frag-acc-load REPLACES :2852;
;;; %register-tile-fit-check REPLACES the 165 overlay copy above; %explode-register-tiles
;;; REPLACES :1877.
;;; ===================================================================

;; src/mma.lisp
(defun %frag-mn (&optional (elem 'float))
  "Per-fragment (M . N) for register-tile decomposition: the active profile's mma-shape (M N) on
   :spirv, else the NVIDIA accumulator geometry for ELEM.

   Endeavour 165 (2b-i): takes ELEM and defers to %acc-frag-mn on the NVIDIA path instead of
   answering a flat 16x8 for everything.  ELEM defaults to FLOAT, so a caller that has not been
   taught to thread it keeps the pre-165 answer -- which is what makes this step inert."
  (if (eq *target-backend* :spirv)
      (multiple-value-bind (m n k) (%spv-mma-shape) (declare (ignore k)) (cons m n))
      (%acc-frag-mn elem)))

;; src/mma.lisp
(defun %emit-per-frag-accumulate (a b entry tiles &optional accum-binding body shape)
  "Per-fragment expansion of mma-accumulate-via-tile.  Endeavor 139 step-4: distributed path is a
   static per-warp switch (n-true threaded to %emit-frag-loop-distributed).  Endeavor 142: when A/B
   are register-tiles (present in TILES, pre-loaded via load-tile), the operand is read from its
   pre-loaded fragment var instead of load-fragment-a/b.

   Endeavor 145 P3a: the staged operands may span SEVERAL native K-steps (Kt / K_n, compile-time)
   and every one of them now fires.  Previously only K-index 0 was emitted and any surplus staged
   data was silently dropped.  For the F3 body/accum-op API this means (accum-op) fires the
   fragment's WHOLE contraction — all of its K-steps — which keeps the promise that the body
   controls WHEN a fragment accumulates, not how its contraction is chopped up."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) operand) (cdr entry)
    (declare (ignore operand))
    (destructuring-bind (fm . fn) (%frag-mn (%register-tile-elem-of (first entry)))
      ;; Endeavour 155 Phase C: honour the shape the KERNEL asked for.
      ;;
      ;; (mma-accumulate-via-tile (8 16 16) C A B) states K=16, which is the correct native
      ;; K-step for a 16-bit operand.  Re-deriving it from (first :mma-shapes) returned the TF32
      ;; K=8 instead, so the walker indexed fragments on a different K than the tiles were minted
      ;; with -- the A-tile held one K=16 fragment while the walker asked for two K=8 ones, and
      ;; the second came back NIL ("Unknown variable NIL").
      ;;
      ;; The requested shape was already in hand at the call site and already validated against
      ;; the profile by %check-mma-shape; it simply was not passed down.  Falling back to
      ;; %spv-mma-shape keeps every other caller behaving exactly as before.
      (multiple-value-bind (sm sn sk)
          (if (and shape (listp shape) (= (length shape) 3) (every #'integerp shape))
              (values-list shape)
              (%spv-mma-shape))
        (declare (ignore sm))
        (let* ((m-frags (floor m fm))
               (n-frags (floor n fn))
               (k-steps (%mma-k-steps a b tiles sk nil)))
          (labels ((a-operand (mi ks)
                     (let ((ta (%resolve-tile-ref a tiles)))
                       (if ta
                           ;; A register tile is Mt x Kt of sm x sk fragments: row-major over
                           ;; (mi, ks), row stride = its own K-step count.
                           (let* ((mp (%warp-slice-extent ta :a))          ; 155 Step 2b
                                  (row (if mp (mod mi mp) mi)))
                             (nth (+ (* row (max 1 (floor (third ta) sk))) ks) (fourth ta)))
                           `(load-fragment-a ,a (,mi ,ks)))))
                   (b-operand (nj ks)
                     (let ((tb (%resolve-tile-ref b tiles)))
                       (if tb
                           ;; A register tile is Kt x Nt of sk x sn fragments: row-major over
                           ;; (ks, nj), row stride = its own column-fragment count.
                           (let* ((np (%warp-slice-extent tb :b))          ; 155 Step 2b
                                  (stride (or np (max 1 (floor (third tb) sn))))
                                  (col (if np (mod nj np) nj)))
                             (nth (+ (* ks stride) col) (fourth tb)))
                           `(load-fragment-b ,b (,ks ,nj)))))
                   (one-frag (fv mi-form nj-form)
                     (let* ((sets (loop for ks below k-steps
                                        collect `(set! ,fv (mma-accumulate ,fv
                                                                           ,(a-operand mi-form ks)
                                                                           ,(b-operand nj-form ks)))))
                            (acc-set (if (= (length sets) 1) (first sets) `(progn ,@sets))))
                       (if body
                           (mapcar (lambda (f) (%subst-accum f accum-binding fv acc-set)) body)
                           (list acc-set)))))
            (if (> n-true 1)
                ;; Endeavour 155: register-resident A/B ARE supported with a warp-distributed
                ;; accumulator.  The refusal this replaces was incidental, not essential --
                ;; %emit-frag-loop-distributed's own contract says so:
                ;;
                ;;   "PER-FRAG-FN is called with (fv mi nj) where mi/nj are INTEGERS
                ;;    (same contract as the n-true=1 static path)."
                ;;
                ;; and it computes them as (floor logical n-frags) / (mod logical n-frags), both
                ;; compile-time.  a-operand/b-operand index the tile's fragment SYMBOL LIST with
                ;; (nth ...), which needs exactly that -- a constant.  139 step-4 made this path
                ;; static precisely so operand addressing could be static, so the machinery the
                ;; refusal was waiting for already existed when it was written.
                ;;
                ;; WHY THIS MATTERS.  It is the only route to a bigger workgroup tile that does
                ;; NOT go through SLM.  C is what limits tile size -- 64x64 in one subgroup spills
                ;; 112 registers and collapses to 20 TFLOPS -- and splitting C across subgroups
                ;; divides exactly that pressure, while A/B keep the register+prefetch path that
                ;; is the fastest thing on this hardware.  A/B are then loaded redundantly per
                ;; warp, which costs bandwidth the cache may absorb; that is the trade to measure.
                (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag)
                `(progn
                   ,@(loop for mi below m-frags append
                           (loop for nj below n-frags
                                 for idx = (+ (* mi n-frags) nj)
                                 append (one-frag (nth idx syms) mi nj)))))))))))


;; src/mma.lisp
(defun %register-tile-fit-check (m n location &optional (elem 'float))
  "F1 register FIT-CHECK — NVIDIA per-thread register model only.  On :spirv the tile is opaque
   cooperative matrices (the driver owns register residency), so SKIP — Intel GRF accounting is
   separate (Phase 4).  Else: (M/fr)x(N/fc) accumulator fragments x regs-per-fragment <=
   :max-registers-per-thread.

   Endeavor 144 (D4): reads the budget through %hp-registers-per-thread-default, since
   :max-registers-per-thread may be a scalar OR a list of selectable modes.

   Endeavour 165 (BUG 058): also refuses a tile too SMALL to hold one fragment.  A tile that
   overflows the register budget and a tile that holds nothing are the same kind of mistake and
   are named by the same function, at compile time, rather than discovered as a spill or as an
   empty kernel.

   Endeavour 165 (2b-i): takes ELEM so both bounds use the element type's own fragment geometry.
   Inert while %acc-frag-mn answers 16x8 for everything."
  (unless (eq *target-backend* :spirv)
    (destructuring-bind (fr . fc) (%acc-frag-mn elem)
      (%register-tile-dims-must-divide m n location fr fc)
      (let* ((nfrags        (* (floor m fr) (floor n fc)))
             (regs-per-frag 4)
             (total-regs    (* nfrags regs-per-frag))
             (budget        (or (%hp-registers-per-thread-default)
                                *default-max-registers-per-thread*)))
        (when (> total-regs budget)
          (error 'crisp-compiler-error
                 :message (format nil "make-register-tile: a ~ax~a accumulator tile needs ~a registers/thread (~a fragments × ~a regs), exceeding the register budget of ~a.  Use a smaller tile shape or a hardware profile with a larger :max-registers-per-thread."
                                  m n total-regs nfrags regs-per-frag budget)
                 :source-location location))))))

;; src/mma.lisp
(defun %explode-register-tiles (let-expr &optional location context)
  "Source->source: explode any (V (make-register-tile T (M N) INIT &key warps)) binding in
   LET-EXPR into per-fragment (V$Fi (make-register-fragment 16 8 INIT)) bindings, and rewrite the
   body's via-tile/store-tile/fill-tile references to V into per-fragment progns.  Runs the register
   FIT-CHECK per tile.  A no-op (returns LET-EXPR unchanged) when no register-tile binding is present.
   Endeavor 139 (decision A): :warps distributes the tile across its participating warps — each warp
   allocates only nfrags/#true fragments (the entry carries n-true/first-true for the emit functions
   to reconstruct each warp's logical fragment range).
   Endeavor 145 P3a: also publishes the LET's SLM scratch-tile shapes in *mma-scratch-tile-dims* so
   the accumulate expansion can walk K within a staged tile."
  (if (not (and (consp let-expr) (>= (length let-expr) 2) (listp (second let-expr))))
      let-expr
      (let* ((head (first let-expr))
             (bindings (second let-expr))
             (body (cddr let-expr))
             ;; 145 P3a: SLM tile shapes for the K-step count (special -> dynamically scoped).
             (*mma-scratch-tile-dims* (%mma-scratch-tile-dims-from-bindings bindings))
             ;; 155 Step 2: the warp grid comes from the ACCUMULATOR and governs how the operand
             ;; tiles slice.  First pass over the same bindings; see the Step 2 header.
             (*warp-grid* (%warp-grid-from-bindings bindings context location))
             ;; 155 Phase C: publish each register tile's ELEMENT TYPE for the same reason and by
             ;; the same mechanism -- the load-tile expansion has only the tile entry, which does
             ;; not record it.
             (*register-tile-elems* (%register-tile-elems-from-bindings bindings))
             (tiles '()))
        (let ((new-bindings
                (loop for b in bindings
                      append
                      (if (and (consp b) (= (length b) 2) (symbolp (first b))
                               (%register-tile-init-form-p (second b)))
                          (let* ((form    (second b))
                                 (elem    (second form))   ; 155: element type, was discarded
                                 (dims    (third form))
                                 (init    (fourth form))
                                 (m       (first dims)) (n (second dims))
                                 (operand (getf (nthcdr 4 form) :operand :acc))
                                 (nfrags  (destructuring-bind (fr . fc) (%frag-mn-for-operand operand elem)
                                            (* (floor m fr) (floor n fc))))
                                 (warps-in (getf (nthcdr 4 form) :warps))
                                 (mask    (and warps-in
                                               (%normalize-warp-mask (%warp-mask-unquote warps-in) location))))
                            (%register-tile-fit-check m n location elem)
                            (multiple-value-bind (n-true first-true)
                                (if mask
                                    ;; 155 Step 2: validate an operand tile against ITS divisor
                                    ;; (gm for :a, gn for :b), not the warp count.
                                    (%validate-warp-mask mask nfrags
                                                         (%resolve-workgroup-warp-count context)
                                                         m n location
                                                         (and *warp-grid* (member operand '(:a :b))
                                                              (%operand-warp-divisor operand)))
                                    (values 1 0))
                              ;; 155 Step 2: an OPERAND tile slices by the grid axis its warps
                              ;; share, not by the total warp count -- gm slices for A, gn for B.
                              ;; The accumulator keeps n-true.  Guarded on *warp-grid*, so a tile
                              ;; without a distributed accumulator in scope allocates whole.
                              (let* ((div (if (and *warp-grid* mask (member operand '(:a :b)))
                                              (%operand-warp-divisor operand)
                                              n-true))
                                     (per-warp (max 1 (floor nfrags div)))
                                     (syms     (%register-tile-frag-syms (first b) per-warp)))
                                (push (list (first b) m n syms n-true first-true operand) tiles)
                                (loop for s in syms
                                      collect (list s `(make-register-fragment ,(car (%frag-mn-for-operand operand elem)) ,(cdr (%frag-mn-for-operand operand elem)) ,init :operand ,operand :elem ,elem))))))
                          (if (and (consp b) (= (length b) 2) (symbolp (first b))
                                   (%register-tile-ring-init-form-p (second b)))
                              (let* ((form    (second b))
                                     (elem    (second form))   ; 155: element type, was discarded
                                     (dims    (third form))
                                     (m       (first dims)) (n (second dims))
                                     (keys    (nthcdr 3 form))
                                     (operand (getf keys :operand :acc))
                                     (rc      (getf keys :ring-count))
                                     ;; 156 Phase 2: a RING may carry :warps too.  Without this the
                                     ;; ring branch gave every warp the WHOLE tile and recorded no
                                     ;; slice fields, so :warps on a ring kernel was a silent no-op
                                     ;; -- 32 subgroups each computing the identical tile.  Every
                                     ;; shipped 16-bit kernel is a ring kernel, which is why none of
                                     ;; them could use more than one subgroup whatever local-size said.
                                     (warps-in (getf keys :warps))
                                     (mask     (and warps-in
                                                    (%normalize-warp-mask (%warp-mask-unquote warps-in) location))))
                                (unless (and (integerp rc) (plusp rc))
                                  (error 'crisp-compiler-error
                                    :message (format nil "make-register-tile-ring: :ring-count must be a positive compile-time integer, got ~S." rc)
                                    :source-location location))
                                (%register-tile-fit-check m n location elem)
                                (destructuring-bind (fr . fc) (%frag-mn-for-operand operand elem)
                                  (let ((nfrags (* (floor m fr) (floor n fc))))
                                    ;; Mirror the plain register-tile branch exactly: validate the
                                    ;; mask against the tile's OWN divisor, then give each warp only
                                    ;; its slice, per SLOT.
                                    (multiple-value-bind (n-true first-true)
                                        (if mask
                                            (%validate-warp-mask mask nfrags
                                                                 (%resolve-workgroup-warp-count context)
                                                                 m n location
                                                                 (and *warp-grid* (member operand (list :a :b))
                                                                      (%operand-warp-divisor operand)))
                                            (values 1 0))
                                      (let* ((div (if (and *warp-grid* mask (member operand (list :a :b)))
                                                      (%operand-warp-divisor operand)
                                                      n-true))
                                             (per-warp (max 1 (floor nfrags div)))
                                             (slot-syms-list
                                               (loop for slot below rc
                                                     collect (%register-tile-frag-syms
                                                              (intern (format nil "~a$S~d" (symbol-name (first b)) slot)
                                                                      (symbol-package (first b)))
                                                              per-warp))))
                                        (push (list (first b) :ring m n slot-syms-list operand n-true first-true) tiles)
                                        (loop for syms in slot-syms-list
                                              append (loop for s in syms
                                                           collect (list s `(make-register-fragment ,(car (%frag-mn-for-operand operand elem)) ,(cdr (%frag-mn-for-operand operand elem)) 0.0 :operand ,operand :elem ,elem)))))))))
                              (list b))))))
          (if (null tiles)
              let-expr
              `(,head ,new-bindings
                      ,@(mapcar (lambda (f)
                                  (%explode-rewrite-body-form
                                   (%unroll-register-ring-loops f tiles) tiles))
                                body)))))))


;;; ===================================================================
;;; Endeavour 165 step 2b-ii — FLIP the geometry: fp64 accumulator fragments are 8x8.
;;;
;;; 2a and 2b-i were each proved inert (14 IR files byte-identical).  This step changes emitted
;;; code, and it changes it for `double` ONLY: every f32 / f16 / bf16 path still resolves to
;;; 16x8 through the very same functions, so the byte-identical check must STILL hold for them.
;;; That is the whole return on having done the two inert steps first -- when the f32 IR moves
;;; here, it is a bug, not a judgement call.
;;;
;;; THE LANE MAPPING IS NOT GUESSED.  fp64 m8n8k4 C/D comes from CuTe's
;;; MMA_Traits<SM80_8x8x4_F64F64F64F64_TN>: CLayout = Layout<Shape<Shape<_4,_8>,_2>,
;;; Stride<Stride<_16,_1>,_8>> over ThrID = Layout<_32>, which with t0 = lane%4, t1 = lane/4 and
;;; v in {0,1} gives m = lane/4, n = 2*(lane%4) + v.  It is the SAME column scheme the tf32 path
;;; already uses, with one row per lane instead of the g / g+8 pair -- corroboration, not
;;; coincidence.  A fragment lane layout is the textbook wrong-but-self-consistent failure: it
;;; compiles, emits the right instruction, passes every mechanical check and computes garbage
;;; that only metal catches.  Endeavour 159 lost a pod session to that class of thing, so this
;;; one came from a machine-readable primary source in the tree rather than from memory.
;;;
;;; STILL NOT DONE HERE: load-fragment-a / -b for fp64 and the m8n8k4 MMA emitter itself.  An
;;; fp64 register tile can now be built, filled and STORED; multiplying is step 3.
;;;
;;; NOTE FOR THE SRC PATCH: %acc-frag-mn and %frag-record-for-acc REPLACE/extend their 165
;;; overlay copies above; register-mma-types REPLACES src/mma.lisp:230;
;;; %ensure-register-tile-type REPLACES the 165 overlay copy; analyze-make-register-fragment
;;; REPLACES src/mma.lisp:~410; analyze-store-fragment REPLACES src/mma.lisp:508;
;;; %emit-per-frag-store REPLACES the 2b-i overlay copy; analyze-store-tile-mma REPLACES the 2a
;;; overlay copy.
;;; ===================================================================

;; src/mma.lisp
(defun %acc-frag-mn (elem)
  "The ACCUMULATOR fragment geometry (ROWS . COLS) for element type ELEM on the current backend.

   THE SINGLE SOURCE OF TRUTH.  Every geometry decision on the register-tile path -- the tile
   minter, the fit-check, the BUG 058 refusal, the store-tile walk, the MMA walk, the warp
   validator and the five %emit-per-frag-* emitters -- resolves here.  That is what steps 2a and
   2b-i built; this step is the payoff, because adding fp64 is now a change to one function.

   fp64: 8x8, because m8n8k4 is the ONLY fp64 tensor-core shape (LLVM 21.1.5 lowers only
   llvm.nvvm.mma.m8n8k4.row.col.f64; CUTLASS declares exactly one f64 tensor-op Mma, at
   GemmShape<8,8,4>).  Its accumulator is 8x8 = 64 elements over 32 lanes = 2 doubles per lane.

   Everything else keeps 16x8, the tf32/16-bit accumulator: 16x8 = 128 over 32 lanes = 4 fp32
   per lane.  16-bit operands accumulate in fp32 and so land here too, deliberately -- the same
   reason %coop-elem-of does not route accumulators through the operand element type.

   :spirv does not consult this; it derives its shape per-element from the profile via
   %spv-mma-shape, and was never 16x8-shaped."
  (if (and elem (symbolp elem) (string= (symbol-name elem) "DOUBLE"))
      (cons 8 8)
      (cons 16 8)))

;; src/mma.lisp
(defun %frag-record-for-acc (elem)
  "The ACCUMULATOR fragment record for element type ELEM.

   Endeavour 165 (2b-ii).  Sibling of %frag-record-for-operand, which has dispatched A and B
   records by element type since endeavour 159; the accumulator was the one role still naming
   register-fragment-acc-f32-16x8 outright at five sites.  One place decides this, so the tile
   minter and the fragment constructor cannot disagree about which record an element type maps
   to -- the same argument 159 made for the operands.

   A 16-bit MMA accumulates in fp32, so half/bfloat16 keep the f32 record on purpose."
  (if (and elem (symbolp elem) (string= (symbol-name elem) "DOUBLE"))
      'register-fragment-acc-f64-8x8
      'register-fragment-acc-f32-16x8))


;; src/mma.lisp
(defun %ensure-register-tile-type (m n &optional (elem 'float))
  "Mint (once) the register-tile record for an M x N tile of ELEM -- (M/fr)x(N/fc) fragment
   fields -- and record its dims AND element type.  Returns the type symbol.

   Endeavour 165 (2a): ELEM is threaded through, and *register-tile-dims* stores (M N ELEM),
   because the store-tile and MMA walks recover their geometry from that table by TYPE NAME and
   had no other way to learn the element type.

   Endeavour 165 (2b-ii): the FIELD type now comes from %frag-record-for-acc rather than being
   hardcoded to the f32 record, so a double tile is a tile of fp64 fragments.

   Endeavour 165 (BUG 058): the divisibility guard delegates to %register-tile-dims-must-divide,
   which the LET-bound path checks too, at the element's own fragment geometry."
  (let ((fmn (%acc-frag-mn elem)))
    (%register-tile-dims-must-divide m n nil (car fmn) (cdr fmn))
    (let ((name (%register-tile-type-name m n elem)))
      (unless (gethash name *crisp-structs*)
        (let ((nfrags (* (floor m (car fmn)) (floor n (cdr fmn)))))
          (register-struct-definition
           name
           (loop for i below nfrags
                 collect (list (intern (format nil "F~d" i) (find-package :crisp.compiler))
                               (%frag-record-for-acc elem)))
           :record)))
      (setf (gethash name *register-tile-dims*) (list m n elem))
      name)))

;; src/mma.lisp
(defun analyze-make-register-fragment (expr env context location)
  "P1 / F-SPV: (make-register-fragment M N INIT &key operand elem tally).  :spirv -> a filled coop
   matrix; else the NVIDIA %construct-struct record.  Endeavor 142: :operand (a|b|acc, default
   acc) picks the coop-matrix Use + shape so an A/B operand tile mints fragments matching
   load-fragment-a/b.

   Endeavor 144: each fragment is tallied against the current kernel — as coop-matrix BYTES on
   SPV (Phase 4's GRF model) and as 32-bit REGISTERS on PTX (Phase 3's occupancy model).  Both
   skip when the form carries :tally nil, which marks fill-tile's per-fragment set!s: those
   RE-INITIALIZE fragments the tile already owns and allocate nothing.

   Endeavour 155: :elem carries the ELEMENT TYPE down from the register tile that generated this
   fragment, and reaches the coop-matrix component type and the GRF byte tally.  It defaults to
   FLOAT — exactly what every caller got before, since the type used to be discarded at
   make-register-tile and bf16 tiles silently produced float32 matrices.  The PTX branch is
   UNCHANGED: its fragment records are tf32/f32 by construction and endeavour 155 does not touch
   the NVIDIA path."
  (destructuring-bind (m n init &rest kwargs) (cdr expr)
    (let* ((operand (getf kwargs :operand :acc))
           (tally-p (getf kwargs :tally t))
           (elem    (getf kwargs :elem 'float))
           (use (ecase operand (:a 0) (:b 1) (:acc 2))))
      (if (eq *target-backend* :spirv)
          (multiple-value-bind (sm sn sk) (%spv-mma-shape elem)   ; 155 Phase C
            (let ((fr (ecase operand (:a sm) (:b sk) (:acc sm)))
                  (fc (ecase operand (:a sk) (:b sn) (:acc sn))))
              (when tally-p (%spv-note-register-fragment fr fc context location elem))
              (make-semantic-coop-op
               :type (list 'coop-matrix (%elem-coop-type elem) fr fc use) :kind :fill
               :value-node (analyze-expression init env context (append location '(1)))
               :rows fr :cols fc :use use :layout 0 :source-location location)))
          (progn
            ;; Endeavour 165 (2b-ii): the accepted geometry is the ELEMENT TYPE's own -- 16x8
            ;; for f32/tf32/16-bit-accumulate, 8x8 for fp64.  It was a flat 16x8 literal, which
            ;; refused every fp64 fragment before it could be built.
            (let ((want (%acc-frag-mn elem)))
              (unless (or (and (eql m (car want)) (eql n (cdr want)))
                          (member operand '(:a :b)))
                (error 'crisp-compiler-error
                       :message (format nil "make-register-fragment: ~a accumulator fragments are ~ax~a on this target (got ~a x ~a)." elem (car want) (cdr want) m n))))
            ;; PTX fragment register counts, matching the records minted below:
            ;; acc 16x8 f32 -> 4, A tf32 16x8 -> 4, B tf32 8x8 -> 2 (per lane, 32-bit each).
            ;; Endeavour 165 (2b-ii): an fp64 accumulator fragment is 2 doubles per lane = 4
            ;; 32-bit registers.  The SAME NUMBER as the f32 16x8 accumulator, but for a
            ;; different reason -- 2 values of 8 bytes rather than 4 of 4 -- so it is computed,
            ;; not inherited from the coincidence.
            (when tally-p
              (%ptx-note-register-demand
               (ecase operand
                 (:acc (let ((want (%acc-frag-mn elem)))
                         (/ (* (car want) (cdr want) (if (eql (%mma-elem-bits elem) 64) 2 1)) 32)))
                 (:a 4) (:b 2))
               context location))
            (analyze-expression
             (ecase operand
               (:acc (let* ((rec (%frag-record-for-acc elem))
                            (want (%acc-frag-mn elem))
                            (nvals (/ (* (car want) (cdr want)) 32)))
                       `(%construct-struct ,rec ,@(make-list nvals :initial-element init))))
               (:a   `(%construct-struct register-fragment-a-tf32-16x8 ,init ,init ,init ,init))
               (:b   `(%construct-struct register-fragment-b-tf32-8x8 ,init ,init)))
             env context location))))))

;; src/mma.lisp
(defun analyze-store-fragment (expr env context location)
  "P1 / F-SPV: (store-fragment FRAG DEST (TY TX)).  :spirv -> CooperativeMatrixStoreKHR
   (accumulator, row-major); else the NVIDIA per-lane writes."
  ;; Endeavour 165 (2b-ii): an optional 4th argument carries the ELEMENT TYPE, supplied by
  ;; the store-tile walks (which know it) and defaulting to FLOAT for a hand-written
  ;; store-fragment.  The alternative -- inferring it from the fragment's own type -- would mean
  ;; analyzing FRAG once to ask, then again inside the rewritten form, and analyzing a form twice
  ;; is not safe in general.
  (destructuring-bind (frag dest tile-id &optional (elem 'float)) (cdr expr)
    (let ((ty (first tile-id)) (tx (second tile-id)))
      (if (eq *target-backend* :spirv)
          ;; C(accumulator) = MxN; layout from the dest tensor's :contiguous-term.
          (multiple-value-bind (sm sn sk) (%spv-mma-shape)
            (declare (ignore sk))
            (let ((dnode (analyze-expression dest env context (append location '(2)))))
              (make-semantic-coop-op
               :type 'void :kind :store
               :value-node  (analyze-expression frag env context (append location '(1)))
               :tensor-node dnode
               :rows sm :cols sn :use 2 :layout (%coop-layout-of dnode)
               :ty (analyze-expression `(to-int ,ty) env context (append location '(3)))
               :tx (analyze-expression `(to-int ,tx) env context (append location '(4)))
               :source-location location)))
          (if (eql (%mma-elem-bits elem) 64)
              ;; fp64 m8n8k4 C/D, decoded from CuTe MMA_Traits<SM80_8x8x4_F64F64F64F64_TN>:
              ;; CLayout = Layout<Shape<Shape<_4,_8>,_2>, Stride<Stride<_16,_1>,_8>> gives
              ;; m = lane/4 and n = 2*(lane%4) + v for v in {0,1}.  Same column scheme as the
              ;; tf32 fragment below (two adjacent columns at 2*(lane%4)); it differs only in
              ;; having ONE row per lane instead of the g / g+8 pair, over a tile 8 rows tall.
              (analyze-expression
               `(let ((frag-val ,frag))
                  (let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (t2 (* 2 (rem lane 4))))
                      (let ((row (+ (* ,ty 8) g)) (col (+ (* ,tx 8) t2)))
                        (set! (~ ,dest row col)       (%extract-struct-member frag-val 0))
                        (set! (~ ,dest row (+ col 1)) (%extract-struct-member frag-val 1))))))
               env context location)
              (analyze-expression
               `(let ((frag-val ,frag))
                  (let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (t2 (* 2 (rem lane 4))))
                      (let ((row (+ (* ,ty 16) g)) (col (+ (* ,tx 8) t2)))
                        (set! (~ ,dest row col)             (%extract-struct-member frag-val 0))
                        (set! (~ ,dest row (+ col 1))       (%extract-struct-member frag-val 1))
                        (set! (~ ,dest (+ row 8) col)       (%extract-struct-member frag-val 2))
                        (set! (~ ,dest (+ row 8) (+ col 1)) (%extract-struct-member frag-val 3))))))
               env context location))))))

;; src/mma.lisp
(defun %emit-per-frag-store (dest tile-id entry)
  "Per-fragment expansion of (store-tile V DEST (BTY BTX)).

   Endeavour 155 Step 3: RUNTIME-ADDRESSED distributed store.

   139 step-4 made this a static per-warp switch, which is right at 2-3 warps and catastrophic at
   32.  Each arm stores to a DIFFERENT global address, so unlike the MMA walk -- whose arms became
   identical once operands were warp-sliced, and collapsed -- every arm survives:

       tile          instrs   MulAdd   stores
       32x64  nw=1     1001       16       16
       128x128 nw=8    2025       16      121
       256x256 nw=32   5168       16      481     <- 32 arms x 16 fragments

   481 static stores for 16 dynamic ones, and 5168 instructions against SYCL-TLA's 2219 for the
   same geometry.

   With the 2-D warp grid the address is REGULAR, so one arm suffices:

       mi = wm*mp + (l / np)      wm = wp / gn      (runtime)
       nj = wn*np + (l mod np)    wn = wp mod gn    (runtime)

   l/np and l mod np are compile-time per fragment; only wm and wn are runtime, and they are two
   scalar ops shared by every fragment.  The static path is kept for the no-grid case, where the
   arms are few and literal addresses are preferable."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) operand) (cdr entry)
    (declare (ignore operand))
    (destructuring-bind (fm . fn) (%frag-mn (%register-tile-elem-of (first entry)))
      (let* ((cl (find-package :crisp-language))
             (to-int-sym (intern "TO-INT" cl))
             (m-frags (floor m fm)) (n-frags (floor n fn))
             (bty (list to-int-sym (first tile-id)))
             (btx (list to-int-sym (second tile-id))))
        (flet ((one-frag (fv mi-form nj-form)
                 (list `(store-fragment ,fv ,dest
                                        ((+ (* ,bty ,m-frags) ,mi-form)
                                         (+ (* ,btx ,n-frags) ,nj-form))
                                        ,(%register-tile-elem-of (first entry))))))
          (let ((grid (and (> n-true 1) (%warp-grid-dims n-true m-frags n-frags))))
            (cond
              ((and grid (> n-true 1))
               (let* ((let-sym (intern "LET" cl))
                      (progn-sym (intern "PROGN" cl))
                      (minus-sym (intern "-" cl))
                      (plus-sym (intern "+" cl))
                      (times-sym (intern "*" cl))
                      (floor-sym (intern "FLOOR" cl))
                      (mod-sym (intern "MOD" cl))
                      (warp-id (intern "WARP-ID" cl))
                      (gm (car grid)) (gn (cdr grid))
                      (mp (max 1 (floor m-frags gm)))
                      (np (max 1 (floor n-frags gn)))
                      (per-warp (length syms))
                      (wp (gensym "WP")) (wm (gensym "WM")) (wn (gensym "WN")))
                 `(,let-sym ((,wp (,minus-sym (,to-int-sym (,warp-id)) ,first-true)))
                    ;; Integer division/remainder via / and - : kernels use / for integer
                    ;; division throughout, whereas FLOOR/MOD in crisp-language are not verified
                    ;; for this use.  Previously they fed only comparisons (which tolerate a wrong
                    ;; value by selecting an arm); here they compute a global ADDRESS, where a
                    ;; wrong value is an out-of-bounds write.
                    ;; ISOLATED BY TEST: crisp-language FLOOR/MOD here yield a value that is fine
                    ;; for a COMPARISON but wrong as an ADDRESS -- almost certainly a float.  The
                    ;; step-2b load switch feeds its selector to (< ...) and is therefore correct;
                    ;; this store feeds a global index and was not.  Integer / and - instead.
                    (,let-sym ((,wm (,(intern "/" cl) ,wp ,gn)))
                      (,let-sym ((,wn (,minus-sym ,wp (,times-sym ,wm ,gn))))
                      (,progn-sym
                        ,@(loop for l below per-warp
                                for fv = (nth l syms)
                                append (one-frag fv
                                                 `(,plus-sym (,times-sym ,wm ,mp) ,(floor l np))
                                                 `(,plus-sym (,times-sym ,wn ,np) ,(mod l np))))))))))
              ((> n-true 1)
               (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag))
              (t
               `(progn
                  ,@(loop for mi below m-frags append
                          (loop for nj below n-frags
                                for idx = (+ (* mi n-frags) nj)
                                append (one-frag (nth idx syms) mi nj))))))))))))

;; src/mma.lisp
(defun analyze-store-tile-mma (expr env context location)
  "store-tile overload: register-tile (mma.sync) OR wgmma-accumulator (Endeavor 140) OR delegate."
  (let* ((src-node (analyze-expression (second expr) env context (append location '(1))))
         (src-type (semantic-node-type src-node)))
    (cond
      ((%wgmma-acc-type-p src-type)
       (let ((n (second (gethash src-type *wgmma-acc-dims*))))
         (analyze-expression (%wgmma-store-rewrite (second expr) (third expr) (fourth expr) n)
                             env context location)))
      ((%register-tile-type-p src-type)
       (destructuring-bind (m n &optional (elem 'float)) (gethash src-type *register-tile-dims*)
         (let* ((tile    (second expr))
                (dest    (third expr))
                (tile-id (fourth expr))
                (to-int-sym (intern "TO-INT" (find-package :crisp-language)))
                (bty (list to-int-sym (first tile-id)))
                (btx (list to-int-sym (second tile-id)))
                (fmn (%acc-frag-mn elem))
                (m-frags (floor m (car fmn))) (n-frags (floor n (cdr fmn))))
           (analyze-expression
            `(let ((tv ,tile))
               (progn
                 ,@(loop for mi below m-frags
                         append (loop for nj below n-frags
                                      for idx = (+ (* mi n-frags) nj)
                                      collect `(store-fragment (%extract-struct-member tv ,idx)
                                                               ,dest
                                                               ((+ (* ,bty ,m-frags) ,mi)
                                                                (+ (* ,btx ,n-frags) ,nj))
                                                               ,elem)))))
            env context location))))
      (t
       (analyze-store-tile-expression expr env context location)))))


;;; ===================================================================
;;; Endeavour 165 step 2b-ii (cont) — the THIRD geometry function.
;;;
;;; %acc-frag-mn and %frag-mn were routed; %frag-mn-for-operand still answered a flat 16x8 for
;;; every operand and element type on the NVIDIA path, so the explode path built 16x8 fragments
;;; for a double tile and analyze-make-register-fragment correctly refused them:
;;;   "make-register-fragment: DOUBLE accumulator fragments are 8x8 on this target (got 16 x 8)."
;;; The refusal did its job -- this is what a loud guard buys over a silent one.
;;;
;;; OPERAND geometry is filled in here too rather than left at 16x8 for fp64.  A and B for
;;; m8n8k4 are 8x4 and 4x8 (CuTe ALayout/BLayout = SM80_8x4, 1 double per lane).  Operand tiles
;;; are not reachable for fp64 until step 3 wires load-fragment-a/-b, but a function that would
;;; answer 16x8 if asked is a trap left lying around, and this endeavour has already paid once
;;; for a geometry that was wrong in a place nobody was looking.
;;; ===================================================================

;; src/mma.lisp
(defun %frag-mn-for-operand (operand &optional elem)
  "Endeavor 142 — per-fragment (rows . cols) for a register-tile of :operand (a|b|acc).  From the
   active profile's mma-shape (sm sn sk): A = sm x sk (Use 0), B = sk x sn (Use 1),
   Acc = sm x sn (Use 2) — matching load-fragment-a/b and make-register-fragment.

   Endeavour 155: ELEM selects the shape, because K depends on the element width.

   Endeavour 165 (2b-ii): the NVIDIA branch stops answering a flat 16x8.  The accumulator defers
   to %acc-frag-mn, the single source of truth; fp64 operands take m8n8k4's own 8x4 / 4x8, from
   CuTe MMA_Traits<SM80_8x8x4_F64F64F64F64_TN> (ALayout = BLayout = SM80_8x4, one double per
   lane).  Non-fp64 operands keep 16x8 exactly as before."
  (if (eq *target-backend* :spirv)
      (multiple-value-bind (sm sn sk) (%spv-mma-shape elem)
        (ecase operand
          (:a   (cons sm sk))
          (:b   (cons sk sn))
          (:acc (cons sm sn))))
      (if (and elem (symbolp elem) (string= (symbol-name elem) "DOUBLE"))
          (ecase operand
            (:a   (cons 8 4))
            (:b   (cons 4 8))
            (:acc (%acc-frag-mn elem)))
          (ecase operand
            (:a   (cons 16 8))
            (:b   (cons 16 8))
            (:acc (%acc-frag-mn elem))))))


;;; ===================================================================
;;; Endeavour 165 step 3 — the fp64 MMA: operand loads + the m8n8k4 emitter.
;;;
;;; Step 2 made the register tile fp64-shaped.  This makes it MULTIPLY.
;;;
;;; LANE LAYOUTS ARE FROM CuTe, NOT FROM MEMORY.  MMA_Traits<SM80_8x8x4_F64F64F64F64_TN> gives
;;; ALayout = BLayout = SM80_8x4, i.e. A(M8,K4) at m = lane/4, k = lane%4 and B(N8,K4) at
;;; n = lane/4, k = lane%4, one double per lane.  The tf32 path already in this file reads B at
;;; rows tg and tg+4, column g = lane/4 -- the same family with K=8 instead of 4 -- so the two
;;; corroborate.  That is the only check available offline: NOTHING LOCAL CAN PROVE A LANE
;;; LAYOUT IS RIGHT.  A wrong one compiles, emits the right instruction, passes every mechanical
;;; check and computes garbage.  MMA_CORRECT on metal is the test, and this is the step that
;;; makes renting a pod worthwhile.
;;;
;;; THE INSTRUCTION NAME IS THE ONE VERIFIED SPELLING.  bin/llc.exe (LLVM 21.1.5, -mcpu=sm_90)
;;; lowers llvm.nvvm.mma.m8n8k4.row.col.f64 to a real mma.sync; the sm_90 f64 shapes
;;; (m16n8k4 / k8 / k16) assemble cleanly and emit an `.extern .func` CALL with NO diagnostic.
;;; So this name must never be checked by prefix -- 159 documented the same trap for the 16-bit
;;; spellings, where two plausible variants passed the verifier as unresolved external calls
;;; while still leaving an "mma.m16n8k16..." substring in the PTX.
;;;
;;; NOTE FOR THE SRC PATCH: %nvvm-frag-format REPLACES src/mma.lisp:203; %nvvm-frag-record
;;; REPLACES :216; register-mma-types REPLACES :230 (and supersedes the 2b-ii overlay copy);
;;; analyze-load-fragment-a REPLACES :552; analyze-load-fragment-b REPLACES :605;
;;; %emit-nvvm-mma-f64 is new; %emit-nvvm-mma REPLACES :821.
;;; ===================================================================

;; src/mma.lisp
(defun %nvvm-frag-format (llvm-elem-type)
  "Which MMA operand format a fragment field's LLVM type implies: :FP16, :BF16, :F64 or :TF32.

   Endeavour 159.  Kinds are read from LLVM at runtime rather than compared against a constant --
   the bindings carry +llvm-half-type-kind+ but no bfloat equivalent, and no llvm-c header is
   installed to take the value from.  Anything not otherwise recognised is the historical
   fp32-stored tf32 path.

   Endeavour 165 (step 3): :F64 joins them.  A double-typed field can only be an fp64 fragment --
   the tf32 path stores fp32 -- so the probe stays a pure function of the record's own LLVM type
   and no :elem has to be threaded down from the caller."
  (let ((k (llvm-get-type-kind llvm-elem-type)))
    (cond ((= k (llvm-get-type-kind (llvm-half-type)))   :fp16)
          ((= k (llvm-get-type-kind (llvm-bfloat-type))) :bf16)
          ((= k (llvm-get-type-kind (llvm-double-type))) :f64)
          (t :tf32))))

;; src/mma.lisp
(defun %nvvm-frag-record (operand elem)
  "The PTX fragment record name for OPERAND (:a or :b) at Crisp element type ELEM.

   Endeavour 159.  One place decides this, so analyze-load-fragment-a and -b cannot disagree
   about which record a given element type maps to.  A 32-bit (or unknown) element keeps the
   historical tf32 records.

   Endeavour 165 (step 3): fp64's m8n8k4 operands, A 8x4 and B 4x8, one double per lane each."
  (let ((bits (%mma-elem-bits elem))
        (name (and elem (symbolp elem) (symbol-name elem))))
    (cond
      ((eql bits 64)
       (ecase operand (:a 'register-fragment-a-f64-8x4) (:b 'register-fragment-b-f64-4x8)))
      ((eql bits 16)
       (if (string= name "BFLOAT16")
           (ecase operand (:a 'register-fragment-a-bf16-16x16) (:b 'register-fragment-b-bf16-16x8))
           (ecase operand (:a 'register-fragment-a-f16-16x16)  (:b 'register-fragment-b-f16-16x8))))
      (t
       (ecase operand (:a 'register-fragment-a-tf32-16x8) (:b 'register-fragment-b-tf32-8x8))))))

;; src/mma.lisp
(defun register-mma-types ()
  "Registers the MMA register-fragment record types.  Called from initialize-compiler
   AFTER register-builtins (initialize-compiler clrhash-es *crisp-structs* on every
   init, so a load-time registration would not survive).

   tf32 m16n8k8 register counts: A (16x8) -> 4 regs, B (8x8) -> 2 regs, C/D (16x8) -> 4
   regs.  tf32 is fp32-stored, so all fragment fields are float.

   Endeavour 159: the 16-bit m16n8k16 twins, fp16 and bf16.  A is 16x16 = 8 elements/lane, B is
   16x8 = 4, both ONE FIELD PER ELEMENT so the member count IS the element count that
   %map-elements-fragment-fields reads.  REGISTERS are half that at 16 bits (two elements per
   32-bit register) and are tracked separately by %ptx-note-register-demand.

   The ACCUMULATOR is deliberately NOT twinned: every 16-bit MMA here accumulates in fp32, so
   register-fragment-acc-f32-16x8 is reused unchanged -- the same reason %coop-elem-of does not
   route accumulators.

   Endeavor 144 Phase 0: also registers the BUILTIN hardware profiles, which must happen
   after initialize-compiler's clrhash of *hardware-profiles* — this is the first hook that
   runs there.  See register-builtin-hardware-profiles for the src-patch note."
  ;; Endeavour 165: the fp64 m8n8k4 family.  C/D is 8x8 = 64 elements over 32 lanes = 2
  ;; doubles per lane; A is 8x4 and B is 4x8 = 32 elements each = ONE double per lane.  These
  ;; match CUTLASS's own declarations for its single f64 tensor-op Mma (FragmentA/B =
  ;; Array<double,1>, FragmentC = Array<double,2>), which is a second source agreeing.
  ;; Fields are DOUBLE, not float: an fp64 MMA accumulates in fp64, unlike the 16-bit paths
  ;; which accumulate in fp32 and therefore reuse the f32 accumulator record.
  (register-struct-definition 'register-fragment-acc-f64-8x8
                              '((r0 double) (r1 double))
                              :record)
  (register-struct-definition 'register-fragment-a-f64-8x4
                              '((a0 double))
                              :record)
  (register-struct-definition 'register-fragment-b-f64-4x8
                              '((b0 double))
                              :record)
  (register-struct-definition 'register-fragment-acc-f32-16x8
                              '((r0 float) (r1 float) (r2 float) (r3 float))
                              :record)
  (register-struct-definition 'register-fragment-a-tf32-16x8
                              '((a0 float) (a1 float) (a2 float) (a3 float))
                              :record)
  (register-struct-definition 'register-fragment-b-tf32-8x8
                              '((b0 float) (b1 float))
                              :record)
  ;; Endeavour 159 — fp16 m16n8k16.
  (register-struct-definition 'register-fragment-a-f16-16x16
                              '((a0 half) (a1 half) (a2 half) (a3 half)
                                (a4 half) (a5 half) (a6 half) (a7 half))
                              :record)
  (register-struct-definition 'register-fragment-b-f16-16x8
                              '((b0 half) (b1 half) (b2 half) (b3 half))
                              :record)
  ;; Endeavour 159 — bf16 m16n8k16, same shape, different encoding.
  (register-struct-definition 'register-fragment-a-bf16-16x16
                              '((a0 bfloat16) (a1 bfloat16) (a2 bfloat16) (a3 bfloat16)
                                (a4 bfloat16) (a5 bfloat16) (a6 bfloat16) (a7 bfloat16))
                              :record)
  (register-struct-definition 'register-fragment-b-bf16-16x8
                              '((b0 bfloat16) (b1 bfloat16) (b2 bfloat16) (b3 bfloat16))
                              :record)
  (register-builtin-hardware-profiles))

;; src/mma.lisp
(defun analyze-load-fragment-a (expr env context location)
  "P2 / F-SPV: [155: component type derived from the operand, not hardcoded float]
    (load-fragment-a SRC (TY TK)).  :spirv -> CooperativeMatrixLoadKHR (A,
   16x8, row-major); else the NVIDIA per-lane read.

   Endeavour 159: the NVIDIA branch DISPATCHES ON THE OPERAND'S ELEMENT WIDTH, using the same
   %coop-elem-of the SPV branch already used.  A 16-bit operand reads the m16n8k16 A layout
   (8 elements/lane) instead of the m16n8k8 tf32 one (4 floats/lane); fp16 and bf16 share that
   layout exactly and differ only in which record they fill.

   PTX ISA mma.m16n8k16 A layout, 32 lanes, groupID = lane/4, tid = lane%4.  Each lane holds
   8 elements as 4 register pairs, and the PAIR ORDER IS LOAD-BEARING -- it is the order the
   intrinsic's 4 A operands are consumed in:
       Ra0 = (groupID,   2*tid), (groupID,   2*tid+1)
       Ra1 = (groupID+8, 2*tid), (groupID+8, 2*tid+1)
       Ra2 = (groupID,   2*tid+8), (groupID,   2*tid+9)
       Ra3 = (groupID+8, 2*tid+8), (groupID+8, 2*tid+9)
   Note the K stride is 16 (not 8) and each lane spans TWO adjacent columns."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((ty (first tile-id)) (tk (second tile-id)))
      (if (eq *target-backend* :spirv)
          (let ((tnode (analyze-expression src env context (append location '(1)))))
            (multiple-value-bind (sm sn sk) (%spv-mma-shape (%coop-elem-of tnode))
              (declare (ignore sn))
              (make-semantic-coop-op
               :type (list 'coop-matrix (%coop-elem-of tnode) sm sk 0) :kind :load
               :tensor-node tnode
               :rows sm :cols sk :use 0 :layout (%coop-layout-of tnode)
               :ty (analyze-expression `(to-int ,ty) env context (append location '(2)))
               :tx (analyze-expression `(to-int ,tk) env context (append location '(3)))
               :source-location location)))
          ;; ---- NVIDIA / PTX ----
          (let* ((probe (analyze-expression src env context (append location '(1))))
                 (elem  (%coop-elem-of probe))
                 (rec   (%nvvm-frag-record :a elem)))
            (if (eql (%mma-elem-bits elem) 64)
                ;; fp64 m8n8k4 A (8x4): m = lane/4, k = lane%4, ONE double per lane.
                ;; CuTe ALayout = SM80_8x4.  The tile coordinates scale by the fragment's own
                ;; extents -- 8 rows and 4 columns -- not by the tf32 path's 16 and 8.
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,ty 8) g)) (c (+ (* ,tk 4) tg)))
                        (%construct-struct ,rec (~ ,src r c)))))
                 env context location)
            (if (eql (%mma-elem-bits elem) 16)
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,ty 16) g)) (c (+ (* ,tk 16) (* tg 2))))
                        (%construct-struct ,rec
                          (~ ,src r c)             (~ ,src r (+ c 1))
                          (~ ,src (+ r 8) c)       (~ ,src (+ r 8) (+ c 1))
                          (~ ,src r (+ c 8))       (~ ,src r (+ c 9))
                          (~ ,src (+ r 8) (+ c 8)) (~ ,src (+ r 8) (+ c 9))))))
                 env context location)
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,ty 16) g)) (c (+ (* ,tk 8) tg)))
                        (%construct-struct ,rec
                          (~ ,src r c) (~ ,src (+ r 8) c) (~ ,src r (+ c 4)) (~ ,src (+ r 8) (+ c 4))))))
                 env context location))))))))

;; src/mma.lisp
(defun analyze-load-fragment-b (expr env context location)
  "P2 / F-SPV: [155: component type derived from the operand, not hardcoded float]
    (load-fragment-b SRC (TK TX)).  :spirv -> CooperativeMatrixLoadKHR (B,
   8x8, col-major); else the NVIDIA per-lane read.

   Endeavour 159: 16-bit dispatch, mirroring load-fragment-a.  PTX ISA mma.m16n8k16 B layout
   (16x8), 32 lanes, groupID = lane/4, tid = lane%4; each lane holds 4 elements as 2 pairs, and
   the pair order is the intrinsic's B operand order:
       Rb0 = (2*tid,   groupID), (2*tid+1, groupID)
       Rb1 = (2*tid+8, groupID), (2*tid+9, groupID)
   B is K-major here (K=16 rows, N=8 cols), so the ROW stride is what doubles, not the column."
  (destructuring-bind (src tile-id) (cdr expr)
    (let ((tk (first tile-id)) (tx (second tile-id)))
      (if (eq *target-backend* :spirv)
          (let ((tnode (analyze-expression src env context (append location '(1)))))
            (multiple-value-bind (sm sn sk) (%spv-mma-shape (%coop-elem-of tnode))
              (declare (ignore sm))
              (make-semantic-coop-op
               :type (list 'coop-matrix (%coop-elem-of tnode) sk sn 1) :kind :load
               :tensor-node tnode
               :rows sk :cols sn :use 1 :layout (%coop-layout-of tnode)
               :ty (analyze-expression `(to-int ,tk) env context (append location '(2)))
               :tx (analyze-expression `(to-int ,tx) env context (append location '(3)))
               :source-location location)))
          ;; ---- NVIDIA / PTX ----
          (let* ((probe (analyze-expression src env context (append location '(1))))
                 (elem  (%coop-elem-of probe))
                 (rec   (%nvvm-frag-record :b elem)))
            (if (eql (%mma-elem-bits elem) 64)
                ;; fp64 m8n8k4 B (4x8): k = lane%4, n = lane/4, ONE double per lane.
                ;; CuTe BLayout = SM80_8x4, the same layout as A with N in M's place.  Compare
                ;; the tf32 branch below, which reads rows tg and tg+4 at column g: same family,
                ;; but K=4 leaves exactly one element per lane instead of two.
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,tk 4) tg)) (c (+ (* ,tx 8) g)))
                        (%construct-struct ,rec (~ ,src r c)))))
                 env context location)
            (if (eql (%mma-elem-bits elem) 16)
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,tk 16) (* tg 2))) (c (+ (* ,tx 8) g)))
                        (%construct-struct ,rec
                          (~ ,src r c)       (~ ,src (+ r 1) c)
                          (~ ,src (+ r 8) c) (~ ,src (+ r 9) c)))))
                 env context location)
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (tg (rem lane 4)))
                      (let ((r (+ (* ,tk 8) tg)) (c (+ (* ,tx 8) g)))
                        (%construct-struct ,rec
                          (~ ,src r c) (~ ,src (+ r 4) c)))))
                 env context location))))))))

;; src/mma.lisp
(defun %emit-nvvm-mma-f64 (builder module a-val b-val c-val)
  "Emit the fp64 tensor-core MMA: llvm.nvvm.mma.m8n8k4.row.col.f64.

   Endeavour 165 step 3.  Operands are ONE double each and the accumulator is TWO, so unlike the
   tf32 and 16-bit paths there is no packing, no bitcast and no vector: doubles are passed as
   doubles.  That is the whole reason this is a separate function rather than another arm of
   %emit-nvvm-mma's operand-format cond -- it shares none of that machinery.

   THE NAME IS THE ONE VERIFIED SPELLING.  On bin/llc.exe (LLVM 21.1.5, -mcpu=sm_90) this lowers
   to `mma.sync.aligned.m8n8k4.row.col.f64.f64.f64.f64`, while the sm_90 f64 shapes
   (m16n8k4 / k8 / k16) assemble cleanly and emit an `.extern .func` CALL with no diagnostic at
   all.  A wrong spelling here is therefore SILENT, so this must never be checked by prefix --
   the same trap endeavour 159 documented for the 16-bit names."
  (let* ((f64 (llvm-double-type))
         (a0  (llvm-build-extract-value builder a-val 0 "fa0"))
         (b0  (llvm-build-extract-value builder b-val 0 "fb0"))
         (c-ops (loop for i below 2
                      collect (llvm-build-extract-value builder c-val i (format nil "fc~d" i))))
         (ret-ty (let ((elts (cffi:foreign-alloc 'llvm-type-ref :count 2)))
                   (dotimes (i 2) (setf (cffi:mem-aref elts 'llvm-type-ref i) f64))
                   (llvm-struct-type-in-context (llvm-get-module-context module) elts 2 nil)))
         (fn-ty (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 4)))
                  (dotimes (i 4) (setf (cffi:mem-aref arr 'llvm-type-ref i) f64))
                  (llvm-function-type ret-ty arr 4 nil)))
         (fn-name "llvm.nvvm.mma.m8n8k4.row.col.f64")
         (fn (let ((existing (llvm-get-named-function module fn-name)))
               (if (cffi:null-pointer-p existing) (llvm-add-function module fn-name fn-ty) existing)))
         (args (list* a0 b0 c-ops))
         (args-arr (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count 4)))
                     (loop for i from 0 for v in args
                           do (setf (cffi:mem-aref arr 'llvm-value-ref i) v))
                     arr))
         (call (llvm-build-call2 builder fn-ty fn args-arr 4 "mmad"))
         (acc-ty (crisp-type-to-llvm-type 'register-fragment-acc-f64-8x8 module))
         (result (let ((agg (llvm-get-undef acc-ty)))
                   (dotimes (i 2)
                     (setf agg (llvm-build-insert-value builder agg
                                (llvm-build-extract-value builder call i (format nil "fd~d" i))
                                i (format nil "facc~d" i))))
                   agg)))
    (values result nil)))

;; src/mma.lisp
(defun %emit-nvvm-mma (builder module a-val b-val c-val)
  "The NVIDIA sync MMA.  Endeavour 159: dispatches on the A fragment's ELEMENT TYPE, emitting
   the tf32 m16n8k8, fp16 m16n8k16, or bf16 m16n8k16 instruction.  Returns (values acc nil).

   DETECTION is by probing the LLVM type of A's field 0 rather than by threading an :elem down:
   the caller (generate-node-ir on semantic-mma-accumulate) passes only LLVM values, and the
   fragment record already carries the answer.  The probe extract is REUSED as a0, so it costs
   no dead instruction.

   THE THREE PATHS DIFFER IN OPERAND REPRESENTATION, and that is the trap on this rung:
     tf32  i32          -- each float bitcast to i32
     fp16  <2 x half>   -- pairs packed into a vector, handed over AS a vector
     bf16  i32          -- pairs packed into <2 x bfloat> and then BITCAST to i32
   All three were verified by compiling a standalone .ll through clang --target=nvptx64 and
   reading the emitted mnemonic.  Two plausible spellings (...f16.f32, ...bf16.f32) pass the
   LLVM verifier as UNRESOLVED EXTERNAL CALLS -- they emit no instruction while still leaving an
   'mma.m16n8k16...' substring in the PTX -- so nothing here may be checked by prefix.

   Fragment records declare ONE FIELD PER ELEMENT, so all pair-packing happens HERE and only
   here.  The pairing order follows the PTX ISA register order documented on
   analyze-load-fragment-a/-b; those must agree, and nothing local can prove they do --
   MMA_CORRECT on metal is what checks it.

   The ACCUMULATOR is f32 in every path here: a 16-bit MMA accumulates in fp32.  fp64 is the
   exception and accumulates in fp64, which is one more reason it lives in its own emitter."
  (let* ((f32 (llvm-float-type))
         (i32 (llvm-int32-type))
         (a0  (llvm-build-extract-value builder a-val 0 "a0"))
         (fmt (%nvvm-frag-format (llvm-type-of a0))))
    (if (eq fmt :f64)
        ;; Endeavour 165 step 3: fp64 shares none of the packing below -- one double per operand,
        ;; two for the accumulator -- so it is its own emitter rather than another arm here.
        (%emit-nvvm-mma-f64 builder module a-val b-val c-val)
    (if (eq fmt :tf32)
        ;; ---------------- tf32 m16n8k8 (unchanged) ----------------
        (let* ((a-ops (cons (llvm-build-bit-cast builder a0 i32 "a0i")
                            (loop for i from 1 below 4 collect
                                  (llvm-build-bit-cast builder (llvm-build-extract-value builder a-val i (format nil "a~d" i)) i32 (format nil "a~di" i)))))
               (b-ops (loop for i below 2 collect
                            (llvm-build-bit-cast builder (llvm-build-extract-value builder b-val i (format nil "b~d" i)) i32 (format nil "b~di" i))))
               (c-ops (loop for i below 4 collect (llvm-build-extract-value builder c-val i (format nil "c~d" i))))
               (ret-ty (let ((elts (cffi:foreign-alloc 'llvm-type-ref :count 4)))
                         (dotimes (i 4) (setf (cffi:mem-aref elts 'llvm-type-ref i) f32))
                         (llvm-struct-type-in-context (llvm-get-module-context module) elts 4 nil)))
               (fn-ty (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 10)))
                        (loop for i from 0 for ty in (list i32 i32 i32 i32 i32 i32 f32 f32 f32 f32)
                              do (setf (cffi:mem-aref arr 'llvm-type-ref i) ty))
                        (llvm-function-type ret-ty arr 10 nil)))
               (fn-name "llvm.nvvm.mma.m16n8k8.row.col.tf32")
               (fn (let ((existing (llvm-get-named-function module fn-name)))
                     (if (cffi:null-pointer-p existing) (llvm-add-function module fn-name fn-ty) existing)))
               (args (append a-ops b-ops c-ops))
               (args-arr (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count 10)))
                           (loop for i from 0 for v in args do (setf (cffi:mem-aref arr 'llvm-value-ref i) v))
                           arr))
               (call (llvm-build-call2 builder fn-ty fn args-arr 10 "mma"))
               (acc-ty (crisp-type-to-llvm-type 'register-fragment-acc-f32-16x8 module))
               (result (let ((agg (llvm-get-undef acc-ty)))
                         (dotimes (i 4)
                           (setf agg (llvm-build-insert-value builder agg
                                      (llvm-build-extract-value builder call i (format nil "d~d" i))
                                      i (format nil "acc~d" i))))
                         agg)))
          (values result nil))
        ;; ---------------- 16-bit m16n8k16 (fp16 / bf16) ----------------
        (let* ((bf16-p  (eq fmt :bf16))
               (elem-ty (if bf16-p (llvm-bfloat-type) (llvm-half-type)))
               (vec-ty  (llvm-vector-type elem-ty 2))
               ;; fp16 hands the vector straight to the intrinsic; bf16 must bitcast it to i32.
               (op-ty   (if bf16-p i32 vec-ty))
               (a-elems (cons a0 (loop for i from 1 below 8
                                       collect (llvm-build-extract-value builder a-val i (format nil "a~d" i)))))
               (b-elems (loop for i below 4
                              collect (llvm-build-extract-value builder b-val i (format nil "b~d" i))))
               (pack (lambda (lo hi name)
                       ;; lane 0 is the LOWER-numbered element -- the order the ISA tables list
                       ;; the pair in, and the order load-fragment-a/-b fills the fields in.
                       (let ((v (llvm-get-undef vec-ty)))
                         (setf v (llvm-build-insert-element builder v lo (llvm-const-int i32 0 nil)
                                                            (format nil "~a_0" name)))
                         (setf v (llvm-build-insert-element builder v hi (llvm-const-int i32 1 nil)
                                                            (format nil "~a_1" name)))
                         (if bf16-p
                             (llvm-build-bit-cast builder v i32 (format nil "~a_i" name))
                             v))))
               (a-ops (loop for i below 4
                            collect (funcall pack (nth (* 2 i) a-elems) (nth (1+ (* 2 i)) a-elems)
                                             (format nil "av~d" i))))
               (b-ops (loop for i below 2
                            collect (funcall pack (nth (* 2 i) b-elems) (nth (1+ (* 2 i)) b-elems)
                                             (format nil "bv~d" i))))
               (c-ops (loop for i below 4 collect (llvm-build-extract-value builder c-val i (format nil "c~d" i))))
               (ret-ty (let ((elts (cffi:foreign-alloc 'llvm-type-ref :count 4)))
                         (dotimes (i 4) (setf (cffi:mem-aref elts 'llvm-type-ref i) f32))
                         (llvm-struct-type-in-context (llvm-get-module-context module) elts 4 nil)))
               (fn-ty (let ((arr (cffi:foreign-alloc 'llvm-type-ref :count 10)))
                        (loop for i from 0 for ty in (list op-ty op-ty op-ty op-ty op-ty op-ty f32 f32 f32 f32)
                              do (setf (cffi:mem-aref arr 'llvm-type-ref i) ty))
                        (llvm-function-type ret-ty arr 10 nil)))
               (fn-name (if bf16-p
                            "llvm.nvvm.mma.m16n8k16.row.col.bf16"
                            "llvm.nvvm.mma.m16n8k16.row.col.f32.f32"))
               (fn (let ((existing (llvm-get-named-function module fn-name)))
                     (if (cffi:null-pointer-p existing) (llvm-add-function module fn-name fn-ty) existing)))
               (args (append a-ops b-ops c-ops))
               (args-arr (let ((arr (cffi:foreign-alloc 'llvm-value-ref :count 10)))
                           (loop for i from 0 for v in args do (setf (cffi:mem-aref arr 'llvm-value-ref i) v))
                           arr))
               (call (llvm-build-call2 builder fn-ty fn args-arr 10 "mma16"))
               (acc-ty (crisp-type-to-llvm-type 'register-fragment-acc-f32-16x8 module))
               (result (let ((agg (llvm-get-undef acc-ty)))
                         (dotimes (i 4)
                           (setf agg (llvm-build-insert-value builder agg
                                      (llvm-build-extract-value builder call i (format nil "d~d" i))
                                      i (format nil "acc~d" i))))
                         agg)))
          (values result nil))))))


;;; ===================================================================
;;; Endeavour 165 step 3 (cont) — mma-accumulate's RESULT TYPE follows its C operand.
;;;
;;; analyze-mma-accumulate typed its node as register-fragment-acc-f32-16x8 outright, so an fp64
;;; accumulate reported an f32 accumulator and the walk refused it:
;;;   "Type mismatch! Expected REGISTER-FRAGMENT-ACC-F64-8X8 but inferred
;;;    REGISTER-FRAGMENT-ACC-F32-16X8."
;;; Another loud refusal finding a hardcode, which is the pattern this endeavour keeps repeating.
;;;
;;; The fix is not "add an fp64 case" but to state the actual rule: an MMA accumulate returns an
;;; accumulator OF THE SAME TYPE AS ITS C OPERAND.  That was always true; it was merely
;;; unexpressible while only one accumulator record existed.  Written that way it needs no
;;; further edit when a third accumulator type appears.
;;; ===================================================================

;; src/mma.lisp
(defun analyze-mma-accumulate (expr env context location)
  "P2 / F-SPV: (mma-accumulate C A B).  Node typed as the accumulator fragment — a coop matrix on
   :spirv, else the SAME RECORD AS C.  Codegen forks in generate-node-ir.

   Endeavour 165 (step 3): the NVIDIA type was hardcoded to the fp32 record, which made an fp64
   accumulate mistype itself.  Deriving it from C states the real rule and covers any accumulator
   record, present or future.  The fallback keeps the historical answer when C's type cannot be
   resolved to an accumulator record."
  (destructuring-bind (c-arg a-arg b-arg) (cdr expr)
    (let* ((c-node (analyze-expression c-arg env context location))
           (c-type (get-single-value-type c-node)))
      (make-semantic-mma-accumulate
       :type (if (eq *target-backend* :spirv)
                 (multiple-value-bind (sm sn sk) (%spv-mma-shape)
                   (declare (ignore sk)) (list 'coop-matrix 'float sm sn 2))
                 (if (and c-type (symbolp c-type)
                          (search "REGISTER-FRAGMENT-ACC-" (symbol-name c-type)))
                     c-type
                     'register-fragment-acc-f32-16x8))
       :c-node c-node
       :a-node (analyze-expression a-arg env context location)
       :b-node (analyze-expression b-arg env context location)
       :source-location location))))


;;; ===================================================================
;;; Endeavour 165 step 3 (cont) — an ADJOINT is never narrower than what it differentiates.
;;;
;;; %mma-ad-adj-init minted every register-tile adjoint at FLOAT, and said so:
;;;   "Element type is FLOAT in both register cases: fragments are fp32."
;;; That was true of every fragment in the tree when it was written.  fp64 fragments make
;;; it false, and the failure was loud -- an fp64 forward produced
;;;   (C-TILE_ADJ (MAKE-REGISTER-TILE FLOAT (8 8) 0.0))
;;; sitting next to correctly-typed (A_ADJ (AS DOUBLE 0.0)) scalars, and the BUG 058
;;; refusal rejected it because an 8x8 FLOAT tile asks for 16x8 fragments.
;;;
;;; FOUND BY READING THE EMITTED AST, not by reasoning.  An earlier attempt patched
;;; %mma-via-tile-backward on the theory that the VJP minted it; the debug log showed that
;;; function is never even reached for this kernel.  --log-level=debug prints the assembled
;;; backward AST for exactly this purpose.
;;;
;;; THE FIX IS THE INVARIANT, NOT A CASE.  An adjoint is allocated at the WIDER of the
;;; forward element type and FLOAT: 16-bit promotes to float (deliberate -- 163 path (a)
;;; ships 16-bit weights with 32-bit gradients), float stays float, double stays double
;;; because float would silently halve a gradient. Every pre-165 kernel is byte-identical.
;;;
;;; NOTE FOR THE SRC PATCH: %ad-adj-elem and %ad-adj-zero are new (src/autodiff.lisp);
;;; %mma-ad-adj-init REPLACES src/autodiff.lisp:4379.
;;; ===================================================================

;; src/autodiff.lisp
(defun %ad-adj-elem (forward-elem cl-pkg)
  "The element type for an adjoint of a value whose forward element type is FORWARD-ELEM:
   the WIDER of FORWARD-ELEM and FLOAT.

   Endeavour 165.  half / bfloat16 promote to FLOAT -- deliberate, and endeavour 163 path (a)
   depends on it (16-bit weights, 32-bit gradients).  DOUBLE stays DOUBLE, because FLOAT there
   would be a downgrade that silently halves the precision of a gradient.  Anything unrecognised
   keeps FLOAT, the pre-165 answer."
  (if (and forward-elem (symbolp forward-elem)
           (string= (symbol-name forward-elem) "DOUBLE"))
      (intern "DOUBLE" cl-pkg)
      (intern "FLOAT" cl-pkg)))

(defun %ad-adj-zero (forward-elem cl-pkg)
  "The zero literal matching %ad-adj-elem's answer.  A bare 0.0 reads as FLOAT and will not
   match a double fragment field; `d` is Crisp's double literal suffix (docs/ideal_001.md)."
  (if (and forward-elem (symbolp forward-elem)
           (string= (symbol-name forward-elem) "DOUBLE"))
      (intern "0.0D" cl-pkg)
      0.0))

;; src/autodiff.lisp
(defun %mma-ad-adj-init (init-form)
  "Endeavor 145 P3b: the adjoint allocator paired with a forward tile binding.

   Scratch tiles keep the existing behaviour (%promote-scratch-init-for-ad, which also
   promotes e.g. ulong -> double).

   Endeavor 146 Gap 4: a register tile's adjoint depends on WHICH ROLE the tile plays.

     ACCUMULATOR  (no :operand)  -> a same-shaped register tile zeroed to 0.0.
        The C adjoint is filled by %load-register-tile-acc from C_GRAD and then staged
        to SLM by the VJP itself, so registers are right for it.

     OPERAND      (:operand :a/:b) -> a same-shaped SCRATCH MATRIX.
        EVERY consumer of an operand adjoint indexes it as memory: the scalar lowering
        writes it with workgroup-stride + ~, the MMA fast path uses it as a store-tile
        DESTINATION, and %load-tile-at-bwd reads it element-wise to scatter into the
        global gradient.  A register tile cannot be written element-wise at all —
        %explode-register-tiles has replaced the whole-tile symbol with per-lane
        fragment vars by then, so `(~ TILE m k)` has no TILE to resolve.  This is not
        an AD-specific fact: the same write fails in a forward-only kernel.

   145 never hit this because its specs staged operands through make-scratch-matrix +
   load-tile-at, so operand adjoints were ALREADY scratch.  142 Phase A introduced
   register-resident operands via the load-tile overload, and this allocator had never
   learned about them.

   NOT a new derivative: dA = dC.B^T and dB = A^T.dC are unchanged and both lowerings
   already computed them correctly.  This decides only WHERE the result is allocated.

   Element type: NEVER NARROWER THAN THE VALUE IT DIFFERENTIATES, and never narrower than
   FLOAT.  Endeavour 165 replaced a hardcoded FLOAT here, whose stated reason -- that fragments
   are fp32 -- stopped being true when fp64 fragments arrived.  The rule is now the wider of the
   forward element type and FLOAT:

     half / bfloat16 -> FLOAT   a PROMOTION, and deliberate: endeavour 163 path (a) ships
                                16-bit weights with 32-bit gradients.  Unchanged.
     float           -> FLOAT   unchanged.
     double          -> DOUBLE  FLOAT would be a DOWNGRADE, silently halving the precision of
                                a gradient in the one endeavour that exists for precision.

   Stated that way it needs no further edit for a future element type, and every pre-165
   kernel emits byte-for-byte what it did."
  (cond
    ((and (consp init-form) (symbolp (car init-form))
          (string-equal (symbol-name (car init-form)) "MAKE-REGISTER-TILE"))
     (let ((cl-pkg (find-package :crisp-language)))
       (if (or (%mma-ad-register-operand-tile-p init-form)
               ;; Endeavour 163: an accumulator whose shape exceeds the per-thread register
               ;; budget gets an SLM adjoint too.  The FORWARD keeps its accumulator in
               ;; registers because that is where the speed is; the backward has no such need --
               ;; the VJP stages dC into SLM immediately either way.  A wgmma accumulator is the
               ;; case that forced this: it is WARPGROUP-wide, so canonicalising it to a
               ;; per-warp sync-MMA register tile at the SAME shape asks for 512 registers.
               (not (%mma-ad-accumulator-fits-registers-p (third init-form))))
           (list (intern "MAKE-SCRATCH-MATRIX" cl-pkg)
                 (%ad-adj-elem (second init-form) cl-pkg)
                 (third init-form))
           (list (intern "MAKE-REGISTER-TILE" cl-pkg)
                 (%ad-adj-elem (second init-form) cl-pkg)
                 (third init-form)
                 (%ad-adj-zero (second init-form) cl-pkg)))))
    ;; Endeavor 146: RING constructors pass through UNCHANGED.
    ;;
    ;; %promote-scratch-init-for-ad opens with %scratch-tensor-canonical-spec, which knows
    ;; only the four scratch TILE forms; handed a ring it yields the stub type `(TENSOR FLOAT)`
    ;; and the caller dies with `Invalid incomplete type specifier`.  A ring adjoint needs no
    ;; promotion in any case: it is a ring of the SAME shape, and these are float already.
    ;;
    ;; This was first patched locally inside %ad-ensure-ring-adj-bindings, which fixed the
    ;; top-level-ring path and left this one — %augment-scratch-adj-bindings reaches the same
    ;; allocator for a ring bound in a NESTED let, which is 142/14's shape.  Fixed at the
    ;; allocator instead, so both paths are covered by one rule.
    ((and (consp init-form) (symbolp (car init-form))
          (member (symbol-name (car init-form))
                  '("MAKE-SCRATCH-VECTOR-RING" "MAKE-SCRATCH-MATRIX-RING"
                    "MAKE-SCRATCH-TENSOR-RING" "MAKE-REGISTER-TILE-RING")
                  :test #'string=))
     init-form)
    (t (%promote-scratch-init-for-ad init-form))))


;;; ===================================================================
;;; Endeavour 165 — the fp64 MMA BACKWARD, part 2: the SCALAR VJP lowering.
;;;
;;; With the adjoint tile now DOUBLE, the scalar lowering still staged it through
;;; `(make-scratch-matrix FLOAT (mt nt))` and accumulated into a `0.0` float local, so:
;;;   Type mismatch! Expected FLOAT but inferred DOUBLE.
;;; That is BUG 057's family -- an element-type mismatch between a tile and the matrix it stages
;;; through.  There it wrote 4-byte floats into a 2-byte tile; here it would truncate a double
;;; gradient to float, which is exactly the wrong silent behaviour in the one endeavour that
;;; exists FOR precision.
;;;
;;; THIS IS THE PATH THIS KERNEL ACTUALLY TAKES.  %mma-vjp-mma-admissible-p rejects the shape, so
;;; the MMA lowering is not used -- which is why an earlier attempt to patch
;;; %mma-via-tile-backward changed nothing: --log-level=debug showed that function is never
;;; reached here.  Reading the emitted backward AST found in one step what reasoning about the
;;; call graph had got wrong twice.
;;;
;;; ACC-ELEM IS OPTIONAL AND NIL IS THE OLD BEHAVIOUR, so every non-fp64 kernel emits what it did
;;; before.  It is threaded from `(fourth c-dims)` at the call site -- the same dims-map lookup
;;; the MMA lowering already performs -- rather than re-derived.
;;;
;;; NOTE FOR THE SRC PATCH: %mma-vjp-scalar-lowering REPLACES src/autodiff.lisp:4623;
;;; %vjp-mma-accumulate-via-tile REPLACES src/autodiff.lisp:5484.
;;; ===================================================================

;; src/autodiff.lisp
(defun %mma-vjp-scalar-lowering (mt nt kt c-adj a-op b-op a-adj b-adj
                                 a-src aoy aox b-src boy box pkg
                                 &optional a-grad b-grad acc-elem)
  "The shape-agnostic scalar backward for a tile multiply.  Emitted as ordinary Crisp source,
   so it lowers through the normal path on either backend and at ANY tile shape.

   dC is materialised from the register accumulator into SLM once, then two collective loops
   accumulate into the operand adjoints.  Index arithmetic is coerced with to-int because a
   staging origin can be a ULONG extent expression while the collective's loop vars are INT."
  (declare (ignore a-op b-op))
  (let* ((cl (find-package :crisp-language))
         (let* (intern "LET" cl))      (msm  (intern "MAKE-SCRATCH-MATRIX" cl))
         ;; Endeavour 165: the dC staging matrix and the loop accumulator follow the
         ;; ACCUMULATOR's element type, not a hardcoded FLOAT.  ACC-ELEM nil reproduces the
         ;; previous emission byte-for-byte, so every pre-165 kernel is unaffected; only a
         ;; DOUBLE accumulator changes anything, and there FLOAT would truncate the gradient.
         (flt  (%ad-adj-elem acc-elem cl))
         (fzero (%ad-adj-zero acc-elem cl))
         (st   (intern "STORE-TILE" cl))
         (sync (intern "SYNC-WORKGROUP" cl))
         (ws   (intern "WORKGROUP-STRIDE" cl))  (dt (intern "DOTIMES" cl))
         (aref (intern "~" cl))        (set! (intern "SET!" cl))
         (plus (intern "+" cl))        (mul  (intern "*" cl))
         (ti   (intern "TO-INT" cl))
         ;; Endeavour 164: dC is staged into SLM here so it can be an MMA operand.  But since
         ;; 163 Phase 12 an accumulator that does NOT fit the register budget already HAS an SLM
         ;; adjoint — so for those, this staging buffer is a byte-for-byte duplicate of c-adj and
         ;; the store below copies SLM to SLM for nothing.  Measured on 154/03: two such copies,
         ;; 65536 B each, 131072 B of the backward's 458752.  Alias instead of copying.
         ;;
         ;; Safe because dc is READ-ONLY in the two loops below (`(~ dc m n)`); nothing writes it,
         ;; so sharing storage with c-adj cannot clobber anything.  And it asks the SAME predicate
         ;; %mma-ad-adj-init used to choose the adjoint's representation, so the two decisions
         ;; cannot drift apart -- the failure mode 146 documented when they did.
         (dc-aliases-c-adj (and (symbolp c-adj)
                                (not (%mma-ad-accumulator-fits-registers-p (list mt nt)))))
         (dc   (if dc-aliases-c-adj
                   c-adj
                   (intern (format nil "~A_VJPDC" (symbol-name c-adj)) pkg)))
         (aadd (intern "ATOMIC-ADD!" cl))  (letf (intern "LET" cl))
         (acc  (intern "%VJP_ACC" cl))
         (m (intern "%VJP_M" cl)) (n (intern "%VJP_N" cl)) (k (intern "%VJP_K" cl)))
    (flet ((ix (base off) (list plus (list ti base) (list ti off))))
      (list let* (if dc-aliases-c-adj nil (list (list dc (list msm flt (list mt nt)))))
            (if dc-aliases-c-adj (list sync) (list st c-adj dc (list 0 0)))
            (list sync)
            ;; dA[m,k] += sum_n dC[m,n] * B[k,n]
            ;; A-GRAD given => the operand is a REUSED buffer (a ring slot).  Accumulate the
            ;; stage's contribution in a LOCAL and scatter it straight into the global gradient
            ;; at this stage's origin, so nothing is ever left in the shared slot to be picked
            ;; up by another stage.  See BUG 044.
            (if a-grad
                (list ws a-adj (list m k)
                      (list letf (list (list acc fzero))
                            (list dt (list n nt)
                                  (list set! acc
                                        (list plus acc
                                              (list mul (list aref dc m n)
                                                    (list aref b-src (ix boy k) (ix box n))))))
                            (list aadd (list aref a-grad (ix aoy m) (ix aox k)) acc)))
                (list ws a-adj (list m k)
                      (list dt (list n nt)
                            (list set! (list aref a-adj m k)
                                  (list plus (list aref a-adj m k)
                                        (list mul (list aref dc m n)
                                              (list aref b-src (ix boy k) (ix box n)))))))) 
            ;; dB[k,n] += sum_m A[m,k] * dC[m,n]   (same reuse rule as dA above)
            (if b-grad
                (list ws b-adj (list k n)
                      (list letf (list (list acc fzero))
                            (list dt (list m mt)
                                  (list set! acc
                                        (list plus acc
                                              (list mul (list aref a-src (ix aoy m) (ix aox k))
                                                    (list aref dc m n)))))
                            (list aadd (list aref b-grad (ix boy k) (ix box n)) acc)))
                (list ws b-adj (list k n)
                      (list dt (list m mt)
                            (list set! (list aref b-adj k n)
                                  (list plus (list aref b-adj k n)
                                        (list mul (list aref a-src (ix aoy m) (ix aox k))
                                              (list aref dc m n)))))))
            (list sync)))))

;; src/autodiff.lisp
(defun %vjp-mma-accumulate-via-tile (form ctx)
  "VJP for (mma-accumulate-via-tile (M N K) C-TILE A B [(acc) BODY...]).

   Picks the LOWERING here, inside the VJP, which is the whole point of the registry: the walk
   never learns the MMA path shape requirements, so they cannot leak back out as a
   language-level contract.

   Endeavor 150: if BODY fuses an activation onto the accum binding with map-elements!, the
   chain rule needs dP = dC * f'(P).  A prefix re-stages the operands from their GLOBAL sources,
   recomputes P into a fresh register tile, and scales the C adjoint through the function's
   _GRAD twin before the existing backward runs.  The forward kernel is untouched."
  (destructuring-bind (shape c-tile a-op b-op &rest ignored) (cdr form)
    (declare (ignore ignored))
    (let* ((flat-anf  (getf ctx :flat-anf))
           (inputs    (getf ctx :inputs))
           (outputs   (getf ctx :outputs))
           (local-adj (getf ctx :local-adj))
           (kernel-pkg (getf ctx :kernel-pkg))
           (dims-map (%mma-ad-tile-dims-map flat-anf))
           (src-map  (%mma-ad-tile-source-map flat-anf))
           (ring-sites (%ad-ring-load-sites flat-anf))
           (c-dims   (assoc (%ad-tile-base c-tile) dims-map))
           (a-dims   (assoc (%ad-tile-base a-op) dims-map)))
      (when c-dims
        (multiple-value-bind (a-src aoy aox a-kind)
            (%mma-vjp-operand-ref a-op src-map dims-map inputs ring-sites)
          (multiple-value-bind (b-src boy box b-kind)
              (%mma-vjp-operand-ref b-op src-map dims-map inputs ring-sites)
            (when (and a-src b-src)
              (let* ((mt (second c-dims))
                     (nt (third c-dims))
                     (kt (if a-dims
                             (third a-dims)
                             (nth-value 2 (%spv-mma-shape))))
                     (pkg (or kernel-pkg (symbol-package (or (%ad-tile-base c-tile) c-tile))))
                     (ringp (or (eq a-kind :ring) (eq b-kind :ring)))
                     (c-adj (%tlc-bwd-adj-name c-tile inputs outputs local-adj kernel-pkg))
                     (a-adj (%tlc-bwd-adj-name a-op  inputs outputs local-adj kernel-pkg))
                     (b-adj (%tlc-bwd-adj-name b-op  inputs outputs local-adj kernel-pkg))
                     (core (if (and (not ringp) (%mma-vjp-mma-admissible-p mt nt kt))
                               (%mma-via-tile-backward form dims-map src-map inputs outputs
                                                       local-adj kernel-pkg)
                               (%mma-vjp-scalar-lowering mt nt kt c-adj a-op b-op a-adj b-adj
                                                         a-src aoy aox b-src boy box pkg
                                                         ;; BUG 044: a RING slot is reused across
                                                         ;; stages, so its adjoint cannot hold a
                                                         ;; per-stage value.  Hand the lowering
                                                         ;; the GLOBAL gradient and let it scatter
                                                         ;; each stage straight there.
                                                         (when (eq a-kind :ring)
                                                           (%tlc-bwd-adj-name a-src inputs outputs
                                                                              local-adj kernel-pkg))
                                                         (when (eq b-kind :ring)
                                                           (%tlc-bwd-adj-name b-src inputs outputs
                                                                              local-adj kernel-pkg))
                                                         ;; Endeavour 165: the accumulator's
                                                         ;; element type, so the lowering can
                                                         ;; stage a double adjoint without
                                                         ;; truncating it to float.  Same
                                                         ;; lookup the MMA lowering uses.
                                                         (fourth c-dims)))))
                (log:debug "VJP via-tile: Mt=~a Nt=~a Kt=~a a=~a(~a) b=~a(~a) ring=~a mma-path=~a"
                           mt nt kt a-op a-kind b-op b-kind ringp
                           (%mma-vjp-mma-admissible-p mt nt kt))
                (log:debug "165 acc-elem probe: c-tile=~a base=~a c-dims=~a fourth=~a"
                           c-tile (%ad-tile-base c-tile) c-dims (fourth c-dims))
                (multiple-value-bind (acc-sym fn-form) (%vjp-via-tile-body-map form)
                  (if (not acc-sym)
                      core
                      (let* ((cl    (find-package :crisp-language))
                             (grad  (%map-elements-grad-name fn-form pkg))
                             (base  (symbol-name (or (%ad-tile-base c-tile) c-tile)))
                             (p-sym  (intern (format nil "~a_PRIMAL" base) pkg))
                             (ap-sym (intern (format nil "~a_PRIMAL_A" base) pkg))
                             (bp-sym (intern (format nil "~a_PRIMAL_B" base) pkg))
                             (progn-s (intern "PROGN" cl))
                             (let-s   (intern "LET" cl))
                             (mrt-s   (intern "MAKE-REGISTER-TILE" cl))
                             (msm-s   (intern "MAKE-SCRATCH-MATRIX" cl))
                             (lta-s   (intern "LOAD-TILE-AT" cl))
                             (sync-s  (intern "SYNC-WORKGROUP" cl))
                             (flt-s   (intern "FLOAT" cl))
                             (via-s   (intern "MMA-ACCUMULATE-VIA-TILE" cl))
                             (vjp-s   (intern "%MAP-ELEMENTS-VJP!" cl))
                             (fn-s    (intern "FUNCTION" cl)))
                        (unless grad
                          (error 'crisp-compiler-error
                                 :message "map-elements! in a via-tile body: the fused function must be a #'NAME form for its gradient twin to be nameable."
                                 :source-location nil))
                        (log:debug "VJP via-tile: fused activation ~a -> dP = dC * ~a(P, dC); re-staging P from ~a / ~a"
                                   fn-form grad a-src b-src)
                        `(,progn-s
                          (,let-s ((,ap-sym (,msm-s ,flt-s (,mt ,kt)))
                                   (,bp-sym (,msm-s ,flt-s (,kt ,nt)))
                                   (,p-sym  (,mrt-s ,flt-s (,mt ,nt) 0.0)))
                                  (,lta-s ,a-src ,ap-sym (,aoy ,aox))
                                  (,lta-s ,b-src ,bp-sym (,boy ,box))
                                  (,sync-s)
                                  (,via-s ,shape ,p-sym ,ap-sym ,bp-sym)
                                  (,vjp-s ,c-adj ,p-sym (,fn-s ,grad)))
                          ,core))))))))))))


;;; ===================================================================
;;; Endeavour 165 — RE-REGISTER the via-tile VJP.  Without this the overlay above is DEAD CODE.
;;;
;;; src/autodiff.lisp:5578 does
;;;     (register-vjp "MMA-ACCUMULATE-VIA-TILE" #'%vjp-mma-accumulate-via-tile)
;;; which captures the FUNCTION OBJECT at load time.  A later `defun` of the same name makes a
;;; NEW function object; the registry still holds the old one, so late binding -- the whole
;;; premise of the overlay workflow -- does not reach it.
;;;
;;; This is a general trap, not a quirk of this function: ANY overlay override of a handler that
;;; was registered as #'NAME must re-register.  Diagnosed by putting two log:debug lines in the
;;; same function body and seeing only the pre-existing one fire -- the overlay's copy was never
;;; running.  Reasoning about the call graph had already produced two wrong theories by then.
;;;
;;; The symptom was subtle rather than loud: %mma-vjp-scalar-lowering IS overridden successfully
;;; (it is called by NAME, so late binding works), and it simply received no ACC-ELEM from the
;;; stale caller and defaulted to FLOAT -- i.e. half the patch was live and half was not.
;;; ===================================================================

;; src/autodiff.lisp
(register-vjp "MMA-ACCUMULATE-VIA-TILE" #'%vjp-mma-accumulate-via-tile)


;;; ===================================================================
;;; Endeavour 165 — the fp64 MMA backward, part 3: load-fragment-acc.
;;;
;;; analyze-load-fragment-acc is the exact INVERSE of analyze-store-fragment and carried the same
;;; two fp32 assumptions the store did before 2b-ii: it built register-fragment-acc-f32-16x8
;;; outright and used the 16x8 lane mapping (rows g and g+8 over a 16-tall tile, four elements per
;;; lane).  Against an fp64 adjoint that reads four floats where the fragment holds two doubles.
;;;
;;; Its own docstring says "a Load/Store pair always agrees".  They now agree BY CONSTRUCTION,
;;; both taking m = lane/4, n = 2*(lane%4) + v from CuTe's CLayout, rather than by two people
;;; writing the same thing twice.
;;;
;;; ELEM arrives as an optional 4th argument from %emit-per-frag-acc-load, mirroring how
;;; store-fragment receives it from %emit-per-frag-store.  Default FLOAT reproduces the old
;;; emission exactly.
;;;
;;; NOTE FOR THE SRC PATCH: analyze-load-fragment-acc REPLACES src/mma.lisp:2676;
;;; %emit-per-frag-acc-load REPLACES src/mma.lisp:2852 (supersedes the 2b-i overlay copy).
;;; ===================================================================

;; src/mma.lisp
(defun analyze-load-fragment-acc (expr env context location)
  "P2 (145): (load-fragment-acc SRC (TY TX)) reads a fp32 ACCUMULATOR fragment from the
   SRC matrix at logical tile (TY TX).  The exact inverse of store-fragment.

   :spirv -> CooperativeMatrixLoadKHR with Use=2 (accumulator), rows/cols from the active
   profile's shape and layout from the source tensor's :contiguous-term — mirroring
   analyze-store-fragment so a Load/Store pair always agrees.

   else   -> the NVIDIA per-lane read at the m16n8 fp32 accumulator layout.  With
   g = lane/4 and t = lane%4 this lane's four registers live at
     (g, 2t) (g, 2t+1) (g+8, 2t) (g+8, 2t+1)
   offset by the tile origin (TY*16, TX*8) — byte-for-byte the addresses store-fragment
   writes, only feeding %construct-struct instead of set!.

   The fragment is tallied against the kernel's register budget exactly as
   make-register-fragment tallies one: a LOADED accumulator occupies the same registers
   as a constructed one, and endeavor 144's fit-check must see both."
  (destructuring-bind (src tile-id &optional (elem 'float)) (cdr expr)
    (let ((ty (first tile-id)) (tx (second tile-id)))
      (if (eq *target-backend* :spirv)
          (multiple-value-bind (sm sn sk) (%spv-mma-shape)
            (declare (ignore sk))
            (let ((tnode (analyze-expression src env context (append location '(1)))))
              (%spv-note-register-fragment sm sn context location)
              (make-semantic-coop-op
               :type (list 'coop-matrix 'float sm sn 2) :kind :load
               :tensor-node tnode
               :rows sm :cols sn :use 2 :layout (%coop-layout-of tnode)
               :ty (analyze-expression `(to-int ,ty) env context (append location '(2)))
               :tx (analyze-expression `(to-int ,tx) env context (append location '(3)))
               :source-location location)))
          ;; Endeavour 165: fp64 reads TWO doubles at the m8n8k4 C/D layout, over a tile 8
          ;; rows tall rather than 16.  The SAME mapping as analyze-store-fragment's fp64
          ;; branch -- m = lane/4, n = 2*(lane%4) + v -- because this function's own docstring
          ;; requires a Load/Store pair to agree.  They now agree by construction: both read it
          ;; from CuTe's CLayout, instead of two people writing the same thing twice.
          (if (eql (%mma-elem-bits elem) 64)
              (progn
                ;; 2 doubles per lane = 4 32-bit registers: the same count as the f32 4x1
                ;; accumulator, arrived at differently.
                (%ptx-note-register-demand 4 context location)
                (analyze-expression
                 `(let ((lane (to-int (warp-lane))))
                    (let ((g (/ lane 4)) (t2 (* 2 (rem lane 4))))
                      (let ((row (+ (* ,ty 8) g)) (col (+ (* ,tx 8) t2)))
                        (%construct-struct register-fragment-acc-f64-8x8
                          (~ ,src row col)
                          (~ ,src row (+ col 1))))))
                 env context location))
          (progn
            (%ptx-note-register-demand 4 context location)
            (analyze-expression
             `(let ((lane (to-int (warp-lane))))
                (let ((g (/ lane 4)) (t2 (* 2 (rem lane 4))))
                  (let ((row (+ (* ,ty 16) g)) (col (+ (* ,tx 8) t2)))
                    (%construct-struct register-fragment-acc-f32-16x8
                      (~ ,src row col)
                      (~ ,src row (+ col 1))
                      (~ ,src (+ row 8) col)
                      (~ ,src (+ row 8) (+ col 1))))))
             env context location)))))))

;; src/mma.lisp
(defun %emit-per-frag-acc-load (src tile-id entry)
  "Endeavor 145 P3b: per-fragment expansion of
   (%load-register-tile-acc TILE SRC (TY TX)) — the exact mirror of %emit-per-frag-store,
   reading each accumulator fragment back out of SRC with P2's load-fragment-acc instead of
   writing it.  This is where the fragment element->lane MAPPING finally becomes
   load-bearing: the seeded gradient is non-zero, so a wrong mapping changes the answer
   (unlike the zero-seed of P2's own spec)."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0) operand) (cdr entry)
    (declare (ignore operand))
    (destructuring-bind (fm . fn) (%frag-mn (%register-tile-elem-of (first entry)))
      (let* ((to-int-sym (intern "TO-INT" (find-package :crisp-language)))
             (m-frags (floor m fm)) (n-frags (floor n fn))
             (bty (list to-int-sym (first tile-id)))
             (btx (list to-int-sym (second tile-id))))
        (flet ((one-frag (fv mi-form nj-form)
                 (list `(set! ,fv (load-fragment-acc ,src
                                                     ((+ (* ,bty ,m-frags) ,mi-form)
                                                      (+ (* ,btx ,n-frags) ,nj-form))
                                                     ,(%register-tile-elem-of (first entry)))))))
          (if (> n-true 1)
              (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag)
              `(progn
                 ,@(loop for mi below m-frags append
                         (loop for nj below n-frags
                               for idx = (+ (* mi n-frags) nj)
                               append (one-frag (nth idx syms) mi nj))))))))))


;;; ===================================================================
;;; Endeavour 165 step 4 — the h100 profile tells the truth about fp64, and the shape check
;;; understands TYPED entries.
;;;
;;; THE TRAP THIS CLOSES (finding 3 in the endeavour doc).  h100's :mma-shapes was
;;; ((16 8 8) (16 8 4) (16 8 16)) with no typed entry, so %mma-shape-for-elem fell to its width
;;; rule -- K x element-bits is a constant fragment footprint -- and resolved `double` to
;;; **(16 8 4)**.  That shape is real in the PTX ISA and is NOT an NVVM intrinsic in LLVM 21.1.5:
;;; it assembles cleanly and llc emits an `.extern .func` CALL with no diagnostic.  So a benchmark
;;; kernel run under --hardware-profile=h100 would have picked an unemittable shape SILENTLY.
;;; The width rule is not wrong; it simply is not the constraint that binds for fp64, where the
;;; hardware offers exactly one shape.
;;;
;;; %check-mma-shape also had to learn typed entries.  It tested raw `member ... :test #'equal`
;;; against the 3-lists, so a TYPED 4-list `(double 8 8 4)` would never have matched the user's
;;; `(8 8 4)` -- adding the entry alone would have made the profile correct and the kernel
;;; un-compilable.  The two edits only work together, which is why they are one block.
;;;
;;; NOTE FOR THE SRC PATCH: %check-mma-shape REPLACES src/mma.lisp:1161;
;;; register-builtin-hardware-profiles REPLACES src/mma.lisp:282.
;;; ===================================================================

;; src/mma.lisp
(defun %check-mma-shape (mma-shape location)
  "Validate the (M N K) MMA shape: an int triple, and — if a hardware profile is active —
   a member of its :mma-shapes (the vendor's supported shape, e.g. Intel (8 16 8)); with
   NO profile, require the tf32 NVIDIA default (16 8 8).

   Endeavour 165: a profile entry may be TYPED — `(ELEM M N K)`, a 4-list — so membership is
   tested against each entry's DIMS via %mma-shape-entry-dims rather than against the entry
   itself.  Untyped 3-lists compare exactly as before."
  (unless (and (listp mma-shape) (= (length mma-shape) 3) (every #'integerp mma-shape))
    (error 'crisp-compiler-error
           :message (format nil "mma-accumulate-via-tile: shape must be an (M N K) integer triple, got ~a." mma-shape)
           :source-location location))
  (let* ((profile (active-hardware-profile))
         (shapes  (and profile (getf profile :mma-shapes))))
    (if shapes
        (unless (find mma-shape shapes :test #'equal :key #'%mma-shape-entry-dims)
          (error 'crisp-compiler-error
                 :message (format nil "mma-accumulate-via-tile: shape ~a is not one of the active hardware profile's :mma-shapes ~a."
                                  mma-shape shapes)
                 :source-location location))
        (unless (equal mma-shape '(16 8 8))
          (error 'crisp-compiler-error
                 :message (format nil "mma-accumulate-via-tile: only tf32 (16 8 8) is supported without a hardware profile, got ~a." mma-shape)
                 :source-location location)))))


;; src/mma.lisp
(defun register-builtin-hardware-profiles ()
  "Endeavor 144 Phase 0 (D2): register Crisp's predefined hardware profiles.

   Called from register-mma-types, which initialize-compiler invokes AFTER it clrhash-es
   *hardware-profiles* — so builtins survive the clear and a same-named user profile still
   overrides them.

   NOTE FOR THE SRC PATCH: this belongs as its own call in initialize-compiler next to
   register-builtins."
  ;; Intel Arc B580 (Battlemage / Xe2).  Device-queried 2026-07-27.
  ;; :tile-visit-strip-width 4 — MEASURED: grouped visit order is worth +63% at 2048 here
  ;; (linear 17.1 -> 27.9 TFLOPS), and 4 beat 2/8/16 across both sizes tested.
  (register-hardware-profile
   'bmg
   '(:simd-width 16                        ; subGroupSizes reports BOTH 16 and 32
     :compute-units 20                     ; Xe-cores (5 slices x 4 subslices)
     :max-registers-per-thread (128 256)   ; GRF registers (32 B each) — selectable modes
     :max-total-threads-per-block 1024
     :max-work-group-dims (1024 1024 1024)
     :max-shared-memory-per-block 128KB
     :l2-cache-size 18MB
     :native-cache-line-size 64            ; Xe2 LSC line; not queryable
     :tile-visit-strip-width 4             ; measured; see the Phase 1 revision comment
     ;; 156 Step 2: BMG offers a second code-generation strategy.  :coop-matrix stays FIRST
     ;; and is therefore still the default, so no existing kernel changes behaviour -- a
     ;; kernel gets :xe-native only by asking for it with (mma-lowering :xe-native).
     :mma-lowerings (:coop-matrix :xe-native)
     :mma-shapes ((8 16 8) (8 16 16) (8 16 32)))) ; XMX tf32, bf16/fp16, int8
  ;; NVIDIA H100 PCIe (Hopper).  Device-queried 2026-07-28.
  ;; :compute-units 114 is the PCIe part (SXM is 132); this value OVERRIDES the device SM query
  ;; in the generated CUDA launch grid, so the variant distinction is load-bearing.
  ;; :max-shared-memory-per-block is the OPT-IN cap, not the 48KB default (chap2/chap3 exceed 48KB).
  ;; :mma-shapes MUST include (16 8 8) — chap0/1/1.5/2 all pass that tf32 shape.
  ;; NO :tile-visit-strip-width — MEASURED: grouped order is neutral-to-harmful here (chap2 worse
  ;; at every width; chap3_wgmma -8.3% at W=4 degrading monotonically to -14.4% at W=16), and no
  ;; cliff appears even at 4x L2.  Omitting the key means linear, which is what this part wants.
  (register-hardware-profile
   'h100
   '(:simd-width 32
     :compute-units 114
     :max-registers-per-cu 65536
     :max-registers-per-thread 255
     :max-total-threads-per-block 1024
     :max-work-group-dims (1024 1024 64)
     :max-shared-memory-per-block 227KB
     :l2-cache-size 50MB
     :native-cache-line-size 128
     ;; THE ELEMENT TYPE IS A KEYWORD, NOT AN INTERNED SYMBOL, AND THAT IS LOAD-BEARING.
     ;; Writing it as `double` interns CRISP.COMPILER::DOUBLE, and the ACTIVE PROFILE IS
     ;; SERIALISED INTO EVERY .metacrisp -- so a plain tf32 kernel compiled with
     ;; --hardware-profile=h100 emitted `CRISP.COMPILER:DOUBLE` into its metadata, and
     ;; crisp-hoist-cuda (which has no such package) died reading it with "Package
     ;; CRISP.COMPILER does not exist".  That broke the CUDA hoist for EVERY benchmark chapter,
     ;; including ones with no doubles anywhere.  A keyword reads in any package.
     ;; The readers are unaffected: %mma-shape-for-elem compares SYMBOL-NAME, and
     ;; (symbol-name :double) is "DOUBLE" either way.
     ;; Endeavour 165: a TYPED fp64 entry, and it is load-bearing rather than tidy.  Without
     ;; it %mma-shape-for-elem falls to the width rule -- K x element-bits is a constant
     ;; fragment footprint -- and resolves `double` to (16 8 4).  That shape exists in the PTX
     ;; ISA but is NOT an NVVM intrinsic in LLVM 21.1.5: it assembles and llc emits an
     ;; `.extern .func` CALL with no diagnostic.  fp64 has exactly ONE tensor-core shape,
     ;; m8n8k4, so it is stated outright instead of being inferred from a rule that has no way
     ;; to know that.
     :mma-shapes ((16 8 8) (16 8 4) (16 8 16) (:double 8 8 4)))))


;;; ===================================================================
;;; Endeavour 165 step 4 (cont) — the profile WRITER accepts typed :mma-shapes entries.
;;;
;;; %mma-shape-entry-dims and %mma-shape-entry-type have understood the typed (ELEM M N K) form
;;; since endeavour 161, and the docs describe it -- but %hp-validate-value never learned it, so
;;; putting one in a profile failed with "expects a non-empty list of (M N K) positive-integer
;;; triples".  Reader and writer disagreed, and the error message described the CHECK rather than
;;; the intent, which is why it read as a syntax mistake rather than a missing feature.
;;;
;;; fp64 is what forced it: the part offers exactly one tensor-core shape and the width rule has
;;; no way to infer that, so the profile has to state it, and stating it requires a typed entry.
;;;
;;; NOTE FOR THE SRC PATCH: %hp-mma-shape-entry-p is new (src/hardware-profile.lisp);
;;; %hp-validate-value REPLACES src/hardware-profile.lisp:107.
;;; ===================================================================

;; src/hardware-profile.lisp
(defun %hp-mma-shape-entry-p (x)
  "T if X is a legal :mma-shapes entry: an untyped (M N K) triple of positive integers, or a
   TYPED (ELEM M N K) 4-list whose first element is a symbol naming the element type.

   Endeavour 165.  Mirrors what %mma-shape-entry-dims / %mma-shape-entry-type already accept on
   the READ side; before this the writer side rejected the typed form the reader understood."
  (or (%hp-3-pos-ints-p x)
      (and (listp x) (= (length x) 4) (symbolp (first x)) (first x)
           (%hp-3-pos-ints-p (cdr x)))))

;; src/hardware-profile.lisp
(defun %hp-validate-value (profile-name key type raw)
  "Validate/normalize RAW for KEY of TYPE.  Signals a clear compile error on a
   malformed value; returns the normalized value (sizes in bytes, lists unquoted).

   Endeavor 144 (D4): :pos-int-or-modes accepts a positive integer OR a list of
   positive integers in STRICTLY ASCENDING order (selectable register-file modes;
   ascending so 'first' is the default mode and 'last' is the largest)."
  (ecase type
    (:pos-int
     (unless (and (integerp raw) (plusp raw))
       (error "def-hardware-profile ~a: key ~a expects a positive integer, got ~s."
              profile-name key raw))
     raw)
    (:pos-int-or-modes
     (let ((v (%hp-unquote raw)))
       (cond
         ((and (integerp v) (plusp v)) v)
         ((and (listp v) v (every (lambda (e) (and (integerp e) (plusp e))) v))
          (unless (apply #'< v)
            (error "def-hardware-profile ~a: key ~a expects selectable modes in strictly ascending order (the first is the default allocation, the last the largest), got ~s."
                   profile-name key raw))
          v)
         (t
          (error "def-hardware-profile ~a: key ~a expects a positive integer or a list of positive integers in ascending order (selectable modes, e.g. (128 256)), got ~s."
                 profile-name key raw)))))
    (:size
     (let ((bytes (%hp-parse-size raw)))
       (unless bytes
         (error "def-hardware-profile ~a: key ~a expects a byte count or size literal (e.g. 227KB, 50MB, 8GB), got ~s."
                profile-name key raw))
       bytes))
    (:dims3
     (let ((d (%hp-unquote raw)))
       (unless (%hp-3-pos-ints-p d)
         (error "def-hardware-profile ~a: key ~a expects a list of 3 positive integers, got ~s."
                profile-name key raw))
       d))
    (:mma-shapes
     (let ((shapes (%hp-unquote raw)))
       ;; Endeavour 165: an entry may be an untyped (M N K) triple OR a TYPED (ELEM M N K)
       ;; 4-list.  Endeavour 161 introduced typed entries for :wgmma-shapes and documented them,
       ;; but this validator was never taught about them -- so writing one in a profile failed
       ;; with "expects a non-empty list of (M N K) positive-integer triples", which describes
       ;; the CHECK rather than the intent.  fp64 forced the issue: it has exactly one
       ;; tensor-core shape and the width rule cannot infer that, so the profile has to say so.
       (unless (and (listp shapes) shapes (every #'%hp-mma-shape-entry-p shapes))
         (error "def-hardware-profile ~a: key ~a expects a non-empty list of (M N K) positive-integer triples, got ~s."
                profile-name key raw))
       shapes))
    ;; 156: an ordered list of code-generation strategies, most-preferred first.  Validated against
    ;; the names the COMPILER knows, so a typo is caught in the profile rather than surfacing later
    ;; as a kernel that mysteriously will not select its lowering.
    (:lowerings
     (let ((ls (%hp-unquote raw)))
       (unless (and (listp ls) ls (every #'keywordp ls))
         (error "def-hardware-profile ~a: key ~a expects a non-empty list of lowering keywords, got ~s."
                profile-name key raw))
       (let ((bad (remove-if (lambda (l) (member l *known-mma-lowerings*)) ls)))
         (when bad
           (error "def-hardware-profile ~a: key ~a names unknown lowering~p ~{~s~^, ~}.  Known lowerings: ~{~s~^, ~}."
                  profile-name key (length bad) bad *known-mma-lowerings*)))
       ls))))


;;; ===================================================================
;;; Endeavour 165 — fill-tile builds fragments at the TILE'S element type.
;;;
;;; %emit-per-frag-fill emitted `(make-register-fragment 16 8 ,val :tally nil)` -- a hardcoded
;;; geometry and NO :elem -- so the element type defaulted to FLOAT and the constructor picked
;;; register-fragment-acc-f32-16x8.  Handed a double init that is a type error, and it is how
;;; chapter 2 of the 64-bit ladder failed:
;;;   STRUCT-CTOR REGISTER-FRAGMENT-ACC-F32-16X8 member R0: arg-type=DOUBLE expected=FLOAT
;;;
;;; This is the SIXTH place in this endeavour where the 16x8-f32 fragment was assumed rather than
;;; asked for, and the fifth found by a loud refusal rather than by reading code.  It surfaced
;;; only now because fill-tile on a register tile is what matrix-multiply-tile-stride uses to
;;; RESET the accumulator per output tile (the BUG 036 fix) -- chapter 1 hand-rolls its loop and
;;; never resets, so it never reached here.
;;;
;;; The reset VALUE was already correct: a register tile resets to its DECLARED INIT, so the
;;; double `0.0d` arrived intact.  Only the fragment it was being poured into was wrong.
;;;
;;; NOTE FOR THE SRC PATCH: %emit-per-frag-fill REPLACES src/mma.lisp:1675.
;;; ===================================================================

;; src/mma.lisp
(defun %emit-per-frag-fill (entry val)
  "Per-fragment expansion of (fill-tile V VAL) for a register tile: reset every fragment
   of V to a fragment-of-VAL (matching make-register-tile's own 16x8 fragment init).

   Endeavor 144 Phase 4: tagged :tally nil.  These forms RE-INITIALIZE fragments the tile
   already owns — a set! of an existing register, not a new allocation — so counting them
   in the GRF demand model would inflate a tile's cost purely for having been filled."
  (destructuring-bind (m n syms &optional n-true first-true operand) (cdr entry)
    (declare (ignore m n n-true first-true operand))
    ;; fill just resets every fragment this warp holds — no logical index needed.
    `(progn
       ,@(loop for s in syms
               collect (let ((fmn (%frag-mn (%register-tile-elem-of (first entry)))))
                          `(set! ,s (make-register-fragment ,(car fmn) ,(cdr fmn) ,val
                                      :elem ,(%register-tile-elem-of (first entry)) :tally nil)))))))

