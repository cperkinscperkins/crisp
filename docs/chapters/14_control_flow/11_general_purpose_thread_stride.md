## General Purpose: `thread-stride`


While `loop-vector-stride` is very handy and one of the most commonly used Crisp affordances, 
it's one task is to just employ all the threads to walk a vector. Sometimes you'll need more.
That's when `thread-stride` will come in play.  `thread-stride` allows you to configure any
type of grid level stride. `loop-vector-stride` uses `thread-stride` under the hood.

```
(thread-stride <problem-space> <chunkExpr> (<bindings>) ...) 
```

`problem-space` 
- a  1D vector, 2D matrix or 3D tensor 
- size list: `(width)` or `(width height)` or `(width height depth)` 

`chunkExpr` 
- `:global-size` (normal grid stride, could be 1D, 2D, or 3D) 
- `:workgroup-idx`  could be 1D, 2D, or 3D
- `:warp-idx`  1D only
- a small 1D vector, 2D matrix or 3D tensor
- small sizes: `(w)`, `(w h)`, or `(w h d)`

`bindings`
- `(x)`, `(x y)`, `(x y z)`

IMPORTANT: the arity of the problem space MUST match the arity of the bindings. 

The "problem space" is the space of the problem you want strided. Like a very large 
vector or matrix, or you can just provide numeric values in a quoted list.

The "chunk expression" is the grouping of the stride. If `:global-size` then it's
like the example with explanation above, where bindings are sequential and any 
single thread strides by the count of all of them.

For `:workgroup-idx` the threads are grouped by workgroup and each thread in each workgroup gets the
same base value for its bindings: that workgroups index. And the stride is number of workgroups.
So for a workgroup size of 64 and four total workgroups, threads 0 to 63 ALL get [0, 4, 8, ...] 

`:warp-idx` is just like `:workgroup-idx` except the threads are grouped by warp and it is 1D only.
Note that if using `:warp-idx` that it is extremely important that the kernel is hoisted 
with a `local_work_size` that is a multiple of `(get-warp-size)`.  Otherwise operations like warp level
reductions could end up deadlocking.

For the "small" vectors, etc or direct sizes, the bindings are index values shared by all threads grouped
by that size.  Note that the "small" vectors or "small" sizes do NOT need to have the same
arity as the problem space. The "small" variants CANNOT be bigger than the net workgroup size. 



### coordinate conversion when striding

Inside the scope of `thread-stride` there are two helper functions defined for you: `problem-space-coords`
and `chunk-coords`.  These take the current index bindings, combined with the current thread id and
calculate the coordinate back into the problem space or into the chunk.

These functions take no arguments themselves, and the value they return has the same arity 
as the problem space or chunk expression. 

```
(problem-space-coords) => (x ...)

(chunk-coords) => (x ...)
```

### tensor in problem space
```
(problem-space-view) => tensor
```
In the scope of `thread-stride` there is another helper function which returns a `tensor`. This `tensor`
has the size and dimensions of the `chunkExpr` but is mapped to the current location in the problem space.

Note that in the event the problem space is not evenly divisible by the chunk, then the `tensor` that is returned
might have dimensions smaller than the chunk if it is near the memory boundary. This way there is no accidental out of bounds
memory access.  
<!--
 NOTE: explain risk of deadlock   
 
 NOTE: compiler will use this to DETECT possible deadlocks 
       this makes it EASIER to detect deadlocks at "ragged edges"
       we insert (declare :ragged-edge) or something 
  TODO: figure this out. (declare (convergent)) and friends.
-->

Note, also, that this is tensor is into the problem space, which is likely `:global`. If you are wanting fast chunk access
use `load-chunk` / `store-chunk` below to transfer to `:local` memory for fast operations.

### Example - Fill a 2D Matrix
```
(def-grid-function matrix-fill (value &out output-m)
  (declare #'(float (matrix float :global :writeable)))
  (thread-stride output-m :global-size (x y)
    (set! (~ output-m y x) value)))
```


### `ceil-pow2`

For certain operations, like warp reductions, it is imperative that certain activities
fit completely in a warp and are not "split" across warp divide. 

If the argument to `ceil-pow2` is a power of 2, it'll be returns. But if not, then the
next hightest power of 2 will be returned. This can be very handy in loops
or for making sure chunk strides don't split work across the warp boundary. 

```
(ceil-pow2 4) => 4
(ceil-pow2 5) => 8
```


