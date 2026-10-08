Endeavour 182 -- the NVIDIA register budget for streaming reductions
=====================================================================

Started 2026-10-08, straight out of 181 (`tests/spec/181-last-man-sweep/last-man-sweep.md`, RESULTS and
follow-up 1).  181 is NOT folded yet -- its overlays are still live; this endeavour builds on them.


Why
---

On an H100 SXM (181), last-man sum reaches 74% of the measured read peak at 4 GiB where `:atomic` on
the same grid reaches 96% and CUB 100%.  The sweep is not the cause.  SASS shows ptxas holding the
kernel to 32 registers -- what full occupancy allows (65536 / 2048 threads) -- and, to fit, routing every
load of the 16-load main loop through ONE register: one load in flight per thread.

Bandwidth needs bytes in flight: roughly 3.2 TB/s x ~600 ns / 132 SMs ~= 14 KB per SM.  Bytes in
flight per SM ~= blocks/SM x 256 threads x loads-in-flight x 4 B, and the 181 measurements line up:

| kernel (H100 SXM, 4 GiB) | regs | blocks/SM | loads in flight | ~KB in flight/SM | measured |
|---|---|---|---|---|---|
| last-man sum | 32 | 8 | 1 | 8 | 74% |
| `:atomic` sum | 32 | 8 | 3 | 24 | 96% |
| sum + sumsq | 40 | 6 | 8 | 48 | 97.5% |


The knob
--------

PTX launch bounds -- CUDA's `__launch_bounds__(256, N)`: `.maxntid 256, 1, 1` (the block size, which
Crisp knows from `(local-size :set-to ...)`) and `.minnctapersm N` (keep at least N blocks resident).
ptxas derives a register cap from them: N=8 -> 32, 6 -> 40, 5 -> 48, 4 -> 64.  LLVM's NVPTX backend can
emit both from IR (`nvvm.maxntid`, `nvvm.minctasm`).  The grid needs no change: hoist and bench fixture
already size it with cuOccupancyMaxActiveBlocksPerMultiprocessor on the compiled kernel.


Offline measurements (2026-10-08, no GPU)
------------------------------------------

`ptxas -arch=sm_90 -O3` + `cuobjdump` in nvidia/cuda:12.4.1-devel; the directives inserted into Crisp's
PTX by hand; `put_temp_files_here/e182/` (gen.py, ana.py).  "In flight" = the most LDG destinations
outstanding before any instruction reads one, in the hot loop (the backward branch with the most LDGs),
followed around the back edge.

| kernel | none | minCTA 8 / 7 | minCTA 6 | minCTA 5 | minCTA 4 |
|---|---|---|---|---|---|
| last-man sum (reduce-vec) | 32 r, **1** | 32, 1 | 40, **6** | 48, 14 | 53, 16 |
| `:atomic` sum | 32, 3 | 32, 1 | 40, 8 | 48, 16 | 48, 16 |
| sum + sumsq | 40, 8 | 32, 4 | 40, 7 | 48, 8 | 60, 8 |
| argmax | 48, 3 | 32, 9 + SPILLS | 40, 9 + SPILLS (9 LDL / 7 STL in loop) | 48, 2 | 64, 11 |
| Welford | 44, 4 | 32, 4 | 40, 4 | 48, 4 | 64, 4 |

- minCTA 6 gives every float stream 6-9 loads in flight; argmax needs >= 48 registers (it spills in its
  hot loop at 40 and at 32 -- no-directive argmax already chose 48 by itself).
- Welford is a CONTROL: its hot loop has 4 loads and a reciprocal (MUFU) per element -- registers should
  not move it.  Its 77% is a separate, compute-side problem.
- Stack frames (144-376 B) are outside the hot loops at every spill-free setting; see 181 follow-up 2.


Probe mechanism (temporary)
---------------------------

`overlays/crisp-compiler-overlay.lisp`, labelled PROBE: with `CRISP_PROBE_PTX_MINCTA=N` (and optional
`CRISP_PROBE_PTX_MAXNTID`, default 256) set, compile-to-ptx inserts the two directives into every
`.entry`.  Inert when unset.  NOT the feature -- it goes when the real mechanism lands.

Pod script: `scripts/182-pod-budget.sh` -- one build, the Crisp sweep at minCTA none / 6 / 5 / 4 over
`rollup/wg_atomic, step5_reduce_vec, workloads`, 64 MiB - 4 GiB, scratch; SUMMARY.txt is a compact table.


Open design question (after the measurement)
--------------------------------------------

Who picks N: a per-kernel declaration, a hardware-profile value (measured per architecture, like 180's
bytes-in-flight constant), or an automatic rule for streaming kernels (anything with loop-vector-stride
or a grid stride).  Matmul kernels have very different register needs, so scope to streaming kernels.


Plan
----

- [x] offline SASS sweep (above)
- [x] probe hook + pod script
- [ ] H100 measurement: minCTA none / 6 / 5 / 4
- [ ] design decision with Chris (who picks N)
- [ ] TDD tests (PTX carries .maxntid / .minnctapersm when expected; metal + bench), bump ci-stop
- [ ] implement via nvvm.maxntid / nvvm.minctasm; remove the probe hook
- [ ] re-measure; fold 181 + 182
