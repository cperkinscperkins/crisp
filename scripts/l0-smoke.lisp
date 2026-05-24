;;;; scripts/l0-smoke.lisp
;;;;
;;;; Phase 1c.2.a — Level Zero reachability smoke test.
;;;;
;;;; This is the Lisp counterpart of put_temp_files_here/intel-bmg-opencl-
;;;; regression/loader_l0.cpp.  Loads the same two SPIR-V binaries, runs
;;;; the forward kernel twice (x±h) for a central-difference numerical
;;;; gradient, runs the backward kernel once for the analytical gradient,
;;;; asserts both equal 5.0 for f(x)=n*x with n=5.
;;;;
;;;; The point is to prove our CFFI bindings (tests/l0-bindings.lisp)
;;;; produce the same answers the C++ probe did.  If this passes, we know
;;;; the L0 surface is reachable end-to-end from Lisp and can move on to
;;;; porting the runner's helper layer (phase 1c.2.b).  If it fails, we
;;;; debug bindings here and don't touch the runner yet.
;;;;
;;;; Usage:
;;;;   sbcl --script scripts/l0-smoke.lisp
;;;;   sbcl --script scripts/l0-smoke.lisp <fwd.spv> <bwd.spv>

(in-package :cl-user)

(load (merge-pathnames "tests/l0-bindings.lisp"
                       (truename *default-pathname-defaults*)))

(defun read-spv (path)
  (with-open-file (s path :direction :input :element-type '(unsigned-byte 8))
    (let* ((len (file-length s))
           (buf (make-array len :element-type '(unsigned-byte 8))))
      (read-sequence buf s)
      buf)))

(defun bytes-to-foreign (bytes)
  "Allocates a foreign uchar buffer of (length BYTES) and copies BYTES into it.
   Returns the pointer (caller must foreign-free)."
  (let ((p (cffi:foreign-alloc :uchar :count (length bytes))))
    (loop for i from 0 below (length bytes)
          do (setf (cffi:mem-aref p :uchar i) (aref bytes i)))
    p))

(defun zero-struct (ptr struct-name)
  "Zero-initialise a CFFI struct allocation."
  (let ((n (cffi:foreign-type-size (list :struct struct-name))))
    (loop for i from 0 below n
          do (setf (cffi:mem-aref ptr :uchar i) 0))))

(defun create-module (ctx dev spv-bytes label)
  (let ((il-ptr (bytes-to-foreign spv-bytes)))
    (cffi:with-foreign-objects ((desc '(:struct ze-module-desc))
                                (mod-out :pointer)
                                (log-out :pointer))
      (zero-struct desc 'ze-module-desc)
      (setf (cffi:foreign-slot-value desc '(:struct ze-module-desc) 'stype)
            +ZE-STYPE-MODULE-DESC+
            (cffi:foreign-slot-value desc '(:struct ze-module-desc) 'format)
            +ZE-MODULE-FORMAT-IL-SPIRV+
            (cffi:foreign-slot-value desc '(:struct ze-module-desc) 'input-size)
            (length spv-bytes)
            (cffi:foreign-slot-value desc '(:struct ze-module-desc) 'p-input-module)
            il-ptr)
      (setf (cffi:mem-ref log-out :pointer) (cffi:null-pointer))
      (let ((err (ze-module-create ctx dev desc mod-out log-out)))
        (cffi:foreign-free il-ptr)
        (unless (= err +ZE-RESULT-SUCCESS+)
          (let ((build-log (ze-fetch-build-log
                            (cffi:mem-ref log-out :pointer))))
            (error "zeModuleCreate(~a) failed: 0x~X~@[~%  build log:~%~A~]"
                   label err build-log)))
        ;; Success path: still destroy the (likely-empty) log handle.
        (let ((log (cffi:mem-ref log-out :pointer)))
          (unless (cffi:null-pointer-p log)
            (ze-module-build-log-destroy log)))
        (cffi:mem-ref mod-out :pointer)))))

(defun create-kernel (mod name)
  (cffi:with-foreign-objects ((desc '(:struct ze-kernel-desc))
                              (out :pointer)
                              (name-c :char (1+ (length name))))
    (zero-struct desc 'ze-kernel-desc)
    (loop for i from 0 below (length name)
          do (setf (cffi:mem-aref name-c :char i) (char-code (char name i))))
    (setf (cffi:mem-aref name-c :char (length name)) 0)
    (setf (cffi:foreign-slot-value desc '(:struct ze-kernel-desc) 'stype)
          +ZE-STYPE-KERNEL-DESC+
          (cffi:foreign-slot-value desc '(:struct ze-kernel-desc) 'p-kernel-name)
          name-c)
    (check-ze (ze-kernel-create mod desc out))
    (cffi:mem-ref out :pointer)))

(defun alloc-cell (ctx dev bytes alignment)
  "USM-shared allocation.  Returns the host-addressable pointer."
  (cffi:with-foreign-objects ((dev-desc '(:struct ze-device-mem-alloc-desc))
                              (host-desc '(:struct ze-host-mem-alloc-desc))
                              (ppout :pointer))
    (zero-struct dev-desc 'ze-device-mem-alloc-desc)
    (zero-struct host-desc 'ze-host-mem-alloc-desc)
    (setf (cffi:foreign-slot-value dev-desc '(:struct ze-device-mem-alloc-desc) 'stype)
          +ZE-STYPE-DEVICE-MEM-ALLOC-DESC+
          (cffi:foreign-slot-value host-desc '(:struct ze-host-mem-alloc-desc) 'stype)
          +ZE-STYPE-HOST-MEM-ALLOC-DESC+)
    (check-ze (ze-mem-alloc-shared ctx dev-desc host-desc bytes alignment dev ppout))
    (cffi:mem-ref ppout :pointer)))

(defun bind-cell-f32 (k base ptr byte-size offset)
  (cffi:with-foreign-objects ((p-ptr :pointer)
                              (p-bs :uint64)
                              (p-off :uint64))
    (setf (cffi:mem-ref p-ptr :pointer) ptr
          (cffi:mem-ref p-bs :uint64) byte-size
          (cffi:mem-ref p-off :uint64) offset)
    (check-ze (ze-kernel-set-argument-value k (+ base 0)
                                            (cffi:foreign-type-size :pointer) p-ptr))
    (check-ze (ze-kernel-set-argument-value k (+ base 1)
                                            (cffi:foreign-type-size :uint64) p-bs))
    (check-ze (ze-kernel-set-argument-value k (+ base 2)
                                            (cffi:foreign-type-size :uint64) p-off))))

(defun bind-ulong-scalar (k idx value)
  (cffi:with-foreign-object (p :uint64)
    (setf (cffi:mem-ref p :uint64) value)
    (check-ze (ze-kernel-set-argument-value k idx (cffi:foreign-type-size :uint64) p))))

(defun dispatch-1d-1wi (ctx dev kernel)
  "Launches KERNEL with group size (1,1,1) and group count (1,1,1).  Blocks."
  (check-ze (ze-kernel-set-group-size kernel 1 1 1))
  (cffi:with-foreign-objects ((gc '(:struct ze-group-count))
                              (cl-desc '(:struct ze-command-list-desc))
                              (cl-out :pointer)
                              (cq-desc '(:struct ze-command-queue-desc))
                              (cq-out :pointer)
                              (cl-array :pointer))
    (setf (cffi:foreign-slot-value gc '(:struct ze-group-count) 'x) 1
          (cffi:foreign-slot-value gc '(:struct ze-group-count) 'y) 1
          (cffi:foreign-slot-value gc '(:struct ze-group-count) 'z) 1)
    (zero-struct cl-desc 'ze-command-list-desc)
    (setf (cffi:foreign-slot-value cl-desc '(:struct ze-command-list-desc) 'stype)
          +ZE-STYPE-COMMAND-LIST-DESC+)
    (zero-struct cq-desc 'ze-command-queue-desc)
    (setf (cffi:foreign-slot-value cq-desc '(:struct ze-command-queue-desc) 'stype)
          +ZE-STYPE-COMMAND-QUEUE-DESC+)
    (check-ze (ze-command-list-create ctx dev cl-desc cl-out))
    (check-ze (ze-command-queue-create ctx dev cq-desc cq-out))
    (let ((cl (cffi:mem-ref cl-out :pointer))
          (cq (cffi:mem-ref cq-out :pointer)))
      (unwind-protect
          (progn
           (check-ze (ze-command-list-append-launch-kernel
                      cl kernel gc (cffi:null-pointer) 0 (cffi:null-pointer)))
           (check-ze (ze-command-list-close cl))
           (setf (cffi:mem-ref cl-array :pointer) cl)
           (check-ze (ze-command-queue-execute-command-lists cq 1 cl-array (cffi:null-pointer)))
           (check-ze (ze-command-queue-synchronize cq +ZE-UINT64-MAX+)))
        (ze-command-list-destroy cl)
        (ze-command-queue-destroy cq)))))

;;; === Main =============================================================

(defun smoke (fwd-path bwd-path)
  (let ((fwd-spv (read-spv fwd-path))
        (bwd-spv (read-spv bwd-path)))
    (format t "~&Loaded fwd (~D bytes)  bwd (~D bytes)~%"
            (length fwd-spv) (length bwd-spv))
    (check-ze (ze-init +ZE-INIT-FLAG-GPU-ONLY+))
    (cffi:with-foreign-objects ((n-drv :uint32)
                                (drv :pointer)
                                (n-dev :uint32)
                                (dev :pointer)
                                (ctx-desc '(:struct ze-context-desc))
                                (ctx-out :pointer))
      (setf (cffi:mem-ref n-drv :uint32) 0)
      (check-ze (ze-driver-get n-drv (cffi:null-pointer)))
      (when (zerop (cffi:mem-ref n-drv :uint32))
        (error "no L0 drivers"))
      (setf (cffi:mem-ref n-drv :uint32) 1)
      (check-ze (ze-driver-get n-drv drv))
      (let ((driver (cffi:mem-ref drv :pointer)))
        (setf (cffi:mem-ref n-dev :uint32) 0)
        (check-ze (ze-device-get driver n-dev (cffi:null-pointer)))
        (when (zerop (cffi:mem-ref n-dev :uint32))
          (error "no L0 devices"))
        (setf (cffi:mem-ref n-dev :uint32) 1)
        (check-ze (ze-device-get driver n-dev dev))
        (let ((device (cffi:mem-ref dev :pointer)))
          (zero-struct ctx-desc 'ze-context-desc)
          (setf (cffi:foreign-slot-value ctx-desc '(:struct ze-context-desc) 'stype)
                +ZE-STYPE-CONTEXT-DESC+)
          (check-ze (ze-context-create driver ctx-desc ctx-out))
          (let* ((ctx (cffi:mem-ref ctx-out :pointer))
                 (mod-fwd nil) (mod-bwd nil)
                 (k-fwd nil) (k-bwd nil)
                 (x-ptr nil) (result-ptr nil)
                 (res-grad nil) (x-grad nil) (n-grad nil))
            (unwind-protect
                (progn
                 (setf mod-fwd (create-module ctx device fwd-spv "forward"))
                 (setf mod-bwd (create-module ctx device bwd-spv "backward"))
                 (setf k-fwd (create-kernel mod-fwd "dotimes_accum_x"))
                 (setf k-bwd (create-kernel mod-bwd "dotimes_accum_x_grad"))
                 (setf x-ptr     (alloc-cell ctx device 4 4)
                       result-ptr (alloc-cell ctx device 4 4)
                       res-grad   (alloc-cell ctx device 4 4)
                       x-grad     (alloc-cell ctx device 4 4)
                       n-grad     (alloc-cell ctx device 8 8))
                 (let ((n 5) (x0 3.0) (h 1e-3) (seed 1.0))
                   ;; --- forward at x+h ---
                   (setf (cffi:mem-ref x-ptr :float) (+ x0 h)
                         (cffi:mem-ref result-ptr :float) 0.0)
                   (bind-cell-f32 k-fwd 0 x-ptr 4 0)
                   (bind-ulong-scalar k-fwd 3 n)
                   (bind-cell-f32 k-fwd 4 result-ptr 4 0)
                   (dispatch-1d-1wi ctx device k-fwd)
                   (let ((f-plus (cffi:mem-ref result-ptr :float)))
                     (format t "f(x+h) = ~F  (expected ~F)~%" f-plus (* n (+ x0 h)))
                     ;; --- forward at x-h ---
                     (setf (cffi:mem-ref x-ptr :float) (- x0 h)
                           (cffi:mem-ref result-ptr :float) 0.0)
                     (bind-cell-f32 k-fwd 0 x-ptr 4 0)
                     (bind-ulong-scalar k-fwd 3 n)
                     (bind-cell-f32 k-fwd 4 result-ptr 4 0)
                     (dispatch-1d-1wi ctx device k-fwd)
                     (let* ((f-minus (cffi:mem-ref result-ptr :float))
                            (numerical (/ (- f-plus f-minus) (* 2.0 h))))
                       (format t "f(x-h) = ~F  (expected ~F)~%" f-minus (* n (- x0 h)))
                       (format t "FD numerical df/dx = ~F~%" numerical)
                       ;; --- backward at x0 ---
                       (setf (cffi:mem-ref x-ptr :float) x0
                             (cffi:mem-ref result-ptr :float) 0.0
                             (cffi:mem-ref res-grad :float) seed
                             (cffi:mem-ref x-grad :float) 0.0
                             (cffi:mem-ref n-grad :double) 0.0d0)
                       (bind-cell-f32 k-bwd 0 x-ptr 4 0)
                       (bind-ulong-scalar k-bwd 3 n)
                       (bind-cell-f32 k-bwd 4 result-ptr 4 0)
                       (bind-cell-f32 k-bwd 7 res-grad 4 0)
                       (bind-cell-f32 k-bwd 10 x-grad 4 0)
                       (bind-cell-f32 k-bwd 13 n-grad 8 0)
                       (dispatch-1d-1wi ctx device k-bwd)
                       (let ((analytical (cffi:mem-ref x-grad :float))
                             (atol 5e-3))
                         (format t "Backward analytical df/dx = ~F~%~%" analytical)
                         (format t "numerical  ~A  (expected 5.0, got ~F)~%"
                                 (if (< (abs (- numerical 5.0)) atol) "OK" "FAIL")
                                 numerical)
                         (format t "analytical ~A  (expected 5.0, got ~F)~%"
                                 (if (< (abs (- analytical 5.0)) atol) "OK" "FAIL")
                                 analytical)
                         (format t "match      ~A  (|analytical - numerical| = ~F)~%~%"
                                 (if (< (abs (- analytical numerical)) atol) "OK" "FAIL")
                                 (abs (- analytical numerical)))
                         (if (and (< (abs (- numerical 5.0)) atol)
                                  (< (abs (- analytical 5.0)) atol))
                             (format t "PASS (L0 + Lisp bindings produce correct AD)~%")
                             (format t "FAIL~%")))))))
              ;; cleanup
              (when x-ptr     (ze-mem-free ctx x-ptr))
              (when result-ptr (ze-mem-free ctx result-ptr))
              (when res-grad  (ze-mem-free ctx res-grad))
              (when x-grad    (ze-mem-free ctx x-grad))
              (when n-grad    (ze-mem-free ctx n-grad))
              (when k-fwd     (ze-kernel-destroy k-fwd))
              (when k-bwd     (ze-kernel-destroy k-bwd))
              (when mod-fwd   (ze-module-destroy mod-fwd))
              (when mod-bwd   (ze-module-destroy mod-bwd))
              (ze-context-destroy ctx))))))))

(let* ((argv (or #+sbcl sb-ext:*posix-argv* nil))
       (fwd (or (nth 2 argv)
                "put_temp_files_here/intel-bmg-opencl-regression/forward.spv"))
       (bwd (or (nth 3 argv)
                "put_temp_files_here/intel-bmg-opencl-regression/backward.spv")))
  (smoke fwd bwd))
