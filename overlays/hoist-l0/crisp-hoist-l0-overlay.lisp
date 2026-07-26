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
