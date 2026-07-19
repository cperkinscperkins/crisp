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
