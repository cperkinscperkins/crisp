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
  (category nil :type (member :signed-int :unsigned-int :float :void :struct :record :pointer :meta :device-vector)))



(defstruct function-signature
  "Represents the full signature of a Crisp function."
  (name nil :type symbol)
  (parameters nil :type list)
  (return-types nil :type list)
  (source-location nil :type list)
  (is-template-p nil :type boolean)
  (template-params nil :type list)
  (implicit-parameters nil :type list)) ; List of parameter-def for implicit args (e.g. __storage)

(defstruct generic-function-def
  name
  params
  env
  return-types
  declarations
  defaults
  keys
  body
  source-location)

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

;; Sema Structs
;; ------------

;; blueprint for a function
(defstruct semantic-function
  name ; 'my-func
  param-list ; A list of declared parameter nodes
  implicit-params ; A list of implicit parameter nodes (e.g., __sc for scratch cells)
  return-type ; The *validated* type, e.g., 'i32
  body ; A list of *other* semantic nodes
  is-entry-point ; T if this is a kernel (has (declare (entry-point)))
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

;; blueprint for a ##(...) device vector literal, e.g. ##(1.0f 2.0f 3.0f) -> float3
(defstruct semantic-device-vec-literal
  "Represents a ##(...) device vector literal.
   VEC-TYPE is the full Crisp type symbol (e.g. 'float4).
   ELEMENT-TYPE is the component type symbol (e.g. 'float).
   WIDTH is the number of elements (2, 3, or 4).
   ELEMENTS is a list of analyzed semantic nodes, one per element."
  vec-type
  element-type
  width
  elements
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

(defstruct semantic-sin
  type arg source-location)

(defstruct semantic-cos
  type arg source-location)

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

(defstruct semantic-atomic-rmw
  "Represents an atomic read-modify-write operation (atomic-add!, atomic-sub!, etc.).
Returns the value at the location BEFORE the modification (fetch-and-op semantics).
OP is a keyword: :add :sub :min :max :xchg.
DELTA-NODE is the value to apply; nil is not used (inc!/dec! use a literal 1)."
  type        ; element type — also the return type (old value)
  op          ; keyword :add :sub :min :max :xchg
  target-node ; semantic-aref for the memory location
  delta-node  ; semantic node for the value to apply
  source-location)


(defstruct semantic-cast
  "Base struct for all cast operations."
  type arg source-location)

(defstruct (semantic-value-cast (:include semantic-cast))
  "Represents a value-preserving cast (e.g., to-float).")

(defstruct (semantic-bitcast (:include semantic-cast))
  "Represents a bit reinterpretation cast (e.g., as-int).")

(defstruct (semantic-fp-truncate-cast (:include semantic-cast))
  "Represents a float-to-integer truncation cast.")

(defstruct (semantic-truncate (:include semantic-cast))
  "Represents a truncate operation returning (quot rem).")


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

(defstruct semantic-insert-value
  "Represents inserting a single value into an aggregate (struct)."
  type ; The type of the result struct
  aggregate-node ; The semantic node for the aggregate being updated
  index ; The 0-based index to insert at
  value-node ; The semantic node for the value being inserted
  source-location)

(defstruct semantic-struct-construction
  "Represents constructing a struct instance e.g. (%construct-struct 'point ...)."
  type ; The type specifier of the struct (symbol name)
  args ; List of semantic nodes for the field values (in definition order)
  source-location)

(defstruct semantic-ct-array
  "Represents construction of a (array T N) value from N scalar T values.
   Used by marshall-tensor to assemble offset/strides/extents array fields."
  type          ; The array type spec, e.g., (array ulong 1)
  val-nodes     ; List of N semantic nodes, each of type T
  source-location)

(defstruct semantic-progn
  "Represents a (progn ...) expression."
  type ; The return type (of the last expression)
  body ; A list of semantic nodes
  source-location)

(defstruct semantic-sizeof
  "Represents a sizeof(type) expression."
  type ; Always ulong (or similar integer type)
  target-type ; The Crisp type to measure
  source-location)

(defstruct semantic-gpu-builtin
  "Represents a GPU built-in function call (e.g. get-global-id, local-barrier).
   BUILTIN-NAME is a keyword: :get-global-id, :local-barrier, etc.
   DIMENSION is NIL for the 3D vector form, or 0/1/2 for the scalar-n form.
   TYPE is the Crisp return type: 'ulong3, 'ulong, 'uint, or NIL (void)."
  builtin-name
  dimension
  type
  source-location)

(defstruct semantic-make-view
  "Represents a make-cell/vector/matrix/tensor view construction.
   Creates a new Storage Handle that reinterprets an existing one.
   No memory allocation occurs — only a new struct value is built.
   Fields:
     type        — result type, e.g. (tensor int 1 :global :read-write :compact)
     source-node — semantic node for the source storage handle
     element-type — new element type symbol (e.g. int, float, short)
     rank        — N: 0=cell, 1=vector, 2=matrix, N=tensor
     offset      — element offset (non-negative integer, default 0)
     length      — explicit length (integer) or NIL for auto-compute (vectors only)
     extents     — list of N integers (matrix/tensor); NIL for cell/auto-vector
     strides     — explicit strides list or NIL (computed from extents/major)
     major       — :row or :col (make-matrix only; default :row)
     source-location"
  type
  source-node
  element-type
  rank
  offset
  length
  extents
  strides
  major
  source-location)

(defstruct semantic-stride-view
  "A view into an existing 2D tensor with stride/extent/offset computed at runtime.
   Used for: transpose (swaps row/col dimensions), col (extract 1D column slice),
   row (extract 1D row slice).
   Fields:
     op           — :transpose, :col, or :row
     source-node  — semantic node for the 2D source matrix
     index-node   — semantic node for the column/row index (NIL for transpose)
     type         — result type list, e.g. (tensor int 2 :global :read-write :strided)
     source-location"
  op
  source-node
  index-node
  type
  source-location)

(defstruct semantic-dotimes
  "Represents (dotimes (var limit [stride]) body...).
   var is bound to 0, stride, 2*stride, ... while var < limit.
   stride-node is NIL when the stride was omitted (emit constant 1).
   Always returns void."
  type
  var-name
  limit-node
  stride-node
  body
  source-location)
