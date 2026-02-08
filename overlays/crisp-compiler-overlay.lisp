;;;; overlays/crisp-compiler-overlay.lisp
;;;;
;;;; Runtime patches for compiler improvements
;;;; Applied via late binding - last definition wins

(in-package :crisp.compiler)

;;; =========================================================
;;; set-derived : Link two existing struct types in a hierarchy
;;; =========================================================
;;; Target: src/types/hierarchy.lisp (register-set-derived)
;;;         src/macros.lisp (set-derived macro)

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
           (incf current-offset (get-std140-size member-type)))

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
           (incf current-offset (get-std140-size member-type))))))
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
                 (error "set-derived: layout mismatch at member index ~a. Ancestor ~a has offset ~a but descendant ~a has offset ~a (std140 alignment difference)."
                        idx ancestor-name a-offset descendant-name d-offset))))))


;; --- The set-derived macro ---
;; src/macros.lisp
(defmacro set-derived (ancestor-type descendant-type)
  "Links two existing struct types in a type hierarchy.
   The descendant can implicitly pass where the ancestor is expected.
   Generates as-<ancestor> and as-<descendant> casting functions.

   Syntax: (set-derived ancestor-type descendant-type)

   Requirements:
   - Both types must be structs (or derived from structs)
   - Ancestor size <= Descendant size
   - Shape compatible (flattened data members match in type and byte offset)
   - No cycles in the type DAG"

  (cl:let* ((pkg (cl:symbol-package ancestor-type))
            (as-ancestor-name (cl:intern (format nil "AS-~a" ancestor-type) pkg))
            (as-descendant-name (cl:intern (format nil "AS-~a" descendant-type) pkg)))
    `(progn
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (register-set-derived ',ancestor-type ',descendant-type))

       ;; Register expression analyzers for casting (if not already present)
       (eval-when (:compile-toplevel :load-toplevel :execute)
         (cl:unless (gethash ',as-ancestor-name *expression-analyzers*)
           (setf (gethash ',as-ancestor-name *expression-analyzers*)
             #'analyze-cast-expression)
           (log:debug "set-derived: registered expression analyzer for ~a" ',as-ancestor-name))
         (cl:unless (gethash ',as-descendant-name *expression-analyzers*)
           (setf (gethash ',as-descendant-name *expression-analyzers*)
             #'analyze-cast-expression)
           (log:debug "set-derived: registered expression analyzer for ~a" ',as-descendant-name))))))

