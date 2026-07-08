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


Progress / Status (as of 2026-07-08)
------------------------------------
The TEST-HARNESS workstream (B) landed first (it was the priority); benchmarking (A) is still
open.  Notably, the design evolved from an "external verifier" to the **stretch goal**: the
sizing + host-reference logic was folded into the HOIST GENERATORS themselves (a `--mma-test`
mode), so there is NO separate verifier binary.  This is chapter-proof: the generators already
emit every implicit arg (SLM/scratch tuples, launch config); `--mma-test` only overrides the
global A/B/C sizing + inputs and appends the host reference, so SLM-staged chapter kernels get
correctness for free.

DONE:
- **Hoist `--mma-test=M,N,K` mode**, both backends (overlays/hoist-l0/… + overlays/hoist-cuda/…):
  role-sizes A=M×K / B=K×N / C=M×N, non-uniform fills A/B (`i%5`/`i%3`), zeros C, and appends a
  STRIDE-AGNOSTIC host reference `C=A·B` → prints `MMA_CORRECT` / `MMA_WRONG`.  L0 reads USM
  directly; CUDA copies A/B/C back to host first (device memory).
- **Directives** (P3): `MMA-DIMS: M N K` (whole-tile problem size) + `MMA-SCALE: N` (expected
  C = N·(A·B), for kernels that fire the MMA >1× per fragment) + `HOIST-HARDWARE-PROFILE`
  (forwards the vendor shape).  Validators `validate-l0-mma-run` / `validate-cuda-mma-run`
  (spec-runner overlay) re-hoist the .metacrisp in `--mma-test` mode then delegate to the stock
  host-run validator (compile+run+HOIST-EXPECT).  Skip-gated (SKIP_*_HOIST / no toolchain).
- **L0 hoist fix:** ported the CUDA `%cuda-scratch-dims` 2-D-scratch support to L0
  (`%l0-scratch-dims` + `%l0-emit-local-scratch-tensor-arg` redef) so SLM-staged tiles like
  `(make-scratch-matrix float (8 16))` hoist.
- **On-metal verified:**
    - L0/BMG: 133/11 (single 16×16 tile) + NEW 133/12-tiled-matmul-bmg (SLM-staged, 2 K-steps,
      shape 8 16 8) → both MMA_CORRECT.
    - CUDA/RTX (RunPod): 132/04 (single tile), 132/05 (multi-fragment), 132/09 (accum-op body,
      scale 2) → all MMA_CORRECT.
- Local suite 867/867; MMA-SCALE plumbing byte-identical for non-scaled specs.

OPEN — bug 034 (see plan/bugs.md):
- **132/06 (CUDA SLM-staged tiled matmul, K=16 → 2 K-steps) is MMA_WRONG** with non-uniform
  inputs (C[0][0]: ref 30, device 13).  The harness caught a REAL pre-existing bug (old A=B=1
  benchmarks masked it).  NARROW: single-K-step CUDA (04/05/09) and the L0 multi-K-step (133/12)
  all pass → CUDA multi-K-step SLM path.  Left wired (red on GPU-CI; SKIPs locally).  Next:
  a K=8 single-step SLM probe to localize (multi-K-step accumulation vs SLM staging), then fix.

TODO next session:
- Investigate/fix bug 034 (K=8 SLM probe spec → pod run → localize → fix).
- Then benchmarking workstream (A): L0 bench_harness + oneAPI-Docker Intel reference; run.py
  `--backend=l0`.  (oneDNN dropped; Intel reference runs in the same oneAPI Docker container.)

Update 2026-07-08 — bug 034 FIXED
---------------------------------
The 132/06 miscompute was a CUDA-hoist SLM-aliasing bug (every local scratch tile emitted at
shared offset 0 → A-tile/B-tile overlapped; staging B clobbered A-tile rows 0-7).  Fixed by
assigning cumulative byte offsets per tile (overlays/hoist-cuda/, commit 8f3168b).  Diagnosed
locally without a GPU by diffing the host reference against the pod's device output (rows 8-15
exact, rows 0-7 = B's structure), then confirmed via the generated .cu (both ptr=0) and PTX.
VERIFIED on RTX: 132/06 output == reference; the 132-mma suite went 11/12 -> 12/12.  Both
backends now have on-metal-verified SLM-staged tiled matmul.  Only the benchmarking on-ramp
(workstream A) remains open.
