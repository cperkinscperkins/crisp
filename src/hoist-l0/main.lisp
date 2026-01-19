(in-package :crisp.hoist.l0)

(defun main ()
  "Entry point for crisp-hoist-l0.exe"
  (handler-case
      (let ((args (uiop:command-line-arguments)))
        (format t "Crisp Hoist L0 - Level Zero C++ Launcher Generator~%")
        (format t "Version: 0.1.0~%~%")

        (unless args
          (format t "Usage: crisp-hoist-l0 <path-to-metacrisp-file>~%")
          (uiop:quit 1))

        (let ((metacrisp-path (first args)))
          (unless (probe-file metacrisp-path)
            (format t "Error: File not found: ~a~%" metacrisp-path)
            (uiop:quit 1))

          (format t "Processing: ~a~%" metacrisp-path)
          (generate-l0-launcher metacrisp-path)
          (format t "Done!~%")
          (uiop:quit 0)))
    (error (e)
      (format t "Error: ~a~%" e)
      (uiop:quit 1))))

(defun generate-l0-launcher (metacrisp-path)
  "Generate Level Zero C++ launcher code from metacrisp file."
  (let ((data (parse-metacrisp-file metacrisp-path)))
    (format t "TODO: Generate C++ code for Level Zero~%")
    (format t "  Kernels: ~a~%" (length (metacrisp-kernels data)))
    (format t "  Aliases: ~a~%" (length (metacrisp-aliases data)))
    (format t "  Structs: ~a~%" (length (metacrisp-structs data)))))
