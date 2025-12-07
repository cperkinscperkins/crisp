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
                              (register-template ',name ',params ',constraints ',form ',signature)) ;; Define the generator macro: (gen-NAME ...)
                            (defmacro ,(intern (format nil "GEN-~a" name) (symbol-package name)) (&rest concrete-types)
                              `(template-instantiation ,(instantiate-template ',name concrete-types)))

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
        (error "No template for ~a matches the provided type arguments: ~a" name concrete-types)) ;; Instantiate all matches
      `(progn
        ,@(loop for tmpl in matches
                for key = (cons name concrete-types)
                  ;; We do NOT check *instantiated-templates* here because the compiler
                  ;; runs in multiple passes (signature analysis + codegen).
                  ;; If we suppress output, the second pass sees nothing and generates no code.
                  ;; The compiler handles duplicate definitions safely.
                collect (let ((substitutions (pairlis (template-data-parameters tmpl) concrete-types)))
                          ;; Mark as instantiated (optional, for other purposes)
                          (setf (gethash key *instantiated-templates*) t)

                          ;; Perform substitution on the body
                          (sublis substitutions (template-data-body tmpl))))))))

(defun get-template-signature (name concrete-types)
  "Returns the specialized signature for a template."
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

      ;; For now, just take the first match's signature and substitute
      (let* ((tmpl (first matches))
             (substitutions (pairlis (template-data-parameters tmpl) concrete-types))
             (sig (template-data-signature tmpl)))
        (when sig
              (sublis substitutions sig))))))

(defun try-infer-template-types (name argument-types)
  "Attempts to infer template parameters for 'name' given 'argument-types'.
   Returns a list of concrete types if successful, or NIL."
  (let ((templates (gethash name *template-registry*)))
    (unless templates (return-from try-infer-template-types nil))

    (loop for tmpl in templates do
            (let* ((raw-sig (template-data-signature tmpl))
                   ;; Unwrap (FUNCTION ...) if present
                   (sig (if (and (listp raw-sig) (eq (first raw-sig) 'COMMON-LISP:FUNCTION))
                            (second raw-sig)
                            raw-sig))
                   (params (template-data-parameters tmpl)) ; e.g. (T)
                   ;; sig is now (T T => T). We want (T T).
                   (sig-params (when sig (butlast sig 2)))) 
              
              ;; 1. Check arity match between args and signature params
              (when (and sig-params (= (length sig-params) (length argument-types)))
                    (let ((inference-map (make-hash-table)))
                      (block inference-loop
                        (loop for sig-param in sig-params
                              for arg-type in argument-types
                              do (cond
                                  ;; Case A: sig-param is a template parameter (e.g. T)
                                  ((member sig-param params)
                                    (let ((existing (gethash sig-param inference-map)))
                                      (if existing
                                          ;; Must match exactly (no promotion)
                                          (unless (equal existing arg-type)
                                            (return-from inference-loop nil))
                                          ;; First time seeing this param, record it
                                          (setf (gethash sig-param inference-map) arg-type))))

                                  ;; Case B: sig-param is a concrete type (e.g. int)
                                  ((valid-type-p sig-param)
                                    (unless (equal sig-param arg-type)
                                      (return-from inference-loop nil)))

                                  ;; Case C: Unknown?
                                  (t (return-from inference-loop nil))))

                        ;; If we get here, all args matched consistent types.
                        ;; Ensure all template parameters were inferred.
                        (let ((concrete-types (loop for p in params
                                                    collect (gethash p inference-map))))
                          (if (every #'identity concrete-types)
                              (return-from try-infer-template-types concrete-types)
                              nil)))))))))


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
