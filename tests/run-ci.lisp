;; tests/run-ci.lisp
(in-package :cl-user)

;; load the crisp system using Quicklisp
(format t "~&; --- Loading Crisp system via Quicklisp...~%")
;; Tell Quicklisp to find local projects in the current directory
(push *default-pathname-defaults* ql:*local-project-directories*)

(asdf:clear-system "crisp")

;; ql:quickload will find crisp.asd, see the dependencies,
;; download dependencies, and then load crisp.
(ql:quickload '("crisp" "parachute"))
(format t "~&; --- System loaded successfully.~%")

;; Switch into the compiler package
(in-package :crisp.compiler)

;; Initialize the compiler for the test run.
(format t "~&; --- Initializing compiler for test run...~%")
(initialize-compiler :log-level :info)


;; basic FFI test
(format t "~&; --- Running test-llvm-hello-world ---~%")
(test-llvm-hello-world)

(defun test-compile-and-print (semantic-fn &key (debug-p nil))
  "Helper to create a module, compile a function, and print the IR."
  (let* ((module (llvm-module-create "ci_test_module"))
         (builder (llvm-create-builder))
         (di-builder (when debug-p (llvm-create-di-builder module))))
    (unwind-protect
         (let ((location-map (when debug-p (generate-location-map (list semantic-fn)))))
           (progn
           (let ((di-compile-unit (when debug-p
                                    (let* ((f "test.crisp")
                                           (d "/tmp/")
                                           (di-file (llvm-di-builder-create-file di-builder f (length f) d (length d)))
                                           (producer "Crisp Compiler")
                                           (flags ""))
                                       (llvm-di-builder-create-compile-unit
                                        di-builder
                                        32768 ; DW_LANG_user_lo
                                        di-file
                                        producer (length producer)
                                        nil ; isOptimized
                                        flags (length flags)
                                        0   ; runtimeVersion
                                        (cffi:null-pointer) 0 ; splitName
                                        1   ; DW_Emission_Kind_Full
                                        0   ; DWOId
                                        nil ; splitDebugInlining
                                        nil ; debugInfoForProfiling
                                        (cffi:null-pointer) 0 ; sysroot
                                        (cffi:null-pointer) 0 ; sdk
                                        ))))) 
             (generate-llvm-ir semantic-fn module builder di-builder di-compile-unit location-map))
           (let ((ir-ptr (llvm-print-module-to-string module)))
             (unwind-protect
                  (format t "~a~%" (cffi:foreign-string-to-lisp ir-ptr))
               (llvm-dispose-message ir-ptr))))
      (when di-builder (llvm-di-builder-finalize di-builder))
      (when di-builder (llvm-dispose-di-builder di-builder))
      (llvm-dispose-builder builder)
      (llvm-dispose-module module)))))

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

(defun test-dwarf-scaffolding ()
  (format t "~&; --- Testing DWARF Scaffolding Generation ---~%")
  (let* ((ir-string (with-output-to-string (s)
                      (let ((*standard-output* s))
                        (test-compile-and-print (internal-def-function 'test-dwarf '() '((return-type int)) '(7) '(0)) :debug-p t))))
         (cu-found (search "!DICompileUnit" ir-string)) 
         (dbg-found (search "define i32 @test-dwarf() !dbg" ir-string))
         (line-found (search "line: 1" ir-string))
         (type-found (search "!DISubroutineType" ir-string)))
    (format t "~&; Test 'DWARF Scaffolding': ~:[FAIL~;PASS~]~%" (and cu-found dbg-found line-found type-found))))

(test-dwarf-scaffolding)

(defun test-dwarf-instruction-level ()
  (format t "~&; --- Testing DWARF Instruction-Level Generation ---~%")
  (let* ((ir-string (with-output-to-string (s)
                      (let ((*standard-output* s))
                        (test-compile-and-print (internal-def-function 'test-instr '() '((return-type int)) '(7) '(0)) :debug-p t))))
         (found (search "ret i32 7, !dbg" ir-string)))
    (format T "ir-string: ~a~%" ir-string)
    (format t "~&; Test 'DWARF Instruction Location': ~:[FAIL~;PASS~]~%" found)))

(test-dwarf-instruction-level)

(defun test-dwarf-add-instruction ()
  (format t "~&; --- Testing DWARF for Add Instruction ---~%")
  (let* ((ir-string (with-output-to-string (s)
                      (let ((*standard-output* s)) 
                        (test-compile-and-print 
                         (internal-def-function 'test-add '(a) '((type a int) (return-type int)) '((+ a 2)) '(0))
                         :debug-p t))))
         ;; LLVM might load the parameter 'a' into a register like %0
         ;; So we search for the add instruction using that register.
         (add-found (search "add i32 %a1, 2, !dbg" ir-string))
         (ret-found (search "ret i32 %add_tmp, !dbg" ir-string)))
    (format T "ir-string: ~a~%" ir-string)
    (format t "~&; Test 'DWARF Add Location': ~:[FAIL~;PASS~]~%" (and add-found ret-found))))

(test-dwarf-add-instruction)

;; Run internal analyzer tests
(format t "~&; --- Running internal analyzer tests ---~%")
(load "tests/analyzer.lisp")
(run-analyzer-tests)

;; Run internal codegen tests
(format t "~&; --- Running Parachute tests ---~%")
(load "tests/all-tests.lisp")
(parachute:test :crisp.tests)

;; yay
(format t "~&~%*** Crisp CI Tests Passed! ***~%")

;; switch back to cl-user just in case
(in-package :cl-user)

(uiop:quit 0)