;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; =========================================================
;;; Branded Types - Infrastructure (Test 01)
;;; =========================================================

;; src/types/registry.lisp
(defvar *brand-definitions* (make-hash-table :test 'equal)
        "Maps (brand-name . struct-type) to brand-definition records.
   Populated when def-struct / def-record with brand declarations are processed.")

;; NEW struct to hold brand metadata (this is a CL struct, not a Crisp def-struct)
(cl:defstruct brand-definition
  "Stores the definition of a branded type declared inside a struct/record."
  (brand-name nil :type symbol) ; e.g., TOKEN-T
  (base-type nil :type symbol) ; e.g., ULONG
  (subst-mode nil :type symbol) ; :no, :equal, :descendant, :ancestor
  (enforce-mode :diff :type symbol) ; :always or :diff
  (owner-struct nil :type symbol)) ; e.g., SERVER

;;; =========================================================
;;; --differentiate flag support (branded types prerequisite)
;;; =========================================================

;; src/types/registry.lisp
(defvar *differentiate-p* nil
        "If T, enable differentiation mode. Activates branded type enforcement
   for brands declared with :enforce :diff (the default).")

;; src/compiler.lisp
(defun initialize-compiler (&key (log-level :info) (runtime-checks nil) (differentiate nil))
  "A master initialization function for the Crisp compiler.
This should be called by any entry point into the system (REPL, executable, CI)."

  (setf *runtime-checks-enabled* runtime-checks)
  (setf *differentiate-p* differentiate)
  ;; Load the LLVM shared library.
  (cffi:use-foreign-library crisp.llvm-bindings::libllvm)

  ;; Configure the logging system to use stderr (important for stdout IR capture)
  (if (eq log-level :off)
      (log:config :off)
      (log:config :sane :stream *error-output* log-level))

  ;; Initialize the compiler's internal state.
  (initialize-crisp-types)
  (initialize-crisp-types)
  (initialize-type-hierarchy) ;; Initialize type derivation graph (DAG)
  (clrhash *function-table*) ;; Reset function table
  (clrhash *crisp-structs*) ;; Reset struct definitions
  (clrhash *crisp-type-aliases*) ;; Reset type aliases
  (clrhash *crisp-template-aliases*) ;; Reset template aliases
  (clrhash *generic-functions*) ;; Reset generic functions
  (clrhash *kernel-declared-signatures*) ;; Reset kernel signatures
  (when (boundp '*record-definitions*) (clrhash *record-definitions*)) ;; Reset records (if defined)

  (setf *compiled-kernels* nil) ;; Reset compiled kernels list

  (initialize-expression-analyzers) ;; In analysis.lisp, but usually registered.
  ;; Note: analysis.lisp initializes *expression-analyzers* entries via def-expression-analyzer.
  ;; Wait, where is initialize-expression-analyzers defined?
  ;; It is usually in analysis.lisp.
  (clrhash *implicit-arg-map*)
  (initialize-advisements)

  ;; Register intrinsic `die`
  (setf (gethash 'die *function-table*)
    (list (make-function-signature :name 'die :parameters nil :return-types '(nil))))

  ;; Bind shadowed symbols to their CL equivalents so they work in macros
  (setf (symbol-function 'truncate) #'cl:truncate)
  (setf (symbol-function 'floor) #'cl:floor)
  (setf (symbol-function 'ceil) #'cl:ceiling)
  (setf (symbol-function 'round) #'cl:round)

  ;; Auto-initialize templates if available (runtime check)
  (if (fboundp 'initialize-templates)
      (funcall 'initialize-templates)
      (log:warn "Template system not loaded/initialized."))

  ;; Reset brand definitions
  (when (boundp '*brand-definitions*) (clrhash *brand-definitions*))

  ;; Initialize built-in structs (storage)
  (register-builtins))


(defun parse-brand-declaration (brand-form)
  "Parses a brand declaration form: (brand name base-type :subst mode &optional :enforce mode).
   Returns a brand-definition struct."
  (cl:let ((name (second brand-form))
           (base-type (third brand-form))
           (rest (cdddr brand-form))
           (subst-mode nil)
           (enforce-mode :diff))

    ;; Parse keyword arguments
    (cl:let ((ptr rest))
      (loop while ptr do
              (cl:cond
                ((eq (car ptr) :subst)
                 (setf subst-mode (cadr ptr))
                 (setf ptr (cddr ptr)))
                ((eq (car ptr) :enforce)
                 (setf enforce-mode (cadr ptr))
                 (setf ptr (cddr ptr)))
                (t (error "Unknown keyword in brand declaration: ~a" (car ptr))
                   (setf ptr (cdr ptr))))))

    ;; Validate
    (cl:unless subst-mode
      (error "Brand ~a: :subst is required." name))
    (cl:unless (member subst-mode '(:no :equal :descendant :ancestor))
      (error "Brand ~a: invalid :subst mode ~a." name subst-mode))
    (cl:unless (member enforce-mode '(:always :diff))
      (error "Brand ~a: invalid :enforce mode ~a. Must be :always or :diff." name enforce-mode))

    (make-brand-definition
     :brand-name name
     :base-type base-type
     :subst-mode subst-mode
     :enforce-mode enforce-mode)))

(defun brand-active-p (brand-def)
  "Returns T if the given brand should be actively enforced in the current compilation.
   A brand is active when :enforce is :always, or when :enforce is :diff
   and *differentiate-p* is set."
  (or (eq (brand-definition-enforce-mode brand-def) :always)
      (and (eq (brand-definition-enforce-mode brand-def) :diff)
           *differentiate-p*)))

(defun register-brand-definition (struct-name brand-form)
  "Registers a brand declaration from within a struct definition.
   When the brand is active: registers as a derived type in the DAG.
   When inactive: registers as a type alias (transparent erasure)."
  (cl:let* ((brand-def (if (brand-definition-p brand-form)
                           brand-form
                           (parse-brand-declaration brand-form)))
            (brand-name (brand-definition-brand-name brand-def))
            (base-type (brand-definition-base-type brand-def))
            (subst-mode (brand-definition-subst-mode brand-def)))

    ;; Check for name collisions
    ;; 1. Structs: Brand name cannot be a struct name (ambiguous constructor)
    (when (gethash brand-name *crisp-structs*)
          (error "Brand name collision: ~a is already defined as a struct." brand-name))

    ;; 2. Functions: Brand name cannot be a function name (ambiguous constructor)
    (when (gethash brand-name *function-table*)
          (error "Brand name collision: ~a is already defined as a function." brand-name))

    ;; 3. Types: Brand name cannot be an existing NON-BRAND type.
    ;;    (Redefinition of brands or shared brands is allowed)
    (when (and (gethash brand-name *crisp-types*)
               (not (is-brand-type-p brand-name)))
          (error "Brand name collision: ~a is already defined as a non-brand type." brand-name))

    ;; Store the owner struct
    (setf (brand-definition-owner-struct brand-def) struct-name)

    ;; Store in *brand-definitions* keyed by (brand-name . struct-type)
    (setf (gethash (cons brand-name struct-name) *brand-definitions*) brand-def)
    (log:info "Registered brand definition: ~a for struct ~a (base: ~a, subst: ~a, enforce: ~a)"
              brand-name struct-name base-type subst-mode
              (brand-definition-enforce-mode brand-def))

    ;; Register the type based on active/inactive status
    (if (brand-active-p brand-def)
        ;; ACTIVE: register as a proper derived type with substitution rules
        (progn
         (log:info "Brand ~a is ACTIVE - registering as derived type of ~a with :subst ~a"
                   brand-name base-type subst-mode)
         (register-derived-type brand-name base-type subst-mode))
        ;; INACTIVE: register as a transparent type alias
        (progn
         (log:info "Brand ~a is INACTIVE - registering as type alias for ~a"
                   brand-name base-type)
         (setf (gethash brand-name *crisp-type-aliases*) base-type)))))

(defun is-brand-type-p (type-name)
  "Returns the brand-definition if TYPE-NAME is a registered brand, NIL otherwise."
  (cond
   ((symbolp type-name)
     ;; For symbol types, check if any brand definition matches the name
     (maphash (lambda (key val)
                (declare (ignore key))
                (cl:when (eq (brand-definition-brand-name val) type-name)
                  (return-from is-brand-type-p val)))
              *brand-definitions*)
     nil)

   ((and (listp type-name) (symbolp (first type-name)))
     (is-brand-type-p (first type-name)))

   (t nil)))

(defun brand-member-p (member-type)
  "Returns T if MEMBER-TYPE is a branded type whose brand is currently active."
  (cl:let ((brand-def (is-brand-type-p member-type)))
    (and brand-def (brand-active-p brand-def))))

;;; =========================================================
;;; Branded Types - Std140 Layout support for derived types
;;; =========================================================
;;; Derived types (including active branded types) have identical
;;; physical layout to their base type. These functions need to
;;; resolve through the DAG as well as through type aliases.

;; src/structs.lisp
(defun get-std140-base-alignment (type-spec)
  "Returns the base alignment (N) for a given type according to std140 rules.
   For scalars, N is the size of the scalar.
   For vectors, it is 2N or 4N.
   For arrays/structs, it is rounded up to vec4 alignment (16).
   Resolves both type aliases and derived types to their physical base."
  ;; Resolve type aliases first, then derived types via DAG
  (cl:let* ((alias-resolved (resolve-type-alias type-spec))
            (resolved-type (get-type-base alias-resolved)))
    (cl:cond
      ((or (eq resolved-type 'float) (eq resolved-type 'int) (eq resolved-type 'uint)) 4)
      ((or (eq resolved-type 'double) (eq resolved-type 'long) (eq resolved-type 'ulong)) 8)
      ((or (eq resolved-type 'char) (eq resolved-type 'uchar)) 1)
      ((or (eq resolved-type 'short) (eq resolved-type 'ushort) (eq resolved-type 'half) (eq resolved-type 'bfloat16)) 2)
      ;; TODO: Handle vectors here (will need vector support first)
      ((or (eq resolved-type 'bool)) 4) ;; booleans are 4 bytes in std140
      ((eq type-spec 'c-pointer) 8) ;; c-pointer is 8 bytes
      ((and (consp type-spec) (eq (first type-spec) 'c-pointer)) 8)
      ;; Cells are pointers (8 bytes) - Check mangled name
      ((and (symbolp type-spec)
            (> (length (symbol-name type-spec)) 5)
            (string-equal (subseq (symbol-name type-spec) 0 5) "CELL_"))
       8)
      ;; Structs align to 16 bytes (vec4)
      ((gethash type-spec *crisp-structs*) 16)
      ;; Parameterized Structs (e.g. (POINT INT))
      ((and (consp type-spec) (valid-type-p type-spec))
       (cl:let ((base (first type-spec)))
         (cl:cond
           ;; Cells are pointers (8 bytes aligned to 8)
           ((string-equal (symbol-name base) "CELL") 8)
           (t
            (cl:let ((mangled (mangle-template-struct-name (first type-spec) (rest type-spec))))
              (if (gethash mangled *crisp-structs*)
                  16
                  (error "Valid type ~a but struct def not found after check alignment." type-spec)))))))
      (t
       (error "Unknown type for alignment: ~a" type-spec)))))

;; src/structs.lisp
(defun get-std140-size (type-spec)
  "Returns the size (in bytes) of a type. Does not include padding for alignment context.
   Resolves both type aliases and derived types to their physical base."
  ;; Resolve type aliases first, then derived types via DAG
  (cl:let* ((alias-resolved (resolve-type-alias type-spec))
            (resolved-type (get-type-base alias-resolved)))
    (cl:cond
      ((or (eq resolved-type 'float) (eq resolved-type 'int) (eq resolved-type 'uint)) 4)
      ((or (eq resolved-type 'double) (eq resolved-type 'long) (eq resolved-type 'ulong)) 8)
      ((or (eq resolved-type 'char) (eq resolved-type 'uchar)) 1)
      ((or (eq resolved-type 'short) (eq resolved-type 'ushort) (eq resolved-type 'half) (eq resolved-type 'bfloat16)) 2)
      ((eq resolved-type 'bool) 4)
      ((eq resolved-type 'c-pointer) 8) ;; c-pointer is 8 bytes
      ((and (consp type-spec) (eq (first type-spec) 'c-pointer)) 8)
      ;; Cells are pointers (8 bytes) - Check mangled name
      ((and (symbolp type-spec)
            (> (length (symbol-name type-spec)) 5)
            (string-equal (subseq (symbol-name type-spec) 0 5) "CELL_"))
       8)
      ;; Structs
      ((gethash type-spec *crisp-structs*)
       (crisp-struct-definition-total-size (gethash type-spec *crisp-structs*)))
      ;; Parameterized Structs
      ((and (consp type-spec) (valid-type-p type-spec))
       (cl:let ((base (first type-spec)))
         (cl:cond
           ((string-equal (symbol-name base) "CELL") 8)
           (t
            (cl:let ((mangled (mangle-template-struct-name (first type-spec) (rest type-spec))))
              (cl:let ((struct-info (gethash mangled *crisp-structs*)))
                (if struct-info
                    (crisp-struct-definition-total-size struct-info)
                    (error "Valid type ~a but struct def not found after check size." type-spec))))))))
      (t
       (error "Unknown type for size: ~a" type-spec)))))

;; src/analysis/structs.lisp
(defun numeric-type-category (type-name)
  "Returns the category (:signed-int, :unsigned-int, :float) if TYPE-NAME is a numeric
   scalar in *crisp-types*, or NIL otherwise. Resolves aliases and derived types first."
  (cl:let* ((resolved (resolve-type-alias type-name))
            (base (get-type-base resolved))
            (crisp-type (cl:when (symbolp base) (gethash base *crisp-types*))))
    (cl:when (and crisp-type
                  (member (crisp-type-category crisp-type) '(:signed-int :unsigned-int :float)))
      (crisp-type-category crisp-type))))

(defun analyze-struct-construction (expr env context location)
  "Analyzes a (%construct-struct type-name arg1 arg2 ...) form.
   Supports implicit promotion of base-type values to branded member types
   in struct constructors (the birthplace of branded values)."
  (let* ((type-name (second expr))
         (args (cddr expr))
         (struct-def (lookup-struct-definition type-name)))
    (unless struct-def
      (error 'crisp-unknown-type-error :type-name type-name :source-location location))

    ;; Validate argument count against original members (excluding compile-time properties)
    (let* ((all-members (crisp-struct-definition-members struct-def))
           (members (remove-if (lambda (m) (and (consp m) (eq (third m) :c-t))) all-members)))
      (unless (= (length args) (length members))
        (error "Struct constructor for ~a expects ~a arguments, got ~a."
          type-name (length members) (length args)))

      ;; Analyze arguments
      (let ((arg-nodes
             (loop for arg in args
                   for member in members
                   for i from 0
                   collect (let ((node (analyze-expression arg env context (append location (list (+ 2 i)))))
                                 (expected-type (second member)))
                             ;; Type check with branded type promotion
                             (unless (type-equal-p (semantic-node-type node) expected-type)
                               (cl:let ((brand-def (is-brand-type-p expected-type)))
                                 (if brand-def
                                     ;; Branded member: check numeric compatibility with base type
                                     (cl:let* ((base-type (brand-definition-base-type brand-def))
                                               (arg-cat (numeric-type-category (semantic-node-type node)))
                                               (base-cat (numeric-type-category base-type)))
                                       (if (and arg-cat base-cat)
                                           ;; Compatible numeric types - wrap in a value cast to the base type
                                           (progn
                                            (log:debug "Constructor promotion: ~a -> ~a (base ~a) for member ~a"
                                                       (semantic-node-type node) expected-type base-type (first member))
                                            (setf node (make-semantic-value-cast
                                                        :type base-type
                                                        :arg node
                                                        :source-location (append location (list (+ 2 i))))))
                                           ;; Not numeric-compatible
                                           (error 'crisp-type-error
                                             :expected expected-type
                                             :inferred (semantic-node-type node)
                                             :source-location location)))
                                     ;; Not a branded member -> real type error
                                     (error 'crisp-type-error
                                       :expected expected-type
                                       :inferred (semantic-node-type node)
                                       :source-location location))))
                             node))))

        (make-semantic-struct-construction
         :type type-name
         :args arg-nodes
         :source-location location)))))

;;; =========================================================
;;; Branded Types - Dependent Type Signatures (Test 03)
;;; =========================================================

;; src/environment.lisp
(defun parse-type-specifier (spec)
  "Parses a single type specifier, handling basic types, parameterized types,
   function types like #'(int => int), and brand type applications like (token-t s)."
  (cond
   ;; 0. Type Aliases -- FIX: Use resolve-type-alias for cycle detection
   ((and (symbolp spec) (gethash spec *crisp-type-aliases*))
     ;; Validate cycle but return alias to preserve it for metadata
     (let ((resolved (resolve-type-alias spec)))
       (valid-type-p resolved) ;; Force instantiation of underlying template
       spec)) ;; Return alias, NOT resolved

   ;; 0.1 Template Aliases (e.g. (in-cell int))
   ((and (listp spec) (symbolp (first spec)) (gethash (first spec) *crisp-template-aliases*))
     (let* ((alias-name (first spec))
            (args (rest spec))
            (alias-def (gethash alias-name *crisp-template-aliases*))
            (params (car alias-def))
            (body-spec (cdr alias-def))
            (arity (length params))
            (required-args (subseq args 0 (min (length args) arity)))
            (rest-args (subseq args (length required-args)))
            (substitutions (pairlis params required-args)))
       (let ((expanded (sublis substitutions body-spec)))
         (let ((final-spec (if (and rest-args (consp expanded))
                               (append expanded rest-args)
                               (if rest-args ;; Fix if expanded is atom but more args exist
                                   (cons expanded rest-args)
                                   expanded))))
           (parse-type-specifier final-spec)))))

   ;; 0.15 Brand Type Application: (brand-name var-ref)
   ;; e.g. (token-t s) where token-t is a brand declared in a struct.
   ;; Must come BEFORE the alias-as-list-head branch because inactive brands
   ;; are registered as type aliases and would be incorrectly expanded.
   ((and (listp spec)
         (= (length spec) 2)
         (symbolp (first spec))
         (symbolp (second spec))
         (is-brand-type-p (first spec)))
     (cl:let* ((brand-name (first spec))
               (var-ref (second spec))
               (brand-def (is-brand-type-p brand-name)))
       ;; Always resolve to the brand type name.
       ;; When active: brand-name is a proper derived type in the DAG.
       ;; When inactive: brand-name is a type alias (transparent erasure).
       ;; Either way, returning the symbol is correct and consistent with
       ;; how parse-type-specifier handles aliases (branch 0 returns alias, not resolved).
       (log:info "PARSE: Brand type application (~a ~a) -> ~a [~a]"
                 brand-name var-ref brand-name
                 (if (brand-active-p brand-def) "active" "inactive"))
       brand-name))

   ;; 0.2 Simple Alias as List Head (e.g. (int-cell :access :read-only))
   ((and (listp spec) (symbolp (first spec)) (gethash (first spec) *crisp-type-aliases*))
     (let* ((alias-name (first spec))
            (args (rest spec))
            (expanded-base (gethash alias-name *crisp-type-aliases*)))
       ;; If alias expands to a list, append args. If symbol, make a new list.
       (let ((final-spec (if (listp expanded-base)
                             (append expanded-base args)
                             (cons expanded-base args))))
         (log:info "EXPAND-ALIAS-HEAD: ~a -> ~a" spec final-spec)
         (parse-type-specifier final-spec))))

   ;; Standard symbol: e.g. 'int'
   ((and (symbolp spec) (valid-type-p spec)) spec)

   ;; Storage Handle Symbols (e.g. CELL, VECTOR...)
   ((and (symbolp spec) (member (symbol-name spec) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
     (log:info "PARSE: Promoting symbol ~a to list (~a)" spec spec)
     (parse-type-specifier (list spec)))

   ;; Function Type: #'(int => int)
   ((and (listp spec) (member (first spec) '(function common-lisp:function)))
     (let* ((sig (if (listp (second spec)) (second spec) (rest spec))))
       `(:function-type ,(analyze-return-type-from-spec sig)
                        :params ,(mapcar #'parse-type-specifier
                                   (subseq sig 0 (position-if (lambda (x) (and (symbolp x) (string-equal (symbol-name x) "=>"))) sig))))))

   ;; Storage Handle Constructor Rules
   ((and (listp spec) (member (symbol-name (first spec)) '("CELL" "VECTOR" "MATRIX" "TENSOR") :test #'string-equal))
     (log:info "PARSE: Calling expand for ~s" spec)
     (let ((canonical (expand-storage-handle-type-specifier spec)))
       (if (valid-type-p canonical)
           (let ((base (first canonical))
                 (params (rest canonical)))
             (let ((resolved-params (mapcar (lambda (p) (if (valid-type-p p) (parse-type-specifier p) p)) params)))
               (mangle-template-struct-name base resolved-params)))
           (error 'crisp-unknown-type-error :type-name spec))))

   ;; Function Type/Literal
   ((and (listp spec) (valid-function-type-p spec)) spec)

   ;; Generic Parameterized Type: e.g. '(point float)
   ((and (listp spec) (valid-type-p spec))
     (log:info "PARSE: Generic path for ~s" spec)
     (let* ((base (first spec))
            (params (rest spec))
            (arity (get-template-arity base)))
       (let ((resolved-params (mapcar (lambda (p) (if (valid-type-p p) (parse-type-specifier p) p)) params)))
         (if (and arity (> arity 0))
             (mangle-template-struct-name base resolved-params)
             (if resolved-params
                 (cons base resolved-params)
                 base)))))

   ;; Unknown?
   (t
     (log:error "PARSE: Unknown type spec: ~s" spec)
     (error 'crisp-unknown-type-error :type-name spec))))

;; src/analysis/core.lisp
(defun validate-return-types (name body env context declared-return-types location)
  "Analyzes the function body and validates return types.
   Fixes: A 1-element list whose sole element is a symbol (e.g. (TOKEN-T)) is always
   treated as a return-types list, never as a parameterized type. This prevents
   double-wrapping when the type name is a type alias."
  (declare (ignore name))
  ;; Handle the case where a function promises a return value but has no body.
  (when (and (not (equal declared-return-types '(nil))) (null body))
        (error 'crisp-type-error :expected declared-return-types :inferred '(nil) :source-location location))

  (let* ((body-nodes (analyze-body-expressions body env context location))
         (return-node (first (last body-nodes)))
         (inferred-types (if return-node
                             (let ((node-type (semantic-node-type return-node)))
                               ;; If the node-type is a list, we need to distinguish between
                               ;; a multi-value return type like '(int int) and a single
                               ;; parameterized type like '(cell int).
                               ;; A 1-element list of a symbol (e.g. (TOKEN-T)) is always a
                               ;; return-types list - no parameterized type has 0 args.
                               (if (and (listp node-type)
                                        (or (not (valid-type-p node-type))
                                            (and (= (length node-type) 1)
                                                 (symbolp (first node-type)))))
                                   node-type ; It's a list of return values, use as-is.
                                   (list node-type))) ; It's a single value, wrap it in a list.
                             '(nil))))

    (log:debug "Analyzed body nodes: ~s~% Return node: ~s~% Inferred types: ~s~% Declared return types: ~s" body-nodes return-node inferred-types declared-return-types)

    (log:debug "Type Check. Inferred: ~s (is list: ~s)~% Declared: ~s (is list: ~s)"
               inferred-types (listp inferred-types)
               declared-return-types (listp declared-return-types))

    ;; Check Types. This allows for a function returning multiple values
    ;; to be used in a context that expects fewer values (the extras are dropped).
    (let* ((num-declared (length declared-return-types))
           (num-inferred (length inferred-types))
           ;; Take the first N inferred types, where N is the number of declared types.
           (inferred-subset (if (>= num-inferred num-declared)
                                (subseq inferred-types 0 num-declared)
                                inferred-types)))
      (unless (and (>= num-inferred num-declared)
                   ;; Fix for Regression in 30-derived-numeric-types:
                   ;; Instead of strict equivalence, we check if the inferred type is assignable
                   ;; to the declared type (e.g. EQ-WEAK is assignable to FLOAT).
                   (every #'types-assignable-p inferred-subset declared-return-types))
        (error 'crisp-type-error
          :expected declared-return-types
          :inferred inferred-types
          :source-location (if return-node
                               (semantic-node-source-location return-node)
                               location))))
    (values body-nodes inferred-types)))

;;; =========================================================
;;; Branded Types - Instance Differentiation (Test 17)
;;; =========================================================

;; Brand Instance Cache: maps (brand-name . var-name) -> gensym'd type name.
;; Cleared per function compilation so that brand instance types are function-scoped.
(defvar *brand-instance-cache* (make-hash-table :test 'equal)
        "Per-function cache mapping (brand-name . variable-identity) to a gensym'd
   instance-specific type name. Cleared at the start of each function compilation.")

(defun resolve-brand-type (brand-name var-ref)
  "Resolves a branded type for a specific variable instance.
   Returns a gensym'd type name unique to (brand-name, var-ref).
   On first call for a given pair, creates a new type node in the DAG
   as a :descendant of brand-name, caches it, and returns it.
   On subsequent calls, returns the cached gensym.

   The :descendant relationship means:
   - The gensym CAN substitute for brand-name (signature matching works)
   - Two different gensyms CANNOT substitute for each other (instance safety)
   - The gensym inherits brand-name's isolation from its base type"
  (cl:let* ((cache-key (cons brand-name var-ref))
            (cached (gethash cache-key *brand-instance-cache*)))
    (or cached
        (cl:let ((gensym-name (gensym (format nil "~a-" brand-name))))
          ;; Register as a derived type: descendant of the brand type.
          ;; This establishes the ancestor link gensym -> brand-name in the DAG.
          (register-derived-type gensym-name brand-name :descendant)
          ;; Cache for this function's lifetime
          (setf (gethash cache-key *brand-instance-cache*) gensym-name)
          (log:info "Created brand instance type ~a for (~a ~a)"
                    gensym-name brand-name var-ref)
          gensym-name))))

;; Track which function the brand cache was last cleared for.
;; When analyze-function-call detects a new function, it clears the cache.
(defvar *brand-cache-last-function* nil
        "The name of the function for which the brand instance cache was last cleared.")

(defun %find-brand-owner-var (brand-def sig-params arg-nodes)
  "Given a brand-definition, finds the actual argument variable for the parameter
   whose type matches the brand's owning struct. Returns the variable name symbol
   if found (and the arg is a simple variable read), or NIL otherwise."
  (cl:let ((owner-struct (brand-definition-owner-struct brand-def)))
    (loop for sp in sig-params
          for an in arg-nodes
            when (eq (parameter-def-type sp) owner-struct)
          do (cl:return (cl:when (typep an 'semantic-var-read)
                          (semantic-var-read-name an))))))

;; src/analysis/core.lisp
(defun analyze-function-call (op expr env context location)
  "Analyzes a call to a user-defined function.
   When --differentiate is active, performs brand instance type checking:
   1. Refines return types that are brand types to instance-specific gensyms
   2. Validates that branded parameter arguments match the expected instance"
  (log:debug "Analyzing function call to ~s. Current function: ~s" op (compiler-context-current-compiling-function context))

  ;; Clear brand instance cache when we start compiling a new function
  (cl:let ((current-fn (compiler-context-current-compiling-function context)))
    (when (and current-fn (not (eq current-fn *brand-cache-last-function*)))
          (clrhash *brand-instance-cache*)
          (setf *brand-cache-last-function* current-fn)))

  ;; Recursion / call-graph tracking
  (if (multi-pass-mode-p)
      (when (compiler-context-current-compiling-function context)
            (pushnew op (gethash (compiler-context-current-compiling-function context) *call-graph*)))
      (when (eq op (compiler-context-current-compiling-function context))
            (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

  ;; Implicit args
  (let ((implicit-args-required (gethash op *implicit-arg-map*)))
    (when (and (single-pass-mode-p) implicit-args-required)
          (setf (gethash (compiler-context-current-compiling-function context) *implicit-arg-map*) implicit-args-required))

    (let* ((arg-forms (rest expr))
           (explicit-arg-nodes (loop for arg-form in arg-forms
                                     for i from 1
                                     collect (analyze-expression arg-form env context (append location (list i)))))
           (explicit-arg-types (mapcar #'get-single-value-type explicit-arg-nodes))
           (signature (resolve-best-signature op explicit-arg-types context)))

      (let ((final-arg-nodes
             (if implicit-args-required
                 (let ((implicit-arg-nodes
                        (loop for (param-name . param-type) in implicit-args-required
                              collect (let ((found (find-variable-in-env param-name env)))
                                        (if found
                                            (make-semantic-var-read :name param-name :type (parameter-def-type found) :source-location location)
                                            (error "Compiler bug: Carrier function ~s is missing implicit argument ~s."
                                              (compiler-context-current-compiling-function context) param-name))))))
                   (append implicit-arg-nodes explicit-arg-nodes))
                 explicit-arg-nodes)))

        (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
          (error 'crisp-signature-arity-error
            :expected (length (function-signature-parameters signature))
            :inferred (length explicit-arg-types)
            :source-location location))

        (let ((augmented-signature
               (if implicit-args-required
                   (let ((implicit-params (loop for (param-name . param-type) in implicit-args-required
                                                collect (make-parameter-def :name param-name :type param-type :kind :in))))
                     (make-function-signature
                      :name (function-signature-name signature)
                      :parameters (append implicit-params (function-signature-parameters signature))
                      :return-types (function-signature-return-types signature)
                      :source-location (function-signature-source-location signature)
                      :is-template-p (function-signature-is-template-p signature)
                      :template-params (function-signature-template-params signature)))
                   signature)))

          ;; === Brand Instance Type Checking (when --differentiate is active) ===
          (let ((refined-return-types (function-signature-return-types augmented-signature)))
            (when *differentiate-p*
                  (let ((sig-params (function-signature-parameters augmented-signature)))

                    ;; 1. Brand parameter type checking
                    ;; For each param whose declared type is a brand, find the struct owner
                    ;; param, resolve the expected instance type, and compare with actual.
                    (loop for param in sig-params
                          for arg-node in final-arg-nodes
                          for param-type = (parameter-def-type param)
                          do (cl:let ((brand-def (is-brand-type-p param-type)))
                               (when (and brand-def (brand-active-p brand-def))
                                     (cl:let ((owner-var (%find-brand-owner-var brand-def sig-params final-arg-nodes)))
                                       (when owner-var
                                             (cl:let* ((expected-type (resolve-brand-type param-type owner-var))
                                                       (actual-type (get-single-value-type arg-node)))
                                               (unless (or (eq actual-type expected-type)
                                                           ;; Also accept if actual IS the expected (through aliasing)
                                                           (is-substitutable-for? actual-type expected-type))
                                                 (log:info "Brand mismatch: expected ~a (instance of ~a for ~a) but got ~a"
                                                           expected-type param-type owner-var actual-type)
                                                 (error 'crisp-type-error
                                                   :expected (list expected-type)
                                                   :inferred (list actual-type)
                                                   :source-location location))))))))

                    ;; 2. Brand return type refinement
                    ;; If any return type is a brand type, refine it to the instance-specific
                    ;; gensym based on the struct owner argument.
                    (setf refined-return-types
                      (loop for ret-type in (function-signature-return-types augmented-signature)
                            collect (cl:let ((brand-def (is-brand-type-p ret-type)))
                                      (if (and brand-def (brand-active-p brand-def))
                                          (cl:let ((owner-var (%find-brand-owner-var brand-def sig-params final-arg-nodes)))
                                            (if owner-var
                                                (resolve-brand-type ret-type owner-var)
                                                ret-type))
                                          ret-type))))))

            (make-semantic-call :name (function-signature-name augmented-signature)
                                :type refined-return-types
                                :args final-arg-nodes
                                :signature augmented-signature
                                :source-location location)))))))

;;; =========================================================
;;; Branded Types - Metadata Generation / Hoisting Fix (Test 43)
;;; =========================================================

(in-package :crisp.compiler)

(defun serialize-structs (stream structs-hash)
  (format stream "(:structs~%")
  (let ((struct-names (alexandria:hash-table-keys structs-hash)))
    (let ((sorted-names (sort-structs-by-dependency struct-names)))
      (dolist (name sorted-names)
        (let ((def (gethash name *crisp-structs*)))
          (when def
                (format stream "  (def-struct ~a" (strip-package-qualifiers name))
                (dolist (m (crisp-struct-definition-members def))
                  (let* ((member-name (first m))
                         (member-type (second m))
                         ;; Resolve brand type to base type for metadata
                         (brand-def (is-brand-type-p member-type))
                         ;; Always resolve to base type for C++ metadata, regardless of active state.
                         ;; C++ does not know about brands, only the underlying physical type.
                         (final-type (if brand-def
                                         (brand-definition-base-type brand-def)
                                         member-type)))
                    (format stream " (~a ~a)"
                      (strip-package-qualifiers member-name)
                      (strip-package-qualifiers final-type))))
                (format stream ")~%"))))))
  (format stream "  )~%~%"))

;; REDEFINITION: generate-metadata-for-file to ensure it uses the NEW serialize-structs
(defun generate-metadata-for-file (input-path output-path &key (output-targets nil) (source-file nil) (forms nil))
  (let ((kernel-names (if forms
                          (extract-defined-kernels forms)
                          (alexandria:hash-table-keys *function-table*)))
        (generated-files nil))

    (let ((src-path (or source-file
                        (namestring input-path))))

      (when (null kernel-names)
            (multiple-value-bind (aliases structs)
                (collect-kernel-dependencies nil)
              (with-open-file (stream output-path :direction :output :if-exists :supersede)
                (format stream ";; generated by crisp-compile~%~%")))
            (push output-path generated-files))

      (dolist (k kernel-names)
        (let* ((suffix (format nil "_~a.metacrisp" (string-downcase (symbol-name k))))
               (final-path (make-pathname :name (format nil "~a_~a" (pathname-name output-path) (string-downcase (symbol-name k)))
                                          :type "metacrisp"
                                          :defaults output-path)))

          (multiple-value-bind (aliases structs)
              (collect-kernel-dependencies (list k))

            (with-open-file (stream final-path :direction :output :if-exists :supersede)
              (format stream ";; generated by crisp-compile~%~%")
              (serialize-aliases stream aliases)
              (serialize-structs stream structs)
              (serialize-kernels stream (list k) :source src-path :output-targets output-targets)))

          (push final-path generated-files)))

      (nreverse generated-files))))
;;; =========================================================
;;; Dependent Type Validation (Test 20 & 13)
;;; =========================================================

(defun validate-dependent-brand-types (declare-forms env)
  "Verifies that any parameters typed as (brand var) refer to a valid owner parameter.
   Scans the raw declarations to find dependencies that parse-type-specifier might have flattened.
   Supports shared brands (same brand name defined on multiple structs)."
  (loop for decl in declare-forms do
          (labels ((scan (form)
                         (cond
                          ((and (listp form)
                                (symbolp (car form))
                                (is-brand-type-p (car form))
                                (= (length form) 2)
                                (symbolp (second form)))
                            ;; Found (BRAND VAR) candidate
                            (let ((brand-name (car form))
                                  (var-ref (second form)))
                              ;; Check var exists in env
                              (let ((param (find var-ref env :key #'parameter-def-name)))
                                (unless param
                                  (error "Brand dependency ~a refers to unknown parameter ~a." form var-ref))

                                (let ((owner-type (parameter-def-type param)))
                                  ;; Check if this specific (Brand . OwnerType) pair is defined
                                  ;; This handles shared brands: TOKEN-T might be defined for SERVER and VIRTUAL-SERVER.
                                  (unless (gethash (cons brand-name owner-type) *brand-definitions*)
                                    ;; Not defined for this specific owner. 
                                    ;; Retrieve *any* definition to give a helpful error message.
                                    (let ((any-def (is-brand-type-p brand-name)))
                                      (error "Brand dependency mismatch: ~a is defined for owner ~a, but ~a is of type ~a (and no shared definition found)."
                                        brand-name
                                        (if any-def (brand-definition-owner-struct any-def) "UNKNOWN")
                                        var-ref owner-type)))))))
                          ((consp form)
                            (scan (car form))
                            (scan (cdr form))))))
            (scan decl))))

;;; Redefine register-function-signature to inject validation
(defun register-function-signature (form location)
  (let* ((name (second form))
         (params (third form))
         (body (cdddr form))
         (declare-forms (loop for f in body
                              while (and (listp f) (eq (car f) 'declare))
                              collect f)))

    (finish-output *error-output*)
    ;; Debug logging
    ;; (log:info "REGISTER-FUNC (Overlay): ~s" name)

    (multiple-value-bind (env return-types optional-idx extracted-defaults key-idx)
        (parse-function-declarations params (loop for f in declare-forms append (rest f)))

      ;; --- NEW VALIDATION ---
      (validate-dependent-brand-types declare-forms env)
      ;; ----------------------

      (cond
       ((or optional-idx key-idx)
         (%register-generic-function name params env return-types declare-forms
                                     extracted-defaults key-idx body location))
       (t
         (%register-standard-function name env return-types declare-forms location))))))
(defun analyze-function-call (op expr env context location)
  "Analyzes a call to a user-defined function."
  (log:debug "Analyzing function call to ~s. Current function: ~s" op (compiler-context-current-compiling-function context))

  ;; PATCHED: Use mode predicates and simplified recursion check
  (if (multi-pass-mode-p)
      (when (compiler-context-current-compiling-function context)
            (pushnew op (gethash (compiler-context-current-compiling-function context) *call-graph*)))
      (when (eq op (compiler-context-current-compiling-function context))
            (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

  ;; PATCHED: Use single-pass-mode-p predicate
  (let ((implicit-args-required (gethash op *implicit-arg-map*)))
    (when (and (single-pass-mode-p) implicit-args-required)
          (setf (gethash (compiler-context-current-compiling-function context) *implicit-arg-map*) implicit-args-required))

    (let* ((arg-forms (rest expr))
           (explicit-arg-nodes (loop for arg-form in arg-forms
                                     for i from 1
                                     collect (analyze-expression arg-form env context (append location (list i)))))
           (explicit-arg-types (mapcar #'get-single-value-type explicit-arg-nodes))
           (signature (resolve-best-signature op explicit-arg-types context)))

      (let ((final-arg-nodes
             (if implicit-args-required
                 (let ((implicit-arg-nodes
                        (loop for (param-name . param-type) in implicit-args-required
                              collect (let ((found (find-variable-in-env param-name env)))
                                        (if found
                                            (make-semantic-var-read :name param-name :type (parameter-def-type found) :source-location location)
                                            (error "Compiler bug: Carrier function ~s is missing implicit argument ~s."
                                              (compiler-context-current-compiling-function context) param-name))))))
                   (append implicit-arg-nodes explicit-arg-nodes))
                 explicit-arg-nodes)))

        (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
          (error 'crisp-signature-arity-error
            :expected (length (function-signature-parameters signature))
            :inferred (length explicit-arg-types)
            :source-location location))

        (let ((augmented-signature
               (if implicit-args-required
                   (let ((implicit-params (loop for (param-name . param-type) in implicit-args-required
                                                collect (make-parameter-def :name param-name :type param-type :kind :in))))
                     (make-function-signature
                      :name (function-signature-name signature)
                      :parameters (append implicit-params (function-signature-parameters signature))
                      :return-types (function-signature-return-types signature)
                      :source-location (function-signature-source-location signature)
                      :is-template-p (function-signature-is-template-p signature)
                      :template-params (function-signature-template-params signature)))
                   signature)))

          (make-semantic-call :name (function-signature-name augmented-signature)
                              :type (function-signature-return-types augmented-signature)
                              :args final-arg-nodes
                              :signature augmented-signature
                              :source-location location))))))
;;; =========================================================
;;; Runtime Check Fix for Shared Brands
;;; =========================================================

(defun %find-brand-owner-var (brand-name sig-params arg-nodes)
  "Finds the actual argument variable for the parameter that owns the brand instance.
   Handles shared brands by checking if any parameter's type is a registered owner 
   for the given BRAND-NAME."
  (loop for sp in sig-params
        for an in arg-nodes
        for param-type = (parameter-def-type sp)
          ;; Check if this parameter's type is a registered owner for the brand
          when (gethash (cons brand-name param-type) *brand-definitions*)
        do (return (if (typep an 'semantic-var-read)
                       (semantic-var-read-name an)
                       nil))))

;;; Redefine analyze-function-call to use the new finding logic
(defun analyze-function-call (op expr env context location)
  (log:debug "Analyzing function call to ~s. Current function: ~s" op (compiler-context-current-compiling-function context))

  (when (eq op 'explicit-return)
        (log:error "WTF: analyze-function-call called on explicit-return! Analyzers map has it? ~a" (gethash 'explicit-return *expression-analyzers*)))

  ;; Recursion / call-graph tracking
  (if (multi-pass-mode-p)
      (when (compiler-context-current-compiling-function context)
            (pushnew op (gethash (compiler-context-current-compiling-function context) *call-graph*)))
      (when (eq op (compiler-context-current-compiling-function context))
            (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

  ;; Implicit args
  (let ((implicit-args-required (gethash op *implicit-arg-map*)))
    (when (and (single-pass-mode-p) implicit-args-required)
          (setf (gethash (compiler-context-current-compiling-function context) *implicit-arg-map*) implicit-args-required))

    (let* ((arg-forms (rest expr))
           (explicit-arg-nodes (loop for arg-form in arg-forms
                                     for i from 1
                                     collect (analyze-expression arg-form env context (append location (list i)))))
           (explicit-arg-types (mapcar #'get-single-value-type explicit-arg-nodes))
           (signature (resolve-best-signature op explicit-arg-types context)))

      (let ((final-arg-nodes
             (if implicit-args-required
                 (let ((implicit-arg-nodes
                        (loop for (param-name . param-type) in implicit-args-required
                              collect (let ((found (find-variable-in-env param-name env)))
                                        (if found
                                            (make-semantic-var-read :name param-name :type (parameter-def-type found) :source-location location)
                                            (error "Compiler bug: Carrier function ~s is missing implicit argument ~s."
                                              (compiler-context-current-compiling-function context) param-name))))))
                   (append implicit-arg-nodes explicit-arg-nodes))
                 explicit-arg-nodes)))

        (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
          (error 'crisp-signature-arity-error
            :expected (length (function-signature-parameters signature))
            :inferred (length explicit-arg-types)
            :source-location location))

        (let ((augmented-signature
               (if implicit-args-required
                   (let ((implicit-params (loop for (param-name . param-type) in implicit-args-required
                                                collect (make-parameter-def :name param-name :type param-type :kind :in))))
                     (make-function-signature
                      :name (function-signature-name signature)
                      :parameters (append implicit-params (function-signature-parameters signature))
                      :return-types (function-signature-return-types signature)
                      :source-location (function-signature-source-location signature)
                      :is-template-p (function-signature-is-template-p signature)
                      :template-params (function-signature-template-params signature)))
                   signature)))

          ;; === Brand Instance Type Checking (when --differentiate is active) ===
          (let ((refined-return-types (function-signature-return-types augmented-signature)))
            (when *differentiate-p*
                  (let ((sig-params (function-signature-parameters augmented-signature)))

                    ;; 1. Brand parameter type checking
                    (loop for param in sig-params
                          for arg-node in final-arg-nodes
                          for param-type = (parameter-def-type param)
                          do (cl:let ((brand-def (is-brand-type-p param-type)))
                               (when (and brand-def (brand-active-p brand-def))
                                     ;; FIX: Use brand-name to find owner, supporting shared brands
                                     (cl:let ((owner-var (%find-brand-owner-var (brand-definition-brand-name brand-def)
                                                                                sig-params final-arg-nodes)))
                                       (when owner-var
                                             (cl:let* ((expected-type (resolve-brand-type param-type owner-var))
                                                       (actual-type (get-single-value-type arg-node)))
                                               (unless (or (eq actual-type expected-type)
                                                           (is-substitutable-for? actual-type expected-type))
                                                 ;; (log:info "Brand mismatch: expected ~a (instance of ~a for ~a) but got ~a" expected-type param-type owner-var actual-type)
                                                 (error 'crisp-type-error
                                                   :expected (list expected-type)
                                                   :inferred (list actual-type)
                                                   :source-location location))))))))

                    ;; 2. Brand return type refinement
                    (setf refined-return-types
                      (loop for ret-type in (function-signature-return-types augmented-signature)
                            collect (cl:let ((brand-def (is-brand-type-p ret-type)))
                                      (if (and brand-def (brand-active-p brand-def))
                                          (cl:let ((owner-var (%find-brand-owner-var (brand-definition-brand-name brand-def)
                                                                                     sig-params final-arg-nodes)))
                                            (if owner-var
                                                (resolve-brand-type ret-type owner-var)
                                                ret-type))
                                          ret-type))))))

            (make-semantic-call :name (function-signature-name augmented-signature)
                                :type refined-return-types
                                :args final-arg-nodes
                                :signature augmented-signature
                                :source-location location)))))))
;;; =========================================================
;;; Runtime Check Fix for Shared Brands
;;; =========================================================

(defun %find-brand-owner-var (brand-name sig-params arg-nodes)
  "Finds the actual argument variable for the parameter that owns the brand instance.
   Handles shared brands by checking if any parameter's type is a registered owner 
   for the given BRAND-NAME."
  (loop for sp in sig-params
        for an in arg-nodes
        for param-type = (parameter-def-type sp)
          ;; Check if this parameter's type is a registered owner for the brand
          when (gethash (cons brand-name param-type) *brand-definitions*)
        do (return (if (typep an 'semantic-var-read)
                       (semantic-var-read-name an)
                       nil))))

;;; Redefine analyze-function-call to use the new finding logic
(defun analyze-function-call (op expr env context location)
  (log:debug "Analyzing function call to ~s. Current function: ~s" op (compiler-context-current-compiling-function context))

  ;; Recursion / call-graph tracking
  (if (multi-pass-mode-p)
      (when (compiler-context-current-compiling-function context)
            (pushnew op (gethash (compiler-context-current-compiling-function context) *call-graph*)))
      (when (eq op (compiler-context-current-compiling-function context))
            (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

  ;; Implicit args
  (let ((implicit-args-required (gethash op *implicit-arg-map*)))
    (when (and (single-pass-mode-p) implicit-args-required)
          (setf (gethash (compiler-context-current-compiling-function context) *implicit-arg-map*) implicit-args-required))

    (let* ((arg-forms (rest expr))
           (explicit-arg-nodes (loop for arg-form in arg-forms
                                     for i from 1
                                     collect (analyze-expression arg-form env context (append location (list i)))))
           (explicit-arg-types (mapcar #'get-single-value-type explicit-arg-nodes))
           (signature (resolve-best-signature op explicit-arg-types context)))

      (let ((final-arg-nodes
             (if implicit-args-required
                 (let ((implicit-arg-nodes
                        (loop for (param-name . param-type) in implicit-args-required
                              collect (let ((found (find-variable-in-env param-name env)))
                                        (if found
                                            (make-semantic-var-read :name param-name :type (parameter-def-type found) :source-location location)
                                            (error "Compiler bug: Carrier function ~s is missing implicit argument ~s."
                                              (compiler-context-current-compiling-function context) param-name))))))
                   (append implicit-arg-nodes explicit-arg-nodes))
                 explicit-arg-nodes)))

        (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
          (error 'crisp-signature-arity-error
            :expected (length (function-signature-parameters signature))
            :inferred (length explicit-arg-types)
            :source-location location))

        (let ((augmented-signature
               (if implicit-args-required
                   (let ((implicit-params (loop for (param-name . param-type) in implicit-args-required
                                                collect (make-parameter-def :name param-name :type param-type :kind :in))))
                     (make-function-signature
                      :name (function-signature-name signature)
                      :parameters (append implicit-params (function-signature-parameters signature))
                      :return-types (function-signature-return-types signature)
                      :source-location (function-signature-source-location signature)
                      :is-template-p (function-signature-is-template-p signature)
                      :template-params (function-signature-template-params signature)))
                   signature)))

          ;; === Brand Instance Type Checking (when --differentiate is active) ===
          (let ((refined-return-types (function-signature-return-types augmented-signature)))
            (when *differentiate-p*
                  (let ((sig-params (function-signature-parameters augmented-signature)))

                    ;; 1. Brand parameter type checking
                    (loop for param in sig-params
                          for arg-node in final-arg-nodes
                          for param-type = (parameter-def-type param)
                          do (cl:let ((brand-def (is-brand-type-p param-type)))
                               (when (and brand-def (brand-active-p brand-def))
                                     ;; FIX: Use brand-name to find owner, supporting shared brands
                                     (cl:let ((owner-var (%find-brand-owner-var (brand-definition-brand-name brand-def)
                                                                                sig-params final-arg-nodes)))
                                       (when owner-var
                                             (cl:let* ((expected-type (resolve-brand-type param-type owner-var))
                                                       (actual-type (get-single-value-type arg-node)))
                                               (unless (or (eq actual-type expected-type)
                                                           (is-substitutable-for? actual-type expected-type))
                                                 (error 'crisp-type-error
                                                   :expected (list expected-type)
                                                   :inferred (list actual-type)
                                                   :source-location location))))))))

                    ;; 2. Brand return type refinement (DISABLED due to regression)
                    ;; (setf refined-return-types ...)
                    ))

            (make-semantic-call :name (function-signature-name augmented-signature)
                                :type refined-return-types
                                :args final-arg-nodes
                                :signature augmented-signature
                                :source-location location)))))))
;;; =========================================================
;;; Runtime Check Fix for Shared Brands
;;; =========================================================

(defun %find-brand-owner-var (brand-name sig-params arg-nodes)
  "Finds the actual argument variable for the parameter that owns the brand instance.
   Handles shared brands by checking if any parameter's type is a registered owner 
   for the given BRAND-NAME."
  (loop for sp in sig-params
        for an in arg-nodes
        for param-type = (parameter-def-type sp)
          ;; Check if this parameter's type is a registered owner for the brand
          when (gethash (cons brand-name param-type) *brand-definitions*)
        do (return (if (typep an 'semantic-var-read)
                       (semantic-var-read-name an)
                       nil))))

;;; Redefine analyze-function-call to use the new finding logic
(defun analyze-function-call (op expr env context location)
  (log:debug "Analyzing function call to ~s. Current function: ~s" op (compiler-context-current-compiling-function context))

  ;; Recursion / call-graph tracking
  (if (multi-pass-mode-p)
      (when (compiler-context-current-compiling-function context)
            (pushnew op (gethash (compiler-context-current-compiling-function context) *call-graph*)))
      (when (eq op (compiler-context-current-compiling-function context))
            (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

  ;; Implicit args
  (let ((implicit-args-required (gethash op *implicit-arg-map*)))
    (when (and (single-pass-mode-p) implicit-args-required)
          (setf (gethash (compiler-context-current-compiling-function context) *implicit-arg-map*) implicit-args-required))

    (let* ((arg-forms (rest expr))
           (explicit-arg-nodes (loop for arg-form in arg-forms
                                     for i from 1
                                     collect (analyze-expression arg-form env context (append location (list i)))))
           (explicit-arg-types (mapcar #'get-single-value-type explicit-arg-nodes))
           (signature (resolve-best-signature op explicit-arg-types context)))

      (let ((final-arg-nodes
             (if implicit-args-required
                 (let ((implicit-arg-nodes
                        (loop for (param-name . param-type) in implicit-args-required
                              collect (let ((found (find-variable-in-env param-name env)))
                                        (if found
                                            (make-semantic-var-read :name param-name :type (parameter-def-type found) :source-location location)
                                            (error "Compiler bug: Carrier function ~s is missing implicit argument ~s."
                                              (compiler-context-current-compiling-function context) param-name))))))
                   (append implicit-arg-nodes explicit-arg-nodes))
                 explicit-arg-nodes)))

        (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
          (error 'crisp-signature-arity-error
            :expected (length (function-signature-parameters signature))
            :inferred (length explicit-arg-types)
            :source-location location))

        (let ((augmented-signature
               (if implicit-args-required
                   (let ((implicit-params (loop for (param-name . param-type) in implicit-args-required
                                                collect (make-parameter-def :name param-name :type param-type :kind :in))))
                     (make-function-signature
                      :name (function-signature-name signature)
                      :parameters (append implicit-params (function-signature-parameters signature))
                      :return-types (function-signature-return-types signature)
                      :source-location (function-signature-source-location signature)
                      :is-template-p (function-signature-is-template-p signature)
                      :template-params (function-signature-template-params signature)))
                   signature)))

          ;; === Brand Instance Type Checking (when --differentiate is active) ===
          (let ((refined-return-types (function-signature-return-types augmented-signature)))
            (when *differentiate-p*
                  (let ((sig-params (function-signature-parameters augmented-signature)))

                    ;; 1. Brand parameter type checking
                    (loop for param in sig-params
                          for arg-node in final-arg-nodes
                          for param-type = (parameter-def-type param)
                          do (cl:let ((brand-def (is-brand-type-p param-type)))
                               (when (and brand-def (brand-active-p brand-def))
                                     ;; FIX: Use brand-name to find owner, supporting shared brands
                                     (cl:let ((owner-var (%find-brand-owner-var (brand-definition-brand-name brand-def)
                                                                                sig-params final-arg-nodes)))
                                       (when owner-var
                                             (cl:let* ((expected-type (resolve-brand-type param-type owner-var))
                                                       (actual-type (get-single-value-type arg-node)))
                                               (unless (or (eq actual-type expected-type)
                                                           (is-substitutable-for? actual-type expected-type))
                                                 (error 'crisp-type-error
                                                   :expected (list expected-type)
                                                   :inferred (list actual-type)
                                                   :source-location location))))))))

                    ;; 2. Brand return type refinement
                    ;; DISABLED due to regression (03-struct-and-function-signatures)
                    ;; Refined return types were causing undefined function errors on explicit-return.
                    ))

            (make-semantic-call :name (function-signature-name augmented-signature)
                                :type refined-return-types
                                :args final-arg-nodes
                                :signature augmented-signature
                                :source-location location)))))))
;;; =========================================================
;;; Runtime Check Fix for Shared Brands
;;; =========================================================

(defun %find-brand-owner-var (brand-name sig-params arg-nodes)
  "Finds the actual argument variable for the parameter that owns the brand instance.
   Handles shared brands by checking if any parameter's type is a registered owner 
   for the given BRAND-NAME."
  (loop for sp in sig-params
        for an in arg-nodes
        for param-type = (parameter-def-type sp)
          ;; Check if this parameter's type is a registered owner for the brand
          when (gethash (cons brand-name param-type) *brand-definitions*)
        do (cl:return (if (typep an 'semantic-var-read)
                          (semantic-var-read-name an)
                          nil))))

;;; Redefine analyze-function-call to use the new finding logic
(defun analyze-function-call (op expr env context location)
  (log:debug "Analyzing function call to ~s. Current function: ~s" op (compiler-context-current-compiling-function context))

  ;; Recursion / call-graph tracking
  (if (multi-pass-mode-p)
      (when (compiler-context-current-compiling-function context)
            (pushnew op (gethash (compiler-context-current-compiling-function context) *call-graph*)))
      (when (eq op (compiler-context-current-compiling-function context))
            (error 'crisp-recursion-error :form op :source-location (append location '(0)))))

  ;; Implicit args
  (let ((implicit-args-required (gethash op *implicit-arg-map*)))
    (when (and (single-pass-mode-p) implicit-args-required)
          (setf (gethash (compiler-context-current-compiling-function context) *implicit-arg-map*) implicit-args-required))

    (let* ((arg-forms (rest expr))
           (explicit-arg-nodes (loop for arg-form in arg-forms
                                     for i from 1
                                     collect (analyze-expression arg-form env context (append location (list i)))))
           (explicit-arg-types (mapcar #'get-single-value-type explicit-arg-nodes))
           (signature (resolve-best-signature op explicit-arg-types context)))

      (let ((final-arg-nodes
             (if implicit-args-required
                 (let ((implicit-arg-nodes
                        (loop for (param-name . param-type) in implicit-args-required
                              collect (let ((found (find-variable-in-env param-name env)))
                                        (if found
                                            (make-semantic-var-read :name param-name :type (parameter-def-type found) :source-location location)
                                            (error "Compiler bug: Carrier function ~s is missing implicit argument ~s."
                                              (compiler-context-current-compiling-function context) param-name))))))
                   (append implicit-arg-nodes explicit-arg-nodes))
                 explicit-arg-nodes)))

        (unless (= (length explicit-arg-types) (length (function-signature-parameters signature)))
          (error 'crisp-signature-arity-error
            :expected (length (function-signature-parameters signature))
            :inferred (length explicit-arg-types)
            :source-location location))

        (let ((augmented-signature
               (if implicit-args-required
                   (let ((implicit-params (loop for (param-name . param-type) in implicit-args-required
                                                collect (make-parameter-def :name param-name :type param-type :kind :in))))
                     (make-function-signature
                      :name (function-signature-name signature)
                      :parameters (append implicit-params (function-signature-parameters signature))
                      :return-types (function-signature-return-types signature)
                      :source-location (function-signature-source-location signature)
                      :is-template-p (function-signature-is-template-p signature)
                      :template-params (function-signature-template-params signature)))
                   signature)))

          ;; === Brand Instance Type Checking (when --differentiate is active) ===
          (let ((refined-return-types (function-signature-return-types augmented-signature)))
            (when *differentiate-p*
                  (let ((sig-params (function-signature-parameters augmented-signature)))

                    ;; 1. Brand parameter type checking
                    (loop for param in sig-params
                          for arg-node in final-arg-nodes
                          for param-type = (parameter-def-type param)
                          do (cl:let ((brand-def (is-brand-type-p param-type)))
                               (when (and brand-def (brand-active-p brand-def))
                                     ;; FIX: Use brand-name to find owner, supporting shared brands
                                     (cl:let ((owner-var (%find-brand-owner-var (brand-definition-brand-name brand-def)
                                                                                sig-params final-arg-nodes)))
                                       (when owner-var
                                             (cl:let* ((expected-type (resolve-brand-type param-type owner-var))
                                                       (actual-type (get-single-value-type arg-node)))
                                               (unless (or (eq actual-type expected-type)
                                                           (is-substitutable-for? actual-type expected-type))
                                                 (error 'crisp-type-error
                                                   :expected (list expected-type)
                                                   :inferred (list actual-type)
                                                   :source-location location))))))))

                    ;; 2. Brand return type refinement
                    (setf refined-return-types
                      (loop for ret-type in (function-signature-return-types augmented-signature)
                            collect (cl:let ((brand-def (is-brand-type-p ret-type)))
                                      (if (and brand-def (brand-active-p brand-def))
                                          (cl:let ((owner-var (%find-brand-owner-var (brand-definition-brand-name brand-def)
                                                                                     sig-params final-arg-nodes)))
                                            (if owner-var
                                                (resolve-brand-type ret-type owner-var)
                                                ret-type))
                                          ret-type))))))

            (make-semantic-call :name (function-signature-name augmented-signature)
                                :type refined-return-types
                                :args final-arg-nodes
                                :signature augmented-signature
                                :source-location location)))))))
;;; =========================================================
;;; Brand Misuse Error
;;; =========================================================

(defmacro brand (&rest args)
  "Catches invalid usage of BRAND outside of DEF-STRUCT or DEF-RECORD."
  (declare (ignore args))
  (error "BRAND can only be used within DEF-STRUCT or DEF-RECORD."))
