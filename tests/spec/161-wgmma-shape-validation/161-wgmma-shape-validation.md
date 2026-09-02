# Endeavour 161 — wgmma shape validation

Opened and completed 2026-09-02, out of the BUG 052 post-mortem.

**Two defects, one endeavour, because they are the same omission at two altitudes.** A wgmma
kernel could be wrong about the shapes it declared and wrong about the tiles it staged, and the
compiler checked neither against anything that knew the hardware.

---

## Where this came from

BUG 052 claimed the wgmma no-swizzle descriptor path computed wrong answers, on the strength of
four failing probe arms including two tf32 controls. It was closed as **NOT A BUG**. Every arm
had a non-compiler cause:

* the two **scatter** arms staged a transposed B — and the tf32 "control", the arm whose failure
  made the bug look pre-existing and conclusive, also had A declared `(64 16)` against a K of 8,
  copy-pasted from the bf16 probe and never adjusted. Both its operands were malformed.
* the two **swz** arms failed on the benchmark fixture, which hardcoded
  `CU_TENSOR_MAP_SWIZZLE_NONE` while the descriptor declared 128B. Fixed separately; chapter 7
  bf16 on that same path now verifies bit-exact at all eight sizes 512..4096.

A rented H100 and a whole bisection went into diagnosing a kernel-authoring error as a compiler
bug. **This endeavour is the check that would have caught it at compile time, for free.**

## The two conventions genuinely differ

This is the heart of it, and why every violator in the tree got it wrong the same way:

```
mma-accumulate-via-tile     A = (Mt Kt)   B = (Kt Nt)     <- %mma-k-steps' docstring
wgmma-accumulate-via-tile   A = (M  K )   B = (N  K )
```

Assuming the sibling form's convention is the *natural* mistake, not a careless one. So the
error messages name the difference explicitly rather than merely stating the rule.

The rule is not inferred from which kernels happen to verify. It is what CUTLASS declares, in
`third_party/cutlass/include/cute/atom/mma_traits_sm90_gmma.hpp`:

```cpp
FrgTypeA = FrgTypeB = GMMA::smem_desc<GMMA::Major::K>;
ALayout  = GMMA::ABLayout<64, 8>;   BLayout = GMMA::ABLayout<64, 8>;
```

and the tf32 SS atoms exist **only** in the `_TN` form — 16 of them, no other suffix — because
tf32 wgmma carries no transpose immediate.

**At 16 bits the ISA genuinely offers both orientations.** The bf16/f16 traits are templated
`<GMMA::Major tnspA, GMMA::Major tnspB>` where tf32's are hardcoded, and that is the
transA/transB pair the 16-bit mnemonic carries (five trailing immediates versus three). A `(K N)`
B operand is `Major::MN` and is legal hardware **with transB=1**. Crisp pins transA/transB to
`(0 0)` via `*wgmma-16-trans*`, never deriving them from the operand — so at 16 bits the refusal
is a fact about *this compiler*, and saying "B must be (N K)" there would be a false claim about
the hardware that sends the reader to fix the wrong thing. The two messages differ accordingly.

> **Follow-up, deliberately not done here.** Inferring transB from the tile orientation would
> make a `(K N)` 16-bit operand correct as written, rather than refused. It is a real feature, it
> touches the emitter, and it wants its own on-metal verification. Filed, not attempted.

## `:mma-shapes` needed expanding — again

`%check-mma-shape` has consulted the hardware profile for the **fragment** form since endeavour
132, with exactly two branches. wgmma was the outlier, still reasoning only from hardcoded
sm_90a constants, so a profile could describe a part accurately and be ignored.

Giving wgmma the same structure needed somewhere for warpgroup shapes to live, and
`:mma-shapes` is the wrong home:

* it is **fragment** granularity — `(8 16 8)` Intel XMX, `(16 8 8)` NVIDIA mma.sync — and ~18
  call sites read it as such, including `%mma-fragment-mn`'s register-tile decomposition and
  `%spv-mma-shape`.
* wgmma's `(64 N K)` is **warpgroup** granularity: M is 64 because a warpgroup is 128 threads,
  and N runs to 256. Mixing those triples into `:mma-shapes` would feed warpgroup dims to
  fragment math.

So **`:wgmma-shapes` is a new, optional profile key.** This is the second widening of the same
schema and it follows the first one's shape deliberately:

| endeavour | what a triple could not say | what was added |
|---|---|---|
| 155 | *what element type* is this a shape for? | typed 4-list `(half 8 16 16)` beside `(8 16 8)` |
| **161** | *what level* does this describe? | `:wgmma-shapes`, a separate key |

The entry **grammar is reused unchanged** — the value type is still `:mma-shapes`, so the
validator, `%mma-shape-entry-dims` and `%mma-shape-for-elem` all apply verbatim, and a 16-bit
part may write `(bfloat16 64 256 16)` here exactly as it would there.

### The two causes, kept apart

1. **A profile declares `:wgmma-shapes` and the kernel's shape is not among them.** The hardware
   has been described and the kernel contradicts the description; the error names the profile's
   list so the reader sees what was on offer. Under `:swizzle` the K is a K-*block*, so `(M N)`
   must match an entry and K must be a positive multiple of that entry's K — the same relaxation
   the fallback makes, kept identical so a profile cannot silently redefine `:swizzle`.
2. **Nothing declares them.** The sm_90a instruction constraints apply as a documented fallback:
   `M=64`, `N` a multiple of 8 in `[8,256]`, `K=8` for tf32 and 16 at 16 bits.

**Cause 2 is the common path and must never itself be an error.** Nine of the eleven wgmma specs
in the tree declare no profile, as does every benchmark kernel. The three sm_90a messages keep
their existing wording at the front — `140-wgmma/errors/01-03` assert `"M must be 64"`,
`"multiple of 8"` and `"K"` — with the fallback named in an additive trailing sentence.

**No builtin profile gained `:wgmma-shapes` in this pass**, deliberately. Adding an incomplete
list to `h100` would refuse working benchmark kernels that use `(64 256 32)`, `(64 256 64)`,
`(64 128 32)` and `(64 64 32)`. Enumerating sm_90a's legal set properly is separate work; until
then every existing kernel takes the fallback and nothing changes.

## One implementation trap worth recording

The operand check first appeared to do nothing: it was added to
`analyze-wgmma-accumulate-via-tile`, an **analyzer**, while `*mma-scratch-tile-dims*` is bound by
`%explode-register-tiles` around the **explosion** only. Every extent read back `NIL`, the check
took its own "unresolvable extents are not an error" path, and silently passed everything —
precisely the failure mode it exists to prevent. It passed 04 and failed 01–03, which is what
made it visible.

The fix extends the binding over `analyze-let-expression` in `analyze-let-with-tile-explosion`.
That adds no behaviour to the explosion path: `%mma-k-steps` is called only from
`%emit-per-frag-accumulate`, which already ran inside the inner binding. The only new reader is
the 161 check.

**Unresolvable extents still skip silently, and must.** A wgmma operand is frequently
`(ring-get RING SLOT)`; refusing on `NIL` would reject the working pipelined kernels — chapter 7,
`sec2_top`, `sec3`, `sec4`. `%mma-operand-extent` handles the `ring-get` unwrap (BUG 040's fix),
so those resolve; anything that does not is left alone, exactly as `%mma-k-steps` treats its own
`NIL`.

## Blast radius

Twelve files staged an operand the new check refuses. **None was ever numerically verified** —
all are compile-only specs or the two never-executed probes — so no measured result moves.

Four of them (`140/errors/01-03`, `160/errors/01`) trip on the *shape* error before the operand
check is reached, so their tiles never mattered; they were corrected anyway rather than left as
wrong examples in the tree.

## Status

- [x] Specs first, RED confirmed: 01-03 "Compiler SUCCEEDED but should have FAILED", 04 on the
      missing schema key
- [x] `:wgmma-shapes` schema key; entry grammar reused
- [x] `%check-wgmma-shape` two-branch, profile then sm_90a fallback
- [x] `%check-wgmma-operands`, with distinct tf32 / 16-bit messages for B
- [x] Registry bound across body analysis
- [x] 12 violating kernels corrected
- [x] **1057/1057 E2E · 232/232 negative · 291/291 unit**
- [ ] Follow-up: infer transB from tile orientation at 16 bits
- [ ] Follow-up: enumerate sm_90a's legal wgmma shapes into the builtin `h100` profile
