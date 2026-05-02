Presently, for any matrix in Crisp, we can only determine if it is "row major" or "col major" by making 
a runtime examination.  Also, we just seem to always default to row-major.   This isn't terrible, because the stride virtual array is passed SROA to the kernel as part of the Storage Handle. But still, it does mean that some compile-time optimization might not
be available.

Fortunately, we can fix this by adding to the tensor definition, and not having to redo a lot of work.

I'm planning on adding a :contiguous-term compile time property to the tensor def-record. It defaults to :last 



The new :contiguous-term shows up in the design doc in a few places now, but mostly concentrated in the section below.

We'll need to add the term, add the property accessor, etc.

One note, and I'd like your feedback on this.  In Crisp in def-record and def-struct, 
some of the terms have "defaults". And we also have this idea that the types at the kernel boundary
must be "fully typed", they can't have unspecified compile-time terms. And, but a type at the boundary
of non-kernel functions CAN have unspecified terms -- they are considered "incomplete".
So, I think that if a term has a "default" that counts for being set at the kernel boundary - it's not incomplete. But at a non-kernel function boundary, we shouldn't overspecify. If the user didn't explicitly
add it to the type, then we consider it incomplete.   Does that make sense?  Is this going to be a mess?

Let me know what you think about contiguous-term, and we'll plan out TDD tests, steps, etc. 






Storage Handle Types
====================

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

 Note that the tensor properties `offset` and `stride` are CANNOT be mutated when the alignment is `:compact`.  Attempting to do so is a compilation error.
 Similarly, `stride` is only mutable in a `:strided` aligned storage handle, and the compiler will emi
 an error if you attempt to mutate it otherwise.

 ### Contiguity  (aka row-major vs col-major )

 Except `cell`, all Storage Handles have compile-time known "contiguity".  This tells the compiler
 in which dimension the data is contiguous. 
 The compiler time property to specify this is `:contiguous-term`. It defaults to `:last` for
 all types, and by virtue of there being a default it means this is optional. Many users will
 never need it, or need to know about it.

 ```
 (tensor float 6 :address-space :global :access :read-write :align :compact :contiguous-term :last)

;; usable with any tensor of any arity
 :contiguous-term  :last   ;; for a matrix, this is same as :row-major
 :contiguous-term  :first  ;; same as :col-major for a matrix

;; usable only with matrices
 :contiguous-term  :row-major
 :contiguous-term  :col-major

 (tensor-stride someMatrix (row-y col-x) ...)
```


Storage Properties
------------------

 `storage` has the following immutable properties:

| Property      | Type          |              |     Description |
| --------------|---------------|--------------|-----------------|
| byte-size~         | ulong         | runtime      | the number of bytes in the `storage`. This is immutable.|
| address-space~ | address-space | compile-time | one of `:global`, `:local`, `:constant` |
| access~        | access        | compile-time | one of `:read-only` `:write-only` `:read-write` `:readable` `:writeable` |


The `byte-size~` property for a `storage` is sometimes known at compile time, but is most often a runtime property.
However the other properties are all known and evaluable at compile time. 

<!-- IMPLEMENTATION NOTE:

We should be able to model storage as a def-record.  But note that the memory address the storage is tracking is both a runtime property AND not directly 
accessible to the user. 

BUT - at the moment, let's NOT hide "address" from the user.  We'll simply
not document it, and play it by ear later. 

;; the address-space and access enumerations provide the "type" for the
;; storage properties of the same name. 

(def-record storage
    (address ulong)    
    (byte-size ulong)
    (address-space address-space :c-t)
    (access access :c-t))

-->

Cell Properties
---------------

A `cell` has these mutable properties:

| Property | Type    | Description |
| ---------|---------|-------------|
| parent~   | storage | address of a "parent" storage |
| offset~   | ulong   | offset into parent. |

`(offset~ someCell)` `(parent~ someCell)` can be used to access (or change) the `cell` view.
Note that out-of-bounds checks are not enabled by default. Certain compiler flags (like `--runtime-checks`) will enable them.

These property access functions are overloadable. It would be unwise to overload them for all `cell`s. Use `def-derived-type` 
to define your own cell type and overload those property accesses. The `~offset~` and `~parent~` functions
can also be used, and those cannot be overloaded. 


Vector / Matrix /Tensor Properties
-------------------------------

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

The `storage` property accessors  `address-space~` and `access~`  can both be used directly on any Storage Handle type. 
There is no reason to do `(access~ (parent~ some-vector))`.  Simply doing `(access~ some-vector)` is sufficient.

Element Access
--------------

- `~`
- `~ref~`

`~` is the main function for accessing elements in a Storage Handle. It can be `set!` and overloaded.
It would be supremely unwise to overload `~` generally. Instead use `def-derived-type` to 
define your own subtype and overload `~` for that type. 

```
;; cell
(~ <cell>) ;; get
(set! (~ <cell>) <value>) ;; to  set!

;; vector
(~ <vector> <index>) ;; to get 
(set! (~ <vector> <index>) <value>) ;; to set!

;; soa-vector of point
(x~ <soa-vec> <index>) ;; get the `x` of point at <index>
(set! (x~ <soa-vec> <index>)  <someValue>) ;; set the `x` of the point at <index>

;; matrix
(~ <matrix> <y-index> <x-index>) ;; to get
(set! (~ <matrix> <y-index> <x-index>)  <someValue>) ;; to set!

;; tensor
(~ <tensor> ... <z-index> <y-index> <x-index>) ;; get
(set~ (~ <tensor> ... <z-index> <y-index> <x-index>) <someValue>)
```

```
; example
(let ((vec #(2 4 6 8))
      (elem (~ vec 1))) ;; 4
  (set! (~ vec 0) (* 2 elem))) ;; stores "8" into the first position of the vec.
```

### `~ref~`
 `~ref~` can also be used to get and set elements in a Storage Handle and these element
access functions cannot be overloaded.   `~ref~` is intended to be used from overloads of `~`

```
;; example with vector
(~ref~ <vector> <index>)  
(set! (~ref~ <vector> <index>) <value>)
```


Helper Functions
----------------

`(element-type~ someStorageHandle)`  a type expression that returns the type of the elements in the Storage Handle.

`(bytes~ someStorageHandle)`  a helper function that calculates the current number of bytes in the Storage Handle.
Note that this is NOT a passthrough. If you want the total number of bytes in the parent `storage`
you'll need `(byte-size~ (parent~ someStorageHandle))`

`(num-dims-of someStorageHandle)`  returns the number of dimensions of a storage handle.
Very useful for the `tensor` type, less so for the others.

| type | dims | 
|------|------|
| cell   | 0 |
| vector | 1 | 
| matrix | 2 | 
| tensor | N | 

Member Data Rules
-----------------

A  Storage Handle can contain any type that has a fixed, known size at compile time.
This would include:
- Scalar types (`int`, `float`, etc)
- Small vector types (`float4` etc)
- Structs
- Views to large data (`cell`, `vector`, `tensor`, `matrix`)

But it excludes:
- `storage`
- `functions` and `kernels`
- `def-record` and `def-rec-vec`




Storage Handle Type Definitions
-------------------------------

Storage Handles are completely typed by 
- type of their element
- `address-space` (which is one of `:global` `:local` `:private` `:constant`)
- `access` (which is one of `:read-only` `:write-only` `:read-write` `:writable` `:readable`)
- `align` (one of `:strided` or `:compact` or `:compact-offset`)  NOTE: `align` is not needed by the `cell` type.
- `contiguous-term` (one of `:first` or `:last`.  Defaults to `:last` if not provided)

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
(XXXX <element-type> &key align address-space access (contiguous-term :last))

;; for tensor
(tensor <element-type> NumDims &key align address-space access (contiguous-term :last))
```



Example: `(vector long :access :writeable)`  This specifies that some vector of longs is writeable. 
It could be of any address space or alignment.

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

Storage Handle Arguments for Kernels
------------------------------------
`def-kernel` is the definition for the kernel function. 
And any Storage Handle in its parameter list MUST have its element-type, number or dimensions, align, address-space and access specified in
its type definition. Only the size can be unspecified. (And for `cell`, `align` is not needed.)
The number of dimensions is (obviously) implicit for the `cell`, `vector` and `matrix` types.


```
(def-type data-from-host-t (vector float :align :compact :address-space :global :access :read-only ))
(def-type result-from-kernel-t (vector float :align :compact :address-space :global :access :write-only ))

;; -- my_kernel --
(def-kernel my_kernel (in &out out)
  (declare #'(data-from-host-t &out result-from-kernel-t))
  ...)
```

Creating Storage Handle Views
------------------------------

Kernels cannot dynamically allocate memory. Crisp has four different ways
of working with and around this limitation:

- vector literals.  Small stack-based vectors that use registers ( `:private` addres space)
- reinterpret view. Re-use existing storage.
- `def-const-vec`. Read-only vector in the `:constant` address space. 
- Side Channels: "scratch" and "implicit" storage handle views.

These four approaches are quite different from one another, and each has advantages
and disadvantages. And some work well together (like declaring a vector literal or constant vec, and then reinterpreting it as a `cell` or `matrix`).

We'll discuss [vector literals](#vector-literals-val0-val1-val2--valn) and 
[reinterpret view](#reinterpret-storage---make-xxxx) in the next two sections, and
introduce [def-const-vec](#def-const-vec) and [Side Channels](#side-channel-storage-handles) later.




### vector literals `#(val0 val1 val2 ... valN)`

A `vector` can be literally declared using the Lisp `#(...)` syntax.

```
(let ((small-vec #(0 1 2 someVal otherVal)))      ;;<-- ideally, type should be inferred
  (declare (type small-vec (literal-vector short))) ;; so that this is not needed.
   ...)
```
A `vector` declared like this allocated using private register memory. It is highly recommended
that this is reserved for very small vectors (no more than 32 elements), else you could incur
a lot of register pressure.

The address space for these is `:private`. If you need it, the type function `(literal-vector T)` 
makes it easy to exactly declare the type for a vector literal.


### reinterpret storage  . `make-XXXX` 

If you have a Storage Handle type, it can be reinterpreted to another type
using `make-` with the four Storage Handle types.

```
(make-cell <source> <new-element-type> &key offset)
(make-vector <source> <new-element-type> &key length offset)
(make-matrix <source> <new-element-type> width height &key offset strides)
(make-matrix <source> <new-element-type> width height &key (major :row) (offset 0))
(make-tensor <source> <new-element-type> <extents-list> &key offset strides)
```

A new `cell` obviously has `length=1`.  For a `vector`, if the `:length` key is not used, then the resulting 
new `vector` will have its size calculated automatically (byte size of the original storage / new element size, minus offset).
If the source byte size is not a multiple of the new element size, the result is truncated.
But the other types (`tensor` and `matrix`) need to have their extents provided.


For the 2D `matrix`, one of the declarations supports a `:major` key which can be `:row` or `:col`.
Alternately, the `:strides` key can set the strides. Setting the strides directly is how to get "row major" vs "col major" (versus "plane major" etc) tensor in higher dimensions. 

There are some restrictions. They are enforced at compile time:

- if the original and new element types don't match, then the source element type cannot be a struct type
- If the original and new element types don't match, the source Storage Handle must have a `:compact` or `:compact-offset` layout. Reinterpreting element types on `:strided` views is mathematically undefined and will trigger a compile-time error. 

The returned Storage Handle inherits the address-space and access permissions from the source. It also inherits the alignmnet (`:compact`, `:compact-offset` or `:strided`), with one exception: if the `:strides` key is explicitly provided during the reinterpretation, the resulting handle is automatically typed as `:strided`.

The runtime will assert that the number of source bytes is sufficient for the new requirements, but this
assertion requires compiler flags (like `--runtime-checks`). 

`:compact` layout is generally more amenable to reinterpretation.

The `:contiguous-term` cannot be overridden by any interpretation operation. The compiler will set it appropriately


```
(def-type vec-floats-t (vector float :align :compact :address-space :local :access :read-write ))
(def-type vec-ints-t (literal-vector int))

;; -- do_things --
(def-kernel do_things (hundred-floats)
  (declare (type hundred-floats (vecl-floats-t 100)))
  (let ((some-ints #(0 1 2 3 4 5)) ;; <-- compiler will attempt to infer typ
        (three-cell (make-cell some-ints int :offset 3))
        (ten-floats-view (make-vector hundred-floats float :length 10)))
    (declare (type some-ints vec-ints-t))
    ...))

```