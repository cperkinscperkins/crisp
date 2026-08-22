;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; HOT-PATCH OVERLAY for CRISP.COMPILER
;;;; ---------------------------------------------------------------------------
;;;; Empty by design.  Endeavour 152's contents were migrated into src/ on 2026-08-19:
;;;;
;;;;   51 new definitions INSERTED after each target file's (in-package ...) form -- not at
;;;;      end of file, because a defvar appended below its users turns their LET bindings
;;;;      lexical and the dynamic value silently stops propagating.
;;;;   20 definitions REPLACED in place, the four generate-node-ir methods matched by
;;;;      SPECIALIZER rather than by name (codegen.lisp has 49 methods of that name).
;;;;    3 fdefinition WRAPPERS rewritten: each original was renamed <name>-base and the
;;;;      wrapper now calls it directly.  Those could not move as text -- the capture
;;;;      (fdefinition 'foo) only found the real original because this file loaded AFTER
;;;;      src; moved in beside it, the wrapper would have captured itself.
;;;;
;;;; INSTRUCTIONS (unchanged):
;;;; 1. Append new/fixed function definitions to the end of this file.
;;;; 2. Add a comment referencing the original file (e.g. ;; src/codegen.lisp)
;;;; 3. Do not modify the original file in src/ until cleanup time.

(in-package :crisp.compiler)


;;; ===================================================================
;;; ENDEAVOUR 154 — wgmma group pipelining.
;;;
;;; THE DEFECT.  %emit-one-wgmma emitted, for EVERY k8 slice:
;;;     wgmma.fence.sync.aligned
;;;     wgmma.mma_async ...
;;;     wgmma.commit_group.sync.aligned
;;;     wgmma.wait_group.sync.aligned 0
;;; and %emit-nvvm-wgmma called it once per slice.  A K-block of 32 is 4 slices, so the
;;; mainloop emitted 4 fences, 4 commit_groups and 4 wait_groups.  `wait_group 0` waits for
;;; ALL outstanding groups, so each async MMA was fully awaited before the next issued --
;;; the async in `mma_async` was completely defeated, and we paid a fence + commit + wait
;;; per k8 slice instead of per K-block.
;;;
;;; THE SHAPE IT SHOULD HAVE (and that CUTLASS uses): one fence, N mma_asyncs, one
;;; commit_group, one wait_group.  A fence is only required before the FIRST wgmma of a
;;; sequence (it orders prior non-wgmma writes to the accumulator registers against the
;;; warpgroup's async reads); back-to-back wgmmas within one group need none, and the
;;; hardware honours the accumulator RAW dependency between them in issue order.
;;;
;;; MEASURED, on an H100 NVL, by patching the emitted PTX and re-running -- interleaved
;;; arms, 3-4 reps each, clocks pinned, MMA_CORRECT at every size:
;;;     256  n64  4.788 -> 5.164 TFLOPS  (+7.9%)
;;;     512  n64  28.264 -> 31.191       (+10.4%)
;;;     1024 n128 109.314 -> 119.726     (+9.5%)
;;;     2048 n256 239.170 -> 249.560     (+4.3%)
;;;     4096 n256 258.888 -> 273.617     (+5.7%)
;;;
;;; NOTE FOR THE SRC PATCH: %emit-wgmma-mma-only is new and belongs next to %emit-one-wgmma
;;; in src/mma.lisp; %emit-nvvm-wgmma REPLACES the one at src/mma.lisp:1817.  %emit-one-wgmma
;;; itself is left in place, unmodified and now unused, so that anything reaching for it
;;; still gets the old self-contained behaviour rather than a link error.
;;;
;;; NOT DONE HERE: `wait_group N` with N >= 1, which is what lets one K-block's MMA overlap
;;; the NEXT block's.  That needs a `wait_group 0` before the epilogue reads D, so it is a
;;; change to the loop/epilogue structure rather than to this emitter.  Endeavour 154 item 3.
;;; ===================================================================

;; src/mma.lisp
(defun %emit-wgmma-mma-only (builder module d-val a-ptr b-ptr acc-type n swizzle-p kslice-off)
  "Emit ONE m64nNk8 wgmma.mma_async and nothing else -- no fence, no commit_group, no
   wait_group.  Those are GROUP-level operations and belong once around the whole k-slice
   sequence, not once per slice; see %emit-nvvm-wgmma.

   Otherwise identical to %emit-one-wgmma: N/2 accumulators in and out, two shared-memory
   descriptors, and KSLICE-OFF (kk*32 bytes) advancing the swizzle descriptor start address.
   Returns the new D record."
  (let* ((f32 (llvm-float-type)) (i64 (llvm-int64-type))
         (nacc (floor n 2))
         (descA (%wgmma-make-desc builder a-ptr swizzle-p kslice-off))
         (descB (%wgmma-make-desc builder b-ptr swizzle-p kslice-off))
         (c-ops (loop for i below nacc collect
                      (llvm-build-extract-value builder d-val i (format nil "wc~d" i))))
         (asm-str     (%wgmma-asm-string nacc n))
         (constraints (%wgmma-constraints nacc))
         (ret-ty      (%wgmma-struct-of-floats module nacc))
         (ptypes      (append (loop repeat nacc collect f32) (list i64 i64)))
         (args        (append c-ops (list descA descB)))
         (call        (%build-inline-asm-call builder ret-ty ptypes args asm-str constraints))
         (agg         (llvm-get-undef (crisp-type-to-llvm-type acc-type module))))
    (dotimes (i nacc)
      (setf agg (llvm-build-insert-value builder agg
                                         (llvm-build-extract-value builder call i (format nil "wo~d" i))
                                         i (format nil "wr~d" i))))
    agg))

;; src/mma.lisp
(defun %emit-nvvm-wgmma (builder module d-val a-ptr b-ptr acc-type n &optional swizzle-p (k 8))
  "Emit the wgmma accumulate as ONE GROUP.  NO-SWIZZLE (scatter): a proxy fence + barrier
   (generic->async proxy visibility) + ONE k8 wgmma.  128B-SWIZZLE (TMA): NO proxy fence (both
   async proxy) + K/8 k-slice wgmmas, D accumulating across them (scaleD=1), each with the start
   advanced kk*32 bytes.  Returns (values D nil).

   Endeavour 154: the wgmma.fence / commit_group / wait_group triple is emitted ONCE around the
   whole k-slice sequence rather than once per slice.  With one slice this is byte-identical to
   the previous behaviour; with four it removes 3 fences, 3 commit_groups and 3 `wait_group 0`s
   from the mainloop and lets the four MMAs actually pipeline.  See the block comment above for
   the measured effect."
  (let ((n-slices (if swizzle-p (max 1 (floor k 8)) 1)))
    (unless swizzle-p
      ;; scatter path: generic st.shared writes must be made visible to wgmma's async-proxy read.
      (%gen-nvvm-fence-proxy-async-shared builder)
      (%ptx-barrier builder module))
    ;; ONE fence before the first MMA of the group.
    (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.fence.sync.aligned;" "~{memory}")
    (let ((cur-d d-val))
      (dotimes (kk n-slices)
        (setf cur-d (%emit-wgmma-mma-only builder module cur-d a-ptr b-ptr acc-type n swizzle-p (* kk 32))))
      ;; ONE commit + wait after the last.
      (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.commit_group.sync.aligned;" "~{memory}")
      (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.wait_group.sync.aligned 0;" "~{memory}")
      (values cur-d nil))))


;;; ===================================================================
;;; ENDEAVOUR 154 item 3 — a wgmma accumulator can be stored at an ABSOLUTE origin.
;;;
;;; WHY.  %wgmma-store-rewrite computed its row base as `bty * 64`, where 64 is the wgmma
;;; instruction's fixed M.  That silently bakes in ONE WARPGROUP: with a second consumer
;;; warpgroup the row base is unchanged, so both warpgroups write the SAME 64 rows.  A
;;; cooperative 128x256 tile -- two warpgroups splitting M, sharing one B tile, which is the
;;; shape CUTLASS uses and the one endeavour 154's arithmetic-intensity argument points at --
;;; is therefore not expressible.  `store-tile-at` looked like the escape hatch but had no
;;; wgmma overload at all; it fell through to the cooperative element-loop path.
;;;
;;; WHAT THIS ADDS, AND WHAT IT DELIBERATELY DOES NOT.  It adds the OVERLOAD: a wgmma
;;; accumulator stored at an absolute (ROW COL) element origin.  The two-warpgroup kernel then
;;; writes its own row offsets explicitly --
;;;
;;;     (:consumer0 ... (store-tile-at D C ((* grid-y 128)        (* grid-x 256))))
;;;     (:consumer1 ... (store-tile-at D C ((+ (* grid-y 128) 64) (* grid-x 256))))
;;;
;;; -- which is checkable by a reader at the point of use.  It does NOT infer the warpgroup
;;; count from anything.  Inference was considered and rejected for now: deriving it from the
;;; tile-stride tile shape (M/64) is UNDER-DETERMINED, because a 128-row tile served by ONE
;;; warpgroup looping over two row halves is a legal kernel that the same rule would silently
;;; mis-address.  Sugar (a `:warpgroups` key, or a cooperative form that expands to both
;;; stores) can be added later once a real cooperative kernel exists and we know whether the
;;; explicit form is actually tedious.  Adding an explicit, correct spelling first costs
;;; nothing and forecloses nothing.
;;;
;;; The within-warpgroup lane mapping is UNCHANGED and needs no generalization: `wgw` is
;;; (rem (warp-id) 4), which for consumer warps 4-7 already yields 0-3.
;;;
;;; NOTE FOR THE SRC PATCH: %wgmma-store-rewrite-origin is new (src/mma.lisp, beside
;;; %wgmma-store-rewrite); %wgmma-store-rewrite REPLACES the one at src/mma.lisp:1832 and is
;;; now a thin caller of it; analyze-store-tile-at-mma is new; register-mma-analyzers REPLACES
;;; the one at src/mma.lisp:1626 with STORE-TILE-AT added to the table.
;;; ===================================================================

;; src/mma.lisp
(defun %wgmma-store-rewrite-origin (tile dest row-origin col-origin n)
  "Store the m64xN wgmma accumulator TILE into DEST with its top-left element at
   (ROW-ORIGIN COL-ORIGIN), both absolute element indices.

   Both origins are coerced with TO-INT.  The lane arithmetic below is INT throughout (wgw and
   rlo come from to-int of warp-id / warp-lane), so a ULONG origin expression -- which is what
   you get from any tile-stride grid binding, e.g. (* grid-y (to-ulong 128)) -- would otherwise
   fail to type-check with \"Cannot operate on ULONG and INT\".  The grid-index caller has always
   passed an INT for the same reason; this just makes the absolute spelling accept either.

   Lane mapping (= wgmma_ref.cu, unchanged): warp w within the warpgroup owns rows
   [16w, 16w+16); within a warp, lane -> row lane/4 and column pair (lane mod 4)*2; each n8
   group contributes the standard mma m16n8 C fragment at rows r0 and r0+8."
  (let* ((to-int (intern "TO-INT" (find-package :crisp-language)))
         (n8 (floor n 8)))
    `(let ((wgv ,tile))
       (let ((wgw (rem (,to-int (warp-id)) 4))
             (lane (,to-int (warp-lane))))
         (let ((rlo (/ lane 4)) (col (* (rem lane 4) 2)))
           (let ((r0 (+ (+ (,to-int ,row-origin) (* wgw 16)) rlo)))
             (let ((r8 (+ r0 8))
                   (c0 (+ (,to-int ,col-origin) col)))
               (progn
                 ,@(loop for j below n8
                         for base = (* j 4)
                         append (list
                                 `(set! (~ ,dest r0 (+ c0 ,(* 8 j)))         (%extract-struct-member wgv ,(+ base 0)))
                                 `(set! (~ ,dest r0 (+ (+ c0 ,(* 8 j)) 1))   (%extract-struct-member wgv ,(+ base 1)))
                                 `(set! (~ ,dest r8 (+ c0 ,(* 8 j)))         (%extract-struct-member wgv ,(+ base 2)))
                                 `(set! (~ ,dest r8 (+ (+ c0 ,(* 8 j)) 1))   (%extract-struct-member wgv ,(+ base 3)))))))))))))

;; src/mma.lisp
(defun %wgmma-store-rewrite (tile dest tile-id n)
  "Store the m64xN wgmma accumulator TILE to DEST at grid tile-id (BTY BTX).

   Endeavour 154: now a thin caller of %wgmma-store-rewrite-origin with the TILE-GRID origin
   (bty*64, btx*N).  Behaviour is unchanged -- deliberately, since this spelling addresses a
   tile by grid index and a grid index only identifies a 64-row tile when ONE warpgroup owns
   it.  Two cooperating warpgroups use store-tile-at with explicit origins instead."
  (let ((to-int (intern "TO-INT" (find-package :crisp-language))))
    (%wgmma-store-rewrite-origin
     tile dest
     `(* (,to-int ,(first tile-id)) 64)
     `(* (,to-int ,(second tile-id)) ,n)
     n)))

;; src/mma.lisp
(defun analyze-store-tile-at-mma (expr env context location)
  "store-tile-at overload: wgmma-accumulator at an absolute (ROW COL) origin, OR delegate to
   the ordinary cooperative store-tile-at path.

   Dispatches on the SOURCE TYPE before the generic path runs, exactly as analyze-store-tile-mma
   does -- which also keeps the wgmma store out of %warp-spec-check-block-only, whose
   workgroup-collective deadlock rationale does not apply to a warpgroup-private accumulator
   spill (and which store-tile already bypasses for the same reason)."
  (let* ((src-node (analyze-expression (second expr) env context (append location '(1))))
         (src-type (semantic-node-type src-node)))
    (if (%wgmma-acc-type-p src-type)
        (let ((n      (second (gethash src-type *wgmma-acc-dims*)))
              (origin (fourth expr)))
          (unless (and (listp origin) (= (length origin) 2))
            (error 'crisp-compiler-error
                   :message (format nil "store-tile-at: a wgmma accumulator needs a 2-D (ROW COL) element origin, got ~S.  The accumulator is a 64xN matrix; its origin is where its top-left element lands in the destination." origin)
                   :source-location location))
          (analyze-expression
           (%wgmma-store-rewrite-origin (second expr) (third expr)
                                        (first origin) (second origin) n)
           env context location))
        (analyze-store-tile-at-expression expr env context location))))

;; src/mma.lisp
(defun register-mma-analyzers ()
  "Registers the MMA + wgmma expression analyzers.
   Endeavor 150: adds MAP-ELEMENTS! and its backward twin %MAP-ELEMENTS-VJP!.
   Endeavour 154: adds STORE-TILE-AT, so a wgmma accumulator can be stored at an absolute
   origin (two cooperating consumer warpgroups); non-wgmma sources delegate unchanged."
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry (list (cons "MAKE-REGISTER-FRAGMENT" #'analyze-make-register-fragment)
                         (cons "STORE-FRAGMENT"          #'analyze-store-fragment)
                         (cons "LOAD-FRAGMENT-A"         #'analyze-load-fragment-a)
                         (cons "LOAD-FRAGMENT-B"         #'analyze-load-fragment-b)
                         (cons "LOAD-FRAGMENT-ACC"       #'analyze-load-fragment-acc)
                         (cons "MMA-ACCUMULATE"          #'analyze-mma-accumulate)
                         (cons "MAKE-REGISTER-TILE"      #'analyze-make-register-tile)
                         (cons "MMA-ACCUMULATE-VIA-TILE" #'analyze-mma-accumulate-via-tile)
                         (cons "MAP-ELEMENTS!"           #'analyze-map-elements)
                         (cons "%MAP-ELEMENTS-VJP!"      #'analyze-map-elements-vjp)
                         (cons "PREFETCH-TILE"           #'analyze-prefetch-tile)
                         (cons "INNER-DIMENSION"         #'analyze-inner-dimension)
                         (cons "OUTER-DIMENSIONS"        #'analyze-outer-dimensions-expression)
                         (cons "MAKE-WGMMA-ACCUMULATOR"    #'analyze-make-wgmma-accumulator)
                         (cons "WGMMA-ACCUMULATE"          #'analyze-wgmma-accumulate)
                         (cons "WGMMA-ACCUMULATE-VIA-TILE" #'analyze-wgmma-accumulate-via-tile)
                         (cons "STORE-TILE"              #'analyze-store-tile-mma)
                         (cons "STORE-TILE-AT"           #'analyze-store-tile-at-mma)
                         (cons "LET"                     #'analyze-let-with-tile-explosion)
                         (cons "LET*"                    #'analyze-let-with-tile-explosion)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) (cdr entry)))))))
