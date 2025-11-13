;; tests/run-ci.lisp
(in-package :cl-user)

;; Load ASDF
(require "asdf")

;; load the crisp system
(format t "~&; --- Loading ASDF and Crisp system...~%")
(push *default-pathname-defaults* asdf:*central-registry*)
(asdf:load-system "crisp")
(format t "~&; --- System loaded successfully.~%")


(in-package :crisp.compiler)

;; basic FFI test
(format t "~&; --- Running test-llvm-hello-world ---~%")
(test-llvm-hello-world)

;; test the semantic analyzer and codegen path (Target #5/6)
(format t "~&; --- Running test for (def-function ... 7) ---~%")
(generate-llvm-ir
 (def-function test-fn-7 ()
   (declare (return-type int)) 7))

(format t "~&; --- Running test for (def-function ... (+ a b)) ---~%")
(generate-llvm-ir
 (def-function test-fn-add (a b)
   (declare (type a b int) (return-type int))
   (+ a b)))

(format t "~&; --- Running test for arrow syntax (def-function ... #') ---~%")
(generate-llvm-ir
 (def-function test-fn-arrow (a b)
   (declare #'(int int => int))
   (+ a b)))

;; yay
(format t "~&~%*** Crisp CI Tests Passed! ***~%")

;; switch back to cl-user just in case
(in-package :cl-user)

(uiop:quit 0)