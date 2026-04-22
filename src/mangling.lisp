;;; src/mangling.lisp
(in-package :crisp.compiler)

;;; =========================================================
;;; Centralized Name Mangling & Type Naming Logic
;;; =========================================================



(defvar *template-arity-lookup-fn* nil
        "A hook for looking up the arity of a template by name (symbol or string).
   Should be set by the templates module. Returns integer or nil.")

(defun split-string (string delimiter)
  "Splits a string by a character delimiter."
  (loop for i = 0 then (1+ j)
          as j = (position delimiter string :start i)
        collect (subseq string i j)
        while j))

(defun mangle-template-struct-name (name params)
  "Generates the mangled name for a struct template instance. e.g. POINT (FLOAT) -> POINT_FLOAT"
  (log:debug "mangle-template-struct-name: name=~s (type=~a) params=~s" name (type-of name) params)
  (unless name (return-from mangle-template-struct-name nil))
  (let ((mangled-params (mapcar (lambda (p)
                                     (if (consp p)
                                         (mangle-template-struct-name (first p) (rest p))
                                         p))
                               params)))
    (if mangled-params
        (common-lisp:let* ((pkg (common-lisp:symbol-package name))
                           (pkg-name (common-lisp:package-name pkg)))
          ;; Avoid interning in locked packages (CL, KEYWORD) by name string
          (common-lisp:if (common-lisp:or (common-lisp:string= pkg-name "COMMON-LISP")
                            (common-lisp:string= pkg-name "KEYWORD"))
                          (common-lisp:intern (common-lisp:format nil "~a_~{~a~^_~}" name mangled-params) *package*)
                          (common-lisp:intern (common-lisp:format nil "~a_~{~a~^_~}" name mangled-params) pkg)))
        name)))

;;; The Helper Functions for Unmangling (from types.lisp)

(defun reconstruct-one-arg (tokens package)
  "Reads exactly one logical form (atom or template-expr) from tokens."
  (if (null tokens) (values nil nil)
      (let* ((token-str (first tokens))
                (token-sym (if (char= (cl:char token-str 0) #\:)
                               (intern (subseq token-str 1) :keyword)
                               (let ((existing (find-symbol token-str package)))
                                 (if existing existing (intern token-str package)))))
                (arity (and *template-arity-lookup-fn*
                            (funcall *template-arity-lookup-fn* token-sym))))

        (if (and arity (> arity 0))
            (multiple-value-bind (args remaining)
                (reconstruct-n-args (rest tokens) arity package)
              (values (list (cons token-sym args)) remaining))
            (values (list token-sym) (rest tokens))))))

(defun reconstruct-n-args (tokens n package)
  "Consumes N arguments from tokens."
  (if (or (<= n 0) (null tokens))
      (values nil tokens)
      ;; We need to reconstruct one argument (which might itself be a template tree)
      ;; But our reconstruct-template-args returns a LIST of args.
      ;; We want effective 'read' behavior: read one form.
      ;; The greedy approach in reconstruct-template-args reads ALL remaining.
      ;; We need a variant that reads ONE form.
      (multiple-value-bind (one-arg-list remaining-after-one)
          (reconstruct-one-arg tokens package)
        (multiple-value-bind (rest-args remaining-after-rest)
            (reconstruct-n-args remaining-after-one (1- n) package)
          (values (cons (first one-arg-list) rest-args) remaining-after-rest)))))



(defun reconstruct-template-args (tokens package)
  "Recursively groups tokens into lists based on template arity.
   tokens: list of strings.
   package: the fallback package for interning.
   Returns: (values property-list remaining-tokens)
   FIX: numeric token strings are parsed as integers before interning as symbols."
  (if (null tokens)
      (values nil nil)
      (let* ((token-str (first tokens))
                ;; Handle keywords specially
                (token-sym (if (char= (cl:char token-str 0) #\:)
                               (intern (subseq token-str 1) :keyword)
                               ;; Try parse as integer first, then find/intern as symbol
                               (multiple-value-bind (n end)
                                   (parse-integer token-str :junk-allowed t)
                                 (if (and n (= end (length token-str)))
                                        n  ; it's a numeric token — return the integer
                                        (let ((existing (find-symbol token-str package)))
                                          (if existing existing
                                                 (intern token-str package)))))))
                (arity (and (not (integerp token-sym))
                               *template-arity-lookup-fn*
                               (funcall *template-arity-lookup-fn* token-sym))))

        (if (and arity (> arity 0))
            ;; It's a template! Consume 'arity' args.
            (multiple-value-bind (args remaining)
                (reconstruct-n-args (rest tokens) arity package)
              (multiple-value-bind (rest-processed rest-remaining)
                  (reconstruct-template-args remaining package)
                (values (cons (cons token-sym args) rest-processed) rest-remaining)))

            ;; Not a template (or arity 0), treat as atom
            (multiple-value-bind (rest-processed rest-remaining)
                (reconstruct-template-args (rest tokens) package)
              (values (cons token-sym rest-processed) rest-remaining))))))

(defun unmangle-template-struct-name (symbol)
  "Attempts to reverse mangling for known parameterized types like CELL.
   Returns the list form (e.g. (CELL FLOAT :GLOBAL :READ-WRITE)) or NIL.
   Returns NIL immediately for uninterned symbols (gensyms produced by
   brand instance differentiation) since they cannot be mangled struct names."
  (when (symbolp symbol)
    ;; Uninterned gensyms (brand instance types like #:TOKEN-T-204) have no
    ;; package and can never be a mangled struct name.  Return NIL early to
    ;; avoid the (intern name NIL) crash that follows.
    (unless (symbol-package symbol)
      (return-from unmangle-template-struct-name nil))
    (let ((name (symbol-name symbol)))
      (if (find #\_ name)
          (let* ((parts (split-string name #\_))
                    (base (first parts))
                    (reconstructed (reconstruct-template-args (rest parts) (symbol-package symbol))))
            (if base
                (let ((base-sym (intern base (symbol-package symbol))))
                  `(,base-sym ,@reconstructed))
                nil))
          ;; No underscore: symbol is a bare type name (e.g. SHIRT -> (SHIRT))
          `(,(intern name (symbol-package symbol)))))))

;;; From src/environment.lisp
;;; =========================

(defun mangle-param-type-name (type)
  "Helper to mangle a type specifier for function names."
  (cond
   ((symbolp type) (string-downcase (symbol-name type)))
   ((and (listp type) (eq (first type) 'keyword) (= (length type) 2))
     (format nil "key_~a" (string-downcase (symbol-name (second type)))))
   ((listp type) (format nil "~{~a~^_~}" (mapcar #'mangle-param-type-name type)))
   (t "unknown")))

(defun mangle-function-variant-name (base-name param-types)
  (let ((suffix (mapcar #'mangle-param-type-name param-types)))
    (intern (format nil "~a_~{~a~^_~}" base-name suffix) (symbol-package base-name))))



(defun mangle-type-spec (type-spec)
  "Creates a string representation of a type spec for name mangling.
   Extended to handle integers (e.g. tensor arity N in canonical list form)."
  (log:debug "mangle-type-spec: ~s (type-of: ~a)" type-spec (type-of type-spec))
  (cond
   ((symbolp  type-spec) (string-downcase (symbol-name type-spec)))
   ((integerp type-spec) (format nil "~a" type-spec))
   ((listp    type-spec) (format nil "~{~a~^_~}" (mapcar #'mangle-type-spec type-spec)))
   (t (error "Cannot mangle unknown type specifier: ~a" type-spec))))
