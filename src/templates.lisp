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
              collect
                (cond
                 ((and (listp form) (eq (first form) 'def-function))
                   (let ((name (second form))
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
                           `(get-template-signature ',',name ',concrete-types))))))

                 ((and (listp form) (eq (first form) 'def-struct))
                   (let* ((name (second form))
                          (members (cddr form))
                          ;; Parse (x type) (y type) -> (type type => name)
                          (member-types (mapcar #'second members))
                          (signature `(function (,@member-types => ,name))))
                     `(progn
                       ;; Register the template for Struct with synthesized constructor signature
                       (eval-when (:compile-toplevel :load-toplevel :execute)
                         (register-template ',name ',params ',constraints ',form ',signature))

                       ;; Define the generator macro: (gen-NAME ...)
                       (defmacro ,(intern (format nil "GEN-~a" name) (symbol-package name)) (&rest concrete-types)
                         `(template-instantiation ,(instantiate-template ',name concrete-types)))

                       ;; Define the type helper macro: (NAME-type ...) 
                       ;; For structs, this returns the Mangled Name.
                       (defmacro ,(intern (format nil "~a-TYPE" name) (symbol-package name)) (&rest concrete-types)
                         (let ((mangled (intern (format nil "~a_~{~a~^_~}" ',name concrete-types) (symbol-package ',name))))
                           `',mangled))))))))))

;;; ----------------------------------------------------------------------------
;;; Template Instantiation Logic
;;; ----------------------------------------------------------------------------


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


(defun normalize-template-sig-type (type)
  "Converts (function ...) specs to (:function-type ...) structs for matching."
  (if (and (listp type) (member (first type) '(common-lisp:function function)))
      (let* ((inner (if (listp (second type)) (second type) (rest type))) ;; Handle (function (args...))
                                                                         (arrow-pos (position '=> inner))
                                                                         (params (subseq inner 0 (or arrow-pos (length inner))))
                                                                         (ret (when arrow-pos (nth (1+ arrow-pos) inner))))
        `(:function-type ,ret :params ,params))
      type))

(defun match-template-arg (raw-sig-type arg-type inference-map template-params)
  "Recursively matches sig-type against arg-type, updating inference-map."
  (let ((sig-type (normalize-template-sig-type raw-sig-type)))
    (cond
     ;; 1. Template Parameter (e.g. T)
     ((member sig-type template-params)
       (let ((existing (gethash sig-type inference-map)))
         (if existing
             (equal existing arg-type)
             (progn (setf (gethash sig-type inference-map) arg-type) t))))

     ;; 2. Match Function Literal against a Function Type Pattern
     ;; Special Case: Only if we are looking for a function type and find a literal func-name.
     ((and (listp sig-type) (eq (first sig-type) :function-type)
           (listp arg-type) (eq (first arg-type) :function-literal))
       (let* ((name (second arg-type))
              (signatures (gethash name *function-table*)))
         (loop for sig in signatures
                 ;; Try to match this overload
                 when (match-function-signature sig-type sig inference-map template-params)
                 return t)))

     ;; 3. Generic List Pattern - Handles (vector T) AND (:function-type ...)
     ((listp sig-type)
       (match-list-structure sig-type arg-type inference-map template-params))

     ;; 4. Concrete Type (int)
     (t (equal sig-type arg-type)))))

(defun match-list-structure (sig-list arg-list inference-map template-params)
  (and (listp arg-list)
       (= (length sig-list) (length arg-list))
       (loop for s in sig-list for a in arg-list
               always (match-template-arg s a inference-map template-params))))

(defun match-function-signature (pattern-sig concrete-sig inference-map template-params)
  ;; pattern-sig: (:function-type <ret> :params (<p1>...))
  ;; concrete-sig: function-signature struct
  (let ((p-ret (getf pattern-sig :function-type))
        (p-params (getf pattern-sig :params)))
    (when (= (length p-params) (length (function-signature-parameters concrete-sig)))
          ;; Use a temporary map to avoid pollution
          (let ((temp-map (make-hash-table)))
            ;; Copy existing mappings
            (maphash (lambda (k v) (setf (gethash k temp-map) v)) inference-map)

            (if (and (loop for pp in p-params
                           for cp in (function-signature-parameters concrete-sig)
                             always (match-template-arg pp cp temp-map template-params))
                     (match-template-arg p-ret (first (function-signature-return-types concrete-sig)) temp-map template-params))
                (progn
                 ;; Commit changes
                 (maphash (lambda (k v) (setf (gethash k inference-map) v)) temp-map)
                 t)
                nil)))))


(defun initialize-templates ()
  "Initializes the template system and hooks into the compiler."
  (setf crisp.compiler::*template-instantiator-fn* #'ensure-template-instantiation)
  (log:info "Template system initialized."))

;;; ----------------------------------------------------------------------------

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun read-template-bracket (stream char)
    (declare (ignore char))
    (let ((next-char (peek-char nil stream nil nil t)))
      (cond
       ;; Case 1: Standard "less than" or "less than or equal" or "shift"
       ((null next-char)
         (intern "<"))

       ;; Case 1: Standard "less than" or "less than or equal" or "shift"
       ((member next-char '(#\Space #\Tab #\Newline #\Return #\( #\)))
         (intern "<"))
       ((char= next-char #\=)
         (read-char stream)
         (intern "<="))
       ((char= next-char #\<)
         (read-char stream)
         (intern "<<"))

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
;;; ============================================================================
;;; REDEFINITIONS FOR ROBUST TEMPLATE AMBIGUITY HANDLING
;;; ============================================================================

(defun instantiate-template (name-or-tmpl concrete-types)
  "Generates the specialized code for a template. 
   name-or-tmpl can be a symbol (name) or a template-data struct."
  (let* ((tmpl (if (template-data-p name-or-tmpl)
                   name-or-tmpl
                   ;; Legacy lookup by name + arity
                   (let ((templates (gethash name-or-tmpl *template-registry*)))
                     (unless templates (error "No template found for ~a" name-or-tmpl))
                     (find-if (lambda (t-data)
                                (= (length (template-data-parameters t-data))
                                  (length concrete-types)))
                         templates))))
         (name (if tmpl (template-data-name tmpl) name-or-tmpl)))

    (unless tmpl
      (error "No template for ~a matches the provided type arguments: ~a" name concrete-types))

    ;; Instantiate single template
    (let ((substitutions (pairlis (template-data-parameters tmpl) concrete-types)))

      ;; Check if it's a struct template by inspecting the body
      (let* ((body (template-data-body tmpl))
             (is-struct (and (listp body) (eq (first body) 'def-struct)))
             (mangled-name (when is-struct
                                 (crisp.compiler::mangle-template-struct-name name concrete-types))))

        (if is-struct
            ;; For Structs: Rename the struct to mangled name AND generate overload wrapper
            (let* ((substituted-body (sublis substitutions (subst mangled-name name body)))
                   ;; Extract members from SUBSTITUTED body: (def-struct MANGLED-NAME (mem concrete-type)...)
                   (members (cddr substituted-body))
                   (parsed-members (mapcar #'crisp.compiler::parse-struct-member-spec members))
                   (param-names (mapcar #'first parsed-members))
                   ;; Use a UNIQUE wrapper name to avoid LLVM collisions if multiple overloads are generated
                   ;; e.g. MAKE-POINT_FLOAT_WRAPPER
                   (wrapper-name (intern (format nil "MAKE-~a_WRAPPER" mangled-name) (symbol-package name)))
                   (constructor-alias (intern (format nil "MAKE-~a" name) (symbol-package name)))
                   (mangled-constructor (intern (format nil "MAKE-~a" mangled-name) (symbol-package name))))

              `(progn
                ,substituted-body
                ;; Generate overload wrapper with UNIQUE name: (def-function make-point_float_wrapper ...)
                (def-function ,wrapper-name ,parsed-members
                              (declare (return-type ,mangled-name))
                              (return (,mangled-constructor ,@param-names)))
                ;; Register this wrapper as an overload for the generic constructor name (e.g. MAKE-POINT)
                (eval-when (:compile-toplevel :load-toplevel :execute)
                  (crisp.compiler::register-overload ',constructor-alias ',wrapper-name))))

            ;; For Functions: Just substitute types
            `(progn ,(sublis substitutions body)))))))

(defun try-infer-template-types (name argument-types)
  "Attempts to infer template parameters for 'name' given 'argument-types'.
   Returns a LIST OF LISTS of (template-data concrete-types)."
  (let ((templates (gethash name *template-registry*)))
    (unless templates (return-from try-infer-template-types nil))

    (loop for tmpl in templates
          for raw-sig = (template-data-signature tmpl)
            ;; Unwrap (FUNCTION ...) if present
          for sig = (if (and (listp raw-sig) (eq (first raw-sig) 'FUNCTION))
                        (second raw-sig)
                        raw-sig)
          for params = (template-data-parameters tmpl) ; e.g. (T)
            ;; sig is now (T T => T).
          for sig-params = (when sig (butlast sig 2))

            ;; 1. Check arity match between args and signature params
            when (and sig-params (= (length sig-params) (length argument-types)))
            append (let ((inference-map (make-hash-table)))
                     (when (loop for sig-param in sig-params
                                 for arg-type in argument-types
                                   always (match-template-arg sig-param arg-type inference-map params))

                           ;; Ensure all template parameters were inferred
                           (let ((concrete-types (loop for p in params
                                                       collect (gethash p inference-map))))
                             (log:info "try-infer: concrete-types = ~a" concrete-types)
                             (if (every #'identity concrete-types)
                                 (list (list tmpl concrete-types)) ;; Return pair!
                                 nil)))))))

(defun ensure-template-instantiation (name explicit-arg-types compiler-callback)
  "Called by the compiler to auto-instantiate templates.
   compiler-callback is (lambda (form location) ...)"
  (let ((templates (gethash name *template-registry*))
        (match-sets nil))

    ;; 1. Try Function Signature Inference
    (setf match-sets (try-infer-template-types name explicit-arg-types))

    ;; 2. If no function match, checking for Struct/Direct Instantiation by Arity
    (unless match-sets
      (loop for tmpl in templates
            for params = (template-data-parameters tmpl)
            do (when (= (length params) (length explicit-arg-types))
                     ;; Direct match by arity (explicit args are the concrete types)
                     ;; This assumes explicit-arg-types are the TYPES, not values.
                     (push (list tmpl explicit-arg-types) match-sets))))

    (let ((did-work nil))
      (loop for (tmpl inferred-types) in match-sets do
              (let* ((key (cons (template-data-name tmpl) inferred-types))
                     (status (gethash key *instantiated-templates*))
                     (is-compiling (and (boundp 'crisp.compiler::*current-module*)
                                        crisp.compiler::*current-module*)))

                ;; Smart Cache Check:
                ;; - If :compiled, we are done.
                ;; - If :analyzed and we are in analysis pass (not compiling), done.
                ;; - If :analyzed and we ARE compiling, we must proceed to generate IR.
                ;; - If nil, proceed.
                (unless (or (eq status :compiled)
                            (and (eq status :analyzed) (not is-compiling)))

                  (log:info "Auto-specializing template ~a for types ~a (Status: ~a, Is-Compiling: ~a)" name inferred-types status is-compiling)
                  ;; 1. Instantiate the template using the SPECIFIC template object found
                  (let ((instantiated-code (instantiate-template tmpl inferred-types)))
                    ;; 2. Compile the instantiated code (it's a PROGN of DEF-FUNCTIONs)
                    (loop for form in (rest instantiated-code) ; skip 'progn
                          do (funcall compiler-callback form nil))

                    ;; Update status
                    (setf (gethash key *instantiated-templates*) (if is-compiling :compiled :analyzed))
                    (setf did-work t)))))
      did-work)))
