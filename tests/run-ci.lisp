;; tests/run-ci.lisp
(in-package :cl-user)

;; load the crisp system using Quicklisp
(format t "~&; --- Loading Crisp system via Quicklisp...~%")
;; Tell Quicklisp to find local projects in the current directory
(push *default-pathname-defaults* ql:*local-project-directories*)

(asdf:clear-system "crisp")

;; ql:quickload will find crisp.asd, see the dependencies,
;; download cffi, and then load crisp.
(ql:quickload "crisp")
(format t "~&; --- System loaded successfully.~%")

(format t "~&; --- Loading LLVM foreign library...~%")
(cffi:use-foreign-library crisp.llvm-bindings::libllvm)

;; Switch into the compiler package
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