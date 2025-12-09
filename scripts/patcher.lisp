(require :uiop)

(defun read-file-content (path)
  (with-open-file (stream path :direction :input)
    (let ((seq (make-string (file-length stream))))
      (read-sequence seq stream)
      seq)))

(defun write-file-content (path content)
  (with-open-file (stream path :direction :output :if-exists :supersede)
    (write-sequence content stream)))

(defun is-whitespace (char)
  (member char '(#\Space #\Tab #\Newline #\Return)))

(defun find-next-fuzzy-match (text search-pattern start-offset)
  "Finds the start and end indices of search-pattern in text, starting from start-offset, ignoring whitespace differences.
   Returns (values start-index end-index) or (values nil nil)."
  (let ((t-len (length text))
        (p-len (length search-pattern)))
    (loop for i from start-offset below t-len do
            (block match-attempt
              (let ((t-idx i)
                    (p-idx 0))
                (loop while (< p-idx p-len) do
                        (let ((p-char (char search-pattern p-idx)))
                          (cond
                           ;; Case 1: Pattern has whitespace -> Consume whitespace in both
                           ((is-whitespace p-char)
                             ;; Consume whitespace in pattern
                             (loop while (and (< p-idx p-len) (is-whitespace (char search-pattern p-idx)))
                                   do (incf p-idx))
                             ;; Consume whitespace in text
                             (let ((found-ws nil))
                               (loop while (and (< t-idx t-len) (is-whitespace (char text t-idx)))
                                     do (setf found-ws t) (incf t-idx))))

                           ;; Case 2: Non-whitespace char -> Must match exactly
                           (t
                             (if (and (< t-idx t-len) (char= (char text t-idx) p-char))
                                 (progn (incf t-idx) (incf p-idx))
                                 (return-from match-attempt nil))))))
                ;; If we got here, we matched the whole pattern!
                (return-from find-next-fuzzy-match (values i t-idx))))))
  (values nil nil))

(defun find-all-matches (text search-pattern)
  "Returns a list of (start end) pairs for all matches."
  (let ((matches '())
        (current-offset 0))
    (loop
     (multiple-value-bind (start end) (find-next-fuzzy-match text search-pattern current-offset)
       (if start
           (progn
            (push (list start end) matches)
            (setf current-offset end)) ; Continue searching after the match
           (return))))
    (nreverse matches)))

(defun apply-patch (patch-file)
  (let* ((patch-spec (with-open-file (in patch-file) (read in)))
         (target-file (getf patch-spec :file))
         (search-str (getf patch-spec :search))
         (replace-str (getf patch-spec :replace)))

    (format t "Applying patch from ~a to ~a~%" patch-file target-file)

    (unless (probe-file target-file)
      (format t "Error: Target file ~a not found.~%" target-file)
      (uiop:quit 1))

    (let* ((content (read-file-content target-file))
           (matches (find-all-matches content search-str))
           (match-count (length matches)))

      (cond
       ((= match-count 1)
         (let* ((match (first matches))
                (start (first match))
                (end (second match))
                (new-content (concatenate 'string
                               (subseq content 0 start)
                               replace-str
                               (subseq content end))))
           (write-file-content target-file new-content)
           (format t "Patch applied successfully!~%")
           (uiop:quit 0)))
       ((= match-count 0)
         (format t "Error: Could not find search block in target file.~%")
         (format t "Search block was:~%~a~%" search-str)
         (uiop:quit 1))
       (t
         (format t "Error: Found ~a matches for search block. Patch must be unique.~%" match-count)
         (uiop:quit 1))))))

(defun main ()
  (let ((args (uiop:command-line-arguments)))
    (if (/= (length args) 1)
        (progn
         (format t "Usage: sbcl --script scripts/patcher.lisp <patch-file>~%")
         (uiop:quit 1))
        (apply-patch (first args)))))

(main)
