Endeavor 134 — MMA benchmarking + on-metal testing, across PTX and SPV
=======================================================================

Goal
----
Give the MMA work a **reusable, host-checked, cross-backend** verification + benchmarking
harness — so every MMA kernel (all four chapters, on both NVIDIA/PTX and Intel/SPV) is
correctness-checked on metal and benchmarked, without hand-written per-kernel fixtures.

Motivation: 132 (PTX) and 133 (SPV) landed the MMA fundamentals + a correct tiled matmul on
BMG, but on-metal verification is currently ad-hoc hand-edited L0 launchers
(put_temp_files_here/bmg_*_l0.cpp) with hardcoded sizes/inputs/expected values.  That doesn't
scale to the reuse ahead:

  Chapter 0 (synchronous)  →  Chapter 1 (async tile load)  →  Chapter 2 (pipelined/rings)
  →  Chapter 3 (warp-specialized)

All four share the SAME external interface — `C[M×N] = A[M×K]·B[K×N]` — only the internals
change.  So ONE parameterized verifier per backend covers all of them.


Key design decisions
--------------------
1. **Host reference, not hardcoded expected values.**  Fill A/B with a known pattern,
   compute `C = A·B` on the CPU, compare device C with a tf32 tolerance.  This catches
   transposes, stride/layout bugs, partial-accumulation bugs, any dims, any data — no per-
   test magic numbers (the throwaway harness's `C=8ij` was brittle).
2. **One parameterized verifier per backend** (not per spec, not per chapter).  Takes
   `M N K` (+ input pattern), sizes A=M×K, B=K×N, C=M×N, launches, checks.  The four chapters
   reuse it unchanged.  Model: `benchmarks/matmul/bench_harness.cu` ALREADY is this for CUDA.
3. **CI-gated like the existing on-metal tests** (`SKIP_L0_HOIST` / `SKIP_CUDA_HOIST` / no-GPU
   → skip cleanly).  Runs where a BMG (L0) or NVIDIA (CUDA) card is present.
4. **Per-vendor facts stay in the type/profile** (from 133): the MMA shape comes from the
   hardware profile's `:mma-shapes`; B's storage (`:contiguous-term`) is row-major on Intel,
   col-major on NVIDIA.  The harness just needs `M N K` + which backend.


Two workstreams
---------------
### A. Extend the matmul BENCHMARK to L0 (mirror the CUDA path)
`benchmarks/matmul/` already has crisp (PTX) vs hand-CUDA + `run.py` (GFLOPS + ratio).  Add:
- `crisp/bench_harness_l0.cpp` — the L0 twin of `bench_harness.cu`: load SPV, alloc A/B/C
  (from argv `M N K`), fill, host-reference correctness gate, timed launches (ze events),
  print GFLOPS JSON.  Reuse the arg-9-tuple layout the hoist emits.
- an Intel reference (a plain SYCL/L0 fp32 matmul, or oneDNN) as the "best-known" comparison,
  analogous to cuda/matmul.cu / cuBLAS.
- `run.py` gains a `--backend=l0|cuda` (or auto-detect) so the same driver benchmarks Crisp-
  on-BMG vs a reference-on-BMG.

### B. Expand the SPEC test system for on-metal MMA on BOTH backends
- A reusable **MMA on-metal validator** invoked by `TEST-HOIST[L0]` / `TEST-HOIST[CUDA]`:
  builds+runs the parameterized verifier against the spec's SPV/PTX, host-reference-checks C.
- New directive(s) to drive it — e.g. `MMA-DIMS: M N K` (the whole-tile problem size) and
  optionally `MMA-FILL: <pattern>` — so a spec DECLARES its matmul shape and gets on-metal
  correctness in CI on whichever backends are present.  (The stock hoist harness under-
  allocates a default 4×4 and zero-inits; MMA needs shape-aware sizing + inputs + a checker.)
- Stretch: fold the sizing/reference logic into the hoist generator itself (a `HOIST-MMA`
  mode), so no external verifier is needed.


Phases
------
[ ] P1 — L0 matmul benchmark verifier (`bench_harness_l0.cpp`), parameterized `M N K`, host-
    reference correctness gate.  Point it at the 133 BMG SPV kernels; retire the ad-hoc
    put_temp_files_here/bmg_*_l0.cpp harnesses.
[ ] P2 — `run.py --backend=l0` + an Intel reference matmul; Crisp-on-BMG GFLOPS vs reference.
[ ] P3 — `MMA-DIMS` directive + a `TEST-HOIST[L0|CUDA]` MMA validator that host-checks C;
    wire the 133 specs (10/11) + the 132 PTX matmul to it → on-metal correctness in CI,
    both backends, skip-gated.
[ ] P4 — (as the chapters land) reuse the same verifier for Chapter 1/2/3 kernels; no harness
    changes, just new SPV/PTX.

Deferred / later: fold into a `HOIST-MMA` generator mode; multi-tile grid-stride perf;
precision variants (fp16/bf16) once 133/132 add them.
