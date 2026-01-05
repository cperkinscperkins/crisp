;; Runs the smoke_test SPIR-V kernel on the BMG GPU
;; ./bin/crisp-compile.exe --ir-target=spv ./tests/spec/023-spirv/01-smoke.crisp
;; Run with: sbcl --non-interactive --load scripts/run_smoke_kernel.lisp

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
              (platform :pointer) (device-type :ulong) (num-entries :uint)
              (devices :pointer) (num-devices :pointer))

(cffi:defcfun ("clCreateContext" cl-create-context) :pointer
              (properties :pointer) (num-devices :uint) (devices :pointer)
              (pfn-notify :pointer) (user-data :pointer) (errcode-ret :pointer))

(cffi:defcfun ("clCreateCommandQueue" cl-create-command-queue) :pointer
              (context :pointer) (device :pointer) (properties :ulong) (errcode-ret :pointer))

(cffi:defcfun ("clCreateProgramWithIL" cl-create-program-with-il) :pointer
              (context :pointer) (il :pointer) (length :size) (errcode-ret :pointer))

(cffi:defcfun ("clBuildProgram" cl-build-program) :int
              (program :pointer) (num-devices :uint) (device-list :pointer)
              (options :string) (pfn-notify :pointer) (user-data :pointer))

(cffi:defcfun ("clCreateKernel" cl-create-kernel) :pointer
              (program :pointer) (kernel-name :string) (errcode-ret :pointer))

(cffi:defcfun ("clCreateBuffer" cl-create-buffer) :pointer
              (context :pointer) (flags :ulong) (size :size)
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

;;; === Main Test ===

(format t "~%=== Running smoke_test SPIR-V Kernel ===~%~%")

(let (platform device context queue program kernel buffer-c)
  (unwind-protect
      (progn
       ;; 1. Get platform and device
       (format t "1. Getting OpenCL platform and device...~%")
       (cffi:with-foreign-objects ((num-platforms :uint)
                                   (platforms :pointer 1)
                                   (num-devices :uint)
                                   (devices :pointer 1))
                                  (check-cl (cl-get-platform-ids 1 platforms (cffi:null-pointer)))
                                  (setf platform (cffi:mem-aref platforms :pointer 0))

                                  (check-cl (cl-get-device-ids platform +CL-DEVICE-TYPE-GPU+ 1 devices (cffi:null-pointer)))
                                  (setf device (cffi:mem-aref devices :pointer 0))
                                  (format t "   Platform: ~a, Device: ~a~%" platform device))

       ;; 2. Create context
       (format t "2. Creating OpenCL context...~%")
       (cffi:with-foreign-object (err :int)
                                 (setf context (cl-create-context (cffi:null-pointer) 1
                                                                  (cffi:foreign-alloc :pointer :initial-element device)
                                                                  (cffi:null-pointer) (cffi:null-pointer) err))
                                 (unless (cffi:null-pointer-p context)
                                   (format t "   Context created: ~a~%" context)))

       ;; 3. Create command queue
       (format t "3. Creating command queue...~%")
       (cffi:with-foreign-object (err :int)
                                 (setf queue (cl-create-command-queue context device 0 err))
                                 (format t "   Queue created: ~a~%" queue))

       ;; 4. Load SPIR-V binary
       (format t "4. Loading SPIR-V binary...~%")
       (let* ((spv-path "tests/spec/023-spirv/01-smoke.spv")
              (spv-data (with-open-file (stream spv-path :direction :input
                                                :element-type '(unsigned-byte 8))
                          (let* ((length (file-length stream))
                                 (data (make-array length :element-type '(unsigned-byte 8))))
                            (read-sequence data stream)
                            data))))
         (format t "   Loaded ~a bytes from ~a~%" (length spv-data) spv-path)

         ;; 5. Create program from SPIR-V
         (format t "5. Creating program from SPIR-V...~%")
         (cffi:with-foreign-object (err :int)
                                   (cffi:with-foreign-object (il-ptr :uchar (length spv-data))
                                                             (loop for i from 0 below (length spv-data)
                                                                   do (setf (cffi:mem-aref il-ptr :uchar i) (aref spv-data i)))
                                                             (setf program (cl-create-program-with-il context il-ptr (length spv-data) err))
                                                             (check-cl (cffi:mem-ref err :int))
                                                             (format t "   Program created: ~a~%" program)))

         ;; 6. Build program
         (format t "6. Building program...~%")
         (check-cl (cl-build-program program 0 (cffi:null-pointer)
                                     (cffi:null-pointer) (cffi:null-pointer) (cffi:null-pointer)))
         (format t "   Build successful!~%")

         ;; 7. Create kernel
         (format t "7. Creating kernel...~%")
         (cffi:with-foreign-object (err :int)
                                   (setf kernel (cl-create-kernel program "smoke_test_c_pointer_address_space_global_ulong_ulong" err))
                                   (check-cl (cffi:mem-ref err :int))
                                   (format t "   Kernel created: ~a~%" kernel))

         ;; 8. Create buffer (1 int)
         (format t "8. Creating buffer...~%")
         (cffi:with-foreign-object (err :int)
                                   (cffi:with-foreign-object (data :int 1)
                                                             (setf (cffi:mem-aref data :int 0) 0) ; Initialize to 0
                                                             (setf buffer-c (cl-create-buffer context +CL-MEM-READ-WRITE+
                                                                                              4 (cffi:null-pointer) err))
                                                             (check-cl (cffi:mem-ref err :int))
                                                             (format t "   Buffer created: ~a~%" buffer-c)))

         ;; 9. Set kernel arguments
         (format t "9. Setting kernel arguments...~%")
         (cffi:with-foreign-objects ((arg0 :pointer) (arg1 :ulong) (arg2 :ulong))
                                    (setf (cffi:mem-ref arg0 :pointer) buffer-c)
                                    (setf (cffi:mem-ref arg1 :ulong) 4) ; byte_size = 4
                                    (setf (cffi:mem-ref arg2 :ulong) 0) ; offset = 0
                                    (check-cl (cl-set-kernel-arg kernel 0 (cffi:foreign-type-size :pointer) arg0))
                                    (check-cl (cl-set-kernel-arg kernel 1 (cffi:foreign-type-size :ulong) arg1))
                                    (check-cl (cl-set-kernel-arg kernel 2 (cffi:foreign-type-size :ulong) arg2))
                                    (format t "   Arguments set~%"))

         ;; 10. Execute kernel
         (format t "10. Executing kernel...~%")
         (cffi:with-foreign-object (global-size :size 1)
                                   (setf (cffi:mem-aref global-size :size 0) 1)
                                   (check-cl (cl-enqueue-ndrange-kernel queue kernel 1
                                                                        (cffi:null-pointer) global-size (cffi:null-pointer)
                                                                        0 (cffi:null-pointer) (cffi:null-pointer))))
         (check-cl (cl-finish queue))
         (format t "   Kernel executed!~%")

         ;; 11. Read result
         (format t "11. Reading result...~%")
         (cffi:with-foreign-object (result :int 1)
                                   (check-cl (cl-enqueue-read-buffer queue buffer-c 1 0 4 result
                                                                     0 (cffi:null-pointer) (cffi:null-pointer)))
                                   (let ((value (cffi:mem-aref result :int 0)))
                                     (format t "   Result: ~a~%" value)
                                     (if (= value 42)
                                         (format t "~%✓ SUCCESS! Kernel wrote 42 to buffer!~%")
                                         (format t "~%✗ FAILED! Expected 42, got ~a~%" value))))))

    ;; Cleanup
    (format t "~%12. Cleaning up...~%")
    (when buffer-c (cl-release-mem-object buffer-c))
    (when kernel (cl-release-kernel kernel))
    (when program (cl-release-program program))
    (when queue (cl-release-command-queue queue))
    (when context (cl-release-context context))
    (format t "   Done!~%")))

(format t "~%=== Test Complete ===~%")
(uiop:quit 0)
