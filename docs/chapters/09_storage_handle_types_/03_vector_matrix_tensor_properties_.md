## Vector / Matrix /Tensor Properties ⚠️


 `vector` and `matrix` are just the 1D and 2D variants of `tensor`

Every `tensor` has these runtime properties:

| Name     | Type        | Description |
|----------|-------------|-------------|
| length~   | ulong       | the number of elements in the `tensor`. Product of the `extents`. This property cannot be directly `set!` for 2D and higher tensors. But CAN be set for `vector`. |
| parent~   | vector      | address of a "parent" storage |
| offsets~   | offset-type       | `def-rec-vec` the length of the `num-dims` that tracks the count to the starting element in the storage. |
| num-dims~ | ulong       | number of dimensions of the tensor.  This is an immutable compile time property of the tensor |
| strides~  | stride-type |  `def-rec-vec` the length of the `num-dims` that tracks the count to the "next" element in that dimension |
| extents~  | extents-type | `def-rec-vec` the lenght of `num-dims` that tracks the extent of that particular dimension |
| align~   | align-enum | `:strided` or `:compact` or `:compact-offset`. This is an immmutable compile-time property. |
| contiguous-term~ | contiguity-enum | `:last` or `:first`. This is an immutable compile-time property. |

Each of those properties can be accessed by the `XXXX~` function.
e.g. `(length~ someTensor)` , `(parent~ someTensor)`

The `align` and `contiguous-term` properties are known at compile-time and are immutable.  

But since these types are just views into some `storage`, their other properties are mutable. 

These property functions for the mutable properties can be overloaded.  They can also be retrieved with `~XXXX~` (which is not overloadable).

### Settable Properties

None of the `storage` properties can be set. Also, excepting `byte-size`, all the `storage` properties are compile time properties. 
The `byte-size` property on a `storage` entity is sometimes a compile time property, but usually it's a runtime property. Regardless, it cannot be changed, .
But ALL the mutable properties on the Storage Handle view can be set. And `vector` can also set the  `length`.

```
(set! (length~ someVector) 10)
(set! (parent~ someMatrix) otherStorage)   
;; offset for cell and vector is direct.
;; but for 2D matrix and higher, requires index
(set! (offset~ someCell) 100)
(set! (offset~ someVector) 4)
(set! (offset~ someMatrix 0) 40)
(set! (offset~ someMatrix 1) 50)
```

Use `def-setter` to overload the property setting function.  `~XXXX~` can also be used to get / set the respective properties


Note that it is an error to set the `length` or `offset` of any Storage Handle such that it's `(length + offset) * (sizeof elementType)` is greater
than the `bytes` of the parent `storage`. But the checking and enforcement for these errors is NOT on by default.

### Pass Through

The `storage` property accessor  `address-space~` can be used directly on any Storage Handle type. 
There is no reason to do `(address-space~ (parent~ some-vector))`.  Simply doing `(address-space~ some-vector)` is sufficient.

