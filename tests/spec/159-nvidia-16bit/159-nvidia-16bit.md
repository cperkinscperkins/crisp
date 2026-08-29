# Endeavour 159 — NVIDIA 16-bit (fp16 / bf16)

**Goal.** Extend the §2 "top contenders" comparison — Crisp, a hand-written CUDA control, CUTLASS
as peer, cuBLAS as ceiling — from tf32 into **fp16 and bf16 on H100**. The Intel side already has
both formats (§2.1 bf16, §2.2 fp16, plus a six-chapter 16-bit technique ladder); NVIDIA has
neither.

Started 2026-08-29.

---

## The finding that shapes the endeavour

**Crisp cannot emit a 16-bit MMA on NVIDIA at all.** Both PTX paths are hardcoded to tf32:

| path | where | what is pinned |
|---|---|---|
| sync MMA | `%emit-nvvm-mma`, `src/mma.lisp:748` | function name `llvm.nvvm.mma.m16n8k8.row.col.tf32` |
| wgmma | `%emit-nvvm-wgmma`, `src/mma.lisp:2173` | `wgmma.mma_async.sync.aligned.m64n%dk8.f32.tf32.tf32` |
| wgmma shape check | `%check-wgmma-shape`, `src/mma.lisp:2071` | K must be exactly 8 (or a multiple of 8 under `:swizzle`) |

The `h100` hardware profile *already declares* `(16 8 16)` in `:mma-shapes`
(`src/mma.lisp:270`) — the 16-bit shape is registered and **nothing emits it**. Every `_bf16`
kernel in `benchmarks/matmul/` is an Intel kernel (`matmul_bmg_bf16.crisp`); there is not one
NVIDIA 16-bit Crisp kernel in the tree.

So this endeavour is two jobs with different natures, and only one of them consumes pod time:

- **Phase A — the contenders.** cuBLAS ceiling, CUTLASS peer, CUDA control, in fp16 and bf16.
  Pure `.cu`, no compiler work. This is what turns an H100 rental into data.
- **Phase B — the Crisp column.** 16-bit operands through the NVIDIA MMA path. A compiler
  endeavour. Developable without a pod; only verification needs one.

Phase A is not merely "the easy half first". CUTLASS is the only contender that lets us *see* the
winning configuration, so its numbers are simultaneously the target Phase B aims at and the
shape-vs-N map that says what Phase B should build.

---

## A prediction, recorded before the first measurement

`benchmarks/matmul/16bit-ladder.md` measured Intel's tf32→bf16 scaling at **min 1.46× / median
1.78× / mean 1.84× / max 2.79×** over sixteen points, and explained it from the hardware's own
shape ladder: XMX goes `(8 16 8)` tf32 → `(8 16 16)` bf16, same M×N with K doubling, so one DPAS
does twice the MACs at the same issue rate and **~2× is the instruction-level ceiling**. 4× is the
tf32→int8 step, one rung further down.

**Hopper's ladder is the same step.** wgmma is `m64nNk8` for tf32 and `m64nNk16` for fp16/bf16 —
K doubles, M and N do not. So the prediction is:

> **cuBLAS fp16 ≈ 2× cuBLAS tf32, not 4×**, at matched N. Points meaningfully above 2× are the
> memory path (halved operand bytes buying cache behaviour), which on Intel showed up only at the
> *large* sizes where the working set stops fitting — so expect the same size-dependence here.

Writing this down first is the point. If the first table comes back at 3.5× we should be looking
for a different kernel family or a changed accumulator, not congratulating ourselves.

---

## Phase A — what was built (2026-08-29, before the pod)

Six sources, added to the **existing** `sec2_top_fp16/` and `sec2_top_bf16/` chapter directories.
Those dirs already held the Intel contenders; `sec2_top/` has likewise always carried both
platforms side by side, and the report loops per GPU, so the NVIDIA rows land in their own
section with `CUTLASS` / `cuBLAS` / `CUDA_Apples` labels and **no report change was needed** for
the table itself.

| file | class | notes |
|---|---|---|
| `sec2_top_fp16/cublas_ceiling_fp16.cu` | Ceiling | `cublasGemmEx`, `CUDA_R_16F` operands, `CUBLAS_COMPUTE_32F` |
| `sec2_top_bf16/cublas_ceiling_bf16.cu` | Ceiling | twin, `CUDA_R_16BF` |
| `sec2_top_fp16/cutlass_peer_fp16.cu` | **Peer, swept** | `cutlass::half_t`, tile/cluster via `-D` |
| `sec2_top_bf16/cutlass_peer_bf16.cu` | **Peer, swept** | twin, `cutlass::bfloat16_t` |
| `sec2_top_fp16/cuda_control_fp16.cu` | Control | tf32 control with the element type swapped |
| `sec2_top_bf16/cuda_control_bf16.cu` | Control | twin |

Wired into `scripts/crisp_bench/matmul.py` in the `platform == "nvidia"` branch, after `sec2_top`.

### Decisions worth keeping

**Operands 16-bit, accumulator f32, C f32 — everywhere.** Matches what Crisp's tensor-core path
does and what the Intel side's `onemkl_fp16.cpp` does (half A/B, float C). A 16-bit C would
measure a different computation and would not be comparable to anything else in the report.

**`-DFAST_MATH` is deliberately inert in the 16-bit ceilings, for two different reasons.** For
fp16 the apparent analogue of the tf32 ceiling's `CUBLAS_COMPUTE_32F_FAST_TF32` is
`CUBLAS_COMPUTE_16F` — *f16 accumulate* — and taking it would both measure a different
computation from Crisp's and break the oracle, since an f16 accumulator past 2048 treats `+1.0` as
a no-op and C would read 2048 instead of K at every K ≥ 2048. For bf16 there is no reduced
accumulate type at all; cuBLAS accumulates bf16 GEMM in f32 by construction. Both files therefore
measure an f32-accumulate GEMM in both precision modes, which is what makes them comparable to
each other. **Do not "fix" this.**

**The ceilings verify, and the tf32 ceiling does not.** `sec2_top/cublas_ceiling.cu` memsets its
inputs to zero and checks nothing. The `A = B = 1 ⇒ C = K` oracle survives the format change
intact — 1.0 is exact in both fp16 and bf16, accumulation is f32 — so there is no reason to
publish an unverified ceiling. A ceiling that never verifies can be mis-specified into a
different, faster computation and read as legitimate.

**The peer is swept and the ceiling is not.** cuBLAS chooses its kernel internally and cannot be
asked which. CUTLASS makes the tile a template argument, exactly as Crisp makes it a source-level
choice. Five configurations per format:

| tag | tile M×N×K | cluster | why |
|---|---|---|---|
| `128x128x64` | 128×128×64 | 1×1×1 | the workhorse |
| `128x256x64` | 128×256×64 | 1×1×1 | wide N, mirrors the tf32 peer's 64×256 |
| `256x128x64` | 256×128×64 | 1×1×1 | tall M |
| `64x128x64` | 64×128×64 | 1×1×1 | small tile, for small N |
| `128x128x64c2` | 128×128×64 | **2**×1×1 | controlled cluster contrast |

The last one is not a shape. It is identical to `128x128x64` but for the cluster, so it is the
only one of the five whose delta is attributable to clustering. Endeavour 152 measured clusters
as a **negative** for Crisp on this part — forming a cluster of two was free, multicast cost a
consistent ~5% and never paid back, and that was read as evidence that the gap to cuBLAS is not on
the operand-fetch path. Whether CUTLASS's clusters pay where ours did not is directly informative,
and it is only readable against its no-cluster twin.

**Schedules left on `Auto`.** The tf32 peer names `KernelTmaWarpSpecialized` explicitly; that
schedule is not valid for every tile in a sweep and a mismatch surfaces as a compile error deep in
a template instantiation. `KernelScheduleAuto` + `EpilogueScheduleAuto` lets CUTLASS pick the
cooperative or pingpong variant each tile wants. Pin one only to answer a specific question.

**CUTLASS status returns are now checked.** `can_implement()`, `initialize()` and `run()` each
return a `cutlass::Status` and the tf32 peer **discards all three**. For one fixed shape that is
sloppy; for a sweep it is a correctness hazard, because some tile/cluster/problem combinations are
legitimately not implementable and the discarded status is the only place CUTLASS says so.
Unchecked, such a config runs anyway and reports a time for a GEMM that did not happen. Every
status is checked; every failure exits non-zero and prints `correct: false`, which the driver
turns into a **dropped point with a printed reason** rather than a silent zero.

### One report change was needed

`_variant_split` in `scripts/crisp_bench/report.py` handled only `Crisp_V_<tag>`. The **peer**
column takes the same silent `max()` over matching competitors that the Crisp column does — which
was harmless only while each chapter carried a single peer build. With five CUTLASS builds the
peer cell becomes an unattributed envelope: a best-per-size number the reader cannot reproduce,
which is precisely the failure that function was written to prevent. It was Crisp-only by accident
of which column got variants first.

Generalised to `<GROUP>_V_<tag>`, plus `_best_named` / `_cell_named` so the peer cell names its
winning configuration. Verified non-regressing against all sixteen competitor names currently in
use — every existing name splits exactly as before; only `CUTLASS_V_*` gains a tag.

---

## Pod runbook

`bench-on-pod.sh` already runs `setup-third-party.sh` (line 209), which clones CUTLASS whenever
`nvcc` is on PATH — so the peer provisions itself. This also **closes the pre-existing tf32
CUTLASS gap in §2 for free**: `third_party/versions.txt` currently records only `sycl-tla`, so the
tf32 peer has almost certainly never actually run.

**Build-verify before sweeping.** None of the six sources has ever been compiled — there is no
`nvcc` on the dev box, so they were authored blind. Compile all six first; a syntax error found
during a sweep costs far more than one found in a two-minute build pass. The CUTLASS peers are the
risk: ten template instantiations, and template errors are slow and loud.

```
# 1. build-verify only (fast fail)
./scripts/bench-on-pod.sh <host> <port> nvidia-16-perf ~/.ssh/id_ed25519 \
    --bench=matmul --chapters=sec2_top_fp16 256 5

# 2. then the real sweep, both formats
./scripts/bench-on-pod.sh <host> <port> nvidia-16-perf ~/.ssh/id_ed25519 \
    --bench=matmul --chapters=sec2_top_fp16,sec2_top_bf16
```

**Start at ≤8192.** The canonical NVIDIA ladder runs to 32768. Every contender here allocates full
host vectors for A, B and C; at 32768 that is ~2 GiB + 2 GiB + 4 GiB of host memory before the
device allocations. Establish the shape ladder at 1024–8192 first and extend deliberately.

**Expect some CUTLASS configs to fail at some sizes, and treat that as data.** `64x128x64` at
large N and `128x256x64` at small N are the likely ones. A dropped point with a printed
`can_implement` reason is a correct outcome, not a bug to work around.

---

---

## Phase A results — H100 NVL, 2026-08-29

Measured on a RunPod **H100 NVL** (95 GB, driver 580.126.09, CUDA 12.4), warmup 10 / iters 50,
CUDA-event timed, median of iters. **Every point below verified `correct: true` with
`max_abs_err` exactly 0.000e+00** — the `A = B = 1 ⇒ C = K` oracle is exact in both 16-bit
formats, as predicted.

Note the SKU: this is the **NVL** part, not the PCIe part the `h100` hardware profile describes
(`:compute-units 114`). Irrelevant to Phase A, since none of these contenders reads that profile,
but it matters the moment Crisp kernels run here — see [[h100-profile-variant-mismatch]].

### The prediction held, including its stated exception

cuBLAS 16-bit ÷ cuBLAS tf32, same pod, same harness, same FLOP count:

| N | tf32 | fp16 | ×  | bf16 | ×  |
|---:|---:|---:|:-:|---:|:-:|
| 1024 | 141.4 | 148.1 | 1.05 | 107.0 | 0.76 |
| 2048 | 323.3 | 449.6 | 1.39 | 445.5 | 1.38 |
| 4096 | 386.3 | 697.5 | **1.81** | 664.4 | **1.72** |
| 8192 | 350.6 | 602.8 | 1.72 | 660.8 | 1.89 |
| 16384 | 292.2 | 631.0 | **2.16** | 631.3 | **2.16** |

**Nothing resembling 4× at any size.** The ratio climbs monotonically with N and crosses 2× only
at 16384 — which is exactly the shape the prediction asked for, including the exception it named:
*"points meaningfully above 2× are the memory path (halved operand bytes buying cache behaviour),
which on Intel showed up only at the large sizes where the working set stops fitting."* The
Intel-derived model transferred to NVIDIA intact, mechanism and size-dependence both.

The 1024 row is the other end of the same story: at small N nothing is arithmetic-bound, so the
instruction-level advantage cannot express itself, and bf16 is actually **slower than tf32**
(0.76×) because cuBLAS picks a poor kernel there. A 16-bit format is not a free win at small N.

### No one kernel fits all N — confirmed on NVIDIA, by the peer itself

CUTLASS fp16, five configurations (TFLOPS):

| N | 128x128x64 | 128x256x64 | 256x128x64 | 64x128x64 | 128x128x64c2 | best | spread |
|---:|---:|---:|---:|---:|---:|:-:|:-:|
| 1024 | 113.0 | 76.7 | 72.6 | **126.9** | 109.7 | `64x128x64` | 1.75× |
| 2048 | 340.9 | **380.0** | 352.5 | 283.6 | 340.9 | `128x256x64` | 1.34× |
| 4096 | 468.7 | **546.8** | 515.0 | 333.4 | 467.1 | `128x256x64` | 1.64× |
| 8192 | 390.6 | **504.7** | 479.1 | 246.4 | 399.8 | `128x256x64` | 2.05× |
| 16384 | — | **484.8** | — | 193.3 | — | `128x256x64` | 2.51× |

**A clean sign flip.** `64x128x64` versus `128x256x64` is **+65% at 1024** and **−51% at 8192**
(−60% at 16384) — the same kernel, opposite verdicts, far outside any run-to-run spread. The
premise the Intel fp16 chapter established with eleven Crisp variants reproduces on NVIDIA with
five CUTLASS builds. Choosing one fixed configuration by measuring at one N will mislead at
another, on both vendors.

bf16 tracks fp16 almost exactly (same winner at every size, within ~1%), so this is a property of
the tile/problem geometry, not of the numeric format.

### Clusters do not pay for CUTLASS either — corroborating endeavour 152

`128x128x64c2` is identical to `128x128x64` but for `ClusterShape 2×1×1`, so its delta is
attributable to clustering alone:

| | 1024 | 2048 | 4096 | 8192 |
|---|---:|---:|---:|---:|
| fp16 | −2.9% | +0.0% | −0.3% | +2.4% |
| bf16 | −3.0% | −0.1% | −0.4% | +4.7% |

Neutral to slightly negative except a small gain at 8192. Endeavour 152 measured cluster-of-two as
free for Crisp (0.98–0.99×) and multicast as a consistent ~5% loss, and concluded the gap to
cuBLAS is **not on the operand-fetch path**. CUTLASS, a far more tuned implementation, gets
essentially nothing from clusters here either. That is independent support for 152's conclusion:
it was not a Crisp deficiency.

### The Control

`cuda_control_fp16` / `_bf16` measure **3.8–4.0 TFLOPS, flat at every size**, fp16 and bf16
indistinguishable. The caveat recorded in the header before the first run was correct:
`cuda::memcpy_async` only takes the accelerated `cp.async` path at 4/8/16-byte granularity, and
each thread stages a single 2-byte element, so the pipeline buys nothing. This is an honest
Control — what a naive 16-bit port of the tf32 control actually does — and it is ~175× below the
ceiling at 4096. A `__half2` (4-byte) staging variant would be a legitimate *second* control.

### The tf32 peer was broken three ways, and the third cost 1.4×

`sec2_top/cutlass_peer.cu` had **never compiled on any machine** — CUTLASS 3.x takes a 3-element
stride (row, col, **batch**) and it passed the 2-element form. That is the concrete cause behind
the long-standing suspicion that CUTLASS had never run; `third_party/versions.txt` recording only
`sycl-tla` was the symptom, not the cause. Fixing it needs `cutlass::make_cute_packed_stride` and
a **second include path** (`tools/util/include`) that no build in the tree carried.

Once it ran, it read **52–57% of cuBLAS** while the 16-bit peers read 76–85%. The tile was not the
reason. The **pinned `KernelTmaWarpSpecialized` schedule** was, and it is coupled to the tile:

| tf32 TFLOPS @4096 | 64x256x32 | 128x128x32 | 128x256x32 | 256x128x32 |
|---|---:|---:|---:|---:|
| pinned `KernelTmaWarpSpecialized` | 219.3 | 180.8 | **22.9** | **39.8** |
| `KernelScheduleAuto` | 208.9 | 258.7 | **316.5** | 297.2 |

Under the pinned schedule a large tile does not merely fail to help — it **collapses, 6–14×** — so
the shipped 64x256x32 looked like the best tile available, and was, *under that schedule*. On Auto
the ranking inverts and the best config is **1.40–1.44× the shipped number** at every size from
2048 up, bringing the tf32 peer to **74–82% of cuBLAS**, finally the same band as the 16-bit peers.

This also validates, after the fact, the decision to leave the 16-bit peers on `KernelScheduleAuto`
from the start. The header predicted a *compile* failure from a pinned schedule; the real
penalty turned out to be silent and numerical, which is worse.

`cutlass_peer.cu` has been rewritten as a structural twin of the 16-bit peers (parameterised tile,
Auto schedule, checked statuses, config in the JSON) and `matmul.py` now sweeps it over four
configs. Verified on the pod: all five builds succeed, all correct, default 128x256x32 reads
317.6 TFLOPS @4096 against the old tile's 208.1.

---

## Status

- [x] Phase A sources authored (six files)
- [x] Driver wiring, five-config CUTLASS sweep per format
- [x] Report peer-provenance generalisation
- [x] Phase A build-verified on H100 — all 11 peer builds succeed (~22 s each) after the stride fix
- [x] Phase A measured, 1024–16384, every point `correct: true`
- [x] **Prediction checked and held**: cuBLAS fp16/tf32 = 1.05 → 2.16×, never 4×
- [x] tf32 CUTLASS gap closed — and found to have been *three* defects, one worth 1.4×
- [ ] Driver run end-to-end on the pod (`bench.py --platform=nvidia`) to confirm the wiring emits
      result JSON and the report renders the swept peer with its config named. The binaries and
      the numbers are verified; the *integration* is not yet exercised on hardware.
- [ ] §2.1/§2.2 NVIDIA sections regenerated into `REPORT.md`
- [ ] Phase B scoped from the measured shape ladder

## Open questions for Phase B

1. **Which rung first — sync `m16n8k16` or `wgmma m64nNk16`?** wgmma is where the tf32
   performance lives (chapter 7, 67–90% of cuBLAS), so it is where a 16-bit number would be
   meaningful. Sync `m16n8k16` is the lower-risk rung and mirrors what Intel did (same kernel,
   operand type and K swapped). The Intel precedent argues for sync first as a correctness
   vehicle, then wgmma for the headline.
2. **How much of `%check-wgmma-shape` has to become operand-width-aware?** K goes 8 → 16, which
   touches the K rule, the descriptor/swizzle math, and the core-matrix layout the VJP reads.
3. **Does the fragment-register accounting in the `h100` profile (endeavour 144 Phase 2) still
   hold** when operands halve in width?
