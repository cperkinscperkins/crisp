# `mma-lowering` ✅


```
(def-kernel matmul (A B &out C)
  (declare #'(a-mat b-mat &out c-mat)
           (mma-lowering :xe-native)
           (global-size :derive-from C :strategy :strided)
           (local-size :set-to 16))
  ...)
```

A kernel declaration selecting which code-generation strategy to use for this kernel's matrix-engine
operations. The hardware profile declares what is *available* (`:mma-lowerings`); the kernel declares
what it *wants*. Omitting it takes the profile's default, which is `:coop-matrix` unless a profile
says otherwise.

**Why you would use it.** `:coop-matrix` is portable and is what every Crisp kernel has always
emitted. `:xe-native` is Intel-only and emits the DPAS instruction directly, with 2D block loads
instead of cooperative-matrix loads. On an Arc B580 it is measurably leaner — 42 machine
instructions per `dpas` against 57 — and at matched geometry it measured +13% at N=2048 and +9% at
N=4096 for bf16.

**It is not automatically better.** Measured on the same hardware, `:xe-native` does *not* currently
compose with a register-tile ring: the shipped bf16 kernel (`:coop-matrix`, ring depth 2, prefetch
distance 2) reaches 60.4 TFLOPS at N=2048, while the same kernel with only the lowering changed
reaches 50.0. Treat it as a parameter to measure, not an upgrade to apply.

**Crisp refuses; it never falls back.** Asking for a lowering the active profile does not offer is a
compile error naming both sides:

```
mma-lowering :XE-NATIVE is not available on the active hardware profile (kernel MATMUL).
This profile offers: :COOP-MATRIX.  Crisp REFUSES rather than falling back to a different
lowering, because a silent downgrade would give you a slow kernel and no way to see why.
```

An unknown *name* is reported differently from a known-but-unavailable one, because the first is a
typo and the second is a portability decision, and they want different fixes.

**The chosen lowering is recorded** in the kernel's `.metacrisp` as `:mma-lowering`, even when it was
defaulted, so a benchmark number can be attributed to a code path.

**Current limits of `:xe-native`**, each a compile-time refusal rather than a silent approximation:

- bfloat16 and half operands only (the instruction's K and operand mask are not inferable for others)
- a zero fragment initialiser only (a non-zero splat needs the per-lane encoding)
- a subgroup width of 16 (the fragment layout is derived from it)
- one operand element type per kernel — a kernel mixing bf16 and fp16 operands is refused, because
  the instruction takes a single mask describing A and B together

There is **no command-line flag** for this. The lowering is selected in the kernel source, or
inherited from the profile default.

