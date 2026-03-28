;; tests/spec/058-multiple-files/multiple-file-compilation.unit.lisp
;;
;; Unit tests for multi-file compilation.
;; These tests verify that the compiler can accept multiple .crisp files and
;; compile them as a single unit, as if they had been concatenated into one file.
;;
;; Test layout:
;;   01-library.crisp    — defines add-three-ints, add-three template, gen-3 macro
;;   11-app-basic.crisp  — kernel calling add-three-ints  (FAIL when compiled alone)
;;   13-app-template.crisp — kernel calling add-three template (FAIL when compiled alone)
;;   15-app-macro.crisp  — kernel using gen-3 defmacro   (FAIL when compiled alone)
;;
;; NOTE on 15-app-macro: (gen-3 float) appears INSIDE the kernel body (not top-level).
;; This is unusual — gen-add-three is typically a top-level template instantiation form.
;; The test is included as TDD; if it exposes a new issue it will be addressed separately.

(in-package :cl-user)

(defpackage :crisp.test.multiple-files
  (:use :cl :parachute)
  (:import-from :crisp.compiler
                #:initialize-compiler
                #:compile-module
                #:crisp-compiler-error)
  (:import-from :crisp.llvm-bindings
                #:llvm-module-create
                #:llvm-create-builder
                #:llvm-print-module-to-string
                #:llvm-dispose-message
                #:llvm-dispose-builder
                #:llvm-dispose-module))

(in-package :crisp.test.multiple-files)

(define-test multiple-files)

;;; --------------------------------------------------------------------------
;;; Local helper — self-contained, no dependency on crisp.spec-runner.
;;; Reads all forms from each file (in :crisp-language package, in order),
;;; concatenates them, and compiles via compile-module.
;;; --------------------------------------------------------------------------

(defun %compile-files-to-ir (filepaths)
  "Compiles a list of .crisp files as a single unit and returns the LLVM IR string.
Forms are read from each file in order (in the :crisp-language package) and compiled
together as if they had been one file.  The last filepath is used as the module name."
  (initialize-compiler :log-level :error)
  (let* ((forms (let ((*package* (find-package :crisp-language)))
                  (loop for filepath in filepaths
                        appending (with-open-file (stream filepath)
                                    (loop for form = (read stream nil :eof)
                                          until (eq form :eof)
                                          collect form)))))
         (module (llvm-module-create (pathname-name (car (last filepaths)))))
         (builder (llvm-create-builder)))
    (unwind-protect
        (progn
         (compile-module forms module builder nil nil nil)
         (let ((ir-ptr (llvm-print-module-to-string module)))
           (unwind-protect (cffi:foreign-string-to-lisp ir-ptr)
             (llvm-dispose-message ir-ptr))))
      (llvm-dispose-builder builder)
      (llvm-dispose-module module))))

;;; --------------------------------------------------------------------------
;;; 11-app-basic: kernel calling add-three-ints from library
;;; --------------------------------------------------------------------------

(define-test (multiple-files basic-multi-file-succeeds)
  "Compiling library + app-basic together should succeed: add-three-ints is available."
  (let ((ir (%compile-files-to-ir
             (list "tests/spec/058-multiple-files/01-library.crisp"
                   "tests/spec/058-multiple-files/11-app-basic.crisp"))))
    (true (and ir (> (length ir) 0))
          "IR should be non-empty")
    (true (search "add_three" ir)
          "IR should contain the add_three kernel")))

(define-test (multiple-files basic-single-file-fails)
  "Compiling app-basic ALONE should signal a crisp-compiler-error (add-three-ints undefined)."
  (fail (%compile-files-to-ir
         (list "tests/spec/058-multiple-files/11-app-basic.crisp"))
        'crisp-compiler-error))

;;; --------------------------------------------------------------------------
;;; 13-app-template: kernel calling add-three template, two gen-add_three calls
;;; --------------------------------------------------------------------------

(define-test (multiple-files template-multi-file-succeeds)
  "Compiling library + app-template together should succeed: add-three template is available."
  (let ((ir (%compile-files-to-ir
             (list "tests/spec/058-multiple-files/01-library.crisp"
                   "tests/spec/058-multiple-files/13-app-template.crisp"))))
    (true (and ir (> (length ir) 0))
          "IR should be non-empty")
    (true (search "add_three_f" ir)
          "IR should contain the add_three_f kernel (float instantiation)")
    (true (search "add_three_l" ir)
          "IR should contain the add_three_l kernel (long instantiation)")))

;;; --------------------------------------------------------------------------
;;; 15-app-macro: kernel using gen-3 defmacro from library
;;; NOTE: (gen-3 float) appears inside the kernel body — see file header comment.
;;; --------------------------------------------------------------------------

(define-test (multiple-files macro-multi-file-succeeds)
  "Compiling library + app-macro together should succeed: gen-3 macro is available."
  (let ((ir (%compile-files-to-ir
             (list "tests/spec/058-multiple-files/01-library.crisp"
                   "tests/spec/058-multiple-files/15-app-macro.crisp"))))
    (true (and ir (> (length ir) 0))
          "IR should be non-empty")
    (true (search "add_three_ff" ir)
          "IR should contain the add_three_ff kernel")))

;;; --------------------------------------------------------------------------
;;; Run
;;; --------------------------------------------------------------------------

(test 'multiple-files)
