;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/templates.lisp
(in-package :crisp.compiler)

;;; ----------------------------------------------------------------------------
;;; Template Infrastructure
;;; ----------------------------------------------------------------------------

(defstruct template-data
  "Stores the definition of a template function."
  (name nil :type symbol)
  (parameters nil :type list) ; Type parameters, e.g., (T U)
  (constraints nil :type list) ; Constraints from declare, e.g., ((type-is T ...))
  (body nil :type list) ; The full (def-function ...) form
  (signature nil :type list)) ; The declared signature, if any

(defvar *template-registry* (make-hash-table)
        "Maps template names (symbols) to a LIST of template-data structs.
This supports overloading templates by arity or other factors.")

(defvar *instantiated-templates* (make-hash-table :test 'equal)
        "Tracks which specializations have already been generated.
Key: (template-name . concrete-types)
Value: The expanded form (or T).")

(defun register-template (name params constraints body signature)
  "Registers a new template definition."
  (let ((data (make-template-data :name name
                                  :parameters params
                                  :constraints constraints
                                  :body body
                                  :signature signature)))
    ;; Append to the list of templates for this name
    (setf (gethash name *template-registry*)
      (append (gethash name *template-registry*) (list data)))))

;;; ----------------------------------------------------------------------------
;;; with-template-type Macro
;;; ----------------------------------------------------------------------------

(defmacro with-template-type (params &body body)
  "Defines templates for the enclosed forms."
  ;; 1. Parse constraints from the body (if any)
  (let* ((declare-form (when (and (listp (first body)) (eq (first (first body)) 'declare))
                             (first body)))
         (real-body (if declare-form (rest body) body))
         (constraints (when declare-form (rest declare-form))))

    `(progn
      ,@(loop for form in real-body
                when (and (listp form) (eq (first form) 'def-function))
              collect (let ((name (second form))
                            (args (third form))
                            (fn-body (cdddr form)))
                        ;; Extract signature from function body if present
                        (let* ((sig-decl (find-if (lambda (f) (and (listp f) (eq (car f) 'declare))) fn-body))
                               (signature (when sig-decl (second sig-decl))))

                          `(progn
                            ;; Register the template at compile/load time
                            (eval-when (:compile-toplevel :load-toplevel :execute)
                              (register-template ',name ',params ',constraints ',form ',signature))

                            ;; Define the generator macro: (gen-NAME ...)
                            (defmacro ,(intern (format nil "GEN-~a" name) (symbol-package name)) (&rest concrete-types)
                              (instantiate-template ',name concrete-types))

                            ;; Define the type helper macro: (NAME-type ...)
                            (defmacro ,(intern (format nil "~a-TYPE" name) (symbol-package name)) (&rest concrete-types)
                              `(get-template-signature ',',name ',concrete-types)))))))))

;;; ----------------------------------------------------------------------------
;;; Template Instantiation Logic
;;; ----------------------------------------------------------------------------

(defun instantiate-template (name concrete-types)
  "Generates the specialized code for a template."
  (let ((templates (gethash name *template-registry*)))
    (unless templates
      (error "No template found for ~a" name))

    ;; Find matching templates by arity of type parameters
    (let ((matches (remove-if-not (lambda (t-data)
                                    (= (length (template-data-parameters t-data))
                                      (length concrete-types)))
                       templates)))
      (unless matches
        (error "No template for ~a matches the provided type arguments: ~a" name concrete-types))

      ;; Instantiate all matches
      `(progn
        ,@(loop for tmpl in matches
                for key = (cons name concrete-types)
                  unless (gethash key *instantiated-templates*)
                collect (let ((substitutions (pairlis (template-data-parameters tmpl) concrete-types)))
                          ;; Mark as instantiated to avoid recursion/duplication
                          (setf (gethash key *instantiated-templates*) t)

                          ;; Perform substitution on the body
                          (sublis substitutions (template-data-body tmpl))))))))

(defun get-template-signature (name concrete-types)
  "Returns the specialized signature for a template."
  (let ((templates (gethash name *template-registry*)))
    (unless templates
      (error "No template found for ~a" name))

    (let ((match (find-if (lambda (t-data)
                            (= (length (template-data-parameters t-data))
                              (length concrete-types)))
                     templates)))
      (unless match
        (error "No template for ~a matches the provided type arguments: ~a" name concrete-types))

      (let ((substitutions (pairlis (template-data-parameters match) concrete-types)))
        (sublis substitutions (template-data-signature match))))))

;;; ----------------------------------------------------------------------------
;;; Reader Macro: <...>
;;; ----------------------------------------------------------------------------

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun read-template-bracket (stream char)
    (declare (ignore char))
    (let ((next-char (peek-char nil stream nil nil t)))
      (cond
       ;; Case 1: Standard "less than" or "less than or equal" or "shift"
       ((member next-char '(#\Space #\Tab #\Newline #\Return #\( #\)))
         (intern "<"))
       ((char= next-char #\=)
         (read-char stream)
         (intern "<="))
       ((char= next-char #\<)
         (read-char stream)
         (intern "<<"))

       ;; Case 1.5: End of file or other delimiters
       ((null next-char)
         (intern "<"))

       ;; Case 2: Template syntax <T U>
       (t
         (let ((chars (loop for c = (read-char stream t nil t)
                            until (char= c #\>)
                            collect c)))
           (let* ((string-content (coerce chars 'string))
                  ;; Read the string as a list of symbols: "T U" -> (T U)
                  (params (read-from-string (format nil "(~a)" string-content)))
                  ;; Create a unique symbol for the macro, e.g., |<T U>|
                  (macro-name (intern (format nil "<~a>" string-content))))

             ;; Define the macro on the fly if it doesn't exist
             (unless (macro-function macro-name)
               (eval `(defmacro ,macro-name (&body body)
                        `(with-template-type ,',params ,@body))))

             ;; Return the macro symbol
             macro-name)))))))

;; Register the reader macro as NON-TERMINATING so it doesn't break symbols like string<
(eval-when (:compile-toplevel :load-toplevel :execute)
  (set-macro-character #\< #'read-template-bracket t))
