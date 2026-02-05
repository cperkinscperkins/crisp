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
  (type-name nil :type symbol)       ; e.g., 'meters', 'point', 'int'
  (original-type nil :type symbol)   ; Immediate parent in derivation (nil for real types)
  (base-type nil :type symbol)       ; Root 'real' type (memoized for fast lookup)
  (subst-mode nil :type symbol)      ; :descendant, :ancestor, :equal, :no (nil for real types)
  (ancestors nil :type list)         ; Immediate more-general types
  (descendants nil :type list))      ; Immediate more-specific types

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
                                   :original-type nil  ; Real type, not derived
                                   :base-type type-name ; Base is itself
                                   :subst-mode nil
                                   :ancestors nil
                                   :descendants nil)))
        (setf (gethash type-name *type-derivation-graph*) node)
        (push node nodes)
        (log:debug "Created numeric type node: ~a" type-name)))

    (setf nodes (nreverse nodes))  ; Now in order: most specific to most general

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

(defun has-ancestor-path? (from-type to-type visited)
  "Walk UP through ancestors from FROM-TYPE to find TO-TYPE.
   Returns T if path exists, NIL otherwise.
   VISITED hash table prevents infinite loops (from :equal cycles)."
  ;; Cycle detection
  (when (gethash from-type visited)
    (return-from has-ancestor-path? nil))

  (setf (gethash from-type visited) t)

  (cl:let ((node (gethash from-type *type-derivation-graph*)))
    (unless node
      (log:debug "Type ~a not found in derivation graph" from-type)
      (return-from has-ancestor-path? nil))

    ;; Check each ancestor
    (dolist (ancestor (type-node-ancestors node))
      (when (or (eq ancestor to-type)
                (has-ancestor-path? ancestor to-type visited))
        (return-from has-ancestor-path? t))))

  nil)

(defun get-type-base (type-name)
  "Returns the base 'real' type for a given type (derived or real).
   If the type is not in the derivation graph, returns the type itself."
  (cl:let ((node (gethash type-name *type-derivation-graph*)))
    (if node
        (type-node-base-type node)
        ;; Not a derived type, return as-is
        type-name)))

(defun resolve-dominance (type-a type-b)
  "Determines which type dominates in arithmetic operations.
   Returns the dominant type, or NIL if they cannot mix.

   Used by get-promoted-type for binary operations like +, -, *, /.

   Rules:
   - If same type, return it
   - If one can substitute for other, return the more general (target)
   - If both derived from common base, apply dominance rules
   - Otherwise, return NIL (caller should use category + size fallback)"
  (cl:cond
    ((eq type-a type-b) type-a)

    ;; Check substitutability (one dominates)
    ((is-substitutable-for? type-a type-b) type-b)  ; B is more general
    ((is-substitutable-for? type-b type-a) type-a)  ; A is more general

    ;; TODO: Phase 5 - Common base dominance rules
    ;; For now, return NIL to fall back to existing logic
    (t nil)))

;;; Derived Type Registration
;;; =========================

(defun compute-base-type (original-type-name)
  "Walks the original-type chain to find the root 'real' type.
   Returns the base type name, or NIL if not found."
  (cl:let ((node (gethash original-type-name *type-derivation-graph*)))
    (if node
        (if (type-node-original-type node)
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

  ;; Validate original type exists
  (unless (or (gethash original-type-name *type-derivation-graph*)
              (gethash original-type-name *crisp-types*)
              (gethash original-type-name *crisp-structs*))
    (error "Cannot derive type ~a from ~a: original type does not exist (single-pass semantics violation)"
           new-type-name original-type-name))

  ;; Validate subst-mode
  (unless (member subst-mode '(:no :equal :descendant :ancestor))
    (error "Invalid subst-mode ~a for derived type ~a. Must be :no, :equal, :descendant, or :ancestor"
           subst-mode new-type-name))

  ;; Compute base type
  (cl:let ((base-type (compute-base-type original-type-name)))
    (log:debug "Computed base type for ~a: ~a" new-type-name base-type)

    ;; Ensure original type has a node in the graph (for establishing relationships)
    ;; If it's not already there, create a basic "real type" node for it
    (unless (gethash original-type-name *type-derivation-graph*)
      (setf (gethash original-type-name *type-derivation-graph*)
            (make-type-node :type-name original-type-name
                            :original-type nil  ; It's a real type
                            :base-type original-type-name  ; Base is itself
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
       ((eq subst-mode :equal)
        (setf (type-node-ancestors new-node) (list original-type-name))
        (setf (type-node-descendants new-node) (list original-type-name))
        ;; Update original's ancestors AND descendants (bidirectional)
        (cl:let ((orig-node (gethash original-type-name *type-derivation-graph*)))
          (push new-type-name (type-node-ancestors orig-node))
          (push new-type-name (type-node-descendants orig-node)))
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
                                  :size 0  ; Structs don't have a fixed bit size
                                  :category :struct))
           (log:debug "Registered ~a in *crisp-types* (struct derived from ~a)"
                      new-type-name base-type))

          (t
           (log:warn "Could not register ~a in *crisp-types*: base type ~a not found"
                     new-type-name base-type))))

      (log:info "Registered derived type ~a (base: ~a, subst: ~a)"
                new-type-name base-type subst-mode)

      new-type-name)))
