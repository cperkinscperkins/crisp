;;;; tests/l0-bindings.lisp
;;;;
;;;; CFFI bindings for the Level Zero loader (`ze_loader.dll` on Windows,
;;;; `libze_loader.so` on Linux).  Just enough surface to load a SPIR-V
;;;; module, create a kernel from it, allocate USM-shared buffers, bind
;;;; args, launch, and synchronise.
;;;;
;;;; Reference: C:/Users/cperk/Documents/level-zero/include/ze_api.h
;;;;
;;;; Calling convention notes:
;;;;   - ze_result_t is a 4-byte unsigned enum.  Return :uint32.
;;;;   - size_t is 8 bytes on x64 (CFFI :size).
;;;;   - All "stype" discriminator values come from ze_structure_type_t.
;;;;   - All struct ZERO-INIT before setting stype + active fields; pNext = NULL.
;;;;
;;;; Lifecycle:
;;;;   zeInit                       once per process
;;;;   zeDriverGet                  get first driver
;;;;   zeDeviceGet                  get first GPU device under driver
;;;;   zeContextCreate              one context for everything below
;;;;   zeModuleCreate               from SPIR-V bytes
;;;;   zeKernelCreate               from module + entry-point name
;;;;   zeMemAllocShared             USM buffer (host-addressable)
;;;;   zeKernelSetGroupSize         REQUIRED before launch (unlike OpenCL)
;;;;   zeKernelSetArgumentValue     per-arg binding
;;;;   zeCommandListCreate          batched command list
;;;;     zeCommandListAppendLaunchKernel
;;;;     zeCommandListClose
;;;;   zeCommandQueueCreate
;;;;   zeCommandQueueExecuteCommandLists
;;;;   zeCommandQueueSynchronize    blocks until completion
;;;;   (destroy in reverse)

(in-package :cl-user)

(unless (find-package :cffi)
  (format t "~&; Loading CFFI for L0 bindings...~%")
  (ql:quickload :cffi :silent t))

;;; === Constants =========================================================

(defconstant +ZE-RESULT-SUCCESS+ 0)
(defconstant +ZE-INIT-FLAG-GPU-ONLY+ 1)
(defconstant +ZE-MODULE-FORMAT-IL-SPIRV+ 0)

;;; ze_structure_type_t discriminators (from ze_api.h enum).
(defconstant +ZE-STYPE-DEVICE-PROPERTIES+        #x3)
(defconstant +ZE-STYPE-CONTEXT-DESC+             #xd)
(defconstant +ZE-STYPE-COMMAND-QUEUE-DESC+       #xe)
(defconstant +ZE-STYPE-COMMAND-LIST-DESC+        #xf)
(defconstant +ZE-STYPE-DEVICE-MEM-ALLOC-DESC+    #x15)
(defconstant +ZE-STYPE-HOST-MEM-ALLOC-DESC+      #x16)
(defconstant +ZE-STYPE-MODULE-DESC+              #x1b)
(defconstant +ZE-STYPE-KERNEL-DESC+              #x1d)

;;; UINT64_MAX — `zeCommandQueueSynchronize` "block forever" sentinel.
(defconstant +ZE-UINT64-MAX+ (1- (expt 2 64)))

;;; === Library load ======================================================

(cffi:define-foreign-library ze-loader
                             (:windows "ze_loader.dll")
                             (:unix "libze_loader.so")
                             (t (:default "libze_loader")))

(cffi:use-foreign-library ze-loader)

;;; === Structs ===========================================================
;;;
;;; CFFI computes the padding/alignment for us.  Field order matches the
;;; C header verbatim.

(cffi:defcstruct ze-module-desc
                 (stype :uint32) (p-next :pointer)
                 (format :uint32) (input-size :size)
                 (p-input-module :pointer) (p-build-flags :pointer)
                 (p-constants :pointer))

(cffi:defcstruct ze-kernel-desc
                 (stype :uint32) (p-next :pointer)
                 (flags :uint32) (p-kernel-name :pointer))

(cffi:defcstruct ze-command-queue-desc
                 (stype :uint32) (p-next :pointer)
                 (ordinal :uint32) (index :uint32)
                 (flags :uint32) (mode :uint32) (priority :uint32))

(cffi:defcstruct ze-command-list-desc
                 (stype :uint32) (p-next :pointer)
                 (command-queue-group-ordinal :uint32) (flags :uint32))

(cffi:defcstruct ze-device-mem-alloc-desc
                 (stype :uint32) (p-next :pointer)
                 (flags :uint32) (ordinal :uint32))

(cffi:defcstruct ze-host-mem-alloc-desc
                 (stype :uint32) (p-next :pointer)
                 (flags :uint32))

(cffi:defcstruct ze-context-desc
                 (stype :uint32) (p-next :pointer)
                 (flags :uint32))

(cffi:defcstruct ze-group-count
                 (x :uint32) (y :uint32) (z :uint32))

;;; === Function bindings =================================================

(cffi:defcfun ("zeInit" ze-init) :uint32
              (flags :uint32))

(cffi:defcfun ("zeDriverGet" ze-driver-get) :uint32
              (p-count :pointer) (drivers :pointer))

(cffi:defcfun ("zeDeviceGet" ze-device-get) :uint32
              (driver :pointer) (p-count :pointer) (devices :pointer))

(cffi:defcfun ("zeContextCreate" ze-context-create) :uint32
              (driver :pointer) (desc :pointer) (context :pointer))

(cffi:defcfun ("zeContextDestroy" ze-context-destroy) :uint32
              (context :pointer))

(cffi:defcfun ("zeModuleCreate" ze-module-create) :uint32
              (context :pointer) (device :pointer) (desc :pointer)
              (module :pointer) (build-log :pointer))

(cffi:defcfun ("zeModuleDestroy" ze-module-destroy) :uint32
              (module :pointer))

(cffi:defcfun ("zeModuleBuildLogGetString" ze-module-build-log-get-string) :uint32
              (build-log :pointer) (p-size :pointer) (p-build-log :pointer))

(cffi:defcfun ("zeModuleBuildLogDestroy" ze-module-build-log-destroy) :uint32
              (build-log :pointer))

(cffi:defcfun ("zeKernelCreate" ze-kernel-create) :uint32
              (module :pointer) (desc :pointer) (kernel :pointer))

(cffi:defcfun ("zeKernelDestroy" ze-kernel-destroy) :uint32
              (kernel :pointer))

(cffi:defcfun ("zeKernelSetGroupSize" ze-kernel-set-group-size) :uint32
              (kernel :pointer) (gx :uint32) (gy :uint32) (gz :uint32))

(cffi:defcfun ("zeKernelSetArgumentValue" ze-kernel-set-argument-value) :uint32
              (kernel :pointer) (arg-index :uint32) (arg-size :size) (p-arg-value :pointer))

(cffi:defcfun ("zeMemAllocShared" ze-mem-alloc-shared) :uint32
              (context :pointer) (device-desc :pointer) (host-desc :pointer)
              (size :size) (alignment :size) (device :pointer) (pp-tr :pointer))

(cffi:defcfun ("zeMemFree" ze-mem-free) :uint32
              (context :pointer) (ptr :pointer))

(cffi:defcfun ("zeCommandListCreate" ze-command-list-create) :uint32
              (context :pointer) (device :pointer) (desc :pointer) (cmd-list :pointer))

(cffi:defcfun ("zeCommandListDestroy" ze-command-list-destroy) :uint32
              (cmd-list :pointer))

(cffi:defcfun ("zeCommandListClose" ze-command-list-close) :uint32
              (cmd-list :pointer))

(cffi:defcfun ("zeCommandListAppendLaunchKernel" ze-command-list-append-launch-kernel) :uint32
              (cmd-list :pointer) (kernel :pointer) (group-count :pointer)
              (signal-event :pointer) (n-wait-events :uint32) (wait-events :pointer))

(cffi:defcfun ("zeCommandQueueCreate" ze-command-queue-create) :uint32
              (context :pointer) (device :pointer) (desc :pointer) (cmd-queue :pointer))

(cffi:defcfun ("zeCommandQueueDestroy" ze-command-queue-destroy) :uint32
              (cmd-queue :pointer))

(cffi:defcfun ("zeCommandQueueExecuteCommandLists" ze-command-queue-execute-command-lists) :uint32
              (cmd-queue :pointer) (n-cmd-lists :uint32) (cmd-lists :pointer) (fence :pointer))

(cffi:defcfun ("zeCommandQueueSynchronize" ze-command-queue-synchronize) :uint32
              (cmd-queue :pointer) (timeout :uint64))

;;; === Error helper ======================================================

(defmacro check-ze (form)
  "Wraps an L0 call.  Signals an error (with hex result code) on failure."
  `(let ((err ,form))
     (unless (= err +ZE-RESULT-SUCCESS+)
       (error "L0 error 0x~X in ~a" err ',form))))

;;; === Build-log helper ==================================================

(defun ze-fetch-build-log (log-handle)
  "Returns the build log as a Lisp string, or NIL if LOG-HANDLE is null.
   Always destroys the handle when done.  Use after a zeModuleCreate
   failure to get the IGC diagnostics."
  (when (and log-handle (not (cffi:null-pointer-p log-handle)))
    (cffi:with-foreign-object (psize :size)
      (setf (cffi:mem-ref psize :size) 0)
      (ze-module-build-log-get-string log-handle psize (cffi:null-pointer))
      (let ((size (cffi:mem-ref psize :size)))
        (unwind-protect
            (if (zerop size)
                ""
                (cffi:with-foreign-object (buf :char size)
                  (ze-module-build-log-get-string log-handle psize buf)
                  (cffi:foreign-string-to-lisp buf :count (1- size))))
          (ze-module-build-log-destroy log-handle))))))

(format t "~&; L0 CFFI bindings loaded (ze_loader linked successfully).~%")
