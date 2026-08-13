;;;; tests/cuda-bindings.lisp
;;;;
;;;; CFFI bindings for the CUDA Driver API (`nvcuda.dll` on Windows,
;;;; `libcuda.so.1` on Linux).  Just enough surface to JIT a PTX module,
;;;; get a kernel from it, allocate managed (unified) buffers, launch with
;;;; a kernelParams array, and synchronise.
;;;;
;;;; This is the CUDA counterpart of tests/l0-bindings.lisp, written for
;;;; endeavor 147 (CUDA VERIFY-AUTODIFF).
;;;;
;;;; Reference: /usr/local/cuda-12.4/include/cuda.h (values below were read
;;;; off that header on the H100 pod, not recalled).
;;;;
;;;; Calling-convention notes:
;;;;   - CUresult is a 4-byte enum.  Return :int.
;;;;   - CUdeviceptr is `unsigned long long` on x64 -> :uint64.  It is NOT a
;;;;     C pointer type, but under cuMemAllocManaged the same value IS a
;;;;     valid host address, so we hand it around as a CFFI pointer (see
;;;;     CU-ALLOC-MANAGED) and every host-side mem-ref path from the L0
;;;;     runner works unchanged.
;;;;   - CUdevice is `int`, not a handle.
;;;;   - MANY driver entry points are versioned: the header #defines
;;;;     cuCtxCreate -> cuCtxCreate_v2, cuMemAlloc -> cuMemAlloc_v2, etc.
;;;;     The UNVERSIONED symbols still exist in libcuda and are the OLD
;;;;     32-bit-size ABI, so binding them by their plain name silently gets
;;;;     the wrong calling convention.  Always bind the _v2 names.
;;;;
;;;; Lifecycle:
;;;;   cuInit                      once per process
;;;;   cuDeviceGet                 device 0
;;;;   cuCtxCreate_v2              one context for everything below
;;;;   cuModuleLoadDataEx          JIT from PTX text (driver compiles it)
;;;;   cuModuleGetFunction         entry point by name
;;;;   cuMemAllocManaged           unified buffer (host-addressable)
;;;;   cuLaunchKernel              grid/block/sharedMemBytes/kernelParams
;;;;   cuCtxSynchronize            blocks until completion
;;;;   (destroy in reverse)

(in-package :cl-user)

(unless (find-package :cffi)
  (format t "~&; Loading CFFI for CUDA bindings...~%")
  (ql:quickload :cffi :silent t))

;;; === Constants =========================================================

(defconstant +CUDA-SUCCESS+ 0)

(defconstant +CU-MEM-ATTACH-GLOBAL+ #x1)

;;; CUjit_option
(defconstant +CU-JIT-INFO-LOG-BUFFER+             3)
(defconstant +CU-JIT-INFO-LOG-BUFFER-SIZE-BYTES+  4)
(defconstant +CU-JIT-ERROR-LOG-BUFFER+            5)
(defconstant +CU-JIT-ERROR-LOG-BUFFER-SIZE-BYTES+ 6)

;;; CUfunction_attribute.  Dynamic shared memory above the default 48 KB
;;; cap must be opted into per function, or the launch fails with
;;; CUDA_ERROR_INVALID_VALUE.  An MMA backward with several staged tiles
;;; plus their _ADJ shadows can cross that line.
(defconstant +CU-FUNC-ATTRIBUTE-MAX-DYNAMIC-SHARED-SIZE-BYTES+ 8)

;;; CUdevice_attribute
(defconstant +CU-DEVICE-ATTRIBUTE-COMPUTE-CAPABILITY-MAJOR+ 75)
(defconstant +CU-DEVICE-ATTRIBUTE-COMPUTE-CAPABILITY-MINOR+ 76)

;;; --- Tensor map (TMA, sm_90+) -----------------------------------------
;;; CUtensorMap is `struct { alignas(64) cuuint64_t opaque[16]; }`.
(defconstant +CU-TENSOR-MAP-NUM-QWORDS+ 16)
(defconstant +CU-TENSOR-MAP-BYTES+      128)
(defconstant +CU-TENSOR-MAP-ALIGN+      64)

;;; CUtensorMapDataType (UINT8=0 ... FLOAT32=7, FLOAT64=8, TFLOAT32=11)
(defconstant +CU-TENSOR-MAP-DATA-TYPE-FLOAT32+  7)
(defconstant +CU-TENSOR-MAP-DATA-TYPE-FLOAT64+  8)
(defconstant +CU-TENSOR-MAP-DATA-TYPE-TFLOAT32+ 11)

(defconstant +CU-TENSOR-MAP-INTERLEAVE-NONE+ 0)
(defconstant +CU-TENSOR-MAP-SWIZZLE-NONE+    0)
(defconstant +CU-TENSOR-MAP-SWIZZLE-32B+     1)
(defconstant +CU-TENSOR-MAP-SWIZZLE-64B+     2)
(defconstant +CU-TENSOR-MAP-SWIZZLE-128B+    3)
(defconstant +CU-TENSOR-MAP-L2-PROMOTION-NONE+   0)
(defconstant +CU-TENSOR-MAP-FLOAT-OOB-FILL-NONE+ 0)

;;; === Library load ======================================================

(cffi:define-foreign-library cuda-driver
                             (:windows "nvcuda.dll")
                             (:unix (:or "libcuda.so.1" "libcuda.so"))
                             (t (:default "libcuda")))

(defvar *cuda-library-loaded* nil
  "T when libcuda linked successfully at load time.  NIL on a machine with
   no NVIDIA driver.

   The link is attempted but NOT allowed to signal: this file has to LOAD
   on an Intel-only box so that verify-autodiff-runner.lisp — which pulls in
   every runtime's bindings so its helpers can be compiled — still loads
   there.  A hard failure here would take the whole runner down and turn
   every VERIFY-AUTODIFF check on that machine into a SKIP.  Callers check
   this flag (see CUDA-AVAILABLE-P) before dispatching to :cuda.")

(handler-case
    (progn (cffi:use-foreign-library cuda-driver)
           (setf *cuda-library-loaded* t))
  (error (e)
    (setf *cuda-library-loaded* nil)
    (format t "~&; CUDA driver library not available (~a) — :cuda runtime disabled.~%" e)))

;;; === Function bindings =================================================

(cffi:defcfun ("cuInit" cu-init) :int
              (flags :uint))

(cffi:defcfun ("cuDriverGetVersion" cu-driver-get-version) :int
              (version :pointer))

(cffi:defcfun ("cuDeviceGet" cu-device-get) :int
              (device :pointer) (ordinal :int))

(cffi:defcfun ("cuDeviceGetCount" cu-device-get-count) :int
              (count :pointer))

(cffi:defcfun ("cuDeviceGetName" cu-device-get-name) :int
              (name :pointer) (len :int) (dev :int))

(cffi:defcfun ("cuDeviceGetAttribute" cu-device-get-attribute) :int
              (pi-out :pointer) (attrib :int) (dev :int))

(cffi:defcfun ("cuCtxCreate_v2" cu-ctx-create) :int
              (pctx :pointer) (flags :uint) (dev :int))

(cffi:defcfun ("cuCtxDestroy_v2" cu-ctx-destroy) :int
              (ctx :pointer))

(cffi:defcfun ("cuCtxSynchronize" cu-ctx-synchronize) :int)

(cffi:defcfun ("cuModuleLoadDataEx" cu-module-load-data-ex) :int
              (module :pointer) (image :pointer) (num-options :uint)
              (options :pointer) (option-values :pointer))

(cffi:defcfun ("cuModuleGetFunction" cu-module-get-function) :int
              (hfunc :pointer) (hmod :pointer) (name :string))

(cffi:defcfun ("cuModuleUnload" cu-module-unload) :int
              (hmod :pointer))

(cffi:defcfun ("cuMemAllocManaged" cu-mem-alloc-managed) :int
              (dptr :pointer) (bytesize :size) (flags :uint))

(cffi:defcfun ("cuMemAlloc_v2" cu-mem-alloc) :int
              (dptr :pointer) (bytesize :size))

(cffi:defcfun ("cuMemFree_v2" cu-mem-free) :int
              (dptr :uint64))

(cffi:defcfun ("cuMemcpyHtoD_v2" cu-memcpy-htod) :int
              (dst :uint64) (src :pointer) (bytecount :size))

(cffi:defcfun ("cuMemcpyDtoH_v2" cu-memcpy-dtoh) :int
              (dst :pointer) (src :uint64) (bytecount :size))

(cffi:defcfun ("cuMemsetD8_v2" cu-memset-d8) :int
              (dst :uint64) (uc :uchar) (n :size))

(cffi:defcfun ("cuLaunchKernel" cu-launch-kernel) :int
              (f :pointer)
              (grid-x :uint) (grid-y :uint) (grid-z :uint)
              (block-x :uint) (block-y :uint) (block-z :uint)
              (shared-mem-bytes :uint) (hstream :pointer)
              (kernel-params :pointer) (extra :pointer))

(cffi:defcfun ("cuFuncSetAttribute" cu-func-set-attribute) :int
              (hfunc :pointer) (attrib :int) (value :int))

(cffi:defcfun ("cuGetErrorString" cu-get-error-string) :int
              (error :int) (pstr :pointer))

(cffi:defcfun ("cuGetErrorName" cu-get-error-name) :int
              (error :int) (pstr :pointer))

;;; cuTensorMapEncodeTiled — TMA descriptor encode (sm_90+, CUDA 12+).
;;; Bound directly; CU-TENSOR-MAP-AVAILABLE-P below lets callers degrade
;;; gracefully on a driver that predates it rather than trapping.
(cffi:defcfun ("cuTensorMapEncodeTiled" cu-tensor-map-encode-tiled) :int
              (tensor-map :pointer) (tensor-data-type :int) (tensor-rank :uint32)
              (global-address :pointer) (global-dim :pointer) (global-strides :pointer)
              (box-dim :pointer) (element-strides :pointer)
              (interleave :int) (swizzle :int) (l2-promotion :int) (oob-fill :int))

;;; === Error helpers =====================================================

(defun cu-error-string (code)
  "Human-readable driver message for CUresult CODE (name + description)."
  (flet ((fetch (fn)
           (cffi:with-foreign-object (p :pointer)
             (setf (cffi:mem-ref p :pointer) (cffi:null-pointer))
             (if (and (zerop (funcall fn code p))
                      (not (cffi:null-pointer-p (cffi:mem-ref p :pointer))))
                 (cffi:foreign-string-to-lisp (cffi:mem-ref p :pointer))
                 nil))))
    (let ((name (fetch #'cu-get-error-name))
          (desc (fetch #'cu-get-error-string)))
      (cond ((and name desc) (format nil "~a: ~a" name desc))
            (name name)
            (desc desc)
            (t (format nil "CUresult ~D" code))))))

(defmacro check-cu (form)
  "Wraps a CUDA driver call.  Signals an error with the driver's own
   message on failure."
  `(let ((err ,form))
     (unless (= err +CUDA-SUCCESS+)
       (error "CUDA error ~D (~a) in ~a" err (cu-error-string err) ',form))))

(defun cuda-available-p ()
  "T when libcuda linked AND at least one CUDA device is present.  This is
   the gate the runner gets asked before dispatching to :cuda."
  (and *cuda-library-loaded*
       (ignore-errors
        (and (= +CUDA-SUCCESS+ (cu-init 0))
             (cffi:with-foreign-object (n :int)
               (and (= +CUDA-SUCCESS+ (cu-device-get-count n))
                    (> (cffi:mem-ref n :int) 0)))))))

(defun cu-tensor-map-available-p ()
  "T when the loaded driver exports cuTensorMapEncodeTiled (CUDA 12+)."
  (and *cuda-library-loaded*
       (cffi:foreign-symbol-pointer "cuTensorMapEncodeTiled")
       t))

;;; === Convenience =======================================================

(defun cu-alloc-managed (bytes &optional (alignment 0))
  "Allocate BYTES of managed (unified) memory and return it as a CFFI
   POINTER.  Managed memory is addressable from both host and device, so
   the returned pointer serves as the kernel argument value AND as a host
   pointer for staging/read-back — exactly the role zeMemAllocShared plays
   under Level Zero.

   ALIGNMENT is accepted for signature-compatibility with the L0 allocator
   and is otherwise unused: cuMemAllocManaged already returns memory
   aligned to at least 256 bytes."
  (declare (ignore alignment))
  (cffi:with-foreign-object (dptr :uint64)
    (setf (cffi:mem-ref dptr :uint64) 0)
    (check-cu (cu-mem-alloc-managed dptr bytes +CU-MEM-ATTACH-GLOBAL+))
    (cffi:make-pointer (cffi:mem-ref dptr :uint64))))

(defun cu-free (ptr)
  "Free a buffer returned by CU-ALLOC-MANAGED."
  (when (and ptr (not (cffi:null-pointer-p ptr)))
    (cu-mem-free (cffi:pointer-address ptr))))

(defun cu-device-name (dev)
  "Device name string for CUdevice DEV."
  (cffi:with-foreign-object (buf :char 256)
    (check-cu (cu-device-get-name buf 256 dev))
    (cffi:foreign-string-to-lisp buf)))

(defun cu-compute-capability (dev)
  "Returns (values MAJOR MINOR) for CUdevice DEV."
  (cffi:with-foreign-objects ((maj :int) (minr :int))
    (check-cu (cu-device-get-attribute maj +CU-DEVICE-ATTRIBUTE-COMPUTE-CAPABILITY-MAJOR+ dev))
    (check-cu (cu-device-get-attribute minr +CU-DEVICE-ATTRIBUTE-COMPUTE-CAPABILITY-MINOR+ dev))
    (values (cffi:mem-ref maj :int) (cffi:mem-ref minr :int))))

(defun cu-module-load-ptx (ptx-string)
  "JIT-compiles PTX-STRING via the driver and returns the CUmodule.
   On failure, signals an error carrying the JIT error log — without it a
   bad .target line or an unsupported opcode just reports a bare
   CUDA_ERROR_INVALID_PTX, which is untraceable."
  (let ((log-size 16384))
    (cffi:with-foreign-object (err-log :char log-size)
      (setf (cffi:mem-aref err-log :char 0) 0)
      (cffi:with-foreign-objects ((opts :int 2)
                                  (vals :pointer 2)
                                  (mod-out :pointer))
        (setf (cffi:mem-aref opts :int 0) +CU-JIT-ERROR-LOG-BUFFER+
              (cffi:mem-aref opts :int 1) +CU-JIT-ERROR-LOG-BUFFER-SIZE-BYTES+
              (cffi:mem-aref vals :pointer 0) err-log
              ;; Option values are void*-sized; an integer option is passed
              ;; by CASTING the integer into the pointer slot, not by
              ;; pointing at it.
              (cffi:mem-aref vals :pointer 1) (cffi:make-pointer log-size))
        (cffi:with-foreign-string (image ptx-string)
          (let ((err (cu-module-load-data-ex mod-out image 2 opts vals)))
            (unless (= err +CUDA-SUCCESS+)
              (error "CUDA cuModuleLoadDataEx failed: ~D (~a)~@[~%  JIT log:~%~a~]"
                     err (cu-error-string err)
                     (let ((s (cffi:foreign-string-to-lisp err-log)))
                       (if (string= s "") nil s))))
            (cffi:mem-ref mod-out :pointer)))))))

(format t "~&; CUDA CFFI bindings loaded (libcuda linked successfully).~%")
