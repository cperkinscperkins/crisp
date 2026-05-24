## Load Tile / Store Tile


`load-tile` and `store-tile` work with tensors of any arity, not only 2D matrices.

`load-tile` is used to copy data from the :global address space problem space tensor
to the :local address space tile tensor.

`store-tile` does the opposite. Storing the :local tile tensor into the original problem
space tensor.  

Note that these helper macros are coordinate aware. When used from within `tile-stride` or `hardware-stride`
stride macros, they know where the current tile "cursor" is and how to map between the problem space and the tile.

There are also asynchronous variants.


```
;; Helpers
(load-tile <src-problem-space-tensor> <dest-tile> &key (identity 0) transpose)
(request-load-tile <src-problem-space-tensor> <dest-tile> &key (identity 0) transpose) => request-token



;; Helpers
(store-tile <src-tile> <dest-problem-space-tensor> &key transformF transpose)
(request-store-tile <src-tile> <dest-problem-space-tensor> &key transpose) => request-token


(await-request request-token)
```

`<problem-space-tensor>` can be any tensor whose arity matches the surrounding tile-stride / hardware-stride and whose element type is compatible with <tile>. Extents, strides, offset, address space, alignment, and contiguous-term may all differ from the stride's tensor — the cooperative loop reads each tensor through its own metadata, and the in-bounds check uses the passed tensor's extents (so ragged or under-sized destinations just skip out-of-range writes / fill with :identity on the load side).

`<tile>` is a small `tensor` , the same dimensions of the `<tile-size>` for the `tile-stride`.
It is typically `:local` address space.

The `:identity` key can be used when the problem space
is not evenly divisible by the tile size.  In that case, the tile will be correctly loaded with
data from the problem space where possible, but the REMAINING values of the tile will be loaded with the `:identity` value (which defaults to 0)

`:transpose` key.  The tile will simply lift the data right out of the problem space tensor, 
whether it is `:col-major` or `:row-major`, and so have the same layout, just smaller.  
But the `:transpose` argument can be used to change that. For tensors of arity 1 (vectors), the `:transpose` is ignored. For arity 2 (matrices) then if `:transpose true` then
the `x` and `y` coordinates will be swapped.
For tensors with an arity of three or greater, the `:transpose` keyword accepts a permutation list (such as `'(0 2 1)`) to explicitly dictate how the axes are reordered when mapping to local memory. Providing a simple boolean `true` serves as a convenient shorthand for this list, defaulting to swapping only the two innermost dimensions while preserving the outer batch structure.



`load-tile` will map the `<tile>` to the appropriate place in the problem space and 
load the tile with the data there.  

Similarly, `store-tile` does the reverse - copies memory from some tile vector
into the appropriate location in the problem space data. This is usually used with 
some `&out` output memory whose size is identical to the problem space. 

The usual practice is that the problem space tensor is `:global` and the tile is `:local`.


`store-tile` can also accept a `:transformF` key. This is a function of `binop-type` that
can be used to transform the value as it is stored. Note that the asynchronous version does
not support the `:transformF` key.

> Implementation Note: first order functions are automatically templated and monomorphically specialized in Crisp

### local-barrier

Both `load-tile` and `store-tile` invoke `(local-barrier)` at the completion of their
operation. This prevents read-after-write and write-after-read race conditions. 
But be aware, that this also means these functions should NOT appear in conditional blocks 
( `when`, `if`, `cond`, `unless`) or you will incure a deadlock. The Crisp compiler should
detect this and emit an error.

### Asynchronous Variants
Crisp also provides asynchronous variants of these tile load and store helpers.
THe `request-XXXX` variants return a `request-token` which can be awaited on with `(await-request <token>)`

```
(let ((my-tile (make-scratch-vector float :match-workgroup-size)))
  (tile-stride big-vector my-tile (x)
    (let ((token (request-load-tile big-vector my-tile))
           ;; we can do OTHER operations before we await.
           ;; just don't touch the data behind big-vector or my-tile.
          (idx (tile-indices x)))
        (await-request token)
        ;; now we can touch my-tile
        (workgroup-stride my-tile (wx)
           (inc! (~ my-tile wx) 10))
        (store-tile my-tile big-vector)
        ...)))
```



### Choosing the Right tile Size

When utilizing `load-tile` and `store-tile`, the shape and size of your `<tile-tile>` directly dictate how the GPU's memory controller fetches data. Choosing the wrong size will result in uncoalesced memory reads and severe performance degradation.

Follow these three guidelines when defining your tile sizes:

#### Capacity: Match the Workgroup Size
Because `load-tile` is a cooperative workgroup operation, the total number of elements in your tile should ideally be a perfect multiple of your `local_work_size`. 
- If your workgroup size is 64 threads, a tile of 64 elements means exactly 1 read per thread. 
- A tile of 128 elements means exactly 2 reads per thread. 
- If you pick an arbitrary total like 50 elements for a 64-thread workgroup, 14 threads sit completely idle while the memory controller waits for the active threads to finish. 

#### Warp : Stretch the Contiguous Dimension
GPU memory is physically 1-dimensional. Cache lines are pulled in 64-byte or 128-byte linear blocks. Therefore, your tile should not be shaped like a square if you can avoid it. It should be stretched as wide as possible along the tensor's `:contiguous-term`.

For a `:row-major` (or `:contiguous-last`) matrix, the contiguous term is the X-axis (the columns). 
- BAD (The Square Trap): A tile of `(Y=8, X=4)`. A warp of 32 threads will be divided across 8 different rows, requesting 4 elements from each. The hardware has to fetch 8 entirely separate cache lines simultaneously, wasting huge amounts of bandwidth.
- GOOD (The Stretched Tile): A tile of `(Y=2, X=16)`. 16 contiguous elements (64 bytes of floats) fit perfectly into a single cache line. 
- PERFECT:*A tile where the contiguous dimension is exactly the Warp Size (e.g., `X=32`). All 32 threads in the warp hit adjacent memory addresses simultaneously, resulting in a single, perfectly coalesced memory transaction.

#### Algorithmic Concerns: Why Square Tiles Exist
If stretched tiles are so fast to load, why do algorithms like Matrix Multiplication (MatMul) famously use square tiles (like `16x16` or `32x32`)?

Because in MatMul, the bottleneck isn't just loading the data; it is reusing the data. A `16x16` tile loaded into `:local` memory allows the workgroup to perform 256 math operations without returning to global memory. A stretched `2x128` tile might load faster, but it provides far less mathematical reuse for the algorithm.


<!-- Next is the new workgroup-stride API.  The old one follows it and is commetnd out -->

