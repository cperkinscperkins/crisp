;;;; Crisp - Lisp for Developing GPU Kernels
;;;; Copyright (c) 2025 Christopher Perkins
;;;;
;;;; Licensed under the MIT License. See LICENSE file in the project root.

;; src/semantic.lisp
(in-package :crisp.compiler)

(defstruct crisp-type
  "Represents a Crisp type."
  (name nil :type symbol)
  ;; The function to get the llvm-type-ref.
  ;; We use a function so we don't have to have a live LLVM context
  ;; when we first define all the types.
  (llvm-type-fn nil :type function)
  (size 0 :type integer) ; size in bits
  (category nil :type (member :signed-int :unsigned-int :float)))


(defstruct function-signature
  "Represents the full signature of a Crisp function."
  (name nil :type symbol)
  (parameters nil :type list)
  (return-types nil :type list)
  (source-location nil :type list)
  (is-template-p nil :type boolean)
  (template-params nil :type list))

(defstruct crisp-struct-definition
  "Stores the definition of a user-defined struct."
  (name nil :type symbol)
  (members nil :type list) ; List of (name type-symbol) pairs - Original definition
  (padded-members nil :type list) ; List including _PAD fields - std140 layout
  (field-indices nil :type hash-table) ; Map of name -> padded-index
  (llvm-type nil) ; Cached LLVM type reference
  )

;; Sema Structs
;; ------------

;; blueprint for a function
(defstruct semantic-function
  name ; 'my-func
  param-list ; A list of types
  return-type ; The *validated* type, e.g., 'i32
  body ; A list of *other* semantic nodes
  source-location)

;; blueprint for a 'return' statement
(defstruct semantic-return
  return-type ; 'i32
  value-node ; The node for the value being returned
  source-location)

(defstruct semantic-explicit-return
  "Represents an explicit (return ...) form."
  type ; A list of types, e.g., '(int int)
  value-nodes ; A list of semantic nodes for the values
  source-location)


;; blueprint for a literal
(defstruct semantic-literal
  value-type ; 'i32
  value ; 7
  source-location)

;; Represents a function parameter (e.g., 'a' and its type 'i32)
(defstruct semantic-param
  name
  type
  source-location)

;; Represents reading a variable (e.g., 'a' or 'b')
(defstruct semantic-var-read
  name
  type
  source-location)

;; Represents a function call (e.g., '(+ a b)')
(defstruct semantic-add
  type ; The *result* type (e.g., 'i32)
  left-arg ; The 'semantic-var-read' node for 'a'
  right-arg ; The 'semantic-var-read' node for 'b'
  source-location)

(defstruct semantic-sub
  type left-arg right-arg source-location)

(defstruct semantic-mul
  type left-arg right-arg source-location)

(defstruct semantic-div
  type left-arg right-arg source-location)

(defstruct semantic-lt
  type left-arg right-arg source-location)

(defstruct semantic-gt
  type left-arg right-arg source-location)

(defstruct semantic-le
  type left-arg right-arg source-location)

(defstruct semantic-ge
  type left-arg right-arg source-location)

(defstruct semantic-eq
  type left-arg right-arg source-location)

(defstruct semantic-neq
  type left-arg right-arg source-location)

(defstruct semantic-if
  type condition-node then-node else-node source-location)

(defstruct semantic-set!
  "Represents a (set! ...) expression."
  target-node ; The node being assigned to (usually semantic-var-read)
  value-node ; The node for the value being assigned
  source-location)

(defstruct semantic-struct-member-update
  "Represents updating a single member of a struct (creates a new struct value)."
  type ; The type of the struct being updated
  struct-node ; The struct value/variable to update
  member-index ; The physical index of the member to update
  value-node ; The new value for the member
  source-location)

(defstruct semantic-aref
  type array-node index-node source-location)

(defstruct semantic-value-cast
  "Represents a value-preserving cast (e.g., to-float)."
  type ; The target type
  arg ; The node being cast
  source-location)

(defstruct semantic-bitcast
  "Represents a bit reinterpretation cast (e.g., as-int)."
  type ; The target type
  arg ; The node being cast
  source-location)

(defstruct semantic-fp-truncate-cast
  "Represents a float-to-integer truncation cast."
  type ; The target integer type
  arg ; The float node being cast
  source-location)


(defstruct semantic-call
  "Represents a call to a user-defined function."
  name ; The symbol name of the function being called
  type ; The return type of the function
  args ; A list of semantic nodes for the arguments
  signature ; The specific FUNCTION-SIGNATURE struct that was resolved
  source-location)

(defstruct semantic-funcall
  "Represents a 'funcall' form."
  func-node ; The semantic node for the function expression (e.g. var-read or literal)
  type ; The return type of the call
  args ; A list of semantic nodes for arguments
  source-location)

(defstruct semantic-let
  "Represents a (let ...) expression."
  type ; The type of the *last* expression in the body
  bindings ; A list of (name . semantic-node) pairs
  body ; A list of semantic nodes for the body
  source-location)

(defstruct semantic-extract-value
  "Represents extracting a single value from an aggregate (struct)."
  type ; The type of the extracted value (e.g., 'int)
  aggregate-node ; The semantic node for the aggregate (e.g., a semantic-call)
  index ; The 0-based index to extract
  source-location)

(defstruct semantic-struct-construction
  "Represents constructing a struct instance e.g. (%construct-struct 'point ...)."
  type ; The type specifier of the struct (symbol name)
  args ; List of semantic nodes for the field values (in definition order)
  source-location)
