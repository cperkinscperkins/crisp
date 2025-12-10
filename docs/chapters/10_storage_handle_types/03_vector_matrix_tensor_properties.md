## Vector / Matrix /Tensor Properties


 `vector` and `matrix` are just the 1D and 2D variants of `tensor`

Every `tensor` has these runtime properties:

| Name     | Type        | Description |
|----------|-------------|-------------|
| length   | ulong       | the number of elements in the `tensor`.  |
| parent   | vector      | address of a "parent" storage |
| offset   | ulong       | offset into parent. |
| num-dims | ulong       | number of dimensions of the tensor.  This is an immutable compile time property of the tensor |
| strides  | stride-type |  `vector` the length of the `num-dims` that tracks the count to the "next" element in that dimension |
| extents  | extents-type | `vector` the lenght of `num-dims` that tracks the extent of that particular dimension |

Each of those properties can be accessed by the `XXXX~` function.
e.g. `(length~ someTensor)` , `(parent~ someTensor)`

The `align` property is known at compile-time and is immutable.  

But since these types are just views into some `storage`, their other properties are mutable. 

These property functions for the mutable properties can be overloaded.  They can also be retrieved with `~XXXX~` (which is not overloadable).

### Settable Properties

None of the `storage` properties can be set. Also, excepting `bytes`, all the `storage` properties are compile time properties. 
The `bytes` property on a `storage` entity is sometimes a compile time property, but usually it's a runtime property. Regardless, it cannot be changed, .
But ALL the mutable properties on the Storage Handle view can be set, including `length`.

```
(set! (length~ someVector) 10)
(set! (parent~ someMatrix) otherStorage)   
(set! (offset~ someCell) 100)
```

Use `def-setter` to overload the property setting function.  `~XXXX~` can also be used to get / set the respective properties


Note that it is an error to set the `length` or `offset` of any Storage Handle such that it's `(length + offset) * (sizeof elementType)` is greater
than the `bytes` of the parent `storage`. But the checking and enforcement for these errors is NOT on by default.

### Pass Through

The `storage` property accessors  `address-space~` and `access~`  can both be used directly on any Storage Handle type. 
There is no reason to do `(access~ (parent~ some-vector))`.  Simply doing `(access~ some-vector)` is sufficient.

