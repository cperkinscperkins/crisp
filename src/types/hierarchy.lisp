;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/types/hierarchy.lisp
(in-package :crisp.compiler)

;;; =========================================================
;;; Type Derivation Hierarchy (DAG)
;;; =========================================================

(defstruct type-node
  "Represents a type in the derivation hierarchy (DAG).
   Used for both 'real' types (scalars, structs) and derived types."
  (type-name nil :type symbol) ; e.g., 'meters', 'point', 'int'
  (original-type nil :type symbol) ; Immediate parent in derivation (nil for real types)
  (base-type nil :type symbol) ; Root 'real' type (memoized for fast lookup)
  (subst-mode nil :type symbol) ; :descendant, :ancestor, :equal, :no (nil for real types)
  (ancestors nil :type list) ; Immediate more-general types
  (descendants nil :type list)) ; Immediate more-specific types

(defvar *type-derivation-graph* (make-hash-table)
        "Maps type-name (symbol) -> type-node for all types (real and derived).")

;;; Initialization
;;; ==============

(defun initialize-type-hierarchy ()
  "Initializes the type derivation graph (starts empty).
   User-defined derived types will be added via def-derived-type.
   Built-in numeric types use the existing size-based promotion system."
  (log:info "Initializing type derivation hierarchy")
  (clrhash *type-derivation-graph*)
  (log:info "Type derivation graph initialized (empty - will be populated by def-derived-type)"))

(defun create-root-type-node (type-name)
  "Creates a root type node for a built-in 'real' type with no derivation relationships."
  (setf (gethash type-name *type-derivation-graph*)
    (make-type-node :type-name type-name
                    :original-type nil
                    :base-type type-name
                    :subst-mode nil
                    :ancestors nil
                    :descendants nil))
  (log:debug "Created root type node: ~a" type-name))

(defun create-numeric-hierarchy (type-names)
  "Creates a linked hierarchy of numeric types.
   type-names should be ordered from most specific to most general.
   Example: '(char short int long) creates char -> short -> int -> long."
  (unless type-names
    (return-from create-numeric-hierarchy nil))

  (cl:let ((nodes nil))
    ;; Create all nodes first
    (dolist (type-name type-names)
      (cl:let ((node (make-type-node :type-name type-name
                                     :original-type nil ; Real type, not derived
                                     :base-type type-name ; Base is itself
                                     :subst-mode nil
                                     :ancestors nil
                                     :descendants nil)))
        (setf (gethash type-name *type-derivation-graph*) node)
        (push node nodes)
        (log:debug "Created numeric type node: ~a" type-name)))

    (setf nodes (nreverse nodes)) ; Now in order: most specific to most general

    ;; Link them: each node's ancestor is the next node
    ;; char.ancestors = [short], short.ancestors = [int], etc.
    (loop for i from 0 below (1- (length nodes))
          for current-node = (nth i nodes)
          for next-node = (nth (1+ i) nodes)
          do (progn
              ;; Current node can substitute for next node (current is more specific)
              (setf (type-node-ancestors current-node)
                (list (type-node-type-name next-node)))

              ;; Next node has current as descendant
              (push (type-node-type-name current-node)
                    (type-node-descendants next-node))

              (log:debug "Linked ~a -> ~a (ancestor)"
                         (type-node-type-name current-node)
                         (type-node-type-name next-node))))))

;;; Query Functions
;;; ===============

(defun is-substitutable-for? (source-type target-type)
  "Returns T if SOURCE-TYPE can be used where TARGET-TYPE is expected.
   This is the fundamental 'Can I put peg A in hole B?' check.

   Algorithm:
   - If types are equal, return T
   - Walk UP from source through ancestors to find target
   - Handles cycles (from :equal relationships) via visited tracking"
  (cl:cond
    ((eq source-type target-type) t)
    (t (has-ancestor-path? source-type target-type (make-hash-table)))))

(defun types-assignable-p (source-type target-type)
  "Checks if source-type can be assigned to target-type.
   This is true if:
   1. The types feature exact equivalence (types-equivalent-p)
   2. The source type represents a derived type that is substitutable for the target (is-substitutable-for?)"
  (or (types-equivalent-p source-type target-type)
      (and (symbolp source-type)
           (symbolp target-type)
           (is-substitutable-for? source-type target-type))))

(defun has-ancestor-path? (from-type to-type visited)
  "Walk UP through ancestors from FROM-TYPE to find TO-TYPE.
   Returns T if path exists, NIL otherwise.
   VISITED hash table prevents infinite loops (from :equal cycles)."
  ;; Cycle detection
  (cl:when (gethash from-type visited)
    (return-from has-ancestor-path? nil))

  (setf (gethash from-type visited) t)

  ;; Package-agnostic lookup
  (cl:let* ((node-direct (gethash from-type *type-derivation-graph*))
            (node-alt (cl:when (and (not node-direct) (symbolp from-type))
                        (gethash (cl:intern (cl:symbol-name from-type)
                                            (cl:find-package :crisp-language))
                                 *type-derivation-graph*)))
            (node (or node-direct node-alt)))
    (cl:unless node
      (log:debug "Type ~a not found in derivation graph" from-type)
      (return-from has-ancestor-path? nil))

    ;; Check each ancestor
    (dolist (ancestor (type-node-ancestors node))
      (cl:when (or (eq ancestor to-type)
                   (has-ancestor-path? ancestor to-type visited))
        (return-from has-ancestor-path? t))))

  nil)

(defun get-type-base (type-name)
  "Returns the base 'real' type for a given type (derived or real).
   If the type is not in the derivation graph, returns the type itself."
  ;; Handle package mismatches - try both current package and CRISP-LANGUAGE
  (cl:let* ((node-direct (gethash type-name *type-derivation-graph*))
            (node-alt (cl:when (and (not node-direct) (symbolp type-name))
                        (gethash (cl:intern (cl:symbol-name type-name)
                                            (cl:find-package :crisp-language))
                                 *type-derivation-graph*)))
            (node (or node-direct node-alt)))
    (cl:if node
           (type-node-base-type node)
           ;; Not a derived type, return as-is
           type-name)))

(defun get-reachable-types (type-name)
  "Returns a list of all types that TYPE-NAME can substitute for (including itself).
   Uses BFS to walk up the ancestor graph, plus handles :equal relationships.
   Returns types in order from closest to farthest (BFS order)."
  (cl:let ((reachable '())
           (visited (make-hash-table))
           (queue (list type-name)))
    (cl:loop while queue
    do (cl:let ((current (pop queue)))
         (cl:unless (gethash current visited)
           (setf (gethash current visited) t)
           (push current reachable)
           ;; Get node with package-agnostic lookup
           (cl:let* ((node-direct (gethash current *type-derivation-graph*))
                     (node-alt (cl:when (and (not node-direct) (symbolp current))
                                 (gethash (intern (symbol-name current)
                                                  (find-package :crisp-language))
                                          *type-derivation-graph*)))
                     (node (or node-direct node-alt)))
             (cl:when node
               ;; Add ancestors to queue
               (dolist (ancestor (type-node-ancestors node))
                 (push ancestor queue))
               ;; For :equal relationships, also add descendants
               ;; (since equal types can substitute for each other)
               (cl:when (eq (type-node-subst-mode node) :equal)
                 (dolist (desc (type-node-descendants node))
                   (push desc queue))))))))
    (nreverse reachable)))

(defun find-common-promoted-type (type-a type-b)
  "Finds the best common type for promotion in binary operations.
   Returns the closest common type that both can substitute for.

   Algorithm:
   1. Calculate all types type-a can reach (substitute for)
   2. Calculate all types type-b can reach
   3. Find intersection
   4. Return the first common type in type-a's reachable list (closest to type-a)

   Returns NIL if no common type exists."
  (cl:let* ((reachable-a (get-reachable-types type-a))
            (reachable-b (get-reachable-types type-b))
            ;; Find common types
            (common (intersection reachable-a reachable-b :test #'eq)))
    (cl:cond
      ((null common) nil) ; No common type - incompatible
      ;; Return the first common type in reachable-a's order
      ;; (this is the closest to type-a in the hierarchy)
      (t (dolist (type reachable-a nil)
           (cl:when (member type common :test #'eq)
             (cl:return type)))))))



(defun resolve-dominance (type-a type-b)
  "Determines which type dominates in arithmetic operations.
   Returns the dominant type, or NIL if the types cannot mix.

   Brand-instance rules are applied BEFORE substitutability so that a brand
   instance always wins over the plain type it descends from:
   - Same type: return it.
   - Both instances of the SAME brand (different vars): cannot mix -> NIL.
   - One brand instance, one non-brand: brand instance dominates.
   - Neither is a brand instance: standard substitutability /
     find-common-promoted-type."
  (cl:cond
    ((eq type-a type-b) type-a)

    (t
     (cl:let ((brand-a (and (boundp '*brand-instance-types*)
                            (gethash type-a *brand-instance-types*)))
              (brand-b (and (boundp '*brand-instance-types*)
                            (gethash type-b *brand-instance-types*))))
       (cl:cond
         ;; Both brand instances of the SAME brand -> cannot mix
         ((and brand-a brand-b (eq brand-a brand-b))
          (log:debug "resolve-dominance: blocking cross-instance mix of ~a and ~a (both brand ~a)"
                     type-a type-b brand-a)
          nil)

         ;; A is a brand instance, B is not -> A dominates unconditionally
         ((and brand-a (not brand-b))
          (log:debug "resolve-dominance: brand instance ~a dominates non-brand ~a"
                     type-a type-b)
          type-a)

         ;; B is a brand instance, A is not -> B dominates unconditionally
         ((and brand-b (not brand-a))
          (log:debug "resolve-dominance: brand instance ~a dominates non-brand ~a"
                     type-b type-a)
          type-b)

         ;; Neither is a brand instance -> standard type rules
         ((is-substitutable-for? type-a type-b)
          (log:debug "resolve-dominance: ~a substitutable for ~a -> ~a dominates"
                     type-a type-b type-b)
          type-b)
         ((is-substitutable-for? type-b type-a)
          (log:debug "resolve-dominance: ~a substitutable for ~a -> ~a dominates"
                     type-b type-a type-a)
          type-a)
         (t
          (log:debug "resolve-dominance: find-common-promoted-type ~a ~a"
                     type-a type-b)
          (find-common-promoted-type type-a type-b)))))))

;;; Derived Type Registration
;;; =========================

(defun compute-base-type (original-type-name)
  "Walks the original-type chain to find the root 'real' type.
   Returns the base type name, or NIL if not found."
  (cl:let ((node (gethash original-type-name *type-derivation-graph*)))
    (cl:if node
           (cl:if (type-node-original-type node)
                  ;; Has an original, keep walking
                  (compute-base-type (type-node-original-type node))
                  ;; No original-type means this IS the base
                  original-type-name)
           ;; Not in graph yet - could be a struct or other type
           ;; For now, assume it's a base type
           original-type-name)))

(defun register-derived-type (new-type-name original-type-name subst-mode)
  "Registers a new derived type in the type derivation graph.

   Parameters:
   - new-type-name: Symbol for the new derived type
   - original-type-name: Symbol for the type being derived from
   - subst-mode: One of :no, :equal, :descendant, :ancestor

   Validates:
   - Original type must exist (in *type-derivation-graph*, *crisp-types*, or *crisp-structs*)
   - Subst-mode must be valid

   Updates:
   - Creates new type-node with computed base-type
   - Updates ancestor/descendant relationships based on subst-mode"

  (log:debug "Registering derived type ~a from ~a with subst-mode ~a"
             new-type-name original-type-name subst-mode)

  ;; Resolve type aliases first - if original-type is an alias, resolve it
  (cl:let ((resolved-original (resolve-type-alias original-type-name)))
    (cl:when (not (eq resolved-original original-type-name))
      (log:debug "Resolved alias ~a to ~a" original-type-name resolved-original)
      (setf original-type-name resolved-original)))

  ;; Check for existing definition in derivation graph (Idempotency Check)
  (cl:let ((existing-node (gethash new-type-name *type-derivation-graph*)))
    (cl:when existing-node
      ;; If it exists, check if it's identical
      (cl:if (and (eq (type-node-type-name existing-node) new-type-name)
                  (eq (type-node-original-type existing-node) original-type-name)
                  (eq (type-node-subst-mode existing-node) subst-mode))
             (cl:progn
               (log:info "Type ~a already registered with identical definition. Skipping re-registration." new-type-name)
               (return-from register-derived-type new-type-name))
             ;; Different definition -> Error!
             (error "Cannot define derived type ~a: type already exists with DIFFERENT definition (Original: ~a, New: ~a)."
               new-type-name (type-node-original-type existing-node) original-type-name))))

  ;; Validate new type name does not collide with existing NON-DERIVED types
  (cl:when (or (gethash new-type-name *crisp-types*)
               (gethash new-type-name *crisp-structs*)
               (gethash new-type-name *crisp-enums*)
               (and (boundp '*crisp-type-aliases*)
                    (gethash new-type-name *crisp-type-aliases*)))
    (error "Cannot define derived type ~a: name collides with existing type/struct/enum." new-type-name))

  ;; Validate original type exists (in derivation graph, types, structs, or aliases)
  (cl:unless (or (gethash original-type-name *type-derivation-graph*)
                 (gethash original-type-name *crisp-types*)
                 (gethash original-type-name *crisp-structs*)
                 (and (boundp '*crisp-type-aliases*)
                      (gethash original-type-name *crisp-type-aliases*)))
    (error "Cannot derive type ~a from ~a: original type does not exist (single-pass semantics violation)"
      new-type-name original-type-name))

  ;; Validate subst-mode
  (cl:unless (member subst-mode '(:no :equal :descendant :ancestor))
    (error "Invalid subst-mode ~a for derived type ~a. Must be :no, :equal, :descendant, or :ancestor"
      subst-mode new-type-name))

  ;; Compute base type
  (cl:let ((base-type (compute-base-type original-type-name)))
    (log:debug "Computed base type for ~a: ~a" new-type-name base-type)

    ;; Ensure original type has a node in the graph (for establishing relationships)
    ;; If it's not already there, create a basic "real type" node for it
    (cl:unless (gethash original-type-name *type-derivation-graph*)
      (setf (gethash original-type-name *type-derivation-graph*)
        (make-type-node :type-name original-type-name
                        :original-type nil ; It's a real type
                        :base-type original-type-name ; Base is itself
                        :subst-mode nil
                        :ancestors nil
                        :descendants nil))
      (log:debug "Created implicit node for original type ~a" original-type-name))

    ;; Create new type node
    (cl:let ((new-node (make-type-node :type-name new-type-name
                                       :original-type original-type-name
                                       :base-type base-type
                                       :subst-mode subst-mode
                                       :ancestors nil
                                       :descendants nil)))

      ;; Update relationships based on subst-mode
      (cl:cond
        ;; Case 1: :descendant - new type is more specific than original
        ((eq subst-mode :descendant)
         (setf (type-node-ancestors new-node) (list original-type-name))
         ;; Update original's descendants
         (cl:let ((orig-node (gethash original-type-name *type-derivation-graph*)))
           (push new-type-name (type-node-descendants orig-node)))
         (log:debug "~a is descendant of ~a (can substitute for original)"
                    new-type-name original-type-name))

        ;; Case 2: :ancestor - new type is more general than original
        ((eq subst-mode :ancestor)
         ;; New type has no ancestors from this relationship (it's more general)
         (setf (type-node-ancestors new-node) nil)
         ;; Update original's ancestors
         (cl:let ((orig-node (gethash original-type-name *type-derivation-graph*)))
           (push new-type-name (type-node-ancestors orig-node)))
         (log:debug "~a is ancestor of ~a (original can substitute for new)"
                    new-type-name original-type-name))

        ;; Case 3: :equal - bidirectional substitution
        ;; For :equal, we create bidirectional substitution by adding to BOTH
        ;; ancestors and descendants. Cycle detection in has-ancestor-path? handles this.
        ((eq subst-mode :equal)
         (setf (type-node-ancestors new-node) (list original-type-name))
         (setf (type-node-descendants new-node) (list original-type-name))
         ;; Update original's descendants AND ANCESTORS
         (cl:let ((orig-node (gethash original-type-name *type-derivation-graph*)))
           (push new-type-name (type-node-descendants orig-node))
           (push new-type-name (type-node-ancestors orig-node)))
         (log:debug "~a is equal to ~a (bidirectional substitution)"
                    new-type-name original-type-name))

        ;; Case 4: :no - no substitution relationship
        ((eq subst-mode :no)
         ;; No relationships added
         (log:debug "~a has no substitution relationship with ~a"
                    new-type-name original-type-name))

        (t
         (error "Unexpected subst-mode ~a" subst-mode)))

      ;; Register the new node
      (setf (gethash new-type-name *type-derivation-graph*) new-node)

      ;; Also register in *crisp-types* so type checking and casting work correctly
      ;; Derived types have identical memory layout to their base type
      (cl:let ((base-crisp-type (or (gethash base-type *crisp-types*)
                                    (gethash base-type *crisp-structs*))))
        (cl:cond
          ;; Base is a built-in type (int, float, etc.)
          ((crisp-type-p base-crisp-type)
           (setf (gethash new-type-name *crisp-types*)
             (make-crisp-type :name new-type-name
                              :llvm-type-fn (crisp-type-llvm-type-fn base-crisp-type)
                              :size (crisp-type-size base-crisp-type)
                              :category (crisp-type-category base-crisp-type)))
           (log:debug "Registered ~a in *crisp-types* (base type category: ~a)"
                      new-type-name (crisp-type-category base-crisp-type)))

          ;; Base is a struct
          ((crisp-struct-definition-p base-crisp-type)
           ;; For structs, we need to create a crisp-type entry
           ;; The LLVM type function should return the struct's LLVM type
           (setf (gethash new-type-name *crisp-types*)
             (make-crisp-type :name new-type-name
                              :llvm-type-fn (lambda (module)
                                              (crisp-type-to-llvm-type base-type module))
                              :size 0 ; Structs don't have a fixed bit size
                              :category :struct))
           (log:debug "Registered ~a in *crisp-types* (struct derived from ~a)"
                      new-type-name base-type))

          (t
           (log:warn "Could not register ~a in *crisp-types*: base type ~a not found"
                     new-type-name base-type))))

      (log:info "Registered derived type ~a (base: ~a, subst: ~a)"
                new-type-name base-type subst-mode)

      new-type-name)))



(defun register-set-derived (ancestor-type-name descendant-type-name)
  "Registers a set-derived relationship between two existing struct types.
   The descendant can implicitly substitute for the ancestor (like :descendant subst-mode).

   Parameters:
   - ancestor-type-name: The 'smaller' or contained type
   - descendant-type-name: The 'larger' or extension type

   Validates:
   - Both types must exist
   - Both must be structs (or derived from structs) -- not records, scalars, functions, or enums
   - Ancestor size <= Descendant size
   - Shape compatibility (flattened data members with matching types and byte offsets)
   - No cycles in the type hierarchy DAG"

  (log:info "register-set-derived: linking ~a (ancestor) -> ~a (descendant)"
            ancestor-type-name descendant-type-name)

  ;; --- Validation: Both types must exist ---
  (cl:let* ((ancestor-base (get-type-base ancestor-type-name))
            (descendant-base (get-type-base descendant-type-name))
            (ancestor-struct (or (gethash ancestor-base *crisp-structs*)
                                 (cl:when (symbolp ancestor-base)
                                   (gethash (cl:intern (cl:symbol-name ancestor-base)
                                                       (cl:find-package :crisp-language))
                                            *crisp-structs*))))
            (descendant-struct (or (gethash descendant-base *crisp-structs*)
                                   (cl:when (symbolp descendant-base)
                                     (gethash (cl:intern (cl:symbol-name descendant-base)
                                                         (cl:find-package :crisp-language))
                                              *crisp-structs*)))))

    ;; --- Validation: No self-reference ---
    (cl:when (eq ancestor-type-name descendant-type-name)
      (error "set-derived: a type cannot derive from itself. ~a is not amused by your attempt at recursive self-improvement."
             ancestor-type-name))

    ;; --- Validation: Both must be structs ---
    (cl:unless ancestor-struct
      (cl:let ((in-types (gethash ancestor-type-name *crisp-types*))
               (in-enums (gethash ancestor-type-name *crisp-enums*)))
        (cl:cond
          (in-enums
           (error "set-derived: ancestor type ~a is an enumeration. Only structs (or types derived from structs) are permitted."
                  ancestor-type-name))
          (in-types
           (error "set-derived: ancestor type ~a is not a struct. Only structs (or types derived from structs) are permitted."
                  ancestor-type-name))
          (t
           (error "set-derived: ancestor type ~a does not exist." ancestor-type-name)))))

    (cl:unless descendant-struct
      (cl:let ((in-types (gethash descendant-type-name *crisp-types*))
               (in-enums (gethash descendant-type-name *crisp-enums*)))
        (cl:cond
          (in-enums
           (error "set-derived: descendant type ~a is an enumeration. Only structs (or types derived from structs) are permitted."
                  descendant-type-name))
          (in-types
           (error "set-derived: descendant type ~a is not a struct. Only structs (or types derived from structs) are permitted."
                  descendant-type-name))
          (t
           (error "set-derived: descendant type ~a does not exist." descendant-type-name)))))

    ;; --- Validation: Must be structs, not records ---
    ;; Category is stored in *crisp-types*, not in crisp-struct-definition
    (cl:let ((ancestor-crisp-type (or (gethash ancestor-type-name *crisp-types*)
                                      (gethash ancestor-base *crisp-types*)))
             (descendant-crisp-type (or (gethash descendant-type-name *crisp-types*)
                                        (gethash descendant-base *crisp-types*))))
      (cl:when (and ancestor-crisp-type (eq (crisp-type-category ancestor-crisp-type) :record))
        (error "set-derived: ancestor type ~a is a record. set-derived only works with structs."
               ancestor-type-name))
      (cl:when (and descendant-crisp-type (eq (crisp-type-category descendant-crisp-type) :record))
        (error "set-derived: descendant type ~a is a record. set-derived only works with structs."
               descendant-type-name)))

    ;; --- Validation: Ancestor size <= Descendant size ---
    (cl:let ((ancestor-size (crisp-struct-definition-total-size ancestor-struct))
             (descendant-size (crisp-struct-definition-total-size descendant-struct)))
      (cl:when (> ancestor-size descendant-size)
        (error "set-derived: ancestor ~a (size ~a bytes) is larger than descendant ~a (size ~a bytes). The ancestor must be smaller or equal."
               ancestor-type-name ancestor-size descendant-type-name descendant-size)))

    ;; --- Validation: Shape compatibility ---
    (validate-set-derived-shape ancestor-struct descendant-struct
                                ancestor-type-name descendant-type-name)

    ;; --- Validation: No cycles ---
    ;; Check if adding this edge would create a cycle:
    ;; descendant's ancestors will include ancestor. If ancestor can already
    ;; reach descendant by walking UP through ancestors, we have a cycle.
    (cl:when (is-substitutable-for? ancestor-type-name descendant-type-name)
      (error "set-derived: adding ~a -> ~a would create a cycle in the type hierarchy. The compiler disapproves of your circular reasoning."
             ancestor-type-name descendant-type-name))

    ;; --- Registration: Ensure both have type-nodes ---
    (cl:unless (gethash ancestor-type-name *type-derivation-graph*)
      (setf (gethash ancestor-type-name *type-derivation-graph*)
        (make-type-node :type-name ancestor-type-name
                        :original-type nil
                        :base-type ancestor-type-name
                        :subst-mode nil
                        :ancestors nil
                        :descendants nil))
      (log:debug "Created implicit type-node for ~a" ancestor-type-name))

    (cl:unless (gethash descendant-type-name *type-derivation-graph*)
      (setf (gethash descendant-type-name *type-derivation-graph*)
        (make-type-node :type-name descendant-type-name
                        :original-type nil
                        :base-type descendant-type-name
                        :subst-mode nil
                        :ancestors nil
                        :descendants nil))
      (log:debug "Created implicit type-node for ~a" descendant-type-name))

    ;; --- Registration: Link ancestor <-> descendant ---
    (cl:let ((ancestor-node (gethash ancestor-type-name *type-derivation-graph*))
             (descendant-node (gethash descendant-type-name *type-derivation-graph*)))

      ;; Add ancestor to descendant's ancestors (if not already there)
      (cl:unless (member ancestor-type-name (type-node-ancestors descendant-node))
        (push ancestor-type-name (type-node-ancestors descendant-node)))

      ;; Add descendant to ancestor's descendants (if not already there)
      (cl:unless (member descendant-type-name (type-node-descendants ancestor-node))
        (push descendant-type-name (type-node-descendants ancestor-node))))

    (log:info "set-derived: successfully linked ~a (ancestor) -> ~a (descendant)"
              ancestor-type-name descendant-type-name)
    descendant-type-name))


(defun flatten-struct-data-members (struct-def)
  "Recursively flattens a struct definition to its scalar data members.
   Returns a list of (type byte-offset) pairs, skipping padding fields.
   Nested structs are expanded recursively."
  (cl:let ((members (crisp-struct-definition-padded-members struct-def))
           (result '())
           (current-offset 0))
    (dolist (member members)
      (cl:let* ((member-name (first member))
                (member-type (second member))
                (member-name-str (cl:symbol-name member-name))
                (is-padding (and (> (length member-name-str) 4)
                                 (string= (subseq member-name-str 0 4) "_PAD"))))
        (cl:cond
          ;; Skip padding fields but count their size
          (is-padding
           (incf current-offset (get-native-size member-type)))

          ;; Nested struct -> recurse
          ((cl:let* ((base (get-type-base member-type))
                     (nested (or (gethash base *crisp-structs*)
                                 (cl:when (symbolp base)
                                   (gethash (cl:intern (cl:symbol-name base)
                                                       (cl:find-package :crisp-language))
                                            *crisp-structs*)))))
             (cl:when nested
               (cl:let ((nested-flat (flatten-struct-data-members nested)))
                 (dolist (entry nested-flat)
                   (push (list (first entry) (+ current-offset (second entry))) result))
                 (incf current-offset (crisp-struct-definition-total-size nested))
                 t))))

          ;; Scalar data member
          (t
           (push (list member-type current-offset) result)
           (incf current-offset (get-native-size member-type))))))
    (nreverse result)))


(defun validate-set-derived-shape (ancestor-struct descendant-struct
                                   ancestor-name descendant-name)
  "Validates shape compatibility for set-derived.
   Flattens both structs and checks that each ancestor data member has a
   matching data member in the descendant with the same type and byte offset."
  (cl:let ((ancestor-flat (flatten-struct-data-members ancestor-struct))
           (descendant-flat (flatten-struct-data-members descendant-struct)))

    (log:debug "Shape check: ~a flat=~s, ~a flat=~s"
               ancestor-name ancestor-flat descendant-name descendant-flat)

    ;; Ancestor must not have more data members than descendant
    (cl:when (> (length ancestor-flat) (length descendant-flat))
      (error "set-derived: ancestor ~a has ~a data members but descendant ~a has only ~a. The descendant must have at least as many."
             ancestor-name (length ancestor-flat) descendant-name (length descendant-flat)))

    ;; Check each ancestor member against corresponding descendant member
    (loop for ancestor-entry in ancestor-flat
          for descendant-entry in descendant-flat
          for idx from 0
          do (cl:let ((a-type (first ancestor-entry))
                      (a-offset (second ancestor-entry))
                      (d-type (first descendant-entry))
                      (d-offset (second descendant-entry)))
               ;; Types must match exactly (resolving aliases)
               (cl:let ((a-resolved (resolve-type-alias a-type))
                        (d-resolved (resolve-type-alias d-type)))
                 (cl:unless (eq a-resolved d-resolved)
                   (error "set-derived: shape mismatch at member index ~a. Ancestor ~a has type ~a but descendant ~a has type ~a. Types must match exactly."
                          idx ancestor-name a-resolved descendant-name d-resolved)))
               ;; Byte offsets must match
               (cl:unless (= a-offset d-offset)
                 (error "set-derived: layout mismatch at member index ~a. Ancestor ~a has offset ~a but descendant ~a has offset ~a."
                        idx ancestor-name a-offset descendant-name d-offset))))))

