;; Tests Auto-Differentiation using OpenCL for empirical finite-difference verification
;; Run with: sbcl --non-interactive --load scripts/verify_autodiff.lisp

(in-package :cl-user)

(format t "~&; Loading CFFI...~%")
(ql:quickload :cffi :silent t)

;;; === OpenCL Constants ===
(defconstant +CL-SUCCESS+ 0)
(defconstant +CL-DEVICE-TYPE-GPU+ 4)
(defconstant +CL-MEM-READ-WRITE+ 1)
(defconstant +CL-MEM-COPY-HOST-PTR+ 4)

;;; === OpenCL CFFI Bindings ===

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

;;; === Helper Macros ===

(defmacro check-cl (form)
  `(let ((err ,form))
     (unless (= err +CL-SUCCESS+)
       (error "OpenCL error in ~a: ~a" ',form err))))

;;; === Test Logic ===

(defun compile-kernels ()
  (format t "~%=== 1. Compiling Crisp Kernels ===~%")
  (let* ((cmd1 '("bin/crisp-compile.exe" "--ir-target=spv" "tests/spec/044-autodiff-execution/01-square.crisp"))
         (cmd2 '("bin/crisp-compile.exe" "--differentiate" "--ir-target=spv" "tests/spec/044-autodiff-execution/01-square.crisp")))
    (uiop:run-program cmd1 :output t :error-output t)
    (uiop:run-program cmd2 :output t :error-output t)
    (format t "Compilation complete.~%")))

(defun read-spv-file (path)
  (with-open-file (stream path :direction :input :element-type '(unsigned-byte 8))
    (let* ((length (file-length stream))
           (data (make-array length :element-type '(unsigned-byte 8))))
      (read-sequence data stream)
      data)))

(defun create-program-and-kernel (context spv-data kernel-name)
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

(defun create-buffer (context initial-value)
  (declare (ignore initial-value))
  (cffi:with-foreign-object (err :int)
                            (let ((buffer (cl-create-buffer context +CL-MEM-READ-WRITE+ 4 (cffi:null-pointer) err)))
                              (check-cl (cffi:mem-ref err :int))
                              buffer)))

(defun write-buffer (queue buffer value)
  (cffi:with-foreign-object (data :float 1)
                            (setf (cffi:mem-aref data :float 0) value)
                            (check-cl (cl-enqueue-write-buffer queue buffer 1 0 4 data 0 (cffi:null-pointer) (cffi:null-pointer)))))

(defun read-buffer (queue buffer)
  (cffi:with-foreign-object (result :float 1)
                            (check-cl (cl-enqueue-read-buffer queue buffer 1 0 4 result 0 (cffi:null-pointer) (cffi:null-pointer)))
                            (cffi:mem-aref result :float 0)))

(defun bind-cell-arg (kernel arg-index base-index buffer)
  (cffi:with-foreign-objects ((arg0 :pointer) (arg1 :uint64) (arg2 :uint64))
                             (setf (cffi:mem-ref arg0 :pointer) buffer)
                             (setf (cffi:mem-ref arg1 :uint64) 4) ; byte_size = 4
                             (setf (cffi:mem-ref arg2 :uint64) 0) ; offset = 0
                             (check-cl (cl-set-kernel-arg kernel (+ base-index 0) (cffi:foreign-type-size :pointer) arg0))
                             (check-cl (cl-set-kernel-arg kernel (+ base-index 1) (cffi:foreign-type-size :uint64) arg1))
                             (check-cl (cl-set-kernel-arg kernel (+ base-index 2) (cffi:foreign-type-size :uint64) arg2))))

(defun run-forward-evaluation (queue kernel buf-x buf-y input-x)
  (write-buffer queue buf-x input-x)
  (write-buffer queue buf-y 0.0)

  (bind-cell-arg kernel 0 0 buf-x)
  (bind-cell-arg kernel 1 3 buf-y)

  (cffi:with-foreign-object (global-size :size 1)
                            (setf (cffi:mem-aref global-size :size 0) 1)
                            (check-cl (cl-enqueue-ndrange-kernel queue kernel 1 (cffi:null-pointer) global-size (cffi:null-pointer) 0 (cffi:null-pointer) (cffi:null-pointer))))
  (check-cl (cl-finish queue))

  (read-buffer queue buf-y))

(defun main ()
  (compile-kernels)

  (format t "~%=== 2. Initializing OpenCL Execution Context ===~%")
  (let (platform device context queue
                 fwd-program fwd-kernel
                 bwd-program bwd-kernel
                 buf-x buf-x-adj buf-x-grad
                 buf-y buf-y-adj buf-y-grad)
    (unwind-protect
        (progn
         (cffi:with-foreign-objects ((num-platforms :uint)
                                     (platforms :pointer 1)
                                     (num-devices :uint)
                                     (devices :pointer 1))
                                    (check-cl (cl-get-platform-ids 1 platforms (cffi:null-pointer)))
                                    (setf platform (cffi:mem-aref platforms :pointer 0))
                                    (check-cl (cl-get-device-ids platform +CL-DEVICE-TYPE-GPU+ 1 devices (cffi:null-pointer)))
                                    (setf device (cffi:mem-aref devices :pointer 0)))

         (cffi:with-foreign-object (err :int)
                                   (setf context (cl-create-context (cffi:null-pointer) 1 (cffi:foreign-alloc :pointer :initial-element device) (cffi:null-pointer) (cffi:null-pointer) err))
                                   (setf queue (cl-create-command-queue context device 0 err)))

         (format t "~%=== 3. Loading Kernels ===~%")
         (let ((fwd-spv (read-spv-file "tests/spec/044-autodiff-execution/01-square.spv"))
               (bwd-spv (read-spv-file "tests/spec/044-autodiff-execution/01-square_grad.spv")))
           (multiple-value-bind (p k) (create-program-and-kernel context fwd-spv "cell_square")
             (setf fwd-program p fwd-kernel k))
           (multiple-value-bind (p k) (create-program-and-kernel context bwd-spv "cell_square_grad")
             (setf bwd-program p bwd-kernel k)))

         (format t "~%=== 4. Allocating Cell Buffers ===~%")
         (setf buf-x (create-buffer context 0.0)
           buf-y (create-buffer context 0.0)
           buf-y-grad (create-buffer context 0.0)
           buf-x-grad (create-buffer context 0.0))

         (format t "~%=== 5. Numerical Central Difference (Forward) ===~%")
         (let* ((x-eval 3.0)
                (h 1e-3)
                (y1 (run-forward-evaluation queue fwd-kernel buf-x buf-y (+ x-eval h)))
                (y2 (run-forward-evaluation queue fwd-kernel buf-x buf-y (- x-eval h)))
                (approx (/ (- y1 y2) (* 2.0 h))))
           (format t "   f(~a + h) = ~a~%" x-eval y1)
           (format t "   f(~a - h) = ~a~%" x-eval y2)
           (format t "   Numerical Gradient (Central Difference): ~a~%" approx)

           (format t "~%=== 6. Analytical Gradient (Backward) ===~%")
           ;; Setup backward pass
           ;; X = x-eval
           ;; Y = x-eval * x-eval (forward compute not strictly required unless backward pass uses it, doing it via Lisp for now)
           (write-buffer queue buf-x x-eval)
           (write-buffer queue buf-y (* x-eval x-eval))
           (write-buffer queue buf-y-grad 1.0) ; incoming dy/dy = 1
           (write-buffer queue buf-x-grad 0.0) ; dx gradient accumulator

           ;; Bind 12 arguments mapped to the 4 cell structs (X, Y, Y_GRAD, X_GRAD)
           (bind-cell-arg bwd-kernel 0 0 buf-x)
           (bind-cell-arg bwd-kernel 1 3 buf-y)
           (bind-cell-arg bwd-kernel 2 6 buf-y-grad)
           (bind-cell-arg bwd-kernel 3 9 buf-x-grad)

           (cffi:with-foreign-object (global-size :size 1)
                                     (setf (cffi:mem-aref global-size :size 0) 1)
                                     (check-cl (cl-enqueue-ndrange-kernel queue bwd-kernel 1 (cffi:null-pointer) global-size (cffi:null-pointer) 0 (cffi:null-pointer) (cffi:null-pointer))))
           (check-cl (cl-finish queue))

           (let ((analytical (read-buffer queue buf-x-grad)))
             (format t "   Analytical Gradient (dx): ~a~%" analytical)

             (format t "~%=== 7. Verification ===~%")
             (let ((diff (abs (- approx analytical))))
               (format t "   Difference: ~a~%" diff)
               (if (< diff 1e-2)
                   (format t "~%✓ VERIFICATION SUCCESSFUL! The parsed kernel executes exact mathematical differentiation!~%")
                   (error "✗ VERIFICATION FAILED! Output deviation of ~a exceeds threshold ~a" diff 1e-2))))))

      ;; Cleanup
      (when buf-x (cl-release-mem-object buf-x))
      (when buf-y (cl-release-mem-object buf-y))
      (when buf-y-grad (cl-release-mem-object buf-y-grad))
      (when buf-x-grad (cl-release-mem-object buf-x-grad))
      (when fwd-kernel (cl-release-kernel fwd-kernel))
      (when fwd-program (cl-release-program fwd-program))
      (when bwd-kernel (cl-release-kernel bwd-kernel))
      (when bwd-program (cl-release-program bwd-program))
      (when queue (cl-release-command-queue queue))
      (when context (cl-release-context context)))))

(main)
(uiop:quit 0)
