;; overlays/spec-runner-overlay.lisp
(in-package :crisp.spec-runner)

;; tests/run-specs.lisp
;; Fix: expectation failure must return-from the function (not just return nil from dolist body).
;; Also removes duplicate output print.
(defun validate-l0-host-run (crisp-file cpp-files)
  "Validates C++ files compile AND run. Links against system ze_loader.dll."
  (if (null cpp-files)
      (progn (format t "FAIL: No C++ files to validate~%") nil)

      (let ((clang-exe (resolve-clang-executable))
            (l0-include (resolve-l0-include-dir))
            (ze-loader (resolve-ze-loader)))

        (log:debug "clang=~s inc=~s loader=~s" clang-exe l0-include ze-loader)

        (unless (and clang-exe l0-include ze-loader)
          (format t "FAIL: Missing native toolchain components. Falling back to validate-l0-compile-only (Docker)...~%")
          (return-from validate-l0-host-run (validate-l0-compile-only crisp-file cpp-files)))

        (dolist (cpp cpp-files)
          (let ((exe-path (make-pathname :type "exe" :defaults cpp)))
            ;; 1. Compile & Link
            (multiple-value-bind (output error-output exit-code)
                (uiop:run-program
                  (list (uiop:native-namestring clang-exe)
                        (uiop:native-namestring cpp)
                        "-I" (namestring l0-include)
                        (uiop:native-namestring ze-loader)
                        "-static"
                        "-o" (uiop:native-namestring exe-path))
                  :output :string :error-output :string :ignore-error-status t)
              (declare (ignore output))

              (if (not (zerop exit-code))
                  (progn
                   (format t "FAIL: ~a compilation error~%~a~%" (file-namestring cpp) error-output)
                   (return-from validate-l0-host-run nil))

                  ;; 2. Run
                  (progn
                   (format t "Compiling ~a -> ~a... OK~%" (file-namestring cpp) (file-namestring exe-path))
                   (multiple-value-bind (run-out run-err run-code)
                       (uiop:run-program (uiop:native-namestring exe-path)
                         :output :string :error-output :string :ignore-error-status t)
                     (format t "Output:~%~a~%" run-out)
                     (if (zerop run-code)
                         ;; Check Expectations
                         (let ((expectations (parse-hoist-expect (extract-test-directives crisp-file)))
                               (passed t))
                           (when expectations
                             (dolist (exp expectations)
                               (unless (search exp run-out)
                                 (format t "FAIL: Expectation not found in output: '~a'~%" exp)
                                 (setf passed nil))))
                           (if passed
                               (progn
                                (format t "PASS: ~a ran successfully!~%" (file-namestring cpp))
                                t)
                               (return-from validate-l0-host-run nil)))
                         (progn
                          (format t "FAIL: ~a execution failed (Code ~a)~%Error: ~a~%"
                            (file-namestring exe-path) run-code run-err)
                          (return-from validate-l0-host-run nil)))))))))
        t)))
