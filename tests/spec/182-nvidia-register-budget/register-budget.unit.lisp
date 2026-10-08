(in-package :cl-user)

(defpackage :crisp.test.register-budget
  (:use :cl :parachute))

(in-package :crisp.test.register-budget)

;;; ENDEAVOUR 182 -- the NVIDIA register budget for streaming kernels.
;;;
;;; The contract at the IR level: an entry point that gets a bound carries the function attributes
;;; "nvvm.maxntid" (the workgroup size) and "nvvm.minctasm" (blocks per compute unit = threads target /
;;; workgroup size), which LLVM's NVPTX backend lowers to .maxntid / .minnctapersm.  The target comes from
;;; (declare (occupancy-target N)) if present -- nil turns it off -- else from the hardware profile's
;;; :stream-occupancy-target, and the profile's applies only to kernels with a stream loop.
;;; The PTX-text and on-metal halves are the .crisp specs in this directory.

(defun %read-all (string)
  "Every form in STRING, read in :crisp-language as the compiler reads a .crisp file."
  (let ((*package* (find-package :crisp-language)))
    (with-input-from-string (s string)
      (loop for f = (read s nil :eof) until (eq f :eof) collect f))))

(defun %ir (source profile &key (target :ptx))
  "The UNOPTIMISED LLVM IR of SOURCE compiled in-process for TARGET under hardware PROFILE."
  (crisp.compiler:initialize-compiler :log-level :error :hardware-profile profile)
  (let ((module (crisp.llvm-bindings:llvm-module-create "u182"))
        (builder (crisp.llvm-bindings:llvm-create-builder)))
    (unwind-protect
         (let ((crisp.compiler:*target-backend* target))
           (crisp.compiler:compile-module (%read-all source) module builder nil nil nil)
           (let ((p (crisp.llvm-bindings:llvm-print-module-to-string module)))
             (unwind-protect (cffi:foreign-string-to-lisp p)
               (crisp.llvm-bindings:llvm-dispose-message p))))
      (crisp.llvm-bindings:llvm-dispose-builder builder)
      (crisp.llvm-bindings:llvm-dispose-module module))))

(defun %kernel-attributes (ir kernel)
  "The text of the `attributes #N = { ... }` group attached to KERNEL's define line, or NIL."
  (with-input-from-string (s ir)
    (let* ((lines (loop for l = (read-line s nil) while l collect l))
           (def (find-if (lambda (l) (and (search "define " l) (search (format nil "@~a(" kernel) l))) lines))
           (group (and def (let ((p (position #\# def :from-end t)))
                             (and p (string-right-trim " {" (subseq def p)))))))
      (and group
           (find-if (lambda (l) (and (search "attributes " l)
                                     (search (format nil "~a = " group) l)))
                    lines)))))

(defun %bound (ir kernel)
  "(maxntid minctasm) strings stamped on KERNEL, or NIL when it carries neither."
  (let ((attrs (%kernel-attributes ir kernel)))
    (flet ((value (key)
             (let ((p (and attrs (search (format nil "\"~a\"=\"" key) attrs))))
               (and p (let* ((start (+ p (length key) 4))
                             (end (position #\" attrs :start start)))
                        (subseq attrs start end))))))
      (let ((maxntid (value "nvvm.maxntid")) (minctasm (value "nvvm.minctasm")))
        (and (or maxntid minctasm) (list maxntid minctasm))))))

(defparameter *profile*
  "(def-hardware-profile stream-gpu :simd-width 32 :compute-units 132 :stream-occupancy-target 1024)")

(defparameter *types*
  "(def-type in-vec (vector float :address-space :global :align :compact))
   (def-type out-c  (cell float :address-space :global))")

(defun %rv-kernel (local &optional (extra-decl ""))
  (format nil "~a ~a
   (def-kernel probe (A &out out)
     (declare #'(in-vec &out out-c => nil)
              (global-size :derive-from A :strategy :strided)
              (local-size  :set-to (~a))
              ~a)
     (reduce-vec #'+ A 0.0 out))" *profile* *types* local extra-decl))

;;; --- tests ----------------------------------------------------------

(define-test register-budget)

(define-test (register-budget profile-key-accepted)
  (crisp.compiler:initialize-compiler :log-level :error)
  (eval (first (%read-all *profile*)))
  (is = 1024 (getf (gethash "STREAM-GPU" crisp.compiler::*hardware-profiles*) :stream-occupancy-target)))

(define-test (register-budget stream-kernel-gets-profile-bound)
  (is equal '("256" "4") (%bound (%ir (%rv-kernel 256) "stream-gpu") "probe")))

(define-test (register-budget bound-follows-workgroup-size)
  (is equal '("512" "2") (%bound (%ir (%rv-kernel 512) "stream-gpu") "probe")))

(define-test (register-budget declaration-overrides-profile)
  (is equal '("256" "2") (%bound (%ir (%rv-kernel 256 "(occupancy-target 512)") "stream-gpu") "probe")))

(define-test (register-budget declaration-nil-turns-it-off)
  (false (%bound (%ir (%rv-kernel 256 "(occupancy-target nil)") "stream-gpu") "probe")))

(define-test (register-budget no-bound-on-spirv)
  (false (%bound (%ir (%rv-kernel 256 "(occupancy-target 512)") "stream-gpu" :target :spirv) "probe")))

;; A quiet `is` failure does not fail the load, and the runner only sees load errors -- so error here.
(let* ((report (test 'register-budget))
       (failures (parachute:results-with-status :failed report)))
  (when failures
    (error "register-budget: ~d result(s) failed:~{~%    ~a~}" (length failures)
           (mapcar (lambda (r) (let ((s (princ-to-string r))) (subseq s 0 (min 160 (length s)))))
                   failures))))
