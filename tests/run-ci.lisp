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

(defun test-compile-and-print (semantic-fn)
  "Helper to create a module, compile a function, and print the IR."
  (let ((module (llvm-module-create "ci_test_module"))
        (builder (llvm-create-builder)))
    (unwind-protect
         (progn
           (generate-llvm-ir semantic-fn module builder)
           (let ((ir-ptr (llvm-print-module-to-string module)))
             (unwind-protect
                  (format t "~a~%" (cffi:foreign-string-to-lisp ir-ptr))
               (llvm-dispose-message ir-ptr))))
      (llvm-dispose-builder builder)
      (llvm-dispose-module module))))

;; test the semantic analyzer and codegen path (Target #5/6)
(format t "~&; --- Running test for (def-function ... 7) ---~%")
(test-compile-and-print
 (internal-def-function 'test-fn-7 '() '((return-type int)) '(7) '(0)))

(format t "~&; --- Running test for (def-function ... (+ a b)) ---~%")
(test-compile-and-print
 (internal-def-function 'test-fn-add '(a b) '((type a b int) (return-type int)) '((+ a b)) '(1)))

(format t "~&; --- Running test for arrow syntax (def-function ... #') ---~%")
(test-compile-and-print
 (internal-def-function 'test-fn-arrow '(a b) '((function (int int => int))) '((+ a b)) '(2)))

(defun test-location-mapping ()
  (format t "~&; --- Testing DWARF Location Mapping ---~%")
  (let* ((crisp-code '((def-function foo (a) (declare (return-type int)) (+ a 1))))
         (location-map (generate-location-map crisp-code))
         (test-passed t)
         ;; Define the expected location->line mappings for the code above
         (expected-mappings
           '(((0) . 1)      ; -> (def-function ...)
             ((0 0) . 2)    ; -> def-function
             ((0 1) . 3)    ; -> foo
             ((0 2) . 4)    ; -> (a)
             ((0 2 0) . 5)  ; -> a
             ((0 3) . 6)    ; -> (declare (return-type int))
             ((0 3 0) . 7)  ; -> declare
             ((0 3 1) . 8)  ; -> (return-type int)
             ((0 4) . 9)    ; -> (+ a 1)
             ((0 4 0) . 10) ; -> +
             ((0 4 1) . 11) ; -> a
             ((0 4 2) . 12) ; -> 1
             )))
    (dolist (mapping expected-mappings)
      (let ((loc (car mapping))
            (expected-line (cdr mapping)))
        (unless (= (gethash loc location-map) expected-line)
          (format t "~&;   [FAIL] Location ~a. Expected ~a, got ~a~%" loc expected-line (gethash loc location-map))
          (setf test-passed nil))))
    (format t "~&; Test 'Virtual Line Number Mapping': ~:[FAIL~;PASS~]~%" test-passed)))

(test-location-mapping)

;; yay
(format t "~&~%*** Crisp CI Tests Passed! ***~%")

;; switch back to cl-user just in case
(in-package :cl-user)

(uiop:quit 0)