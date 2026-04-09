Crisp has five Storage Handles: cell, vector, matrix, tensor and soa-vector.

The design docs for these in docs/chapters/10_storage_handle_types/   There are a score of very short .md files about them.


cell has already been implemented. It's TDD tests are in tests/spec/015-cell  as well as 017-scratch-cell and 037-cell-branded

tensors can have any arity, which is always known at compile time.  A vector is just a tensor of arity 1. A matrix is just
a tensor of arity 2.

Since tensor is the lynchpin behind vector and matrix, we'll start with realizing it. It's tests are in 064-tensor. This initial
batch of tests is mostly just updated variants of the 015-cell tests. If you see "cell" in any of them, it means I overlooked one
and it should be changed to tensor.  If you have suggestsion for more initial TDD tests, let me know.

Remember that Crisp has both def-record and def-struct. They pun for one another and have the exact same affordances,
but structs are contiguous memory and records are virtual structs - just collections of registers that we pass around via SROA. 
The Storage Handles are all built atop def-record.  

Crisp also has a fixed array type (tests in 060-array). When the (array T N) declaration appears inside a def-record we
create a VIRTUAL array.  These virtual arrays are very important and most of the fields of the tensor are virtual arrays. To wit:

tensor N
- offsets: (array ulong N)
- strides: (array ulong N)
- extents: (array ulong N)
- storage: the same def-record used by cell. Just a pointer and a size.

Note that cell only has storage and offset, and its offset is just a ulong.

When we want to transpose a matrix/tensor we just mutate the strides, rather than move all the memory. 

Crisp supports branded types and all the Storage Handles use type branding, this is for the auto-differentiation to be able to 
track proveneance of the data flow.  The cell is already branded. 


## Implementation Plan (2026-04-07)

### Tensor def-record template

```lisp
(with-template-type ((To T) (N integer 1) (Addr address-space :global)
                     (Acc access :read-write) (Align align :compact))
  (def-record tensor
    (brand value-t To :subst :descendant :enforce :diff)
    (parent  (storage Addr))
    (offsets (array ulong N))
    (strides (array ulong N))
    (extents (array ulong N))
    (length  ulong)
    (element-type  type-spec     :c-t To)
    (num-dims      ulong         :c-t N)
    (address-space address-space :c-t Addr)
    (access        access        :c-t Acc)
    (align         align         :c-t Align)))
```

T and N are positional. :address-space, :access, :align are keyword args with defaults
:global, :read-write, :compact respectively.

Canonical (internal) type specifier is a 6-tuple:
  (tensor element-type N addr access align)

### Six overlay changes

**1. align enumeration** (def-enumeration align :std140 :compact)
   - Goes in the overlay (calls the already-defined def-enumeration macro)

**2. register-builtins redefinition**
   - Full replacement in overlay; copies existing storage+cell body, adds:
     - tensor def-record template registration
     - bytes~ template for tensor (same pattern as cell)

**3. expand-storage-handle-type-specifier redefinition**
   - Tensor gets special-case: N is second positional arg (error if missing),
     :align parsed alongside :address-space/:access, returns 6-tuple.
   - Cell/vector/matrix unchanged (still return 4-tuple).
   - (tensor long) without N => crisp-incomplete-type-error

**4. get-array-element-type redefinition**
   - Fix symbolp branch (currently only handles mangled cell symbols)
     to also unmangle and recognize mangled tensor symbols.

**5. analyze-aref-expression redefinition**
   - Before the fallback-to-function-call path, detect tensor type.
   - Extract N from the type spec; verify exactly N index forms present.
   - Build flat element index form:
       flat = sum_k( (~ (offsets~ t) k) + ik * (~ (strides~ t) k) )
   - Recursively analyze that form to get a single flat-index node.
   - Return semantic-aref with tensor node + flat-index node.

**6. generate-node-ir (semantic-aref) redefinition**
   - Add Case 3 for tensor (between Case 2 array and the error fallthrough):
   - Extract parent.address from field 0 of SROA'd tensor (same as cell).
   - Byte offset = flat_index * sizeof(element)  (no cell_offset addition;
     offsets are already folded into the flat index by the analyzer).
   - GEP i8* + byte_off, bitcast, load. Return (values loaded nil ptr).

### Test phases

- Changes 1-4 alone: tests 01-arg, 02-props, 03-passthrough, 03.1-helpers
  (all use auto-generated def-record accessors + existing array GEP path)
- Changes 5-6 additionally: tests 04-accessor through 09-type-constructors
  and the tensor-of-struct tests
- Error tests: changes 1-3 are sufficient (type-spec expansion raises the error)

