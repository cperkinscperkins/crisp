;;; src/mangling.lisp
(in-package :crisp.compiler)

;;; =========================================================
;;; Centralized Name Mangling & Type Naming Logic
;;; =========================================================



(cl:defvar *template-arity-lookup-fn* nil
        "A hook for looking up the arity of a template by name (symbol or string).
   Should be set by the templates module. Returns integer or nil.")

(cl:defun split-string (string delimiter)
  "Splits a string by a character delimiter."
  (cl:loop for i = 0 then (1+ j)
          as j = (cl:position delimiter string :start i)
        collect (cl:subseq string i j)
        while j))

(cl:defun mangle-template-struct-name (name params)
  "Generates the mangled name for a struct template instance. e.g. POINT (FLOAT) -> POINT_FLOAT"
  (log:debug "mangle-template-struct-name: name=~s (type=~a) params=~s" name (cl:type-of name) params)
  (cl:unless name (cl:return-from mangle-template-struct-name nil))
  (cl:let ((mangled-params (cl:mapcar (lambda (p)
                                     (cl:if (cl:consp p)
                                         (mangle-template-struct-name (cl:first p) (cl:rest p))
                                         p))
                               params)))
    (cl:if mangled-params
        (common-lisp:let* ((pkg (common-lisp:symbol-package name))
                           (pkg-name (common-lisp:package-name pkg)))
          ;; Avoid interning in locked packages (CL, KEYWORD) by name string
          (common-lisp:if (common-lisp:or (common-lisp:string= pkg-name "COMMON-LISP")
                            (common-lisp:string= pkg-name "KEYWORD"))
                          (common-lisp:intern (common-lisp:format nil "~a_~{~a~^_~}" name mangled-params) *package*)
                          (common-lisp:intern (common-lisp:format nil "~a_~{~a~^_~}" name mangled-params) pkg)))
        name)))

;;; The Helper Functions for Unmangling (from types.lisp)

(cl:defun reconstruct-one-arg (tokens package)
  "Reads exactly one logical form (atom or template-expr) from tokens."
  (cl:if (cl:null tokens) (cl:values nil nil)
      (cl:let* ((token-str (cl:first tokens))
                (token-sym (cl:if (cl:char= (cl:char token-str 0) #\:)
                               (cl:intern (cl:subseq token-str 1) :keyword)
                               (cl:let ((existing (cl:find-symbol token-str package)))
                                 (cl:if existing existing (cl:intern token-str package)))))
                (arity (cl:and *template-arity-lookup-fn*
                            (cl:funcall *template-arity-lookup-fn* token-sym))))

        (cl:if (cl:and arity (cl:> arity 0))
            (cl:multiple-value-bind (args remaining)
                (reconstruct-n-args (cl:rest tokens) arity package)
              (cl:values (cl:list (cl:cons token-sym args)) remaining))
            (cl:values (cl:list token-sym) (cl:rest tokens))))))

(cl:defun reconstruct-n-args (tokens n package)
  "Consumes N arguments from tokens."
  (cl:if (cl:or (cl:<= n 0) (cl:null tokens))
      (cl:values nil tokens)
      ;; We need to reconstruct one argument (which might itself be a template tree)
      ;; But our reconstruct-template-args returns a LIST of args.
      ;; We want effective 'read' behavior: read one form.
      ;; The greedy approach in reconstruct-template-args reads ALL remaining.
      ;; We need a variant that reads ONE form.
      (cl:multiple-value-bind (one-arg-list remaining-after-one)
          (reconstruct-one-arg tokens package)
        (cl:multiple-value-bind (rest-args remaining-after-rest)
            (reconstruct-n-args remaining-after-one (1- n) package)
          (cl:values (cl:cons (cl:first one-arg-list) rest-args) remaining-after-rest)))))



(cl:defun reconstruct-template-args (tokens package)
  "Recursively groups tokens into lists based on template arity.
   tokens: list of strings.
   package: the fallback package for interning.
   Returns: (values property-list remaining-tokens)
   FIX: numeric token strings are parsed as integers before interning as symbols."
  (cl:if (cl:null tokens)
      (cl:values nil nil)
      (cl:let* ((token-str (cl:first tokens))
                ;; Handle keywords specially
                (token-sym (cl:if (cl:char= (cl:char token-str 0) #\:)
                               (cl:intern (cl:subseq token-str 1) :keyword)
                               ;; Try parse as integer first, then find/intern as symbol
                               (cl:multiple-value-bind (n end)
                                   (cl:parse-integer token-str :junk-allowed t)
                                 (cl:if (cl:and n (cl:= end (cl:length token-str)))
                                        n  ; it's a numeric token — return the integer
                                        (cl:let ((existing (cl:find-symbol token-str package)))
                                          (cl:if existing existing
                                                 (cl:intern token-str package)))))))
                (arity (cl:and (cl:not (cl:integerp token-sym))
                               *template-arity-lookup-fn*
                               (cl:funcall *template-arity-lookup-fn* token-sym))))

        (cl:if (cl:and arity (cl:> arity 0))
            ;; It's a template! Consume 'arity' args.
            (cl:multiple-value-bind (args remaining)
                (reconstruct-n-args (cl:rest tokens) arity package)
              (cl:multiple-value-bind (rest-processed rest-remaining)
                  (reconstruct-template-args remaining package)
                (cl:values (cl:cons (cl:cons token-sym args) rest-processed) rest-remaining)))

            ;; Not a template (or arity 0), treat as atom
            (cl:multiple-value-bind (rest-processed rest-remaining)
                (reconstruct-template-args (cl:rest tokens) package)
              (cl:values (cl:cons token-sym rest-processed) rest-remaining))))))

(cl:defun unmangle-template-struct-name (symbol)
  "Attempts to reverse mangling for known parameterized types like CELL.
   Returns the list form (e.g. (CELL FLOAT :GLOBAL :READ-WRITE)) or NIL.
   Returns NIL immediately for uninterned symbols (gensyms produced by
   brand instance differentiation) since they cannot be mangled struct names."
  (cl:when (cl:symbolp symbol)
    ;; Uninterned gensyms (brand instance types like #:TOKEN-T-204) have no
    ;; package and can never be a mangled struct name.  Return NIL early to
    ;; avoid the (intern name NIL) crash that follows.
    (cl:unless (cl:symbol-package symbol)
      (cl:return-from unmangle-template-struct-name nil))
    (cl:let ((name (cl:symbol-name symbol)))
      (cl:if (cl:find #\_ name)
          (cl:let* ((parts (split-string name #\_))
                    (base (cl:first parts))
                    (reconstructed (reconstruct-template-args (cl:rest parts) (cl:symbol-package symbol))))
            (cl:if base
                (cl:let ((base-sym (cl:intern base (cl:symbol-package symbol))))
                  `(,base-sym ,@reconstructed))
                nil))
          ;; No underscore: symbol is a bare type name (e.g. SHIRT -> (SHIRT))
          `(,(cl:intern name (cl:symbol-package symbol)))))))

;;; From src/environment.lisp
;;; =========================

(cl:defun mangle-param-type-name (type)
  "Helper to mangle a type specifier for function names."
  (cl:cond
   ((cl:symbolp type) (cl:string-downcase (cl:symbol-name type)))
   ((cl:and (cl:listp type) (cl:eq (cl:first type) 'keyword) (cl:= (cl:length type) 2))
     (cl:format nil "key_~a" (cl:string-downcase (cl:symbol-name (cl:second type)))))
   ((cl:listp type) (cl:format nil "~{~a~^_~}" (cl:mapcar #'mangle-param-type-name type)))
   (cl:t "unknown")))

(cl:defun mangle-function-variant-name (base-name param-types)
  (cl:let ((suffix (cl:mapcar #'mangle-param-type-name param-types)))
    (cl:intern (cl:format nil "~a_~{~a~^_~}" base-name suffix) (cl:symbol-package base-name))))

;;; From src/codegen.lisp
;;; =====================

(cl:defun mangle-type-spec (type-spec)
  "Creates a string representation of a type spec for name mangling."
  (log:debug "mangle-type-spec: ~s (type-of: ~a)" type-spec (cl:type-of type-spec))
  (cl:cond
   ((cl:symbolp type-spec) (cl:string-downcase (cl:symbol-name type-spec)))
   ((cl:listp type-spec) (cl:format nil "~{~a~^_~}" (cl:mapcar #'mangle-type-spec type-spec)))
   (cl:t (cl:error "Cannot mangle unknown type specifier: ~a" type-spec))))
