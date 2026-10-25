# mma-accumulate-via-tile ✅

```
(mma-accumulate-via-tile (<sz-expr>) C-tile A-tile B-tile (<accum-binding>) 
  ;; in the context of this macro, the helper `accum-op` is available.
  ;; call it once to perform the MMA accumulation.
  ...)
```

`mma-accumulate-via-tile` walks the tile in steps of `<sz-expr>` — an `(M N K)` triple that must match one of the Tensor MMA units of the underlying hardware.
The `<sz-expr>` you pass to `mma-accumulate-via-tile` is checked against the active profile's `:mma-shapes` (also an `(M N K)` triple). A shape the hardware doesn't list is a compile error. With no active profile, the shape is accepted unchecked.

Also note the multiplicity constraints: the output tile's M and N must each be a multiple of the shape's M and N, and the K-loop extent (the matrices' inner dimension) must be a multiple of the shape's K.

Two further compile-time constraints, both checked from information you already declare:

- **Operand layout.** The A and B matrices' `:contiguous-term` (`:row-major` / `:col-major`)
  selects which hardware MMA variant is emitted, and a layout the chosen instruction cannot accept
  is a compile error.  The canonical NVIDIA form is A row-major, B **column-major**
  (`mma…row.col`); Intel requires **every** operand `:row-major`.  Use `:transpose` on the tile
  load to reconcile a source stored the other way.  The Intel rule and its workaround have their
  own section below.
- **Precision.** The `(M N K)` triple encodes operand *precision* — the same M×N comes in
  several K variants for different dtypes (e.g. k16 for fp16, k8 for tf32). The shape you pass
  must match your operands' element type, or it is a compile error.

Physical SLM *swizzling* (bank-conflict avoidance) is a separate performance optimization, not
a correctness requirement — a plain row/col-major staging feeds the fragment loads correctly.

The baseline kernel above passes `(16 8 8)` — the **tf32** shape (K=8), matching tf32/`float`
operands. The same M×N with **fp16** operands is `(16 8 16)`, which is the variant the expansion
below illustrates (note its `mma.m16n8k16` intrinsic and K-step of 16).

The forms this macro composes — `make-register-fragment`, `load-fragment-a` / `-b`,
`mma-accumulate` and `store-fragment` — are documented under **Fragment primitives** below, for
the rare kernel that needs to hand-roll the loop.

