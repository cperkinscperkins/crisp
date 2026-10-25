# `prefetch-tile` ✅


`(prefetch-tile src (coord-y coord-x) :size (h w) &key warp-partitioned) => nil`

**Intel only.**  Warms the cache for an `h x w` block of the 2-D global tensor `src`, starting at the
element coordinates `(coord-y coord-x)`, so that a later register load of that block (`load-tile`
into a register tile feeding the XMX engine) hits cache instead of stalling on memory.  It has no
destination and never changes a result: it is a fire-and-forget hint, lowered to SPIR-V
`Subgroup2DBlockPrefetchINTEL`.

* Requires `--hardware-profile`: the profile's L1 / GRF limits drive the register-pipeline safety
  analysis.  Refused on PTX (NVIDIA's prefetch model is `cp.async` into shared memory, a different
  construct — use `load-tile` with `:barrier`).
* `:size` must be a compile-time `(h w)` of integers; the coordinates must be a two-element list.
* `:warp-partitioned t` spreads the footprint across the workgroup's warps — each warp prefetches
  its own hardware blocks instead of every warp prefetching the whole footprint.  It needs a literal
  `local-size` (the warp count is `local-size / simd-width`), is implemented for 2-byte elements
  (`half`, `bfloat16`) only, and requires `h` and `w` to tile into whole hardware prefetch blocks.
  When there are fewer blocks than warps, the surplus warps re-prefetch a block another warp already
  asked for — deliberately: a duplicate prefetch costs one instruction, while a branch around a
  prefetch is BUG 051.
* The prefetch takes its cache control from `src`'s type (`:cache`, see *Cache hints*); a `:cache`
  key on `prefetch-tile` itself is refused.

Typically issued in a `matrix-multiply-tile-stride` `:prologue` (to warm the first K-steps) and again
inside the loop a fixed distance ahead of the loads it serves:

```lisp
(matrix-multiply-tile-stride C C-tile K 8 (grid-y grid-x grid-k)
  :prologue (prefetch-tile A (grid-y 0) :size (32 8))
  ...)
```

(Endeavours 142 and 158.)

