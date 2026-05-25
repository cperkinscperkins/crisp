;;;; scripts/l0-load-smoke.lisp
;;;;
;;;; Tiny L0 module-create test.  Loads a single SPV and reports whether
;;;; zeModuleCreate succeeds.  Used to validate async-tile codegen
;;;; choices in endeavor 114 — when an IR variant compiles to SPV but
;;;; fails IGC linkage, this catches it.
;;;;
;;;; Usage: sbcl --non-interactive --load scripts/l0-load-smoke.lisp <path-to-spv>

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
  (let ((p (cffi:foreign-alloc :uchar :count (length bytes))))
    (loop for i from 0 below (length bytes)
          do (setf (cffi:mem-aref p :uchar i) (aref bytes i)))
    p))

(defun zero-struct (ptr struct-name)
  (let ((n (cffi:foreign-type-size (list :struct struct-name))))
    (loop for i from 0 below n do (setf (cffi:mem-aref ptr :uchar i) 0))))

(defun try-load-spv (spv-path &optional (kname ""))
  (let ((spv-bytes (read-spv spv-path)))
    (format t "~&Loaded ~D bytes from ~A~%" (length spv-bytes) spv-path)
    (check-ze (ze-init +ZE-INIT-FLAG-GPU-ONLY+))
    (cffi:with-foreign-objects ((n-drv :uint32) (drv :pointer)
                                (n-dev :uint32) (dev :pointer)
                                (ctx-out :pointer))
      (setf (cffi:mem-ref n-drv :uint32) 0)
      (check-ze (ze-driver-get n-drv (cffi:null-pointer)))
      (setf (cffi:mem-ref n-drv :uint32) 1)
      (check-ze (ze-driver-get n-drv drv))
      (let ((driver (cffi:mem-ref drv :pointer)))
        (setf (cffi:mem-ref n-dev :uint32) 0)
        (check-ze (ze-device-get driver n-dev (cffi:null-pointer)))
        (setf (cffi:mem-ref n-dev :uint32) 1)
        (check-ze (ze-device-get driver n-dev dev))
        (let* ((device (cffi:mem-ref dev :pointer))
               (ctx-desc (cffi:foreign-alloc :uchar :count
                                              (cffi:foreign-type-size '(:struct ze-context-desc)))))
          (loop for i from 0 below (cffi:foreign-type-size '(:struct ze-context-desc))
                do (setf (cffi:mem-aref ctx-desc :uchar i) 0))
          (setf (cffi:foreign-slot-value ctx-desc '(:struct ze-context-desc) 'stype)
                +ZE-STYPE-CONTEXT-DESC+)
          (check-ze (ze-context-create driver ctx-desc ctx-out))
          (let* ((ctx (cffi:mem-ref ctx-out :pointer))
                 (il-ptr (bytes-to-foreign spv-bytes))
                 (mod-desc (cffi:foreign-alloc :uchar :count
                                               (cffi:foreign-type-size '(:struct ze-module-desc)))))
            (loop for i from 0 below (cffi:foreign-type-size '(:struct ze-module-desc))
                  do (setf (cffi:mem-aref mod-desc :uchar i) 0))
            (setf (cffi:foreign-slot-value mod-desc '(:struct ze-module-desc) 'stype)
                  +ZE-STYPE-MODULE-DESC+
                  (cffi:foreign-slot-value mod-desc '(:struct ze-module-desc) 'format)
                  +ZE-MODULE-FORMAT-IL-SPIRV+
                  (cffi:foreign-slot-value mod-desc '(:struct ze-module-desc) 'input-size)
                  (length spv-bytes)
                  (cffi:foreign-slot-value mod-desc '(:struct ze-module-desc) 'p-input-module)
                  il-ptr)
            (cffi:with-foreign-objects ((mod-out :pointer) (log-out :pointer))
              (setf (cffi:mem-ref log-out :pointer) (cffi:null-pointer))
              (let ((err (ze-module-create ctx device mod-desc mod-out log-out)))
                (cond
                 ((not (zerop err))
                  (let ((blog (ze-fetch-build-log
                               (cffi:mem-ref log-out :pointer))))
                    (format t "~&FAIL: zeModuleCreate -> 0x~X~@[~%--- build log ---~%~A~]~%"
                            err blog)))
                 (t
                  (format t "~&MODULE-CREATE OK~%")
                  ;; Also try kernel-create on every entry point.  Run-specs
                  ;; failed at this step despite module-create succeeding.
                  (let* ((mod (cffi:mem-ref mod-out :pointer)))
                    (when (string/= kname "")
                      (cffi:with-foreign-objects ((kdesc :uchar (cffi:foreign-type-size
                                                                  '(:struct ze-kernel-desc)))
                                                  (k-out :pointer)
                                                  (name-c :char (1+ (length kname))))
                        (loop for i from 0 below (cffi:foreign-type-size '(:struct ze-kernel-desc))
                              do (setf (cffi:mem-aref kdesc :uchar i) 0))
                        (loop for i from 0 below (length kname)
                              do (setf (cffi:mem-aref name-c :char i)
                                       (char-code (char kname i))))
                        (setf (cffi:mem-aref name-c :char (length kname)) 0)
                        (setf (cffi:foreign-slot-value kdesc '(:struct ze-kernel-desc) 'stype)
                              +ZE-STYPE-KERNEL-DESC+
                              (cffi:foreign-slot-value kdesc '(:struct ze-kernel-desc) 'p-kernel-name)
                              name-c)
                        (let ((kerr (ze-kernel-create mod kdesc k-out)))
                          (cond
                            ((zerop kerr)
                             (format t "~&KERNEL-CREATE(~A) OK~%" kname)
                             (ze-kernel-destroy (cffi:mem-ref k-out :pointer)))
                            (t
                             (format t "~&KERNEL-CREATE(~A) FAIL -> 0x~X~%" kname kerr))))))
                    (ze-module-destroy mod))))))
            (ze-context-destroy ctx)))))))

(let ((argv (or #+sbcl sb-ext:*posix-argv* nil)))
  (let ((path  (or (nth 2 argv)
                   (error "usage: sbcl --non-interactive --load l0-load-smoke.lisp -- <SPV> [kernel-name]")))
        (kname (or (nth 3 argv) "")))
    (try-load-spv path kname)))
