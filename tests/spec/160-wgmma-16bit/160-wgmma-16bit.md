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
