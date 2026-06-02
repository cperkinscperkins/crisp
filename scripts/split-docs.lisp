;;; Documentation Splitter in Common Lisp
;;; Usage: sbcl --script scripts/split-docs.lisp

(require :uiop)

;;; Configuration
(defparameter *input-file* "docs/ideal_001.md")
(defparameter *output-dir* "docs/chapters/")
(defparameter *index-file* "docs/chapters/index.md")

(defun clean-filename (text)
  "Turns 'Higher Order Functions' into 'higher_order_functions'.
   Replaces non-alphanumeric chars with _, collapses duplicates, and lowercases."
  (let* ((downcased (string-downcase (string-trim '(#\Space #\Tab) text)))
         ;; Keep only alphanumeric, space, _, -
         (filtered (remove-if-not (lambda (c)
                                    (or (alphanumericp c)
                                        (member c '(#\Space #\_ #\-))))
                                  downcased))
         ;; Replace space and dash with underscore
         (sub-space (substitute #\_ #\Space filtered))
         (sub-dash (substitute #\_ #\- sub-space)))
    ;; Collapse multiple underscores
    (with-output-to-string (s)
      (loop for c across sub-dash
            with last-was-underscore = nil
            do (cond ((char= c #\_)
                      (unless last-was-underscore
                        (write-char c s)
                        (setf last-was-underscore t)))
                     (t
                      (write-char c s)
                      (setf last-was-underscore nil)))))))

(defun header-line-p (line char)
  "Checks if a line consists (mostly) of a specific character (like = or -), used for Setext headers."
  (let ((trimmed (string-trim '(#\Space #\Return #\Newline) line)))
    (and (> (length trimmed) 2)
         (every (lambda (c) (char= c char)) trimmed))))

(defun write-buffer-to-file (file-path buffer)
  "Writes the accumulated string buffer to the file."
  (with-open-file (stream file-path 
                          :direction :output 
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (write-string buffer stream)))

(defun main ()
  (unless (probe-file *input-file*)
    (format t "Error: Could not find ~A~%" *input-file*)
    (uiop:quit 1))

  ;; Clean output directory if it exists
  (when (probe-file *output-dir*)
    (format t "Cleaning old output directory...~%")
    (uiop:delete-directory-tree (pathname *output-dir*) :validate t :if-does-not-exist :ignore))
  
  (ensure-directories-exist *output-dir*)

  (let ((lines (uiop:read-file-lines *input-file*))
        (chapter-num 0)
        (section-num 0)
        (nav-chapters nil)
        (in-code-block nil)
        ;; Default to preamble before first chapter
        (current-chapter-dir (merge-pathnames "00_preamble/" *output-dir*))
        (current-section-file nil)
        ;; Adjustable string buffer for content
        (current-buffer (make-array 0 :element-type 'character :fill-pointer 0 :adjustable t))
        ;; Adjustable string buffer for the master index
        (index-content (make-array 0 :element-type 'character :fill-pointer 0 :adjustable t)))

    ;; Initialize Master Index content
    (format index-content "# Crisp Language Specification~%~%")
    
    ;; Pre-create preamble directory
    (ensure-directories-exist current-chapter-dir)

    (loop with i = 0
          while (< i (length lines))
          do (let* ((orig-line (elt lines i))
                    (trimmed (string-trim '(#\Space #\Tab #\Return) orig-line)))
               
                (cond
                 ;; Case 0: Track code blocks
                 ((and (>= (length trimmed) 3)
                       (string= "```" trimmed :end2 3))
                  (setf in-code-block (not in-code-block))
                  (format current-buffer "~A~%" (string-trim '(#\Return) orig-line))
                  (incf i))

                 ;; Case 0.5: In code block, treat as normal text
                 (in-code-block
                  (format current-buffer "~A~%" (string-trim '(#\Return) orig-line))
                  (incf i))

                 ;; Case 1: Chapter Header (starts with "# " or "## ")
                 ((or (and (>= (length trimmed) 2)
                           (string= "# " trimmed :end2 2))
                      (and (>= (length trimmed) 3)
                           (string= "## " trimmed :end2 3)))
                  ;; Flush previous file if active
                  (when current-section-file
                    (write-buffer-to-file current-section-file current-buffer)
                    (setf (fill-pointer current-buffer) 0))

                  ;; Setup New Chapter
                  (incf chapter-num)
                  (setf section-num 0)
                  
                  (let* ((prefix-len (if (string= "# " trimmed :end2 2) 2 3))
                         (title (string-trim '(#\Space #\Tab #\Return) (subseq trimmed prefix-len)))
                         (slug (clean-filename title))
                         (dirname (format nil "~2,'0d_~A/" chapter-num slug)))
                    
                    (setf current-chapter-dir (merge-pathnames dirname *output-dir*))
                    (ensure-directories-exist current-chapter-dir)

                    (let ((chapter-dirname (car (last (pathname-directory current-chapter-dir)))))
                      ;; Append to Master Index
                      (format index-content "~%## ~A~%" title)

                      ;; Start a new intro file for the chapter
                      (setf current-section-file (merge-pathnames "00_intro.md" current-chapter-dir))
                      (format current-buffer "# ~A~%~%" title)
                      
                      ;; Add to nav structure
                      (push (list title (cons "Introduction" (format nil "chapters/~A/00_intro.md" chapter-dirname))) nav-chapters))
                    
                    (incf i)))

                 ;; Case 2: Section Header (starts with "### ")
                 ((and (>= (length trimmed) 4)
                       (string= "### " trimmed :end2 4))
                  ;; Flush previous file if active
                  (when current-section-file
                    (write-buffer-to-file current-section-file current-buffer)
                    (setf (fill-pointer current-buffer) 0))

                  ;; Setup New Section
                  (incf section-num)
                  (let* ((title (string-trim '(#\Space #\Tab #\Return) (subseq trimmed 4)))
                         (slug (clean-filename title))
                         (filename (format nil "~2,'0d_~A.md" section-num slug)))
                    
                    (setf current-section-file (merge-pathnames filename current-chapter-dir))

                    ;; Append Link to Master Index
                    ;; Relative path from docs/chapters/index.md: 01_intro/01_file.md
                    (let* ((chapter-dirname (car (last (pathname-directory current-chapter-dir))))
                           (rel-path (format nil "~A/~A" chapter-dirname filename)))
                       (format index-content "- [~A](~A/~A)~%" title chapter-dirname filename)
                       
                       ;; Add to nav structure
                       (setf (car nav-chapters)
                             (append (car nav-chapters)
                                     (list (cons title rel-path)))))
                    
                    ;; Start buffer with header (H1 to prevent redundant sidebar nesting)
                    (format current-buffer "# ~A~%~%" title)

                    (incf i)))

                 ;; Case 3: Normal Text
                 (t
                  ;; read-file-lines strips newlines, so we must add them back
                  (format current-buffer "~A~%" (string-trim '(#\Return) orig-line))
                  (incf i)))))

    ;; Flush any remaining content in the buffer at EOF
    (when current-section-file
      (write-buffer-to-file current-section-file current-buffer))

    ;; Write the Master Index file
    (write-buffer-to-file *index-file* index-content)

    (format t "Done! Split ~D chapters into ~A~%" chapter-num *output-dir*)
    (format t "Generated Master Index at ~A~%" *index-file*)))

;; Run it
(main)