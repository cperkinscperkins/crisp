Endeavor 144 — Findings
=======================

Written to be useful to someone who is *not* us: a GPU-library engineer, an oneMKL or CUTLASS
person, or ourselves in six months.  Each finding states what we measured, on what, and what we
think it means — including the ones where our theory was wrong.

Hardware: Intel Arc B580 (Battlemage / Xe2, 20 Xe-cores, 18 MB L2, SIMD16) and NVIDIA H100 PCIe
(114 SMs, 50 MB L2, 227 KB opt-in SMEM).  Workload: square tf32 GEMM, `fast` precision.  All
performance figures are median kernel time over ≥30 launches with a host-reference correctness
check (`MMA_CORRECT`) on the same run.


1. Tile visit order is worth ~60% once the working set leaves L2
---------------------------------------------------------------

**The measurement** (B580, register-ring + 2D-block-prefetch matmul, 32×32 output tile):

| Size | A+B+C working set | linear tile order | grouped, strip W=4 | |
|---|---|---:|---:|---|
| 1024 | 12.6 MB — **fits** the 18 MB L2 | 23.63 TFLOPS | 23.18 | −1.9% |
| 2048 | 50 MB — **exceeds** L2 | **17.16** | **27.96** | **+63%** |

**Read it vertically.**  Under linear order the kernel gets *slower* going from 1024 to 2048
(23.6 → 17.2) even though a larger GEMM has strictly better arithmetic intensity.  That is a
**cliff**, not a gradual falloff: it is the point where consecutively-scheduled workgroups stop
finding A and B rows in L2.  Grouping the walk into column strips restores monotone scaling
(23.2 → 28.0).

Why linear order is bad specifically: with an exact tile cover, workgroup *i* takes tile *i* in
row-major order, so the workgroups resident at any instant span one **row-band** of C.  They
share an A row-block but between them stream the *entire* B matrix.  A W-wide strip makes the
resident set a compact `W × (R/W)` neighbourhood instead, so both operands get re-read from
cache.  This is the same effect CUTLASS gets from `ThreadblockSwizzle`; what we can add is the
size at which it bites on Battlemage, and how sharp it is.

**For anyone tuning a GEMM on Xe2:** the crossover sits between 1024 and 2048 for fp32 operands
on an 18 MB L2, exactly where `3·N²·4 bytes` crosses the cache size.  Below it, grouping costs
~2% (pure index arithmetic, no reuse to win).  Above it, not grouping costs ~40% of achievable
throughput.

### …but this does NOT generalize, and "working set > L2" is not the mechanism

We tested the same change on an H100 PCIe (114 SMs, 50 MB L2) expecting a bigger version of the
same cliff at 4096 (200 MB = 4× L2).  **It never appears.**  Linear order keeps scaling cleanly —
one chapter goes 36.95 TFLOPS at 2048 → 59.60 at 4096, another reaches 207.41 — and grouping is
neutral to actively harmful:

| H100 @4096 | linear | W=2 | W=4 | W=8 | W=16 |
|---|---:|---:|---:|---:|---:|
| TMA + tf32 MMA, 64×64 tile | 59.60 | 59.34 | 59.26 | **60.01** | 59.32 |
| pipelined, 64×64 tile | **55.83** | 54.95 | 55.38 | 54.73 | 54.94 |
| warpgroup MMA, 64×256 tile | **207.41** | 208.34 | 190.22 | 184.76 | 177.64 |

The last row degrades **monotonically** with strip width — −14.4% at W=16 — which is a real
effect, not scatter.  Its likely mechanism: with a 64×**256** tile, a W-wide strip spans 256·W
columns, so at W=16 the "strip" is 4096 columns wide — the entire matrix.  The grouping
degenerates and contributes only arithmetic while discarding the locality linear order already
had.  Wide tiles want narrow strips.

We pushed further to test the obvious objection — *maybe the bigger machine just cliffs later.*
At **8192** the working set is 800 MB = **16× the H100's L2**, versus the mere 2.8× at which the
B580 fell off.  Still no cliff: linear scaling is monotone (one chapter 36.95 → 59.60 → 63.77
TFLOPS, another 124.83 → 207.64 → **230.18**) and merely *flattens*, which is the signature of
approaching a roofline rather than falling out of cache.

But the 8192 data adds a real qualification.  The two chapters diverge by **tile shape**:

| @8192 | linear | grouped W=4 | |
|---|---:|---:|---|
| 64×64 tile | 63.77 | **65.70** | **+3.0%** (was −0.6% at 4096) |
| 64×256 tile | **230.18** | 190.17 | **−17.4%** (was −8.3% at 4096) |

For the square tile, grouping *does* start to pay as size grows — asymptotically, not as a
cliff.  For the wide tile it gets steadily worse.  Both follow if the useful strip width scales
**inversely with tile width**: a W-wide strip spans `tile_N × W` columns, so a wide tile
saturates the matrix and the grouping degenerates into pure index arithmetic.

**So the honest version of this finding is:** tile rasterization was worth +63% on one device and
−17% on another, it depends on tile shape as well as machine, and we cannot currently predict
which from any machine property we have.  L2 size
does not predict it (both devices report one; outcomes are opposite).  Bandwidth-per-FLOP does not
separate them either (~456 GB/s / ~58 TFLOPS tf32 vs ~2000 / ~400 — similar ratios).  If you are
adding rasterization to a code generator, **measure it per target and per tile shape**; do not
infer it from cache size, and do not assume the CUTLASS-style win transfers to a
bandwidth-rich part or to a very wide output tile.

We ship it gated on an explicitly measured per-machine width rather than on a derived formula,
because a formula that is right on one of two devices is worse than an honest table.


2. The strip width barely matters.  Engaging at all is what matters
------------------------------------------------------------------

Sweep at 2048 on the B580:

| W | 1 (linear) | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| TFLOPS | 17.14 | 27.62 | 27.89 | 26.87 | 28.05 |

Grouped-vs-linear is worth ~60%.  The width *within* 2..16 is worth ~4%.  Any `W ≥ 2` captures
essentially the whole win.

**This contradicted our own theory, which is the interesting part.**  Minimizing the concurrent
footprint `(H·tile_M + W·tile_N)·K` subject to `H·W = R` (R = resident blocks) gives
`W = sqrt(R · tile_M / tile_N)`.  That algebra says the width is important and that you need an
occupancy model to pick it.  Measured, the width is nearly irrelevant and the occupancy model is
a refinement rather than a prerequisite.  We had sequenced an entire phase on the assumption that
it was a prerequisite; the measurement reordered the work.

Practical consequence: if you are adding rasterization to a code generator, **do not block on
getting W right**.  Ship any small constant ≥ 2 and tune later.

(W=8 sits in a reproducible local dip — 26.87 at 2048, and 22.44 vs W=4's 23.18 at 1024.  We
have no confident explanation; it reproduces across rebuilds.  Possibly an interaction with the
20 Xe-core count or the 2D-block-prefetch stride pattern.)


3. Intel's register-file mode is a first-order performance decision, and the default is wrong
   for a register-resident matmul
---------------------------------------------------------------------------------------------

IGC defaults to **128 GRF registers per thread**; `-ze-opt-large-register-file` asks for **256**,
at the cost of halving threads-per-EU (8 → 4 on Xe2).

Our register-resident matmul (a 32×32 accumulator plus 2-deep A/B register rings, one SIMD16
subgroup) demands, per thread:

```
C 32×32 = 1024 elements + A-ring 2×(32×8) = 512 + B-ring 2×(8×32) = 512  =  2048 elements
2048 × 4 B / 32 B per GRF register                                       =  256 registers
```

Exactly 2× the default allocation.  IGC's response was to **spill** rather than to use the
larger file, and the spill was invisible from the source:

| Kernel | spillMemSize, default GRF | with large GRF |
|---|---:|---:|
| register-ring + prefetch | 1792 B | **0** |
| synchronous SLM-staged | 2560 B | **0** |
| async OpGroupAsyncCopy staged | 2752 B | **0** |

Fixing it on the register-resident kernel (same SPIR-V, only `ze_module_desc_t.pBuildFlags`
differing):

| Size | default GRF | large GRF | |
|---|---:|---:|---|
| 256 | 2.52 TFLOPS | 4.08 | 1.62× |
| 512 | 9.06 | 14.03 | 1.55× |
| 1024 | 11.61 | 23.33 | **2.01×** |

**But large GRF is emphatically not a global win.** Forced onto the two SLM-staged kernels — which
spill *more* — it made them slower:

| Kernel @1024 | default GRF | large GRF forced | |
|---|---:|---:|---|
| synchronous SLM-staged | 1.66 TFLOPS | 1.03 | **−38%** |
| async staged | 0.95 | 0.85 | −11% |

Those two are occupancy-bound (many threads, SLM staging), not register-bound, so halving
threads-per-EU costs more than the spill did.  A blanket `-ze-opt-large-register-file` would have
regressed the first by 38%.

**The generalizable lesson:** the register-file mode must be chosen per kernel from its actual
register demand, and "it spills" is *not* sufficient evidence to widen the file.  Both of our
SLM-staged kernels spill and both are hurt by the larger allocation.  Anyone exposing this knob —
a compiler, a library's kernel selector, a tuning harness — needs a demand model, not a spill
detector.

Also worth knowing: **the spill was silently costing occupancy twice over.**  Level Zero
launchers commonly derate the grid when `spillMemSize > 0`; ours halved it.  So a spilling
kernel paid both the spill traffic and a 2× smaller grid, and the only visible symptom was a
suspiciously round occupancy number.


4. `sqrt(L2 / tile_bytes)` is a bad proxy for anything
-----------------------------------------------------

Our first (unshipped) width heuristic was `clamp(sqrt(L2 / tile_bytes))`.  On both targets it
saturates the clamp: B580 gives `sqrt(18 MB / 4 KB) = 67`; H100 gives `sqrt(50 MB / 16 KB) = 56`.
A formula that always returns "the clamp" is a constant wearing a costume.  If you find yourself
writing a cache-capacity heuristic, check whether it saturates on every device you care about
before believing it is derived from anything.


5. Two measurement traps that produced convincing wrong answers
---------------------------------------------------------------

Both of these generated *plausible, publishable-looking* results.  We record them because the
failure modes are generic.

**(a) A stale artifact impersonating a negative result.**  Our first rasterization sweep showed
~27 TFLOPS for every setting *including linear* — a clean "this optimization does nothing."  In
fact the compiler resolves a DLL path relative to the working directory, so every compile issued
from the wrong directory died instantly, and we benchmarked one leftover binary five times with
stderr discarded.  What exposed it: the output artifacts were **byte-identical across settings**,
which different code cannot produce.  Hash your artifacts against a known-different control, and
never discard a compiler's exit status in a measurement loop.

**(b) A batched-submit loop inflating throughput by exactly the iteration count.**  An earlier
Level Zero harness re-submitted an already-in-flight command list; the runtime coalesced the
submissions, so reported GFLOPS were high by precisely `iters`.  A correctness check cannot catch
this — the results are right, only the timing is wrong.  If a number is off by exactly your loop
count, suspect the loop, not the kernel.  (Both traps flatter you, which is why they survive.)


5c. A third trap: comparing two different amounts of work
---------------------------------------------------------

Our compile-time table reported the competing toolchains as "4-8.5x slower than Crisp".  It was
measuring **Crisp source → IR** against **competitor source → linked executable** — the vendor
timings included host-side C++ compilation and linking (`-lcublas`, `-qmkl`), work Crisp never
does at that stage.  Worse, most Crisp rows excluded the runtime JIT of the IR as well, so the
comparison omitted device codegen on one side and included host codegen on the other.

The fix is one flag per toolchain — `nvcc -ptx`, `icpx -fsycl -fsycl-device-only` — timed
against `crisp-compile --ir-target=…`.

Two things generalise:

- **A performance claim should name both endpoints.**  "Compile time" is not a quantity; "source
  to device IR" is.  The original column header named neither, which is exactly how the
  asymmetry survived several readings, including ours.
- **Library ceilings cannot participate in a compile-time comparison at all.**  cuBLAS and
  oneMKL kernels ship precompiled inside the library, so a device-only compile of the *caller*
  measures nothing.  Including them was unfair to the libraries under the old scheme and would
  have been absurdly flattering to them under the new one.  They are now excluded, with the
  reason stated in the report itself.

This was found by asking "what exactly is on each side of this ratio?" — the same question that
exposed traps 5(a) and 5(b).  It is worth asking of every number you intend to publish.


6. Vendor-library context, offered carefully
--------------------------------------------

On the B580 our best kernel reaches 23.7 TFLOPS at 1024 against oneMKL's 11.97 in the same
harness at the same precision — nominally ~198%.  We do **not** read that as "2× better than
Intel's library on the merits," and we would discourage anyone from quoting it that way.

Context that matters: 23.7 TFLOPS is roughly 40% of the B580's tf32 peak, which is a good but
unremarkable GEMM.  oneMKL landing at ~20% of peak is *low* for a vendor library, and the most
likely explanation is simply that Battlemage is new consumer silicon and its tf32 GEMM path is
not yet tuned there.  The honest claim is "an untuned vendor path on new hardware," not a
fundamental gap — and if the oneMKL team reads this, findings 1 and 3 are probably the two most
actionable items above, since both are configuration-level rather than algorithmic.


7. "Maximize the resource that fits" is the wrong default, three times over
---------------------------------------------------------------------------

Three separate decisions in this endeavor had the same shape — *a resource is available; should
the compiler take as much as fits?* — and the honest answer was different each time:

| Decision | "Take the max" would have | Measured reality |
|---|---|---|
| Register file mode (Intel GRF) | always request 256 GRF | **2.01x win** on a register-resident kernel, **-38%** on an occupancy-bound one |
| Tile visit strip width | pick the widest that fits L2 | +63% on one device, **-14%** on another; width itself worth only ~4% |
| Pipeline ring depth | deepest ring that fits SLM | prior work measured a crossover: +7-9% throughput for **-6% occupancy**, sign flipping with problem size |

The pattern: every one of these trades a resource the kernel *wants* against a resource
(concurrency) that the kernel *also* wants, and which side wins depends on whether the kernel is
latency-bound or throughput-bound — which a compiler cannot infer from a shape.

So the design rule we ended on: **the compiler computes and reports; a measured per-machine
constant decides.**  Two of the three consumers ended up gated on an explicitly measured profile
value rather than a derived formula, and the third (ring depth) ships as a report rather than an
optimizer.  That is less satisfying than a model, and it is what the measurements support.

Corollary worth stating separately, because it is the one that surprised us most: **"the kernel
spills" is not sufficient evidence to give it more registers.**  Two of our three Intel kernels
spill *and* are made slower by a larger register file.  A spill detector is not a demand model.


8. What we would tell someone starting this work
------------------------------------------------

- **Measure the mechanism, not just the outcome.**  Diffing generated artifacts with and without
  a change caught two separate cases where an optimization provably could not matter, saving an
  expensive benchmark run each time.
- **Theory sequences work; measurement re-sequences it.**  Our width algebra was correct and
  nearly useless.  Build the mechanism, put the tunable behind one function, then measure.
- **Prefer "does it engage?" telemetry over inference.**  One log line stating the decision the
  compiler made would have caught trap 5(a) immediately.
- Correctness checks do not validate timing, and timing does not validate correctness.  We have
  now been bitten by each independently.


Reproducing
-----------

The probe tools are small and self-contained:

- `put_temp_files_here/hw-profile-query/query.cpp` — Level Zero device properties → a
  hardware-profile form.
- `put_temp_files_here/hw-profile-query/query_cuda.cu` — the CUDA twin.
- `put_temp_files_here/hw-profile-query/kernel-probe.cpp` — loads a `.spv` and reports
  `spillMemSize` / SLM / private memory **under each register-file mode**.  This is the oracle for
  finding 3.

Visit-order A/B is `CRISP_TILE_VISIT=linear|grouped|grouped:N` at compile time.
Register-file A/B is `ze_module_desc_t.pBuildFlags = "-ze-opt-large-register-file"` at module
build time — no recompile needed, which makes it a cheap experiment on any existing SPIR-V.
