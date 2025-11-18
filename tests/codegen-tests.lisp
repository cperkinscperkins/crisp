;;; tests/codegen.lisp

(in-package :crisp.compiler)

(defun run-codegen-tests ()
  "Runs all internal tests for the code generator."
  (test-fadd-generation)
  (test-di-type-generation)
  (test-promotion-casts)
  (format t "~&; --- Codegen tests passed! ---~%"))



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

(defun test-fadd-generation ()
  (format t "~&;   Testing fadd generation...~%")
  (let ((ir (compile-crisp-file-to-string "tests/types.crisp")))
    (assert (search "fadd float" ir))
    (format t "~&;     [PASS] Found 'fadd float' instruction.~%"))
  (format t "~&;   ...test-fadd-generation PASSED~%"))

(defun test-di-type-generation ()
  (format t "~&;   Testing DWARF type generation...~%")
  (let ((ir (compile-crisp-file-to-string "tests/types.crisp" :debug-p t)))
    (assert (search "!DIBasicType(name: \"uint\"" ir))
    (assert (search "!DIBasicType(name: \"float\"" ir))
    (format t "~&;     [PASS] Found DIBasicType for uint and float.~%"))
  (format t "~&;   ...test-di-type-generation PASSED~%"))

(defun test-promotion-casts ()
  (format t "~&;   Testing type promotion cast generation...~%")
  (let ((ir (compile-crisp-file-to-string "tests/promotions.crisp")))
    (assert (search "sitofp i32" ir))
    (format t "~&;     [PASS] Found 'sitofp' for signed int -> float promotion.~%")
    (assert (search "uitofp i32" ir))
    (format t "~&;     [PASS] Found 'uitofp' for unsigned int -> float promotion.~%")
    (assert (search "sext i8" ir))
    (format t "~&;     [PASS] Found 'sext' for signed char -> int promotion.~%")
    (assert (search "fpext float" ir))
    (format t "~&;     [PASS] Found 'fpext' for float -> double promotion.~%"))
  (format t "~&;   ...test-promotion-casts PASSED~%"))