(in-package :crisp.hoist.l0)

;; src/hoist-l0/main.lisp
;;
;; Endeavor 143 fix: the --mma-bench timing loop was measuring nothing.
;;
;; The original emitted N back-to-back zeCommandQueueExecuteCommandLists() calls on the SAME
;; closed command list, followed by a SINGLE zeCommandQueueSynchronize(), on the assumption
;; (see the old comment: "they serialize") that N submits cost N executions.  They do not.
;; Re-submitting a command list that is still in flight is not something L0 guarantees, and
;; the Intel driver coalesces the repeats: a probe on BMG measured a CONSTANT ~3.07 ms of wall
;; time for N = 1, 2, 5, 10, 25, 50 and 100 submits of a 1024^3 GEMM.  Dividing one execution's
;; time by N inflated the reported throughput by exactly N -- at the default 100 iters the
;; intel_prefetch chapter reported 69.65 TFLOPS for a kernel actually running at ~1.4.
;;
;; The replacement measures each launch on its own, using L0 kernel-timestamp events, and
;; reports the MEDIAN.  That is the same methodology already used by the fixed harness in
;; benchmarks/matmul/crisp/bench_harness_l0.cpp (which is why chap0/chap1 were never affected)
;; and by SYCL's command_start/command_end profiling, so Crisp and SYCL_Apples are finally
;; measured the same way.  The BENCH line keeps its original prefix so existing parsers still
;; match, with median_us=/min_us=/method= appended for the ones that want the better number.
;;
;; The CUDA twin (src/hoist-cuda/main.lisp) does NOT have this bug -- it re-issues cuLaunchKernel
;; per iteration on an in-order stream and brackets the loop with CUDA events, which really does
;; execute N times.  No change needed there.
(defun generate-kernel-launch (stream kernel-name declared-sig aliases records &optional dispatch-info)
  "Generate kernel creation and launch code. Returns list of USM allocations.
   Extended to accept dispatch-info plist with :global-size, :local-size, :num-groups.

   Endeavor 143: the --mma-bench block now times each launch individually via L0
   kernel-timestamp events and reports the median, replacing the batched-submit /
   single-sync loop whose repeats the driver coalesced (inflating GFLOPS by ITERS)."
  (format stream "    // Create kernel~%")
  (format stream "    ze_kernel_desc_t kernelDesc = { ZE_STRUCTURE_TYPE_KERNEL_DESC };~%")
  (format stream "    kernelDesc.pKernelName = \"~a\";~%" kernel-name)
  (format stream "    ze_kernel_handle_t kernel;~%")
  (format stream "    result = zeKernelCreate(module, &kernelDesc, &kernel);~%")
  (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
  (format stream "        std::cerr << \"ERROR: zeKernelCreate failed: \" << result << std::endl;~%")
  (format stream "        return 1;~%")
  (format stream "    }~%~%")

  ;; Set kernel arguments if any
  (let ((allocations '()))
    (when declared-sig
          (setf allocations (generate-kernel-arguments-with-usm stream declared-sig aliases records "context" "device" dispatch-info)))

    ;; Create command list and queue
    (format stream "    // Create command list~%")
    (format stream "    ze_command_list_desc_t cmdListDesc = { ZE_STRUCTURE_TYPE_COMMAND_LIST_DESC };~%")
    (format stream "    ze_command_list_handle_t cmdList;~%")
    (format stream "    result = zeCommandListCreate(context, device, &cmdListDesc, &cmdList);~%")
    (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
    (format stream "        std::cerr << \"ERROR: zeCommandListCreate failed: \" << result << std::endl;~%")
    (format stream "        return 1;~%")
    (format stream "    }~%~%")

    (format stream "    // Create command queue~%")
    (format stream "    ze_command_queue_desc_t cmdQueueDesc = { ZE_STRUCTURE_TYPE_COMMAND_QUEUE_DESC };~%")
    (format stream "    ze_command_queue_handle_t cmdQueue;~%")
    (format stream "    result = zeCommandQueueCreate(context, device, &cmdQueueDesc, &cmdQueue);~%")
    (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
    (format stream "        std::cerr << \"ERROR: zeCommandQueueCreate failed: \" << result << std::endl;~%")
    (format stream "        return 1;~%")
    (format stream "    }~%~%")

    ;; Launch kernel — strategy-aware dispatch
    (format stream "    // Launch kernel~%")
    (let ((global-decl (when dispatch-info (getf dispatch-info :global-size)))
          (local-decl (when dispatch-info (getf dispatch-info :local-size)))
          (num-groups-decl (when dispatch-info (getf dispatch-info :num-groups))))
      (%l0-emit-dispatch stream global-decl local-decl num-groups-decl))

    (format stream "    result = zeCommandListAppendLaunchKernel(cmdList, kernel, &groupCount, nullptr, 0, nullptr);~%")
    (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
    (format stream "        std::cerr << \"ERROR: zeCommandListAppendLaunchKernel failed: \" << result << std::endl;~%")
    (format stream "        return 1;~%")
    (format stream "    }~%~%")

    (format stream "    // Close and execute command list~%")
    (format stream "    zeCommandListClose(cmdList);~%")
    (format stream "    zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdList, nullptr);~%")
    (format stream "    zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%~%")

    (format stream "    std::cout << \"Kernel executed successfully\" << std::endl;~%~%")

    ;; Endeavor 142 (Q1) / fixed in 143: per-launch kernel-timestamp timing.  Each iteration is a
    ;; SEPARATE submit + sync of a measurement command list that signals a kernel-timestamp event,
    ;; so every sample is one real execution.  Report the median.  See the overlay header comment
    ;; for why the previous batched-submit loop measured one execution no matter the iteration count.
    (when (and *mma-bench-iters* *mma-test-dims*)
      (destructuring-bind (m n k) *mma-test-dims*
        (format stream "    // --mma-bench: per-launch kernel-timestamp timing (Endeavor 142; fixed 143)~%")
        (format stream "    {~%")
        (format stream "        const int BENCH_ITERS = ~d;~%" *mma-bench-iters*)
        (format stream "        ze_device_properties_t _bmProps = { ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES };~%")
        (format stream "        zeDeviceGetProperties(device, &_bmProps);~%")
        (format stream "        uint64_t _timerRes  = _bmProps.timerResolution;~%")
        (format stream "        uint64_t _validBits = _bmProps.kernelTimestampValidBits;~%")
        (format stream "        uint64_t _clockMask = (_validBits >= 64) ? ~~0ULL : ((1ULL << _validBits) - 1ULL);~%")
        ;; timerResolution is cycles/sec on L0 1.0 and ns/tick from 1.1 on; disambiguate by magnitude
        ;; exactly as bench_harness_l0.cpp does.
        (format stream "        bool _timerInHz = (_timerRes > 1000000ULL);~%~%")

        (format stream "        ze_event_pool_desc_t _poolDesc = { ZE_STRUCTURE_TYPE_EVENT_POOL_DESC };~%")
        (format stream "        _poolDesc.flags = ZE_EVENT_POOL_FLAG_KERNEL_TIMESTAMP;~%")
        (format stream "        _poolDesc.count = 1;~%")
        (format stream "        ze_event_pool_handle_t _pool = nullptr;~%")
        (format stream "        ze_event_handle_t _tsEvent = nullptr;~%")
        (format stream "        ze_command_list_handle_t _measList = nullptr;~%")
        (format stream "        bool _poolOk = (zeEventPoolCreate(context, &_poolDesc, 1, &device, &_pool) == ZE_RESULT_SUCCESS);~%")
        (format stream "        bool _tsOk = _poolOk;~%")
        (format stream "        if (_tsOk) {~%")
        (format stream "            ze_event_desc_t _evDesc = { ZE_STRUCTURE_TYPE_EVENT_DESC };~%")
        (format stream "            _evDesc.index  = 0;~%")
        (format stream "            _evDesc.signal = ZE_EVENT_SCOPE_FLAG_HOST;~%")
        (format stream "            _evDesc.wait   = ZE_EVENT_SCOPE_FLAG_HOST;~%")
        (format stream "            _tsOk = (zeEventCreate(_pool, &_evDesc, &_tsEvent) == ZE_RESULT_SUCCESS);~%")
        (format stream "        }~%")
        (format stream "        if (_tsOk) {~%")
        (format stream "            zeCommandListCreate(context, device, &cmdListDesc, &_measList);~%")
        (format stream "            zeCommandListAppendLaunchKernel(_measList, kernel, &groupCount, _tsEvent, 0, nullptr);~%")
        (format stream "            zeCommandListClose(_measList);~%")
        (format stream "        }~%~%")

        (format stream "        // Warmup: real submit + sync pairs, so caches/clocks settle per execution.~%")
        (format stream "        for (int _w = 0; _w < 20; ++_w) {~%")
        (format stream "            zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdList, nullptr);~%")
        (format stream "            zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
        (format stream "        }~%~%")

        (format stream "        double _kt[BENCH_ITERS];~%")
        (format stream "        int _kn = 0;~%")
        (format stream "        double _total_s = 0.0;~%")
        (format stream "        for (int _it = 0; _it < BENCH_ITERS; ++_it) {~%")
        (format stream "            if (_tsOk) {~%")
        (format stream "                zeEventHostReset(_tsEvent);~%")
        (format stream "                zeCommandQueueExecuteCommandLists(cmdQueue, 1, &_measList, nullptr);~%")
        (format stream "                zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
        (format stream "                zeEventHostSynchronize(_tsEvent, UINT64_MAX);~%")
        (format stream "                ze_kernel_timestamp_result_t _ts = {};~%")
        (format stream "                if (zeEventQueryKernelTimestamp(_tsEvent, &_ts) != ZE_RESULT_SUCCESS) continue;~%")
        (format stream "                uint64_t _s = _ts.context.kernelStart & _clockMask;~%")
        (format stream "                uint64_t _e = _ts.context.kernelEnd   & _clockMask;~%")
        (format stream "                uint64_t _d = (_e >= _s) ? (_e - _s) : (_clockMask + 1 - _s + _e);~%")
        (format stream "                double _ns = _timerInHz ? ((double)_d * 1e9 / (double)_timerRes)~%")
        (format stream "                                        : ((double)_d * (double)_timerRes);~%")
        (format stream "                _kt[_kn++] = _ns / 1000.0;~%")
        (format stream "                _total_s += _ns / 1e9;~%")
        (format stream "            } else {~%")
        (format stream "                // Fallback if timestamp events are unavailable: wall clock around ONE~%")
        (format stream "                // submit + sync.  Includes launch overhead, but is still one execution~%")
        (format stream "                // per sample rather than one execution divided by BENCH_ITERS.~%")
        (format stream "                auto _w0 = std::chrono::high_resolution_clock::now();~%")
        (format stream "                zeCommandQueueExecuteCommandLists(cmdQueue, 1, &cmdList, nullptr);~%")
        (format stream "                zeCommandQueueSynchronize(cmdQueue, UINT64_MAX);~%")
        (format stream "                auto _w1 = std::chrono::high_resolution_clock::now();~%")
        (format stream "                double _ws = std::chrono::duration<double>(_w1 - _w0).count();~%")
        (format stream "                _kt[_kn++] = _ws * 1e6;~%")
        (format stream "                _total_s += _ws;~%")
        (format stream "            }~%")
        (format stream "        }~%~%")

        (format stream "        // Median via insertion sort (BENCH_ITERS is small; avoids an <algorithm> include).~%")
        (format stream "        for (int _i = 1; _i < _kn; ++_i) {~%")
        (format stream "            double _v = _kt[_i]; int _j = _i - 1;~%")
        (format stream "            while (_j >= 0 && _kt[_j] > _v) { _kt[_j + 1] = _kt[_j]; --_j; }~%")
        (format stream "            _kt[_j + 1] = _v;~%")
        (format stream "        }~%")
        (format stream "        double _med_us = (_kn > 0) ? _kt[_kn / 2] : 0.0;~%")
        (format stream "        double _min_us = (_kn > 0) ? _kt[0] : 0.0;~%")
        (format stream "        double _flops = 2.0 * ~d.0 * ~d.0 * ~d.0;~%" m n k)
        (format stream "        double _gflops = (_med_us > 0.0) ? (_flops / (_med_us / 1e6) / 1e9) : 0.0;~%")
        (format stream "        std::cout << \"BENCH ~d ~d ~d \" << _gflops << \" GFLOPS (\" << _kn << \" iters, \" << _total_s << \" s)\"~%" m n k)
        (format stream "                  << \" median_us=\" << _med_us << \" min_us=\" << _min_us~%")
        (format stream "                  << (_tsOk ? \" method=kernel_timestamp\" : \" method=wallclock_per_iter\")~%")
        (format stream "                  << std::endl;~%")
        (format stream "        if (_measList) zeCommandListDestroy(_measList);~%")
        (format stream "        if (_tsEvent)  zeEventDestroy(_tsEvent);~%")
        (format stream "        if (_poolOk)   zeEventPoolDestroy(_pool);~%")
        (format stream "    }~%~%")))

    allocations))

;;; =====================================================================
;;; Endeavor 143 — dispatch geometry for tiled kernels
;;;
;;; MEASURED ON BMG (Arc B580, _hw_threads=640), matmul_bmg_prefetch, tf32, TFLOPS:
;;;
;;;   size    tile grid   current (40,1)   occupancy-clamped     exact tile cover
;;;   1024      32x32          1.40        8.10  (32,20)        10.52  (32,32)
;;;   2048      64x64          1.40        6.26  (64,10)         8.64  (64,64)
;;;   4096    128x128          1.37        4.26  (128,5)         7.46  (128,128)
;;;
;;; Two independent defects, and they do NOT compose:
;;;
;;; 1. AXIS SERIALIZATION (the big one).  `:strided` emitted a 1-D group count
;;;    `{_hw_threads / wg_total, 1, 1}` and ignored :tile-shape entirely.  Under an
;;;    N-D `tile-stride` loop a 1-D grid does not merely under-dispatch — the axes with
;;;    extent 1 are SERIALIZED inside each workgroup.  At 1024 only the 32 column-tiles
;;;    had any parallelism, out of 640 resident hardware threads.  Every result was
;;;    still correct, which is why it survived: tile-stride covers the tiles either way.
;;;
;;; 2. A UNITS ERROR.  `_hw_threads` counts hardware threads, each executing
;;;    physicalEUSimdWidth (16) work-items, but it was divided by the workgroup size in
;;;    WORK-ITEMS.  With local-size 16 one workgroup *is* one hardware thread, so the
;;;    resident capacity is 640 groups and the code emitted 40 — 16x low.
;;;
;;; Measured (640,1,1) == (40,1,1) == 1537 us: fixing #2 alone buys exactly nothing,
;;; because #1 dominates.  Both are fixed below.
;;;
;;; WHY EXACT-COVER RATHER THAN OCCUPANCY.  The occupancy budget is 640 groups; the
;;; exact tile grid at 4096 is 16384 groups — 25x oversubscribed — and it still wins,
;;; by 75%.  The margin WIDENS with size, so there is no crossover to clamp at (up to
;;; 4096, the largest measured).  For tiled kernels "cover the tile grid" beats "fill
;;; the machine".  `:occupancy` remains available as a manual derate.
;;;
;;; AXIS MAPPING: dispatch axis k <- tensor dimension k.  Measured on a NON-SQUARE
;;; 512x2048 problem (16 row-tiles x 64 col-tiles): (16,64) = 12.28 TFLOPS vs
;;; (64,16) = 9.41.  So gx <- extent0 (ROWS), gy <- extent1 (COLS) — the opposite of
;;; the CUDA x=columns convention.  BOTH orderings return MMA_CORRECT; the only symptom
;;; of getting it backwards is 1.31x, so do not "fix" this without re-measuring.

;; src/hoist-l0/main.lisp
(defun %l0-tensor-extent-cpp-var (sym k)
  "Convert a tensor parameter symbol to its C++ extent variable for dimension K.
   The L0 hoist emits 'uint64_t <name>_ext<k> = N;' for each tensor param dimension
   (see generate-kernel-arguments-with-usm).  Companion to %l0-tensor-length-cpp-var,
   which yields the flat length and is therefore useless for rank-N grid geometry."
  (format nil "~a_ext~d" (substitute #\_ #\- (string-downcase (symbol-name sym))) k))

;; src/hoist-l0/main.lisp
(defun %l0-emit-tile-grid-limit-guard (stream can-stride declared-axes)
  "Emit the ze_device_compute_properties_t guard for a tile-grid dispatch.

   DECLARED-AXES is the subset of (var limit label) triples whose group-count variable was
   actually emitted — a rank-2 kernel declares only _gx/_gy, so guarding _gz would not compile.

   CAN-STRIDE distinguishes the two cases, and the distinction is a CORRECTNESS one:

     :strided — the kernel's tile-stride loop covers any tile the grid does not reach, so
                clamping the grid to the device limit is SAFE.  It costs throughput, not
                correctness.  We clamp and warn.
     :exact   — one workgroup per tile, no loop.  A clamped grid would SILENTLY SKIP TILES,
                so exceeding the limit must be a hard error, not a clamp.

   Measured on BMG (Arc B580) 2026-07-26: maxGroupCountX/Y/Z all report UINT32_MAX, so a
   32x32-tile cover would not reach the limit until N ~ 1.4e11.  This guard is therefore
   inert on that part — it is here because exact-cover dispatch made the grid scale with the
   PROBLEM rather than with the hardware, so the bound is now reachable in principle where
   it previously was not, and because the strided/exact split above must not be silent."
  (format stream "    // Device dispatch limits (Endeavor 143).  The tile grid scales with the~%")
  (format stream "    // problem, not the hardware, so bound it by what the device will accept.~%")
  (format stream "    ze_device_compute_properties_t _cmpProps = { ZE_STRUCTURE_TYPE_DEVICE_COMPUTE_PROPERTIES };~%")
  (format stream "    if (zeDeviceGetComputeProperties(device, &_cmpProps) == ZE_RESULT_SUCCESS) {~%")
  (dolist (axis declared-axes)
    (destructuring-bind (var limit label) axis
      (format stream "        if (~a > _cmpProps.~a) {~%" var limit)
      (if can-stride
          (progn
            ;; Safe: the tile-stride loop picks up the remainder.
            (format stream "            std::cerr << \"NOTE: ~a group count \" << ~a << \" exceeds device ~a (\"~%" label var limit)
            (format stream "                      << _cmpProps.~a << \"); clamping — the tile-stride loop covers the rest.\" << std::endl;~%" limit)
            (format stream "            ~a = _cmpProps.~a;~%" var limit))
          (progn
            ;; Unsafe: :exact has no stride loop, so a clamp would drop tiles.
            (format stream "            std::cerr << \"ERROR: ~a group count \" << ~a << \" exceeds device ~a (\"~%" label var limit)
            (format stream "                      << _cmpProps.~a << \"). :strategy :exact has no stride loop, so clamping\"~%" limit)
            (format stream "                      << \" would skip tiles.  Use :strategy :strided for a problem this large.\" << std::endl;~%")
            (format stream "            return 1;~%")))
      (format stream "        }~%")))
  (format stream "    }~%"))

;; src/hoist-l0/main.lisp
(defun %l0-emit-tile-grid-group-count (stream derive-from derive-from-is-tensor tile-shape &optional can-stride)
  "Emit a rank-N ze_group_count_t covering the OUTPUT TILE GRID: one workgroup per tile,
   ceil(extent_k / tile_k) along each axis, with dispatch axis k drawn from dimension k
   of the :derive-from source.

   DERIVE-FROM-IS-TENSOR selects the source of each extent: a tensor contributes
   <name>_ext<k> (per-dimension), a scalar list contributes its k'th parameter.  Note the
   tensor case must NOT use <name>_length — the flat element count carries no shape, and
   dividing it by tile-x is what the old :exact tensor branch did.

   Rank comes from the length of TILE-SHAPE, clamped to the 3 axes L0 dispatches.  Axes
   beyond that rank are the literal 1 in the initializer rather than a declared variable,
   so a rank-2 kernel emits `{ _gx, _gy, 1 }` and carries no unused _gz."
  (let* ((axis-vars '("_gx" "_gy" "_gz"))
         (axis-limits '("maxGroupCountX" "maxGroupCountY" "maxGroupCountZ"))
         (axis-labels '("x" "y" "z"))
         (rank (min (length tile-shape) 3))
         (inits (list "1" "1" "1"))
         (declared '()))
    (format stream "    // :tile-shape ~a — one workgroup per output tile; axis k <- dimension k.~%"
      tile-shape)
    (format stream "    // Endeavor 143: exact tile cover measured strictly better than an~%")
    (format stream "    // occupancy-clamped grid at every size up to 4096 (see overlay notes).~%")
    (dotimes (k rank)
      (let* ((var (nth k axis-vars))
             (tk  (or (nth k tile-shape) 1))
             (src (if derive-from-is-tensor
                      (when (first derive-from)
                        (%l0-tensor-extent-cpp-var (first derive-from) k))
                      (when (nth k derive-from)
                        (%dispatch-sym-to-cpp-var (nth k derive-from))))))
        (when (and src (> tk 0))
          (format stream "    uint32_t ~a = (uint32_t)(((uint64_t)~a + ~d) / ~d);~%"
            var src (1- tk) tk)
          (format stream "    if (~a < 1) ~a = 1;~%" var var)
          (setf (nth k inits) var)
          (push (list var (nth k axis-limits) (nth k axis-labels)) declared))))
    ;; Guard before the initializer, so the clamp/error applies to the values actually used,
    ;; and only over axes we really declared.
    (when declared
      (%l0-emit-tile-grid-limit-guard stream can-stride (nreverse declared)))
    (format stream "    ze_group_count_t groupCount = { ~a, ~a, ~a };~%"
      (first inits) (second inits) (third inits))))

;; src/hoist-l0/main.lisp
(defun %l0-emit-group-count (stream is-strided is-interleaved is-exact is-one-thread-per dispatch-decl set-to derive-from derive-from-is-tensor tile-shape local-x local-y)
  "Emit group count logic for ze_group_count_t groupCount.

   Endeavor 143: when :tile-shape is present on a :strided or :exact kernel, the grid is
   the rank-N tile grid (see %l0-emit-tile-grid-group-count) regardless of strategy —
   :tile-shape now determines grid SHAPE, :strategy only sizing policy along it.  The
   bare :strided path (no tile-shape, e.g. 1-D vector grid-stride) keeps occupancy sizing
   but corrects the hardware-thread/work-item units error described in the overlay notes."
  (cond
   ;; :tile-shape — rank-N tile-grid dispatch.  Takes precedence over the strategy's own
   ;; sizing: a 1-D grid under an N-D tile-stride loop serializes the missing axes.
   ;; CAN-STRIDE = is-strided: only a strided kernel has the tile-stride loop that makes
   ;; clamping the grid safe.  :exact must hard-error instead of silently dropping tiles.
   ((and tile-shape derive-from (or is-strided is-exact))
     (%l0-emit-tile-grid-group-count stream derive-from derive-from-is-tensor tile-shape
                                     is-strided))

   ;; :strided without :tile-shape — occupancy-based 1-D grid (vector grid-stride).
   (is-strided
     (let ((wg-total (* local-x (max 1 local-y))))
       (format stream "    // Occupancy sizing: _hw_threads counts SIMD hardware threads, so~%")
       (format stream "    // convert the workgroup size from work-items to threads before dividing.~%")
       (format stream "    uint32_t _simd_w = _deviceProps.physicalEUSimdWidth ? _deviceProps.physicalEUSimdWidth : 16;~%")
       (format stream "    uint32_t _threads_per_group = (~d + _simd_w - 1) / _simd_w;~%" wg-total)
       (format stream "    if (_threads_per_group < 1) _threads_per_group = 1;~%")
       (format stream "    uint32_t _gx = _hw_threads / _threads_per_group;~%")
       (format stream "    if (_gx < 1) _gx = 1;~%")
       (format stream "    ze_group_count_t groupCount = { _gx, 1, 1 };~%")))

   (is-interleaved
     (format stream "    ze_group_count_t groupCount = { 1, 1, 1 };~%"))

   ((null dispatch-decl)
     (format stream "    ze_group_count_t groupCount = { 1, 1, 1 };~%"))

   ;; :exact with tensor :derive-from and NO tile-shape — flat length / local-x.  Only
   ;; meaningful for rank-1 work; a tiled kernel must declare :tile-shape to get shape.
   ((and is-exact derive-from-is-tensor)
     (let ((tx (if tile-shape (or (first tile-shape) 1) local-x))
           (tensor-var (%l0-tensor-length-cpp-var (first derive-from))))
       (format stream "    uint32_t _gx = ((uint32_t)~a + ~d) / ~d;~%"
         tensor-var (1- tx) tx)
       (format stream "    ze_group_count_t groupCount = { _gx, 1, 1 };~%")))

   ;; :exact with scalar derive-from list
   (is-exact
     (let* ((d0 (first derive-from))
            (d1 (second derive-from))
            (d2 (third derive-from))
            (tx (if tile-shape (or (first tile-shape) 1) local-x))
            (ty (if tile-shape (or (second tile-shape) 1) (if (> local-y 1) local-y 1))))
       (when d0
             (format stream "    uint32_t _gx = ((uint32_t)~a + ~a) / ~a;~%"
               (%dispatch-sym-to-cpp-var d0) (1- tx) tx))
       (when d1
             (format stream "    uint32_t _gy = ((uint32_t)~a + ~a) / ~a;~%"
               (%dispatch-sym-to-cpp-var d1) (1- ty) ty))
       (when d2
             (format stream "    uint32_t _gz = ((uint32_t)~a + 0) / 1;~%"
               (%dispatch-sym-to-cpp-var d2)))
       (format stream "    ze_group_count_t groupCount = { ~a, ~a, ~a };~%"
         (if d0 "_gx" "1")
         (if d1 "_gy" "1")
         (if d2 "_gz" "1"))))

   ;; :one-thread-per with tensor :derive-from
   ((and is-one-thread-per derive-from-is-tensor)
     (let ((tensor-var (%l0-tensor-length-cpp-var (first derive-from))))
       (if (> local-x 1)
           (format stream "    ze_group_count_t groupCount = { ((uint32_t)~a + ~d) / ~d, 1, 1 };~%"
             tensor-var (1- local-x) local-x)
           (format stream "    ze_group_count_t groupCount = { (uint32_t)~a, 1, 1 };~%"
             tensor-var))))

   ((integerp set-to)
     (let ((g0 (%l0-dim-to-gc set-to local-x)))
       (format stream "    ze_group_count_t groupCount = { ~a, 1, 1 };~%" g0)))

   ;; :set-to list OR :derive-from (scalar list)
   (t
     (let* ((dims (cond
                   ((consp set-to) set-to)
                   (derive-from derive-from)
                   (t nil)))
            (d0 (first dims))
            (d1 (second dims))
            (d2 (third dims))
            (g0 (%l0-dim-to-gc d0 local-x))
            (g1 (%l0-dim-to-gc d1 (if (> local-y 1) local-y 1)))
            (g2 (%l0-dim-to-gc d2 1)))
       (format stream "    ze_group_count_t groupCount = { ~a, ~a, ~a };~%" g0 g1 g2)))))

;; src/hoist-l0/main.lisp
;;
;; Endeavor 143 follow-up: when :tile-shape drives the grid, do NOT emit the occupancy preamble.
;; %l0-emit-group-count's tile-grid branch ignores _hw_threads entirely, so emitting it left an
;; unused variable in the generated C++ underneath a comment reading "grid uses occupancy" —
;; directly above a grid that does not use occupancy.  That is the same species of comment/code
;; drift that sent us chasing zeDeviceGetComputeProperties for hours, so it gets fixed rather
;; than tolerated.  The preamble is still emitted for a bare :strided kernel (no tile-shape),
;; which genuinely needs _hw_threads.
(defun %l0-emit-dispatch (stream global-decl local-decl num-groups-decl)
  "Emit zeKernelSetGroupSize and ze_group_count_t based on dispatch declarations.
   Supports:
     :strategy :strided        — max occupancy (zeDeviceGetProperties +
                                 optional zeKernelGetProperties)
     :strategy :one-thread-per — grid sized to derive-from source
     :strategy :exact          — grid sized via derive-from / local-size (or tile-shape if present)
     :strategy :interleaved    — not yet implemented (default dispatch)
   :set-to scalar/list       — fixed grid
   :derive-from can be a single tensor symbol (uses <name>_length) or a list
   of scalar parameter names (uses <name>_arg).

   Endeavor 143: a :tile-shape on a :strided/:exact kernel makes the grid the rank-N tile grid,
   so the occupancy preamble is suppressed in that case — it would be dead code."
  (let* ((ls-rest (when local-decl (cdr local-decl)))
         (ls-set-to (when ls-rest (getf ls-rest :set-to)))
         (local-x (cond
                   ((integerp ls-set-to) ls-set-to)
                   ((and (listp ls-set-to) (first ls-set-to)) (first ls-set-to))
                   (t 1)))
         (local-y (cond
                   ((and (listp ls-set-to) (second ls-set-to)) (second ls-set-to))
                   (t 1)))

         (dispatch-decl (or global-decl num-groups-decl))
         (disp-rest (when dispatch-decl (cdr dispatch-decl)))
         (strategy (when disp-rest (getf disp-rest :strategy)))
         (strat-name (when strategy (symbol-name strategy)))

         (is-strided (and strat-name (string-equal strat-name "STRIDED")))
         (is-exact (and strat-name (string-equal strat-name "EXACT")))
         (is-interleaved (and strat-name (string-equal strat-name "INTERLEAVED")))
         (is-one-thread-per (and strat-name (string-equal strat-name "ONE-THREAD-PER")))

         (set-to (when disp-rest (getf disp-rest :set-to)))
         (raw-derive-from (when disp-rest (getf disp-rest :derive-from)))
         (derive-from-is-tensor (%l0-derive-from-is-tensor-p raw-derive-from))
         (derive-from (%l0-normalize-derive-from raw-derive-from))
         (tile-shape (when disp-rest (getf disp-rest :tile-shape)))
         (occupancy (when disp-rest (getf disp-rest :occupancy)))
         ;; True when %l0-emit-group-count will take the tile-grid branch below.
         (tile-grid-p (and tile-shape derive-from (or is-strided is-exact))))

    (%l0-emit-occupancy-and-strategy stream
                                     (and is-strided (not tile-grid-p))
                                     is-interleaved occupancy
                                     derive-from-is-tensor derive-from)

    (let ((wg-x (format nil "~a" local-x))
          (wg-y (format nil "~a" local-y)))

      (format stream "    // Set group (workgroup) size~%")
      (format stream "    result = zeKernelSetGroupSize(kernel, ~a, ~a, 1);~%" wg-x wg-y)
      (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
      (format stream "        std::cerr << \"ERROR: zeKernelSetGroupSize failed: \" << result << std::endl;~%")
      (format stream "        return 1;~%")
      (format stream "    }~%~%")

      (format stream "    // Compute dispatch group count~%")
      (%l0-emit-group-count stream is-strided is-interleaved is-exact is-one-thread-per
                            dispatch-decl set-to derive-from derive-from-is-tensor tile-shape
                            local-x local-y))))
