;;;; src/types/brand.lisp
;;;;
;;;; Branded Types - Definition, Registration, Instance Differentiation, and Validation
;;;;
;;;; This module implements the brand type system for Crisp. Brands are
;;;; lightweight derived types declared inside structs/records that provide
;;;; type-level isolation (preventing accidental misuse of values) with
;;;; optional instance differentiation (ensuring values from different
;;;; sources cannot be mixed).
;;;;
;;;; Key concepts:
;;;;   - Brand Definition:  Parsed from (brand name base-type :subst mode :enforce mode)
;;;;   - Brand Registration: Hooks into the type DAG (active) or alias table (inactive)
;;;;   - Instance Differentiation: Per-function gensym'd types for :enforce :diff brands
;;;;   - Dependent Validation: Ensures (brand var) references point to valid owners

(in-package :crisp.compiler)

;;; =========================================================
;;; Brand Instance Differentiation - State
;;; =========================================================

(defvar *brand-instance-cache* (make-hash-table :test 'equal)
  "Per-function cache mapping (brand-name . variable-identity) to a gensym'd
   instance-specific type name. Cleared at the start of each function compilation.")

(defvar *brand-cache-last-function* nil
  "The name of the function for which the brand instance cache was last cleared.")

(defvar *brand-instance-types* (make-hash-table :test 'equal)
  "Maps gensym brand-instance type names (created by resolve-brand-type) to
   the brand-name they instantiate.  Consulted by resolve-dominance to block
   cross-instance arithmetic and to preserve instance types in arithmetic
   with the brand's base type.
   Cleared alongside *brand-instance-cache* in initialize-compiler.")

;;; =========================================================
;;; Brand Predicates & Queries
;;; =========================================================

(defun brand-active-p (brand-def)
  "Returns T if the given brand should be actively enforced in the current compilation.
   A brand is active when :enforce is :always, or when :enforce is :diff
   and *differentiate-p* is set."
  (or (eq (brand-definition-enforce-mode brand-def) :always)
      (and (eq (brand-definition-enforce-mode brand-def) :diff)
           *differentiate-p*)))

(defun is-brand-type-p (type-name)
  "Returns the brand-definition if TYPE-NAME is a registered brand, NIL otherwise."
  (cl:cond
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
;;; Brand Parsing
;;; =========================================================

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

;;; =========================================================
;;; Brand Registration
;;; =========================================================


(defun register-brand-definition (struct-name brand-form)
  "Registers a brand declaration from within a struct definition.
   When the brand is active: registers as a derived type in the DAG.
   When inactive: registers as a type alias (transparent erasure).
   Parameterized brands (base type varies across template specializations,
   and the brand is NOT used as a concrete struct member type) skip global
   registration and are resolved lazily per-owner.
   Brands that conflict in base type AND appear as a concrete struct member
   in the existing owner are always an error (cannot be parameterized).

   Non-symbol base types (e.g., compound types like (POINT INT)) are silently
   skipped: they cannot be registered in the type DAG."
  ;; Guard: compound element types (cell (point int), etc.) produce brand forms
  ;; like (brand value-t (POINT INT) ...).  The brand-definition struct requires
  ;; a symbol for base-type; skip registration rather than crashing.
  (cl:when (and (listp brand-form) (not (brand-definition-p brand-form)))
    (cl:let ((raw-base-type (third brand-form)))
      (cl:unless (symbolp raw-base-type)
        (log:info "Skipping brand registration for ~a: base-type ~a is not a symbol (compound element types cannot be branded)"
                  struct-name raw-base-type)
        (return-from register-brand-definition nil))))

  (cl:let* ((brand-def (if (brand-definition-p brand-form)
                           brand-form
                           (parse-brand-declaration brand-form)))
            (brand-name (brand-definition-brand-name brand-def))
            (base-type (brand-definition-base-type brand-def))
            (subst-mode (brand-definition-subst-mode brand-def))
            (is-parameterized (gethash brand-name *parameterized-brand-names*))
            ;; Set to T when this brand is already globally registered (same base-type,
            ;; different owner struct).  In that case we store the per-owner entry in
            ;; *brand-definitions* but skip calling register-derived-type again.
            ;; This prevents subst-mode conflicts when multiple structs share a brand
            ;; name with the same element type but declare different :subst modes
            ;; (e.g., real cell uses :descendant, fake-cell uses :ancestor).
            (skip-global nil))

    ;; Check for name collisions
    (cl:when (gethash brand-name *crisp-structs*)
          (error "Brand name collision: ~a is already defined as a struct." brand-name))
    (cl:when (gethash brand-name *function-table*)
          (error "Brand name collision: ~a is already defined as a function." brand-name))
    (cl:when (and (gethash brand-name *crisp-types*)
               (not (is-brand-type-p brand-name)))
          (error "Brand name collision: ~a is already defined as a non-brand type." brand-name))

    ;; Examine any existing registration for the same brand name.
    (cl:unless is-parameterized
      (cl:let ((existing (is-brand-type-p brand-name)))
        (cl:when existing
          (cl:cond
            ;; Different base-type: conflict or parameterize
            ((not (eq (brand-definition-base-type existing) base-type))
             (cl:let* ((existing-owner (brand-definition-owner-struct existing))
                       (existing-struct-def (find-struct-definition-by-name existing-owner))
                       (brand-used-as-member-p
                         (and existing-struct-def
                              (some (lambda (m) (eq (second m) brand-name))
                                    (crisp-struct-definition-members existing-struct-def)))))
               (if brand-used-as-member-p
                   (error "Cannot define derived type ~a: type already exists with DIFFERENT definition (Original: ~a, New: ~a)."
                          brand-name
                          (brand-definition-base-type existing)
                          base-type)
                   (progn
                    (log:info "Brand ~a detected as PARAMETERIZED: base ~a (from ~a) vs ~a (from ~a)"
                              brand-name
                              (brand-definition-base-type existing) existing-owner
                              base-type struct-name)
                    (setf is-parameterized t)
                    (setf (gethash brand-name *parameterized-brand-names*) t)
                    (remhash brand-name *crisp-type-aliases*)))))

            ;; Same base-type, different owner: brand already globally registered.
            ;; Skip global re-registration to avoid subst-mode conflicts.
            ;; This handles the case where real cell registers value-t with
            ;; :descendant and fake-cell later registers value-t with :ancestor
            ;; for the same element type.  The first owner's subst-mode wins;
            ;; subsequent owners just get a per-owner *brand-definitions* entry.
            ((not (eq (brand-definition-owner-struct existing) struct-name))
             (log:info "Brand ~a already globally registered (first owner: ~a); skipping global re-registration for ~a (same base-type ~a)"
                       brand-name (brand-definition-owner-struct existing) struct-name base-type)
             (setf skip-global t))

            ;; Same base-type, same owner: idempotent, nothing to do
            (t nil)))))

    ;; Store the owner struct
    (setf (brand-definition-owner-struct brand-def) struct-name)

    ;; Store in *brand-definitions* keyed by (brand-name . struct-type)
    (setf (gethash (cons brand-name struct-name) *brand-definitions*) brand-def)
    (log:info "Registered brand definition: ~a for struct ~a (base: ~a, subst: ~a, enforce: ~a~a)"
              brand-name struct-name base-type subst-mode
              (brand-definition-enforce-mode brand-def)
              (cl:cond (is-parameterized ", PARAMETERIZED")
                    (skip-global ", SKIP-GLOBAL")
                    (t "")))

    ;; Register the type based on active/inactive status.
    ;; Skip global registration for parameterized brands (resolved lazily per owner)
    ;; and for brands already globally registered by another owner (skip-global).
    (cl:cond
      (is-parameterized
       (log:info "Brand ~a is PARAMETERIZED - skipping global type registration (resolved lazily per owner)"
                 brand-name))
      (skip-global
       (log:info "Brand ~a - skip global type registration (already registered by first owner with same base-type ~a)"
                 brand-name base-type))
      ((brand-active-p brand-def)
       (log:info "Brand ~a is ACTIVE - registering as derived type of ~a with :subst ~a"
                 brand-name base-type subst-mode)
       (register-derived-type brand-name base-type subst-mode))
      (t
       (log:info "Brand ~a is INACTIVE - registering as type alias for ~a"
                 brand-name base-type)
       (setf (gethash brand-name *crisp-type-aliases*) base-type)))))

;;; =========================================================
;;; Brand Instance Differentiation
;;; =========================================================


(defun resolve-brand-type (brand-name var-ref &optional base-type)
  "Resolves a branded type for a specific variable instance.
   Returns a gensym'd type name unique to (brand-name, var-ref [, base-type]).

   When BASE-TYPE is supplied the gensym is registered as a :descendant of
   BASE-TYPE directly.  BASE-TYPE is first normalized against the type registries
   to handle package mismatches: unmangle-template-struct-name creates symbols in
   crisp.compiler (the cell type's package) while user structs are stored in
   crisp-language (Fix D reads source files in that package).  A name-based scan
   of *type-derivation-graph* then *crisp-structs* finds the canonical symbol.

   When BASE-TYPE is NIL, the gensym is registered as a :descendant of
   brand-name (original behaviour, used by fake-cell / template brands).

   In all cases the gensym is stored in *brand-instance-types* under brand-name
   so that resolve-dominance can block cross-instance arithmetic."
  (cl:let* ((cache-key (if base-type
                           (list brand-name var-ref base-type)
                           (cons brand-name var-ref)))
            (cached (gethash cache-key *brand-instance-cache*)))
    (or cached
        (cl:let* ((gensym-name (gensym (format nil "~a-" brand-name)))
                  ;; Normalize base-type to the canonical symbol in the type
                  ;; registries.  Fast path: symbol already findable by eq.
                  ;; Slow path: name-based scan for package-mismatch cases.
                  (canonical-base
                   (when (and base-type (symbolp base-type))
                     (or
                      ;; Fast path: already canonical
                      (and (or (gethash base-type *type-derivation-graph*)
                               (gethash base-type *crisp-types*)
                               (gethash base-type *crisp-structs*))
                           base-type)
                      ;; Slow path: same-named symbol in a different package
                      (cl:let ((name (symbol-name base-type)))
                        (or (block found
                              (maphash (lambda (k v)
                                         (declare (ignore v))
                                         (when (and (symbolp k)
                                                    (string= (symbol-name k) name))
                                           (return-from found k)))
                                       *type-derivation-graph*)
                              nil)
                            (block found
                              (maphash (lambda (k v)
                                         (declare (ignore v))
                                         (when (and (symbolp k)
                                                    (string= (symbol-name k) name))
                                           (return-from found k)))
                                       *crisp-structs*)
                              nil))))))
                  (ancestor (or canonical-base base-type brand-name)))
          (cl:when (and base-type canonical-base (not (eq base-type canonical-base)))
            (log:info "resolve-brand-type: normalized ~s -> ~s (package mismatch)"
                      base-type canonical-base))
          ;; Register gensym directly against the chosen ancestor.
          (register-derived-type gensym-name ancestor :descendant)
          ;; Track under brand-name so resolve-dominance works across all
          ;; element types of the same brand name.
          (setf (gethash gensym-name *brand-instance-types*) brand-name)
          (setf (gethash cache-key *brand-instance-cache*) gensym-name)
          (log:info "Created brand instance type ~a for (~a ~a) [ancestor: ~a]"
                    gensym-name brand-name var-ref ancestor)
          gensym-name))))

;;; =========================================================
;;; Brand Validation
;;; =========================================================

(defun validate-dependent-brand-types (declare-forms env)
  "Verifies that any parameters typed as (brand var) refer to a valid owner parameter.
   Scans the raw declarations to find dependencies that parse-type-specifier might have flattened.
   Supports shared brands (same brand name defined on multiple structs).
   Uses find-brand-for-owner for alias resolution (e.g., FC-INT -> FAKE-CELL_INT_GLOBAL_READ-WRITE)."
  (loop for decl in declare-forms do
          (labels ((scan (form)
                         (cl:cond
                          ((and (listp form)
                                (symbolp (car form))
                                (is-brand-type-p (car form))
                                (= (length form) 2)
                                (symbolp (second form)))
                            ;; Found (BRAND VAR) candidate
                            (cl:let ((brand-name (car form))
                                  (var-ref (second form)))
                              ;; Check var exists in env
                              (cl:let ((param (find var-ref env :key #'parameter-def-name)))
                                (cl:unless param
                                  (error "Brand dependency ~a refers to unknown parameter ~a." form var-ref))

                                (cl:let ((owner-type (parameter-def-type param)))
                                  ;; Check if this specific (Brand . OwnerType) pair is defined
                                  ;; Uses find-brand-for-owner which resolves aliases
                                  (cl:unless (find-brand-for-owner brand-name owner-type)
                                    ;; Not defined for this specific owner.
                                    ;; Retrieve *any* definition to give a helpful error message.
                                    (cl:let ((any-def (is-brand-type-p brand-name)))
                                      (error "Brand dependency mismatch: ~a is defined for owner ~a, but ~a is of type ~a (and no shared definition found)."
                                        brand-name
                                        (if any-def (brand-definition-owner-struct any-def) "UNKNOWN")
                                        var-ref owner-type)))))))
                          ((consp form)
                            (scan (car form))
                            (scan (cdr form))))))
            (scan decl))))


(defun %find-brand-owner-var (brand-name sig-params arg-nodes)
  "Finds the actual argument variable for the parameter that owns the brand instance.
   Handles shared brands by checking if any parameter's type is a registered owner
   for the given BRAND-NAME. Uses find-brand-for-owner for alias resolution."
  (loop for sp in sig-params
        for an in arg-nodes
        for param-type = (parameter-def-type sp)
          ;; Check if this parameter's type is a registered owner for the brand
          when (find-brand-for-owner brand-name param-type)
        do (cl:return (if (typep an 'semantic-var-read)
                          (semantic-var-read-name an)
                          nil))))


;;; =========================================================
;;; Parameterized Brand Support
;;; =========================================================
;;;
;;; When a brand's base type is a template parameter (e.g., (brand value-t T ...)),
;;; different template specializations register the same brand name with different
;;; base types. This makes global type registration impossible.
;;;
;;; Solution: detect the conflict reactively in register-brand-definition,
;;; skip global registration, and resolve (brand-name var) lazily in
;;; parse-function-declarations where we have the environment context.

(defvar *parameterized-brand-names* (make-hash-table :test 'eq)
  "Set of brand names whose base type varies across template specializations.
   These brands skip global type registration and are resolved lazily per-owner.")

;; src/types/brand.lisp
(defun resolve-owner-type-to-mangled (type-spec)
  "Resolves a type specifier (which may be an alias like FC-INT) to its
   canonical mangled form (like FAKE-CELL_INT_GLOBAL_READ-WRITE).
   Used for looking up per-owner brand definitions."
  (cl:let ((canonical (canonicalize-type-specifier type-spec)))
    (cl:cond
      ((and (listp canonical) (> (length canonical) 1))
       (mangle-template-struct-name (first canonical) (rest canonical)))
      ((and (listp canonical) (= (length canonical) 1))
       (first canonical))
      (t canonical))))

;; src/types/brand.lisp
(defun find-brand-for-owner (brand-name owner-type)
  "Looks up a brand definition for the given brand name and owner type.
   Resolves type aliases (e.g., FC-INT -> FAKE-CELL_INT_GLOBAL_READ-WRITE)
   before lookup."
  (or (gethash (cons brand-name owner-type) *brand-definitions*)
      ;; Try resolving the owner type alias
      (cl:let ((resolved (resolve-owner-type-to-mangled owner-type)))
        (cl:when (and resolved (not (eq resolved owner-type)))
          (log:debug "Brand lookup: resolved owner ~a -> ~a" owner-type resolved)
          (gethash (cons brand-name resolved) *brand-definitions*)))))

;; src/types/brand.lisp
(defun resolve-parameterized-brand-in-env (brand-spec env)
  "Resolves a parameterized brand application (brand-name var-ref) using
   the function environment. Returns the concrete base type for the brand
   based on the variable's owner type.
   For inactive brands, returns the base type directly (transparent).
   For active brands, returns the base type (instance differentiation
   happens later in analyze-function-call)."
  (cl:let* ((brand-name (first brand-spec))
            (var-ref (second brand-spec)))
    ;; Find the variable in the environment
    (cl:let ((param (find var-ref env :key #'parameter-def-name)))
      (if param
          (cl:let* ((owner-type (parameter-def-type param))
                    (brand-def (find-brand-for-owner brand-name owner-type)))
            (if brand-def
                (cl:let ((base-type (brand-definition-base-type brand-def)))
                  (log:info "Resolved parameterized brand (~a ~a): owner ~a -> base type ~a"
                            brand-name var-ref owner-type base-type)
                  base-type)
                (progn
                  (log:warn "No brand definition found for (~a . ~a), returning brand-name as fallback"
                            brand-name owner-type)
                  brand-name)))
          (progn
            (log:warn "Variable ~a not found in env for parameterized brand ~a, returning spec as-is"
                      var-ref brand-name)
            brand-spec)))))
