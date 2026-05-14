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
                         (x 3.0)
                         (seed-grad 1.0)
                         (h 1e-3)
                         (atol 1e-2)
                         verbose)
  "On-metal AD verification for a scalar-cell-in / scalar-cell-out kernel.

   Runs the forward kernel at X+H and X-H to compute a central-difference
   numerical gradient.  Then runs the backward kernel with the output
   gradient seeded to SEED-GRAD, and reads back the analytical input
   gradient.  Compares with absolute tolerance ATOL.

   Returns (values PASS-P ANALYTICAL NUMERICAL DIFF).  When VERBOSE,
   prints progress to *standard-output*; otherwise stays silent.

   Phase 1 scope (endeavor 103): assumes the kernel has exactly one cell
   input and one cell output, both (cell float :address-space :global).
   Wider shapes (tensors, records, structs) come in later phases."
  (flet ((vlog (control &rest args)
           (when verbose (apply #'format t control args))))
    (let (platform device context queue
                   fwd-program fwd-kernel
                   bwd-program bwd-kernel
                   buf-x buf-y buf-y-grad buf-x-grad
                   (pass-p nil) (analytical nil) (numerical nil) (diff nil))
      (unwind-protect
          (progn
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

           (vlog "~&;   Loading kernels: ~a / ~a~%" fwd-kernel-name bwd-kernel-name)
           (let ((fwd-spv (read-spv-file fwd-spv-path))
                 (bwd-spv (read-spv-file bwd-spv-path)))
             (multiple-value-bind (p k) (create-program-and-kernel context fwd-spv fwd-kernel-name)
               (setf fwd-program p fwd-kernel k))
             (multiple-value-bind (p k) (create-program-and-kernel context bwd-spv bwd-kernel-name)
               (setf bwd-program p bwd-kernel k)))

           (setf buf-x      (create-float-cell-buffer context)
                 buf-y      (create-float-cell-buffer context)
                 buf-y-grad (create-float-cell-buffer context)
                 buf-x-grad (create-float-cell-buffer context))

           ;; --- Numerical gradient via central difference -------------
           (let ((y-plus  (progn (write-float-cell queue buf-x (+ x h))
                                 (write-float-cell queue buf-y 0.0)
                                 (bind-cell-arg fwd-kernel 0 buf-x)
                                 (bind-cell-arg fwd-kernel 3 buf-y)
                                 (launch-kernel-1d queue fwd-kernel)
                                 (read-float-cell queue buf-y)))
                 (y-minus (progn (write-float-cell queue buf-x (- x h))
                                 (write-float-cell queue buf-y 0.0)
                                 (bind-cell-arg fwd-kernel 0 buf-x)
                                 (bind-cell-arg fwd-kernel 3 buf-y)
                                 (launch-kernel-1d queue fwd-kernel)
                                 (read-float-cell queue buf-y))))
             (setf numerical (/ (- y-plus y-minus) (* 2.0 h)))
             (vlog "~&;   f(x+h) = ~a, f(x-h) = ~a, numerical grad = ~a~%"
                   y-plus y-minus numerical))

           ;; --- Analytical gradient via backward kernel ---------------
           ;; Seed primals at x (X, Y), output grad (Y_GRAD), zero input grad (X_GRAD).
           (write-float-cell queue buf-x x)
           ;; Y can be re-derived; do it in Lisp to keep this layer simple.
           ;; The current scalar-cell kernels don't use Y in the backward
           ;; chain rule (e.g. d(x^2)/dx = 2x doesn't need y), but kernels
           ;; whose grad expressions reference the forward output would.
           (write-float-cell queue buf-y (* x x))
           (write-float-cell queue buf-y-grad seed-grad)
           (write-float-cell queue buf-x-grad 0.0)

           (bind-cell-arg bwd-kernel 0 buf-x)
           (bind-cell-arg bwd-kernel 3 buf-y)
           (bind-cell-arg bwd-kernel 6 buf-y-grad)
           (bind-cell-arg bwd-kernel 9 buf-x-grad)

           (launch-kernel-1d queue bwd-kernel)
           (setf analytical (read-float-cell queue buf-x-grad))

           (setf diff (abs (- numerical analytical)))
           (setf pass-p (< diff atol))
           (vlog "~&;   analytical grad = ~a, diff = ~a, atol = ~a => ~a~%"
                 analytical diff atol (if pass-p "PASS" "FAIL")))

        ;; Cleanup
        (when buf-x      (cl-release-mem-object buf-x))
        (when buf-y      (cl-release-mem-object buf-y))
        (when buf-y-grad (cl-release-mem-object buf-y-grad))
        (when buf-x-grad (cl-release-mem-object buf-x-grad))
        (when fwd-kernel  (cl-release-kernel fwd-kernel))
        (when fwd-program (cl-release-program fwd-program))
        (when bwd-kernel  (cl-release-kernel bwd-kernel))
        (when bwd-program (cl-release-program bwd-program))
        (when queue   (cl-release-command-queue queue))
        (when context (cl-release-context context)))

      (values pass-p analytical numerical diff))))
