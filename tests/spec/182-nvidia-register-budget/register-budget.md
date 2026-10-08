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


H100 measurement (2026-10-08, H100 SXM, `scripts/182-pod-budget.sh`)
---------------------------------------------------------------------

% of the SXM's measured 3178.6 GB/s, 4 GiB; all 96 points verified; JSON in `benchmarks/results/scratch/`;
full table in `put_temp_files_here/e182/pod-SUMMARY.txt`.  Groups follow from the bound automatically
(8 blocks/SM = 1056, 6 = 792, 5 = 660, 4 = 528).

| kernel | none (today) | minCTA 6 | minCTA 5 | **minCTA 4** |
|---|---|---|---|---|
| `:atomic` sum | 95.8 | **99.1** | 97.1 | 97.1 |
| last-man sum | 74.8 | **97.8** | 96.9 | 96.5 |
| argmax | 80.3 | 85.0 | 77.0 | **96.7** |
| sum + sumsq | **97.6** | 96.9 | 97.1 | 95.9 |
| Welford | 77.6 | 94.1 | 92.6 | **96.2** |
| worst kernel | 74.8 | 85.0 | 77.0 | **95.9** |

- **minCTA 4 is the uniform choice**: every kernel 95.9-97.1% (CUB: 100% sum, 99% argmax).  minCTA 6 is
  best for the simple float sums but leaves argmax at 85% (it spills there -- predicted offline).
- **Small sizes favour 4 everywhere** (64 MiB: last-man sum 1195 -> 1684 GB/s, argmax 1167 -> 1480,
  Welford 873 -> 1344): fewer groups, so less per-group fixed cost (fence, ticket, partial).
- **The Welford prediction was WRONG.**  Offline said registers would not move it (4 loads + a MUFU in
  the loop, same SASS loads at every setting); measured 77.6% -> 96.2%.  Its limit was latency-hiding
  across the whole loop body, not loads per se.  Measure, don't classify (145's lesson again).
- Interpretation: 4 x 256 = 1024 threads per SM -- HALF occupancy -- with 64 registers each beats full
  occupancy at 32.  The classic memory-bound result: enough independent work per thread matters more
  than more threads.  For other block sizes the natural generalisation is a THREADS-per-SM target
  (1024 here), N = target / local-size.


Decisions (with Chris, 2026-10-08)
----------------------------------

- **D1 -- automatic** for kernels whose own body has a stream loop (`loop-vector-stride`, so `reduce-vec`).
- **D2 -- a hardware-profile key, not a compiler constant**: `:stream-occupancy-target` (threads per compute
  unit, MEASURED).  Absent => no bound (pre-182 behaviour).  Chris: a constant means a compiler change for
  every new part (CRI), and a tuning value measured in an empty room belongs where the operator can see and
  revise it.  (180's `*stream-unroll-bytes-in-flight*` constant has the same flaw -- a candidate to migrate.)
- **D3 -- `(declare (occupancy-target N))`** overrides per kernel; `nil` opts out.  Threads, like
  local-size; needs a compile-time local-size; must be >= one workgroup; a literal.
- **D4 -- PTX only.**  On SPIR-V the key and the declaration are accepted and do nothing.
- **D5 -- the measured value lives in `benchmarks/profiles/h100-sxm.crisp`** (hand-maintained; like any
  profile it is just another source file on the command line -- `crisp-compile h100-sxm.crisp <lib> <kernel>
  --hardware-profile=h100-sxm` -- which is what the bench harness's `--profile-file` does), because `--auto-profile` regenerates `h100-80gb-hbm3.crisp` on every run.  Not
  promoted to a builtin -- separate decision.  The generated skeleton and query-cuda.cu now name the key
  as a commented MEASURED line, so a new part's profile documents it without guessing it.


Implementation (overlays, 2026-10-08)
-------------------------------------

- `*hardware-profile-schema*` gains `(:stream-occupancy-target . :pos-int)`.
- `internal-def-function` (wrapper) binds `*analyzing-function*` and parses/validates `(occupancy-target ...)`
  into `*kernel-occupancy-targets*`; `%expand-loop-vector-stride-form` (wrapper) marks `*stream-functions*`.
- `%apply-cluster-dims-attribute` (wrapper) calls `%apply-occupancy-bound`, which stamps `"nvvm.maxntid"` and
  `"nvvm.minctasm"` (LLVM lowers them to `.maxntid` / `.minnctapersm`; checked with bin/llc.exe).
- Known limit: a stream loop inside a separately defined grid function marks that function, not the
  calling kernel -- declare the target on the kernel.
- Verified by hand: spec 01's PTX has `.maxntid 256` / `.minnctapersm 4`; its SASS has 53 registers and
  16 loads in flight (= the minCTA 4 probe); spec 05 has no bound; spec 08 is 512 / 2.
- The env-var PROBE hook is removed.


Plan
----

- [x] offline SASS sweep (above)
- [x] probe hook + pod script
- [x] H100 measurement: minCTA none / 6 / 5 / 4 -- minCTA 4 (1024 threads/SM) uniform winner
- [x] design decision with Chris (D1-D5)
- [x] TDD tests: 10 specs (01-09 PTX/SPIR-V compile + validators, 10 CUDA metal), 6 negative, unit file;
      ci-stop -> 182
- [x] implement via nvvm.maxntid / nvvm.minctasm; remove the probe hook; docs (ideal_001.md)
- [x] re-measure with the REAL mechanism (below)
- [x] fold 181 + 182 into src/ (2026-10-08): verbatim replacements by script (fold diff = exactly the
      overlay changes), wrappers re-expressed at their call sites, overlays emptied LAST; build has no
      redefinitions; 181 10/10 + 182 16/16; folded CUDA launcher identical to the overlay one but paths;
      chapters / reference / call graph / globals regenerated
- [ ] canonical benchmark runs from the folded commit (BMG Docker + H100 SXM pod), then REPORT-reduction


Verification -- the real mechanism (2026-10-08, a different H100 SXM, `scripts/182-pod-verify.sh`)
-------------------------------------------------------------------------------------------------

All 26 CUDA specs on metal (182: 16/16, 181: 10/10); every bench point verified; profile
`benchmarks/profiles/h100-sxm.crisp` via `--profile-file`.  THIS card's measured read peak is
3099.7 GB/s (the probe card's was 3178.6), so the baseline was re-run in the same session
(`--auto-profile`, no key).  % of 3099.7, 4 GiB:

| kernel | unbounded | `h100-sxm` profile | groups |
|---|---|---|---|
| `:atomic` sum | 93.0 | 93.9 | 1056 -> 660 |
| last-man sum | 75.5 | **93.4** | 1056 -> 528 |
| argmax | 80.3 | **94.5** | 660 -> 528 |
| Welford | 78.0 | **94.0** | 1056 -> 528 |
| sum + sumsq | **95.8** | 92.8 | 792 -> 528 |

Reproduces the probe: the three laggards gain 14-18 points and meet `:atomic`; sum+sumsq loses ~3 (it
was the one kernel already at a good budget by luck -- 40 registers at 792 groups).  `:atomic` gets 660
groups, not 528: .minnctapersm is a MINIMUM, and ptxas fitted it in 48 registers, 5 blocks per SM.

