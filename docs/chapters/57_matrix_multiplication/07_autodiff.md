# Autodiff ✅


The MMA forms differentiate.  `--differentiate` walks a tile-level matrix multiply and emits a
backward kernel like any other, and because the VJP selects its own lowering the rule holds at
every altitude these forms are written at — from `matrix-multiply-tile-stride` down to a
hand-rolled fragment loop.  The exception is Hopper’s `wgmma-accumulate-via-tile`, which is
forward-only.

**For `half` / `bfloat16` operands, the backward kernel’s gradient values are `float`.**  The
general rule and its ABI consequence — a host must size 16-bit gradient buffers at 4 bytes per
element — are under
[Promoted adjoint types](#promoted-adjoint-types) in the Auto Differentiation section.

**The backward still issues 16-bit MMA.**  That promotion covers adjoint *storage*, not the
matrix multiply.  The operands the backward feeds to the tensor cores — `dC`, `Aᵀ`, `Bᵀ` — take
their element type from the forward tile, so they stay 16-bit and the backward keeps the same
tensor-core path, the same shapes, and the same lowering the forward used.  A 16-bit kernel does
not quietly become an fp32 kernel when you differentiate it.

Verified on metal: `tests/spec/163-autodiff-revisit/01-fp16-mma-gradient-bmg.crisp` checks a
16-bit MMA gradient against a real number on an Arc B580 — analytical 1.2000704 against an
expected 1.2.


