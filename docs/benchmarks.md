# Reduction benchmark — running commentary

## 2026-05-30 — Intel Arc B580 (BMG) — three-way + InstCombine-free pipeline

Crisp SPV path now works end-to-end on BMG via WSL2 Docker.  The fix
went through two stages this evening:

1. **First pass** (Plan A in our bug-hunt): disable opt entirely for the
   SPV path.  Verified the kernel runs; documented the InstCombine
   UB-inference bug in the overlay header.
2. **Second pass** (Plan C): replace opt -O3 with a custom
   InstCombine-free pipeline:
   `function(mem2reg,sroa,early-cse,gvn,dce,simplifycfg,loop(loop-rotate),loop-unroll,dce)`.
   Recovers mem2reg + SROA + CSE + GVN + DCE + simplifycfg + loop unroll
   without triggering the InstCombine UB.  Verified end-to-end (kernel
   correctness + spec suite 732/732 default + 732/732 --differentiate).

The expected perf gain on this kernel turned out to be in the noise
(~1% at all sizes), because the reduction is bandwidth-bound and the
remaining opt passes don't transform the hot path much.  The pipeline
is still a strict improvement: future compute-bound kernels (GEMM, etc.)
will get real benefit from mem2reg + SROA + GVN + unroll.

**Final three-way at occupancy=0.5, 100 iters (InstCombine-free pipeline):**

|       N | crisp (us) | crisp GB/s | sycl (us) | sycl GB/s | onedpl (us) | onedpl GB/s |
|--------:|-----------:|-----------:|----------:|----------:|------------:|------------:|
|    1000 |       8.94 |       0.45 |      6.66 |      0.60 |      147.69 |        0.03 |
|  100000 |       8.84 |      45.25 |      7.07 |     56.56 |      164.20 |        2.44 |
| 1000000 |      14.66 |     272.78 |     12.90 |    310.17 |      173.06 |       23.11 |

**Headline:** at N=1M, Crisp hits 272.78 GB/s vs SYCL's 310.17 GB/s →
**crisp/sycl = 87.9%**, i.e. Crisp comes within 12% of hand-tuned DPC++
on BMG, *without the full opt -O3 pass*.  Same ballpark as Crisp's
~88% of hand-tuned CUDA on Blackwell.

Both Crisp and SYCL crush oneDPL by 10-25× — its `oneapi::dpl::reduce`
has multi-pass orchestration overhead that swamps the kernel work at
this scale (wall ≈ 150-180us at all N).  CUB doesn't show the same
pattern on the NVIDIA side; this is a real ergonomic gap between the
two library stacks.

**Occupancy sweep on SYCL (used to pick the across-platform value):**

|        N | occ=0.25 | occ=0.5 | occ=1.0 |
|---------:|---------:|--------:|--------:|
|     1000 |     5.93 |    6.14 |    8.63 |
|   100000 |     7.18 |    6.86 |    8.74 |
|  1000000 |    18.30 |   12.48 |   11.75 |

Best per size: 0.25 at small N, 1.0 at large N, 0.5 is the compromise.
We picked **0.5** as the across-the-board value.

This is **opposite of CUDA's 0.15 sweet spot**.  Reason: the SYCL harness's
heuristic (`gridSize = numEUs × occupancy`) is much simpler than the
CUDA path's `cuOccupancyMaxActiveBlocksPerMultiprocessor() × occupancy`
(which already accounts for register and SLM pressure before the
multiplier).  Different scales of "1.0" map to different absolute grid
sizes.  Worth tracking separately per platform — the user's hope that
one occupancy value works across platforms doesn't pan out here.

**Open Crisp bug:** opt -O3's InstCombine destroys SPV kernels.
Reproduced with both `sum_reduce` and `vector_add` (and presumably any
kernel using a Crisp stride macro).  PTX path is unaffected because
opt loads the NVPTX target there and uses a proper data layout.

**2026-05-31 root-cause investigation update:** confirmed via aggressive
bisection that the destruction signature `entry: store i1 true, ptr poison;
br i1 poison` arises from how SROA decomposes Crisp's alloca+aggregate-
store+load round-trip:

1. Crisp's `initialize-function-parameters` emits, for every parameter:
   ```
   %alloca = alloca STRUCT
   store STRUCT %imploded, ptr %alloca
   ... later ...
   %loaded = load STRUCT, ptr %alloca
   ```
   `%generate-let-binding` emits the same pattern for let-bindings of
   aggregate-typed values (like the tensor handles built by
   `marshall-tensor`).

2. SROA decomposes aggregate allocas into per-field slices.  Because
   the alloca starts uninitialised, SROA models its initial content as
   POISON and rewrites loads as:
   ```
   %p.fca.0.0.insert = insertvalue %TENSOR poison, ..., 0, 0
   %p.fca.0.1.insert = insertvalue %TENSOR %p.fca.0.0.insert, ..., 0, 1
   ...
   ```

3. InstCombine walks this poison-rooted insertvalue chain.  On the SPV
   target (no data layout loaded — opt-21 doesn't ship SPIR-V target
   plugin), it conservatively propagates poison and marks the entire
   entry block unreachable.

**Attempted fix** (overlay sketch in `put_temp_files_here/` for next-time
reference): bypass the alloca round-trip for aggregate parameters and
aggregate let-bindings, storing the imploded SSA value directly in a
new `*param-direct-values*` hash; have `semantic-var-read` check that
hash first.  The fix successfully removes the alloca round-trip in the
IR (verified by IR inspection — length__ becomes `ret i64 %5`, vec_copy
has zero aggregate allocas) and 725/732 tests still pass.  **But:**

- The 7 failing tests are kernels that SET! their aggregate parameters
  (records-mutable, transpose-bang, etc.) — when the direct-value path
  is taken, subsequent SET! writes to the alloca don't propagate to
  later reads.  Need SET!-reachability analysis to gate the optimisation.
- Even with the alloca round-trip eliminated, InstCombine STILL destroys
  vec_copy.  So the alloca-with-aggregate-store-then-extract pattern is
  one trigger, but not the only one.  The extract-from-insertvalue-from-
  undef chain that builds the tensor handle in the caller still survives
  in the IR and seems to be enough on its own.

Remaining hypotheses (kept from previous session):

- **Address-space mixing through the sizeof trick.**  Crisp emits
  `ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i64)` to
  compute sizeof(float) without a data layout.  The `ptr null` is
  addrspace(0); the downstream uses are addrspace(1) and addrspace(3)
  pointers.  Without the SPIR-V target loaded, opt has no anchor for
  the relative sizes of these address spaces, and InstCombine may
  conservatively poison rather than reason about them.

- **Signed-overflow on pointer offsets.**  The `mul i64` Crisp uses
  for byte-offset computation has no `nsw`/`nuw` flags, so it can
  wrap.  The downstream `getelementptr inbounds` is then potentially
  out-of-bounds → poison.  Adding `nuw` to the multiply (it's always
  multiplying a non-negative element index by a positive sizeof
  constant) would let InstCombine prove the `inbounds` is sound.

- **Missing SPIR-V target backend in opt.**  `apt.llvm.org`'s opt-21
  doesn't include the native SPIR-V target.  Building opt with
  `LLVM_TARGETS_TO_BUILD=...;SPIRV` may resolve the data-layout
  ambiguity at the source.  Worth checking as Plan A when we come back
  to this.

Bisecting the IR for a minimal repro (Plan B) is the guaranteed-success
diagnostic path if neither hypothesis pans out.

**Infrastructure highlights:**
- Docker image: `intel/oneapi-basekit` + SBCL 2.5.5 + LLVM 21 + Quicklisp
- BMG visible via L0 inside container with `--device=/dev/dxg` +
  `-v /usr/lib/wsl:/usr/lib/wsl` + `LD_LIBRARY_PATH=/usr/lib/wsl/lib:...`
- icpx -fsycl -O3: 4-8s build for the SYCL impls; crisp-compile: 0.5s
- Wall-time floor ~150-250us regardless of N (Docker/WSL2/SYCL queue
  overhead).  Only kernel-time numbers are competitive-comparison
  material.

---

## 2026-05-30 — RTX PRO 4500 Blackwell

Latest run (raw transcript below).  Notable:

**N=1M kernel-time, crisp/cuda ratio across GPUs we've measured:**

| GPU | crisp GB/s | cuda GB/s | ratio |
|---|---|---|---|
| RTX 4090 (Ada) | 286.70 | 365.50 | 78.4% |
| A40 (Ampere) | 292.06 | 388.20 | 75.2% |
| **RTX PRO 4500 (Blackwell)** | **426.62** | **486.38** | **87.7%** |

Best ratio we've measured.  Worth flagging that the jump is partly
architectural — Blackwell's L2/SM layout shifts what's expensive.
Crisp's larger param-load footprint, longer-tail bookkeeping in PTX,
etc., matter less when the hardware's memory subsystem is wider.
Same kernel, different ceiling.

A couple of other things in this run:

- **N=1K**: crisp 6.88us vs cuda 6.21us → essentially tied with
  hand-written CUDA at small N for the first time.  We've been
  trailing here.
- **N=1M**: CUB (550 GB/s) now beats CUDA (486 GB/s).  CUB's at
  ~55% of Blackwell's ~1 TB/s peak; the kernel's tail recursion /
  device-wide reduce strategy benefits from Blackwell's wider mem
  path more than the simple grid-stride does.
- **Wall times** are tight: crisp 19us / cub 17us / cuda 18us at
  N=1M.  From a "user-feels-it" perspective, all three are
  indistinguishable.
- **Compile times** unchanged story — Crisp's device-only 0.18s vs
  nvcc's 0.56s (cuda) / 2.16s (cub) stays our biggest lead.

---

=== Crisp Benchmark Runner ===
  Host:   213.173.108.110:47263
  Branch: shore-up-benchmark
  Sizes:  1K,100K,1M
  Iters:  100

--- Step 1: Verify GPU ---
NVIDIA RTX PRO 4500 Blackwell, 12.0, 32623 MiB


--- Step 5: Run benchmarks ---
=== Build phase ===
Building CUDA hand-written...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cuda/sum_reduce.cu -o /root/crisp/benchmarks/reduction/cuda/sum_reduce
  Compiled in 1.88s (device-only: 0.56s)
Building CUB...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cub/sum_reduce_cub.cu -o /root/crisp/benchmarks/reduction/cub/sum_reduce_cub
  Compiled in 5.91s (device-only: 2.16s)
Building Crisp...
  Crisp compile [sum-reduce.crisp]: /root/crisp/bin/crisp-compile --ir-target=ptx /root/crisp/benchmarks/reduction/crisp/sum-reduce.crisp
  Crisp compiled in 0.18s
  nvcc harness: nvcc -O3 /root/crisp/benchmarks/reduction/crisp/bench_harness.cu -lcuda -o /root/crisp/benchmarks/reduction/crisp/sum_reduce_crisp
  Total 2.65s (device-only: 0.18s + harness: 2.47s)

=== Benchmark phase ===

Occupancy: 0.15 (parsed from sum-reduce.crisp, applied to both crisp and cuda)
  Running: cuda N=1000 ... 6.21 us (median)
  Running: cub N=1000 ... 3.39 us (median)
  Running: crisp N=1000 ... 6.88 us (median)
  Running: cuda N=100000 ... 5.86 us (median)
  Running: cub N=100000 ... 6.85 us (median)
  Running: crisp N=100000 ... 8.61 us (median)
  Running: cuda N=1000000 ... 8.22 us (median)
  Running: cub N=1000000 ... 7.26 us (median)
  Running: crisp N=1000000 ... 9.38 us (median)

============================================================
Compile Times
============================================================
        impl     device (s)     end-to-end (s)
  ----------   ------------   ----------------
       crisp           0.18               2.65
         cub           2.16               5.91
        cuda           0.56               1.88

====================================================================================================
Kernel Time (GPU hardware events, excludes host overhead)
====================================================================================================
         N      crisp (us)   crisp GB/s        cub (us)     cub GB/s       cuda (us)    cuda GB/s
-------------------------------------------------------------------------------------------------
      1000            6.88         0.58            3.39         1.18            6.21         0.64
    100000            8.61        46.47            6.85        58.41            5.86        68.31
   1000000            9.38       426.62            7.26       550.66            8.22       486.38

======================================================================
Wall Time (includes kernel + sync + D→H readback)
======================================================================
         N      crisp (us)        cub (us)       cuda (us)
----------------------------------------------------------
      1000           16.20           12.88           15.97
    100000           18.05           16.66           16.00
   1000000           19.04           16.97           18.05


=== Benchmark run complete ===