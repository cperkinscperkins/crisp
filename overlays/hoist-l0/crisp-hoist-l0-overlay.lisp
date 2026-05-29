(in-package :crisp.hoist.l0)

;; Overlay file for crisp-hoist-l0
;; Add late-binding fixes here as needed


;; ======================================================================
;; :derive-from <tensor> + :strategy expansion
;; ======================================================================
;;
;; Mirrors the CUDA hoist semantic upgrade:
;;   :derive-from <SYMBOL>   — tensor parameter; reference <name>_length
;;   :derive-from (a b ...)  — scalar parameter names; reference <name>_arg
;;
;;   :strategy :strided      — max occupancy.  L0 has no single-call equivalent
;;                             of CUDA's cuOccupancyMaxActiveBlocksPerMultiprocessor,
;;                             so we compute it from zeDeviceGetComputeProperties
;;                             plus optional zeKernelGetProperties for register
;;                             pressure awareness.
;;   :strategy :one-thread-per — grid = ceil(length / wg_x)
;;   :strategy :tiled        — grid = ceil(length / tile-shape[0])

(defun %l0-tensor-length-cpp-var (sym)
  "Convert a tensor parameter symbol to its C++ length variable.
   The L0 hoist emits 'uint64_t <name>_length = N;' for each tensor param."
  (format nil "~a_length" (substitute #\_ #\- (string-downcase (symbol-name sym)))))

(defun %l0-normalize-derive-from (raw)
  "Normalize :derive-from value into a list:
     <symbol>           -> (<symbol>)  ;; tensor case
     (sym1 sym2 ...)    -> (sym1 sym2 ...)
     nil                -> nil"
  (cond
    ((null raw) nil)
    ((symbolp raw) (list raw))
    ((consp raw) raw)
    (t nil)))

(defun %l0-derive-from-is-tensor-p (raw)
  "Returns T if :derive-from was supplied as a bare symbol (tensor name)."
  (and raw (symbolp raw)))


;; ----------------------------------------------------------------------
;; src/hoist-l0/main.lisp — whole-function redefine of %l0-emit-dispatch.
;; ----------------------------------------------------------------------

(defun %l0-emit-dispatch (stream global-decl local-decl num-groups-decl)
  "Emit zeKernelSetGroupSize and ze_group_count_t based on dispatch declarations.
   Supports:
     :strategy :strided        — max occupancy (zeDeviceGetComputeProperties +
                                 optional zeKernelGetProperties)
     :strategy :one-thread-per — grid sized to derive-from source
     :strategy :tiled          — grid sized via derive-from + tile-shape
     :strategy :interleaved    — not yet implemented (default dispatch)
     :set-to scalar/list       — fixed grid
   :derive-from can be a single tensor symbol (uses <name>_length) or a list
   of scalar parameter names (uses <name>_arg)."
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

         (is-strided     (and strat-name (string-equal strat-name "STRIDED")))
         (is-tiled       (and strat-name (string-equal strat-name "TILED")))
         (is-interleaved (and strat-name (string-equal strat-name "INTERLEAVED")))
         (is-one-thread-per (and strat-name (string-equal strat-name "ONE-THREAD-PER")))

         (set-to     (when disp-rest (getf disp-rest :set-to)))
         (raw-derive-from (when disp-rest (getf disp-rest :derive-from)))
         (derive-from-is-tensor (%l0-derive-from-is-tensor-p raw-derive-from))
         (derive-from (%l0-normalize-derive-from raw-derive-from))
         (tile-shape (when disp-rest (getf disp-rest :tile-shape)))
         ;; :occupancy <ratio> — manual derating for :strided (default 1.0)
         (occupancy  (when disp-rest (getf disp-rest :occupancy))))

    (when is-strided
      (let ((ratio (cond ((null occupancy) 1.0)
                         ((numberp occupancy) (float occupancy))
                         (t 1.0))))
        (format stream "    // Strategy: :strided — max occupancy~%")
        (format stream "    ze_device_compute_properties_t _computeProps = { ZE_STRUCTURE_TYPE_DEVICE_COMPUTE_PROPERTIES };~%")
        (format stream "    zeDeviceGetComputeProperties(device, &_computeProps);~%")
        (format stream "    uint32_t _hw_threads = _computeProps.numSubslices * _computeProps.numEUsPerSubslice * _computeProps.numThreadsPerEU;~%")
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
          ;; :strided — occupancy-based grid
          (is-strided
           ;; Divide _hw_threads by workgroup size to get group count
           (let ((wg-total (* local-x (max 1 local-y))))
             (if (> wg-total 1)
                 (format stream "    ze_group_count_t groupCount = { _hw_threads / ~d, 1, 1 };~%" wg-total)
                 (format stream "    ze_group_count_t groupCount = { _hw_threads, 1, 1 };~%"))))

          (is-interleaved
           (format stream "    ze_group_count_t groupCount = { 1, 1, 1 };~%"))

          ((null dispatch-decl)
           (format stream "    ze_group_count_t groupCount = { 1, 1, 1 };~%"))

          ;; :tiled with tensor :derive-from
          ((and is-tiled derive-from-is-tensor)
           (let ((tx (or (first tile-shape) 1))
                 (tensor-var (%l0-tensor-length-cpp-var (first derive-from))))
             (format stream "    uint32_t _gx = ((uint32_t)~a + ~d) / ~d;~%"
                     tensor-var (1- tx) tx)
             (format stream "    ze_group_count_t groupCount = { _gx, 1, 1 };~%")))

          ;; :tiled with scalar derive-from list
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

          ;; :one-thread-per with tensor :derive-from
          ((and is-one-thread-per derive-from-is-tensor)
           (let ((tensor-var (%l0-tensor-length-cpp-var (first derive-from))))
             (if (> local-x 1)
                 (format stream "    ze_group_count_t groupCount = { ((uint32_t)~a + ~d) / ~d, 1, 1 };~%"
                         tensor-var (1- local-x) local-x)
                 (format stream "    ze_group_count_t groupCount = { (uint32_t)~a, 1, 1 };~%"
                         tensor-var))))

          ((integerp set-to)
           (let ((g0 (dim-to-gc set-to local-x)))
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
                  (g0 (dim-to-gc d0 local-x))
                  (g1 (dim-to-gc d1 (if (> local-y 1) local-y 1)))
                  (g2 (dim-to-gc d2 1)))
             (format stream "    ze_group_count_t groupCount = { ~a, ~a, ~a };~%" g0 g1 g2))))))))
