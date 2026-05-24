;;;; scripts/verify-autodiff-l0-smoke.lisp
;;;;
;;;; Phase 1c.2.b sanity check.  Loads the runner with *ad-runtime* = :l0
;;;; (the default after Phase 1c.2.b) and calls VERIFY-AUTODIFF directly
;;;; against the bug-031 SPVs.
;;;;
;;;; If this PASSes, the runtime-init / dispatch-shim / l0-* helper chain
;;;; is wired correctly end-to-end, and Phase 1c.2.c (running the same
;;;; thing via the spec runner) is just a path/CLI question.
;;;;
;;;;   sbcl --non-interactive --load scripts/verify-autodiff-l0-smoke.lisp

(in-package :cl-user)

(load (merge-pathnames "tests/verify-autodiff-runner.lisp"
                       *default-pathname-defaults*))

(format t "~&;; *ad-runtime* = ~A~%" *ad-runtime*)

(multiple-value-bind (pass-p results)
    (verify-autodiff
     "put_temp_files_here/intel-bmg-opencl-regression/forward.spv"
     "put_temp_files_here/intel-bmg-opencl-regression/backward.spv"
     "dotimes_accum_x"
     :inputs '(("x" . 3.0) ("n" . 5))
     :atol 5e-3
     :verbose t)
  (format t "~&;; pass-p = ~A~%" pass-p)
  (dolist (r results)
    (format t ";;   ~A:  analytical=~A  numerical=~A  diff=~A~%"
            (getf r :name) (getf r :analytical)
            (getf r :numerical) (getf r :diff)))
  (if pass-p
      (format t "~&;; PASS~%")
      (progn (format t "~&;; FAIL~%")
             (sb-ext:exit :code 1))))
