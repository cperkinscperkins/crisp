## Storage Handle Type Definitions


Storage Handles are completely typed by 
- type of their element
- `address-space` (which is one of `:global` `:local` `:private` `:constant`)
- `access` (which is one of `:read-only` `:write-only` `:read-write` `:writable` `:readable`)
- `align` (one of `:std140` or `:compact`)  NOTE: `align` is not needed by the `cell` type.

The `tensor` type also requires the number of dimensions to be known at compile time.

Further, constant vecs (see below) also need their `length` to be fully typed.


But none of those are necessary to specify a storage handle type in a parameter list.
Therefore, there are several storage handle type functions available in CRISP,
 and they fall on a gradient, from loose to specific.   Many of the type functions here
 return incomplete types, which make them flexible. But any operation that accesses the
 actual data of the storage handle will, at minimum, require the element type to be specified.

### Simplest

No argument.

```
(cell)
(vector)
(matrix)
(tensor)
```

It's a `cell`, `vector`, `matrix` or `tensor`.   

### Element Type Only
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


### Using Optional
After the base element type and dimensions, the other arguments can be provided as "optional" args. 

```
(cell <element-type> &optional address-space access)
(vector <element-type> &optional align address-space access length)
(matrix <element-type> &optional align address-space access length)
(tensor <element-type> NumDims &optional align address-space access length))
```

Example: `(vector float :compact)` 
This example specifies a vector  of floats with `:compact` alignment. 
It does not specify address-space,  access, or size.

Note that this is the MINIMUM amount of information needed to use element access `(~ someVec i)`
for the non-cell Storage Handle types.
If a `XXXX-type` doesn't include `element-type` AND `align` then the body
of the function won't compile uses of element access (`~`).

The `address-space`, `access` and `length` may appear in order.

### Using Keys
For the most flexibility, keys can be used.
`(XXXX &key element-type num-dims align address-space access length)`

Example: `(vector :access :writeable)`  This specifies that some vector is writeable. 
It could be of any type, address space, alignment, or size.

Example: `(tensor)`  This specifies merely that something is a `tensor`, but nothing else is known about it.



### Element Type
The element type of a Storage Hnadle must be an element of a fixed size known at compile time.
It cannot be the type of a function.  Nor can it be a `storage` entity.

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
    (declare (return-type ulong) (type v (vector long :std140 :global :read-only)))
 ...)

 ;; vectors can be compile-time fixed size
(vector float :std140 :local :read-write 100)
```

