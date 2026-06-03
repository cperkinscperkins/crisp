# Storage Handle Type Definitions ⚠️


Storage Handles are completely typed by 
- type of their element
- `address-space` (which is one of `:global` `:local` `:private` `:constant`)
- `align` (one of `:strided` or `:compact` or `:compact-offset`)  NOTE: `align` is not needed by the `cell` type.
- `contiguous-term` (one of `:first` or `:last`.  Defaults to `:last` if not provided)

The `tensor` type also requires the number of dimensions to be known at compile time.

Further, constant vecs (see below) also need their `length` to be fully typed.


But none of those are necessary to specify a storage handle type in a parameter list.
Therefore, there are several storage handle type functions available in CRISP,
 and they fall on a gradient, from loose to specific.   Many of the type functions here
 return incomplete types, which make them flexible. But any operation that accesses the
 actual data of the storage handle will, at minimum, require the element type to be specified.



#### Simplest - Element Type Only

For tensor, the arity is also required (at minimum).

```
(cell <element-type>)
(vector <element-type>)
(matrix <element-type>)
(tensor <element-type> NumDims)
```

Unlike the other Storage Handle types, the `tensor` type doesn't have an "only element type" type
specifier. Whenever the element-type is provided, the number of dimensions must also be provided.

Example: `(vector float)`
This example simply specifies that the value or parameter is a `vector` 
with a `float` element type. It does not specify any particular alignment, address space, or size.

Note that for the `cell` type, this is the minimum information needed to perform element access (`~`).


#### Using Keys
For the most flexibility, keys can be used.
```
;; for cell
(cell <element-type> &key address-space)

;; for vector and matrix
(XXXX <element-type> &key align address-space (contiguous-term :last))

;; for tensor
(tensor <element-type> NumDims &key align address-space (contiguous-term :last))
```



Example: `(vector long)`  This specifies that some vector of longs is writeable. 
It could be of any address space or alignment.

Example: `(tensor float 4)`  This specifies that we have a hypercube of floats, but nothing else is known about it. 



#### Element Type
The element type of a Storage Hnadle must be an element of a fixed size known at compile time.
It cannot be the type of a function. It cannot be a `def-record`.  Nor can it be a `storage` entity.


#### Usage

```
;; -- count --
(def-function count (v)
    (declare (return-type ulong) (type v (vector long :align :compact :address-space :global)))
 ...)

 ;; vectors can be compile-time fixed size
(vector float :align :compact :address-space :local :extent (100))
```

