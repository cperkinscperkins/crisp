;;; Documentation Splitter in Common Lisp
;;; Usage: sbcl --script scripts/split-docs.lisp

(require :uiop)

;;; Configuration
(defparameter *input-file* "docs/ideal_001.md")
(defparameter *output-dir* "docs/chapters/")
(defparameter *index-file* "docs/index.md")

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
          do (let* ((line (elt lines i))
                    ;; Look ahead to next line
                    (next-line (if (< (+ i 1) (length lines)) (elt lines (+ i 1)) ""))
                    (trimmed-next (string-trim '(#\Space #\Return #\Newline) next-line)))
               
               (cond
                 ;; Case 1: Chapter Header (======)
                 ((header-line-p trimmed-next #\=)
                  ;; Flush previous file if active
                  (when current-section-file
                    (write-buffer-to-file current-section-file current-buffer)
                    (setf (fill-pointer current-buffer) 0))

                  ;; Setup New Chapter
                  (incf chapter-num)
                  (setf section-num 0)
                  
                  (let* ((title (string-trim '(#\Space #\Return) line))
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
                    
                    ;; Skip both title line and underline
                    (incf i 2)))

                 ;; Case 2: Section Header (------)
                 ((header-line-p trimmed-next #\-)
                  ;; Flush previous file if active
                  (when current-section-file
                    (write-buffer-to-file current-section-file current-buffer)
                    (setf (fill-pointer current-buffer) 0))

                  ;; Setup New Section
                  (incf section-num)
                  (let* ((title (string-trim '(#\Space #\Return) line))
                         (slug (clean-filename title))
                         (filename (format nil "~2,'0d_~A.md" section-num slug)))
                    
                    (setf current-section-file (merge-pathnames filename current-chapter-dir))

                    ;; Append Link to Master Index
                    ;; We need the relative path for Markdown: chapters/01_intro/01_file.md
                    (let* ((chapter-dirname (car (last (pathname-directory current-chapter-dir))))
                           (rel-path (format nil "chapters/~A/~A" chapter-dirname filename)))
                       (format index-content "- [~A](chapters/~A/~A)~%" title chapter-dirname filename)
                       
                       ;; Add to nav structure
                       (setf (car nav-chapters)
                             (append (car nav-chapters)
                                     (list (cons title rel-path)))))
                    
                    ;; Start buffer with header (H1 to prevent redundant sidebar nesting)
                    (format current-buffer "# ~A~%~%" title)

                    ;; Skip both title line and underline
                    (incf i 2)))

                 ;; Case 3: Normal Text
                 (t
                  ;; read-file-lines strips newlines, so we must add them back
                  (format current-buffer "~A~%" (string-trim '(#\Return) line))
                  (incf i)))))

    ;; Flush any remaining content in the buffer at EOF
    (when current-section-file
      (write-buffer-to-file current-section-file current-buffer))

    ;; Write the Master Index file
    (write-buffer-to-file *index-file* index-content)

    ;; Generate mkdocs.yml with navigation
    (setf nav-chapters (nreverse nav-chapters))
    (let ((base-content (if (probe-file "mkdocs-base.yml")
                            (uiop:read-file-string "mkdocs-base.yml")
                            "")))
      (with-open-file (stream "mkdocs.yml" 
                              :direction :output 
                              :if-exists :supersede
                              :if-does-not-exist :create)
        (write-string base-content stream)
        (format stream "~%nav:~%")
        (format stream "  - \"Welcome\": \"index.md\"~%")
        (format stream "  - \"The Blueprint Philosophy\": \"crisp-curios.md\"~%")
        (format stream "  - \"Crisp Codebase Reference\": \"reference.md\"~%")
        (format stream "  - \"Crisp Testing Guide\": \"tests.md\"~%")
        (format stream "  - \"Call Graph\": \"call_graph.md\"~%")
        (format stream "  - \"Defmacro Utilities\": \"defmacro-utils.md\"~%")
        (format stream "  - \"Benchmarks\": \"benchmarks.md\"~%")
        (format stream "  - \"Criticisms\": \"criticsms.md\"~%")
        (format stream "  - \"Elevator Pitches\": \"elevator_pitches.md\"~%")
        (format stream "  - \"Chapters\":~%")
        (dolist (ch nav-chapters)
          (let ((ch-title (remove #\" (car ch)))
                (sections (cdr ch)))
            (format stream "      - \"~A\":~%" ch-title)
            (dolist (sec sections)
              (let ((sec-title (remove #\" (car sec)))
                    (sec-path (cdr sec)))
                (let ((clean-path (substitute #\/ #\\ sec-path)))
                  (format stream "          - \"~A\": \"~A\"~%" sec-title clean-path))))))))

    (format t "Done! Split ~D chapters into ~A~%" chapter-num *output-dir*)
    (format t "Generated Master Index at ~A~%" *index-file*)
    (format t "Generated mkdocs.yml navigation~%")))

;; Run it
(main)