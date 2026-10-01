# Operand layout: Intel MMA operands must be `:row-major` ✅


An Intel MMA operand — the `A` and `B` matrices, and the accumulator — must be declared
`:contiguous-term :row-major` (equivalently `:last`). A `:col-major` operand is a **compile
error**, not a silent fallback:

```
Intel cooperative-matrix (MMA) operands cannot be :col-major (:contiguous-term :first).
IGC ships no PackedA_ColumnMajor / PackedB_ColumnMajor load builtin, so such a kernel
fails to build on the device, and a ColumnMajor accumulator computes incorrectly.
Declare the operand :row-major, or stage an explicit transpose into scratch and feed the
MMA from there. (NVIDIA/PTX is unaffected.)
```

This is a limitation of the **hardware's builtin library**, not a Crisp design choice, and it
was measured rather than assumed. Crisp translates `:col-major` to `MemoryLayout =
ColumnMajorKHR` on the `CooperativeMatrixLoadKHR`, which is valid SPIR-V — but on an Arc B580
(driver 32.0.101.8864) IGC then fails the module build with:

```
undefined reference to `__builtin_spriv_OpJointMatrixLoadINTEL_
  PackedB_ColumnMajor_SG16_8x16_i32_8_global_v8i8_pi32_i32'
```

and the same for `PackedA_ColumnMajor` on a column-major `A`. IGC simply does not ship
ColumnMajor variants of the operand-load builtins. A column-major **accumulator** is a
slightly different story — that builtin *does* exist and the module builds — but it then
computes the wrong result on metal, so it is refused too, conservatively, until that is
understood.

**If you need a column-major operand**, stage the transpose explicitly into scratch and feed
the MMA from the staged tile. That keeps the cost visible and under your control — it is what
the MMA autodiff backward does for its transposed operands.

> **This is per-vendor, like the shapes.** On NVIDIA/PTX the layout is baked into the
> `mma.sync` instruction variant (`row.col`) rather than read from the tensor type, and
> `:col-major` **B** is the *canonical* form there. So the same source may want a different
> operand layout per backend, exactly as it wants a different `:mma-shapes` triple.

Specs: `133-mma-spv/13-col-major-operand-refused-bmg`, `14-col-major-accum-refused-bmg`.

