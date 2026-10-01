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

**Sections — `:let`, `:prologue`, `:body`, `:epilogue`.** `:epilogue` is one of four section
markers. Most kernels need only it; the other three exist for the two things the bare envelope
could not express — a binding scoped over the K-loop, and per-tile setup that runs before it.

```
(matrix-multiply-tile-stride C C-tile K k-step (grid-y grid-x grid-k)
  :let      ((A-ring (make-register-tile-ring float (32 8) :ring-count 2 :operand :a))
             (B-ring (make-register-tile-ring float (8 64) :ring-count 2 :operand :b))
             (C-tile (make-register-tile float (32 64) 0.0)))
  :prologue (prefetch-tile A (grid-y 0) :size (32 8))      ; once per output tile,
            (load-tile A (ring-get A-ring 0) (grid-y 0))   ;   BEFORE the K-loop
  :body     (load-tile A A-tile (grid-y grid-k))           ; once per K-step
            (load-tile B B-tile (grid-k grid-x))
            (mma-accumulate-via-tile (8 16 8) C-tile A-tile B-tile)
  :epilogue (store-tile C-tile C (grid-y grid-x)))         ; once per tile, post-reduction
```

`:let` takes one binding group and is an ordinary Crisp `let` — sequential, and it destructures
multiple values, so `(q r (truncate x))` works exactly as it does anywhere else. Its bindings
are entered **per output tile**, inside the stride loop, and they scope over the prologue, the
K-loop and the epilogue. That is what lets a register tile or a ring live where it belongs; before
sections, a kernel that needed one had to abandon the macro and hand-write its expansion.

`:prologue`, `:body` and `:epilogue` each hold one or more forms (an implicit `progn`). `:let`
does not — it holds bindings, not statements.

Three rules, all enforced at compile time:

* **The sections must appear in the order above.** The split is positional, so a `:prologue`
  written after `:epilogue` would still lower to code that runs *before* the K-loop — the text
  would read one way and execute another. That is an error rather than a convention.
* **The marker set is closed.** A keyword in section position that is not one of the four is an
  error, because it is almost always a typo. A mistyped `:epilog` used to be folded silently into
  the reduction body, which stored the tile on every K-step.
* **`:body` is required once `:let` or `:prologue` is used.** Both the prologue and the reduction
  are bare form sequences, so without a marker there is nothing to separate them, and guessing
  would quietly move a warm-up into the loop (or a load out of it). With neither present the body
  may stay unmarked, which is why every pre-section kernel still compiles untouched.

**Accumulator reset.** The macro resets `C-tile` at the start of each output tile's reduction, so
a workgroup that owns more than one tile does not carry the previous tile's partial sums into the
next.  A register tile resets to the init it was declared with; a scratch tile, which has no
declared init, resets to `0.0` and gets a `sync-workgroup` after it, since filling scratch is a
workgroup-collective write.  You do not write the reset yourself.

One nuance, and it costs nothing to know: a **register** tile declared in `:let` is already
re-initialised per output tile by its own binding, so the macro emits no second reset for it. A
scratch tile has no init to re-run, so the macro's reset is what does the work wherever it is
bound. Either way the guarantee is the same.

The reset runs **before** `:prologue`, which is what makes a seeded accumulator expressible: the
tile starts at its declared init and the prologue may then overwrite it — with a bias tile, say —
without the macro clobbering the seed afterwards.

> **Not yet differentiable: a scratch tile declared in `:let`.** Under `--differentiate` a
> `make-scratch-matrix` bound in a nested `let` — which is what `:let` lowers to — gets a scalar
> adjoint where the backward wants a tensor. The same bindings in the kernel's enclosing `let`
> differentiate fine, and so does a **register** tile in `:let`. This predates sections and is
> reproducible with no macro at all; see BUG 064.

**Grid semantics.** `grid-y` / `grid-x` are TILE-IDs — 0-based tile coordinates over `C`'s output
tiles (sized by `C-tile`) — which is exactly what `load-tile` / `store-tile` expect (they scale a
tile-ID by the tile's extent).  `grid-k` is the K-step index, `0 .. K/<k-step> - 1`.  The macro is
grid-strided: a workgroup owns **≥ 1** `C`-tile and strides across the grid, so it works whether
you launch one workgroup per output tile (a 2-D grid = (#row-tiles, #col-tiles)) or fewer.

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

