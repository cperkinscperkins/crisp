(defun check-file (path)
  (with-open-file (s path)
    (let ((balance 0)
          (line 1)
          (col 0))
      (loop for char = (read-char s nil nil)
            while char do
              (incf col)
              (case char
                (#\( (incf balance))
                (#\) (decf balance))
                (#\Newline (incf line) (setf col 0))
                (#\; (read-line s nil nil) (incf line) (setf col 0))) ;; Simple comment skip

              (when (< balance 0)
                    (format t "Extra closing paren at ~a:~a~%" line col)
                    (return-from check-file)))
      (format t "Final Balance: ~a~%" balance))))

(check-file "src/templates.lisp")
