# The VJP Signature Rule (vetted)


When you call a foreign function inside a `--differentiate` kernel, the compiler cannot see inside the
C black box, so you must supply its backward pass — a Vector-Jacobian Product (VJP) — as the third
argument to `def-foreign-function`. The compiler mechanically derives the VJP's required signature
from the forward signature; your `def-function` must match it exactly.

Type categories:
- **Active scalars** — `int`, `float`, `long`, etc. Differentiated; gradients promoted
  (`int`/`float`→`float`, `long`/`ulong`→`double`).
- **Active memory** — `(c-pointer ...)` / `voidp`. Differentiated via shadow buffers.
- **Passive** — `(c-handle ...)`. Ignored in every gradient phase.

**VJP inputs** (appended strictly in this order):
1. **Primals** — the exact original forward arguments.
2. **Seeds for active returns** — if the forward returns an active scalar, append its gradient seed
   (promoted type). (Active-memory returns are out of scope for now.)
3. **Shadow pointers for active-memory inputs** — for each pointer argument, append a shadow pointer
   into which the VJP accumulates that buffer's gradient.

**VJP outputs**:
- One gradient per active **scalar** input, in forward order. (Promoted: `float`, or `double` for
  64-bit primals.) Pointer-input gradients are written through the shadow pointers, not returned.

> Crisp does not trivialize integers. An `int` primal still demands a returned `float` gradient; a
> `long` primal a `double`. The compiler's signature generator is blind to semantics — even a
> logically-zero gradient (e.g. a buffer `size`) must be returned as `0.0` to keep the ABI sound.


