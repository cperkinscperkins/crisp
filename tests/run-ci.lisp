;; tests/run-ci.lisp
(in-package :cl-user)

;; 1. Load the crisp system
(format t "~&; --- Loading ASDF and Crisp system...~%")
(push *default-pathname-defaults* asdf:*central-registry*)
(asdf:load-system "crisp")
(format t "~&; --- System loaded successfully.~%")

;; 2. Run the basic FFI test
(format t "~&; --- Running test-llvm-hello-world ---~%")
(crisp.compiler:test-llvm-hello-world)

;; 3. Test the semantic analyzer and codegen path (Target #5/6)
(format t "~&; --- Running test for (def-function ... 7) ---~%")
(crisp.compiler:generate-llvm-ir
 (crisp.compiler:def-function test-fn-7 ()
   (declare (return-type int)) 7))

(format t "~&; --- Running test for (def-function ... (+ a b)) ---~%")
(crisp.compiler:generate-llvm-ir
 (crisp.compiler:def-function test-fn-add (a b)
   (declare (type a b int) (return-type int))
   (+ a b)))

(format t "~&; --- Running test for arrow syntax (def-function ... #') ---~%")
(crisp.compiler:generate-llvm-ir
 (crisp.compiler:def-function test-fn-arrow (a b)
   (declare #'(int int => int))
   (+ a b)))

;; 4. If we got here, all is well
(format t "~&~%*** Crisp CI Tests Passed! ***~%")

;; Exit SBCL with a success code
(uiop:quit 0)