;;;
;;;  sbcl --non-interactive --load ./scripts/generate-reference.lisp
;;;


(require :asdf)
(require :sb-introspect)

(defun load-project ()
  (format t "~&Loading Crisp system...~%")
  (push (uiop:getcwd) ql:*local-project-directories*)
  (ql:register-local-projects)
  (ql:quickload "crisp")
  (format t "~&Crisp system loaded.~%"))

;; Helper to safely extract elements from a form
(defun safe-get (list index)
  (if (and (listp list) (> (length list) index))
      (nth index list)
      nil))

(defun parse-docstring-and-body (body)
  "Helper to find docstring in a list of body forms.
   Returns (docstring . remaining-body)."
  (let ((doc nil)
        (rest body))
    (when (stringp (first body))
          (setf doc (first body))
          (setf rest (rest body)))
    (values doc rest)))

(defun extract-def-info (form)
  "Analyzes a top-level form and returns specific info:
   (:type :name :args :docstring)"
  (unless (and (listp form) (symbolp (first form)))
    (return-from extract-def-info (list :type :other :form form)))

  (let ((op (symbol-name (first form)))
        (args (rest form)))
    (cond
     ((member op '("DEFUN" "DEFMACRO" "DEFGENERIC" "DEF-FUNCTION" "DEF-KERNEL" "DEF-GRID-FUNCTION") :test #'string=)
       (let ((name (first args))
             (lambda-list (second args))
             (body (cddr args)))
         (multiple-value-bind (doc remaining) (parse-docstring-and-body body)
           (list :type (intern op "KEYWORD")
                 :name name
                 :args lambda-list
                 :docstring doc))))

     ((member op '("DEFSTRUCT" "DEFCLASS") :test #'string=)
       (let ((name-spec (first args))
             (body (rest args)))
         (let ((name (if (listp name-spec) (first name-spec) name-spec))
               (doc (if (stringp (first body)) (first body) nil)))
           (list :type (intern op "KEYWORD")
                 :name name
                 :docstring doc))))

     ((member op '("DEFVAR" "DEFPARAMETER" "DEFCONSTANT") :test #'string=)
       (let ((name (first args))
             ;; val is second
             (doc (third args)))
         (list :type (intern op "KEYWORD")
               :name name
               :docstring doc)))

     ((member op '("DEFPACKAGE" "IN-PACKAGE") :test #'string=)
       (list :type :skip))

     (t
       (list :type :other :name (first form))))))

(defun process-file (file stream)
  (format stream "## File: `~a`~%~%" (uiop:native-namestring file))

  (with-open-file (in file :direction :input)
    (loop for form = (read in nil :eof)
          until (eq form :eof)
          do
            (let ((info (extract-def-info form)))
              (unless (eq (getf info :type) :skip)
                (cond
                 ((eq (getf info :type) :other)
                   ;; Maybe just log small note?
                   ;; (format stream "- *Top-level form: ~a*~%" (getf info :name))
                   nil)
                 (t
                   (format stream "### ~a `~a`~%" (getf info :type) (getf info :name))
                   (when (getf info :args)
                         (format stream "- **Args**: `~a`~%" (getf info :args)))
                   (when (getf info :docstring)
                         (format stream "~%  > ~a~%~%"
                           (uiop:symbol-call :cl-ppcre :regex-replace-all "\\n" (getf info :docstring) "  > ")))
                   (format stream "~%---~%"))))))))

(defun main ()
  (load-project)
  (ql:quickload "local-time")
  (ql:quickload "cl-ppcre")

  (format t "~&Generating reference...~%")

  (with-open-file (stream "docs/reference.md" :direction :output :if-exists :supersede)
    (format stream "# Crisp Codebase Reference~%~%")
    (format stream "Generated on ~a~%~%"
      (uiop:symbol-call :local-time :format-timestring nil
        (uiop:symbol-call :local-time :now)))

    (let* ((sys (asdf:find-system "crisp"))
           ;; Getting components in order.
           ;; For a simple :serial t system, this usually works.
           ;; We filter for :file components and construct full path.
           (components (asdf:component-children sys)))

      (dolist (c components)
        (when (typep c 'asdf:cl-source-file)
              (let ((path (asdf:component-pathname c)))
                (format t "Processing ~a...~%" path)
                (process-file path stream))))))

  (format t "~&Done. Written to docs/reference.md~%")
  (uiop:quit 0))

(main)
