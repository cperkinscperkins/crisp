;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins
;;;;
;;;; (Empty — Endeavor 135's matrix-multiply-tile-stride / fill-tile / tile-ID
;;;;  grid-term fix graduated to src/analysis/control.lisp + src/mma.lisp.
;;;;  Append new in-progress definitions here.)

(in-package :crisp.compiler)

;;; ===========================================================================
;;; Endeavor 139 (Chapter 3) — STEP 4: multi-lap phase flipping for warp-spec
;;; producer/consumer rings.
;;; ===========================================================================
;;;
;;; A warp-spec ring slot is reused every RING-COUNT K-steps, and an mbarrier's
;;; try_wait.parity flips each lap.  138/04 side-stepped this by RE-INITing the
;;; barrier each step, but producer and consumer are separate warps here, so
;;; neither can re-init on the other's behalf.  Instead the compiler injects a
;;; per-ring visit counter and derives the parity at each await:
;;;
;;;     phase = initial_phase  XOR  ((visit / ring_count) & 1)
;;;
;;; The ring is accessed strictly round-robin (slot = loop-var mod ring_count)
;;; and each ring is awaited at exactly ONE site per role (producer awaits
;;; `empty`, consumer awaits `full` — never the same ring at two sites), so a
;;; monotonic counter incremented once per await tracks the visit exactly.  It
;;; degrades to the constant initial phase at visit 0, so the single-step 139/02
;;; handshake is unchanged.

;;; src/analysis/control.lisp
;;; analyze-await now carries the phase as (initial-phase ring-count) for a
;;; warp-spec ring (was the bare initial-phase integer); codegen turns that into
;;; the runtime flipping parity above.  NIL (a plain 138 ring) is unchanged.
(defun analyze-await-expression (expr env context location)
  "Emits semantic-nvvm-cp-async-wait on :ptx; no-op fallback elsewhere.
   Endeavor 139: for a warp-spec ring (has :initial-state) the :phase is
   (initial-phase ring-count) so codegen can inject the multi-lap flipping parity."
  (unless (= (length expr) 2)
    (error 'crisp-compiler-error
      :message (format nil "await: expected (await BARRIER), got ~S" expr)
      :source-location location))
  (let ((barrier-node (analyze-expression (second expr) env context (append location '(1))))
        (mode (async-barrier-mode-of (second expr))))
    (cond
      ((and (eq mode :block) (eq *target-backend* :ptx))
       (make-semantic-nvvm-tma-wait
        :barrier-node barrier-node
        :load-count (barrier-load-count-of (second expr))
        ;; Endeavor 139: a warp-spec ring -> (initial-phase ring-count) for the flipping await;
        ;; a plain 138 ring -> NIL (re-init await).
        :phase (let ((ip (barrier-initial-phase-of (second expr))))
                 (when ip (list ip (barrier-ring-count-of (second expr)))))
        :type 'ulong
        :source-location location))
      ((eq mode :block)
       (analyze-expression nil env context location))
      ((eq *target-backend* :ptx)
       (make-semantic-nvvm-cp-async-wait
        :barrier-node barrier-node
        :group-count (* (1- (barrier-ring-count-of (second expr)))
                        (barrier-load-count-of (second expr)))
        :type 'ulong
        :source-location location))
      ((eq *target-backend* :spirv)
       (make-semantic-spirv-group-wait
        :barrier-node barrier-node
        :type 'ulong
        :source-location location))
      (t
       (analyze-expression nil env context location)))))

;;; src/codegen.lisp
;;; (await bar) for a :block TMA barrier.  Three shapes of the phase field:
;;;   NIL            -> 138 path: try_wait.parity(0) + workgroup bar.sync + re-init.
;;;   integer (0/1)  -> legacy warp-spec constant parity (kept for safety; not
;;;                     emitted any more by analyze-await).
;;;   (init N)       -> Endeavor 139 multi-lap: per-ring entry-block visit counter,
;;;                     parity = init XOR ((visit / N) & 1), NO bar.sync, NO re-init.
(defmethod generate-node-ir ((node semantic-nvvm-tma-wait) builder module var-env
                              di-builder di-scope location-map)
  "Endeavor 137/2d + 139/step4 — (await bar) for a :block TMA barrier."
  (let* ((i32-type  (llvm-int32-type))
         (ptr-as3   (llvm-pointer-type (llvm-int8-type) 3))
         (barrier-i (generate-node-ir (semantic-nvvm-tma-wait-barrier-node node) builder module var-env
                                      di-builder di-scope location-map))
         (mbar-ptr  (llvm-build-int-to-ptr builder barrier-i ptr-as3 "tma_mbar"))
         (mbar-addr (llvm-build-ptr-to-int builder mbar-ptr i32-type "mbar_addr"))
         (load-cnt  (max 1 (semantic-nvvm-tma-wait-load-count node)))
         (ws-phase  (semantic-nvvm-tma-wait-phase node))
         (parent    (llvm-get-basic-block-parent (llvm-get-insert-block builder)))
         (wait-bb   (llvm-append-basic-block parent "tma_wait"))
         (exit-bb   (llvm-append-basic-block parent "tma_wait_done")))
    (when ws-phase
      ;; ---- Endeavor 139 multi-lap flipping parity ----------------------------
      ;; Compute the runtime parity from a per-ring visit counter, spin on
      ;; try_wait.parity(parity), increment the counter, return.  NO workgroup
      ;; bar.sync (only one role's warps reach here) and NO re-init.
      (let* ((is-list  (consp ws-phase))
             (init     (if is-list (first ws-phase) ws-phase))
             (ring-n   (if is-list (max 1 (second ws-phase)) 1))
             (parity
              (if (not is-list)
                  ;; Legacy constant parity.
                  (llvm-const-int i32-type init nil)
                  ;; Entry-block counter (persists across loop iterations): alloca +
                  ;; init-store hoisted before the entry block's terminator.
                  (let* ((saved (llvm-get-insert-block builder))
                         (entry (crisp.llvm-bindings::llvm-get-entry-basic-block parent))
                         (term  (llvm-get-basic-block-terminator entry)))
                    (if (cffi:null-pointer-p term)
                        (llvm-position-builder-at-end builder entry)
                        (crisp.llvm-bindings::llvm-position-builder-before builder term))
                    (let ((ctr (llvm-build-alloca builder i32-type "ws_pctr")))
                      (llvm-build-store builder (llvm-const-int i32-type 0 nil) ctr)
                      (llvm-position-builder-at-end builder saved)
                      ;; visit = load ctr; q = visit / N; lap = q - (q/2)*2  (= q mod 2)
                      (let* ((visit (llvm-build-load2 builder i32-type ctr "ws_visit"))
                             (q     (llvm-build-udiv builder visit (llvm-const-int i32-type ring-n nil) "ws_lap_q"))
                             (q2    (llvm-build-udiv builder q (llvm-const-int i32-type 2 nil) "ws_lap_q2"))
                             (q2x2  (llvm-build-mul builder q2 (llvm-const-int i32-type 2 nil) "ws_lap_q2x2"))
                             (lap   (llvm-build-sub builder q q2x2 "ws_lap"))
                             ;; parity = init XOR lap; init is a compile-time 0/1:
                             ;;   init 0 -> lap ; init 1 -> 1 - lap
                             (par   (if (zerop init)
                                        lap
                                        (llvm-build-sub builder (llvm-const-int i32-type 1 nil) lap "ws_parity"))))
                        ;; Stash the counter + visit on locals for the post-wait increment.
                        (setf (gethash '%ws-ctr var-env) ctr
                              (gethash '%ws-visit var-env) visit)
                        par))))))
        (llvm-build-br builder wait-bb)
        (llvm-position-builder-at-end builder wait-bb)
        (let* ((complete (%gen-nvvm-mbarrier-try-wait-parity builder mbar-addr parity))
               (done     (llvm-build-icmp builder +llvm-int-ne+ complete (llvm-const-int i32-type 0 nil) "ws_done")))
          (llvm-build-cond-br builder done exit-bb wait-bb))
        (llvm-position-builder-at-end builder exit-bb)
        ;; Increment the visit counter for the next lap (list path only).
        (when is-list
          (let* ((ctr   (gethash '%ws-ctr var-env))
                 (visit (gethash '%ws-visit var-env))
                 (next  (llvm-build-add builder visit (llvm-const-int i32-type 1 nil) "ws_visit_next")))
            (llvm-build-store builder next ctr)
            (remhash '%ws-ctr var-env)
            (remhash '%ws-visit var-env)))
        (return-from generate-node-ir (values (llvm-const-int (llvm-int64-type) 0 nil) nil))))
    ;; ---- 138 path (unchanged): try_wait.parity(0) + bar.sync + re-init --------
    (llvm-build-br builder wait-bb)
    (llvm-position-builder-at-end builder wait-bb)
    (let* ((complete (%gen-nvvm-mbarrier-try-wait-parity builder mbar-addr (llvm-const-int i32-type 0 nil)))
           (done     (llvm-build-icmp builder +llvm-int-ne+ complete (llvm-const-int i32-type 0 nil) "tma_done")))
      (llvm-build-cond-br builder done exit-bb wait-bb))
    (llvm-position-builder-at-end builder exit-bb)
    (%ptx-barrier builder module)
    (let* ((tid-x   (%gen-nvvm-read-tid-x builder module))
           (tid-y   (%gen-nvvm-read-tid-y builder module))
           (tid-z   (%gen-nvvm-read-tid-z builder module))
           (tid-sum (llvm-build-add builder (llvm-build-add builder tid-x tid-y "rtxy") tid-z "rtxyz"))
           (is-zero (llvm-build-icmp builder +llvm-int-eq+ tid-sum (llvm-const-int i32-type 0 nil) "reinit_tid0"))
           (reinit-bb (llvm-append-basic-block parent "tma_reinit"))
           (cont-bb   (llvm-append-basic-block parent "tma_reinit_cont")))
      (llvm-build-cond-br builder is-zero reinit-bb cont-bb)
      (llvm-position-builder-at-end builder reinit-bb)
      (%gen-nvvm-mbarrier-init-shared builder module mbar-ptr (llvm-const-int i32-type load-cnt nil))
      (%gen-nvvm-fence-proxy-async-shared builder)
      (llvm-build-br builder cont-bb)
      (llvm-position-builder-at-end builder cont-bb)
      (%ptx-barrier builder module))
    (values (llvm-const-int (llvm-int64-type) 0 nil) nil)))

;;; ===========================================================================
;;; Endeavor 139 (Chapter 3) — STEP 4 PERF: static per-warp fragment addressing
;;; ===========================================================================
;;;
;;; The register-tile DISTRIBUTION (n-true>1) computed each fragment's (mi nj)
;;; from the RUNTIME warp-position (wp = warp-id - first-true), so the SMEM
;;; operand addresses were runtime-derived and ptxas could not reuse (CSE) the
;;; A-row / B-col loads shared across fragments.  Measured cost: ws2 did 94
;;; ld.shared for 16 mma (5.9 loads/mma) vs ws1's 50 for 32 (1.6) — ~4x the
;;; operand traffic per MMA.
;;;
;;; FIX: wp is inherently runtime (warp identity comes from threadIdx), so branch
;;; on it ONCE — a `<`-cascade, exactly the with-warp-specialization role-branch
;;; pattern — and inside each of the n-true arms fold the fragment coordinates to
;;; integer LITERALS.  After the single runtime branch every operand address is a
;;; compile-time constant, so ptxas reuses the shared loads (the n-true=1 path
;;; already did this; now the distributed path matches it per warp).

;;; src/mma.lisp
(defun %emit-frag-loop-distributed (syms n-frags first-true n-true per-frag-fn)
  "Endeavor 139 step-4 perf: emit a COMPILE-TIME-STATIC per-warp switch (was a runtime
   fragment-index loop).  wp = warp-position is runtime, so branch on it once via a `<`-cascade
   (the role-branch pattern, last warp = bare else since wp is gated into [0,n-true)); inside each
   arm the fragment (mi nj) fold to integer LITERALS so the SMEM operand loads get static addresses
   and ptxas can CSE them.  PER-FRAG-FN is called with (fv mi nj) where mi/nj are INTEGERS (same
   contract as the n-true=1 static path)."
  (let* ((cl        (find-package :crisp-language))
         (progn-sym (intern "PROGN" cl))  (let-sym (intern "LET" cl))
         (if-sym    (intern "IF" cl))     (lt-sym  (intern "<" cl))
         (minus-sym (intern "-" cl))      (to-int-sym (intern "TO-INT" cl))
         (warp-id-sym (intern "WARP-ID" cl))
         (per-warp  (length syms))
         (wp        (gensym "WP")))
    (labels ((arm (k)
               `(,progn-sym
                  ,@(loop for l below per-warp
                          for fv = (nth l syms)
                          for logical = (+ (* k per-warp) l)
                          for mi = (floor logical n-frags)
                          for nj = (mod logical n-frags)
                          append (funcall per-frag-fn fv mi nj))))
             (chain (k)
               (if (>= k (1- n-true))
                   (arm k)                                   ; last warp = bare else
                   `(,if-sym (,lt-sym ,wp ,(1+ k))
                             ,(arm k)
                             ,(chain (1+ k))))))
      `(,let-sym ((,wp (,minus-sym (,to-int-sym (,warp-id-sym)) ,first-true)))
         ,(chain 0)))))

;;; src/mma.lisp — pass n-true through to the (now static) distributed emitter.
(defun %emit-per-frag-accumulate (a b entry &optional accum-binding body)
  "Per-fragment expansion of mma-accumulate-via-tile.  Endeavor 139 step-4: distributed path is now
   a static per-warp switch (n-true threaded to %emit-frag-loop-distributed)."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0)) (cdr entry)
    (destructuring-bind (fm . fn) (%frag-mn)
      (let ((m-frags (floor m fm)) (n-frags (floor n fn)))
        (flet ((one-frag (fv mi-form nj-form)
                 (let ((acc-set `(set! ,fv (mma-accumulate ,fv
                                                           (load-fragment-a ,a (,mi-form 0))
                                                           (load-fragment-b ,b (0 ,nj-form))))))
                   (if body
                       (mapcar (lambda (f) (%subst-accum f accum-binding fv acc-set)) body)
                       (list acc-set)))))
          (if (> n-true 1)
              (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag)
              `(progn
                 ,@(loop for mi below m-frags append
                         (loop for nj below n-frags
                               for idx = (+ (* mi n-frags) nj)
                               append (one-frag (nth idx syms) mi nj))))))))))

;;; src/mma.lisp — same n-true threading for the distributed store.
(defun %emit-per-frag-store (dest tile-id entry)
  "Per-fragment expansion of (store-tile V DEST (BTY BTX)).  Endeavor 139 step-4: distributed path
   is now a static per-warp switch."
  (destructuring-bind (m n syms &optional (n-true 1) (first-true 0)) (cdr entry)
    (destructuring-bind (fm . fn) (%frag-mn)
      (let* ((to-int-sym (intern "TO-INT" (find-package :crisp-language)))
             (m-frags (floor m fm)) (n-frags (floor n fn))
             (bty (list to-int-sym (first tile-id)))
             (btx (list to-int-sym (second tile-id))))
        (flet ((one-frag (fv mi-form nj-form)
                 (list `(store-fragment ,fv ,dest
                                        ((+ (* ,bty ,m-frags) ,mi-form)
                                         (+ (* ,btx ,n-frags) ,nj-form))))))
          (if (> n-true 1)
              (%emit-frag-loop-distributed syms n-frags first-true n-true #'one-frag)
              `(progn
                 ,@(loop for mi below m-frags append
                         (loop for nj below n-frags
                               for idx = (+ (* mi n-frags) nj)
                               append (one-frag (nth idx syms) mi nj))))))))))

;;; ===========================================================================
;;; Endeavor 140 (Chapter 4) -- STEP 0: wgmma front-end scaffolding
;;; ===========================================================================
;;;
;;; Two user forms mirroring make-register-tile / mma-accumulate-via-tile:
;;;   (make-wgmma-accumulator float (64 N) 0.0)    -> a warpgroup D accumulator
;;;   (wgmma-accumulate-via-tile (64 N 8) D A B)   -> D += A*B  (A,B are SMEM tiles)
;;; PROTOTYPE reuses the semantic-mma-accumulate node (dispatched to wgmma codegen by the
;;; accumulator TYPE) so Step 0/1 stay entirely in the overlay -- no struct patch during metal
;;; iteration.  Step 0 = forms + shape/dtype validation + accumulator minting + a NO-OP codegen
;;; stub (so it compiles); Step 1 fills in the real descriptor + wgmma emission.

(defvar *wgmma-acc-dims* (make-hash-table :test 'eq)
  "wgmma accumulator type symbol -> (list M N K).")

(defun %wgmma-acc-type-name (n)
  (intern (format nil "WGMMA-ACC-F32-64X~d" n) (find-package :crisp.compiler)))

(defun %wgmma-acc-type-p (type-name)
  "T if TYPE-NAME is a minted wgmma accumulator record type."
  (and (symbolp type-name) (nth-value 1 (gethash type-name *wgmma-acc-dims*))))

(defun %ensure-wgmma-acc-type (n)
  "Mint (once) the WGMMA-ACC-F32-64xN record -- N/2 flat f32 fields (the wgmma D accumulator, N/2
   f32 registers per thread across the 128-thread warpgroup).  Returns the type symbol."
  (let ((name (%wgmma-acc-type-name n)))
    (unless (gethash name *crisp-structs*)
      (register-struct-definition
       name
       (loop for i below (floor n 2)
             collect (list (intern (format nil "D~d" i) (find-package :crisp.compiler)) 'float))
       :record))
    (setf (gethash name *wgmma-acc-dims*) (list 64 n 8))
    name))

(defun %check-wgmma-shape (shape location)
  "Validate a wgmma (M N K) shape -- grounded in machine truth: M is fixed 64; N a multiple of 8 in
   [8,256] (the m64nNk8 family); K by dtype (tf32 -> 8, the only dtype implemented now)."
  (unless (and (listp shape) (= (length shape) 3) (every #'integerp shape))
    (error 'crisp-compiler-error
           :message (format nil "wgmma-accumulate-via-tile: shape must be an (M N K) integer triple, got ~a." shape)
           :source-location location))
  (destructuring-bind (m n k) shape
    (unless (= m 64)
      (error 'crisp-compiler-error
             :message (format nil "wgmma: M must be 64 (wgmma is always m64), got ~a." m)
             :source-location location))
    (unless (and (>= n 8) (<= n 256) (zerop (mod n 8)))
      (error 'crisp-compiler-error
             :message (format nil "wgmma: N must be a multiple of 8 in [8,256] (the m64nNk8 family), got ~a." n)
             :source-location location))
    (unless (= k 8)
      (error 'crisp-compiler-error
             :message (format nil "wgmma: K must be 8 for tf32 (the only dtype implemented), got ~a." k)
             :source-location location))))

(defun analyze-make-wgmma-accumulator (expr env context location)
  "(make-wgmma-accumulator T (64 N) INIT) -> a warpgroup D accumulator record of N/2 f32 fields,
   each initialized to INIT.  Mints the type on demand; rewrites to %construct-struct."
  (destructuring-bind (elem dims init) (cdr expr)
    (declare (ignore elem))              ; tf32/f32 fixed for now
    (destructuring-bind (m n) dims
      (%check-wgmma-shape (list m n 8) location)
      (let ((type-name (%ensure-wgmma-acc-type n)))
        (analyze-expression
         `(%construct-struct ,type-name ,@(loop repeat (floor n 2) collect init))
         env context location)))))

(defun analyze-wgmma-accumulate (expr env context location)
  "(wgmma-accumulate D A B) -- the primitive.  D is a wgmma accumulator record; A,B are SMEM tiles.
   Reuses semantic-mma-accumulate typed as the wgmma accumulator; generate-node-ir dispatches to the
   wgmma instruction by that type.  (Prototype: node reuse -- see wgmma.md.)"
  (destructuring-bind (d a b) (cdr expr)
    (let* ((d-node (analyze-expression d env context (append location '(1))))
           (d-type (semantic-node-type d-node)))
      (unless (%wgmma-acc-type-p d-type)
        (error 'crisp-compiler-error
               :message (format nil "wgmma-accumulate: D (1st arg) must be a make-wgmma-accumulator, got type ~a." d-type)
               :source-location location))
      (make-semantic-mma-accumulate
       :type d-type
       :c-node d-node
       :a-node (analyze-expression a env context (append location '(2)))
       :b-node (analyze-expression b env context (append location '(3)))
       :source-location location))))

(defun analyze-wgmma-accumulate-via-tile (expr env context location)
  "(wgmma-accumulate-via-tile (64 N 8) D A B) -> (set! D (wgmma-accumulate D A B)).  The warpgroup
   analog of mma-accumulate-via-tile, but NO fragment walk -- one wgmma over the whole accumulator."
  (destructuring-bind (shape d a b) (cdr expr)
    (%check-wgmma-shape shape location)
    (analyze-expression `(set! ,d (wgmma-accumulate ,d ,a ,b)) env context location)))

;;; Registration: reproduce register-mma-analyzers + the 3 wgmma entries.
(defun register-mma-analyzers ()
  "Registers the MMA + wgmma expression analyzers.  Overlay (Endeavor 140): adds the wgmma forms."
  (let ((cl-pkg (find-package :crisp-language))
        (cc-pkg (find-package :crisp.compiler)))
    (dolist (entry (list (cons "MAKE-REGISTER-FRAGMENT" #'analyze-make-register-fragment)
                         (cons "STORE-FRAGMENT"          #'analyze-store-fragment)
                         (cons "LOAD-FRAGMENT-A"         #'analyze-load-fragment-a)
                         (cons "LOAD-FRAGMENT-B"         #'analyze-load-fragment-b)
                         (cons "MMA-ACCUMULATE"          #'analyze-mma-accumulate)
                         (cons "MAKE-REGISTER-TILE"      #'analyze-make-register-tile)
                         (cons "MMA-ACCUMULATE-VIA-TILE" #'analyze-mma-accumulate-via-tile)
                         (cons "INNER-DIMENSION"         #'analyze-inner-dimension)
                         (cons "OUTER-DIMENSIONS"        #'analyze-outer-dimensions-expression)
                         ;; Endeavor 140 (Chapter 4) -- wgmma forms
                         (cons "MAKE-WGMMA-ACCUMULATOR"    #'analyze-make-wgmma-accumulator)
                         (cons "WGMMA-ACCUMULATE"          #'analyze-wgmma-accumulate)
                         (cons "WGMMA-ACCUMULATE-VIA-TILE" #'analyze-wgmma-accumulate-via-tile)
                         (cons "STORE-TILE"              #'analyze-store-tile-mma)
                         (cons "LET"                     #'analyze-let-with-tile-explosion)
                         (cons "LET*"                    #'analyze-let-with-tile-explosion)))
      (let ((sym-cl (intern (car entry) cl-pkg))
            (sym-cc (intern (car entry) cc-pkg)))
        (setf (gethash sym-cl *expression-analyzers*) (cdr entry))
        (unless (eq sym-cl sym-cc)
          (setf (gethash sym-cc *expression-analyzers*) (cdr entry)))))))

;;; Codegen: reproduce generate-node-ir (semantic-mma-accumulate) + a wgmma dispatch.  Step 0 =
;;; NO-OP stub (return the accumulator unchanged so it compiles); Step 1 emits the real wgmma.
(defmethod generate-node-ir ((node semantic-mma-accumulate)
                             builder module var-env di-builder di-scope location-map)
  "F-SPV / NVVM mma.sync + Endeavor 140 wgmma dispatch (by accumulator type)."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (let ((acc-type (semantic-mma-accumulate-type node)))
      (if (%wgmma-acc-type-p acc-type)
          ;; Endeavor 140 STEP 0 STUB -- return the accumulator unchanged (no-op) so the front-end
          ;; compiles; Step 1 replaces this with wgmma.fence + descriptors + mma_async + commit/wait.
          (values (gen (semantic-mma-accumulate-c-node node)) nil)
          (let ((c-val (gen (semantic-mma-accumulate-c-node node)))
                (a-val (gen (semantic-mma-accumulate-a-node node)))
                (b-val (gen (semantic-mma-accumulate-b-node node))))
            (if (eq *target-backend* :spirv)
                (multiple-value-bind (sm sn sk) (%spv-mma-shape)
                  (values (%coop-mma builder module a-val b-val c-val (llvm-float-type) sm sn sk) nil))
                (%emit-nvvm-mma builder module a-val b-val c-val)))))))

;;; ===========================================================================
;;; Endeavor 140 (Chapter 4) — STEP 1: real wgmma codegen (port of the metal-verified
;;; wgmma_ref.cu recipe).  m64nNk8 tf32, no swizzle, SS (both operands from SMEM).
;;; ===========================================================================

(defun %wgmma-make-desc (builder base-ptr)
  "Build the 64-bit wgmma SMEM matrix descriptor from an addrspace(3) BASE-PTR (element 0 of the
   core-matrix-ordered tile).  start = (addr>>4)&0x3FFF at [0:13]; the compile-time constant packs
   LBO=128B (enc 8) at [16:29], SBO=256B (enc 16) at [32:45], swizzle=0 at [62:63].  (Verified in
   wgmma_ref.cu: MMA_CORRECT.)"
  (let* ((i32 (llvm-int32-type)) (i64 (llvm-int64-type))
         (const-val (logior (ash 8 16) (ash 16 32)))   ; LBO_enc<<16 | SBO_enc<<32 | swizzle=0
         (addr (llvm-build-ptr-to-int builder base-ptr i32 "wg_addr"))
         (sh   (crisp.llvm-bindings::llvm-build-l-shr builder addr (llvm-const-int i32 4 nil) "wg_sh"))
         (msk  (crisp.llvm-bindings::llvm-build-and builder sh (llvm-const-int i32 #x3FFF nil) "wg_start"))
         (st64 (llvm-build-zext builder msk i64 "wg_start64")))
    (crisp.llvm-bindings::llvm-build-or builder st64 (llvm-const-int i64 const-val nil) "wg_desc")))

(defun %wgmma-struct-of-floats (module nacc)
  "The LLVM struct type { float x NACC } — the wgmma inline-asm result (NACC = N/2 accumulators)."
  (let ((elts (cffi:foreign-alloc 'llvm-type-ref :count nacc)))
    (dotimes (i nacc) (setf (cffi:mem-aref elts 'llvm-type-ref i) (llvm-float-type)))
    (llvm-struct-type-in-context (llvm-get-module-context module) elts nacc nil)))

(defun %wgmma-asm-string (nacc n)
  "wgmma.mma_async.sync.aligned.m64nNk8.f32.tf32.tf32 {$0..$nacc-1}, descA, descB, 1,1,1;
   NB on operand numbering: LLVM IR inline-asm has no '+f'; a read-write accumulator is an '=f'
   OUTPUT ($0..$nacc-1) PLUS a matching tied INPUT ($nacc..$2*nacc-1).  The tied inputs DO occupy
   operand slots, so the two 'l' descriptors are $2*nacc and $2*nacc+1 (not $nacc/$nacc+1)."
  (let ((accs (format nil "~{$~d~^,~}" (loop for i below nacc collect i))))
    (format nil "wgmma.mma_async.sync.aligned.m64n~dk8.f32.tf32.tf32 {~a}, $~d, $~d, 1, 1, 1;"
            n accs (* 2 nacc) (1+ (* 2 nacc)))))

(defun %wgmma-constraints (nacc)
  "NACC '=f' outputs, NACC tied inputs (0..nacc-1), 2 'l' descriptor inputs, memory clobber."
  (let ((outs (loop for i below nacc collect "=f"))
        (ties (loop for i below nacc collect (format nil "~d" i))))
    (format nil "~{~a~^,~},~{~a~^,~},l,l,~~{memory}" outs ties)))

(defun %emit-nvvm-wgmma (builder module d-val a-ptr b-ptr acc-type n)
  "Emit the m64nNk8 tf32 wgmma: descriptors from the A/B SMEM base ptrs, fence, mma_async (N/2
   accumulators in/out + 2 descs), commit, wait; reconstruct the D record.  Returns (values D nil)."
  (let* ((f32 (llvm-float-type)) (i64 (llvm-int64-type))
         (nacc (floor n 2))
         (descA (%wgmma-make-desc builder a-ptr))
         (descB (%wgmma-make-desc builder b-ptr))
         (c-ops (loop for i below nacc collect
                      (llvm-build-extract-value builder d-val i (format nil "wc~d" i)))))
    ;; The A/B SMEM tiles are written by GENERIC st.shared (the kernel's scatter/load); wgmma reads
    ;; them via the ASYNC proxy.  fence.proxy.async.shared::cta makes each thread's generic writes
    ;; visible to the async proxy, then a workgroup barrier makes ALL threads' writes visible before
    ;; the collective wgmma reads.  (Without this, a single wgmma got lucky (Step 1) but the multi-K
    ;; loop raced -> non-deterministic MMA_WRONG.)  Harmless/redundant for a TMA-staged tile (Step 3).
    (%gen-nvvm-fence-proxy-async-shared builder)
    (%ptx-barrier builder module)
    ;; wgmma.fence establishes the accumulator registers before the async MMA.
    (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.fence.sync.aligned;" "~{memory}")
    (let* ((asm-str     (%wgmma-asm-string nacc n))
           (constraints (%wgmma-constraints nacc))
           (ret-ty      (%wgmma-struct-of-floats module nacc))
           (ptypes      (append (loop repeat nacc collect f32) (list i64 i64)))
           (args        (append c-ops (list descA descB)))
           (call        (%build-inline-asm-call builder ret-ty ptypes args asm-str constraints)))
      ;; commit + wait (memory clobber keeps the downstream store after wait_group — the async
      ;; hazard the wgmma_ref.cu relied on).
      (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.commit_group.sync.aligned;" "~{memory}")
      (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.wait_group.sync.aligned 0;" "~{memory}")
      ;; NB: `return` is SHADOWED in :crisp.compiler by Crisp's RETURN macro (-> explicit-return),
      ;; so a `(loop ... finally (return agg))` would expand to (explicit-return agg).  Use dotimes.
      (let ((agg (llvm-get-undef (crisp-type-to-llvm-type acc-type module))))
        (dotimes (i nacc)
          (setf agg (llvm-build-insert-value builder agg
                      (llvm-build-extract-value builder call i (format nil "wo~d" i))
                      i (format nil "wr~d" i))))
        (values agg nil)))))

;;; analyze-wgmma-accumulate: A/B become aref (~ tile 0) so codegen recovers the addrspace(3) base.
(defun analyze-wgmma-accumulate (expr env context location)
  "(wgmma-accumulate D A B).  D is a wgmma accumulator record; A,B are flat SMEM tiles in
   CORE-MATRIX order.  a-node/b-node are (~ A 0) / (~ B 0) so generate-node-ir's 3rd value is the
   addrspace(3) base pointer for the descriptor."
  (destructuring-bind (d a b) (cdr expr)
    (let* ((d-node (analyze-expression d env context (append location '(1))))
           (d-type (semantic-node-type d-node)))
      (unless (%wgmma-acc-type-p d-type)
        (error 'crisp-compiler-error
               :message (format nil "wgmma-accumulate: D (1st arg) must be a make-wgmma-accumulator, got type ~a." d-type)
               :source-location location))
      (make-semantic-mma-accumulate
       :type d-type
       :c-node d-node
       :a-node (analyze-expression `(~ ,a 0) env context (append location '(2)))
       :b-node (analyze-expression `(~ ,b 0) env context (append location '(3)))
       :source-location location))))

;;; Codegen: real wgmma emission (replaces the Step-0 stub).
(defmethod generate-node-ir ((node semantic-mma-accumulate)
                             builder module var-env di-builder di-scope location-map)
  "F-SPV / NVVM mma.sync + Endeavor 140 wgmma (dispatched by accumulator type)."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (let ((acc-type (semantic-mma-accumulate-type node)))
      (if (%wgmma-acc-type-p acc-type)
          (let ((c-val (gen (semantic-mma-accumulate-c-node node))))
            (multiple-value-bind (av al a-ptr)
                (gen (semantic-mma-accumulate-a-node node))
              (declare (ignore av al))
              (multiple-value-bind (bv bl b-ptr)
                  (gen (semantic-mma-accumulate-b-node node))
                (declare (ignore bv bl))
                (unless (and a-ptr b-ptr)
                  (error "wgmma: A/B (~ tile 0) did not yield an SMEM element pointer (a ~A b ~A)" a-ptr b-ptr))
                (%emit-nvvm-wgmma builder module c-val a-ptr b-ptr acc-type
                                  (second (gethash acc-type *wgmma-acc-dims*))))))
          (let ((c-val (gen (semantic-mma-accumulate-c-node node)))
                (a-val (gen (semantic-mma-accumulate-a-node node)))
                (b-val (gen (semantic-mma-accumulate-b-node node))))
            (if (eq *target-backend* :spirv)
                (multiple-value-bind (sm sn sk) (%spv-mma-shape)
                  (values (%coop-mma builder module a-val b-val c-val (llvm-float-type) sm sn sk) nil))
                (%emit-nvvm-mma builder module a-val b-val c-val)))))))

;;; store-tile: add a wgmma-accumulator branch (the warp-tiled m16n8 C fragment store).
(defun %wgmma-store-rewrite (tile dest tile-id n)
  "Store the m64xN wgmma accumulator TILE to DEST at grid tile-id (BTY BTX).  warp w (within the
   warpgroup) -> rows [16w,16w+16); per n8 group the standard mma m16n8 C fragment.  (= wgmma_ref.cu.)"
  (let* ((to-int (intern "TO-INT" (find-package :crisp-language)))
         (n8 (floor n 8))
         (bty `(,to-int ,(first tile-id)))
         (btx `(,to-int ,(second tile-id))))
    `(let ((wgv ,tile))
       (let ((wgw (rem (,to-int (warp-id)) 4))
             (lane (,to-int (warp-lane))))
         (let ((rlo (/ lane 4)) (col (* (rem lane 4) 2)))
           (let ((r0 (+ (+ (* ,bty 64) (* wgw 16)) rlo)))
             (let ((r8 (+ r0 8))
                   (c0 (+ (* ,btx ,n) col)))
               (progn
                 ,@(loop for j below n8
                         for base = (* j 4)
                         append (list
                                 `(set! (~ ,dest r0 (+ c0 ,(* 8 j)))         (%extract-struct-member wgv ,(+ base 0)))
                                 `(set! (~ ,dest r0 (+ (+ c0 ,(* 8 j)) 1))   (%extract-struct-member wgv ,(+ base 1)))
                                 `(set! (~ ,dest r8 (+ c0 ,(* 8 j)))         (%extract-struct-member wgv ,(+ base 2)))
                                 `(set! (~ ,dest r8 (+ (+ c0 ,(* 8 j)) 1))   (%extract-struct-member wgv ,(+ base 3)))))))))))))

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
       (destructuring-bind (m n) (gethash src-type *register-tile-dims*)
         (let* ((tile    (second expr))
                (dest    (third expr))
                (tile-id (fourth expr))
                (to-int-sym (intern "TO-INT" (find-package :crisp-language)))
                (bty (list to-int-sym (first tile-id)))
                (btx (list to-int-sym (second tile-id)))
                (m-frags (floor m 16)) (n-frags (floor n 8)))
           (analyze-expression
            `(let ((tv ,tile))
               (progn
                 ,@(loop for mi below m-frags
                         append (loop for nj below n-frags
                                      for idx = (+ (* mi n-frags) nj)
                                      collect `(store-fragment (%extract-struct-member tv ,idx)
                                                               ,dest
                                                               ((+ (* ,bty ,m-frags) ,mi)
                                                                (+ (* ,btx ,n-frags) ,nj)))))))
            env context location))))
      (t
       (analyze-store-tile-expression expr env context location)))))

;;; ===========================================================================
;;; Endeavor 140 (Chapter 4) — STEP 3: TMA + 128B swizzle wgmma (port of the metal-verified recipe)
;;; ===========================================================================
;;; A :swizzle :128b tile is TMA-loaded (async proxy) into a 128B-swizzled 64xK-block SMEM tile; the
;;; wgmma reads it with the SWIZZLE descriptor (SBO=1024, base_offset=0, swizzle bits=1) and iterates
;;; K/8 k-slices (start advances kk*32 bytes).  NO fence.proxy.async (TMA + wgmma are both async proxy;
;;; the scatter path still needs it).  Swizzle+k threaded node->codegen via *wgmma-node-swizzle*.

(defvar *wgmma-node-swizzle* (make-hash-table :test 'eq)
  "semantic-mma-accumulate node -> (list swizzle-mode k-block) for the wgmma path.")

;;; src/mma.lisp / overlay — descriptor now parameterized by swizzle + per-k-slice byte offset.
(defun %wgmma-make-desc (builder base-ptr &optional swizzle-p (kslice-byte-off 0))
  "Build the 64-bit wgmma SMEM matrix descriptor.  NO-SWIZZLE (Step 1, scatter/core-matrix): LBO=128B
   (enc 8), SBO=256B (enc 16), swizzle=0.  128B-SWIZZLE (Step 3, TMA, CUTLASS make_gmma_desc<K>):
   LBO=16B (enc 1), SBO=1024B (enc 64), swizzle bits=1, base_offset=0; the k-slice ADVANCES the start
   address by KSLICE-BYTE-OFF (kk*32).  start = ((addr+off)>>4)&0x3FFF at [0:13]."
  (let* ((i32 (llvm-int32-type)) (i64 (llvm-int64-type))
         (const-val (if swizzle-p
                        (logior (ash 1 16) (ash 64 32) (ash 1 62))    ; LBO=16,SBO=1024,swz=128B,base=0
                        (logior (ash 8 16) (ash 16 32))))             ; LBO=128,SBO=256,swz=0
         (addr0 (llvm-build-ptr-to-int builder base-ptr i32 "wg_addr"))
         (addr  (if (zerop kslice-byte-off) addr0
                    (llvm-build-add builder addr0 (llvm-const-int i32 kslice-byte-off nil) "wg_addr_k")))
         (sh    (crisp.llvm-bindings::llvm-build-l-shr builder addr (llvm-const-int i32 4 nil) "wg_sh"))
         (msk   (crisp.llvm-bindings::llvm-build-and builder sh (llvm-const-int i32 #x3FFF nil) "wg_start"))
         (st64  (llvm-build-zext builder msk i64 "wg_start64")))
    (crisp.llvm-bindings::llvm-build-or builder st64 (llvm-const-int i64 const-val nil) "wg_desc")))

(defun %emit-one-wgmma (builder module d-val a-ptr b-ptr acc-type n swizzle-p kslice-off)
  "One m64nNk8 wgmma: fence + mma_async (N/2 accumulators in/out + 2 descs) + commit + wait; return
   the new D record.  The k-slice offset (kk*32 bytes) advances the swizzle descriptor start address."
  (let* ((f32 (llvm-float-type)) (i64 (llvm-int64-type))
         (nacc (floor n 2))
         (descA (%wgmma-make-desc builder a-ptr swizzle-p kslice-off))
         (descB (%wgmma-make-desc builder b-ptr swizzle-p kslice-off))
         (c-ops (loop for i below nacc collect
                      (llvm-build-extract-value builder d-val i (format nil "wc~d" i)))))
    (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.fence.sync.aligned;" "~{memory}")
    (let* ((asm-str     (%wgmma-asm-string nacc n))
           (constraints (%wgmma-constraints nacc))
           (ret-ty      (%wgmma-struct-of-floats module nacc))
           (ptypes      (append (loop repeat nacc collect f32) (list i64 i64)))
           (args        (append c-ops (list descA descB)))
           (call        (%build-inline-asm-call builder ret-ty ptypes args asm-str constraints)))
      (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.commit_group.sync.aligned;" "~{memory}")
      (%build-inline-asm-call builder (llvm-void-type) nil nil "wgmma.wait_group.sync.aligned 0;" "~{memory}")
      (let ((agg (llvm-get-undef (crisp-type-to-llvm-type acc-type module))))
        (dotimes (i nacc)
          (setf agg (llvm-build-insert-value builder agg
                      (llvm-build-extract-value builder call i (format nil "wo~d" i))
                      i (format nil "wr~d" i))))
        agg))))

(defun %emit-nvvm-wgmma (builder module d-val a-ptr b-ptr acc-type n &optional swizzle-p (k 8))
  "Emit the wgmma accumulate.  NO-SWIZZLE (scatter): a proxy fence + barrier (generic->async proxy
   visibility) + ONE k8 wgmma.  128B-SWIZZLE (TMA): NO proxy fence (both async proxy) + K/8 k-slice
   wgmmas, D accumulating across them (scaleD=1), each with the start advanced kk*32 bytes.
   Returns (values D nil)."
  (let ((n-slices (if swizzle-p (max 1 (floor k 8)) 1)))
    (unless swizzle-p
      ;; scatter path: generic st.shared writes must be made visible to wgmma's async-proxy read.
      (%gen-nvvm-fence-proxy-async-shared builder)
      (%ptx-barrier builder module))
    (let ((cur-d d-val))
      (dotimes (kk n-slices)
        (setf cur-d (%emit-one-wgmma builder module cur-d a-ptr b-ptr acc-type n swizzle-p (* kk 32))))
      (values cur-d nil))))

;;; %check-wgmma-shape: K is now a positive multiple of 8 (8 = one wgmma; 32 = a 128B-swizzle K-block).
(defun %check-wgmma-shape (shape location)
  "Validate a wgmma (M N K) shape.  M fixed 64; N a multiple of 8 in [8,256]; K a positive multiple
   of 8 (8 for a single k8 wgmma / scatter path; a K-block e.g. 32 for the TMA+swizzle path)."
  (unless (and (listp shape) (= (length shape) 3) (every #'integerp shape))
    (error 'crisp-compiler-error
           :message (format nil "wgmma-accumulate-via-tile: shape must be an (M N K) integer triple, got ~a." shape)
           :source-location location))
  (destructuring-bind (m n k) shape
    (unless (= m 64)
      (error 'crisp-compiler-error :message (format nil "wgmma: M must be 64 (wgmma is always m64), got ~a." m)
             :source-location location))
    (unless (and (>= n 8) (<= n 256) (zerop (mod n 8)))
      (error 'crisp-compiler-error :message (format nil "wgmma: N must be a multiple of 8 in [8,256], got ~a." n)
             :source-location location))
    (unless (and (plusp k) (zerop (mod k 8)))
      (error 'crisp-compiler-error :message (format nil "wgmma: K must be a positive multiple of 8, got ~a." k)
             :source-location location))))

;;; analyze-wgmma-accumulate: accepts :swizzle / :k, stashed on the node for codegen.
(defun analyze-wgmma-accumulate (expr env context location)
  "(wgmma-accumulate D A B [:swizzle MODE :k K]).  a/b -> (~ tile 0) so codegen's 3rd value is the
   addrspace(3) base; :swizzle/:k stashed in *wgmma-node-swizzle* keyed by the node."
  (destructuring-bind (d a b &rest kwargs) (cdr expr)
    (let* ((d-node (analyze-expression d env context (append location '(1))))
           (d-type (semantic-node-type d-node)))
      (unless (%wgmma-acc-type-p d-type)
        (error 'crisp-compiler-error
               :message (format nil "wgmma-accumulate: D (1st arg) must be a make-wgmma-accumulator, got type ~a." d-type)
               :source-location location))
      (let ((node (make-semantic-mma-accumulate
                   :type d-type
                   :c-node d-node
                   :a-node (analyze-expression `(~ ,a 0) env context (append location '(2)))
                   :b-node (analyze-expression `(~ ,b 0) env context (append location '(3)))
                   :source-location location)))
        (setf (gethash node *wgmma-node-swizzle*) (list (getf kwargs :swizzle) (or (getf kwargs :k) 8)))
        node))))

(defun analyze-wgmma-accumulate-via-tile (expr env context location)
  "(wgmma-accumulate-via-tile (64 N K) D A B [:swizzle :128b]) -> (set! D (wgmma-accumulate D A B
   :swizzle MODE :k K)).  K is the K-block (8 = single wgmma; 32 = 128B-swizzle 4-slice block)."
  (destructuring-bind (shape d a b &rest kwargs) (cdr expr)
    (%check-wgmma-shape shape location)
    (analyze-expression `(set! ,d (wgmma-accumulate ,d ,a ,b :swizzle ,(getf kwargs :swizzle) :k ,(third shape)))
                        env context location)))

;;; generate-node-ir dispatch: read swizzle/k from the table, pass to %emit-nvvm-wgmma.
(defmethod generate-node-ir ((node semantic-mma-accumulate)
                             builder module var-env di-builder di-scope location-map)
  "F-SPV / NVVM mma.sync + Endeavor 140 wgmma (dispatched by accumulator type; swizzle/k from table)."
  (flet ((gen (n) (generate-node-ir n builder module var-env di-builder di-scope location-map)))
    (let ((acc-type (semantic-mma-accumulate-type node)))
      (if (%wgmma-acc-type-p acc-type)
          (destructuring-bind (&optional swizzle-mode (k 8)) (gethash node *wgmma-node-swizzle*)
            (let ((c-val (gen (semantic-mma-accumulate-c-node node)))
                  (swizzle-p (and swizzle-mode (string-equal (string swizzle-mode) "128B"))))
              (multiple-value-bind (av al a-ptr) (gen (semantic-mma-accumulate-a-node node))
                (declare (ignore av al))
                (multiple-value-bind (bv bl b-ptr) (gen (semantic-mma-accumulate-b-node node))
                  (declare (ignore bv bl))
                  (unless (and a-ptr b-ptr)
                    (error "wgmma: A/B (~ tile 0) did not yield an SMEM element pointer (a ~A b ~A)" a-ptr b-ptr))
                  (%emit-nvvm-wgmma builder module c-val a-ptr b-ptr acc-type
                                    (second (gethash acc-type *wgmma-acc-dims*)) swizzle-p k)))))
          (let ((c-val (gen (semantic-mma-accumulate-c-node node)))
                (a-val (gen (semantic-mma-accumulate-a-node node)))
                (b-val (gen (semantic-mma-accumulate-b-node node))))
            (if (eq *target-backend* :spirv)
                (multiple-value-bind (sm sn sk) (%spv-mma-shape)
                  (values (%coop-mma builder module a-val b-val c-val (llvm-float-type) sm sn sk) nil))
                (%emit-nvvm-mma builder module a-val b-val c-val)))))))

;;; ===========================================================================
;;; Endeavor 140 Step 3 — thread :swizzle from load-tile -> scan -> resolve -> metadata so a wgmma
;;; tile's CuTensorMap gets SWIZZLE_128B.  Three reproductions, each = original + one :swizzle line.
;;; ===========================================================================

;;; src/analysis/core.lisp — %scan-register-tma-descriptor: capture the load-tile's :swizzle key.
(defun %scan-register-tma-descriptor (args)
  "Endeavor 137/140: register a CUtensorMap descriptor for a :block load-tile's SRC; capture the
   optional :swizzle key (:128b for wgmma) so the hoist emits CU_TENSOR_MAP_SWIZZLE_128B."
  (let* ((src     (first args))
         (tile    (second args))
         (barrier (getf (cdddr args) :barrier))
         (swizzle (getf (cdddr args) :swizzle))
         (bar-ring  (%barrier-ring-form-p barrier))
         (bar-key   (or bar-ring (and (symbolp barrier) barrier)))
         (tile-ring (and (consp tile) (symbolp (first tile))
                         (string-equal (symbol-name (first tile)) "RING-GET")
                         (symbolp (second tile))
                         (second tile)))
         (tile-key  (or tile-ring (and (symbolp tile) tile))))
    (when (and (symbolp src) bar-key
               (eq (async-barrier-mode-of barrier) :block)
               (eq *target-backend* :ptx))
      (setf *scan-is-originator* t)
      (unless bar-ring
        (incf (gethash bar-key *async-barrier-load-count* 0)))
      (let* ((fn-name  (compiler-context-scanning-function-name *compiler-context*))
             (existing (gethash fn-name *implicit-arg-map*))
             (already  (find-if (lambda (e)
                                  (let ((spec (cdr e)))
                                    (and (consp spec)
                                         (symbolp (first spec))
                                         (string-equal (symbol-name (first spec)) "TENSOR-MAP")
                                         (eq (second spec) src))))
                                existing)))
        (unless already
          (let* ((uname (intern (format nil "~a_TENSORMAP_FROM_~a" src fn-name)
                                (symbol-package src)))
                 (spec  (list (intern "TENSOR-MAP" (find-package :crisp.compiler)) src)))
            (log:info "Pass 1: :block load-tile of ~a (tile ~a, swizzle ~a) -> CUtensorMap descriptor ~a"
                      src tile swizzle uname)
            (push (cons uname spec) (gethash fn-name *implicit-arg-map*))
            (setf (gethash uname *tma-descriptor-info*)
                  (list :originator fn-name :describes-sym src
                        :tile-sym (or tile-key tile)
                        :tile-via-ring (and tile-ring t)
                        :swizzle swizzle))))))))

;;; src/analysis/core.lisp — resolve-tma-descriptors: carry :swizzle into *tma-resolved*.
(defun resolve-tma-descriptors ()
  "Endeavor 137/140: resolve describes + box-dims through the carrier chain into *tma-resolved*,
   carrying the :swizzle marking from *tma-descriptor-info*."
  (loop for kernel being the hash-keys of *implicit-arg-map*
        when (%fn-is-kernel-p kernel)
          do (dolist (entry (gethash kernel *implicit-arg-map*))
               (let ((uname (car entry)))
                 (when (gethash uname *tma-descriptor-info*)
                   (let ((d (%tma-resolve-ref kernel uname :describes))
                         (til (%tma-resolve-ref kernel uname :tile)))
                     (cond
                       ((and d (eq (first d) :tensor) til (eq (first til) :tile))
                        (let* ((via-ring (getf (gethash uname *tma-descriptor-info*) :tile-via-ring))
                               (swizzle  (getf (gethash uname *tma-descriptor-info*) :swizzle))
                               (dims     (second til))
                               (box      (if via-ring (rest dims) dims)))
                          (setf (gethash (cons kernel uname) *tma-resolved*)
                                (list :describes (second d)
                                      :element-type (third til)
                                      :rank (length box)
                                      :box-dims box
                                      :layout (%kernel-param-contiguous-term kernel (second d))
                                      :swizzle swizzle))))
                       (t
                        (log:warn "Endeavor 137: unresolved CUtensorMap descriptor ~a in kernel ~a (describes=~a tile=~a)"
                                  uname kernel d til)))))))))

;;; src/metadata.lisp — generate-implicit-signature: emit :swizzle from the resolved info (was :none).
(defun generate-implicit-signature (sig declared-params)
  "Generates the :implicit-params plist for metadata serialization.  Endeavor 140: the CUtensorMap
   descriptor's :swizzle now comes from *tma-resolved* (:128b for wgmma tiles) instead of hardcoded."
  (declare (ignore declared-params))
  (let ((implicit-args nil)
        (phys-index 0)
        (implicit-params (function-signature-implicit-parameters sig)))
    (dolist (param-def implicit-params)
      (let* ((name (parameter-def-name param-def))
             (type (parameter-def-type param-def))
             (width (get-physical-width type))
             (start phys-index)
             (end (+ phys-index width -1))
             (type-head (when (consp type) (symbol-name (first type)))))
        (cond
          ((and type-head (string-equal type-head "TENSOR-MAP"))
           (let ((info (gethash (cons (function-signature-name sig) name) *tma-resolved*)))
             (push (list :name (string-downcase (symbol-name name))
                         :kind :tensor-map
                         :describes (and (getf info :describes)
                                         (string-downcase (symbol-name (getf info :describes))))
                         :element-type (strip-package-qualifiers (getf info :element-type))
                         :rank (getf info :rank)
                         :box-dims (getf info :box-dims)
                         :layout (or (getf info :layout) :row-major)
                         :swizzle (or (getf info :swizzle) :none)
                         :address-space :global
                         :range (list start end))
                   implicit-args)))
          (t
           (let ((address-space
                   (cond
                     ((and (consp type) (string-equal type-head "CELL") (>= (length type) 3))
                      (nth 2 type))
                     ((and (consp type) (member type-head '("TENSOR" "VECTOR" "MATRIX")
                                                :test #'string-equal)
                           (>= (length type) 4))
                      (nth 3 type))
                     (t :local)))
                 (size-expr (gethash name *implicit-scratch-size-expr-map*)))
             (push (list :name (string-downcase (symbol-name name))
                         :type (strip-package-qualifiers type)
                         :size-expr size-expr
                         :address-space address-space
                         :range (list start end))
                   implicit-args))))
        (incf phys-index width)))
    (nreverse implicit-args)))

;;; Endeavor 140 Step 3: the base-ptr aref is rank-aware — swizzle tiles are TMA-loaded scratch
;;; MATRICES (64xK) so use (~ A 0 0); scatter tiles are flat scratch VECTORS so use (~ A 0).
(defun analyze-wgmma-accumulate (expr env context location)
  "(wgmma-accumulate D A B [:swizzle MODE :k K]).  a/b -> (~ tile 0 0) for a swizzle (matrix) tile or
   (~ tile 0) for a scatter (vector) tile, so codegen's 3rd value is the addrspace(3) base."
  (destructuring-bind (d a b &rest kwargs) (cdr expr)
    (let* ((d-node (analyze-expression d env context (append location '(1))))
           (d-type (semantic-node-type d-node))
           (swz    (getf kwargs :swizzle))
           (aref-a (if swz `(~ ,a 0 0) `(~ ,a 0)))
           (aref-b (if swz `(~ ,b 0 0) `(~ ,b 0))))
      (unless (%wgmma-acc-type-p d-type)
        (error 'crisp-compiler-error
               :message (format nil "wgmma-accumulate: D (1st arg) must be a make-wgmma-accumulator, got type ~a." d-type)
               :source-location location))
      (let ((node (make-semantic-mma-accumulate
                   :type d-type
                   :c-node d-node
                   :a-node (analyze-expression aref-a env context (append location '(2)))
                   :b-node (analyze-expression aref-b env context (append location '(3)))
                   :source-location location)))
        (setf (gethash node *wgmma-node-swizzle*) (list swz (or (getf kwargs :k) 8)))
        node))))

;;; ===========================================================================
;;; Endeavor 140 Step 5 FIX — warp-spec-aware :block TMA leader election.
;;; The load-tile :block TMA/expect_tx was guarded by GLOBAL tid==0, which fires only from thread 0.
;;; In a consumer-first with-warp-specialization, tid 0 is a CONSUMER -> no producer thread issues the
;;; TMA -> `full` never flips -> deadlock (Endeavor-140 root cause).  FIX: inside a warp-spec role block
;;; the producer is a single dedicated warp, so elect LANE 0 of that warp (laneid==0) — the unique
;;; role-local leader — instead of global tid 0.  Outside a role block, keep global tid==0 (all warps
;;; participate; lane-0-per-warp would issue redundant TMAs).  The node is tagged at analysis time when
;;; *in-warp-spec-block* is bound.  This makes consumer-first first-class and removes the producer-first
;;; workaround (and its wasted warps).
;;; ===========================================================================

(defvar *tma-copy-ws-leader* (make-hash-table :test 'eq)
  "semantic-nvvm-tma-tile-copy node -> T when the load-tile :block sits inside a with-warp-specialization
   role block (elect laneid==0 of the producer warp, not global tid==0).")

;; Tag TMA-copy nodes created inside a warp-spec role block (wrapper-capture; no reproduction).
(unless (fboundp 'orig-analyze-nvvm-tma-load-tile-at)
  (setf (fdefinition 'orig-analyze-nvvm-tma-load-tile-at) (fdefinition '%analyze-nvvm-tma-load-tile-at)))
(defun %analyze-nvvm-tma-load-tile-at (expr env context location)
  "Endeavor 140: as the original, plus tag the node WS-leader when analyzed inside a role block."
  (let ((node (funcall 'orig-analyze-nvvm-tma-load-tile-at expr env context location)))
    (when *in-warp-spec-block*
      (setf (gethash node *tma-copy-ws-leader*) t))
    node))

;; Reproduce the TMA-copy codegen (src codegen.lisp:3814) with the role-aware leader election.
(defmethod generate-node-ir ((node semantic-nvvm-tma-tile-copy) builder module var-env
                              di-builder di-scope location-map)
  "Endeavor 137 + 140 — one bulk TMA copy issued by a single elected leader.  Leader = laneid==0 (the
   producer warp's lane 0) inside a warp-spec role block, else global tid==0."
  (multiple-value-bind (dv di dst-ptr)
      (generate-node-ir (semantic-nvvm-tma-tile-copy-dst-aref-node node) builder module var-env
                        di-builder di-scope location-map)
    (declare (ignore dv di))
    (multiple-value-bind (sv si src-ptr)
        (generate-node-ir (semantic-nvvm-tma-tile-copy-src-aref-node node) builder module var-env
                          di-builder di-scope location-map)
      (declare (ignore sv si))
      (unless (and dst-ptr src-ptr)
        (error "nvvm-tma-tile-copy: aref did not yield an element pointer (dst ~A src ~A)" dst-ptr src-ptr))
      (let* ((i32-type   (llvm-int32-type))
             (ptr-as3    (llvm-pointer-type (llvm-int8-type) 3))
             (ptr-gen    (llvm-pointer-type (llvm-int8-type) 0))
             (ptr-glob   (llvm-pointer-type (llvm-int8-type) 1))
             (desc-ptr   (%tma-lookup-descriptor-ptr builder var-env
                          (semantic-nvvm-tma-tile-copy-src-name node) ptr-glob))
             (tmap-ptr   (llvm-build-addrspace-cast builder (or desc-ptr src-ptr) ptr-gen "tma_map"))
             (barrier-i  (generate-node-ir (semantic-nvvm-tma-tile-copy-barrier-node node) builder module var-env
                                           di-builder di-scope location-map))
             (mbar-ptr   (llvm-build-int-to-ptr builder barrier-i ptr-as3 "tma_mbar"))
             (coord-vals (loop for cn in (semantic-nvvm-tma-tile-copy-coord-nodes node)
                               collect (%coerce-to-i32 builder
                                          (generate-node-ir cn builder module var-env
                                                             di-builder di-scope location-map))))
             (coord0     (or (second coord-vals) (llvm-const-int i32-type 0 nil)))
             (coord1     (or (first coord-vals)  (llvm-const-int i32-type 0 nil)))
             ;; Endeavor 140: role-aware leader.  WS role block -> laneid==0 (producer warp's lane 0);
             ;; else global tid==0.
             (ws-leader  (gethash node *tma-copy-ws-leader*))
             (is-leader  (if ws-leader
                             (llvm-build-icmp builder +llvm-int-eq+
                                (%ptx-read-warp-sreg builder module "laneid")
                                (llvm-const-int i32-type 0 nil) "is_lane0")
                             (let* ((tid-x (%gen-nvvm-read-tid-x builder module))
                                    (tid-y (%gen-nvvm-read-tid-y builder module))
                                    (tid-z (%gen-nvvm-read-tid-z builder module))
                                    (tid-sum (llvm-build-add builder (llvm-build-add builder tid-x tid-y "txy") tid-z "txyz")))
                               (llvm-build-icmp builder +llvm-int-eq+ tid-sum
                                  (llvm-const-int i32-type 0 nil) "is_tid_0"))))
             (issue-bb   (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "tma_issue"))
             (cont-bb    (llvm-append-basic-block (llvm-get-basic-block-parent (llvm-get-insert-block builder)) "tma_cont")))
        (llvm-build-cond-br builder is-leader issue-bb cont-bb)
        (llvm-position-builder-at-end builder issue-bb)
        (let* ((len-val   (generate-node-ir (semantic-nvvm-tma-tile-copy-tile-length-node node) builder module var-env
                                            di-builder di-scope location-map))
               (elem-b    (semantic-nvvm-tma-tile-copy-elem-bytes node))
               (len-i32   (%coerce-to-i32 builder len-val))
               (tx-bytes  (llvm-build-mul builder len-i32 (llvm-const-int i32-type elem-b nil) "tma_tx_bytes"))
               (mbar-addr (llvm-build-ptr-to-int builder mbar-ptr i32-type "mbar_addr")))
          (%gen-nvvm-mbarrier-arrive-expect-tx builder mbar-addr tx-bytes))
        (%gen-nvvm-tma-bulk-tensor-g2s-2d builder module dst-ptr mbar-ptr tmap-ptr coord0 coord1)
        (llvm-build-br builder cont-bb)
        (llvm-position-builder-at-end builder cont-bb)
        (values nil nil)))))
