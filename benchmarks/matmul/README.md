# Matmul benchmark — Crisp tensor-core GEMM vs CUDA (NVIDIA) and SYCL (Intel/BMG)

`C[M x N] = A[M x K] . B[K x N]`, tf32.  Both backends run the SAME Crisp macro —
`matrix-multiply-tile-stride` (Endeavor 135) — over the Endeavor-132 MMA forms
(`make-register-tile`, `mma-accumulate-via-tile`, `load-tile`/`store-tile`, `inner-dimension`).
The macro owns the grid-stride tile walk, the K-loop, and the auto-store; the body just
stages + accumulates.

Because the tensor-core shape genuinely differs per vendor, there are TWO kernels (not a
shape swap):
- **NVIDIA** (`matmul.crisp`): `(16 8 8)` tf32 MMA, **B col-major**, 64×64 register tile
  (one warp / tile → 32 `mma.sync.aligned.m16n8k8` per K-step).
- **Intel BMG** (`matmul_bmg.crisp`): `(8 16 8)` XMX shape, **B row-major** (SPV/DPAS has no
  ColumnMajor-B coop builtin), 32×32 register tile (one 16-lane sub-group / tile).  64×64
  spills BMG's sub-group registers ~5×; 32×32 was swept as the BMG sweet spot.

## Layout
```
matmul/
  crisp/matmul.crisp          NVIDIA kernel  (compiles to matmul.ptx)
  crisp/matmul_bmg.crisp      Intel/BMG kernel  (compiles to matmul_bmg.spv)
  crisp/bench_harness.cu      CUDA-Driver-API launcher (2-D grid, timing, A=B=1 correctness)
  crisp/bench_harness_l0.cpp  Level-Zero launcher (2-D grid, ze-event timing, correctness)
  cuda/matmul.cu              hand CUDA reference (16x16 shared-mem tiled, fp32 baseline)
  sycl/matmul.cpp             hand SYCL reference (16x16 shared-mem tiled, fp32 baseline)
  run.py                      NVIDIA: build + run crisp vs cuda, print GFLOPS
```
The Intel side is driven by `scripts/bench-intel.sh matmul` (Docker + BMG passthrough) →
`scripts/bench-intel-driver.py`, which builds Crisp(L0) + the SYCL reference and compares.

## Correctness oracle
Inputs are `A = B = 1.0`, so every `C[i][j] == K` exactly (1.0 is representable in
tf32; K is exact in fp32 accumulation for the sizes here). Each binary asserts
`max|C - K| < K·1e-3` and exits non-zero on failure — so "correct" is a hard gate,
not eyeballing.

## Running — NVIDIA (CUDA box, e.g. RunPod)
```
python run.py --sizes=256,512,1024        # crisp (matmul.crisp) vs cuda
```
Sizes must satisfy `M % 64 == 0`, `N % 64 == 0`, `K % 8 == 0` (64×64 tile).

## Running — Intel BMG (Docker on the dev box)
```
./scripts/bench-intel.sh matmul                    # sizes default to 256,512,1024
./scripts/bench-intel.sh matmul 256,512,1024 100   # crisp (matmul_bmg.crisp) vs sycl
```
Sizes must be multiples of 32 (the BMG tile).  Runs in the oneAPI Docker image with
`/dev/dxg` BMG passthrough; builds Crisp→SPV + the SYCL reference and prints a GFLOPS table.

## Results

### Initial 16×8 baseline (RunPod, RTX, 2026-07-05) — CORRECT
`ok=True` at all sizes on the first real run (no harness tweaks needed):

| MxNxK | crisp GFLOPS | cuda GFLOPS | crisp/cuda |
|-------|-------------:|------------:|-----------:|
| 256   | 77.5         | 1216.5      | 15.7×      |
| 512   | 70.8         | 1737.5      | 24.5×      |
| 1024  | 70.3         | 1865.8      | 26.5×      |

Correctness confirmed on metal (the whole tf32 MMA path computes A·B).  Crisp
**plateaued at ~70 GFLOPS** = memory-bound: one 16×8 output tile per warp, re-staging
A/B from global each K-step (tiny arithmetic intensity), so the tensor cores starved.

### Bigger register tiles — 64×64 (RunPod, RTX, 2026-07-05) — CORRECT
`matmul.crisp` now uses a **64×64** register tile (4×8 = 32 accumulator fragments, 32
`mma.sync` per K-step).  Pure source change — no compiler work.  Per K-step it stages
1024 global floats (64×8 A + 8×64 B) that feed 32 MMAs instead of 1.

| MxNxK | crisp GFLOPS | 16×8 was | cuda GFLOPS | crisp/cuda |
|-------|-------------:|---------:|------------:|-----------:|
| 256   | 45.6         | 77.5     | 1309.1      | 28.7×      |
| 512   | 185.5        | 70.8     | 1738.2      | 9.4×       |
| 1024  | **429.4**    | 70.3     | 1844.7      | **4.3×**   |

`ok=True` at all sizes.  **At 1024, +6.1× over the 16×8 baseline — almost exactly the
predicted ~6× arithmetic-intensity win**; crisp/cuda collapsed 26.5× → 4.3×.  The 256
*regression* is occupancy, not the kernel: 256² with 64×64 tiles = only 16 workgroups,
so most SMs idle (512 → 64 blocks, 1024 → 256 blocks; GFLOPS climbs as the grid fills
the machine).  Bigger tiles trade workgroup count for per-warp work — they want big
problems.

`ptxas -v` (sm_80, original monolithic accumulator): **181 registers, 0 spills**, but a
**4896-byte stack frame** — the 64×64 accumulator was one monolithic loop-carried
aggregate (`{{4×float}×32}`) rewritten wholesale each K-step, which SROA can't scalarize
(survives as a struct-typed PHI), so NVPTX dropped it to `.local`.  Not spilling — a
structural residency problem, unchanged even under `opt -O3`.

**FIXED 2026-07-05 (register residency).** The `let` that binds a `make-register-tile`
now explodes it into N individual per-fragment mutable variables (each a small
`{4×float}` set! independently), so mem2reg/SROA keep them in registers.  Verified
in-process (`opt -O3` → `llc`): the 64×64 matmul went from a 1024-byte `.local` depot +
~200 local ld/st to **zero `.local`, 0 ld.local, 0 st.local** — fully register-resident,
32 `mma.sync` / 32 `ld.shared` intact.  The `register-tile` / `mma-accumulate-via-tile`
source API is unchanged.  Re-measure on RunPod to see the GFLOPS lift.  Remaining levers:
block-level SLM reuse, then async load-tile / pipelining / warp-specialization.

### macro rewrite (Endeavor 135) — both backends, on metal (2026-07-10)
Both kernels rewritten onto `matrix-multiply-tile-stride`.  **All `ok=True`**; the tf32-MMA
path computes A·B correctly on both vendors.  References are the naive **fp32** tiled kernels
(`cuda/matmul.cu` / `sycl/matmul.cpp`) — NOT cuBLAS/oneMKL — so this is Crisp-tensor-cores vs a
straightforward hand-written baseline, both far below the cards' tensor peak.

**NVIDIA RTX 4000 Ada (RunPod), 64×64 tile:**

| MxNxK | crisp GFLOPS | cuda GFLOPS | crisp/cuda |
|-------|-------------:|------------:|-----------:|
| 256   | 124          | 1235        | 0.10       |
| 512   | 500          | 1621        | 0.31       |
| 1024  | **1899**     | 1823        | **1.04**   |

**Intel Arc B580 / BMG (Docker), 32×32 tile:**

| MxNxK | crisp GFLOPS | sycl GFLOPS | crisp/sycl |
|-------|-------------:|------------:|-----------:|
| 256   | 114          | 1317        | 0.09       |
| 512   | 416          | 1466        | 0.28       |
| 1024  | **1493**     | 1531        | **0.97**   |

Same shape on both: **latency-bound and far behind at small N** (the synchronous Chapter-0
staging + grid-stride overhead dominates a tiny problem), **converging to ≈parity at 1024**
(1.04× on RTX, 0.97× on BMG).  The small-N gap is what the async chapters (pipelined /
warp-specialized loads) exist to close.  Correctness oracle (A=B=1 → C=K) is a hard gate on
every run.

### Chapter 1 — async tile loading (Endeavor 136, 2026-07-12)

Both crisp kernels now have an ASYNC twin (`matmul_async.crisp` / `matmul_bmg_async.crisp`):
the K-step A/B staging goes through `(make-async-barrier :mode :linear)` +
`:barrier`/`await`.  On PTX that lowers to the per-element `cp.async` coop loop +
`commit_group`/`wait_group`; on SPIR-V to per-row `OpGroupAsyncCopy` + `OpGroupWaitEvents`.
`run.py` (NVIDIA) and `bench-intel.sh matmul` (BMG) run sync vs async vs the vendor reference.

**NVIDIA RTX 4000 Ada (RunPod) — async is a clear win, ~1.55×:**

| MxNxK | sync GFLOPS | **async GFLOPS** | cuda GFLOPS | async/sync (time) | async vs cuda |
|-------|------------:|-----------------:|------------:|:-:|:-:|
| 256   | 124         | **196**          | 1237        | 0.63 (1.58× faster) | 6.3× behind |
| 512   | 501         | **796**          | 1619        | 0.63 (1.59× faster) | 2.0× behind |
| 1024  | 1899        | **2919**         | 1725        | 0.65 (1.54× faster) | **1.7× AHEAD** |

Per-element `cp.async` overlaps the K-step stage with the MMA and adds no per-copy overhead,
so it's a uniform ~1.55× lift — and at 1024 crisp-async **passes the naive CUDA reference**.

**Intel Arc B580 / BMG (Docker) — async is SLOWER here, and the reason is instructive:**

| MxNxK | sync GFLOPS | async GFLOPS | sycl GFLOPS | async/sync (time) |
|-------|------------:|-------------:|------------:|:-:|
| 256   | 114         | 82           | 1322        | 1.39× slower |
| 512   | 416         | 257          | 1470        | 1.62× slower |
| 1024  | 1494        | 782          | 1528        | 1.91× slower |

`OpGroupAsyncCopy` is a *collective bulk* copy, not per-element, so a 2D strided tile becomes
**one collective copy per row**.  This GEMM's A-tile is **32×8** — 32 rows of only 8 elements —
so each K-step fires **32 tiny 8-element collective copies** (+ 8 for the 8×32 B-tile), and that
per-call overhead swamps the copy itself.  (Contrast `performance/matmul-async-bmg/`, an 8×16
microbench = 8-row tiles, where async is *24% faster* — the win flips with row count.)  This is
exactly the tall-thin-strided case that **Chapter 1.5's LSC 2D block loads** exist to handle
efficiently; `:mode :linear` per-row is the honest floor they'll improve on.  Correctness oracle
(A=B=1 → C=K) passed on every run, both backends.

### Chapter 1.5 — `:mode :block` TMA / CuTensorMap (Endeavor 137, 2026-07-15)

**NVIDIA H100 80GB (RunPod), 64×64 tile, tf32 size sweep — all `MMA_CORRECT`, GFLOPS:**

| M=N=K | sync | `:linear` | `:block` (TMA) | cuBLAS tf32 | `:block`/cuBLAS |
|------:|-----:|----------:|---------------:|------------:|:-:|
|  256  |   100 |   155 |  1,631 |   6,143 | 27% |
|  512  |   386 |   624 |  7,188 |  34,848 | 21% |
| 1024  | 1,534 | 2,510 | 28,139 | 143,077 | 20% |
| 2048  | 5,596 | 8,964 | 75,039 | 365,512 | 21% |
| 4096  |  —    |  —    | 79,720 | 436,177 | 18% |

(sync / `:linear` at 4096 omitted — copy-bound and glacial; cuBLAS via `cublasGemmEx` +
`CUBLAS_COMPUTE_32F_FAST_TF32`, `cublas_bench.cu`, same 2·M·N·K FLOP count.)

Findings:
- **`:block` is a step-change over `:linear`, ~8–11×.**  At K=N the `cp.async` path issues
  ~131K per-element copies per workgroup; TMA issues ~256 **bulk descriptor-driven 2-D** copies,
  so `:block` becomes compute-bound while sync/`:linear` stay copy-bound (<2.5% of cuBLAS).
- **Naive `:block` holds a steady ~18–27% of cuBLAS** across two orders of magnitude — a clean
  "TMA staging alone buys ~1/5 of peak" result.
- **`:block` plateaus at 4096** (75→80 TFLOPS from 2048→4096) — the **single-warp / low-occupancy**
  kernel saturates, while cuBLAS keeps climbing (365→436).  Closing that gap is exactly what the
  remaining levers do: **rings** (pipeline overlap), **warp specialization** (producer/consumer),
  bigger tiles, and SLM swizzling.  So this row is the honest "naive TMA ceiling" the next
  chapters build on.
- sync→`:linear` 1.6× matches the RTX ~1.55× above.

Generated apples-to-apples by the hoist itself — `crisp-hoist-cuda --mma-bench=M,N,K
--grid-tile=64 <metacrisp>` emits a per-kernel `_CUDA.cu` that sets up each kernel's exact args
(incl. the CUtensorMap descriptor for `:block`), warms up, times 100 launches with CUevents, and
prints GFLOPS + the C=A·B check.  `nvcc -arch=sm_90a … -lcuda`.

### Chapter 2 — ring pipelining (Endeavor 138, 2026-07-16)

`matmul_pipelined.crisp` replaces the single `:block` barrier + single A/B SLM tile with **2-deep
rings** (A-tile ring, B-tile ring, barrier ring, `:arrivals 2`), so stage *k+2*'s TMA transfer is
in flight while stage *k* feeds the tensor cores.  Hand-rolled `tile-stride` + `dotimes` (= what
`matrix-multiply-tile-stride` lowers to) so a **prologue** can precede the K-loop; ring slot is
just `(mod grid-k 2)`.  Same 64×64 register tile, `(16 8 8)` tf32 MMA, B col-major.

**NVIDIA H100 80GB PCIe (RunPod), 64×64 tile, tf32 size sweep — all `MMA_CORRECT`, GFLOPS:**

| M=N=K | sync | `:linear` | `:block` | **pipelined** | cuBLAS tf32 | pipe/`:block` |
|------:|-----:|----------:|---------:|-----------:|------------:|:-:|
| 1024  | 1,354 | 2,156 | 24,084 | **25,875** | 111,452 | **+7.4%** |
| 2048  | 2,599 | 3,992 | 36,005 | **39,328** | 204,019 | **+9.2%** |
| 4096  | 3,992 | 6,373 | **57,957** | 54,601 | 297,113 | **−5.7%** |

(H100 **PCIe** here — Endeavor 137's Ch 1.5 table was a stronger H100 SKU, so absolute GFLOPS
differ; the pipe-vs-`:block` delta is measured on the *same* pod.  Same `--mma-bench` harness;
the `BENCH … GFLOPS` line is CUevent-timed over 100 launches, independent of the host C=A·B check.)

**Depth sweep — 2-deep is the sweet spot; deeper never wins** (GFLOPS, same pod):

| M=N=K | `:block` | pipe **2** | pipe 3 | pipe 4 |
|------:|---------:|-----------:|-------:|-------:|
| 1024  | 24,343   | **26,021** | 25,220 | 25,714 |
| 2048  | 36,147   | **39,335** | 39,053 | 36,034 |
| 4096  | **57,875** | 54,387   | 54,207 | 54,070 |

Findings:
- **Pipelining is a real but modest win at 1024–2048 (+7–9%)** and the win *grows* with K — more
  K-steps means more DMA to overlap behind the MMA.  TMA staging alone (Ch 1.5) already made
  `:block` mostly compute-bound; the 2-deep ring recovers the residual DMA stall by keeping the
  next tile landing during the current MMA.
- **Deeper does NOT help — 2 stages saturate the available overlap.**  pipe-3/pipe-4 are flat-to-
  *worse* than pipe-2 at every size (pipe-4 at 2048 falls all the way back to `:block`); the extra
  prologue + per-stage bookkeeping isn't repaid.  The "maybe deeper helps at small sizes" intuition
  is empirically false here.
- **It crosses over and loses ~6% at 4096 — but NOT for the reason first assumed.**  `ptxas -v`:
  `:block` = **254 registers/thread**, pipe = 250, both jammed against the 255 ceiling (the 64×64
  register accumulator alone is 128 floats = 128 regs/thread).  That pins residency at **~8 warps/
  SM ≈ 12.5% occupancy**, **identical** for `:block` and every pipe depth — the rings live in
  *dynamic* shared memory (4 KB `:block` → 8 KB pipe-2 → 12 KB pipe-3), which never becomes the
  binding limit (registers hit first).  So the crossover is **not** an occupancy effect.  The
  leading explanation: while the GEMM is latency-bound (≤2048) the ring's overlap is worth its
  bookkeeping; by 4096 the resident warps already cover the DMA, so the extra per-stage
  sync/mbarrier work is net cost.  (Stable across reps: 57.9K `:block` vs 54.4K pipe-2.)
- **The real 5× vs cuBLAS is the REGISTER WALL, not pipelining.**  254 regs/thread → ~12.5%
  occupancy → one warp per workgroup with almost nothing else resident to hide latency.  cuBLAS
  runs many cooperating warps per CTA at far higher occupancy.  The dominant lever is therefore
  **getting the 64×64 tile off a single warp** — distribute it across cooperating warps (≈32
  regs/thread instead of 128) so occupancy climbs from ~12% toward the 50–75% cuBLAS runs at.
  That is exactly what warp specialization / multi-warp CTAs buy — *not* a deeper ring, which
  cannot move the register wall.  Naive-ring `:block` holds ~18–20% of cuBLAS; the gap is the
  occupancy the register wall is costing us.

Reproduce: `put_temp_files_here/bench05.sh "1024 2048 4096"` (or the same `crisp-hoist-cuda
--mma-bench=M,N,K --grid-tile=64` → `nvcc -arch=sm_90a … -lcuda` flow as Ch 1.5).  At 4096 the
harness's O(N³) host reference check is glacial *after* the timed run — grab the `BENCH` line and
move on (`stdbuf -oL ./bin | grep -m1 BENCH`).

## Remaining levers
Block-level SLM reuse; Chapter 1.5 (`:mode :block` — CuTensorMap / LSC 2D block loads) for the
tall-thin-strided BMG case above; then pipelining / warp-specialization (the "three chapters" in
`docs/topology.md`).  Chapter 2 (rings) shows the next real lever is **occupancy** — warp
specialization (producer/consumer over the rings, no second full SLM tile per stage) rather than a
deeper ring.  A tf32-MMA / cuBLAS / oneMKL "best-known" reference is the natural follow-on for a
peak-vs-peak ratio.
