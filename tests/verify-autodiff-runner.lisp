;;;; tests/verify-autodiff-runner.lisp
;;;;
;;;; On-metal AD verification runner.  Provides VERIFY-AUTODIFF, which takes
;;;; a forward + backward SPV pair and verifies that the analytical gradient
;;;; emitted by the backward kernel matches a central-difference numerical
;;;; gradient computed by running the forward kernel at x +/- h.
;;;;
;;;; Phase 1 scope (endeavor 103): scalar-cell-in / scalar-cell-out only.
;;;; Tensor/record/struct inputs come in later phases.
;;;;
;;;; Entry point:
;;;;
;;;;   (verify-autodiff fwd-spv-path bwd-spv-path fwd-kernel-name
;;;;                    &key bwd-kernel-name x seed-grad h atol verbose)
;;;;     => (values pass-p analytical numerical diff)
;;;;
;;;; This file loads OpenCL via CFFI at load time.  Loading it on a host
;;;; without an OpenCL ICD will signal at the (cffi:use-foreign-library)
;;;; step -- callers wanting to soft-skip should wrap LOAD in HANDLER-CASE.

(in-package :cl-user)

(unless (find-package :cffi)
  (format t "~&; Loading CFFI for verify-autodiff runner...~%")
  (ql:quickload :cffi :silent t))

;;; === OpenCL Constants =================================================

(defconstant +CL-SUCCESS+ 0)
(defconstant +CL-DEVICE-TYPE-GPU+ 4)
(defconstant +CL-MEM-READ-WRITE+ 1)
(defconstant +CL-MEM-COPY-HOST-PTR+ 4)

;;; === OpenCL CFFI Bindings =============================================
;;;
;;; cl_ulong / cl_bitfield are unsigned long long (64-bit) per the OpenCL
;;; spec on all platforms.  CFFI :ulong is C unsigned long, which is 32-bit
;;; on Windows LLP64 -- so always use :uint64 for cl_ulong-typed args.

(cffi:define-foreign-library opencl
                             (:windows "OpenCL.dll")
                             (:unix "libOpenCL.so")
                             (t (:default "libOpenCL")))

(cffi:use-foreign-library opencl)

(cffi:defcfun ("clGetPlatformIDs" cl-get-platform-ids) :int
              (num-entries :uint) (platforms :pointer) (num-platforms :pointer))

(cffi:defcfun ("clGetDeviceIDs" cl-get-device-ids) :int
              (platform :pointer) (device-type :uint64) (num-entries :uint)
              (devices :pointer) (num-devices :pointer))

(cffi:defcfun ("clCreateContext" cl-create-context) :pointer
              (properties :pointer) (num-devices :uint) (devices :pointer)
              (pfn-notify :pointer) (user-data :pointer) (errcode-ret :pointer))

(cffi:defcfun ("clCreateCommandQueue" cl-create-command-queue) :pointer
              (context :pointer) (device :pointer) (properties :uint64) (errcode-ret :pointer))

(cffi:defcfun ("clCreateProgramWithIL" cl-create-program-with-il) :pointer
              (context :pointer) (il :pointer) (length :size) (errcode-ret :pointer))

(cffi:defcfun ("clBuildProgram" cl-build-program) :int
              (program :pointer) (num-devices :uint) (device-list :pointer)
              (options :string) (pfn-notify :pointer) (user-data :pointer))

(cffi:defcfun ("clCreateKernel" cl-create-kernel) :pointer
              (program :pointer) (kernel-name :string) (errcode-ret :pointer))

(cffi:defcfun ("clCreateBuffer" cl-create-buffer) :pointer
              (context :pointer) (flags :uint64) (size :size)
              (host-ptr :pointer) (errcode-ret :pointer))

(cffi:defcfun ("clSetKernelArg" cl-set-kernel-arg) :int
              (kernel :pointer) (arg-index :uint) (arg-size :size) (arg-value :pointer))

(cffi:defcfun ("clEnqueueNDRangeKernel" cl-enqueue-ndrange-kernel) :int
              (command-queue :pointer) (kernel :pointer) (work-dim :uint)
              (global-work-offset :pointer) (global-work-size :pointer) (local-work-size :pointer)
              (num-events-in-wait-list :uint) (event-wait-list :pointer) (event :pointer))

(cffi:defcfun ("clEnqueueReadBuffer" cl-enqueue-read-buffer) :int
              (command-queue :pointer) (buffer :pointer) (blocking-read :uint)
              (offset :size) (size :size) (ptr :pointer)
              (num-events-in-wait-list :uint) (event-wait-list :pointer) (event :pointer))

(cffi:defcfun ("clEnqueueWriteBuffer" cl-enqueue-write-buffer) :int
              (command-queue :pointer) (buffer :pointer) (blocking-write :uint)
              (offset :size) (size :size) (ptr :pointer)
              (num-events-in-wait-list :uint) (event-wait-list :pointer) (event :pointer))

(cffi:defcfun ("clFinish" cl-finish) :int
              (command-queue :pointer))

(cffi:defcfun ("clReleaseMemObject" cl-release-mem-object) :int
              (memobj :pointer))

(cffi:defcfun ("clReleaseKernel" cl-release-kernel) :int
              (kernel :pointer))

(cffi:defcfun ("clReleaseProgram" cl-release-program) :int
              (program :pointer))

(cffi:defcfun ("clReleaseCommandQueue" cl-release-command-queue) :int
              (command-queue :pointer))

(cffi:defcfun ("clReleaseContext" cl-release-context) :int
              (context :pointer))

;;; === Helpers ===========================================================

(defmacro check-cl (form)
  `(let ((err ,form))
     (unless (= err +CL-SUCCESS+)
       (error "OpenCL error in ~a: ~a" ',form err))))

(defun read-spv-file (path)
  "Reads a SPIR-V binary file into a freshly-allocated (unsigned-byte 8) array."
  (with-open-file (stream path :direction :input :element-type '(unsigned-byte 8))
    (let* ((length (file-length stream))
           (data (make-array length :element-type '(unsigned-byte 8))))
      (read-sequence data stream)
      data)))

(defun create-program-and-kernel (context spv-data kernel-name)
  "Builds an OpenCL program from SPV-DATA and creates KERNEL-NAME.
   Returns (values program kernel)."
  (cffi:with-foreign-object (err :int)
    (cffi:with-foreign-object (il-ptr :uchar (length spv-data))
      (loop for i from 0 below (length spv-data)
            do (setf (cffi:mem-aref il-ptr :uchar i) (aref spv-data i)))
      (let* ((program (cl-create-program-with-il context il-ptr (length spv-data) err)))
        (check-cl (cffi:mem-ref err :int))
        (check-cl (cl-build-program program 0 (cffi:null-pointer) (cffi:null-pointer) (cffi:null-pointer) (cffi:null-pointer)))
        (let ((kernel (cl-create-kernel program kernel-name err)))
          (check-cl (cffi:mem-ref err :int))
          (values program kernel))))))

(defun create-float-cell-buffer (context)
  "Creates a 4-byte read/write cl_mem buffer for a single-float cell."
  (cffi:with-foreign-object (err :int)
    (let ((buffer (cl-create-buffer context +CL-MEM-READ-WRITE+ 4 (cffi:null-pointer) err)))
      (check-cl (cffi:mem-ref err :int))
      buffer)))

(defun write-float-cell (queue buffer value)
  "Writes VALUE (a single-float) to the 1-element float buffer."
  (cffi:with-foreign-object (data :float 1)
    (setf (cffi:mem-aref data :float 0) value)
    (check-cl (cl-enqueue-write-buffer queue buffer 1 0 4 data 0 (cffi:null-pointer) (cffi:null-pointer)))))

(defun read-float-cell (queue buffer)
  "Reads the single float from BUFFER and returns it."
  (cffi:with-foreign-object (result :float 1)
    (check-cl (cl-enqueue-read-buffer queue buffer 1 0 4 result 0 (cffi:null-pointer) (cffi:null-pointer)))
    (cffi:mem-aref result :float 0)))

(defun bind-cell-arg (kernel base-index buffer &key (byte-size 4) (offset 0))
  "Binds a Crisp cell to KERNEL starting at BASE-INDEX (3 args: parent ptr,
   byte_size, offset).  Reflects the post-:access-removal cell layout
   (3-tuple).  Sizes use :uint64 to match the kernel's i64 params on Windows."
  (cffi:with-foreign-objects ((arg0 :pointer) (arg1 :uint64) (arg2 :uint64))
    (setf (cffi:mem-ref arg0 :pointer) buffer)
    (setf (cffi:mem-ref arg1 :uint64) byte-size)
    (setf (cffi:mem-ref arg2 :uint64) offset)
    (check-cl (cl-set-kernel-arg kernel (+ base-index 0) (cffi:foreign-type-size :pointer) arg0))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 1) (cffi:foreign-type-size :uint64) arg1))
    (check-cl (cl-set-kernel-arg kernel (+ base-index 2) (cffi:foreign-type-size :uint64) arg2))))

(defun launch-kernel-1d (queue kernel &key (global-size 1))
  "Launches KERNEL with a 1D ND-range of GLOBAL-SIZE and waits for it to finish."
  (cffi:with-foreign-object (gs :size 1)
    (setf (cffi:mem-aref gs :size 0) global-size)
    (check-cl (cl-enqueue-ndrange-kernel queue kernel 1 (cffi:null-pointer) gs (cffi:null-pointer) 0 (cffi:null-pointer) (cffi:null-pointer))))
  (check-cl (cl-finish queue)))

;;; === Entry Point =======================================================

(defun verify-autodiff (fwd-spv-path bwd-spv-path fwd-kernel-name
                       &key
                         (bwd-kernel-name (concatenate 'string fwd-kernel-name "_grad"))
                         inputs
                         (seed-grad 1.0)
                         (h 1e-3)
                         (atol 1e-2)
                         verbose)
  "On-metal AD verification for an N-scalar-cell-in / single-scalar-cell-out
   kernel.

   INPUTS is an alist of (NAME-STRING . FLOAT-VALUE) for each kernel input,
   in declaration order.  For each input the runner does a central-difference
   FD pass (perturbing only that input).  The backward kernel is then run
   once with all primals + SEED-GRAD, and the per-input analytical gradients
   are compared with their numerical FD counterparts using tolerance ATOL.

   Returns (values PASS-P RESULTS) where:
     PASS-P  -- T iff every input's |analytical - numerical| < ATOL.
     RESULTS -- list of per-input plists, in declaration order:
                  (:name <string>
                   :analytical <float>
                   :numerical <float>
                   :diff <float>)

   Phase 5a scope (endeavor 103): all inputs are
   (cell float :address-space :global); output is one cell of the same.
   Tensor / record / struct inputs come in later phases."
  (flet ((vlog (control &rest args)
           (when verbose (apply #'format t control args))))
    (let* ((n (length inputs))
           (platform nil) (device nil) (context nil) (queue nil)
           (fwd-program nil) (fwd-kernel nil)
           (bwd-program nil) (bwd-kernel nil)
           (input-bufs nil) (output-buf nil) (output-grad-buf nil) (input-grad-bufs nil)
           (pass-p nil) (results nil))
      (unwind-protect
          (progn
           (when (zerop n)
             (error "VERIFY-AUTODIFF: no inputs supplied"))

           (cffi:with-foreign-objects ((platforms :pointer 1)
                                       (devices :pointer 1))
             (check-cl (cl-get-platform-ids 1 platforms (cffi:null-pointer)))
             (setf platform (cffi:mem-aref platforms :pointer 0))
             (check-cl (cl-get-device-ids platform +CL-DEVICE-TYPE-GPU+ 1 devices (cffi:null-pointer)))
             (setf device (cffi:mem-aref devices :pointer 0)))

           (cffi:with-foreign-object (err :int)
             (setf context (cl-create-context (cffi:null-pointer) 1
                                              (cffi:foreign-alloc :pointer :initial-element device)
                                              (cffi:null-pointer) (cffi:null-pointer) err))
             (setf queue (cl-create-command-queue context device 0 err)))

           (vlog "~&;   Loading kernels: ~a / ~a (~a input~:p)~%"
                 fwd-kernel-name bwd-kernel-name n)
           (let ((fwd-spv (read-spv-file fwd-spv-path))
                 (bwd-spv (read-spv-file bwd-spv-path)))
             (multiple-value-bind (p k) (create-program-and-kernel context fwd-spv fwd-kernel-name)
               (setf fwd-program p fwd-kernel k))
             (multiple-value-bind (p k) (create-program-and-kernel context bwd-spv bwd-kernel-name)
               (setf bwd-program p bwd-kernel k)))

           ;; Buffers: N inputs + Y + Y_grad + N input-grads.
           (setf input-bufs (loop repeat n collect (create-float-cell-buffer context))
                 output-buf      (create-float-cell-buffer context)
                 output-grad-buf (create-float-cell-buffer context)
                 input-grad-bufs (loop repeat n collect (create-float-cell-buffer context)))

           (labels ((write-primals (perturb-i delta)
                      "Writes all input cells.  When PERTURB-I is non-nil,
                       input at that index is shifted by DELTA."
                      (loop for entry in inputs
                            for buf in input-bufs
                            for i from 0
                            do (let* ((v (cl:float (cdr entry) 1.0))
                                      (vv (if (eql i perturb-i)
                                              (cl:float (+ v delta) 1.0)
                                              v)))
                                 (write-float-cell queue buf vv))))
                    (bind-forward-args ()
                      (loop for buf in input-bufs
                            for i from 0
                            do (bind-cell-arg fwd-kernel (* 3 i) buf))
                      (bind-cell-arg fwd-kernel (* 3 n) output-buf))
                    (bind-backward-args ()
                      (loop for buf in input-bufs
                            for i from 0
                            do (bind-cell-arg bwd-kernel (* 3 i) buf))
                      (bind-cell-arg bwd-kernel (* 3 n) output-buf)
                      (bind-cell-arg bwd-kernel (* 3 (1+ n)) output-grad-buf)
                      (loop for buf in input-grad-bufs
                            for i from 0
                            do (bind-cell-arg bwd-kernel (* 3 (+ n 2 i)) buf))))

             ;; --- Forward at unperturbed primals, to capture Y for backward.
             (write-primals nil 0.0)
             (write-float-cell queue output-buf 0.0)
             (bind-forward-args)
             (launch-kernel-1d queue fwd-kernel)
             (let ((y-at-primals (read-float-cell queue output-buf))
                   (numerical-grads nil))
               (vlog "~&;   y(primals) = ~a~%" y-at-primals)

               ;; --- Per-input central-difference FD ---------------------
               (loop for entry in inputs
                     for perturbed-i from 0
                     do (write-primals perturbed-i h)
                        (write-float-cell queue output-buf 0.0)
                        (launch-kernel-1d queue fwd-kernel)
                        (let ((y-plus (read-float-cell queue output-buf)))
                          (write-primals perturbed-i (- h))
                          (write-float-cell queue output-buf 0.0)
                          (launch-kernel-1d queue fwd-kernel)
                          (let* ((y-minus (read-float-cell queue output-buf))
                                 (grad (/ (- y-plus y-minus) (* 2.0 h))))
                            (push grad numerical-grads)
                            (vlog "~&;   d/d~a: y+=~a y-=~a num=~a~%"
                                  (car entry) y-plus y-minus grad))))
               (setf numerical-grads (nreverse numerical-grads))

               ;; --- Backward with primals + seed ------------------------
               (write-primals nil 0.0)
               (write-float-cell queue output-buf y-at-primals)
               (write-float-cell queue output-grad-buf (cl:float seed-grad 1.0))
               (dolist (buf input-grad-bufs)
                 (write-float-cell queue buf 0.0))
               (bind-backward-args)
               (launch-kernel-1d queue bwd-kernel)

               (let ((analytical-grads
                      (loop for buf in input-grad-bufs
                            collect (read-float-cell queue buf))))
                 (setf results
                       (loop for entry in inputs
                             for num  in numerical-grads
                             for ana  in analytical-grads
                             collect (list :name (car entry)
                                           :analytical ana
                                           :numerical num
                                           :diff (abs (- ana num)))))
                 (setf pass-p (every (lambda (r) (< (getf r :diff) atol))
                                     results))
                 (vlog "~&;   pass-p = ~a~%" pass-p)))))

        ;; Cleanup
        (dolist (b input-bufs)      (when b (cl-release-mem-object b)))
        (dolist (b input-grad-bufs) (when b (cl-release-mem-object b)))
        (when output-buf      (cl-release-mem-object output-buf))
        (when output-grad-buf (cl-release-mem-object output-grad-buf))
        (when fwd-kernel  (cl-release-kernel fwd-kernel))
        (when fwd-program (cl-release-program fwd-program))
        (when bwd-kernel  (cl-release-kernel bwd-kernel))
        (when bwd-program (cl-release-program bwd-program))
        (when queue   (cl-release-command-queue queue))
        (when context (cl-release-context context)))

      (values pass-p results))))
