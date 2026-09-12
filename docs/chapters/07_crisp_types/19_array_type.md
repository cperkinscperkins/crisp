# Array Type ⚠️


`(array T N)`

In Crisp an `array` type is a 1 dimensional vector type of consecutive elements where
both the element type `T` and the length `N` of the array are known at compile time.

This is mostly a utility type used by some of the Crisp built-ins. Most users will be
better served by the `vector` Storage Handle. 

Like for `vector` the simple `~` accessor is available for dereferencing.

```
(def-kernel something (arr)
  (declare #'((array long 4) => nil))
  (+ (~ arr 0) (~ arr 3))) 
```

Arrays can be direct kernel parameters. But if they are appear directly on the kernel boundary,
they are read only, immutable.

Arrays always use :compact alignment.

Arrays can be elements of a struct, and can ALSO be in a record, but if used in a
`def-record` they are automatically virtualized like the other `def-record` members 


#### `~` ✅
Like vectors, arrays support `~` for refer-by-index semantics. This can be used for both
get and set.

#### `length~` ✅
The `length~` compile time property is supported.

#### No `make-array`
Arrays are expected to be part of structs or records, or passed from the host when enqueing. 
There is no `make-array` expression. 

#### No Nesting

arrays cannot be nested in one another. And expression like `(array (array long 4) 6)` 
will trigger a compilation error.

#### Note: soa-vector Disambiguation

Crisp also has the `soa-vector` data type, where "soa" stands for "Struct of Arrays." The fixed-size `(array T N)` type is architecturally distinct from `soa-vector`. An `array` is a stack-allocated or register-backed primitive, whereas `soa-vector` is a pointer-backed Storage Handle.




