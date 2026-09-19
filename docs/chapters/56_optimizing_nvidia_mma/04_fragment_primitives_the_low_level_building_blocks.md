# Fragment primitives (the low-level building blocks)


`mma-accumulate-via-tile` composes these lower-level forms.  Most kernels never write them
directly — reach for them only when you need a hand-rolled MMA loop the macro doesn't cover.
A *fragment* is one hardware MMA operand's worth of data, distributed across a warp's lanes.

```
(make-register-fragment <M> <N> <init>)          => an M×N accumulator fragment, filled with <init>
(load-fragment-a <src> (<ty> <tk>))              => the A operand fragment at tile (ty, tk)
(load-fragment-b <src> (<tk> <tx>))              => the B operand fragment at tile (tk, tx)
(mma-accumulate <c-frag> <a-frag> <b-frag>)      => a new accumulator = a-frag · b-frag + c-frag
(store-fragment <frag> <dest> (<ty> <tx>))       => write accumulator <frag> to <dest> at tile (ty, tx)
```

- The tile coordinates are in **fragment units** (a fragment is the MMA shape's M×N / M×K / K×N block),
  not element units.
- `<src>` / `<dest>` may be global memory or an SLM scratch tile — the per-lane layout is the same.
- These are **warp-collective**: each lane holds its slice of the fragment; the forms lower to the
  per-lane reads/writes (and, on NVIDIA, a single `mma.sync` for `mma-accumulate`).  On the SPV
  path they lower to `CooperativeMatrixLoadKHR` / `…StoreKHR` / the coop-matrix multiply — the
  operand `:contiguous-term` drives the KHR MemoryLayout (so B's row-major requirement above
  applies here too).
- `make-register-tile` is a *tile* of these fragments (an (M/frag-M)×(N/frag-N) grid), and
  `mma-accumulate-via-tile` walks that grid for you.

