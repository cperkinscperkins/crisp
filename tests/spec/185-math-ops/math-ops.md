# Endeavour 185 — math-ops

The math operations the design doc (chapter 32) promises but that never received real
implementations, plus three transcendentals the contests will want.  Found 2026-10-12 while
verifying the agent guide (BUG 119).

## Inventory (2026-10-12, both backends, int and float operands)

| Chapter | Operation | Before 185 |
|---|---|---|
| 32/02 (marked ✅) | `sqrt`, `rsqrt` | missing ("Unsupported form") |
| 32/02, 32/03 | `exp log log2 sin cos tan asin acos atan pow atan2` | work (PTX needs libdevice) |
| 32/04 (marked ✅) | `abs`, `clamp`, `*!` | missing |
| 32/04 | `min`, `max` | work |
| 32/05 (marked 📝) | `ash logand logior logxor lognot popcount` | missing |
| 32/06 (marked ✅) | `(floor a b)`, `(ceil a b)`, `(round a b)` | **SILENTLY WRONG**: registered as float->int casts, so the divisor was ignored -- `(floor a b)` compiled to `ret a` |
| 32/06 | `/` giving quotient AND remainder | quotient only |
| 32/06 | one-argument `(floor x)` / `ceil` / `round` on a float | **SILENTLY WRONG**: BITCAST the float's bits (`(floor 2.5)` gave 1075838976); only `truncate` converted |
| (not in docs) | `tanh`, `erf`, `exp2` | missing |
| bugs.md 062 | unsigned `/` and `rem` | emit a SIGNED divide |

## Decisions (agreed with Chris 2026-10-12)

**D1. Integer division returns both values only where you bind both.**  Chapter 06's semantics hold:
`/`, `floor`, `ceil`, `round` on integers give a quotient and a remainder.  But `(/ a b)` stays an
ordinary single-value expression everywhere; the remainder exists only in a multiple-value binding,
`(let ((q r (floor a b))) ...)`.  Why: making `/` a multi-value node everywhere would touch every index
computation and land on known weak spots (BUG 093: an `if` whose branches return multiple values;
BUG 063: a multi-value binding feeding AD).  GPU cost of the remainder is nil either way (integer division
is a ~20-instruction software sequence on both vendors; the remainder is one multiply and one subtract,
and LLVM drops it when unused); the floor / ceil / round corrections are selects, never branches.

**D2. One-argument `floor` / `ceil` / `round` / `truncate` stay float -> int conversions.**  The two
forms are told apart by arity.  A two-argument form on FLOATS is a compile error (chapter 06 is
integer division); write `(floor (/ a b))`.

**D3. `ash` has Common Lisp semantics, fully defined on every GPU.**  Positive count shifts left,
negative shifts right; right shifts are arithmetic for signed types, logical for unsigned.  A shift
by at least the bit width is defined, as in Common Lisp: left -> 0; right -> 0, or -1 for a negative
signed value.  (LLVM makes such shifts poison and the hardware disagrees -- PTX clamps, SPIR-V leaves
it undefined -- so Crisp defines it.)  A literal count costs nothing extra; a runtime count costs a
select or two, branch-free.

**D4. `sqrt` / `rsqrt` follow the transcendental precision machinery** (endeavour 128): `ieee` ->
`llvm.sqrt` (correctly rounded); `fast` -> the approximate hardware instruction.  `ieee` `rsqrt` is
`1/sqrt`.  Neither needs libdevice.

**D5. `tanh`, `erf`, `exp2` join the transcendentals** (not in the design doc; added for the contests):
libdevice on PTX, the platform's builtins on SPIR-V, an AD rule each.

**D6. `*!` on the basic types is `*`** -- chapter 32/04 says `(accum T)` is `T` for them.  The
widening forms belong to the quantized / microfloat rework.

## Status

- **P0 DONE 2026-10-12** -- specs 01-07 + errors/01 pass on the BMG (TEST-HOIST[L0]) and under --differentiate.
  BUG 062 fixed.  Integer floor / ceil / round lower to a call to an internal noinline helper because of
  **BUG 120** (inline + SLP-vectorized, the BMG stored nothing; open, see bugs.md).
- **P1 DONE 2026-10-12** -- sqrt / rsqrt / abs / clamp / *!: specs 08, 09, 14 on the BMG; 10-13
  VERIFY-AUTODIFF on the BMG (0.25, -0.0625, -3.0, 2.0 against finite differences); errors/02.
  Registered by name in both packages (sqrt / abs are COMMON-LISP symbols; :crisp-language uses nothing).
- **P2 DONE 2026-10-12** -- ash / logand / logior / logxor / lognot / popcount: specs 15-17 on the BMG, errors/03.
  popcount and ash are lowered behind noinline helpers: inline, the BMG gave a wrong lane (popcount) or failed
  zeModuleCreate (ash) -- the same family as BUG 120, NOT caused by vectorization (checked with SLP off).
- **P3 DONE 2026-10-12** -- tanh / erf / exp2: spec 18 on the BMG, 19-21 VERIFY-AUTODIFF on the BMG.  On PTX
  they need libdevice (__nv_tanhf / __nv_erff / __nv_exp2f), with the same clear error as exp; verifying the
  PTX path on metal needs a CUDA host.
- Docs: chapter 32/02-06 updated (both copies).

## Open questions for Chris

- **`mod` is truncating, like `rem`** (endeavour 109).  Common Lisp's `mod` is floor-based: `(mod -1 4)` is 3
  there, -1 in Crisp.  Harmless for non-negative coordinates; surprising otherwise.  Now that `floor` divides
  properly, `mod` could be the floor remainder.  Not changed.
- **BUG 120** is open: inline integer code in a kernel body misbehaving on the BMG; three ops now use helpers.

## Phases

- **P0 integer division** (the silent one first) + BUG 062.  Specs 01-06, errors/01.
- **P1** `sqrt`, `rsqrt`, `abs`, `clamp`, `*!`; AD rules for sqrt / rsqrt / abs / clamp.
- **P2** `ash`, `logand`, `logior`, `logxor`, `lognot`, `popcount` (no gradients).
- **P3** `tanh`, `erf`, `exp2` (+ AD).
- Docs: chapter 32/02, 04, 05, 06 status marks and examples; the agent guide lists what exists.

On-metal: every phase has `TEST-HOIST[L0]` specs on the BMG with values from the chapter's own tables,
and `VERIFY-AUTODIFF` for the differentiable ops.  The PTX libdevice path (P3) is compile-verified here
and needs a pod for metal.

Runtime operands come from `(get-workgroup-id 0)`, which is 0 at run time but unknown to the compiler,
so nothing is constant-folded away (the 172/02 trick).
