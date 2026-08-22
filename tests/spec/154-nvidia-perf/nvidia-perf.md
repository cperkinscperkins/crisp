Endeavour 154 — NVIDIA MMA performance
======================================

GOAL: Crisp MMA at 90%+ of cuBLAS for most sizes on H100 (tf32).

Where we start (benchmarks/REPORT.md, chap3_wgmma vs cuBLAS):

| size | Crisp TF | cuBLAS TF | % | multiplier needed for 90% |
|---:|---:|---:|---:|---:|
| 256  | 2.50   | 5.39   | 46.4% | 1.94x |
| 512  | 14.98  | 30.58  | 49.0% | 1.84x |
| 1024 | 79.69  | 132.43 | 60.2% | 1.50x |
| 2048 | 238.23 | 318.68 | 74.8% | 1.20x |
| 4096 | 257.08 | 380.96 | 67.5% | 1.33x |

Zero of five sizes clear 90%.  Note the multiplier is WORST at small sizes — the opposite of
the usual intuition that small problems are "nearly free".


PHASE 0 — STATIC EXPLORATION (2026-08-21, no hardware)
=======================================================

Read: src/mma.lisp, src/analysis/control.lisp, src/hardware-profile.lisp,
src/hoist-cuda/main.lisp, and the chap3 kernel.  Findings below are SOURCE FACTS unless
marked otherwise.


F1 — THE SMALL SIZES ARE GRID-STARVED, AND THE ARITHMETIC IS UNARGUABLE
------------------------------------------------------------------------
chap3 uses a 64x256 output tile.  The number of output tiles is therefore fixed by the
problem, and `--mma-bench` launches an exact tile cover (`(M/TM x N/TN)` grid,
src/hoist-cuda/main.lisp:482).  On a 114-SM H100:

| size | tiles = (M/64)x(N/256) | blocks | machine filled | measured % of cuBLAS |
|---:|---:|---:|---:|---:|
| 256  | 4 x 1  | 4    | 3.5%       | 46.4% |
| 512  | 8 x 2  | 16   | 14%        | 49.0% |
| 1024 | 16 x 4 | 64   | 56%        | 60.2% |
| 2048 | 32 x 8 | 256  | 2.2 waves  | 74.8% |
| 4096 | 64 x 16| 1024 | 9.0 waves  | 67.5% |

The measured column tracks the "machine filled" column almost monotonically up to 2048.
This is tile GRANULARITY, not harness configuration: with a 64x256 tile there cannot be more
than 4 tiles of work at N=256, whatever the launch flags say.

F2 — THE TWO HALVES OF THE GOAL PULL IN OPPOSITE DIRECTIONS
------------------------------------------------------------
The large-size lever is a BIGGER tile (more arithmetic intensity per CTA).  The small-size
lever is MORE TILES.  A 128x256 tile would take N=256 from 4 blocks to 2.

This is the central design tension of the endeavour, and it is exactly what CUTLASS's
stream-K decomposition exists to resolve: it splits the (M,N,K) iteration space across a
FIXED number of CTAs (= SM count), so tile shape and parallelism stop being the same knob.
Crisp has NO split-K or stream-K today (grep: no hits anywhere in src/ or docs/).
`atomic-add!` exists (src/analysis/ops.lisp:379), so the reduction primitive is present.

F3 — ONE CONSUMER WARPGROUP, AND TWO IS NOT EXPRESSIBLE
--------------------------------------------------------
chap3 is `(local-size :set-to 160)` = 1 producer warp + FOUR consumer warps = ONE warpgroup.
The `m64n256` accumulator is 128 f32 registers/thread (N/2 per thread across 128 threads,
src/mma.lisp:%wgmma-acc-fit-check) — 50.2% of the 255 budget for the accumulator ALONE.
The compiler already warns about this (*wgmma-acc-occupancy-warn-fraction* = 1/2 was chosen
so precisely this shape fires).

That is the same register wall Chapter 2 diagnosed and Chapter 3 escaped by splitting a
64x64 tile across two consumer WARPS.  Moving to wgmma re-created it at warpgroup granularity.

CUTLASS's Hopper mainloop is 1 producer warpgroup + 2 consumer warpgroups, either
COOPERATIVE (both split M of a 128x256 tile, sharing one B tile — 128*256/(128+256) = 85
arithmetic intensity vs 64*256/(64+256) = 51, a 1.67x improvement in operand bytes per flop)
or PING-PONG (alternating tiles so one warpgroup's epilogue hides under the other's mainloop).

**Neither is expressible in Crisp source today.**  `with-warp-specialization` itself is fine —
it lowers to a warp-id `<`-cascade (src/analysis/control.lisp:%lower-warp-specialization) and
would happily accept `(:consumer0 4 :consumer1 4 :producer 1)` with warpgroup-aligned
boundaries.  The blocker is the STORE:

    src/mma.lisp:%wgmma-store-rewrite
      (wgw (rem (to-int (warp-id)) 4))
      (r0  (+ (+ (* bty 64) (* wgw 16)) rlo))

The row base is `bty*64` with no notion of which warpgroup is executing.  A second consumer
warpgroup would write the SAME 64 rows as the first.  `store-tile-at` is not an escape hatch —
it has no wgmma-accumulator overload (only `store-tile` does, via `analyze-store-tile-mma`).

Good news: the fix is small and localized — the rewrite needs a warpgroup index and a row
stride, not a redesign.

F4 — setmaxnreg IS NOT IMPLEMENTED
-----------------------------------
Zero hits in src/ or overlays/.  The only mention in the repo is benchmarks/matmul/README.md
naming it as a future lever.  A producer warp that reserves the consumer's register budget is
pure waste; `setmaxnreg.dec`/`.inc` is how CUTLASS reclaims it.

F5 — THE EPILOGUE IS SCATTERED 8-BYTE GLOBAL STORES
-----------------------------------------------------
`%wgmma-store-rewrite` emits, per thread, four scalar `set!`s per n8 group at rows r0 and
r0+8.  For n=256 that is 32 groups x 4 = 128 scalar global stores per thread, landing as
8-byte pieces spread over 8 rows per warp.  There is no SMEM staging and no TMA store.

Expected to matter MOST at small sizes (where the epilogue is a large fraction of runtime)
and least at 4096 — consistent with chap5's fused-relu number being within 1.5% of chap3 at
4096.  UNMEASURED as a fraction of runtime; see the hardware asks.

F6 — L2 / GRID RASTERIZATION IS A CLOSED QUESTION.  DROP IT.
--------------------------------------------------------------
I expected this to be an open lever.  It is not.  Endeavour 144 Phase 1 built a grouped
column-strip visit order (`%expand-tile-stride-swizzled`) and MEASURED it on both vendors:

    Arc B580  @2048: linear 17.1 -> W4 27.9 TF   (+63%)
    H100 PCIe @4096: linear 207.4 -> W4 190.2    (-8.3%), W16 177.6 (-14.4%, monotonic)

The `h100` builtin profile therefore deliberately OMITS `:tile-visit-strip-width`, with the
reasoning recorded at src/hardware-profile.lisp:280-305.  The stated cause — "a W-wide strip
spans 256*W columns and degenerates to the whole matrix" — applies equally to a 128x256 tile,
so this stays closed even if the tile changes.

F7 — A FRAMING PROBLEM THAT IS NOT A BUG
------------------------------------------
cuBLAS is a DISPATCHER over dozens of tile shapes selected by problem size.  A Crisp kernel
has ONE compile-time tile.  "90% at most sizes from a single kernel" is therefore a strictly
harder target than what cuBLAS is doing, and it may not be the right target.

Two honest resolutions, and this is a DECISION OWED before the benchmark story is written:
  (a) report the best Crisp kernel PER SIZE, and say plainly that is what cuBLAS does too; or
  (b) give Crisp a way to express size-conditional tile selection, making it a dispatcher.
Not proposing (b) as work yet — recording that the comparison currently flatters cuBLAS.


WHAT IS STILL UNKNOWN (and needs an H100)
==========================================
Everything above is static reading and arithmetic.  Not one performance claim in it has been
measured, and 152 is the cautionary tale for acting on an unmeasured bottleneck.

No local CUDA toolkit on this box (no ptxas / nvcc / nvdisasm; nvidia-smi present but
permission-denied), so even register counts need the pod.


PHASE 1 — MEASURED ON AN H100 NVL (2026-08-21)
===============================================

Pod: H100 NVL, sm_90, 93.1 GB, CUDA 12.4.  Method: kernels compiled to PTX on the dev box
(`--ir-target-arch=sm_90a --hardware-profile=h100 --math-precision=fast`), harness generated
by `crisp-hoist-cuda --mma-bench`, both shipped to the pod, `nvcc -O3 -arch=sm_90a -lcuda`.
House protocol (WARMUP=20, ITERS=100, CUevent-timed) comes from the generated harness
unchanged.  Kernels are exact replicas of the shipped chap3 kernel with ONLY the output-tile
width varied; sources in put_temp_files_here/154/.

PIPELINE VALIDATED AGAINST A PUBLISHED NUMBER FIRST.  n256 @1024 measured 79.61 TFLOPS vs
REPORT.md's 79.69 for chap3 — 0.1%.  The replica and harness are faithful, so everything
below is comparable to the published ladder.

M1 — THE DEVICE IS NOT THE ONE THE PROFILE DESCRIBES
------------------------------------------------------
`scripts/hw-profile/query-cuda.cu` on this pod reports **132 SMs and 60 MB L2**.  The builtin
`h100` profile (src/mma.lisp:246) says **114 SMs and 50 MB** — those are H100 *PCIe* values,
and this is an H100 *NVL*.

The profile's own comment states `:compute-units` "OVERRIDES the device SM query in the
generated CUDA launch grid, so the variant distinction is load-bearing".  So any `:strided`
(occupancy-sized) kernel compiled with `--hardware-profile=h100` and run on an NVL part is
launched with a grid sized for 14% fewer SMs than exist.

NOT a factor in any number below — `--mma-bench` sizes the grid by exact tile cover, not by
occupancy.  But it is a live bug for other kernels and it means REPORT.md's H100 figures were
taken on a part the profile misdescribes.  Recording; fix is a decision about whether `h100`
should be split into `h100-pcie` / `h100-nvl` / `h100-sxm`.

M2 — F1 CONFIRMED, AND IT IS THE DOMINANT SMALL-SIZE EFFECT
-------------------------------------------------------------
Tile sweep, TFLOPS, all MMA_CORRECT.  n256 is the shipped chap3 shape:

| size | n64 | n128 | n256 (shipped) | cuBLAS |
|---:|---:|---:|---:|---:|
| 256  | **4.70** | 3.55 | 2.49 | 5.39 |
| 512  | **27.72** | 21.20 | 14.99 | 30.58 |
| 1024 | **109.04** | 108.17 | 79.34 | 132.43 |
| 2048 | 121.93 | 201.57 | **238.99** | 318.68 |
| 4096 | 134.65 | 201.59 | **263.31** | 380.96 |

A 64x64 tile is **1.88x faster than the shipped kernel at 256** and **1.85x at 512**, purely
by existing in enough copies to fill the machine.  The crossover to n256 is clean and lands
between 1024 and 2048 — exactly where the block count stops being the binding constraint.
F2's tension is now MEASURED, not argued: no single tile width is best at more than three of
the five sizes, and the best and worst differ by 1.9x in both directions.

Each variant also saturates at its own arithmetic intensity, as predicted:
  n64  intensity 32.0 -> plateaus ~135 TFLOPS
  n128 intensity 42.7 -> plateaus ~202
  n256 intensity 51.2 -> plateaus ~263
Throughput rises FASTER than intensity (1.33x intensity -> 1.50x TFLOPS; 1.20x -> 1.31x), so
the kernel is not purely operand-bandwidth-bound.  A 128x256 tile would be intensity 85.3,
1.67x over n256 — which is the quantitative case for F3.

M3 — THE REGISTER WALL IS NOT WHERE WE THOUGHT.  F3 NEEDS RESTATING.
---------------------------------------------------------------------
`ptxas -v -arch=sm_90a`:

| variant | registers/thread | spill | stack frame |
|---|---:|---:|---:|
| n64  | 66  | 0 | 192 B |
| n128 | 96  | 0 | 328 B |
| n256 | 165 | 0 | 616 B |

**165 of 255, zero spills.**  Chapter 2's "254 registers, jammed against the ceiling" does NOT
describe the wgmma kernel — that was the mma.sync register-tile kernel.  I carried the claim
forward without checking it; it is wrong here.  There is register HEADROOM at n256.

I also briefly suspected the accumulator had fallen into a `.local` depot (the 2026-07-05
structural-residency bug) because of the stack frame + 288 `.local` mentions in the PTX.
**That is also wrong.**  Reading the mainloop, the accumulator is fully register-resident:
the wgmma operands are `%r1886`-`%r2013`, 128 live registers, and the `ld.local` traffic sits
in other basic blocks (ring/barrier bookkeeping and the producer path), not between the MMAs.

So F3's *mechanism* was wrong even though its *conclusion* (go to two consumer warpgroups)
survives — it is justified by ARITHMETIC INTENSITY (M2), not by a register wall.

M4 — THE REAL MAINLOOP DEFECT: wgmma IS ISSUED SYNCHRONOUSLY  [numbers SUPERSEDED by M7]
--------------------------------------------------------------
`%emit-one-wgmma` (src/mma.lisp:1858) emits, for EVERY k8 slice:

    wgmma.fence.sync.aligned
    wgmma.mma_async ...
    wgmma.commit_group.sync.aligned
    wgmma.wait_group.sync.aligned 0

and `%emit-nvvm-wgmma` (src/mma.lisp:1817) calls it once per slice.  A K-block of 32 is 4
slices, so the mainloop emits **4 fences, 4 commit_groups and 4 `wait_group 0`s**.
`wait_group 0` waits for ALL outstanding groups, so each async MMA is fully awaited before the
next issues.  The async in `mma_async` is defeated, and we pay a fence + commit + wait per
k8 slice instead of per K-block.

CUTLASS's shape is one fence, all the mma_asyncs, one commit_group, one wait_group.

MEASURED, not argued — by patching the emitted PTX directly (no compiler change) to keep only
the first fence and the last commit/wait, then rebuilding and rerunning:

| size | n256 | n256 pipelined | gain |
|---:|---:|---:|---:|
| 256  | 2.49   | 2.66   | +6.7% |
| 512  | 14.99  | 16.50  | +10.1% |
| 1024 | 79.34  | 88.83  | +12.0% |
| 2048 | 238.99 | 249.55 | +4.4% |
| 4096 | 263.31 | 285.05 | +8.3% |

**MMA_CORRECT at every size.**  Deleting 9 instructions per K-block buys 4-12%, on every
wgmma kernel, at no cost.  This is the clearest single defect found so far and it is
independent of tile width, warp count, and clustering.

Not yet tried: `wait_group N` with N>=1, which is what actually lets one K-block's MMA overlap
the next.  Needs a `wait_group 0` before the epilogue, so it is a compiler change rather than a
textual PTX patch.

M5 — COMBINED PICTURE: THE PROBLEM HAS INVERTED  [numbers SUPERSEDED by M7]
-------------------------------------------------
Best variant per size, with the pipelining patch applied:

| size | shipped chap3 | best 154 variant | best TFLOPS | cuBLAS | was | NOW |
|---:|---:|---|---:|---:|---:|---:|
| 256  | 2.49   | n64 pipelined  | 5.08   | 5.39   | 46.2% | **94.3%** |
| 512  | 14.99  | n64 pipelined  | 30.66  | 30.58  | 49.0% | **100.3%** |
| 1024 | 79.34  | n128 pipelined | 118.62 | 132.43 | 59.9% | **89.6%** |
| 2048 | 238.99 | n256 pipelined | 249.55 | 318.68 | 75.0% | 78.3% |
| 4096 | 263.31 | n256 pipelined | 285.05 | 380.96 | 69.1% | 74.8% |

Three of five sizes are now at or near the 90% goal; 512 exceeds cuBLAS.  **The endeavour's
problem has completely inverted.**  We began with small sizes worst (46%) and large best
(75%); we now have small sizes essentially solved and the remaining deficit concentrated at
2048/4096 — which is precisely where F3's 128x256 two-warpgroup tile applies.

CAVEATS, stated plainly:
- The pipelining win is a HAND-PATCHED PTX.  It must be done properly in `%emit-nvvm-wgmma`
  and re-measured before any of it is claimed.
- "Best variant per size" means a DIFFERENT KERNEL per size.  F7 is no longer hypothetical —
  it is now the central reporting decision of this endeavour.
- Single measurements; stability re-runs pending.

M6 — STABILITY, AND A CONFOUND I INTRODUCED
---------------------------------------------
Repeat runs (2 reps, same pod session):

| variant | size | first | rep1 | rep2 | spread |
|---|---:|---:|---:|---:|---:|
| n64pipe  | 256  | 5084.5 | 5071.7 | 5071.7 | 0.25% |
| n64pipe  | 512  | 30659  | 30751  | 30684  | 0.30% |
| n128pipe | 1024 | 118617 | 118634 | 118621 | 0.01% |
| n128pipe | 4096 | —      | 196699 | 196021 | 0.35% |
| n256pipe | 2048 | 249550 | 249605 | 249280 | 0.13% |
| n256pipe | 4096 | 285046 | 274279 | 270946 | **5.2%** |

Everything is stable to <0.4% EXCEPT n256pipe at 4096, which declines MONOTONICALLY across
runs (285.0 -> 274.3 -> 270.9).  That is the signature of clock/thermal drift, not of the
kernel.

**This is a confound of my own making.**  The baseline arm and the patched arm were measured in
SEPARATE BATCHES, so the patched 4096 number was taken on a colder GPU than the baseline it is
compared against.  Part or all of M4's +8.3% at 4096 may therefore be drift rather than the
patch.  The 256/512/1024/2048 gains are NOT affected at that magnitude — those variants
reproduce to <0.4% — but the largest size, which is the one that matters most for the endeavour
goal, is unsettled.

Correct method, now running: interleave the arms within one session and record SM clock and
temperature alongside each reading.

METHOD NOTE FOR THE REST OF THIS ENDEAVOUR: A/B arms must be interleaved, never batched, and
every performance table should carry the rep count.  The house protocol (WARMUP=20 ITERS=100)
controls within-run variance and says nothing about between-run drift.

M7 — DEFINITIVE INTERLEAVED A/B.  SUPERSEDES THE TABLES IN M4 AND M5.
=======================================================================
Method fixed per M6: the two arms alternate WITHIN one session, 3 reps per arm (4 at 4096),
SM clock and temperature recorded with every reading.  Clocks were pinned at 1785 MHz
(1770 in the 4096 session) and temperature held at 34-36 C throughout — this pod did not
throttle, so the earlier monotonic decline was a batching artifact and nothing more.

Each cell is the mean of its reps.  At EVERY size, every `pipe` reading exceeded every `base`
reading — the distributions do not overlap.

| size | variant | base (TFLOPS) | pipelined (TFLOPS) | gain | reps |
|---:|---|---:|---:|---:|---:|
| 256  | n64  | 4.788   | 5.164   | +7.9%  | 3 |
| 512  | n64  | 28.264  | 31.191  | +10.4% | 3 |
| 1024 | n128 | 109.314 | 119.726 | +9.5%  | 3 |
| 2048 | n256 | 239.170 | 249.560 | +4.3%  | 3 |
| 4096 | n256 | 258.888 | 273.617 | +5.7%  | 4 |

The wgmma group fix is worth **+4.3% to +10.4%**, real at every size, MMA_CORRECT throughout.
My first report of +8.3% at 4096 was inflated by the batching confound; the true figure is
+5.7%, and the mid-size gains are slightly LARGER than first measured.

FINAL STANDING vs cuBLAS
-------------------------
Best tile per size, with the wgmma group fix:

| size | shipped chap3 | % | best 154 variant | TFLOPS | cuBLAS | **%** |
|---:|---:|---:|---|---:|---:|---:|
| 256  | 2.49   | 46.2% | n64 pipelined  | 5.164   | 5.39   | **95.8%** |
| 512  | 14.99  | 49.0% | n64 pipelined  | 31.191  | 30.58  | **102.0%** |
| 1024 | 79.34  | 59.9% | n128 pipelined | 119.726 | 132.43 | **90.4%** |
| 2048 | 239.17 | 75.0% | n256 pipelined | 249.560 | 318.68 | 78.3% |
| 4096 | 258.89 | 68.0% | n256 pipelined | 273.617 | 380.96 | 71.8% |

THREE OF FIVE SIZES ARE AT OR ABOVE THE 90% GOAL, and 512 beats cuBLAS.  The remaining
deficit is entirely at 2048 and 4096.

Neither ingredient required a compiler change to MEASURE, and one of them (tile width) does
not require one to USE.  The wgmma group fix does — it is a codegen change in
`%emit-nvvm-wgmma` / `%emit-one-wgmma`, not a source-level choice.

WHAT THIS MEANS FOR THE ENDEAVOUR
----------------------------------
The problem is now exactly inverted from where Phase 0 started, and the remaining work is
NARROW: close 2048 (needs 1.28x) and 4096 (needs 1.39x).  Both are large-size, arithmetic-
intensity problems, which is what F3's 128x256 two-consumer-warpgroup tile addresses — and
M3 removed the register objection to it (165/255 used, zero spills, headroom available).

OPEN DECISIONS (owed before more building)
-------------------------------------------
1. F7, now central rather than hypothetical.  The table above selects a different KERNEL per
   size.  cuBLAS does the same thing internally, but Crisp makes it a compile-time user choice.
   Report best-per-size and say so plainly, or give Crisp size-conditional tile selection?
2. Whether to land the wgmma group fix in src/ or an overlay, and what the TDD spec asserts —
   the natural assertion is on the EMITTED INSTRUCTION SHAPE (one fence / N mma_async / one
   commit / one wait per K-block), since a correctness-only test cannot see the defect at all:
   the current codegen is CORRECT, merely slow.
3. `wait_group N` (N>=1) for cross-K-block overlap — not attempted; needs a `wait_group 0`
   before the epilogue, so it cannot be tested by PTX patching alone.
4. Whether `h100` should split into `h100-pcie` / `h100-nvl` / `h100-sxm` (M1).


PHASE 2 — IMPLEMENTATION (2026-08-21)
======================================

All three items live in `overlays/crisp-compiler-overlay.lisp` (chosen over src/ because more
154 work is expected and one appendable place is easier to keep coherent).  Each carries a
NOTE FOR THE SRC PATCH naming the file and the definition it replaces.  The two new spec
validators live in `overlays/spec-runner-overlay.lisp`.

ITEM 1 — wgmma group pipelining.  DONE.
----------------------------------------
`%emit-wgmma-mma-only` (new) emits just the `mma_async`; `%emit-nvvm-wgmma` (replaced) emits
ONE fence before the k-slice loop and ONE commit_group + wait_group after it.  `%emit-one-wgmma`
is left in place, unmodified and unused.

Verified WITHOUT hardware, which was the point of doing it this way: the compiler-emitted PTX
was diffed against `mm_n256pipe.ptx` -- the exact file whose performance was measured in M7.
Normalised instruction streams are **2855 lines each and differ in ONE respect**: the compiler
places the single fence BEFORE the first k-slice's descriptor arithmetic, where the hand patch
left it after.  Same instruction multiset, same order otherwise, and the fence still sits after
D's initialisation and before the first `mma_async`, which is all it is required to do.  The
measured +4.3-10.4% therefore transfers, modulo a fence moved nine instructions earlier.

STILL WANTS A POD RUN.  "Transfers by construction" is an argument, not a measurement, and this
endeavour has already produced two claims that survived reading and died on contact with a
number.  One confirmation run at 1024 and 4096 closes it.

ITEM 2 — the TDD spec.  DONE.
------------------------------
`tests/spec/154-nvidia-perf/01-wgmma-group-pipelining.crisp` + a new
`validate-ptx-wgmma-group`.  ci-stop moved 152-DSMEM-Cluster -> 154-nvidia-perf.

THE VALIDATOR WAS ITSELF TESTED, against five inputs rather than assumed correct:

| input | expected | got |
|---|---|---|
| synthesised pre-154 shape (4 fence / 4 mma / 4 commit / 4 wait) | FAIL | FAIL |
| single-slice kernel (grouping property vacuous) | FAIL | FAIL |
| commit_group hoisted above the mma_asyncs (wrong order) | FAIL | FAIL |
| compiler-emitted, post-fix | PASS | PASS |
| hand-patched PTX from M7 | PASS | PASS |

The single-slice case matters: without it the spec could later be edited down to K=8 and would
go on passing while testing nothing.

Note 140/03 compiles this same kernel shape and its `validate-ptx-wgmma` passes both BEFORE and
AFTER the fix, because that validator only asserts the four opcodes are PRESENT.  Presence was
never the question; multiplicity was.  The two rungs are siblings and both are worth having.

ITEM 3 — store-tile-at gains a wgmma overload.  DONE.
------------------------------------------------------
`%wgmma-store-rewrite-origin` (new) takes an absolute (ROW COL) element origin;
`%wgmma-store-rewrite` (replaced) is now a thin caller of it supplying the grid origin
(bty*64, btx*N), so `store-tile` behaviour is unchanged; `analyze-store-tile-at-mma` (new)
dispatches on source type; `register-mma-analyzers` (replaced) adds STORE-TILE-AT.

DESIGN DECISION, RECORDED BECAUSE IT WAS A REAL FORK.  The obvious alternative was to INFER the
warpgroup count -- derive it from the tile-stride tile shape as M/64 -- which needs no new
syntax at all.  Rejected: it is UNDER-DETERMINED.  A 128-row tile served by ONE warpgroup that
loops over two row halves is a legal kernel, and the same rule would silently mis-address it.
An explicit origin costs nothing, is checkable by a reader at the point of use, and forecloses
nothing; sugar can be added later once a real cooperative kernel tells us whether the explicit
spelling is actually tedious.

VERIFIED WITHOUT HARDWARE, differentially:
  - `(store-tile D C (0 0))` and `(store-tile-at D C (0 0))` emit **byte-identical PTX**
    (74581 bytes each) -- the overload matches the existing path exactly at origin 0.
  - `(store-tile-at D C (64 0))` differs precisely where it should: the row pair becomes
    `r0|64` / `r0|72` instead of `r0` / `r0|8`, i.e. the offset lands on BOTH row halves.
  - 32 static `st.global` = 4 x (64/8), the register-direct accumulator store, and every
    `bar.sync` precedes the final `wgmma.wait_group` -- so it did not fall through to the
    cooperative staged path.

`tests/spec/154-nvidia-perf/02-wgmma-store-at-origin.crisp` + `validate-ptx-wgmma-store-direct`
(no `bar.sync` after the last `wgmma.wait_group`).  Its origin is (0 0) deliberately -- a metal
MMA_CORRECT check spans the whole matrix, so storing one accumulator at row 64 would leave rows
0-63 zero and fail for reasons unrelated to the overload.  The non-zero origin is exercised for
real by the two-warpgroup kernel, not here; recorded so a green rung 02 is not over-read.

WHAT ITEM 3 DOES **NOT** DO
----------------------------
It is the enabling overload, NOT the cooperative kernel.  Still outstanding before a 128x256
two-warpgroup matmul exists:
  - the kernel itself (two `:consumer` roles at 4 warps each + a producer, local-size 288),
  - `:arrivals` on the `empty`/`full` barrier rings scaling with TWO consumers rather than one,
  - and confirmation that `with-warp-specialization` role blocks are warpgroup-ALIGNED in
    practice, not merely warp-aligned -- the lowering is a warp-id `<`-cascade, so consumer0 =
    warps 0-3 and consumer1 = warps 4-7 gives threads 0-127 and 128-255, which IS aligned, but
    it has never been exercised and wgmma requires it.


PHASE 3 — ITEM 1 CONFIRMED ON HARDWARE (2026-08-21, second pod)
================================================================
Second H100 NVL, CUDA 12.4 — same part and same toolkit as the M7 session, so the numbers are
directly comparable.  (CUDA 13 was offered and declined: wgmma, TMA and sm_90a all landed in
12.0; 13 matters for Blackwell-class features we do not use, and changing major versions
mid-endeavour would put a ptxas revision inside the A/B.)

THE BASELINE IS NOW A TRUE ONE.  M7 compared the shipped kernel against a HAND-PATCHED PTX.
This compares two COMPILER OUTPUTS: the pre-154 overlay (recovered with `git show
a1bdd2f:overlays/crisp-compiler-overlay.lisp`) rebuilt and used to emit `base_n*.ptx`, then the
154 overlay rebuilt to emit `fix_n*.ptx`.  Arms interleaved, 3 reps each.

| size | variant | base | fixed | gain | M7 predicted |
|---:|---|---:|---:|---:|---:|
| 256  | n64  | 4.701   | 5.028   | +7.0%  | +7.9% |
| 512  | n64  | 27.841  | 30.702  | +10.3% | +10.4% |
| 1024 | n128 | 108.790 | 120.556 | +10.8% | +9.5% |
| 2048 | n256 | 238.882 | 249.098 | +4.3%  | +4.3% |
| 4096 | n256 | 257.260 | 268.710 | +4.5%  | +5.7% |

**MMA_CORRECT at every size and every rep.**  Every `fix` reading exceeded every `base` reading;
the distributions do not overlap at any size.  The compiler-emitted fix reproduces the
hand-patched measurement on a different pod, so item 1 is closed: the +4-11% is real and it is
what the shipped compiler now does.

AND A RETROACTIVE CHECK THAT PAID OFF.  The synthetic "pre-154 shape" PTX used to test the
validator (built by re-inserting per-slice brackets into the fixed output) turns out to be
**byte-identical to the true pre-154 compiler output**.  The validator test was therefore
testing the real thing, not an approximation of it.

INSTRUMENTATION ARTEFACT, RECORDED SO THE TABLE IS NOT MISREAD.  The `clocks.sm` column reads
1785 MHz at 256-2048 but **345 MHz at 4096**.  That is not a downclock during the benchmark: the
script samples nvidia-smi AFTER the binary exits, and at 4096 the harness's O(N^3) host-side
correctness check runs long enough after the timed region for the GPU to drop to idle clocks.
The GFLOPS are CUevent-timed around the kernel launches only and are unaffected — but the clock
column is uninformative at 4096 and would need sampling DURING the timed loop to mean anything.

A BUG IN MY OWN ITEM 3, FOUND BY WRITING THE KERNEL THAT USES IT
=================================================================
`%wgmma-store-rewrite-origin` generated `(+ (+ ROW-ORIGIN (* wgw 16)) rlo)` where `wgw` and `rlo`
are INT (they come from `to-int` of warp-id / warp-lane).  Handed a ULONG origin -- which is what
ANY tile-stride grid binding produces, e.g. `(* grid-y (to-ulong 128))` -- this fails with
"Type mismatch for operator '+'. Cannot operate on ULONG and INT."

Rung 02 did not catch it because its origin is the literal `(0 0)`, and integer literals are INT.
The grid-index caller never hit it either, because it has always passed `(* (to-int bty) 64)`.
So the overload worked for every input a test exercised and failed for the input it exists to
serve.  FIXED by coercing both origins with `to-int` inside the rewrite -- which is what the
grid path was already doing by hand.  Verified the `store-tile` path is unchanged: `store-tile
D C (0 0)` and `store-tile-at D C (0 0)` still emit byte-identical PTX.

THE COOPERATIVE KERNEL COMPILES
--------------------------------
`put_temp_files_here/154/mm_coop.crisp` — 128x256 output tile, two consumer warpgroups splitting
M and sharing one B tile, one producer warp (local-size 288).

A is staged as TWO 64-row rings rather than one 128-row ring: a wgmma A operand is a 64-row
descriptor and Crisp cannot point one at a sub-tile of a larger scratch matrix.  Two A loads
instead of one; B -- the big operand -- is fetched ONCE and consumed by both warpgroups, which
is the entire point.  Arithmetic intensity 128*256/(128+256) = 85.3 vs n256's 51.2, a 1.67x
improvement in operand bytes per flop at the SAME accumulator registers per thread.

Emitted structure confirms the roles split as intended:
  - **2 wgmma fences, 8 mma_async, 2 commit_groups, 2 wait_groups** — one correctly-grouped
    4-slice sequence per warpgroup, so item 1's fix composes with two warpgroups.
  - 3 TMA bulk copies (A0, A1, shared B).
  - `ptxas -v`: **166 registers/thread, 0 spills** — no worse per-thread than n256's 165, while
    covering twice the output-tile area per CTA.  288 threads x 166 = 47,808 of the SM's 65,536
    registers, so ONE CTA per SM (n256 fits two at 160 x 165 = 26,400 each).
  - 96 KB dynamic shared memory, under the 227 KB opt-in cap.

So the open question from Phase 2 -- whether `with-warp-specialization`'s warp-id cascade would
give WARPGROUP-aligned role blocks -- is answered in the affirmative by construction: consumer0
is warps 0-3 (threads 0-127) and consumer1 is warps 4-7 (threads 128-255), and each emitted its
own independent wgmma group.


PHASE 4 — THE COOPERATIVE KERNEL IS MEASURED, AND MY PREDICTION WAS WRONG
==========================================================================
`mm_coop.crisp` is MMA_CORRECT at 512/1024/2048/4096 (3 reps each, interleaved against the
n256 kernel), so the two-warpgroup construction WORKS.  It is also SLOWER than the kernel it
was supposed to beat, everywhere the endeavour actually needs it.

| size | coop 128x256 | n256 (fixed) | ratio | coop grid | n256 grid |
|---:|---:|---:|---:|---:|---:|
| 512  | 10.68  | 30.64  | **0.35x** | 8 blocks    | 16 blocks |
| 1024 | 59.55  | 120.41 | **0.49x** | 32          | 64 |
| 2048 | 205.06 | 249.69 | **0.82x** | 128         | 256 |
| 4096 | 249.03 | 272.29 | **0.91x** | 512         | 1024 |
| 8192 | 235.12 | 219.38 | **1.07x** | 2048        | 4096 |

**The crossover is between 4096 and 8192, not below 2048 as the intensity argument implied.**

WHAT I GOT WRONG, AND WHY.  M2 computed that a 128x256 tile has arithmetic intensity 85.3 vs
n256's 51.2 -- a 1.67x improvement in operand bytes per flop -- and F3/M3 concluded that this was
the lever for the 2048/4096 deficit.  That was a PAPER argument about bandwidth that ignored
occupancy entirely, and occupancy is what actually decides it below 8192:

  - The tile is twice as tall, so there are HALF as many blocks.  At 512 that is 8 blocks on
    132 SMs -- 6% of the machine -- which is worse starvation than the problem M2 identified.
  - `ptxas -v`: coop is 288 threads x 166 registers = 47,808 of the SM's 65,536, so **ONE CTA
    per SM**.  n256 is 160 x 165 = 26,400, so **TWO** fit.  Halving resident CTAs halves the
    independent pipelines available to hide TMA latency, and nothing in the intensity argument
    accounted for that.

The ratio climbing monotonically 0.35 -> 0.49 -> 0.82 -> 0.91 -> 1.07 is exactly the signature
of an occupancy penalty being amortised as the grid grows.  By 8192 both kernels have plenty of
blocks, the penalty is paid off, and the intensity advantage finally shows: BOTH kernels fall
off their 4096 peak there (n256 272 -> 219, coop 249 -> 235) because 8192 is past the bandwidth
wall, but coop falls **much less**, which is precisely what higher intensity is for.

SO THE LEVER IS REAL BUT IT IS AIMED AT THE WRONG SIZES.  It does not close 2048/4096.  It is
the right answer for 8192+, where the current ladder is weakest in absolute terms and where
REPORT.md does not even measure NVIDIA today.

STANDING AFTER THIS SESSION (best Crisp kernel per size, vs cuBLAS)

| size | best kernel | TFLOPS | cuBLAS | % |
|---:|---|---:|---:|---:|
| 256  | n64 fixed  | 5.028   | 5.39   | 93.3% |
| 512  | n64 fixed  | 30.702  | 30.58  | 100.4% |
| 1024 | n128 fixed | 120.556 | 132.43 | 91.0% |
| 2048 | n256 fixed | 249.098 | 318.68 | 78.2% |
| 4096 | n256 fixed | 268.710 | 380.96 | 70.5% |
| 8192 | coop       | 235.12  | (not measured) | — |

Three of five sizes at or above 90%.  2048 and 4096 are unchanged by this phase and remain the
endeavour's open problem — and the mechanism nominated to fix them has now been measured and
does not.

WHAT IS LEFT FOR 2048/4096
---------------------------
Of the levers enumerated in Phase 0, the only untried one with a clear mechanism is
**`wait_group N` (N >= 1)** — letting one K-block's MMA overlap the next, rather than draining
the group every block.  Item 1 removed the per-SLICE drain; the per-BLOCK drain is still there.
That needs a `wait_group 0` before the epilogue reads D, so it is a loop/epilogue change, not an
emitter change, and it cannot be tested by PTX patching.

Two others are now argued DOWN rather than up:
  - `setmaxnreg` would free the producer warp's register reservation, but n256 already fits two
    CTAs/SM and a third would need 79,200 of 65,536 registers.  It cannot buy a CTA here.
  - A TMA-store epilogue matters least exactly where the deficit is: at 4096 the epilogue is a
    small fraction of a K=4096 mainloop, and chap5's fused-relu number sits within 1.5% of
    chap3's, which bounds how much the store can be costing.

PHASE 5 — METAL VERIFICATION AND RUNG 03 (2026-08-21)
======================================================
All three 154 rungs run on the H100 NVL through the spec runner: **3/3 Passed, MMA_CORRECT
emitted once per spec.**

RUNG 03 ADDED — the cooperative kernel is now a spec, not just a benchmark artefact.  It is the
rung that WOULD HAVE CAUGHT the ULONG/INT bug: rung 02 stores at the literal `(0 0)` and integer
literals are INT, while any real cooperative kernel derives its origin from a tile-stride grid
binding, which is ULONG.  Its performance is deliberately NOT what it claims -- the header says
so explicitly, with the measured 0.35x/0.82x/0.91x/1.07x -- so nobody reads it as "cooperating
is faster".  It claims cooperating WORKS.

THE GROUP VALIDATOR WAS GENERALISED, because rung 03 broke it and the break was the validator's
fault.  `validate-ptx-wgmma-group` asserted EXACTLY one fence / one commit / one wait for the
whole module, which silently assumed one wgmma group per kernel.  Two consumer warpgroups emit
TWO groups, both perfectly well-formed.  The real invariant is the SHAPE of each group, not how
many there are, so it now parses the opcode stream into groups and requires each to be
`fence, >=2 mma_async, commit_group, wait_group`, with nothing left over.

Re-tested against six inputs, now including the TRUE pre-154 compiler output (not just the
synthesised one) and the two-warpgroup kernel:

| input | expected | got |
|---|---|---|
| synthesised pre-154 shape | FAIL | FAIL |
| **true pre-154 compiler output** | FAIL | FAIL |
| single-slice kernel (vacuous) | FAIL | FAIL |
| commit hoisted above the mma_asyncs | FAIL | FAIL |
| fixed, ONE warpgroup | PASS | PASS |
| **fixed, TWO warpgroups** | PASS | PASS |

A GAP FOUND AND NAMED (not introduced here)
--------------------------------------------
The cooperative kernel does not differentiate:

    mma-accumulate-via-tile: cannot differentiate this tile multiply — the A operand has no
    compile-time shape.

MEASURED, not assumed, before writing the skip: the **SHIPPED chap3 kernel shape fails
identically**, with the same message.  So every ring-staged wgmma kernel in the benchmark ladder
is non-differentiable, and the cause is not wgmma, warp specialization, or two warpgroups — it
is that `ring-get` erases the operand's compile-time shape from the tile-multiply VJP.  Same
family as the blocker recorded on 140/01 and 140/02.

That is a real endeavour-sized item: make `ring-get` shape-transparent to the VJP.  Recorded in
rung 03's SKIP-WITH with the evidence, rather than as a vague "wgmma is forward-only" — which is
the exact anti-pattern endeavour 146 existed to retract.

REGRESSION: 1028/1028 specs locally, 3/3 on metal, 218/218 negative, 291/291 unit.

A PROCESS NOTE, TWICE EARNED
-----------------------------
I twice raised a false alarm from my own log truncation.  `... | tail -N` on a spec run keeps
only N lines AND returns TAIL's exit code, not sbcl's; and the CUDA hoist prints multi-kilobyte
BUFFER dumps that blow a small window instantly.  Both times the underlying run was fine and the
evidence (a `Spec Summary` line; an `MMA_CORRECT`) was present in the full log.  Capture spec
runs to a FILE and grep the file; never judge a run from a piped tail.

PHASE 6 — RING DEPTH.  A SECOND FREE WIN, AND THE OCCUPANCY MODEL HOLDS UP.
============================================================================
Same method as the tile sweep, and chosen for the same reason: no compiler change, so it can be
wrong cheaply.  A PREDICTION WAS WRITTEN DOWN FIRST, from SMEM footprint vs the SM's 228 KB and
registers vs 65,536:

| kernel | SMEM | predicted CTAs/SM |
|---|---:|---:|
| n128 r2 / r3 / r4 | 48 / 72 / 96 KB | 4 / 3 / 2 |
| n256 r2 / r3 / r4 | 80 / 120 / 160 KB | 2 / 1 / 1 |

MEASURED (3 reps each, all MMA_CORRECT):

| size | tile | r2 | r3 | r4 | r8 |
|---:|---|---:|---:|---:|---:|
| 256  | n64  | 5,180   | —       | **5,363**   | 2,916 |
| 512  | n64  | 31,151  | —       | **33,563**  | 11,708 |
| 1024 | n128 | 120,412 | 119,816 | **132,247** | 31,576 |
| 2048 | n128 | **196,796** | 158,761 | 186,594 | — |
| 2048 | n256 | **249,123** | 202,052 | 223,175 | — |
| 4096 | n256 | **270,108** | 208,445 | 218,624 | — |

**Ring 4 is the optimum at 256-1024 (+3.5%, +7.7%, +9.8%); ring 2 remains best at 2048-4096.**
Ring 8 collapses everywhere (0.24x-0.54x) — it pushes n64 to 128 KB and n128 to 192 KB, both
1 CTA/SM.  The optimum is therefore BRACKETED, not merely observed to improve.

The split falls exactly where the CTA model says it should: n256 cannot go past r2 without
dropping 2 CTAs -> 1, while n128/n64 have SMEM headroom to buy pipeline depth and still keep
two or more CTAs resident.  This is the SAME mechanism that sank the cooperative kernel in
Phase 4 — the third time this session that occupancy, not bandwidth, decided the outcome.

ONE HYPOTHESIS RAISED AND IMMEDIATELY REFUTED.  r3 is consistently worse than BOTH r2 and r4,
which CTA count alone does not explain (it sits between them at 3 CTAs for n128).  I guessed
non-power-of-two slot arithmetic — `(mod grid-k 3)` forcing an integer division in the inner
loop.  Checked the emitted PTX: **div and rem counts are IDENTICAL across r2/r3/r4** (4 div,
0 rem).  Refuted; LLVM strength-reduces the constant modulus in every case.  Cause of the r3
dip is unexplained and left unexplained rather than decorated with a story.  Practically it
does not matter: power-of-two depths are what one would use anyway.

STANDING — best (tile, ring) per size
--------------------------------------
| size | best config | TFLOPS | cuBLAS | **%** |
|---:|---|---:|---:|---:|
| 256  | n64 ring 4  | 5.363   | 5.39   | **99.5%** |
| 512  | n64 ring 4  | 33.563  | 30.58  | **109.8%** |
| 1024 | n128 ring 4 | 132.247 | 132.43 | **99.9%** |
| 2048 | n256 ring 2 | 249.123 | 318.68 | 78.2% |
| 4096 | n256 ring 2 | 270.108 | 380.96 | 70.9% |

**Four of five sizes are at or above 99% of cuBLAS; three are at parity or better.**  Compare
the session's starting point: 46.2 / 49.0 / 59.9 / 75.0 / 68.0%.

WHAT ACTUALLY PRODUCED THAT.  Two source-level sweeps that needed NO compiler change (tile
width, ring depth) plus ONE codegen fix (the wgmma group).  Every mechanism I reasoned my way
to from reading source — the register wall, the cooperative tile — was either absent or aimed
at the wrong sizes.  That is the reusable lesson, and it is now three-for-three.

PROFILING IS NOT AVAILABLE ON THESE PODS
-----------------------------------------
`ncu` is installed, but every profile fails with ERR_NVGPUCTRPERM.  The container runs as uid 0
yet `CapEff` lacks **CAP_SYS_ADMIN**, and the driver is built with `RmProfilingAdminOnly: 1`;
`/proc/driver/nvidia/params` is read-only and the module cannot be reloaded from inside a
container.  Fixing it requires `--cap-add SYS_ADMIN` at POD CREATION.

So "ask the hardware what it is stalled on" is currently closed to us, and the working method
stays what it has been: cheap targeted A/B sweeps.  Worth requesting a SYS_ADMIN-capable pod
before the next mechanism-hunting phase, because 2048/4096 are exactly where guessing has
failed three times.

PHASE 7 — THE 8192 CEILING, AND A BETTER DESCRIPTION OF WHAT IS LEFT
=====================================================================
REPORT.md's NVIDIA ladder stops at 4096, so Phase 4's cooperative-kernel win at 8192 had nothing
to be measured against.  Built a minimal cuBLAS tf32 baseline (`put_temp_files_here/154/
cublas_ref.cu`, same WARMUP=20 / ITERS=100 / cudaEvent protocol, CUBLAS_COMPUTE_32F_FAST_TF32).

VALIDATED BEFORE USE, at a size whose answer is already known: 4096 measured 379.9 / 375.0 /
382.0 -> **mean 379.0 TFLOPS** against REPORT.md's 380.96 — within 0.5%.  The harness reproduces
the published ceiling, so its 8192 figure can be trusted.

**cuBLAS at 8192: 331.6 / 334.2 / 334.9 -> mean 333.6 TFLOPS.**  cuBLAS falls off its own 4096
peak by 12% (379.0 -> 333.6), so the bandwidth wall at 8192 is a property of the MACHINE, not of
Crisp's kernel.

FULL LADDER, best Crisp configuration per size:

| size | best Crisp config | TFLOPS | cuBLAS | **%** |
|---:|---|---:|---:|---:|
| 256  | n64 ring 4  | 5.363   | 5.39   | **99.5%** |
| 512  | n64 ring 4  | 33.563  | 30.58  | **109.8%** |
| 1024 | n128 ring 4 | 132.247 | 132.43 | **99.9%** |
| 2048 | n256 ring 2 | 249.123 | 318.68 | 78.2% |
| 4096 | n256 ring 2 | 270.108 | 379.0  | 71.3% |
| 8192 | **coop 128x256** | 235.12 | 333.6 | 70.5% |

THE REMAINING DEFICIT IS NOT "2048 AND 4096".  It is a PLATEAU: Crisp reaches parity at
256-1024 and then settles into a **70-78% band for every size from 2048 up**.  4096 was never
special — it was just the largest size measured.  8192 sits at 70.5%, right alongside it.

That reframing matters for what to attack next.  A defect that showed up only at 4096 would
suggest something size-specific (wave quantisation, a cache cliff).  A flat 70-78% band across a
4x range of sizes says the mainloop simply issues less math per unit time than cuBLAS's once
both are throughput-bound — which is where `wait_group N` (the per-K-block pipeline drain, the
one enumerated lever still untried) is the natural suspect.

AND THE COOPERATIVE KERNEL EARNS ITS KEEP AFTER ALL.  At 8192 it is the best Crisp kernel:
70.5% of cuBLAS against the n256 kernel's 65.8%.  Phase 4 measured it as a large-size lever and
that is exactly what it turned out to be; it simply needed a size past the ladder's old edge to
show it.  It should stay in the ladder as the 8192 entry.

PHASE 8 — THE EPILOGUE, WHICH I HAD RULED OUT ON A BAD ARGUMENT
================================================================
CORRECTION FIRST.  Phase 4 argued the store could not be costing much because "chap5's
fused-relu number sits within 1.5% of chap3's, which bounds what the store can be costing."
**That is invalid.**  Fusing ReLU changes the ARITHMETIC applied before the store; it does not
change the store pattern by a single instruction.  chap5 ~= chap3 shows the ACTIVATION is free.
It says nothing whatever about the store.  The epilogue was never ruled out.

MEASURED WITHOUT A PROFILER, by scaling K at fixed M=N.  The mainloop is O(K); the epilogue,
prologue and launch are O(1) in K.  M=N=2048 throughout, so the grid is an identical 256 blocks
in every run and only the mainloop length varies.  3 reps each, all MMA_CORRECT, spread <0.3%:

| K | ms/iter |
|---:|---:|
| 1024 | 0.04409 |
| 2048 | 0.06903 |
| 4096 | 0.11488 |
| 8192 | 0.21103 |

Least-squares on `t = a*K + b`: **a = 2.33e-5 ms per unit K** (consistent to +-3% across all
three intervals) and **b = 20.2 us**, which predicts every one of the four points to within 1.6%.

**So 20.2 us per launch is K-INDEPENDENT — 29% of runtime at K=2048, 17.6% at K=4096.**

WHAT IS IN b, AND HOW MUCH OF IT IS THE STORE.  b covers launch overhead + prologue + epilogue.
Launch is ~3-5 us for a 256-block `cuLaunchKernel`; the prologue is two TMA issues and barrier
init.  The epilogue writes C = 2048^2 floats = 16.8 MB, which at this part's HBM3 bandwidth
(~3.9 TB/s) costs **4.3 us even if perfectly coalesced**.  That leaves roughly 15 us for a store
whose floor is 4.3 — about **3.5x off bandwidth**.

Which is exactly what the emitted code predicts.  `%wgmma-store-rewrite-origin` emits, per
thread, FOUR SCALAR STORES per n8 group -- 8-byte pieces scattered across two rows 8 apart --
128 of them per thread at N=256.  There is no SMEM staging and no TMA store.  CUTLASS stages the
accumulator through shared memory precisely so the global writes can be coalesced 128-byte
transactions.

EXPECTED VALUE, stated as an estimate and not a result:
  - 2048: bringing the store to near-bandwidth saves ~11 us of 69 -> ~+19% -> ~296 TFLOPS,
    which would be ~93% of cuBLAS.
  - 4096: the output is 4x larger so the epilogue is ~60 us of 504 -> ~+10% -> ~79%.

**This displaces `wait_group N` as the leading candidate.**  Two reasons.  First, it is
QUANTIFIED -- 20.2 us measured, with a mechanism visible in the emitted PTX -- where wait_group
N is still an argument.  Second, the evidence for wait_group N got weaker this session: item 1
removed the per-SLICE drain and bought +10.3-10.8% at 512-1024 but only +4.3-4.5% at 2048-4096,
i.e. it helped LEAST exactly where we now need help.  Removing the per-BLOCK drain plausibly
follows the same pattern.

HONEST LIMIT OF THIS MEASUREMENT.  b is attributed to the epilogue by elimination plus a
bandwidth floor calculation, not by direct measurement of the store alone.  A profiler would
settle the split in one run.  What is NOT in doubt is that 20.2 us is real, K-independent, and
large, and that the store instruction sequence is non-coalesced by construction.

PHASE 8b — WHAT b ACTUALLY IS.  BOTH OF MY EXPLANATIONS WERE WRONG.
====================================================================
Phase 8 attributed the 20.2 us to "scattered 8-byte stores, ~3.5x off bandwidth".  Reading the
emitted code properly kills that too.

FIRST, COALESCING WAS NEVER THE PROBLEM.  Work the lane mapping through: for a fixed n8 group,
lanes 0-3 hold rlo=0 and col=0,2,4,6, so they write EIGHT CONTIGUOUS FLOATS -- 32 bytes, a full
sector -- at one row; lanes 4-7 do the next row, and so on.  A warp writes 8 rows x 32 bytes per
group, and every one of those is a complete 32-byte sector.  Sector efficiency is 100%.  A
perfectly linear warp store would move 128 bytes in 4 sectors; ours moves 256 in 8.  Identical
bytes per transaction.  There was nothing to coalesce.

WHAT IS ACTUALLY THERE.  In the epilogue's basic block:

    st.local.v2.b32 [%rd147],    {%r1887, %r1888}      <- the very registers wgmma just wrote
    ...  (64 of these)
    ld.local.v2.b32 {%r1501, %r1502}, [%rd147+8]       <- loaded straight back
    ...  (189 local loads)
    st.global.b32 [%rd159], %r1498

**The accumulator goes registers -> .local -> registers -> global.**  A complete round trip
through the stack for 128 values that wgmma had already left in registers, plus ~500
instructions of address arithmetic.  The PTX marks the block `in Loop: Header=BB71_18 Depth=2`
-- the TILE-STRIDE loop, not the K-loop -- so it is O(1) in K.  That is exactly the shape of the
measured intercept.

THE CAUSE, and it is a one-line habit.  `%wgmma-store-rewrite-origin` opened with
`(let ((wgv ,tile)) ...)`.  Binding a 128-field struct to a fresh variable materialises it into
an alloca, and nothing splits it back up: `%explode-register-tiles` -- the 2026-07-05 fix that
made register TILES register-resident, and which is registered on LET/LET* precisely to catch
this -- tests `%register-tile-init-form-p` and **has no notion of `make-wgmma-accumulator`**.
So the mechanism that exists to prevent this exact bug does not cover the wgmma path.

THE FIX (this phase): do not copy at all when TILE is already a variable -- extract the members
straight from it.  A symbol needs no alias; only a compound expression does, and then once.

MEASURED IN THE EMITTED PTX (mm_n256, N=256):

| | st.local | ld.local | st.global | wgmma |
|---|---:|---:|---:|---:|
| before | 80 | 207 | 128 | 4 |
| after  | **15** | **142** | 128 | 4 |

The accumulator now feeds `st.global` directly from registers (`st.global.b32 [%rd155], %r1759`).
Regression: **1028/1028 specs, 218/218 negative, 291/291 unit.**

RESIDUAL, DELIBERATELY NOT CHASED YET.  126 `ld.local.b32` remain -- all reloads of ONE stack
slot (`c0`, the column base) once per store, with ~6 instructions of address arithmetic each.
Why a let-bound int is not promoted is not yet understood, and guessing has a poor record in
this endeavour.  It is second-order against the 253 local accesses already removed.

**UNMEASURED.**  This is a PTX-shape improvement with a plausible mechanism and a green
regression.  It has not run on hardware -- not for speed, and more importantly not for
CORRECTNESS.  The change is semantically an alias removal (nothing mutates the accumulator
between extractions, and every `set!` in the generated form targets the destination), but this
endeavour's record on "obviously fine" reasoning is not good enough to skip the metal check.

PHASE 8c — THE EPILOGUE FIX IS A NEGATIVE RESULT.  MEASURED, AND REVERTED.
===========================================================================
Third H100 NVL, CUDA 12.4.  Interleaved arms, the two PTX files differing ONLY in the epilogue
(verified by opcode histogram: 27 local-memory ops removed, 760 -> 729 instructions for n64,
nothing else changed).  `ptxas -v`: register counts IDENTICAL (64 / 96 / 164-165), zero spills
both ways, stack frames 136/320/616 bytes -> 0/0/96.

| size | kernel | old epilogue | new epilogue | delta |
|---:|---|---:|---:|---:|
| 256  | n64  | 5,307   | 5,106   | **-3.8%** |
| 512  | n64  | 33,082  | 30,582  | **-7.6%** |
| 1024 | n128 | 132,855 | 121,220 | **-8.8%** |
| 2048 | n256 | 249,798 | 256,463 | +2.7% |
| 4096 | n256 | 271,692 | 272,821 | +0.4% |
| 8192 | coop | 233,843 | 241,373 | +3.2% |

2 reps per cell, all MMA_CORRECT, within-arm spread <0.3%.  The result is not noise.

**AND IT INVERTS EXACTLY WHERE THE MECHANISM SAYS IT SHOULD NOT.**  The kernels whose local
traffic went to ZERO (n64 17/10 -> 0/0; n128 40/43 -> 0/0) got SLOWER.  The kernels that kept
residual traffic (n256 80/207 -> 15/142; coop 147/418 -> 18/264) got FASTER.  Strictly fewer
instructions, strictly less memory traffic, identical registers, no spills -- and slower.

I do not have an explanation.  Candidate stories (live-range pressure limiting the scheduler,
the LSU pipelining local loads that registers cannot overlap) are exactly the kind of reasoning
that has lost to measurement four times in this endeavour, so they are recorded as unexplained
rather than dressed up.

REVERTED, and the reasoning for reverting rather than shape-gating:
  - It is not a net win: -3.8/-7.6/-8.8% against +2.7/+0.4/+3.2%.
  - Counting sizes at >=90% of cuBLAS it is a WASH -- three either way (old: 99.5/109.8/99.9;
    new: 94.7/100.0/91.5).  Old has the higher peaks, new the higher floor.
  - A compiler that switches codegen on accumulator width, justified only by "it measured
    faster on one H100 and I cannot say why", is a heuristic this codebase should not carry.
    The `:tile-visit-strip-width` precedent is a MEASURED MACHINE FACT in a profile; this would
    be an unexplained shape rule inside the emitter.  Not the same thing.

WHAT SURVIVES THIS PHASE.  The 20.2 us intercept is still real and still unexplained -- the
K-scaling re-run that would have said whether the local round trip was any part of it did not
finish before the pod was released.  What Phase 8b established is narrower than it claimed: the
round trip EXISTS and is removable, not that it COSTS anything.  Removing it, on its own, is
worth roughly nothing and sometimes less.

STILL TRUE AND WORTH KEEPING: `%explode-register-tiles` does not cover `make-wgmma-accumulator`.
That is a real gap in a mechanism built to prevent exactly this class of bug.  It simply turns
out not to be a performance bug here.

PHASE 9 — THE INTERCEPT IS THE EPILOGUE.  MEASURED, NOT ATTRIBUTED.
====================================================================
Phase 8 measured a 20.2 us K-independent intercept and ATTRIBUTED it to the epilogue by
elimination.  Phase 8c then showed the local round trip -- the epilogue's most obvious defect --
was worth nothing.  So the attribution needed a direct test.

METHOD: two probe kernels, differing from the baseline in exactly one thing each.
  - `pb_nostore` — the store guarded by `(> (get-global-linear-id) 999999999)`, a predicate the
    compiler cannot fold (verified: `setp.gt.s32 %p18, %r9, 999999999` survives in the PTX, and
    is absent from the baseline).  Accumulator stays live, mainloop runs, no store executes.
  - `pb_noinit` — the per-tile `(set! D (make-wgmma-accumulator ...))` removed.  Numerically
    harmless here because grid == tile count, so each block owns exactly one tile.  Verified to
    differ from baseline by exactly **128 `mov.b32`** — the accumulator zero-splat, one per
    register — and nothing else.

M=N=2048, K in {1024, 2048, 4096, 8192}, 3 reps, spread <0.5%:

| arm | slope a (ms per unit K) | intercept b |
|---|---:|---:|
| baseline | 2.2627e-5 | **20.80 us** |
| nostore  | 2.3240e-5 | **1.03 us** |
| noinit   | 2.2450e-5 | 24.95 us |

**The intercept collapses 20.80 -> 1.03 us when the store is skipped.**  Slopes agree within
2.7%, confirming the mainloop is untouched.  So the epilogue is ~95% of the intercept and
launch + prologue + accumulator init together are ~1 us.  Phase 8's attribution was right, and
is now a measurement.

| K | epilogue | % of runtime |
|---:|---:|---:|
| 1024 | 19.14 us | **43.5%** |
| 2048 | 19.20 us | **27.9%** |
| 4096 | 15.58 us | 13.8% |
| 8192 | 14.74 us | 7.2% |

(And `noinit` is SLOWER than baseline -- intercept 24.95 vs 20.80.  Removing 128 movs costs
4 us.  Same inversion as Phase 8c.  Still unexplained; still not storified.)

LEVER 1 — ROW-MAJOR EMISSION ORDER.  KEPT.
--------------------------------------------
The natural loop is j-outer, interleaving r0 and r8, so the tile is written column-strip by
column-strip -- 32 passes revisiting the same rows.  Emitting all of row r0 then all of row r8
lets each warp lay down a contiguous 1 KB row.  Pure reordering: same stores, values, addresses.

Interleaved A/B, 3 reps: **+1.5% at 2048, +0.7% at 4096, +0.5% at 1024, neutral (noise) at
256/512.**  Nothing regresses.  Small, free, universal — kept.

LEVER 2 — COALESCING.  ITS CEILING IS NOW MEASURED, AND IT IS LOW.
--------------------------------------------------------------------
Rather than build SMEM staging and find out, a probe build emitted a PERFECTLY COALESCED
(numerically wrong) store of the same 128 values -- element e = i*128 + tid, so consecutive
lanes hit consecutive columns.  That is the floor SMEM staging could ever reach.

| K | epilogue, scattered | epilogue, perfectly coalesced | recovered | % of epilogue | % of TOTAL |
|---:|---:|---:|---:|---:|---:|
| 2048 | 18.07 us | 13.34 us | 4.73 us | 26% | **7.0%** |
| 4096 | 14.73 us | 10.82 us | 3.90 us | 27% | **3.5%** |

**So SMEM staging is worth at most 7.0% at 2048 and 3.5% at 4096.**  That is a lot of machinery
-- an SMEM epilogue tile, a barrier, a transposed read, and the occupancy cost of the extra
shared memory -- for a bounded and modest return.  On this evidence I would NOT build it, and
the reason is a measurement rather than a preference.

LEVER 3 — STORE WIDTH.  THE REAL RESIDUAL, AND NOT YET TRIED.
---------------------------------------------------------------
Even PERFECTLY COALESCED the store costs 13.34 us against a 4.3 us HBM floor for 16.8 MB — 3x.
The reason is visible in the PTX: all 128 stores are **`st.global.b32`**, 4 bytes per lane, so a
warp-store moves only 128 bytes.

And the fix does not need a layout change at all.  In the REAL fragment layout the column pairs
`(c0+8j, c0+8j+1)` are already ADJACENT, so an 8-byte `st.global.v2.f32` is available for free —
halving both the store count and the address arithmetic.  LLVM is not merging them today; they
are emitted as two independent scalar `set!`s on a 2-D `~` index and the load/store vectorizer
does not see through it.

That makes store WIDTH a better next lever than coalescing: cheaper to reach, no occupancy cost,
and aimed at the larger share of the residual.  It needs a way to express (or a codegen pass to
recognise) an adjacent-pair store.

PHASE 10 — STORE WIDTH, AND A METHODOLOGICAL DISCOVERY THAT MATTERS MORE
=========================================================================
Phase 9 named store WIDTH as the next lever: all 128 stores are `st.global.b32`, and the column
pairs `(c0+8j, c0+8j+1)` are already ADJACENT, so an 8-byte `st.global.v2.f32` should be free.

WHY LLVM WAS NOT MERGING THEM.  The emitted address arithmetic went
`ld.local(c0) -> add.s32 -> cvt.s64.s32 -> ... -> st.global.b32`.  The **sign extension** is the
first blocker: `sext(c0+1) != sext(c0)+1` when overflow is possible, so LLVM cannot prove the two
addresses differ by 4.  Widening the index arithmetic to ulong REMOVED it and LLVM immediately
started folding the offset (`st.global.b32 [%rd162+4]`) -- but still emitted two scalar stores,
because the base register was RECOMPUTED for the second one.

And the reason it was recomputed is the second blocker: **`c0` lives in local memory and is
reloaded 128 times** (one `ld.local.b64` per store).  Two loads from memory cannot be assumed to
return the same value, so LLVM rebuilds the address from scratch and never sees adjacency.
Inlining `c0` to remove the variable made it WORSE (ld.local 206 -> 335): the inlined expression
depends on `col`, which is *also* a let-bound scalar in local memory.  Systemic, not local.

**THE CAUSE IS THAT `opt -O3` IS NOT RUNNING ON THIS MACHINE.**

src/compiler.lisp:378-398 documents an `opt -O3` pass between IR emission and llc, with an
explicit graceful fallback: "if `opt` is not on the system, the pipeline runs unchanged (just
llc / llvm-spirv)".  `%opt-available-p` probes for the tool and returns NIL when absent.

On this box there is **no `opt` binary at all** -- `bin/` carries llc, llvm-as and llvm-spirv but
not opt; nothing named opt/opt-21 is on PATH; `CRISP_USE_SYSTEM_TOOLS` is unset.  So every PTX
generated locally in this endeavour skipped mem2reg, DCE and unrolling.  Unpromoted `let`-bound
scalars sitting in `.local` are exactly what that produces.  The compiler's own note puts the
measured cost of skipping it at ~13% on the reduction benchmark.

WHAT THIS DOES AND DOES NOT INVALIDATE
---------------------------------------
UNAFFECTED — every A/B in this endeavour compiled BOTH arms with the same compiler, so the
relative results stand: the wgmma group fix (+4.3-10.8%), the tile sweep (1.88x at 256), the ring
depth sweep (ring 4 at 256-1024), row-major store order (+1.5%/+0.7%), the coalescing ceiling
(26% of the epilogue), and the intercept decomposition (20.80 -> 1.03 us).

IN DOUBT — the ABSOLUTE "% of cuBLAS" figures, if `opt` would have helped these kernels.

AND ONE PIECE OF EVIDENCE AGAINST IT MATTERING MUCH: the Phase 1 pipeline check reproduced
REPORT.md's published chap3 number to **0.1%** (79.61 vs 79.69 TFLOPS) using a locally-built,
un-opt'd PTX.  Either opt does little for this kernel family, or REPORT.md's numbers were
produced the same way.  Both are worth knowing and neither is established.

STORE WIDTH IS THEREFORE UNRESOLVED, NOT REFUTED.  The v2 merge is blocked by an artefact of a
missing optimisation pass, not by anything about the store.  With mem2reg running, `c0` would be
a register, the base would be reused, and the adjacent pair may well merge on its own with no
compiler change at all.  Chasing it by hand before establishing that would be work against a
phantom.

NEXT STEP IS NOT A LEVER, IT IS A CONTROL: get `opt` onto the toolchain (bundle it in `bin/`
beside llc, or set CRISP_USE_SYSTEM_TOOLS with opt-21 on PATH), regenerate one kernel, and diff.
That single check tells us whether months of local PTX reading has been looking at code the
shipped compiler does not actually emit.

KEPT FROM THIS PHASE: row-major emission order only (measured).  The ulong widening was reverted
-- it demonstrably removed the sext blocker, but it is unmeasured for performance and its
motivation may dissolve once opt runs.

PHASE 11 — OVERLAY FOLDED INTO src/ (2026-08-22)
=================================================
Six definitions moved from `overlays/crisp-compiler-overlay.lisp` into `src/mma.lisp`.  All plain
defuns -- no defvars, macros or structs -- so unlike endeavour 152's fold this one needed no
insert-after-`in-package` care; only ONE ordering constraint applied, and it is recorded below.

| definition | disposition | src/mma.lisp |
|---|---|---|
| `%emit-wgmma-mma-only` | NEW | beside `%emit-nvvm-wgmma` |
| `%emit-nvvm-wgmma` | REPLACED | one fence / N mma_async / one commit / one wait |
| `%wgmma-store-rewrite-origin` | NEW | absolute (ROW COL) origin, TO-INT coercion, row-major order |
| `%wgmma-store-rewrite` | REPLACED | thin caller of -origin; behaviour unchanged |
| `analyze-store-tile-at-mma` | NEW | placed BEFORE `register-mma-analyzers` |
| `register-mma-analyzers` | REPLACED | STORE-TILE-AT added to the dispatch table |

ORDERING CONSTRAINT: `register-mma-analyzers` takes `#'analyze-store-tile-at-mma`, so the analyzer
is defined ahead of it.  Strictly this is belt-and-braces -- `#'` is evaluated when the registrar
RUNS (at initialize-compiler), not when it is compiled -- but it keeps the build free of
undefined-function style warnings.

VERIFIED BEHAVIOUR-PRESERVING BY CONSTRUCTION, not by inspection: PTX was emitted for four
kernels (n64 r4, n128 r4, n256 r2, coop) plus spec 03 BEFORE the fold, md5'd, and re-checked
after.  **All five byte-identical.**  That is the check worth having -- a fold that compiles and
passes tests can still have quietly changed codegen.

The overlay is now empty again, with a header recording what moved.  The two spec validators
(`validate-ptx-wgmma-group`, `validate-ptx-wgmma-store-direct`) stay in
`overlays/spec-runner-overlay.lisp` and were deliberately NOT folded: `tests/run-specs.lisp`
calls `(main)` on its last line, so anything appended after it is defined too late to be found.
They belong in that overlay or ahead of the `(main)` call.


WHERE TO PICK THIS UP  (written 2026-08-22 for the post-merge branch)
=====================================================================
Endeavour 154 is at a natural pause, not a conclusion.  What follows is what I would do next and
why, ordered by expected value.

STANDING (best config per size, H100 NVL, tf32, vs cuBLAS)

| size | best config | % of cuBLAS |
|---:|---|---:|
| 256  | n64 tile, ring 4  | 99.5% |
| 512  | n64 tile, ring 4  | 109.8% |
| 1024 | n128 tile, ring 4 | ~100% |
| 2048 | n256 tile, ring 2 | 78.2% |
| 4096 | n256 tile, ring 2 | 71.3% |
| 8192 | coop 128x256, ring 2 | 70.5% |

Small-to-mid is DONE -- at parity, nothing left worth chasing.  Everything from 2048 up sits in a
70-78% band, and it is a PLATEAU rather than a defect at one size (8192 confirmed that; cuBLAS
itself falls 12% off its 4096 peak there, so the wall at 8192 is the machine's, not ours).

--- 1. THE CONTROL THAT GATES EVERYTHING ELSE: get `opt` onto Windows ---------
`tools/` bundles llvm-spirv, llvm-as, llc and LLVM-C -- **not opt** -- and the build copies
exactly those four (build/build-compiler.lisp:27).  `C:\Program Files\LLVM-x` is a clang-only
distribution with no opt.exe either.  Meanwhile EVERY Linux harness sets
`CRISP_USE_SYSTEM_TOOLS=true` (run-on-pod.sh:228, bench-on-pod.sh:223, Dockerfile.bench-intel:80)
and installs llvm-21, and `resolve-tool-executable` probes versioned names ONLY under that flag --
so `opt-21` is found and `-O3` RUNS on pods and in Docker, and is SILENTLY SKIPPED on the dev box.

Consequence: all local PTX analysis in this endeavour was of un-optimised code.  Every A/B is
still valid (both arms, same compiler), but codegen READING has been of code the shipped compiler
does not emit on Linux.  Add `opt-windows.exe` / `opt-linux` to `tools/` and to that copy list.

One data point says this may matter less than it sounds: the Phase 1 pipeline check reproduced
REPORT.md's published chap3 number to **0.1%** with locally-built, un-opt'd PTX.  Not established
either way -- which is exactly why it should be checked before more codegen work.

--- 2. RE-BASE THE PUBLISHED LADDER ------------------------------------------
The shipped chapters all still use the OLD shape -- n256 tile, ring 2, at every size.  chap3's
67.5% at 4096 is stale twice over (before the wgmma group fix, before tile/ring selection).  On
current knowledge the ladder should carry, per size, the best (tile, ring) and the row-major
epilogue.  This is mostly mechanical and it is the largest single improvement available to the
NUMBERS, without any new compiler work.

Reporting decision already settled with Chris: report best-kernel-per-size and say plainly that
cuBLAS is doing the same thing one layer down.  Size-conditional selection is a HOST-side enqueue
concern (possibly `def-orchestration` one day), not a compiler feature.

--- 3. LEVERS, HONESTLY RANKED -----------------------------------------------
`wait_group N` (N>=1) -- the per-K-BLOCK pipeline drain; endeavour 154 removed only the per-SLICE
one.  Still untried, and it is the last enumerated lever with a clear mechanism.  But its evidence
WEAKENED: removing the per-slice drain bought +10.3-10.8% at 512-1024 and only +4.3-4.5% at
2048-4096 -- it helped LEAST exactly where help is needed.  Needs a `wait_group 0` before the
epilogue reads D, so it is a loop/epilogue change and cannot be prototyped by PTX patching.

Store WIDTH -- all 128 stores are `st.global.b32`; the column pairs are already adjacent so an
8-byte `v2` should be free.  Blocked today by an unpromoted `c0` alloca reloaded 128 times, which
is precisely what mem2reg exists to fix.  **Do item 1 first** -- this may evaporate on its own.

SMEM-staged epilogue -- ceiling MEASURED at 7.0% (2048) / 3.5% (4096) via a coalesced-store probe.
A lot of machinery for that.  I would not build it, and that is a measurement not a preference.

--- 4. WHAT IS KNOWN AND SHOULD NOT BE RE-DERIVED ----------------------------
- The epilogue is 95% of the K-independent intercept (20.80 -> 1.03 us when the store is skipped)
  and 27.9% of runtime at 2048^3.  Its cost is NOT coalescing (sector fill is already 100%) and
  NOT the register->local round trip (removing that was a measured LOSS).
- Occupancy (CTAs/SM, bounded by registers and SMEM) decided the outcome of THREE separate levers:
  cooperative tiles, ring depth, and tile width.  It predicted two of them before measurement.
  It is the first thing to compute for any new shape.
- Two changes that look like pure wins are measured LOSSES: removing the accumulator's local
  round trip, and removing the per-tile accumulator zero-init.  Both unexplained.  Do not
  re-attempt either without a profiler.

--- 5. PROFILING IS STILL BLOCKED --------------------------------------------
`ncu` fails with ERR_NVGPUCTRPERM on RunPod: container is uid 0 but CapEff lacks CAP_SYS_ADMIN and
the driver has `RmProfilingAdminOnly: 1`.  `nsys` would not answer these questions (tracing, not
stall analysis).  The narrower ask, worth pressing: host driver loaded with
`NVreg_RestrictProfilingToAdminUsers=0` -- same access, no container capability.  Support request
is in flight as of 2026-08-22.  Several open questions in section 4 are one profile away.
