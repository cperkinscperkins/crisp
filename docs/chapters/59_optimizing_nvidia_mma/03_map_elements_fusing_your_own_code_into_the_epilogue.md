# map-elements! ✅ — fusing your own code into the epilogue


```
(map-elements! <fragment-or-tile> #'<unary-fn>)   => nil ; applied to every element, IN PLACE
```

Applies a **unary function to every element**, in place, while the data is still in registers.
This is the mechanism for a fused epilogue — an activation, a scale, a clamp, anything
elementwise — without a round trip through memory.

**Status.**  The **fragment** form (on `mma-accumulate-via-tile`'s accum binding) is implemented
on both backends and verified on hardware.  The **whole-tile** form (in an `:epilogue`) and
`--differentiate` support are in flight; see `tests/spec/150-fused-epilogue/`.

The function is an ordinary Crisp `def-function`, not a compiler builtin:

```
(def-function leaky-relu (x)
  (declare #'(float => float))
  (if (> x 0.0) x (* x 0.5)))

(mma-accumulate-via-tile (16 8 8) C-tile A B (acc)
  (accum-op)                              ; the MMA fires
  (map-elements! acc #'leaky-relu))       ; then YOUR code, on the accumulator, in registers
```

That is the whole point: vendor libraries offer a fixed menu of epilogues (bias, relu, gelu …),
and anything off the menu costs you a full round trip to HBM — write C, read C, write C.  Here
the activation is just a function you wrote.  Crisp realises first-order functions by **template
monomorphization**, so there is no function-pointer indirection in the emitted kernel.

**It is the same idiom as `store-tile`'s `:transformF`**, at a different altitude.  Three places
can carry a per-element transform, and which one you want depends on where the data is:

| site | when it runs | form |
|---|---|---|
| accumulator fragment | in registers, per fragment | `map-elements!` on the accum binding |
| completed C-tile | in registers, once per output tile | `map-elements!` in the `:epilogue` |
| during the write-out | as each element goes to memory | `store-tile … :transformF #'f` |

For a pure elementwise activation, `:transformF` is often the best of the three — it rides a
store you were already doing, so it costs nothing extra.

> **⚠️ Do NOT fuse on `acc` inside a staged K-loop.**  When `matrix-multiply-tile-stride`'s
> `grid-k` loop calls `mma-accumulate-via-tile` once per K-step, `acc` holds a **partial sum**,
> and a map applied there mutates the accumulator that later K-steps keep adding to.  With `p1`
> and `p2` the two K-steps' contributions, doubling once in the `:epilogue` gives `2·p1 + 2·p2`,
> while doubling per K-step gives `4·p1 + 2·p2`.  Note this is **not** a statement about
> non-linear functions — the only function that survives per-step application is the identity,
> so even a scale is wrong.  The compiler refuses it; put the map in the `:epilogue`, where the
> tile is complete.

**Elementwise only, and that is deliberate.**  A fragment is warp-collective, and which logical
`(row, col)` a given register holds is a per-vendor layout detail.  An elementwise function does
not care — applying `f` to each register independently is identical to applying it to the logical
matrix — which is exactly what makes this portable.  Operations that *do* need the coordinate
(adding a bias along N, row-wise reductions like softmax) are not expressible this way and are
not supported.

**What it lowers to.**  The two vendors differ, and it shows up in the generated code:

- **NVIDIA / PTX** — a fragment is a record of scalar registers whose count is known at compile
  time, so the map is **unrolled** fieldwise (four applications for a tf32 `m16n8k8`
  accumulator), directly after the `mma.sync`.
- **Intel / SPV** — a fragment is an opaque cooperative matrix whose per-invocation component
  count is a **runtime** value (`OpCooperativeMatrixLengthKHR`), so the map is a **loop** over the
  components, each reached with `OpAccessChain`.  This is the same fact as the paragraph above:
  the kernel never learns which logical element it holds.

