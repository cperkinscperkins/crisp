(in-package :cl-user)
(require "asdf")
(let ((quicklisp-init (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (when (probe-file quicklisp-init)
    (load quicklisp-init)))
(push *default-pathname-defaults* ql:*local-project-directories*)
(asdf:load-system "crisp")

(defpackage :repro
  (:use :cl :crisp.compiler :uiop)
  (:shadowing-import-from :crisp.compiler
                          #:internal-def-function
                          #:generate-llvm-ir
                          #:char #:short #:float #:double #:truncate #:floor
                          #:ceil #:round
                          #:cond #:when #:unless ;; Shadow conditionals
                          #:die ;; Shadow die (conflict with uiop)
                          #:let #:return))
(in-package :repro)

(initialize-compiler :log-level :debug)

(defun cleanup-ir-string (output)
  "Extracts the IR from the compiler stdout."
  (let ((marker "--- Generated LLVM IR: ---"))
    (let ((pos (search marker output)))
      (if pos
          (string-trim '(#\Space #\Newline #\Return) (subseq output (+ pos (length marker))))
          output))))

(defun validate-ir-with-clang (ir-string)
  "Uses clang to validate LLVM IR."
  (uiop:with-temporary-file (:stream stream :pathname path :type "ll")
    (write-string ir-string stream)
    (finish-output stream)
    (format t "Validating IR with Clang... Temp file: ~a~%" path) (finish-output)
    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program (list "clang" "-x" "ir" "-c" (uiop:native-namestring path)
                                "-o" (uiop:native-namestring (uiop:null-device-pathname)))
          :output :string
          :error-output :string
          :ignore-error-status t)
      (format t "Clang Output: ~a~%" output)
      (format t "Clang Error: ~a~%" error-output)
      (finish-output)
      (if (zerop exit-code)
          t
          (progn
           (format t "~%LLVM Verification Error:~%~a~%" error-output)
           nil)))))

(defun test ()
  (let ((file "tests/spec/017-scratch-cell/scratch-cell.crisp"))
    (format *error-output* "Running ~a...~%" file)
    (handler-case
        (let ((ir-str 
               (let ((*standard-output* (make-broadcast-stream)))
                 (let ((ir (with-open-file (s file)
                             (let ((forms (loop for f = (read s nil :eof) until (eq f :eof) collect f))
                                   (module (crisp.llvm-bindings:llvm-module-create "repro"))
                                   (builder (crisp.llvm-bindings:llvm-create-builder)))
                                  (crisp.compiler:compile-module forms module builder nil nil nil)
                                  (crisp.llvm-bindings:llvm-print-module-to-string module)))))
                   (cffi:foreign-string-to-lisp ir)))))

          (format *error-output* "IR Generated (Length ~a)~%" (length ir-str))
          (if (validate-ir-with-clang ir-str)
              (format *error-output* "PASS~%")
              (format *error-output* "FAIL (Clang validation)~%")))
      (error (e)
        (format *error-output* "FAIL (Condition: ~a)~%" e)))))

(test)
