# matrix-multiply-tile-stride ✅

```
(matrix-multiply-tile-stride <C-matrix> <C-matrix-tile> <K-inner-dim-scalar> <k-step> (<grid-bindings>) ...)

```

Given `A`, `B` and `C` with `A x B = C`, this macro strides and walks the output space one tile at
a time.  It does not perform the multiplication and so does not take `A` or `B`: it needs the `C`
matrix, the tile view into `C`, the inner dimension `K`, and the tile dimension that strides `K`.
Each iteration binds `<grid-bindings>` for you.  Use this macro together with
`mma-accumulate-via-tile` and nearly all the boilerplate of a matrix multiply is handled.

`<k-step>` is the K-extent of the staging tiles. It is the dimension A-tile and B-tile share.   `K / <k-step>` give the loop trip count.
 

`<grid-bindings>` are `(grid-y grid-x grid-k)`

Inside the body of the macro, `grid-k` will be the fastest changing term as it loops over K. 
This macro is very handy for producing matrix multiply kernels.  If used in conjunction with `mma-accumulate-via-tile` 
then nearly all the boilerplate of a matrix multiply is handled.

**The `:epilogue` (store + fusion).** The macro owns the `grid-y`/`grid-x` spatial and `grid-k`
reduction loops, but it does **not** store `C-tile` for you.  Split the body with an `:epilogue`
marker: forms **before** it run once per K-step (the reduction); forms **after** it run once per
tile, post-reduction, with `grid-y`/`grid-x` in scope and `C-tile` complete.  That is where your
store — and any fused epilogue (ReLU, bias, scale) — go:

```
(matrix-multiply-tile-stride C C-tile K k-step (grid-y grid-x grid-k)
  ;; per-K-step reduction body
  (load-tile A A-tile (grid-y grid-k))
  (load-tile B B-tile (grid-k grid-x))
  (sync-workgroup)
  (mma-accumulate-via-tile (16 8 8) C-tile A-tile B-tile)
  (sync-workgroup)
  :epilogue                               ; <- once per tile, post-reduction
  (relu C-tile)                           ; optional fused epilogue on the completed tile
  (store-tile C-tile C (grid-y grid-x)))  ; explicit store — you own the write-back
```

The explicit `:epilogue` keeps
the macro lean and the store honest — and it makes the progression to ring pipelining / warp
specialization (which also store explicitly) consistent.  **If a kernel never stores its `C-tile`,
the compiler warns** (a matmul that discards its result is almost always a bug).

> **Where does the activation go — `my-accum` or `:epilogue`?**  `mma-accumulate-via-tile` exposes
> a per-fragment accumulator (`my-accum`, in registers) for fusion, and the macro exposes a
> per-tile `:epilogue`.  The form that does the fusing in either place is
> `map-elements!`.
> Use whichever owns the *complete* reduction: if
> `mma-accumulate-via-tile` does the whole K-contraction itself, fuse on `my-accum` (finer,
> in-register).  But in this **staged** pattern — the macro's `grid-k` loop calls
> `mma-accumulate-via-tile` once per K-step — `my-accum` holds a **partial** sum each step, so the
> activation belongs in the macro's `:epilogue` (on the completed `C-tile`), **not** on `my-accum`.
> Fusing on `my-accum` here is a compile-time **error**, not merely bad practice — see the
> partial-sum warning under `map-elements!` for why even a linear function is wrong.

**Grid semantics.** `grid-y` / `grid-x` are TILE-IDs — 0-based tile coordinates over `C`'s output
tiles (sized by `C-tile`) — which is exactly what `load-tile` / `store-tile` expect (they scale a
tile-ID by the tile's extent).  `grid-k` is the K-step index, `0 .. K/<k-step> - 1`.  The macro is
grid-strided: a workgroup owns **≥ 1** `C`-tile and strides across the grid, so it works whether
you launch one workgroup per output tile (a 2-D grid = (#row-tiles, #col-tiles)) or fewer.

**Accumulator reset.** The macro resets `C-tile` at the start of each output tile's reduction, so
a workgroup that owns more than one tile does not carry the previous tile's partial sums into the
next.  A register tile resets to the init it was declared with; a scratch tile, which has no
declared init, resets to `0.0`.  You do not write the reset yourself.

**Chapter 0 (synchronous) — what ships today.** The Chapter-0 body is fully synchronous: stage with
plain `load-tile` (no `:barrier`), `sync-workgroup`, `mma-accumulate-via-tile`, `sync-workgroup`.
```
(def-kernel matmul (A B &out C)
  (declare #'(a-mat b-mat &out c-mat) (local-size :set-to 32))
  (let ((A-tile (make-scratch-matrix float (64 8)))
        (B-tile (make-scratch-matrix float (8 64)))
        (C-tile (make-register-tile float (64 64) 0.0))
        (K      (inner-dimension A B)))
    (matrix-multiply-tile-stride C C-tile K 8 (grid-y grid-x grid-k)
      (load-tile A A-tile (grid-y grid-k))
      (load-tile B B-tile (grid-k grid-x))
      (sync-workgroup)
      (mma-accumulate-via-tile (16 8 8) C-tile A-tile B-tile)
      (sync-workgroup)
      :epilogue                               ; <- once per tile, post-K-loop
      (store-tile C-tile C (grid-y grid-x))))) ; you own the store
```
The kernel above is the **shared synchronous baseline** — it ships and is metal-correct on both
NVIDIA and Intel.  Optimizing past it splits by vendor; the two arcs follow below.

