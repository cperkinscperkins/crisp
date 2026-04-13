# Storage Handle Types


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


### Alignment

Crisp supports three different alignment schemes for Storage Handles:  `:compact`, `:compact-offset`, and `:strided`

`:compact` alignment is contiguous with no gaps between data members. For a `vector` that would be compatible with `std::vector<T> .data()`.  `:compact` alignment also means that the underlying `storage` parent pointer is aligned to a 16 byte address boundary. Lastly, `:compact` storage handles are not offset. When alignment is `:compact` the access operations (`~`) ignore both the `stride` and `offset` elements of the storage handle and the element dereferences are calculated directly and performantly.

`:compact-offset` alignment is like `:compact` above except the `offset` elements of the storage handle
are used, they are not ignored.  This means there is an additional calculation that has to occur when
referencing.

 `:strided` alignment means that the Storage Handle uses its `stride` values when determining reference locations  during access operations. `:strided` Storage Hanles are often the result of transpose and slicing operations. This increases the reuse potential of Storage Handles and means less data copying
 is required.   

 If a storage handle type function arg is declared as `:compact` it will not accept a `:strided` or `:compact-offset` storage handle value.  Crisp developers can choose different strategies to help deal with alignment when declaring storage handle types. 
 - use templates.  `(with-template-type (T A) ...) ` where `A` is the alignment. Then you will have a "fast" `:compact` or `:compact-offset` version of your function and a more flexible `:strided`.
 - use incomplete types.  Just skip the `:align` keyword when declaring a storage handle type. The 
 compiler will then allow any type of storage handle to be used as an argument to that function. But, note, that it will default to the slightly slower `:strided` behavior.
 - be exact. Just specify the alignment you expect/desire. For users who aren't using transpose or slicing operations, this is simplest.

