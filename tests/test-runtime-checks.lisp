(in-package :crisp.tests)

(defun test-runtime-checks ()
  (format t "~&Testing Runtime Checks...~%")

  ;; Case 1: Checks ENABLED
  (format t "  Verifying ENABLED checks generation... ")
  (crisp.compiler:initialize-compiler :runtime-checks t)

  (let ((ir (crisp.compiler:compile-crisp-form-to-ir-string
             '(def-function test-die ()
                            (declare (return-type nil))
                            (r-t-assert (= 1 0))))))

    (if (search "llvm.trap" ir)
        (format t "PASS (found llvm.trap)~%")
        (error "FAIL: llvm.trap not found when checks enabled.~%IR: ~a" ir)))

  ;; Case 2: Checks DISABLED
  (format t "  Verifying DISABLED checks elision... ")
  (crisp.compiler:initialize-compiler :runtime-checks nil)

  (let ((ir (crisp.compiler:compile-crisp-form-to-ir-string
             '(def-function test-nodie ()
                            (declare (return-type nil))
                            (r-t-assert (= 1 0))))))

    (if (search "llvm.trap" ir)
        (error "FAIL: llvm.trap found when checks disabled!~%IR: ~a" ir)
        (format t "PASS (no llvm.trap)~%"))))

(test-runtime-checks)
