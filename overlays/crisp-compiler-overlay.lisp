;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

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
  (brand-name nil :type symbol)       ; e.g., TOKEN-T
  (base-type nil :type symbol)        ; e.g., ULONG
  (subst-mode nil :type symbol)       ; :no, :equal, :descendant, :ancestor
  (enforce-mode :diff :type symbol)   ; :always or :diff
  (owner-struct nil :type symbol))    ; e.g., SERVER

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
  (cl:when (symbolp type-name)
    (maphash (lambda (key val)
               (declare (ignore key))
               (cl:when (eq (brand-definition-brand-name val) type-name)
                 (return-from is-brand-type-p val)))
             *brand-definitions*)
    nil))

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

