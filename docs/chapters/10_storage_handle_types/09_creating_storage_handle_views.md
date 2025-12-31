## Creating Storage Handle Views


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

The returned Storage Handle inherits the address-space, access permissions, and layout (`:compact` or `:std140`) from the source.

For the 2D `matrix`, one of the declarations supports a `:major` key which can be `:row` or `:col`.
Alternately, the `:strides` key can set the strides. Setting the strides directly is how to get "row major" vs "col major" (versus "plane major" etc) tensor in higher dimensions. 

There are some restrictions. They are enforced at compile time:

- if the original and new element types don't match, then the source element type cannot be a struct type
- if the original and new element types don't match, then the the new type also cannot be a struct type
- if the underlying source has `:std140` layout, then reinterpretation between
  types requires that both have the same base alignment requirement under `std140`. 

The runtime will assert that the number of source bytes is sufficient for the new requirements, but this
assertion requires compiler flags (like `--runtime-checks`). 

`:compact` layout is generally more amenable to reinterpretation.


```
(def-type vec-floats-t (vector float :align :std140 :address-space :local :access :read-write ))
(def-type vec-ints-t (literal-vector int))

;; -- do_things --
(def-kernel do_things (hundred-floats)
  (declare (type hundred-floats (vecl-floats-t 100)))
  (let ((some-ints #(0 1 2 3 4 5)) ;; <-- compiler will attempt to infer typ
        (three-cell (make-cell some-ints 'int :offset 3))
        (ten-floats-view (make-vector hundred-floats float :length 10)))
    (declare (type some-ints vec-ints-t))
    ...))

```


