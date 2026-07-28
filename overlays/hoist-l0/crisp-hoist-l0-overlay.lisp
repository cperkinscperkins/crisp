(in-package :crisp.hoist.l0)

;;; ===================================================================
;;; ENDEAVOR 144 Phase 4 Step 4 — ask IGC for the register allocation the
;;; compiler selected.
;;;
;;; MEASURED: all three BMG benchmark kernels were spilling (intel_prefetch 1792 B,
;;; chap0_sync 2560 B, chap1_async_linear 2752 B) purely because the generated launcher
;;; hardcoded `nullptr` for ze_module_desc_t.pBuildFlags, leaving IGC in its default
;;; 128-GRF mode for kernels that demand 256.  Passing `-ze-opt-large-register-file`
;;; takes spill to 0 on all three and runs 1.5-2.07x faster (24.01 vs 11.61 TFLOPS at
;;; 1024 on a B580), verified MMA_CORRECT.
;;;
;;; The compiler decides (it owns the register-demand model); the hoist only transcribes.
;;; The decision arrives as :selected-registers-per-thread inside the metacrisp's
;;; (:hardware-profile ...) form.
;;;
;;; NOTE FOR THE SRC PATCH — these two definitions belong in DIFFERENT files:
;;;   %l0-note-hardware-profile + parse-metacrisp-file  -> src/hoist/common.lisp
;;;   generate-module-loading                           -> src/hoist-l0/main.lisp
;;; They are together here only because overlays/hoist-common/ is not loaded by any build
;;; script, so the hoist-l0 overlay is the only late-binding hook that reaches both.
;;; ===================================================================

;; src/hoist-l0/main.lisp
(defvar *l0-selected-registers-per-thread* nil
  "Endeavor 144 Phase 4: the per-thread register allocation the COMPILER selected for this
   module, read from the metacrisp's (:hardware-profile ... :selected-registers-per-thread N).
   NIL when no profile was active or no kernel needed more than the default allocation.
   Consumed by generate-module-loading to set ze_module_desc_t.pBuildFlags.")

;; src/hoist-l0/main.lisp
(defvar *l0-register-modes* nil
  "Endeavor 144 Phase 4: the profile's selectable :max-registers-per-thread modes (a list),
   so the hoist can tell whether the selected allocation IS the default (emit nothing) or a
   larger mode (emit the IGC flag).")

;; src/hoist/common.lisp
(in-package :crisp.hoist)

(defun parse-metacrisp-file (filepath)
  "Parse a .metacrisp file and return the data structure.

   Endeavor 144 Phase 4: also latches the active profile's register-allocation decision
   into crisp.hoist.l0::*l0-selected-registers-per-thread* / *l0-register-modes*, so the
   L0 module build can request it.  Latching here (rather than threading the profile
   through generate-l0-launcher) keeps the change to two small functions."
  (with-open-file (stream filepath :direction :input)
    (let ((aliases '())
          (structs '())
          (records '())
          (kernels '())
          (hardware-profile nil))
      ;; Read all forms from the file
      (loop for form = (read stream nil :eof)
            until (eq form :eof)
            do (cond
                ((and (consp form) (eq (first form) :aliases))
                  (setf aliases (or (rest form) '())))
                ((and (consp form) (eq (first form) :structs))
                  (setf structs (or (rest form) '())))
                ((and (consp form) (eq (first form) :records))
                  (setf records (or (rest form) '())))
                ((and (consp form) (eq (first form) :kernels))
                  (setf kernels (or (rest form) '())))
                ;; Endeavor 130 Phase 5: the active hardware profile (only the
                ;; selected one) travels in as (:hardware-profile (:name "X" ...)).
                ((and (consp form) (eq (first form) :hardware-profile))
                  (setf hardware-profile (second form)))))
      ;; Endeavor 144 Phase 4: latch the register decision for the L0 module build.
      (let ((modes (getf hardware-profile :max-registers-per-thread))
            (sel   (getf hardware-profile :selected-registers-per-thread)))
        (setf (symbol-value (find-symbol "*L0-REGISTER-MODES*" :crisp.hoist.l0))
              (if (listp modes) modes (and modes (list modes))))
        (setf (symbol-value (find-symbol "*L0-SELECTED-REGISTERS-PER-THREAD*" :crisp.hoist.l0))
              sel))
      ;; Return as plist for easy access
      (list :aliases aliases :structs structs :records records :kernels kernels
            :hardware-profile hardware-profile))))

;; src/hoist-l0/main.lisp
(in-package :crisp.hoist.l0)

(defun %l0-register-build-flags ()
  "Endeavor 144 Phase 4: the IGC build-flag string for the compiler-selected register
   allocation, or NIL when nothing needs to be requested.

   Emits `-ze-opt-large-register-file` only when the selected allocation is ABOVE the
   profile's default (first) mode.  Returning NIL for the default case matters: large-GRF
   is not free — it halves threads-per-EU — so it must be requested only for kernels whose
   register demand actually exceeds the default allocation."
  (let ((sel   *l0-selected-registers-per-thread*)
        (modes *l0-register-modes*))
    (when (and sel modes (> sel (first modes)))
      "-ze-opt-large-register-file")))

;; src/hoist-l0/main.lisp
(defun generate-module-loading (stream spv-path)
  "Generate SPIR-V module loading code.

   Endeavor 144 Phase 4: pBuildFlags now carries the compiler-selected register allocation
   (see %l0-register-build-flags) instead of being unconditionally nullptr."
  (format stream "    // Load SPIR-V module~%")
  (format stream "    const char* spv_path = \"~a\";~%" (namestring spv-path))
  (format stream "    std::vector<uint8_t> spirv_data;~%")
  (format stream "    try {~%")
  (format stream "        spirv_data = read_spirv_file(spv_path);~%")
  (format stream "    } catch (const std::exception& e) {~%")
  (format stream "        std::cerr << \"ERROR: \" << e.what() << std::endl;~%")
  (format stream "        return 1;~%")
  (format stream "    }~%~%")

  (let ((flags (%l0-register-build-flags)))
    (when flags
      (format stream "    // Endeavor 144: the kernel's register-tile demand (~a registers/thread)~%"
              *l0-selected-registers-per-thread*)
      (format stream "    // exceeds this target's default allocation (~a), so ask IGC for the larger~%"
              (first *l0-register-modes*))
      (format stream "    // register file.  Without this the JIT spills instead (measured 1.5-2x slower).~%")
      (format stream "    const char* _buildFlags = \"~a\";~%" flags))

    (format stream "    ze_module_desc_t moduleDesc = {~%")
    (format stream "        ZE_STRUCTURE_TYPE_MODULE_DESC,~%")
    (format stream "        nullptr,~%")
    (format stream "        ZE_MODULE_FORMAT_IL_SPIRV,~%")
    (format stream "        spirv_data.size(),~%")
    (format stream "        spirv_data.data(),~%")
    (format stream "        ~a,~%" (if flags "_buildFlags" "nullptr"))
    (format stream "        nullptr~%")
    (format stream "    };~%~%"))

  (format stream "    ze_module_handle_t module;~%")
  (format stream "    result = zeModuleCreate(context, device, &moduleDesc, &module, nullptr);~%")
  (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
  (format stream "        std::cerr << \"ERROR: zeModuleCreate failed: \" << result << std::endl;~%")
  (format stream "        return 1;~%")
  (format stream "    }~%")
  (format stream "    std::cout << \"Module loaded successfully\" << std::endl;~%~%"))


;;; ===================================================================
;;; ENDEAVOR 144 Phase 6 — :compute-units on the L0 launcher.
;;;
;;; Endeavor 130 Phase 5 wired :compute-units into the CUDA launcher (`int _numSMs = N;`
;;; replacing the SM query) but DEFERRED the Intel half, because CUDA has one obvious
;;; "compute unit" and Intel does not: the L0 occupancy formula is
;;;     numSlices x numSubslicesPerSlice x numEUsPerSubslice x numThreadsPerEU
;;; and it was left open whether :compute-units should mean subslices, Xe-cores, or a
;;; separate Intel-specific key.  (Left "until we actually benchmark on BMG" — done now.)
;;;
;;; DECISION (2026-07-28, made unattended under standing authorization; rationale here so it
;;; can be reversed knowingly):  **:compute-units means Xe-cores** on Intel, i.e. it replaces
;;; the `numSlices * numSubslicesPerSlice` product.  numEUsPerSubslice and numThreadsPerEU stay
;;; QUERIED.
;;;
;;; Why that split:
;;;   - It is the same SEMANTIC as CUDA's SM count — "how many independent compute units may I
;;;     use" — so one key means one thing on both backends, which is the whole point of a
;;;     vendor-neutral profile.
;;;   - The queried terms are MICRO-ARCHITECTURAL (how an Xe-core is built internally).  A user
;;;     shrinking a profile is expressing "I only get part of the machine", which is a statement
;;;     about how many cores they get, never about EU internals.
;;;   - It makes topology.md's "shrunken profile" / Empty Room Fallacy case actually work:
;;;     :compute-units 10 on a 20-Xe-core B580 yields exactly half the threads.
;;;   - Device-queried B580 confirms the arithmetic: 5 slices x 4 subslices = 20 Xe-cores, and
;;;     20 x 8 EUs x 8 threads = 1280 = the value the unmodified formula produces.  So a
;;;     FULL-SIZE profile is a no-op, which is the correctness property we want.
;;;
;;; Scope note: this only affects the `:strided` occupancy path.  Endeavor 143 showed tiled
;;; kernels do better with exact tile cover (`:tile-shape`), which never consults _hw_threads —
;;; so matmul is unaffected and the consumers are vector/reduction-shaped kernels.
;;; ===================================================================

(in-package :crisp.hoist.l0)

;; src/hoist-l0/main.lisp
(defvar *l0-compute-units* nil
  "Endeavor 144 Phase 6: the active profile's :compute-units (Xe-cores on Intel), or NIL.
   Latched by parse-metacrisp-file; consumed by %l0-emit-occupancy-and-strategy to replace the
   queried numSlices*numSubslicesPerSlice product.")

;; src/hoist/common.lisp
(in-package :crisp.hoist)

(defun parse-metacrisp-file (filepath)
  "Parse a .metacrisp file and return the data structure.

   Endeavor 144: also latches the active profile's register-allocation decision (Phase 4) and
   :compute-units (Phase 6) into crisp.hoist.l0 specials, so the L0 emitters can consult them
   without threading the profile through generate-l0-launcher."
  (with-open-file (stream filepath :direction :input)
    (let ((aliases '())
          (structs '())
          (records '())
          (kernels '())
          (hardware-profile nil))
      (loop for form = (read stream nil :eof)
            until (eq form :eof)
            do (cond
                ((and (consp form) (eq (first form) :aliases))
                  (setf aliases (or (rest form) '())))
                ((and (consp form) (eq (first form) :structs))
                  (setf structs (or (rest form) '())))
                ((and (consp form) (eq (first form) :records))
                  (setf records (or (rest form) '())))
                ((and (consp form) (eq (first form) :kernels))
                  (setf kernels (or (rest form) '())))
                ((and (consp form) (eq (first form) :hardware-profile))
                  (setf hardware-profile (second form)))))
      (let ((modes (getf hardware-profile :max-registers-per-thread))
            (sel   (getf hardware-profile :selected-registers-per-thread))
            (cus   (getf hardware-profile :compute-units)))
        (setf (symbol-value (find-symbol "*L0-REGISTER-MODES*" :crisp.hoist.l0))
              (if (listp modes) modes (and modes (list modes))))
        (setf (symbol-value (find-symbol "*L0-SELECTED-REGISTERS-PER-THREAD*" :crisp.hoist.l0))
              sel)
        (setf (symbol-value (find-symbol "*L0-COMPUTE-UNITS*" :crisp.hoist.l0))
              cus))
      (list :aliases aliases :structs structs :records records :kernels kernels
            :hardware-profile hardware-profile))))

;; src/hoist-l0/main.lisp
(in-package :crisp.hoist.l0)

(defun %l0-emit-occupancy-and-strategy (stream is-strided is-interleaved occupancy derive-from-is-tensor derive-from)
  "Emit strategy descriptions and max-occupancy calculation.

   Endeavor 144 Phase 6: when a hardware profile supplies :compute-units, it REPLACES the
   queried numSlices*numSubslicesPerSlice (Xe-core count) in the occupancy formula; the
   per-Xe-core terms stay queried.  See the decision block above."
  (when is-strided
        (let ((ratio (cond ((null occupancy) 1.0)
                           ((numberp occupancy) (float occupancy))
                           (t 1.0))))
          (format stream "    // Strategy: :strided — max occupancy~%")
          (format stream "    ze_device_properties_t _deviceProps = { ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES };~%")
          (format stream "    zeDeviceGetProperties(device, &_deviceProps);~%")
          (if *l0-compute-units*
              (progn
                (format stream "    // Endeavor 144 Phase 6: hardware profile active — :compute-units (~a Xe-cores)~%"
                        *l0-compute-units*)
                (format stream "    //   replaces the queried numSlices*numSubslicesPerSlice; EUs/core and~%")
                (format stream "    //   threads/EU remain queried (micro-architectural, not user-shrinkable).~%")
                (format stream "    uint32_t _xe_cores = ~d;~%" *l0-compute-units*)
                (format stream "    uint32_t _hw_threads = _xe_cores * _deviceProps.numEUsPerSubslice * _deviceProps.numThreadsPerEU;~%"))
              (format stream "    uint32_t _hw_threads = _deviceProps.numSlices * _deviceProps.numSubslicesPerSlice * _deviceProps.numEUsPerSubslice * _deviceProps.numThreadsPerEU;~%"))
          (format stream "    // Refine with kernel resource footprint (privateMemSize, spillMemSize)~%")
          (format stream "    ze_kernel_properties_t _kernelProps = { ZE_STRUCTURE_TYPE_KERNEL_PROPERTIES };~%")
          (format stream "    zeKernelGetProperties(kernel, &_kernelProps);~%")
          (format stream "    // Derate occupancy by 2x if kernel spilled to private memory~%")
          (format stream "    if (_kernelProps.spillMemSize > 0) { _hw_threads /= 2; }~%")
          (unless (= ratio 1.0)
            (format stream "    // :occupancy ~a — user-requested derate from max~%" occupancy)
            (format stream "    _hw_threads = (uint32_t)(_hw_threads * ~f);~%" ratio)
            (format stream "    if (_hw_threads < 1) _hw_threads = 1;~%"))
          (when derive-from-is-tensor
                (format stream "    // :derive-from tensor '~a' (length=~a) used for check-thread-bounds; grid uses occupancy~%"
                  (first derive-from) (%l0-tensor-length-cpp-var (first derive-from))))
          (format stream "~%")))

  (when is-interleaved
        (format stream "    // Strategy: :interleaved not yet implemented — using default dispatch~%")))
