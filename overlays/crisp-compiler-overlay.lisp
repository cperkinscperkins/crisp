;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)



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

    ;; 4. Brands: Check for redefinition with DIFFERENT base type.
    (let ((existing (is-brand-type-p brand-name)))
      (when existing
            (unless (eq (brand-definition-base-type existing) base-type)
              (error "Cannot define derived type ~a: type already exists with DIFFERENT definition (Original: ~a, New: ~a)."
                brand-name (brand-definition-base-type existing) base-type))))

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
;;; Branded Types - Instance Differentiation 
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

                            

;;; =========================================================
;;; Branded Types - Metadata Generation / Hoisting Fix (Test 43)
;;; =========================================================

(in-package :crisp.compiler)



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


;;; =========================================================
;;; Brand Misuse Error
;;; =========================================================

(defmacro brand (&rest args)
  "Catches invalid usage of BRAND outside of DEF-STRUCT or DEF-RECORD."
  (declare (ignore args))
  (error "BRAND can only be used within DEF-STRUCT or DEF-RECORD."))
