;; scripts/run-spirv.lisp
;; Usage: sbcl --script scripts/run-spirv.lisp [path/to/kernel.spv]

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(ql:quickload "cffi")

(defpackage :crisp.runtime.opencl
  (:use :cl :cffi))

(in-package :crisp.runtime.opencl)

;; --- CFFI Setup ---
(define-foreign-library libopencl
                        (:windows "OpenCL.dll")
                        (:linux "libOpenCL.so")
                        (t (:default "libOpenCL")))

(use-foreign-library libopencl)

;; --- OpenCL Types ---
(defctype cl_int :int)
(defctype cl_uint :unsigned-int)
(defctype cl_platform_id :pointer)
(defctype cl_device_id :pointer)
(defctype cl_context :pointer)
(defctype cl_command_queue :pointer)
(defctype cl_mem :pointer)
(defctype cl_program :pointer)
(defctype cl_kernel :pointer)
(defctype cl_event :pointer)
(defctype size_t :unsigned-long-long) ;; Assuming 64-bit

;; --- OpenCL Constants ---
(defconstant CL_SUCCESS 0)
(defconstant CL_DEVICE_TYPE_GPU 4)
(defconstant CL_MEM_READ_WRITE 1)
(defconstant CL_MEM_COPY_HOST_PTR 32)
(defconstant CL_PROGRAM_BUILD_LOG #x1183)
(defconstant CL_KERNEL_FUNCTION_NAME #x1190)

;; --- OpenCL Functions ---
(defcfun "clGetPlatformIDs" cl_int
         (num_entries cl_uint)
         (platforms :pointer)
         (num_platforms :pointer))

(defcfun "clGetDeviceIDs" cl_int
         (platform cl_platform_id)
         (device_type :unsigned-long-long)
         (num_entries cl_uint)
         (devices :pointer)
         (num_devices :pointer))

(defcfun "clCreateContext" cl_context
         (properties :pointer)
         (num_devices cl_uint)
         (devices :pointer)
         (pfn_notify :pointer)
         (user_data :pointer)
         (errcode_ret :pointer))

(defcfun "clCreateCommandQueue" cl_command_queue
         (context cl_context)
         (device cl_device_id)
         (properties :unsigned-long-long)
         (errcode_ret :pointer))

(defcfun "clCreateProgramWithIL" cl_program
         (context cl_context)
         (il :pointer)
         (length size_t)
         (errcode_ret :pointer))

(defcfun "clBuildProgram" cl_int
         (program cl_program)
         (num_devices cl_uint)
         (device_list :pointer)
         (options :string)
         (pfn_notify :pointer)
         (user_data :pointer))

(defcfun "clCreateKernel" cl_kernel
         (program cl_program)
         (kernel_name :string)
         (errcode_ret :pointer))

(defcfun "clCreateBuffer" cl_mem
         (context cl_context)
         (flags :unsigned-long-long)
         (size size_t)
         (host_ptr :pointer)
         (errcode_ret :pointer))

(defcfun "clEnqueueWriteBuffer" cl_int
         (command_queue cl_command_queue)
         (buffer cl_mem)
         (blocking_write cl_int)
         (offset size_t)
         (size size_t)
         (ptr :pointer)
         (num_events_in_wait_list cl_uint)
         (event_wait_list :pointer)
         (event :pointer))

(defcfun "clSetKernelArg" cl_int
         (kernel cl_kernel)
         (arg_index cl_uint)
         (arg_size size_t)
         (arg_value :pointer))

(defcfun "clEnqueueNDRangeKernel" cl_int
         (command_queue cl_command_queue)
         (kernel cl_kernel)
         (work_dim cl_uint)
         (global_work_offset :pointer)
         (global_work_size :pointer)
         (local_work_size :pointer)
         (num_events_in_wait_list cl_uint)
         (event_wait_list :pointer)
         (event :pointer))

(defcfun "clEnqueueReadBuffer" cl_int
         (command_queue cl_command_queue)
         (buffer cl_mem)
         (blocking_read cl_int)
         (offset size_t)
         (size size_t)
         (ptr :pointer)
         (num_events_in_wait_list cl_uint)
         (event_wait_list :pointer)
         (event :pointer))

(defcfun "clFinish" cl_int (command_queue cl_command_queue))
(defcfun "clReleaseKernel" cl_int (kernel cl_kernel))
(defcfun "clReleaseProgram" cl_int (program cl_program))
(defcfun "clReleaseMemObject" cl_int (memobj cl_mem))
(defcfun "clReleaseCommandQueue" cl_int (command_queue cl_command_queue))
(defcfun "clReleaseContext" cl_int (context cl_context))
(defcfun "clGetProgramBuildInfo" cl_int
         (program cl_program)
         (device cl_device_id)
         (param_name cl_uint)
         (param_value_size size_t)
         (param_value :pointer)
         (param_value_size_ret :pointer))

(defcfun "clCreateKernelsInProgram" cl_int
         (program cl_program)
         (num_kernels cl_uint)
         (kernels :pointer)
         (num_kernels_ret :pointer))

(defcfun "clGetKernelInfo" cl_int
         (kernel cl_kernel)
         (param_name cl_uint)
         (param_value_size size_t)
         (param_value :pointer)
         (param_value_size_ret :pointer))

;; --- Helper Logic ---

(defun check-error (err fn-name)
  (unless (zerop err)
    (error "OpenCL Error in ~a: ~a" fn-name err)))

(defun get-gpu-device ()
  (with-foreign-objects ((num-platforms :uint)
                         (platform :pointer))
                        (check-error (clGetPlatformIDs 1 platform num-platforms) "clGetPlatformIDs")
                        (let ((pid (mem-ref platform :pointer)))
                          (with-foreign-objects ((num-devices :uint)
                                                 (device :pointer))
                                                (check-error (clGetDeviceIDs pid CL_DEVICE_TYPE_GPU 1 device num-devices) "clGetDeviceIDs")
                                                (mem-ref device :pointer)))))

(defun read-file-to-byte-vector (path)
  (with-open-file (s path :direction :input :element-type '(unsigned-byte 8))
    (let* ((len (file-length s))
           (vec (make-array len :element-type '(unsigned-byte 8))))
      (read-sequence vec s)
      vec)))

(defun run-test ()
  (let ((spv-path (or (second (uiop:command-line-arguments))
                      "tests/spec/023-spirv/01-smoke.spv")))
    (format t "~&Loaded Run-SPIRV... Target: ~a~%" spv-path)

    (unless (probe-file spv-path)
      (error "SPIR-V file not found: ~a. Run 'sbcl --script tests/run-specs.lisp' first." spv-path))

    (let* ((device (get-gpu-device))
           (context (clCreateContext (null-pointer) 1 (make-pointer (pointer-address (foreign-alloc :pointer :initial-element device))) (null-pointer) (null-pointer) (null-pointer)))
           (queue (clCreateCommandQueue context device 0 (null-pointer))))

      (format t "Context & Queue Created on Device: ~a~%" device)

      ;; Load SPIR-V
      (let* ((spv-bytes (read-file-to-byte-vector spv-path))
             (spv-len (length spv-bytes)))
        (format t "Read ~d bytes of SPIR-V.~%" spv-len)

        (with-foreign-array (il spv-bytes `(:array :unsigned-char ,spv-len))
                            (with-foreign-object (err :int)
                                                 (let ((program (clCreateProgramWithIL context il spv-len err)))
                                                   (check-error (mem-ref err :int) "clCreateProgramWithIL")

                                                   (format t "Building Program...~%")
                                                   (let ((build-res (clBuildProgram program 1 (make-pointer (pointer-address (foreign-alloc :pointer :initial-element device))) (null-pointer) (null-pointer) (null-pointer))))
                                                     (unless (zerop build-res)
                                                       (format t "Build Failed. Log:~%")
                                                       (with-foreign-object (log-size :unsigned-long-long)
                                                                            (clGetProgramBuildInfo program device CL_PROGRAM_BUILD_LOG 0 (null-pointer) log-size)
                                                                            (let* ((len (mem-ref log-size :unsigned-long-long))
                                                                                   (log (foreign-alloc :char :count len)))
                                                                              (clGetProgramBuildInfo program device CL_PROGRAM_BUILD_LOG len log (null-pointer))
                                                                              (format t "~a~%" (foreign-string-to-lisp log))
                                                                              (error "Build Failed"))))
                                                     (format t "Program Built Successfully.~%"))

                                                   ;; Discover Kernels
                                                   (format t "Discovering Kernels...~%")
                                                   (with-foreign-object (num-kernels :uint)
                                                                        (check-error (clCreateKernelsInProgram program 0 (null-pointer) num-kernels) "clCreateKernelsInProgram(Count)")
                                                                        (let ((count (mem-ref num-kernels :uint)))
                                                                          (format t "Found ~d kernels.~%" count)
                                                                          (when (zerop count) (error "No kernels found in SPIR-V."))

                                                                          (with-foreign-object (kernels :pointer count)
                                                                                               (check-error (clCreateKernelsInProgram program count kernels (null-pointer)) "clCreateKernelsInProgram(Kernels)")

                                                                                               ;; Use the first kernel
                                                                                               (let ((kernel (mem-aref kernels :pointer 0)))
                                                                                                 ;; Get Name
                                                                                                 (with-foreign-object (name-len :unsigned-long-long)
                                                                                                                      (clGetKernelInfo kernel CL_KERNEL_FUNCTION_NAME 0 (null-pointer) name-len)
                                                                                                                      (let* ((len (mem-ref name-len :unsigned-long-long))
                                                                                                                             (name-ptr (foreign-alloc :char :count len)))
                                                                                                                        (clGetKernelInfo kernel CL_KERNEL_FUNCTION_NAME len name-ptr (null-pointer))
                                                                                                                        (format t "Using Kernel: ~a~%" (foreign-string-to-lisp name-ptr))))

                                                                                                 ;; Continue with 'kernel' logic
                                                                                                 ;; Allocate Buffer (Int)
                                                                                                 (let ((buf-size 4)) ;; sizeof(int)
                                                                                                   (let ((mem (clCreateBuffer context CL_MEM_READ_WRITE buf-size (null-pointer) err)))
                                                                                                     (check-error (mem-ref err :int) "clCreateBuffer")

                                                                                                     ;; Zero initialize
                                                                                                     (with-foreign-object (zero :int)
                                                                                                                          (setf (mem-ref zero :int) 0)
                                                                                                                          (clEnqueueWriteBuffer queue mem 1 0 buf-size zero 0 (null-pointer) (null-pointer)))

                                                                                                     ;; Set Args
                                                                                                     ;; ABI: (ptr buffer, u64 size, u64 offset)

                                                                                                     ;; Arg 0: Buffer Handle (cl_mem)
                                                                                                     (with-foreign-object (mem-ptr :pointer)
                                                                                                                          (setf (mem-ref mem-ptr :pointer) mem)
                                                                                                                          (clSetKernelArg kernel 0 (foreign-type-size :pointer) mem-ptr))

                                                                                                     ;; Arg 1: Size (u64)
                                                                                                     (with-foreign-object (size-ptr :unsigned-long-long)
                                                                                                                          (setf (mem-ref size-ptr :unsigned-long-long) buf-size)
                                                                                                                          (clSetKernelArg kernel 1 (foreign-type-size :unsigned-long-long) size-ptr))

                                                                                                     ;; Arg 2: Offset (u64)
                                                                                                     (with-foreign-object (offset-ptr :unsigned-long-long)
                                                                                                                          (setf (mem-ref offset-ptr :unsigned-long-long) 0)
                                                                                                                          (clSetKernelArg kernel 2 (foreign-type-size :unsigned-long-long) offset-ptr))

                                                                                                     (format t "Kernel Args Set. Enqueuing...~%")

                                                                                                     ;; Enqueue NDRange
                                                                                                     (with-foreign-object (global-work-size :unsigned-long-long)
                                                                                                                          (setf (mem-ref global-work-size :unsigned-long-long) 1) ;; 1 thread
                                                                                                                          (check-error
                                                                                                                           (clEnqueueNDRangeKernel queue kernel 1 (null-pointer) global-work-size (null-pointer) (null-pointer) 0 (null-pointer) (null-pointer))
                                                                                                                           "clEnqueueNDRangeKernel"))

                                                                                                     (format t "Kernel Executed. Reading result...~%")
                                                                                                     (clFinish queue)

                                                                                                     ;; Read Back
                                                                                                     (with-foreign-object (result :int)
                                                                                                                          (clEnqueueReadBuffer queue mem 1 0 buf-size result 0 (null-pointer) (null-pointer))
                                                                                                                          (let ((val (mem-ref result :int)))
                                                                                                                            (format t "Result: ~d (Expected: 42)~%" val)
                                                                                                                            (if (= val 42)
                                                                                                                                (format t "SUCCESS!~%")
                                                                                                                                (error "FAILURE: Expected 42, got ~d" val)))))))))))))))))

(run-test)
