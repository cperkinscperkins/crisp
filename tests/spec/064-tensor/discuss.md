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

