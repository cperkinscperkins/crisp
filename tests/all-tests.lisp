;;; tests/all-tests.lisp

(defpackage :crisp.tests
  (:use :cl :crisp.compiler :parachute))

(in-package :crisp.tests)

(define-test crisp-compiler)

(defun compile-crisp-file-to-string (filepath &key (debug-p nil))
  "Compiles a .crisp file and returns the LLVM IR as a string."
  (with-output-to-string (s)
    (let ((*standard-output* s)
          (forms (with-open-file (stream filepath)
                   (loop for form = (read stream nil :eof)
                         until (eq form :eof)
                         collect form))))
      (let* ((module (llvm-module-create "codegen_test"))
             (builder (llvm-create-builder))
             (di-builder (when debug-p (llvm-create-di-builder module)))
             (di-compile-unit (when debug-p
                                (let* ((f "test.crisp") (d "/tmp/")
                                       (di-file (llvm-di-builder-create-file di-builder f (length f) d (length d))))
                                  (llvm-di-builder-create-compile-unit di-builder 32768 di-file "Crisp" 5 nil "" 0 0 "" 0 1 0 nil nil "" 0 "" 0)))))
        (unwind-protect
             (progn
               (compile-module forms module builder di-builder di-compile-unit nil)
               (let ((ir-ptr (llvm-print-module-to-string module)))
                 (unwind-protect (format s "~a" (cffi:foreign-string-to-lisp ir-ptr))
                   (llvm-dispose-message ir-ptr))))
          (when di-builder (llvm-di-builder-finalize di-builder))
          (when di-builder (llvm-dispose-di-builder di-builder))
          (llvm-dispose-builder builder)
          (llvm-dispose-module module))))))

(define-test (crisp-compiler codegen)
  "Tests for the code generation phase.")

(define-test (codegen fadd-generation)
  (let ((ir (compile-crisp-file-to-string "tests/types.crisp")))
    (true (search "fadd float" ir) "Expected to find 'fadd float' instruction.")))

(define-test (codegen di-type-generation)
  (let ((ir (compile-crisp-file-to-string "tests/types.crisp" :debug-p t)))
    (true (search "!DIBasicType(name: \"uint\"" ir))
    (true (search "!DIBasicType(name: \"float\"" ir))))

(define-test (codegen promotion-casts)
  (let ((ir (compile-crisp-file-to-string "tests/promotions.crisp")))
    (true (search "sitofp i32" ir))
    (true (search "uitofp i32" ir))
    (true (search "sext i8" ir))
    (true (search "fpext float" ir))))

(define-test (codegen explicit-casts)
  (let ((ir (compile-crisp-file-to-string "tests/casts.crisp")))
    (true (search "sext i32" ir))
    (true (search "bitcast float" ir))
    (true (search "fptosi float" ir))))