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

    ;; Endeavour 193 (BUG 136): die no longer lowers to llvm.trap (OpUnreachable on SPIR-V, which
    ;; IGC deletes).  It claims the module-scope die record and returns.
    (if (and (search "cmpxchg ptr addrspace(1) @__crisp_die_record" ir)
             (not (search "llvm.trap" ir)))
        (format t "PASS (found the die record CAS, no llvm.trap)~%")
        (error "FAIL: the die lowering (CAS on @__crisp_die_record) not found when checks enabled.~%IR: ~a" ir)))

  ;; Case 2: Checks DISABLED
  (format t "  Verifying DISABLED checks elision... ")
  (crisp.compiler:initialize-compiler :runtime-checks nil)

  (let ((ir (crisp.compiler:compile-crisp-form-to-ir-string
             '(def-function test-nodie ()
                            (declare (return-type nil))
                            (r-t-assert (= 1 0))))))

    (if (or (search "llvm.trap" ir) (search "__crisp_die_record" ir))
        (error "FAIL: a die lowering found when checks disabled!~%IR: ~a" ir)
        (format t "PASS (no die lowering)~%"))))

(test-runtime-checks)
