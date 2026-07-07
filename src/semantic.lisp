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

;; Endeavor 132 (MMA): one tf32 m16n8k8 matrix-multiply-accumulate.
;; Genuine codegen (@llvm.nvvm.mma.m16n8k8.row.col.tf32); see src/mma.lisp.
(defstruct semantic-mma-accumulate
  type c-node a-node b-node source-location)

;; Endeavor 128: transcendentals. Unary intrinsics (1 arg) + binary (pow, atan2).
(defstruct semantic-exp
  type arg source-location)

(defstruct semantic-log
  type arg source-location)

(defstruct semantic-log2
  type arg source-location)

(defstruct semantic-tan
  type arg source-location)

(defstruct semantic-asin
  type arg source-location)

(defstruct semantic-acos
  type arg source-location)

(defstruct semantic-atan
  type arg source-location)

(defstruct semantic-pow
  type left-arg right-arg source-location)

(defstruct semantic-atan2
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

;; Endeavor 132 (MMA) F2: a multi-value producer.  Packs VALUE-NODES into a multi-value
;; aggregate whose TYPE is the list of their types (e.g. (ulong ulong)); consumed by the
;; let multi-value binding path (like (floor …)/(truncate …)).  Backs outer-dimensions;
;; a future (values …) expression would build the same node.
(defstruct semantic-values
  "A multi-value producer: TYPE = list of the VALUE-NODES' types; codegen packs them into
   an LLVM aggregate (get-llvm-return-type + insertvalue), indexed by the let mvb path."
  type value-nodes source-location)

;; Endeavor 122 (FFI) Pass 4: handles (void**).
(defstruct semantic-make-c-handle
  "Allocates a local slot (alloca) that holds a pointer of HELD-TYPE; the node's
   value is the slot's address (a c-handle, an addrspace-0 pointer). Pass it to a
   foreign function expecting a void**; read it back with get-pointer."
  type        ; the c-handle type: (c-handle <held-ptr-type>)
  held-type   ; the held pointer type-spec, e.g. (c-pointer :address-space :global)
  source-location)

(defstruct semantic-get-pointer
  "Loads the held pointer out of a c-handle slot (the value a foreign function
   wrote into it)."
  type         ; the held pointer type-spec
  handle-node  ; semantic node evaluating to the c-handle
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

(defstruct semantic-with-precision
  "Endeavor 126 (pass 5): (with-precision (KEY) body...) — per-region precision.
   Codegen dynamically binds *math-precision* to MODE over the body (unless
   --force-math-precision locks it), so the body's FP ops carry the region's mode.
   Value is the last body expression's value (like progn)."
  type ; return type (of the last body expression)
  mode ; :fast or :ieee
  body ; a list of semantic nodes
  source-location)

(defstruct semantic-to-workgroup-uniform
  "Represents a (to-workgroup-uniform ...) expression."
  type ; The type of the value
  value-node ; The expression being made uniform
  source-location)

(defstruct semantic-to-warp-uniform
  "Represents a (to-warp-uniform ...) expression."
  type ; The type of the value
  value-node ; The expression being made uniform
  source-location)

(defstruct semantic-sizeof
  "Represents a sizeof(type) expression."
  type ; Always ulong (or similar integer type)
  target-type ; The Crisp type to measure
  source-location)

(defstruct semantic-gpu-builtin
  "Represents a GPU built-in function call (e.g. get-global-id, sync-workgroup).
   BUILTIN-NAME is a keyword: :get-global-id, :sync-workgroup, etc.
   DIMENSION is NIL for the 3D vector form, or 0/1/2 for the scalar-n form.
   TYPE is the Crisp return type: 'ulong3, 'ulong, 'uint, or NIL (void)."
  builtin-name
  dimension
  type
  source-location)

;; Endeavor 114 Phase A SPV codegen was attempted then reverted — see
;; tests/spec/114-async-tile-codegen/async-tile-codegen.md.  The two
;; semantic node defstructs the SPV path needed (semantic-spirv-async-tile-copy
;; and semantic-spirv-await-request) are NOT defined here; if/when the
;; SPV blocker is unblocked, they'll be re-introduced.

;; Endeavor 114 Phase B: NVPTX cp.async-based async tile copy.  Holds the
;; analyzed sub-nodes; codegen emits per-thread cp.async + commit_group
;; for the request, and cp.async.wait_group(0) for the await.  Direct LLVM
;; NVVM intrinsics — no linkage hazard (the SPV blocker doesn't apply).
;;
;; Phase B.1 scope: simple case where tile.length == workgroup_size (one
;; cp.async per thread, no inner loop).  Bigger tiles need a cooperative
;; loop, which lands in B.2.
(defstruct semantic-make-async-barrier
  type
  cell-node
  source-location)

(defstruct semantic-nvvm-cp-async-tile-copy
  src-node      ;; semantic node for the source tensor (addrspace 1)
  tile-node     ;; semantic node for the dest tile (addrspace 3)
  origin-nodes  ;; list of semantic nodes for origin coords (one per dim)
  barrier-node  ;; semantic node for the mbarrier object
  type
  source-location)

(defstruct semantic-nvvm-cp-async-wait
  barrier-node  ;; semantic node for the mbarrier object
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

(defstruct semantic-while
  "Represents (while condition body...).
   Returns void."
  type
  condition-node
  body
  source-location)
