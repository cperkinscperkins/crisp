## Workgroup Stride


Whereas `thread-stride` bends all available threads to its wicked purposes, `workgroup-stride` is 
used to just set up a stride across a worksgroup. This makes it one of the very few "workplace level" 
macros that Crisp provdes.  This CAN be nested in a grid level operation (such as `thread-stride`)

```
(workgroup-stride <problem-space> <chunkExpr> (<bindings>) ...)
```

`problem-space` 
- a  1D vector, 2D matrix or 3D tensor 
- size list: `(width)` or `(width height)` or `(width height depth)` 

`chunkExpr` 
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

(wg-chunk-coords) => (x ...)
```
                     





