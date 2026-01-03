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

(defmacro template-instantiation (form)
  "Identity macro to allow top-level template instantiation logic to be visible to the compiler
   walker (visit-toplevel-form), preventing 'undefined function' errors."
  form)


(defun reorder-template-args-from-keywords (args param-names)
  "Helper to convert keyword args to positional loop for template constructors."
  (if (keywordp (first args))
      (loop for name in param-names
            for key = (intern (symbol-name name) :keyword)
            collect (getf args key))
      args))

(defmacro with-template-type (params &body body)
  "Defines templates for the enclosed forms."
  ;; 1. Parse constraints from the body (if any)
  (let* ((declare-form (when (and (listp (first body)) (eq (first (first body)) 'declare))
                             (first body)))
         (real-body (if declare-form (rest body) body))
         (constraints (when declare-form (rest declare-form))))

    `(progn
      ,@(loop for form in real-body
                append
                (cond
                 ;; Case 1: def-function
                 ((and (listp form) (eq (first form) 'def-function))
                   (let ((name (second form))
                         (fn-body (cdddr form)))
                     ;; Extract signature from function body if present
                     (let* ((sig-decl (find-if (lambda (f) (and (listp f) (eq (car f) 'declare))) fn-body))
                            (signature (when sig-decl
                                             (let ((raw (second sig-decl))) ;; (return-type <type>) or (function <spec>)
                                               (cond
                                                ;; Case 1: (declare (return-type ...)) -> old style
                                                ((eq (first raw) 'return-type)
                                                  `(function (=> ,(second raw))))
                                                ;; Case 2: (declare (function ...)) or (declare #'...)
                                                ((member (first raw) '(function common-lisp:function))
                                                  ;; raw is (function (args... => ret))
                                                  ;; We need to clean the args list (remove &out, &key, names if mixed?)
                                                  ;; Assuming signature specs are types only or keywords.
                                                  (let* ((inner (second raw))
                                                         (arrow-pos (position '=> inner))
                                                         (args (subseq inner 0 (or arrow-pos (length inner))))
                                                         (clean-args (remove-if (lambda (x)
                                                                                  (and (symbolp x)
                                                                                       (member (symbol-name x) '("&OUT" "&KEY" "&OPTIONAL" "&REST") :test #'string-equal)))
                                                                         args))
                                                         (ret (when arrow-pos (nth (1+ arrow-pos) inner))))
                                                    `(function (,@clean-args => ,ret)))))))))
                       (list
                        `(eval-when (:compile-toplevel :load-toplevel :execute)
                           (register-template ',name ',params ',constraints ',form ',signature))

                        `(eval-when (:compile-toplevel :load-toplevel :execute)
                           (defmacro ,(intern (format nil "GEN-~a" name) (symbol-package name)) (&rest args)
                             (let* ((arity ,(length params))
                                    (provided (length args)))
                               (if (= provided arity)
                                   `(template-instantiation ,(instantiate-template ',name args))
                                   (error "Template instantiation for ~a expects ~a type arguments, got ~a." ',name arity provided)))))

                        ;; Define the type helper macro: (NAME-type ...)
                        `(defmacro ,(intern (format nil "~a-TYPE" name) (symbol-package name)) (&rest concrete-types)
                           `(get-template-signature ',',name ',concrete-types))

                        `(eval-when (:compile-toplevel :load-toplevel :execute)
                           (export ',(intern (format nil "~a-TYPE" name) (symbol-package name)) (symbol-package ',name)))))))

                 ;; Case 2: def-kernel
                 ((and (listp form) (member (first form) '(def-kernel def-kernel-exact)))
                   (let ((name (second form)))
                     (list
                      `(eval-when (:compile-toplevel :load-toplevel :execute)
                         (register-template ',name ',params ',constraints ',form nil))

                      `(eval-when (:compile-toplevel :load-toplevel :execute)
                         (defmacro ,(intern (format nil "GEN-~a" name) (symbol-package name)) (&rest args)
                           (let* ((arity ,(length params))
                                  (provided (length args)))
                             (cond
                              ((= provided arity)
                                `(template-instantiation ,(instantiate-template ',name args)))
                              ((= provided (1+ arity))
                                (let ((types (subseq args 0 arity))
                                      (override (nth arity args)))
                                  `(template-instantiation ,(instantiate-template ',name types override))))
                              (t
                                (error "Template instantiation for ~a expects ~a type arguments (plus optional name), got ~a." ',name arity provided))))))

                      `(eval-when (:compile-toplevel :load-toplevel :execute)
                         (export ',(intern (format nil "GEN-~a" name) (symbol-package name)) (symbol-package ',name))))))

                 ;; Case 3: def-struct
                 ((and (listp form) (member (first form) '(def-struct def-record)))
                   (let* ((name (second form))
                          (members (cddr form))
                          ;; Parse (x type) (y type) -> (type type => name)
                          (member-types (mapcar #'second members))
                          (param-names (mapcar #'first members))
                          (signature `(function (,@member-types => ,name))))
                     (list
                      `(eval-when (:compile-toplevel :load-toplevel :execute)
                         (register-template ',name ',params ',constraints ',form ',signature))

                      ;; 1. Generate normal generic constructor GEN-POINT(T U)(x y) wrapper -> make-point_float_float
                      `(defmacro ,(intern (format nil "GEN-~a" name) (symbol-package name)) (&rest args)
                         (let* ((arity ,(length params))
                                (concrete-types (subseq args 0 arity))
                                (ctor-args (subseq args arity))
                                (ordered-ctor-args (crisp.compiler::reorder-template-args-from-keywords ctor-args ',param-names)))
                           (list* 'make-structure-template-instance
                             ',name
                             (list 'quote concrete-types)
                             ordered-ctor-args)))

                      ;; 2. Generate Type Helper GEN-POINT-TYPE(T U) => POINT_FLOAT_FLOAT
                      `(defmacro ,(intern (format nil "GEN-~a-TYPE" name) (symbol-package name)) (&rest concrete-types)
                         `(template-instantiation ,(instantiate-template ',name concrete-types)))

                      ;; 3. Generate generic constructor alias MAKE-POINT -> MAKE-POINT%DISPATCH
                      `(defmacro ,(intern (format nil "MAKE-~a" name) (symbol-package name)) (&rest args)
                         (let ((ordered (crisp.compiler::reorder-template-args-from-keywords args ',param-names)))
                           (cons ',(intern (format nil "MAKE-~a%DISPATCH" name) (symbol-package name)) ordered)))

                      `(eval-when (:compile-toplevel :load-toplevel :execute)
                         (export ',(intern (format nil "GEN-~a" name) (symbol-package name)) (symbol-package ',name)))

                      ;; Define the type helper macro: (NAME-type ...)
                      ;; For structs, this returns the Mangled Name.
                      `(defmacro ,(intern (format nil "~a-TYPE" name) (symbol-package name)) (&rest concrete-types)
                         (let ((mangled (intern (format nil "~a_~{~a~^_~}" ',name concrete-types) (symbol-package ',name))))
                           `',mangled))

                      `(eval-when (:compile-toplevel :load-toplevel :execute)
                         (export ',(intern (format nil "~a-TYPE" name) (symbol-package name)) (symbol-package ',name))))))

                 ;; Case 4: def-type
                 ((and (listp form) (eq (first form) 'def-type))
                   (let* ((raw-name (second form))
                          (name (if (consp raw-name) (first raw-name) raw-name))
                          (type-spec (third form)))
                     (list
                      `(eval-when (:compile-toplevel :load-toplevel :execute)
                         (setf (gethash ',name crisp.compiler::*crisp-template-aliases*)
                           (cons ',params ',type-spec)))))))))))

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

     ;; 3. Generic List Pattern - Handles (vector T) AND (:function-type ...)
     ((listp sig-type)
       (or (match-list-structure sig-type arg-type inference-map template-params)
           ;; Unmangle struct names to lists for matching (e.g. CELL_FLOAT -> (CELL FLOAT ...))
           (and (symbolp arg-type)
                (let ((unmangled (crisp.compiler::unmangle-template-struct-name arg-type)))
                  (when unmangled
                        (match-list-structure sig-type unmangled inference-map template-params))))
           ;; Check for Template Aliases (e.g. (out-c T) -> (cell T ...))
           (let ((alias-def (and (symbolp (first sig-type))
                                 (gethash (first sig-type) crisp.compiler::*crisp-template-aliases*))))
             (when alias-def
                   (let* ((alias-params (car alias-def))
                          (alias-body (cdr alias-def))
                          (args (rest sig-type))
                          (arity (length alias-params))
                          (required-args (subseq args 0 (min (length args) arity)))
                          (rest-args (subseq args (length required-args)))
                          (substitutions (pairlis alias-params required-args))
                          (expanded-base (sublis substitutions alias-body))
                          ;; If base expanded to a list, we append the rest args
                          (expanded-sig (if (and rest-args (consp expanded-base))
                                            (append expanded-base rest-args)
                                            expanded-base)))
                     (match-template-arg (crisp.compiler::canonicalize-type-specifier expanded-sig) arg-type inference-map template-params))))))

     ;; NEW: Check for Symbol Alias (e.g. out-c)
     ((and (symbolp sig-type)
           (gethash sig-type crisp.compiler::*crisp-template-aliases*))
       (let* ((alias-def (gethash sig-type crisp.compiler::*crisp-template-aliases*))
              (alias-body (cdr alias-def)))
         (match-template-arg (crisp.compiler::canonicalize-type-specifier alias-body) arg-type inference-map template-params)))

     ;; 4. Concrete Type (int)
     (t (or (equal sig-type arg-type)
            (and (symbolp sig-type) (symbolp arg-type)
                 (string-equal (symbol-name sig-type) (symbol-name arg-type))))))))

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
  (clrhash *instantiated-templates*) ;; Reset cache
  (clrhash *template-registry*) ;; Reset registry
  (setf crisp.compiler::*template-instantiator-fn* #'ensure-template-instantiation)
  (setf crisp.compiler::*template-arity-lookup-fn*
    (lambda (name)
      (let ((tmpls (gethash name *template-registry*)))
        (unless tmpls
          ;; Robust lookup: try to find by string name in registry keys
          (maphash (lambda (k v)
                     (when (string-equal (symbol-name k) (symbol-name name))
                           (setf tmpls v)))
                   *template-registry*))
        (when tmpls
              (length (template-data-parameters (first tmpls)))))))
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

(defun instantiate-template (name-or-tmpl concrete-types &optional override-name)
  "Generates the specialized code for a template. 
   name-or-tmpl can be a symbol (name) or a template-data struct.
   override-name: If provided (string or symbol), renames the generated function/kernel."
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
    (let* ((raw-params (template-data-parameters tmpl))
           (params (mapcar (lambda (p) (if (consp p) (first p) p)) raw-params))
           (arity (length params))
           (substitution-args (subseq concrete-types 0 (min (length concrete-types) arity)))
           (substitutions (pairlis params substitution-args)))

      ;; Augment substitutions with template aliases
      ;; (Fixed: Do not aggressively substitute aliases here. Let canonicalize-type-specifier handle them.)

      ;; Check if it's a struct template by inspecting the body
      (let* ((body (template-data-body tmpl))
             (is-struct (and (listp body) (member (first body) '(def-struct def-record)))))

        (if is-struct
            (%instantiate-structure-template name body substitutions concrete-types)
            (%instantiate-callable-template name body substitutions override-name))))))

(defun %instantiate-structure-template (name body substitutions concrete-types)
  (let* ((mangled-name (crisp.compiler::mangle-template-struct-name name concrete-types))
         (substituted-body (sublis substitutions (subst mangled-name name body)))
         ;; Extract members from SUBSTITUTED body: (def-struct MANGLED-NAME (mem concrete-type)...)
         (members (cddr substituted-body))
         (all-parsed-members (mapcar #'crisp.compiler::parse-struct-member-spec members))
         ;; Filter out compile-time members for the generated wrapper signature
         (parsed-members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) all-parsed-members))
         (param-names (mapcar #'first parsed-members))
         ;; Use a UNIQUE wrapper name to avoid LLVM collisions if multiple overloads are generated
         (wrapper-name (intern (format nil "MAKE-~a_WRAPPER" mangled-name) (symbol-package name)))
         (constructor-alias (intern (format nil "MAKE-~a%DISPATCH" name) (symbol-package name)))
         (mangled-constructor (intern (format nil "MAKE-~a" mangled-name) (symbol-package name)))
         (keyword-args (loop for name in param-names
                             collect (intern (symbol-name name) :keyword)
                             collect name))
         ;; Check for incomplete :c-t fields (no default value)
         (incomplete-fields (remove-if-not (lambda (m) (and (consp m) (eq (third m) :c-t) (null (fourth m)))) all-parsed-members)))
    `(progn
      ,substituted-body
      ;; Only generate runtime wrapper if all :c-t fields have defaults.
      ;; If there are missing :c-t values, this type cannot be constructed via a runtime function.
      ,@(unless incomplete-fields
          `((def-function ,wrapper-name ,parsed-members
                          (declare (return-type ,mangled-name))
                          (return (,mangled-constructor ,@keyword-args)))))

      ;; Register this wrapper as an overload (only if we generated it)
      ,@(unless incomplete-fields
          `((eval-when (:compile-toplevel :load-toplevel :execute)
              (crisp.compiler::register-overload ',constructor-alias ',wrapper-name)))))))

(defun %instantiate-callable-template (name body substitutions override-name)
  (let ((substituted-body (sublis substitutions body)))
    (if override-name
        (let ((new-name (if (stringp override-name) (intern override-name (symbol-package name)) override-name)))
          (if (and (consp substituted-body)
                   (member (first substituted-body) '(def-function def-kernel def-kernel-exact)))
              ;; Swap the name: (def-X OLD-NAME ...) -> (def-X NEW-NAME ...)
              `(progn ,(cons (first substituted-body) (cons new-name (cddr substituted-body))))
              ;; Fallback if body structure is unexpected
              `(progn ,substituted-body)))
        `(progn ,substituted-body))))

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
          for raw-params = (template-data-parameters tmpl)
          for params = (mapcar (lambda (p) (if (consp p) (first p) p)) raw-params)
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
                             (if (every #'identity concrete-types)
                                 (list (list tmpl concrete-types)) ;; Return pair!
                                 nil)))))))

(defun ensure-template-instantiation (name explicit-arg-types compiler-callback)
  "Called by the compiler to auto-instantiate templates.
   compiler-callback is (lambda (form location) ...)"
  (let* ((templates (gethash name *template-registry*))
         ;; If not found directly, try stripping "MAKE-" or "MAKE-...%DISPATCH" prefix for struct constructors
         (struct-name (when (and (null templates) (symbolp name))
                            (let ((s (symbol-name name)))
                              (cond
                               ((alexandria:starts-with-subseq "MAKE-" s)
                                 (if (alexandria:ends-with-subseq "%DISPATCH" s)
                                     (intern (subseq s 5 (- (length s) 9)) (symbol-package name)) ;; MAKE-POINT%DISPATCH -> POINT
                                     (intern (subseq s 5) (symbol-package name)))) ;; MAKE-POINT -> POINT
                               (t nil)))))
         (templates (or templates (when struct-name (gethash struct-name *template-registry*))))
         (match-sets nil))

    ;; 1. Try Function Signature Inference
    (setf match-sets (try-infer-template-types (or struct-name name) explicit-arg-types))

    ;; 2. If no function match, checking for Struct/Direct Instantiation by Arity
    (unless match-sets
      (loop for tmpl in templates
            for params = (template-data-parameters tmpl)
              ;; Relaxed check: Allow arguments > parameters if the extras are properties (managed by mangle)
            do (when (>= (length explicit-arg-types) (length params))
                     ;; Direct match/superset by arity (explicit args are the concrete types)
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

(defmacro make-structure-template-instance (template-name concrete-types &rest ctor-args)
  "Instantiates the struct template ensuring definitions exist, then calls the constructor."
  (let* ((template-name (if (and (consp template-name) (eq (first template-name) 'quote)) (second template-name) template-name))
         (concrete-types (if (and (consp concrete-types) (eq (first concrete-types) 'quote)) (second concrete-types) concrete-types))
         (mangled-name (crisp.compiler::mangle-template-struct-name template-name concrete-types))
         ;; Use the generated wrapper from instantiate-template logic
         (wrapper-name (intern (format nil "MAKE-~a_WRAPPER" mangled-name) (symbol-package template-name))))

    ;; Side-effect: Ensure template is instantiated (compiled) immediately
    (ensure-template-instantiation template-name concrete-types
                                   (lambda (form location)
                                     (if (and (boundp 'crisp.compiler::*current-module*) crisp.compiler::*current-module*)
                                         ;; If we are in the compiler (Pass 2), compile it now.
                                         (crisp.compiler::compile-toplevel-form form location
                                                                                crisp.compiler::*current-module*
                                                                                crisp.compiler::*current-builder*
                                                                                crisp.compiler::*current-di-builder*
                                                                                crisp.compiler::*current-di-compile-unit*
                                                                                crisp.compiler::*current-location-map*)
                                         ;; Fallback: Eval it (e.g. top-level macro expansion analysis)
                                         (eval form))))

    ;; Return just the call to the wrapper IF args provided, else nil
    (if ctor-args
        `(,wrapper-name ,@ctor-args)
        nil)))
