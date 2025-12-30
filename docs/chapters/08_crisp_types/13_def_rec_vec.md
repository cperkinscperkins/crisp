## `def-rec-vec`


Just as `def-record` makes a virtualized struct, so does `def-rec-vec` maka a virtualized
vector, though far simpler than either `def-record` or `vector` for that matter. 

### Type declaration

`(def-rec-vec <TypeName> T N)`
The `def-rec-vec` declares a new type. `T` is the element type which is limited to the basic hardware types (`float`, `long` `int4`, `half` etc). And `N` is the length of the vector. All arguments must be 
known at compile-time. 

### `marshall-XXXX`
`(marshall-<TypeName> a0 a1 ... aN)`
The `marshall-XXXX` macro names the variables (ie register ids) that are bound. All `N` are required. 

### `~`
Like vectors, `def-rec-vec` instance support `~` for refer-by-index semantics. This can be used for both
get and set.

> Implementation Note: this mutability will likely mean we'll need to lower this to an `alloca` for LLVM.

### `length~`
The `length~` compile time property is supported.

### example
```
(def-rec-vec virt-arr long 5)

...
(let ((va (marshall-virt-arr a b c d e))
      (A   (~ va 0))
      (B   (~ va 1))
      (len (length~ va))) ;; <-- 5

      (set! (~ va 2) someVal)

      ...)
```

`def-rec-vec` is mostly used internally by Crisp itself when modelling advanced Storage Handle types
like tensors and matrices.  If you are modelling your own data type and need to marshall it during `def-kernel-exact` then `def-rec-vec` might be useful to you. But for true linear access to data interchanged between the host and the kernel, use `vector`, `soa-vector` or the other provided
Storage Handle types (`cell`, `vector`, `matrix`, `tensor`).  


