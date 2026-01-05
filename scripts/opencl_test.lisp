;; OpenCL Device Enumeration Test
;; Run with: sbcl --non-interactive --load scripts/opencl_test.lisp

(in-package :cl-user)

(format t "~&; Loading CFFI...~%")
(ql:quickload :cffi :silent t)

;;; === OpenCL Type Definitions ===

(defconstant +CL-SUCCESS+ 0)
(defconstant +CL-DEVICE-TYPE-GPU+ 4)
(defconstant +CL-DEVICE-TYPE-ALL+ #xFFFFFFFF)
(defconstant +CL-DEVICE-NAME+ #x102B)
(defconstant +CL-DEVICE-VENDOR+ #x102C)
(defconstant +CL-PLATFORM-NAME+ #x0902)
(defconstant +CL-PLATFORM-VENDOR+ #x0903)

;;; === OpenCL CFFI Bindings ===

(cffi:define-foreign-library opencl
                             (:windows "OpenCL.dll")
                             (:unix "libOpenCL.so")
                             (t (:default "libOpenCL")))

(cffi:use-foreign-library opencl)

;; clGetPlatformIDs(cl_uint num_entries, cl_platform_id *platforms, cl_uint *num_platforms)
(cffi:defcfun ("clGetPlatformIDs" cl-get-platform-ids) :int
              (num-entries :uint)
              (platforms :pointer)
              (num-platforms :pointer))

;; clGetDeviceIDs(cl_platform_id platform, cl_device_type device_type, 
;;                cl_uint num_entries, cl_device_id *devices, cl_uint *num_devices)
(cffi:defcfun ("clGetDeviceIDs" cl-get-device-ids) :int
              (platform :pointer)
              (device-type :ulong)
              (num-entries :uint)
              (devices :pointer)
              (num-devices :pointer))

;; clGetPlatformInfo(cl_platform_id platform, cl_platform_info param_name,
;;                   size_t param_value_size, void *param_value, size_t *param_value_size_ret)
(cffi:defcfun ("clGetPlatformInfo" cl-get-platform-info) :int
              (platform :pointer)
              (param-name :uint)
              (param-value-size :size)
              (param-value :pointer)
              (param-value-size-ret :pointer))

;; clGetDeviceInfo(cl_device_id device, cl_device_info param_name,
;;                 size_t param_value_size, void *param_value, size_t *param_value_size_ret)
(cffi:defcfun ("clGetDeviceInfo" cl-get-device-info) :int
              (device :pointer)
              (param-name :uint)
              (param-value-size :size)
              (param-value :pointer)
              (param-value-size-ret :pointer))

;;; === Helper Functions ===

(defun get-info-string (get-info-fn handle param-name)
  "Generic helper to get a string info value from OpenCL."
  (cffi:with-foreign-object (size-ret :size)
                            ;; First call to get size
                            (let ((err (funcall get-info-fn handle param-name 0 (cffi:null-pointer) size-ret)))
                              (unless (= err +CL-SUCCESS+)
                                (error "Failed to get info size: ~a" err))
                              (let ((size (cffi:mem-ref size-ret :size)))
                                ;; Second call to get actual string
                                (cffi:with-foreign-pointer (str-ptr size)
                                                           (let ((err2 (funcall get-info-fn handle param-name size str-ptr (cffi:null-pointer))))
                                                             (unless (= err2 +CL-SUCCESS+)
                                                               (error "Failed to get info string: ~a" err2))
                                                             (cffi:foreign-string-to-lisp str-ptr)))))))

;;; === Main Test ===

(format t "~%=== OpenCL Device Enumeration ===~%~%")

;; 1. Get number of platforms
(cffi:with-foreign-object (num-platforms :uint)
                          (let ((err (cl-get-platform-ids 0 (cffi:null-pointer) num-platforms)))
                            (unless (= err +CL-SUCCESS+)
                              (error "Failed to get platform count: error ~a" err))

                            (let ((platform-count (cffi:mem-ref num-platforms :uint)))
                              (format t "Found ~a OpenCL platform(s)~%~%" platform-count)

                              (when (zerop platform-count)
                                    (format t "No OpenCL platforms found!~%")
                                    (uiop:quit 1))

                              ;; 2. Get platform IDs
                              (cffi:with-foreign-object (platforms :pointer platform-count)
                                                        (let ((err2 (cl-get-platform-ids platform-count platforms (cffi:null-pointer))))
                                                          (unless (= err2 +CL-SUCCESS+)
                                                            (error "Failed to get platforms: error ~a" err2))

                                                          ;; 3. For each platform, query devices
                                                          (dotimes (i platform-count)
                                                            (let ((platform (cffi:mem-aref platforms :pointer i)))
                                                              (format t "Platform ~a:~%" i)
                                                              (format t "  Name: ~a~%"
                                                                (get-info-string #'cl-get-platform-info platform +CL-PLATFORM-NAME+))
                                                              (format t "  Vendor: ~a~%"
                                                                (get-info-string #'cl-get-platform-info platform +CL-PLATFORM-VENDOR+))

                                                              ;; Query devices
                                                              (cffi:with-foreign-object (num-devices :uint)
                                                                                        (let ((err3 (cl-get-device-ids platform +CL-DEVICE-TYPE-ALL+ 0
                                                                                                                       (cffi:null-pointer) num-devices)))
                                                                                          (if (= err3 +CL-SUCCESS+)
                                                                                              (let ((device-count (cffi:mem-ref num-devices :uint)))
                                                                                                (format t "  Devices: ~a~%~%" device-count)

                                                                                                (cffi:with-foreign-object (devices :pointer device-count)
                                                                                                                          (cl-get-device-ids platform +CL-DEVICE-TYPE-ALL+ device-count
                                                                                                                                             devices (cffi:null-pointer))

                                                                                                                          ;; Print each device
                                                                                                                          (dotimes (j device-count)
                                                                                                                            (let ((device (cffi:mem-aref devices :pointer j)))
                                                                                                                              (format t "    Device ~a:~%" j)
                                                                                                                              (format t "      Name: ~a~%"
                                                                                                                                (get-info-string #'cl-get-device-info device +CL-DEVICE-NAME+))
                                                                                                                              (format t "      Vendor: ~a~%~%"
                                                                                                                                (get-info-string #'cl-get-device-info device +CL-DEVICE-VENDOR+))))))
                                                                                              (format t "  No devices found for this platform~%~%")))))))))))

(format t "~%=== Test Complete ===~%")
(uiop:quit 0)
