;;;; overlays/hoist-cuda/crisp-hoist-cuda-overlay.lisp
;;;;
;;;; Runtime patches for CUDA hoist improvements.
;;;; Applied via late binding - last definition wins.

(in-package :crisp.hoist.cuda)


;; ======================================================================
;; :derive-from <tensor> + :strategy expansion
;; ======================================================================
;;
;; Design:
;;   :derive-from <SYMBOL>   — single symbol = tensor parameter name.
;;                             Hoist references <symbol>_length at launch.
;;   :derive-from (a b ...)  — list of scalar parameter names.
;;                             Hoist references <a>_arg, etc.
;;
;;   :strategy :strided      — max occupancy via
;;                             cuOccupancyMaxActiveBlocksPerMultiprocessor.
;;                             Ignores tensor length (loop-vector-stride knows
;;                             where to stop via length~).
;;   :strategy :one-thread-per — gridX = ceil(length / block_x)
;;   :strategy :tiled        — gridX = ceil(length / tile-shape[0])
;;
;; The block size used for occupancy comes from :local-size :set-to N.
;; If :local-size is missing, defaults to 256.

(defun %tensor-length-cpp-var (sym)
  "Convert a tensor parameter symbol to its C++ length variable.
   The CUDA hoist emits 'uint64_t <name>_length = N;' for each tensor param,
   which we reference at dispatch time."
  (format nil "~a_length" (substitute #\_ #\- (string-downcase (symbol-name sym)))))

(defun %normalize-derive-from (raw)
  "Normalize :derive-from value into a list:
     <symbol>           -> (<symbol>)  ;; tensor case
     (sym1 sym2 ...)    -> (sym1 sym2 ...)
     nil                -> nil"
  (cond
    ((null raw) nil)
    ((symbolp raw) (list raw))
    ((consp raw) raw)
    (t nil)))

(defun %derive-from-is-tensor-p (raw)
  "Returns T if :derive-from was supplied as a bare symbol (tensor name)."
  (and raw (symbolp raw)))


;; ----------------------------------------------------------------------
;; src/hoist-cuda/main.lisp — whole-function redefine of emit-launch.
;; ----------------------------------------------------------------------

(defun emit-launch (stream dispatch-info shared-bytes)
  "Emit cuLaunchKernel call with grid/block dims from dispatch-info.
   Supports:
     :strategy :strided        — max occupancy (cuOccupancyMaxActiveBlocksPerMultiprocessor)
     :strategy :one-thread-per — grid sized to derive-from source
     :strategy :tiled          — grid sized via derive-from + tile-shape
     :set-to integer/list      — fixed grid
   And :derive-from can be a single tensor symbol (uses <name>_length) or a list
   of scalar parameter names (uses <name>_arg)."
  (let* ((global-decl     (when dispatch-info (getf dispatch-info :global-size)))
         (local-decl      (when dispatch-info (getf dispatch-info :local-size)))
         (num-groups-decl (when dispatch-info (getf dispatch-info :num-groups)))

         (ls-rest    (when local-decl (cdr local-decl)))
         (ls-set-to  (when ls-rest (getf ls-rest :set-to)))
         (block-x    (cond ((integerp ls-set-to) ls-set-to)
                           ((and (consp ls-set-to) (first ls-set-to)) (first ls-set-to))
                           (t 1)))
         (block-y    (cond ((and (consp ls-set-to) (second ls-set-to)) (second ls-set-to))
                           (t 1)))

         (dispatch-decl (or global-decl num-groups-decl))
         (disp-rest  (when dispatch-decl (cdr dispatch-decl)))
         (set-to     (when disp-rest (getf disp-rest :set-to)))
         (raw-derive-from (when disp-rest (getf disp-rest :derive-from)))
         (derive-from-is-tensor (%derive-from-is-tensor-p raw-derive-from))
         (derive-from (%normalize-derive-from raw-derive-from))
         (strategy    (when disp-rest (getf disp-rest :strategy)))
         (strat-name  (when strategy (symbol-name strategy)))
         (is-strided  (and strat-name (string-equal strat-name "STRIDED")))
         (is-tiled    (and strat-name (string-equal strat-name "TILED")))
         (is-one-thread-per (or (and strat-name (string-equal strat-name "ONE-THREAD-PER"))
                                ;; default when :derive-from is present without explicit strategy
                                (and (null strat-name) derive-from)))
         (tile-shape  (when disp-rest (getf disp-rest :tile-shape)))
         ;; :occupancy <ratio> — manual derating for :strided (default 1.0)
         (occupancy   (when disp-rest (getf disp-rest :occupancy))))

    (format stream "    // Launch kernel~%")

    (cond
      ;; --- :strategy :strided — max occupancy (optionally derated by :occupancy) ---
      (is-strided
       (let ((block-size (* block-x (max 1 block-y)))
             (ratio (cond ((null occupancy) 1.0)
                          ((numberp occupancy) (float occupancy))
                          (t 1.0))))
         (format stream "    // Strategy: :strided — max occupancy via cuOccupancyMaxActiveBlocksPerMultiprocessor~%")
         (when derive-from-is-tensor
           (format stream "    // derive-from tensor '~a' (length=~a) used for check-thread-bounds; grid uses occupancy~%"
                   (first derive-from) (%tensor-length-cpp-var (first derive-from))))
         (format stream "    int _blocksPerSM;~%")
         (format stream "    CUDA_CHECK(cuOccupancyMaxActiveBlocksPerMultiprocessor(&_blocksPerSM, kernel, ~d, ~a));~%"
                 block-size shared-bytes)
         (format stream "    int _numSMs;~%")
         (format stream "    CUDA_CHECK(cuDeviceGetAttribute(&_numSMs, CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT, device));~%")
         (if (= ratio 1.0)
             (format stream "    unsigned int gridX = (unsigned int)(_blocksPerSM * _numSMs);~%")
             (progn
               (format stream "    // :occupancy ~a — user-requested derate from max~%" occupancy)
               (format stream "    unsigned int gridX = (unsigned int)((_blocksPerSM * _numSMs) * ~f);~%" ratio)
               (format stream "    if (gridX < 1) gridX = 1;~%")))
         (format stream "    unsigned int gridY = 1, gridZ = 1;~%")))

      ;; --- :set-to integer — fixed grid ---
      ((and (not is-tiled) (integerp set-to))
       (let ((grid-x (if (> block-x 1)
                         (format nil "(~a + ~a) / ~a" set-to (1- block-x) block-x)
                         (format nil "~a" set-to))))
         (format stream "    unsigned int gridX = ~a, gridY = 1, gridZ = 1;~%" grid-x)))

      ;; --- :strategy :tiled with :derive-from and :tile-shape ---
      (is-tiled
       (if derive-from-is-tensor
           ;; Tensor-derived tiled: gridX = ceil(<tensor>_length / tile-shape[0])
           (let ((tx (or (first tile-shape) 1))
                 (tensor-var (%tensor-length-cpp-var (first derive-from))))
             (format stream "    unsigned int gridX = ((unsigned int)~a + ~d) / ~d;~%"
                     tensor-var (1- tx) tx)
             (format stream "    unsigned int gridY = 1, gridZ = 1;~%"))
           ;; Scalar list:tiled
           (let ((d0 (first derive-from))
                 (d1 (second derive-from))
                 (tx (or (first tile-shape) 1))
                 (ty (or (second tile-shape) 1)))
             (when d0
               (format stream "    unsigned int gridX = ((unsigned int)~a + ~a) / ~a;~%"
                       (%dispatch-sym-to-cpp-var d0) (1- tx) tx))
             (when d1
               (format stream "    unsigned int gridY = ((unsigned int)~a + ~a) / ~a;~%"
                       (%dispatch-sym-to-cpp-var d1) (1- ty) ty))
             (unless d0 (format stream "    unsigned int gridX = 1;~%"))
             (unless d1 (format stream "    unsigned int gridY = 1;~%"))
             (format stream "    unsigned int gridZ = 1;~%"))))

      ;; --- :strategy :one-thread-per (or unstated default) + :derive-from <tensor> ---
      ((and is-one-thread-per derive-from-is-tensor)
       (let ((tensor-var (%tensor-length-cpp-var (first derive-from))))
         (format stream "    // Strategy: :one-thread-per from tensor ~a~%" (first derive-from))
         (if (> block-x 1)
             (format stream "    unsigned int gridX = ((unsigned int)~a + ~d) / ~d;~%"
                     tensor-var (1- block-x) block-x)
             (format stream "    unsigned int gridX = (unsigned int)~a;~%" tensor-var))
         (format stream "    unsigned int gridY = 1, gridZ = 1;~%")))

      ;; --- :set-to list OR :derive-from (scalar list) ---
      ((or (consp set-to) derive-from)
       (let* ((dims (cond ((consp set-to) set-to)
                          (derive-from derive-from)
                          (t nil)))
              (d0 (first dims))
              (d1 (second dims)))
         (flet ((dim-gc (dim local-val)
                  (cond
                    ((null dim) "1")
                    ((integerp dim)
                     (if (> local-val 1)
                         (format nil "(~a + ~a) / ~a" dim (1- local-val) local-val)
                         (format nil "~a" dim)))
                    ((symbolp dim)
                     (let ((v (%dispatch-sym-to-cpp-var dim)))
                       (if (> local-val 1)
                           (format nil "((unsigned int)~a + ~a) / ~a" v (1- local-val) local-val)
                           (format nil "(unsigned int)~a" v))))
                    (t "1"))))
           (format stream "    unsigned int gridX = ~a, gridY = ~a, gridZ = 1;~%"
                   (dim-gc d0 block-x)
                   (dim-gc d1 (if (> block-y 1) block-y 1))))))

      ;; --- Default fallback ---
      (t
       (format stream "    unsigned int gridX = 1, gridY = 1, gridZ = 1;~%")))

    (format stream "    CUDA_CHECK(cuLaunchKernel(kernel,~%")
    (format stream "        gridX, gridY, gridZ,~%")
    (format stream "        ~a, ~a, 1,~%" block-x block-y)
    (format stream "        ~a, 0,~%" shared-bytes)
    (format stream "        kernelParams, nullptr));~%~%")))
