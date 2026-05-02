## Workgroup Stride


Whereas the other stride macros bend all available threads to their wicked purposes, `workgroup-stride` is 
used to just set up a stride across a worksgroup. This makes it one of the very few "workplace level" 
macros that Crisp provdes.  This CAN be nested in a grid level operation (such as `tile-stride`)

```
(workgroup-stride <tensor> (<bindings>) ...)
(workgroup-stride <tensor> <tile-tag> (<bindings>) ...)
```

The `<tensor>` can be any arity, but because this operates at the workgroup level, it should represent a small problem space (typically a `:local` memory tile). Do not use `workgroup-stride` to walk massive global matrices.


`tile-tag` 
- `:local-size` (normal grid stride, could be 1D, 2D, or 3D) 
- `:warp-idx`  1D only
- a small 1D vector, 2D matrix or 3D tensor
- small sizes: `(w)`, `(w h)`, or `(w h d)`

`bindings`
- `(x)`, `(x y)`, `(x y z)`

The `problem-space` can be anything or any size. But whatever it is, it should have
been divided among all workgroups. Don't use `workgroup-stride` to stride something
really big. Ideally, something small and using `:local` memory.

`:local-size` - each thread in the workgroup starts with its own local id
and each time through the stride increments the binding by the number of threads
in the workgroup. 

`:warp-idx` - every thread in a warp will get the same binding, striding by the 
  number of warps in a workgroup.

### coordinate conversion

These functions operate analagously to their `thread-stride` counterparts.

```
(wg-problem-space-coords) => (x ...)

(wg-tile-coords) => (x ...)
```

-->
                     

### `ceil-pow2`

For certain operations, like warp reductions, it is imperative that certain activities
fit completely in a warp and are not "split" across warp divide. 

If the argument to `ceil-pow2` is a power of 2, it'll be returns. But if not, then the
next hightest power of 2 will be returned. This can be very handy in loops
or for making sure tile strides don't split work across the warp boundary. 

```
(ceil-pow2 4) => 4
(ceil-pow2 5) => 8
```



