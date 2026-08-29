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

## Status

- [x] Phase A sources authored (six files) — **not yet compiled anywhere**
- [x] Driver wiring, five-config CUTLASS sweep per format
- [x] Report peer-provenance generalisation
- [ ] Phase A build-verified on H100
- [ ] Phase A measured; §2.1/§2.2 NVIDIA sections populated
- [ ] tf32 CUTLASS gap in §2 confirmed closed by the same run
- [ ] Prediction checked: is cuBLAS fp16/tf32 ≈ 2×?
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
