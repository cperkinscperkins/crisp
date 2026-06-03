;;;; src/struct-definitions.lisp
;;;;
;;;; Core struct definitions needed early in the compile/load order to prevent
;;;; SBCL style-warnings about previously compiled structure accessors.

(in-package :crisp.compiler)

(defstruct crisp-struct-definition
  "Stores the definition of a user-defined struct."
  (name nil :type symbol)
  (members nil :type list) ; List of (name type-symbol) pairs - Original definition
  (padded-members nil :type list) ; List including _PAD fields 
  (field-indices nil :type hash-table) ; Map of name -> padded-index
  (llvm-type nil) ; Cached LLVM type reference
  (total-size 0 :type integer) ; Total size in bytes (padded)
  (constructor nil) ; Helper function name
  (canonical-type nil) ; For template instantiations, the fully resolved type name
  )

(defstruct brand-definition
  "Stores the definition of a branded type declared inside a struct/record."
  (brand-name nil :type symbol) ; e.g., TOKEN-T
  (base-type nil :type symbol) ; e.g., ULONG
  (subst-mode nil :type symbol) ; :no, :equal, :descendant, :ancestor
  (enforce-mode :diff :type symbol) ; :always or :diff
  (owner-struct nil :type symbol)) ; e.g., SERVER

(defstruct type-node
  "Represents a type in the derivation hierarchy (DAG).
   Used for both 'real' types (scalars, structs) and derived types."
  (type-name nil :type symbol) ; e.g., 'meters', 'point', 'int'
  (original-type nil :type symbol) ; Immediate parent in derivation (nil for real types)
  (base-type nil :type symbol) ; Root 'real' type (memoized for fast lookup)
  (subst-mode nil :type symbol) ; :descendant, :ancestor, :equal, :no (nil for real types)
  (ancestors nil :type list) ; Immediate more-general types
  (descendants nil :type list)) ; Immediate more-specific types

(defstruct template-data
  "Stores the definition of a template function."
  (name nil :type symbol)
  (parameters nil :type list) ; Type parameters, e.g., (T U)
  (constraints nil :type list) ; Constraints from declare, e.g., ((type-is T ...))
  (body nil :type list) ; The full (def-function ...) form
  (signature nil :type list)) ; The declared signature, if any
