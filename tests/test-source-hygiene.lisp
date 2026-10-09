;; tests/test-source-hygiene.lisp
;;
;; BUG 110.  In a CRLF source file a FORMAT string's "~<newline>" continuation is really
;; "~<return><newline>", and FORMAT reads "~<return>" as an unknown directive -- so the message
;; that was meant to explain an error crashes instead ("Unknown format directive (character:
;; Return)").  It is invisible until the error path runs, which is exactly when the message is
;; needed: 181/02 hit one live, and the 2026-10-08 sweep found 24 more in nine error messages.
;;
;; This scans the source TEXT under src/ for a tilde followed by CR-LF inside a string literal.
;; Comments and character literals are skipped.  Any string counts, not only FORMAT controls:
;; telling a docstring from a control string needs the reader, and a joined docstring costs nothing.

(in-package :crisp.tests)

(defun %tilde-crlf-in-strings (path)
  "Line numbers in PATH where a string literal contains ~ immediately followed by CR LF."
  (let* ((text (uiop:read-file-string path :external-format :utf-8))
         (n (length text))
         (hits '())
         (line 1)
         (in-str nil)
         (i 0))
    (flet ((ch (k) (and (< k n) (cl:char text k))))
      (loop while (< i n)
            do (let ((c (cl:char text i)))
                 (when (char= c #\Newline) (incf line))
                 (cond
                   ((not in-str)
                    (cond
                      ((char= c #\;)                       ; comment to end of line
                       (loop while (and (< i n) (char/= (cl:char text i) #\Newline)) do (incf i))
                       (decf i))
                      ((and (char= c #\#) (eql (ch (1+ i)) #\|)) ; block comment
                       (let ((end (search "|#" text :start2 (+ i 2))))
                         (loop for k from i below (or end n)
                               when (char= (cl:char text k) #\Newline) do (incf line))
                         (setf i (if end (1+ end) n))))
                      ((and (char= c #\#) (eql (ch (1+ i)) #\\)) ; character literal
                       (incf i 2))
                      ((char= c #\") (setf in-str t))))
                   ((char= c #\\) (incf i))                ; escape inside a string
                   ((char= c #\") (setf in-str nil))
                   ((and (char= c #\~) (eql (ch (1+ i)) #\Return) (eql (ch (+ i 2)) #\Newline))
                    (push line hits))))
               (incf i)))
    (nreverse hits)))

(define-test source-hygiene
  "Properties of the source text that no compile catches.")

(define-test (source-hygiene no-tilde-crlf-continuations)
  "BUG 110: no string literal under src/ contains ~ followed by CR LF."
  (let ((files (directory (merge-pathnames "src/**/*.lisp" (uiop:getcwd)))))
    (true (> (length files) 20) "found only ~a source files; the glob is probably wrong" (length files))
    (dolist (f files)
      (let ((hits (%tilde-crlf-in-strings f)))
        (false hits
               "~a: a string literal has a ~~<CR><LF> continuation at line(s) ~{~a~^, ~} -- FORMAT will crash on it (BUG 110); join the line instead"
               (enough-namestring f (uiop:getcwd)) hits)))))
