## Storage Handle Type Definitions


Storage Handles are completely typed by 
- type of their element
- `address-space` (which is one of `:global` `:local` `:private` `:constant`)
- `access` (which is one of `:read-only` `:write-only` `:read-write` `:writable` `:readable`)
- `align` (one of `:strided` or `:compact`)  NOTE: `align` is not needed by the `cell` type.

The `tensor` type also requires the number of dimensions to be known at compile time.

Further, constant vecs (see below) also need their `length` to be fully typed.


But none of those are necessary to specify a storage handle type in a parameter list.
Therefore, there are several storage handle type functions available in CRISP,
 and they fall on a gradient, from loose to specific.   Many of the type functions here
 return incomplete types, which make them flexible. But any operation that accesses the
 actual data of the storage handle will, at minimum, require the element type to be specified.



### Simplest - Element Type Only

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
with a `float` element type. It does not specify any particular alignment, address space, access, or size.

Note that for the `cell` type, this is the minimum information needed to perform element access (`~`).


### Using Keys
For the most flexibility, keys can be used.
```
;; for cell
(cell <element-type> &key address-space access)

;; for vector and matrix
(XXXX <element-type> &key align address-space access extent)

;; for tensor
(tensor <element-type> NumDims &key align address-space access extent)
```

Note that `:extent` is normally a runtime property and is NOT required to complete the
type. It can optionally be provided at compile-time and, when provided, is a list of the sizes of each dimension. The sizes cannot be runtime variables, they must be compile-time expressions.


Example: `(vector long :access :writeable)`  This specifies that some vector of longs is writeable. 
It could be of any address space, alignment, or size.

Example: `(tensor float 4)`  This specifies that we have a hypercube of floats, but nothing else is known about it. 



### Element Type
The element type of a Storage Hnadle must be an element of a fixed size known at compile time.
It cannot be the type of a function. It cannot be a `def-record`.  Nor can it be a `storage` entity.

### Access
The enumeration for access has five different choices in Crisp:
- `:read-only`
- `:write-only`
- `:read-write`
- `:readable` 
- `:writable`

But note that the last two are not available in the hoisting example code for loading and enqueueing the kernel

### Usage

```
;; -- count --
(def-function count (v)
    (declare (return-type ulong) (type v (vector long :align :compact :address-space :global :access :read-only)))
 ...)

 ;; vectors can be compile-time fixed size
(vector float :align :compact :address-space :local :access :read-write :extent (100))
```

