# Endeavour 160 — wgmma at 16 bits

**Goal.** Let Crisp emit the Hopper warpgroup async MMA at bf16/fp16, so the NVIDIA 16-bit ladder
has a chapter 7.

## Why this is the highest-value remaining work

Endeavour 159 built the NVIDIA 16-bit ladder and measured it on an H100 NVL:

| rung | technique | N=1024 | N=2048 | N=4096 |
|---|---|---:|---:|---:|
| 1 | hand-rolled sync MMA | 2.1 | 5.5 | 5.8 |
| 2 | tile-stride macro | 2.3 | 7.3 | 7.2 |
| **4** | **TMA descriptor** | **31.7** | **59.7** | **92.5** |
| 5 | SMEM ring | 29.4 | 41.6 | 64.2 |
| 6 | warp specialization | 29.6 | 51.0 | 65.9 |
| **7** | **wgmma** | **—** | **—** | **—** |

Chapter 4 is the best Crisp has at bf16: **92.5 TFLOPS = 13.9% of cuBLAS** (666.2). At tf32,
chapter 7 reaches 67–90% of cuBLAS. wgmma is the instruction that closes that gap, and it is the
only rung on the ladder that is empty for a COMPILER reason rather than a missing kernel.

**A second finding from 159 raises the stakes.** The 16-bit ladder does NOT rank like the tf32
one: chapter 4 beats chapter 6 by ~40% at N=4096, and chapter 5's ring is the SLOWEST of the three
above 1024 — the opposite of tf32, where endeavour 139 measured warp specialization as the fastest
Crisp kernel of its day. So the 16-bit story cannot be assumed to follow the 32-bit story anywhere,
including here: it is possible wgmma pays differently at 16 bits too. That is a reason to measure
it, not a reason to expect a particular answer.

## The blocker, exactly

Two hard gates, both tf32-pinned:

* `%check-wgmma-shape` (src/mma.lisp:2069) — without `:swizzle`, `K` must be **exactly 8**; with
  `:swizzle`, a positive multiple of 8. A 16-bit kernel wants K=16.
* `%wgmma-asm-string` (src/mma.lisp:2173) — emits `wgmma.mma_async.sync.aligned.m64n{N}k8.f32.tf32.tf32`.

## Step 0 findings (established before writing any code)

**The instruction exists in the form we need.** `ptxas -arch=sm_90a` accepts

    wgmma.mma_async.sync.aligned.m64n64k16.f32.bf16.bf16

with 32 accumulator registers — matching Crisp's existing `nacc = N/2` convention, so
`%wgmma-struct-of-floats` and the accumulator register accounting are unaffected.

**THE DESCRIPTOR MATH LOOKS UNCHANGED, and the reason is byte arithmetic.** This was expected to
be the hard part. `%emit-nvvm-wgmma` walks a K-block as `k/8` slices, advancing the descriptor
start by `kk*32` BYTES per slice (`%wgmma-make-desc`'s `kslice-byte-off`). A wgmma core matrix is
8 rows x 16 bytes regardless of element type, and:

    tf32  K=8  slice = 8 x 4 bytes = 32 bytes
    bf16  K=16 slice = 16 x 2 bytes = 32 bytes

So a bf16 k16 slice occupies exactly the byte geometry the existing code already emits for a tf32
k8 slice. The hardcoded descriptor constants — no-swizzle LBO=128B/SBO=256B, 128B-swizzle
LBO=16B/SBO=1024B — are byte offsets over that same geometry and should carry over untouched.

**What changes is the K-PER-SLICE, not the byte stride.** `n-slices` is `(floor k 8)`; at 16 bits
it must be `(floor k 16)`, so a K-block of 32 is TWO bf16 slices rather than four tf32 ones.

**This is a HYPOTHESIS, and it is not locally verifiable.** The descriptor is a runtime 64-bit
value; `ptxas` never validates it, and CUTLASS's `make_gmma_desc` (which the existing comment cites
as its source) is not vendored locally. Only `MMA_CORRECT` against a host reference on real
hardware can settle it. The plan is therefore shaped the same way endeavour 159's sync MMA was:
assert the INSTRUCTION locally, prove the DESCRIPTOR on metal.

## Open question for step 1

`%emit-nvvm-wgmma` receives `acc-type` (the f32 accumulator) plus raw SMEM pointers — it has no
operand element type to dispatch on. The sync path solved the equivalent problem by probing the
LLVM type of the A fragment's field 0, but here the operands are POINTERS, not records. The
element type will have to be threaded down from `wgmma-accumulate-via-tile`, which knows the tile's
type. That is the first thing to settle, because it decides whether this is a local change or a
signature change rippling through the call chain.

## Status

- [x] Step 0 — instruction verified with ptxas; descriptor byte-equivalence argued
- [ ] Step 1 — thread the operand element type to `%emit-nvvm-wgmma`
- [ ] Step 2 — widen `%check-wgmma-shape` for 16-bit K
- [ ] Step 3 — emit the bf16/fp16 mnemonic, k-per-slice by element width
- [ ] Step 4 — rung 01 green locally (instruction present, no tf32 residue)
- [ ] Step 5 — `chap7_wgmma_bf16` kernel + MMA_CORRECT on metal (settles the descriptor)
- [ ] Step 6 — measure; promote the ladder winner into §2

---

# MEASURED 2026-09-01, H100 PCIe — the descriptor hypothesis is FALSIFIED

Steps 1-4 completed locally: the compiler emits 16-bit wgmma, rungs 01/02 green, `errors/01`
still refusing tf32 at K=16, full regression **1051/1051 + 228/228 + 291/291**. `chap7_wgmma_bf16`
compiles to `wgmma.mma_async.sync.aligned.m64n256k16.f32.bf16.bf16` in **four** k16 slices —
structurally identical to its tf32 twin's four k8 slices, same SMEM, zero tf32 residue.

**And it computes the wrong answer.**

| rung (N=256, H100 PCIe) | verified | TFLOPS |
|---|---|---:|
| chap1 / chap2 | True | 0.137 / 0.144 |
| chap4 / chap5 | True | 1.502 / 1.527 |
| chap6 | True | 1.887 |
| **chap7 (wgmma bf16)** | **FALSE** | 1.984 |
| **chap7 (wgmma tf32, control, same pod)** | **True** | 2.830 |

The control is what makes this conclusive: tf32 wgmma still verifies on the same machine at the
same size, so the fault is in the 16-bit lowering — not the harness, not the fixture, not the
kernel shape, and not a pre-existing wgmma problem.

## What was eliminated, cheaply

`transA`/`transB` were the strongest suspect: tf32 wgmma has no transpose control at all, the
16-bit form adds two, and endeavour 160 set them to `0, 0` **without evidence** — the one value in
the whole lowering that was chosen rather than derived. B is staged N x K (B^T), so `transB=0`
looked like a plausible mistake.

All four combinations fail:

    transA=0 transB=0  ->  verified=False  1.984
    transA=0 transB=1  ->  verified=False  1.982
    transA=1 transB=0  ->  verified=False  1.994
    transA=1 transB=1  ->  verified=False  1.967

Throughput barely moves across the four, which is itself a signal: the flags are changing almost
nothing about what the kernel does, consistent with operands being misread the same way regardless.
A `*wgmma-16-trans*` probe hook was added so one build could test all four rather than four
rebuilds on a rented GPU; it remains in the overlay, defaulting to the original `(0 0)`.

## What is left, and why the original argument was insufficient

`%wgmma-make-desc` — deliberately left untouched on this reasoning:

> a wgmma core matrix is 8 rows x 16 bytes regardless of element type, and a tf32 k8 slice
> (8 x 4 bytes) and a bf16 k16 slice (16 x 2 bytes) are both 32 bytes, so the LBO/SBO constants
> describe the same geometry

The byte EXTENTS do match. What that argument does not establish is that the **element-level
arrangement inside a swizzled 128-byte chunk** matches. The 128B swizzle permutes *core matrices*,
and a core matrix holds 4 tf32 elements per row versus 8 bf16 elements per row. If the swizzle
interleaves at element granularity anywhere, the descriptor is describing a layout the TMA never
wrote — which would produce exactly this: a kernel that runs at full speed and returns garbage.

**Method note.** Equal byte extents were treated as equal layouts. They are not the same claim, and
nothing local could tell them apart — every local test passes in both worlds. This is the third
time in this endeavour pair that a plausible argument stood in for a measurement (see also
endeavour 159's "all 484 failures are mine" and the `run_bench_proc` phantom); the difference here
is that the hypothesis was written down as a hypothesis first, so the experiment that falsified it
was designed before the code was.

## Next

Vendor CUTLASS and read `make_gmma_desc` — Crisp's own comment on `%wgmma-make-desc` already cites
it as the source of these constants, and it is not currently in `third_party/`. That is local work
needing no GPU. Chapters 1-6 are unaffected and remain green.

## Status

- [x] Steps 0-4 — instruction emitted, rungs green, regression clean
- [x] Step 5a — `chap7_wgmma_bf16` written, compiles, four slices
- [x] Step 5b — measured on metal: **INCORRECT**; transpose flags eliminated
- [ ] Step 5c — derive the correct 16-bit swizzled descriptor from `make_gmma_desc`
- [ ] Step 6 — re-measure; promote the ladder winner into §2

---

# BISECTION 2026-09-01 — the probe found a DIFFERENT bug (BUG 052)

Two minimal scatter-path kernels, identical but for element type and K, at N=256 on an H100 PCIe:

| probe | verified | TFLOPS |
|---|---|---:|
| `_probe_wgmma_bf16_scatter` | **False** | 0.176 |
| `_probe_wgmma_tf32_scatter` (control) | **False** | 0.089 |
| same tf32 probe, compiler built at `3da5807a` (pre-160) | **False** | 0.089 |

**The no-swizzle wgmma path is broken for both element types and predates this endeavour.**
Filed as BUG 052. The pre-160 control is what makes that conclusive — without it, "pre-existing"
would have been an assumption, and the scatter path has never been verified numerically so there
was no prior evidence either way.

## This did NOT answer the question it was built to answer

The probe was designed to isolate the 16-bit wgmma lowering from chapter 7's five simultaneous
variables (TMA, 128B swizzle, ring, warp specialization, wgmma). It instead landed on a SIXTH
variable that was not known to exist. Because the scatter path is independently broken, the bf16
arm's failure carries no information about the 16-bit work.

**The two defects are now cleanly separated, which is the actual gain:**

1. **BUG 052** — scatter wgmma wrong for tf32 and bf16 alike. Pre-existing, independent of 160.
2. **Endeavour 160's defect** — the SWIZZLE path verifies at tf32 and fails at bf16. Untouched by
   today's run, still open.

## Where that leaves the 16-bit swizzle question

Still unexplained, and the descriptor is now RULED IN rather than out: reading CUTLASS's
`make_gmma_desc` showed Major-K B128 wants `leading_byte_offset_ = 1` and
`stride_byte_offset_ = 8*K*bytes/16`, which for chapter 7's K-block is **64 at both widths** —
byte-identical, exactly what Crisp already emits. So the swizzled descriptor constants appear
correct for bf16, and the divergence must be on the **write** side (how TMA + 128B swizzle lay a
2-byte tile into SMEM) rather than the read side.

The next isolation should therefore hold the swizzle path fixed and remove the ring and warp
specialization — chapter 7 minus the pipelining — rather than remove the swizzle, which is what
this probe did.

## Status

- [x] Steps 0-4 — compiler emits 16-bit wgmma; rungs green; regression clean
- [x] Step 5a/5b — chapter 7 written; measured INCORRECT on metal; transpose flags eliminated
- [x] Step 5c — CUTLASS vendored; swizzled descriptor constants shown to be byte-identical
- [x] Step 5d — scatter bisection: found BUG 052, cleared the 16-bit lowering of that failure
- [ ] Step 5e — isolate the swizzle path at bf16 (chapter 7 minus ring + warp specialization)
- [ ] Step 6 — re-measure; promote the ladder winner into §2
