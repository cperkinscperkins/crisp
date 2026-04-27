(in-package :crisp.hoist.l0)

;; Overlay file for crisp-hoist-l0
;; Add late-binding fixes here as needed


;;; =========================================================
;;; 089-strategy: dispatch code generation helpers
;;; =========================================================

(defun %dispatch-sym-to-cpp-var (sym)
  "Convert a dispatch param symbol (e.g. 'WIDTH or 'width) to C++ variable name 'width_arg'."
  (format nil "~a_arg" (substitute #\_ #\- (string-downcase (symbol-name sym)))))

(defun %l0-emit-dispatch (stream global-decl local-decl num-groups-decl)
  "Emit zeKernelSetGroupSize and ze_group_count_t based on dispatch declarations.
   Handles: :set-to scalar/list, :derive-from with :one-thread-per/:strided/:tiled/:interleaved."
  ;; Determine local size integers (for ceil math)
  (let* ((ls-rest (when local-decl (cdr local-decl)))
         (ls-set-to (when ls-rest (getf ls-rest :set-to)))
         (local-x (cond
                    ((integerp ls-set-to) ls-set-to)
                    ((and (listp ls-set-to) (first ls-set-to)) (first ls-set-to))
                    (t 1)))
         (local-y (cond
                    ((and (listp ls-set-to) (second ls-set-to)) (second ls-set-to))
                    (t 1)))

         ;; Active dispatch declaration (global-size or num-groups)
         (dispatch-decl (or global-decl num-groups-decl))
         (disp-rest (when dispatch-decl (cdr dispatch-decl)))
         (strategy (when disp-rest (getf disp-rest :strategy)))
         (strat-name (when strategy (symbol-name strategy)))

         (is-strided      (and strat-name (string-equal strat-name "STRIDED")))
         (is-tiled        (and strat-name (string-equal strat-name "TILED")))
         (is-interleaved  (and strat-name (string-equal strat-name "INTERLEAVED")))
         (is-one-per      (and strat-name (string-equal strat-name "ONE-THREAD-PER")))

         (set-to      (when disp-rest (getf disp-rest :set-to)))
         (derive-from (when disp-rest (getf disp-rest :derive-from)))
         (tile-shape  (when disp-rest (getf disp-rest :tile-shape))))

    ;; Emit hardware query for :strided
    (when is-strided
      (format stream "    // Strategy: strided — query hardware compute properties~%")
      (format stream "    ze_device_compute_properties_t _computeProps = { ZE_STRUCTURE_TYPE_DEVICE_COMPUTE_PROPERTIES };~%")
      (format stream "    zeDeviceGetComputeProperties(device, &_computeProps);~%")
      (format stream "    uint32_t _hw_threads = _computeProps.numSubslices * _computeProps.numEUsPerSubslice * _computeProps.numThreadsPerEU;~%~%"))

    ;; Emit :interleaved fallback comment
    (when is-interleaved
      (format stream "    // Strategy: :interleaved not yet implemented — using default dispatch~%"))

    ;; Compute workgroup (local) size strings for zeKernelSetGroupSize
    (let ((wg-x (if is-tiled
                    (format nil "~a" (or (first tile-shape) 1))
                    (format nil "~a" local-x)))
          (wg-y (if is-tiled
                    (format nil "~a" (or (second tile-shape) 1))
                    (format nil "~a" local-y))))

      ;; zeKernelSetGroupSize
      (format stream "    // Set group (workgroup) size~%")
      (format stream "    result = zeKernelSetGroupSize(kernel, ~a, ~a, 1);~%" wg-x wg-y)
      (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
      (format stream "        std::cerr << \"ERROR: zeKernelSetGroupSize failed: \" << result << std::endl;~%")
      (format stream "        return 1;~%")
      (format stream "    }~%~%")

      ;; Compute and emit group count
      (format stream "    // Compute dispatch group count~%")

      ;; Helper: convert one dimension (integer or symbol) → C++ group-count expression
      ;; accounting for local size (for ceil math when local > 1)
      (flet ((dim-to-gc (dim local-val)
               (cond
                 ((null dim) "1")
                 ((integerp dim)
                  ;; Literal global size
                  (if (> local-val 1)
                      (format nil "(~a + ~a) / ~a" dim (1- local-val) local-val)
                      (format nil "~a" dim)))
                 ((symbolp dim)
                  ;; Runtime param: use _arg var
                  (let ((cpp-var (%dispatch-sym-to-cpp-var dim)))
                    (if (> local-val 1)
                        (format nil "((uint32_t)~a + ~a) / ~a" cpp-var (1- local-val) local-val)
                        (format nil "(uint32_t)~a" cpp-var))))
                 (t "1"))))

        (cond
          ;; :strided — hardware-determined group count
          (is-strided
           (format stream "    ze_group_count_t groupCount = { _hw_threads, 1, 1 };~%"))

          ;; :interleaved — fallback default
          (is-interleaved
           (format stream "    ze_group_count_t groupCount = { 1, 1, 1 };~%"))

          ;; No dispatch info — default
          ((null dispatch-decl)
           (format stream "    ze_group_count_t groupCount = { 1, 1, 1 };~%"))

          ;; :tiled — ceil(dim / tile) per dimension
          (is-tiled
           (let* ((d0 (first derive-from))
                  (d1 (second derive-from))
                  (d2 (third derive-from))
                  (tx (or (first tile-shape) 1))
                  (ty (or (second tile-shape) 1)))
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

          ;; :set-to scalar integer
          ((integerp set-to)
           (let ((g0 (dim-to-gc set-to local-x)))
             (format stream "    ze_group_count_t groupCount = { ~a, 1, 1 };~%" g0)))

          ;; :set-to list of dims  OR  :derive-from with any strategy (one-thread-per, etc.)
          (t
           (let* ((dims (cond
                          ;; :set-to (d0 d1 ...)
                          ((listp set-to) set-to)
                          ;; :derive-from (d0 d1 ...)
                          (derive-from derive-from)
                          (t nil)))
                  (d0 (first dims))
                  (d1 (second dims))
                  (d2 (third dims))
                  (g0 (dim-to-gc d0 local-x))
                  (g1 (dim-to-gc d1 (if (> local-y 1) local-y 1)))
                  (g2 (dim-to-gc d2 1)))
             (format stream "    ze_group_count_t groupCount = { ~a, ~a, ~a };~%" g0 g1 g2))))))))


;;; src/hoist-l0/main.lisp (v2 — fix (listp nil) = T bug in dims cond)
;; Bug: (cond ((listp set-to) set-to) ...) when set-to=NIL: (listp nil)=T so dims=nil,
;; all group-count dims become "1". Fix: use (consp set-to) which returns NIL for nil.
(defun %l0-emit-dispatch (stream global-decl local-decl num-groups-decl)
  "Emit zeKernelSetGroupSize and ze_group_count_t based on dispatch declarations.
   Handles: :set-to scalar/list, :derive-from with :one-thread-per/:strided/:tiled/:interleaved."
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

         (is-strided      (and strat-name (string-equal strat-name "STRIDED")))
         (is-tiled        (and strat-name (string-equal strat-name "TILED")))
         (is-interleaved  (and strat-name (string-equal strat-name "INTERLEAVED")))

         (set-to      (when disp-rest (getf disp-rest :set-to)))
         (derive-from (when disp-rest (getf disp-rest :derive-from)))
         (tile-shape  (when disp-rest (getf disp-rest :tile-shape))))

    (when is-strided
      (format stream "    // Strategy: strided — query hardware compute properties~%")
      (format stream "    ze_device_compute_properties_t _computeProps = { ZE_STRUCTURE_TYPE_DEVICE_COMPUTE_PROPERTIES };~%")
      (format stream "    zeDeviceGetComputeProperties(device, &_computeProps);~%")
      (format stream "    uint32_t _hw_threads = _computeProps.numSubslices * _computeProps.numEUsPerSubslice * _computeProps.numThreadsPerEU;~%~%"))

    (when is-interleaved
      (format stream "    // Strategy: :interleaved not yet implemented — using default dispatch~%"))

    (let ((wg-x (if is-tiled
                    (format nil "~a" (or (first tile-shape) 1))
                    (format nil "~a" local-x)))
          (wg-y (if is-tiled
                    (format nil "~a" (or (second tile-shape) 1))
                    (format nil "~a" local-y))))

      (format stream "    // Set group (workgroup) size~%")
      (format stream "    result = zeKernelSetGroupSize(kernel, ~a, ~a, 1);~%" wg-x wg-y)
      (format stream "    if (result != ZE_RESULT_SUCCESS) {~%")
      (format stream "        std::cerr << \"ERROR: zeKernelSetGroupSize failed: \" << result << std::endl;~%")
      (format stream "        return 1;~%")
      (format stream "    }~%~%")

      (format stream "    // Compute dispatch group count~%")

      (flet ((dim-to-gc (dim local-val)
               (cond
                 ((null dim) "1")
                 ((integerp dim)
                  (if (> local-val 1)
                      (format nil "(~a + ~a) / ~a" dim (1- local-val) local-val)
                      (format nil "~a" dim)))
                 ((symbolp dim)
                  (let ((cpp-var (%dispatch-sym-to-cpp-var dim)))
                    (if (> local-val 1)
                        (format nil "((uint32_t)~a + ~a) / ~a" cpp-var (1- local-val) local-val)
                        (format nil "(uint32_t)~a" cpp-var))))
                 (t "1"))))

        (cond
          (is-strided
           (format stream "    ze_group_count_t groupCount = { _hw_threads, 1, 1 };~%"))

          (is-interleaved
           (format stream "    ze_group_count_t groupCount = { 1, 1, 1 };~%"))

          ((null dispatch-decl)
           (format stream "    ze_group_count_t groupCount = { 1, 1, 1 };~%"))

          (is-tiled
           (let* ((d0 (first derive-from))
                  (d1 (second derive-from))
                  (d2 (third derive-from))
                  (tx (or (first tile-shape) 1))
                  (ty (or (second tile-shape) 1)))
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

          ((integerp set-to)
           (let ((g0 (dim-to-gc set-to local-x)))
             (format stream "    ze_group_count_t groupCount = { ~a, 1, 1 };~%" g0)))

          ;; :set-to list OR :derive-from
          ;; FIXED: use (consp set-to) not (listp set-to) — (listp nil)=T would
          ;; wrongly pick set-to=nil over derive-from when :set-to is absent.
          (t
           (let* ((dims (cond
                          ((consp set-to) set-to)
                          (derive-from derive-from)
                          (t nil)))
                  (d0 (first dims))
                  (d1 (second dims))
                  (d2 (third dims))
                  (g0 (dim-to-gc d0 local-x))
                  (g1 (dim-to-gc d1 (if (> local-y 1) local-y 1)))
                  (g2 (dim-to-gc d2 1)))
             (format stream "    ze_group_count_t groupCount = { ~a, ~a, ~a };~%" g0 g1 g2))))))))

;;; src/hoist-l0/main.lisp
(defun generate-kernel-launch (stream kernel-name declared-sig aliases records &optional dispatch-info)
  "Generate kernel creation and launch code. Returns list of USM allocations.
   Extended to accept dispatch-info plist with :global-size, :local-size, :num-groups."
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
          (setf allocations (generate-kernel-arguments-with-usm stream declared-sig aliases records "context" "device")))

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
          (local-decl  (when dispatch-info (getf dispatch-info :local-size)))
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

    allocations))


;;; src/hoist-l0/main.lisp
(defun generate-cpp-main (stream kernel-name spv-path declared-sig aliases records &optional dispatch-info)
  "Generate C++ main function. Extended to accept dispatch-info for strategy-aware launch."
  (format stream "int main() {~%")
  (format stream "    ze_result_t result;~%")
  (format stream "    std::cout << \"Level Zero Launcher for kernel: ~a\" << std::endl;~%~%" kernel-name)

  ;; L0 Initialization
  (generate-l0-init stream)

  ;; Module loading
  (when spv-path
        (generate-module-loading stream spv-path))

  ;; Kernel creation and launch
  (let ((allocations (generate-kernel-launch stream kernel-name declared-sig aliases records dispatch-info)))

    ;; Print output buffers
    (format stream "    // Verify Output~%")
    (dolist (alloc allocations)
      (let ((name (getf alloc :name))
            (ptr (getf alloc :ptr))
            (size-v (getf alloc :size-var))
            (dir (getf alloc :direction))
            (access (getf alloc :access)))
        (declare (ignore dir access))

        (format stream "    std::cout << \"BUFFER ~a: \";~%" name)
        (format stream "    for (size_t i = 0; i < ~a; i++) {~%" size-v)
        (format stream "        std::cout << ~a[i] << (i == ~a - 1 ? \"\" : \" \");~%" ptr size-v)
        (format stream "    }~%")
        (format stream "    std::cout << std::endl;~%")))

    (format stream "    std::cout << \"Success!\" << std::endl;~%")
    (format stream "    return 0;~%")
    (format stream "}~%")))


;;; src/hoist-l0/main.lisp
(defun generate-l0-launcher (metacrisp-path)
  "Generate Level Zero C++ launcher code from metacrisp file.
   Extended to extract and pass dispatch declarations to generate-cpp-main."
  (let* ((data     (parse-metacrisp-file metacrisp-path))
         (kernels  (metacrisp-kernels data))
         (aliases  (metacrisp-aliases data))
         (base-name (pathname-name metacrisp-path)))

    (format t "Processing ~a~%" metacrisp-path)
    (format t "  Kernels: ~a~%" (length kernels))

    (when (null kernels)
      (format t "WARNING: No kernels found in ~a. Nothing to hoist.~%" metacrisp-path))

    (let ((*hoist-current-structs* (metacrisp-structs data)))
      (dolist (kernel kernels)
        (let* ((kernel-name    (getf kernel :name))
               (declared-sig  (getf kernel :declared-signature))
               (implicit-sig  (getf kernel :implicit-params))
               ;; Extract dispatch info from parsed metacrisp plist
               (dispatch-info (let ((gs (getf kernel :global-size))
                                    (ls (getf kernel :local-size))
                                    (ng (getf kernel :num-groups)))
                                 (when (or gs ls ng)
                                   (append (when gs (list :global-size gs))
                                           (when ls (list :local-size  ls))
                                           (when ng (list :num-groups  ng))))))
               (comparable-range-start
                 (lambda (param)
                   (let ((r (getf param :range)))
                     (if (listp r) (first r) -1))))
               (full-sig      (sort (append declared-sig implicit-sig) #'<
                                    :key comparable-range-start))
               (output-targets (getf kernel :output-targets)))

          (let* ((spv-path-entry (or (assoc :spirv output-targets)
                                     (assoc :spv output-targets)))
                 (spv-path  (when spv-path-entry (second spv-path-entry)))
                 (suffix    (format nil "_~a" kernel-name))
                 (name-part (if (uiop:string-suffix-p base-name suffix)
                                base-name
                                (format nil "~a~a" base-name suffix)))
                 (output-name (format nil "~a_L0.cpp" name-part))
                 (output-path (make-pathname :name (pathname-name output-name)
                                             :type "cpp"
                                             :defaults metacrisp-path)))

            (if (null spv-path)
                (format t "WARNING: No SPIR-V target found for kernel ~a. Skipping host generation.~%"
                        kernel-name)
                (progn
                 (format t "  Generating: ~a~%" output-name)
                 (let ((dvec-types (%collect-dvec-types declared-sig aliases)))
                   (with-open-file (stream output-path :direction :output :if-exists :supersede)
                     (generate-cpp-preamble stream metacrisp-path kernel-name output-name)
                     (generate-cpp-includes stream)
                     (generate-cpp-typedefs stream aliases)
                     (generate-cpp-dvec-typedefs stream dvec-types)
                     (generate-cpp-structs stream (append (metacrisp-records data) (metacrisp-structs data)))
                     (generate-cpp-helpers stream)
                     (generate-cpp-main stream kernel-name spv-path full-sig aliases (metacrisp-records data) dispatch-info)))
                 (format t "  Done: ~a~%" (namestring output-path))))))))))







