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

(defvar *partial-template-instantiations* (make-hash-table :test 'eq)
  "Maps template name symbols to lists of partial instantiation plists.
   Each plist has keys:
     :partial-mangled-name - symbol for the partial concrete type (e.g. FAKE-CELL_INT)
     :data-members         - ordered data-member specs (excluding brand forms)")


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
                           (defmacro ,(intern (format nil "GEN-~a" name) (or (symbol-package name) *package*)) (&rest args)
                             (let* ((arity ,(length params))
                                    (provided (length args)))
                               (if (= provided arity)
                                   `(template-instantiation ,(instantiate-template ',name args))
                                   (error "Template instantiation for ~a expects ~a type arguments, got ~a." ',name arity provided)))))

                        ;; Define the type helper macro: (NAME-type ...)
                        `(defmacro ,(intern (format nil "~a-TYPE" name) (or (symbol-package name) *package*)) (&rest concrete-types)
                           `(get-template-signature ',',name ',concrete-types))

                        `(eval-when (:compile-toplevel :load-toplevel :execute)
                           (export ',(intern (format nil "~a-TYPE" name) (or (symbol-package name) *package*)) (symbol-package ',name)))))))

                 ;; Case 2: def-kernel
                 ((and (listp form) (member (first form) '(def-kernel def-kernel-exact)))
                   (let ((name (second form)))
                     (list
                      `(eval-when (:compile-toplevel :load-toplevel :execute)
                         (register-template ',name ',params ',constraints ',form nil))

                      `(eval-when (:compile-toplevel :load-toplevel :execute)
                         (defmacro ,(intern (format nil "GEN-~a" name) (or (symbol-package name) *package*)) (&rest args)
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
                         (export ',(intern (format nil "GEN-~a" name) (or (symbol-package name) *package*)) (symbol-package ',name))))))

                 ;; Case 3: def-struct
                 ((and (listp form) (member (first form) '(def-struct def-record)))
                   (let* ((name (second form))
                          (members (cddr form))
                          ;; Parse (x type) (y type) -> (type type => name)
                          ;; Filter out (brand ...) forms
                          (data-members (remove-if (lambda (m) (and (consp m) (string-equal (symbol-name (car m)) "BRAND"))) members))
                          (member-types (mapcar #'second data-members))
                          (param-names (mapcar #'first data-members))
                          (signature `(function (,@member-types => ,name))))
                     (list
                      `(eval-when (:compile-toplevel :load-toplevel :execute)
                         (register-template ',name ',params ',constraints ',form ',signature))

                      ;; 1. Generate normal generic constructor GEN-POINT(T U)(x y) wrapper -> make-point_float_float
                      `(defmacro ,(intern (format nil "GEN-~a" name) (or (symbol-package name) *package*)) (&rest args)
                         (let* ((arity ,(length params))
                                (concrete-types (subseq args 0 arity))
                                (ctor-args (subseq args arity))
                                (ordered-ctor-args (crisp.compiler::reorder-template-args-from-keywords ctor-args ',param-names)))
                           (list* 'make-structure-template-instance
                             ',name
                             (list 'quote concrete-types)
                             ordered-ctor-args)))

                      ;; 2. Generate Type Helper GEN-POINT-TYPE(T U) => POINT_FLOAT_FLOAT
                      `(defmacro ,(intern (format nil "GEN-~a-TYPE" name) (or (symbol-package name) *package*)) (&rest concrete-types)
                         `(template-instantiation ,(instantiate-template ',name concrete-types)))

                      ;; 3. Generate generic constructor alias MAKE-POINT -> MAKE-POINT%DISPATCH
                      `(defmacro ,(intern (format nil "MAKE-~a" name) (or (symbol-package name) *package*)) (&rest args)
                         (let ((ordered (crisp.compiler::reorder-template-args-from-keywords args ',param-names)))
                           (cons ',(intern (format nil "MAKE-~a%DISPATCH" name) (or (symbol-package name) *package*)) ordered)))

                      `(eval-when (:compile-toplevel :load-toplevel :execute)
                         (export ',(intern (format nil "GEN-~a" name) (or (symbol-package name) *package*)) (symbol-package ',name)))

                      ;; Define the type helper macro: (NAME-type ...)
                      ;; For structs, this returns the Mangled Name.
                      `(defmacro ,(intern (format nil "~a-TYPE" name) (or (symbol-package name) *package*)) (&rest concrete-types)
                         (let ((mangled (intern (format nil "~a_~{~a~^_~}" ',name concrete-types) (or (symbol-package ',name) *package*))))
                           `',mangled))

                      `(eval-when (:compile-toplevel :load-toplevel :execute)
                         (export ',(intern (format nil "~a-TYPE" name) (or (symbol-package name) *package*)) (symbol-package ',name))))))

                 ;; Case 4: def-type
                 ((and (listp form) (eq (first form) 'def-type))
                   (let* ((raw-name (second form))
                          (name (if (consp raw-name) (first raw-name) raw-name))
                          (type-spec (third form)))
                     (list
                      `(eval-when (:compile-toplevel :load-toplevel :execute)
                         (setf (gethash ',name crisp.compiler::*crisp-template-aliases*)
                           (cons ',params ',type-spec)))))))))))



(defun strip-keyword-labels (type-list template-params)
  "Strips keyword LABEL pairs from a type specifier list, keeping keyword VALUES.
   A keyword is treated as a label (and stripped) only when the element following
   it is a template parameter.  Keyword values (concrete types like :global) are kept.
   e.g. (fake-cell T :address-space addr :access acc) with params (T addr acc)
        => (fake-cell T addr acc)
   But  (cell T :global :read-write) with params (T)
        => (cell T :global :read-write)  -- :global and :read-write are values, kept."
  (let ((result nil))
    (loop for (elem . rest) on type-list
          do (cond
              ;; Keyword followed by a template param = label. Skip the keyword.
              ;; The template param itself will be collected on the next iteration.
              ((and (keywordp elem)
                    rest
                    (member (car rest) template-params))
               nil)
              (t (push elem result))))
    (nreverse result)))

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
  "Recursively matches sig-type against arg-type, updating inference-map.
   FIX: Resolves type aliases (e.g., FC-INT -> (FAKE-CELL INT ...)) before matching
   list structures, so def-type aliases work with template inference."
  (let ((sig-type (normalize-template-sig-type raw-sig-type)))
    (cond
     ;; 1. Template Parameter (e.g. T)
     ((member sig-type template-params)
       (let ((existing (gethash sig-type inference-map)))
         (if existing
             (equal existing arg-type)
             (progn (setf (gethash sig-type inference-map) arg-type) t))))

     ;; 2. Match Function Literal against a Function Type Pattern
     ((and (listp sig-type) (eq (first sig-type) :function-type)
           (listp arg-type) (eq (first arg-type) :function-literal))
       (let* ((name (second arg-type))
              (signatures (gethash name *function-table*)))
         (loop for sig in signatures
                 when (match-function-signature sig-type sig inference-map template-params)
                 return t)))

     ;; 3. Generic List Pattern
     ((listp sig-type)
       (or
        ;; A. Dependent Type Match
        (and (symbolp (first sig-type)) (symbolp arg-type)
             (let ((sig-name (symbol-name (first sig-type)))
                   (arg-name (symbol-name arg-type)))
               (or (string-equal sig-name arg-name)
                   (and (> (length arg-name) (length sig-name))
                        (string-equal sig-name (subseq arg-name 0 (length sig-name)))
                        (cl:char= (cl:char arg-name (length sig-name)) #\-)))))

        ;; B. Standard recursive list match
        (match-list-structure sig-type arg-type inference-map template-params)
        ;; C. Unmangle struct names to lists for matching (e.g. CELL_FLOAT -> (CELL FLOAT ...))
        ;;    Strip keyword labels from sig-type since mangled names are purely positional.
        ;;    e.g. sig (fake-cell T :address-space addr :access acc) stripped to (fake-cell T addr acc)
        ;;         matches unmangled (FAKE-CELL INT GLOBAL READ-WRITE)
        (and (symbolp arg-type)
             (let ((unmangled (unmangle-template-struct-name arg-type)))
               (when unmangled
                     (let ((stripped (strip-keyword-labels sig-type template-params)))
                       (log:debug "match-template-arg unmangle path: sig=~s stripped=~s unmangled=~s"
                                  sig-type stripped unmangled)
                       (when (match-list-structure stripped unmangled inference-map template-params)
                         ;; Post-process: mangling loses keyword-ness (format "~a" :GLOBAL => "GLOBAL").
                         ;; For template params that were preceded by keyword labels in the original
                         ;; sig-type, convert the inferred plain symbol back to a keyword.
                         (loop for (elem . rest) on sig-type
                               when (and (keywordp elem) rest (member (car rest) template-params))
                               do (let* ((param (car rest))
                                         (val (gethash param inference-map)))
                                    (when (and val (symbolp val) (not (keywordp val)))
                                      (log:debug "keywordify inferred param ~s: ~s => :~a" param val (symbol-name val))
                                      (setf (gethash param inference-map)
                                            (intern (symbol-name val) :keyword)))))
                         t)))))

        ;; D. Resolve type aliases and try matching (use raw resolved form, not canonical,
        ;; to preserve keyword labels for element-by-element matching with sig-type)
        ;; e.g., FC-INT -> (FAKE-CELL INT :ADDRESS-SPACE :GLOBAL :ACCESS :READ-WRITE)
        (and (symbolp arg-type)
             (let ((resolved (resolve-type-alias arg-type)))
               (when (and resolved (not (eq resolved arg-type)) (listp resolved))
                     (log:debug "Template match: resolved alias ~a -> ~a" arg-type resolved)
                     (match-list-structure sig-type resolved inference-map template-params))))

        ;; E. Check for Template Aliases (e.g. (out-c T) -> (cell T ...))
        (let ((alias-def (and (symbolp (first sig-type))
                              (gethash (first sig-type) *crisp-template-aliases*))))
          (when alias-def
                (let* ((alias-params (car alias-def))
                       (alias-body (cdr alias-def))
                       (args (rest sig-type))
                       (arity (length alias-params))
                       (required-args (subseq args 0 (min (length args) arity)))
                       (rest-args (subseq args (length required-args)))
                       (substitutions (pairlis alias-params required-args))
                       (expanded-base (sublis substitutions alias-body))
                       (expanded-sig (if (and rest-args (consp expanded-base))
                                         (append expanded-base rest-args)
                                         expanded-base)))
                  (match-template-arg (canonicalize-type-specifier expanded-sig) arg-type inference-map template-params))))))

     ;; 4. Check for Symbol Alias (e.g. out-c)
     ((and (symbolp sig-type)
           (gethash sig-type *crisp-template-aliases*))
       (let* ((alias-def (gethash sig-type *crisp-template-aliases*))
              (alias-body (cdr alias-def)))
         (match-template-arg (canonicalize-type-specifier alias-body) arg-type inference-map template-params)))

     ;; 5. Concrete Type (int)
     (t (or (equal sig-type arg-type)
            (and (symbolp sig-type) (symbolp arg-type)
                 (string-equal (symbol-name sig-type) (symbol-name arg-type)))

            ;; Implicit Template Expansion: SERVER -> (SERVER T)
            (and (symbolp sig-type)
                 (gethash sig-type *template-registry*)
                 (let* ((tmpl (first (gethash sig-type *template-registry*)))
                        (params (mapcar (lambda (p) (if (consp p) (first p) p)) (template-data-parameters tmpl))))
                   (when params
                         (match-template-arg (cons sig-type params) arg-type inference-map template-params)))))))))


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
                           for cp-def in (function-signature-parameters concrete-sig)
                           for cp = (parameter-def-type cp-def)
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
                                ;; Arity check is fuzzy with defaults, so we pick the one with *enough* params?
                                ;; For backwards compat, exact match on PARAMS length is safest for overloading by arity.
                                (= (length (template-data-parameters t-data))
                                  (length concrete-types)))
                         templates)
                     ;; Fallback: If no exact arity match, pick the first one and let parameter parsing handle defaults/errors?
                     (or (first templates)
                         (error "No template registry entry for ~a" name-or-tmpl)))))
         (name (if tmpl (template-data-name tmpl) name-or-tmpl)))

    (unless tmpl
      (error "No template for ~a matches the provided type arguments: ~a" name concrete-types))

    ;; Instantiate with Parameters, Defaults, and Type Checking
    (let* ((raw-params (template-data-parameters tmpl))
           (parsed-params (mapcar #'crisp.compiler::parse-template-parameter-spec raw-params))
           (final-substitutions '()))

      ;; Validate Argument Count (Too many?)
      (when (> (length concrete-types) (length parsed-params))
            (error "Too many type arguments for template ~a. Expected max ~a, got ~a: ~a"
              name (length parsed-params) (length concrete-types) concrete-types))

      ;; Process Parameters
      (loop for (p-name p-type p-default) in parsed-params
            for i from 0
            for arg = (if (< i (length concrete-types))
                          (nth i concrete-types)
                          (if p-default
                              p-default
                              (error "Missing required type argument for template parameter ~a (index ~d)" p-name i)))
            do
              (log:debug "TEMPLATE CHECK: ~a arg=~a type=~a default=~a" p-name arg p-type p-default)
              (unless (eq p-type 'T)
                (log:debug "  Typep Result: ~a" (typep arg p-type)))

              (crisp.compiler::validate-template-arg arg p-type p-name)
              (push (cons p-name arg) final-substitutions))

      (setf final-substitutions (nreverse final-substitutions))

      ;; Augment substitutions with template aliases
      ;; (Fixed: Do not aggressively substitute aliases here. Let canonicalize-type-specifier handle them.)

      ;; Check if it's a struct template by inspecting the body
      (let* ((body (template-data-body tmpl))
             (is-struct (and (listp body) (member (first body) '(def-struct def-record)))))

        (if is-struct
            (%instantiate-structure-template name body final-substitutions concrete-types)
            (%instantiate-callable-template name body final-substitutions override-name))))))


(defun %instantiate-structure-template (name body substitutions concrete-types)
  "Instantiates a struct template with the given substitutions and concrete types.
   For incomplete templates (those with :c-t fields lacking a default value), stores
   partial instantiation info in *partial-template-instantiations* and installs a CL
   macro for MAKE-X%DISPATCH so dispatch can complete the type at call-site expansion.
   For complete templates, generates the wrapper def-function and registers the overload
   as before."
  (let* ((mangled-name       (mangle-template-struct-name name concrete-types))
         (substituted-body   (sublis substitutions (subst mangled-name name body)))
         (members            (cddr substituted-body))
         (data-members       (remove-if (lambda (m)
                                          (and (consp m)
                                               (string-equal (symbol-name (car m)) "BRAND")))
                                        members))
         (all-parsed-members (mapcar #'parse-struct-member-spec data-members))
         ;; Remove only INCOMPLETE :c-t fields (nil fourth) from the wrapper param list
         (parsed-members     (remove-if (lambda (m)
                                          (and (consp m) (eq (third m) :c-t) (not (fourth m))))
                                        all-parsed-members))
         (param-names        (mapcar #'first parsed-members))
         (wrapper-name       (intern (format nil "MAKE-~a_WRAPPER" mangled-name)
                                     (symbol-package name)))
         (constructor-alias  (intern (format nil "MAKE-~a%DISPATCH" name)
                                     (symbol-package name)))
         (mangled-constructor (intern (format nil "MAKE-~a" mangled-name)
                                      (symbol-package name)))
         (keyword-args       (loop for pname in param-names
                                   collect (intern (symbol-name pname) :keyword)
                                   collect pname))
         (incomplete-fields  (remove-if-not (lambda (m)
                                              (and (consp m) (eq (third m) :c-t) (null (fourth m))))
                                            all-parsed-members)))
    ;; Side-effect: for incomplete types, store partial info and install dispatch macro
    (when incomplete-fields
      (log:info "INSTANTIATE-STRUCT-TEMPLATE: ~a is incomplete (missing CT: ~a), storing partial"
                mangled-name (mapcar #'first incomplete-fields))
      (push (list :partial-mangled-name mangled-name
                  :data-members         data-members)
            (gethash name *partial-template-instantiations*))
      ;; Install MAKE-X%DISPATCH as a CL macro (once per template name)
      (unless (macro-function constructor-alias)
        (let ((tname name))
          (setf (macro-function constructor-alias)
                (lambda (whole-form env)
                  (declare (ignore env))
                  (%dispatch-incomplete-template tname (rest whole-form)))))))
    `(progn
       ,substituted-body
       ;; Wrapper + overload registration only for complete types
       ,@(unless incomplete-fields
           `((def-function ,wrapper-name ,parsed-members
                           (declare (return-type ,mangled-name))
                           (return (,mangled-constructor ,@keyword-args)))
             (eval-when (:compile-toplevel :load-toplevel :execute)
               (register-overload ',constructor-alias ',wrapper-name)))))))





(defun %dispatch-incomplete-template (template-name all-args)
  "Called at CL macro expansion time when MAKE-X%DISPATCH expands for an incomplete
   struct template. Maps positional args back to keyword args and calls the partial
   struct's constructor with all values (including the required incomplete CT ones).
   Returns a direct constructor call whose result type is the partial mangled type
   (e.g. FAKE-CELL_INT), preserving correct arity for template function resolution."
  (let* ((partials (gethash template-name *partial-template-instantiations*))
         (partial  (or (first partials)
                       (error "DISPATCH-INCOMPLETE: No partial instantiation for ~a" template-name)))
         (partial-mangled  (getf partial :partial-mangled-name))
         (data-members     (getf partial :data-members))
         ;; Constructor for the partial type (e.g. MAKE-FAKE-CELL_INT)
         (constructor-name (intern (format nil "MAKE-~a" partial-mangled)
                                   (symbol-package template-name)))
         ;; Map positional args back to keyword args using data-member names
         (keyword-call-args
           (loop for m in data-members
                 for i from 0
                 for member-name = (first m)
                 for kw = (intern (symbol-name member-name) :keyword)
                 when (< i (length all-args))
                 collect kw
                 and collect (nth i all-args))))
    (log:info "DISPATCH-INCOMPLETE: ~a -> ~a with keyword args ~a"
              template-name constructor-name keyword-call-args)
    `(,constructor-name ,@keyword-call-args)))

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

(defun %unwrap-function-signature (raw-sig)
  "Helper: Unwraps (FUNCTION ...) wrapper if present."
  (if (and (listp raw-sig) (eq (first raw-sig) 'FUNCTION))
      (second raw-sig)
      raw-sig))

(defun %infer-from-single-template (tmpl argument-types)
  "Helper: Attempts to infer template types for a single template.
   Returns NIL on failure, or (list template-data concrete-types) on success."
  (let* ((raw-sig (template-data-signature tmpl))
         (sig (%unwrap-function-signature raw-sig))
         (raw-params (template-data-parameters tmpl))
         (params (mapcar (lambda (p) (if (consp p) (first p) p)) raw-params))
         ;; sig is now (T T => T)
         (sig-params (when sig (butlast sig 2))))

    ;; Check arity match between args and signature params
    (when (and sig-params (= (length sig-params) (length argument-types)))
          (let ((inference-map (make-hash-table)))
            (when (loop for sig-param in sig-params
                        for arg-type in argument-types
                          always (match-template-arg sig-param arg-type inference-map params))

                  ;; Ensure all template parameters were inferred
                  (let ((concrete-types (loop for p in params
                                              collect (gethash p inference-map))))
                    (when (every #'identity concrete-types)
                          (list (list tmpl concrete-types))))))))) ; Return pair!

(defun try-infer-template-types (name argument-types)
  "Attempts to infer template parameters for 'name' given 'argument-types'.
   Returns a LIST OF LISTS of (template-data concrete-types)."
  (let ((templates (gethash name *template-registry*)))
    (unless templates (return-from try-infer-template-types nil))

    (loop for tmpl in templates
            append (or (%infer-from-single-template tmpl argument-types) '()))))

(defun %resolve-template-name (name)
  "Helper: Resolves constructor names (MAKE-POINT, MAKE-POINT%DISPATCH) to base struct names."
  (when (and (null (gethash name *template-registry*)) (symbolp name))
        (let ((s (symbol-name name)))
          (cond
           ((alexandria:starts-with-subseq "MAKE-" s)
             (if (alexandria:ends-with-subseq "%DISPATCH" s)
                 (intern (subseq s 5 (- (length s) 9)) (symbol-package name)) ;; MAKE-POINT%DISPATCH -> POINT
                 (intern (subseq s 5) (symbol-package name)))) ;; MAKE-POINT -> POINT
           (t nil)))))

(defun %should-instantiate-template (key status is-compiling)
  "Helper: Determines if a template should be instantiated based on cache status.
   Returns T if instantiation should proceed, NIL otherwise."
  (not (or (eq status :compiled)
           (and (eq status :analyzed) (not is-compiling)))))

(defun ensure-template-instantiation (name explicit-arg-types compiler-callback)
  "Called by the compiler to auto-instantiate templates.
   compiler-callback is (lambda (form location) ...)"
  (let* ((templates (gethash name *template-registry*))
         ;; If not found directly, try stripping "MAKE-" or "MAKE-...%DISPATCH" prefix for struct constructors
         (struct-name (%resolve-template-name name))
         (templates (or templates (when struct-name (gethash struct-name *template-registry*))))
         (match-sets nil))

    ;; 1. Try Function Signature Inference
    (setf match-sets (try-infer-template-types (or struct-name name) explicit-arg-types))

    ;; 2. If no function match, checking for Struct/Direct Instantiation by Arity
    (unless match-sets
      (loop for tmpl in templates
            for params = (template-data-parameters tmpl)
              ;; Relaxed check: Allow arguments >= parameters if the extras are properties (managed by mangle)
            do (when (= (length explicit-arg-types) (length params))
                     ;; Direct match/superset by arity (explicit args are the concrete types)
                     ;; This assumes explicit-arg-types are the TYPES, not values.
                     (push (list tmpl explicit-arg-types) match-sets))))

    (let ((did-work nil))
      (loop for (tmpl inferred-types) in match-sets do
              (let* ((key (cons (template-data-name tmpl) inferred-types))
                     (status (gethash key *instantiated-templates*))
                     (is-compiling (and (boundp 'crisp.compiler::*current-module*)
                                        crisp.compiler::*current-module*)))

                ;; Smart Cache Check: Only proceed if needed
                (when (%should-instantiate-template key status is-compiling)
                      (log:info "Auto-specializing template ~a for types ~a (Status: ~a, Is-Compiling: ~a)"
                                name inferred-types status is-compiling)

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
