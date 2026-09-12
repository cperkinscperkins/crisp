# Alignment ✅


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

 Note that the tensor properties `offset` and `stride` are CANNOT be mutated when the alignment is `:compact`.  Attempting to do so is a compilation error.
 Similarly, `stride` is only mutable in a `:strided` aligned storage handle, and the compiler will emi
 an error if you attempt to mutate it otherwise.

