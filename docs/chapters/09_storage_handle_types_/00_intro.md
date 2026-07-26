# Storage Handle Types ✅


Crisp has an internal represention called `storage`.  It is a contiguous array of bytes. 
`storage` entities cannot have their capacity resized. 
All `storage` entities have their data allocated either by the host or the compiler, 
they cannot be dynamically allocated by the runtime. 

We mention this internal represention not because you will interact directly with it, but because
it underpins the `cell`, `vector`, `soa-vector`, `matrix` and `tensor` constructs. All of them have a parent `storage`to which they provide access.

All these Storage Handle types are views into some parent `storage`. It is often useful to adjust the offset or size of a view to use it
as a cursor to a section of the `storage`. 


- `cell` : A view of one single element, type `T`
- `vector` : provides 1D linear access.  Technically, this is a 1D `tensor`
- `soa-vector` : Struct of Arrays. 1D linear access. See the `soa-vector` section below.
- `matrix` : a 2D `tensor`
- `tensor` : arity must be known at compile time. `tensor` can be any arity.  All tensors support "strides" which is how far to the next element in any of the `N` dimensions of the `tensor`


