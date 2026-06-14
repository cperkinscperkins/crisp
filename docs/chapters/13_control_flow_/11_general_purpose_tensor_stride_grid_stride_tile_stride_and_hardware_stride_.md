# General Purpose: `tensor-stride`, `grid-stride`,  `tile-stride` and `hardware-stride` ✅


While `loop-vector-stride` is very handy and one of the most commonly used Crisp affordances, 
it's one task is to just employ all the threads to walk a vector. Sometimes you'll need more.
That's when the other Crisp stride macros will come into play.  Unlike `loop-vector-stride`, these can be used with Storage Handles of other arities.

- `tensor-stride` - like `loop-vector-stride` but for matrices and tensors of any arity.
- `grid-stride`  - not associated with any data, just sets up a simple mathematical stride, to any arity.
- `tile-stride` - VERY HANDY stride variant of `tensor-stride` but that moves by "tiles".  Works in
any arity and has helper macros to move between the problem space vector , the indexing, and the tile coordinate systems.
- `hardware-stride` - stride by workgroup or warp. 



#### Simple Safe tensor-stride ✅
```
(tensor-stride <tensor> (<bindings>) ...) 

;;example: fill a matrix with "2"
(tensor-stride someMatrix (row-y col-x)
  (set! (~ someMatrix row-y col-x) 2))
```
This macro visits every unique location in the tensor. Within each warp, the contiguous term of the tensor 
is guaranteed to change. Meaning it's easy to get coalesced memory access.  Works equally well
with row major or col major matrices, for example. 

If the contiguous term of the tensor is compile time determinable, then this will be optimized striding,
otherwise an extra calculation at runtime might be required. Note that even though `:contiguous-term` is 
a compile-time requirement for all tensors, incomplete types at function boundaries might make that indeterminable.  
  

#### Strict tensor-stride ✅
```
(tensor-stride <tensor> <layout-tag> (<bindings>) ...)

;; example
(tensor-stride someMatrix :row-major (row-y col-x) 
   (set! (~ someMatrix row-y col-x) 3))
```

Forces the compiler to hardcode the specified layout. If the static type contradicts it, fail compilation.

Just as with the previous form, this `tensor-stride` macro visits every unique location in the tensor, with
the contiguos term of the tensor mapping neatly to each warp lane.  Once again, works equally well
with row major or col major matrices.

But this variant uses a `layout-tag` argument to express the authors expectation and that will be
EXACTLY how the tensor is strided, with the compiler optimizing every operation. 

`<layout-tag>` choices are

| Tag | Description |
| -- | -- |
| `:row-major` | bindings are `(row-y col-x)` and the LAST term is assumed to be contiguous.  IF the matrix is known at compile time to be :col-major then this is compilation error. OTHERWISE, it assumed the user knows what they are doing. |
| `:col-major` | bindings are still `(row-y col-x)`, but the FIRST term is assumed to be contiguous.|
| `:contiguous-last`  | bindings are `(... y x)` and the LAST term is assumed to be contiguous.|
| `:contiguous-first` | bindings are still `(... y x)` but the FIRST term is assumed to be contigous.|

If the compiler can determine the contiguos term of the tensor and sees that it disagrees with the `layout-tag` it
will emit an error.
But if the compiler CANNOT determine the contiguous term and the provided `layout-tag` is wrong, then this stride
will NOT have coalesced memory access and will likely be slow.  If compiled with `--runtime-checks` a runtime check 
is asserted into the code. 




#### Mathematical grid-stride ✅
```
(grid-stride (<size-list>) (<bindings>) ...)

;; example
(grid-stride (8000000 4000000) (y x) ...)
```
Unlike the others, `grid-stride` does not take a `<tensor>` argument. It simply divides up the `<size-list>` 
problem space by the number of enqueued threads and strides the problem. It treats it as a purely mathematical grid. Defaults to row-major mapping (right-most binding gets the warp).
It is how you tell Crisp to "Forget about physical memory for a second. Just generate a virtual 2D grid of 8 million rows and 4 million columns, and march the GPU across it."


#### tile-stride ✅
```
;; "safe" variants
(tile-stride <tensor> (<size-list>) (<bindings>) ...)
(tile-stride <tensor> <tile-tensor> (<bindings>) ...)

;; "strict" variants
(tile-stride <tensor> <layout-tag> (<size-list>) (<bindings>) ...)
(tile-stride <tensor> <layout-tag> <tile-tensor> (<bindings>) ...)

(tile-stride someMatrix (8 4) (grid-y grid-x) ;; grid-y/x denote nth tile
  (let ((y x (tensor-coords grid-y grid-x))) ;; which pixel/element in the matrix is it exactly
        
    ...))

```
`tile-stride` breaks up a `tensor` into tiles (of any arity, not just 2D). The body of 
`tile-stride` executes once for each tile, with the `<bindings>` being the coordinate
of the `<tensor>` that would act as the tiles origin.

For example, let's say tile-stride is used with a source vector length 30 and a tile length 10.
Then in
`(tile-stride source tile (grid-x) ...)`
The body will execute three times, with `grid-x` bound to 0, 1 and 2.


The arity of the `<size-list>` must match the arity of the `tensor` and the `<bindings>`. Compilation error otherwise.
Alternately, a smaller `<tile-tensor>` can be provided. Its extents will be used for the tile size and, of course,
its arity must match as well. 

Note that there are "safe" and "strict" variants of `tile-stride`. See the descriptions of `tensor-stride` above for that discussion

These variants of `tile-stride` DO set up helper macros. They are discussed below.

Note that `tile-stride` should nearly always be used with the `:strategy :tiled` declaration.  See [:strategy](#strategy) for a discussion. The strategy declaration
is how you communicate your tiling expections out to the metadata or hoisting code that runs host side. 


#### hardware-stride - stride by workgroup or warp. ✅

```
(hardware-stride <tensor>  <hw-tag> (<bindings>) ...)
(hardware-stride <tensor> <layout-tag> <hw-tag> (<bindings>) ...)

;; examples
(hardware-stride someMatrix :row-major :workgroup-idx (grid-y grid-x) ...)
   
(hardware-stride someVector  :warp-idx (grid-x) ...)

```

`hardware-stride` takes a `<hw-tag>` argument and chunks the problem space by the physical hardware enqueue dimensions. For "strict", provide a `<layout-tag>`.

Just like `tile-stride`, `hardware-stride` acts as an **outer loop**. Its body executes once per hardware chunk, and the `<bindings>` represent the index of that chunk within the tensor. The key difference is that you do not provide a `<size-list>`; the chunk size is implicitly derived from the hardware environment.

There are two choices for `<hw-tag>`: `:workgroup-idx` and `:warp-idx`.

##### `:workgroup-idx` ✅

With `:workgroup-idx`, the tensor is chunked by the workgroup dimensions. The arity of the tensor and the bindings MUST match the arity of the workgroup enqueue.

```lisp
;; 2D enqueue
(hardware-stride someMatrix :row-major :workgroup-idx (grid-y grid-x) ;; which workgroup chunk is this?
   (let ((y x (tensor-coords grid-y grid-x)))  ;; which pixel of someMatrix is at its upper-left 
       
       ;; body executes once per workgroup cooperatively
       (load-tile ...) 
       ...))

```

##### `:warp-idx` ✅

With `:warp-idx`, the tensor is chunked into 1D segments equal to the hardware warp width. Note that if using `:warp-idx`, it is extremely important that the kernel is hoisted with a `local_work_size` that is a multiple of `(get-warp-size)`. Otherwise, operations like warp-level reductions could end up deadlocking.

Note that `hardware-stride :warp-idx` can be used with any global size arity, but it iterates over the flattened, global execution space by the hardware warp width.

Also note that `load-tile` and `store-tile` (and their async counterparts) are not available
from within a `:warp-idx` hardware-stride.  

```
(hardware-stride someVector :warp-idx (grid-x) 
      ;; body executes once per warp cooperatively
      ...)

```

> Implementation Note: Unlike `tensor-stride`, the chunking variants (`tile-stride` and `hardware-stride`) do not evaluate their bodies per-element. They stride the problem space in block-sized steps. For `hardware-stride`, those steps are driven dynamically by `(get-local-size)` or `(get-warp-size)`. Any element-level computation must be done in an inner loop (like `workgroup-stride`) inside the body.

#### Helper Macros ✅

The helper macros map the tensor coordinates to the other spaces.  These helper macros are
available when using the `tile-stride` and `hardware-stride` stride macros.

<!-- 
REMOVED FOR NOW
##### `tile-coords`
`tile-coords` always has the same arity as the binding and returns that same number of argumetns.
These coordinates are within the tile `<size-list>`/`<tile-tensor>`

```
(let ((t-z t-y t-x (tile-coords cube-z cube-y cube-x))) ...)
```
-->
<!-- REMOVED FOR NOW 
##### `tile-indices` ✅
`tile-indices` also matches arity. It returns the index coordinates of the tile
-->

<!-- 
 REMOVED FOR NOW 
##### `tensor-coords` 
```
(tensor-coords (<grid-indices>) &optional (<tile-coords>))
```
`tensor-coords` macro takes two arguments. A list of the tile indices followed by a list of the tile coordinates.
It returns mapping coordinates into the problem space tensor.

```
(let ((row-y col-x (tensor-coords (idx-y idx-x) (t-y t-x)))))
```
-->
<!-- 
HELPERS REMOVED

##### `load-tile` / `store-tile` ✅
There are two other helper functions that are present when doing "tileed" striding.  
They have their own section of the docs below.
-->
<!--  

NOTE: I'm temporarily setting the stride-subview helper function aside
NOTE: explain risk of deadlock   
 
NOTE: compiler will use this to DETECT possible deadlocks 
       this makes it EASIER to detect deadlocks at "ragged edges"
       we insert (declare :ragged-edge) or something 
TODO: figure this out. (declare (convergent)) and friends.

##### `stride-subview`
In the scope of `thread-stride` there is helper function `stride-subview` which returns another `tensor`.
 This `tensor` has the size and dimensions of the `chunkExpr` but is mapped to the current location in the problem space.

Note that in the event the problem space is not evenly divisible by the chunk, then the `tensor` that is returned
might have dimensions smaller than the chunk if it is near the memory boundary. This way there is no accidental out of bounds memory access.  


Note, also, that this chunk is a subview into the problem space, which is likely `:global`.
If you are wanting fast chunk access use `load-chunk` / `store-chunk` below to transfer to `:local` memory for fast operations.
-->



<!--

