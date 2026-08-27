# Roofline probe — is the shipped fp16 matmul bound by its loads or by its math?

**This directory is a diagnostic, not a benchmark chapter.** It has no contenders, produces no
report row, and two of its three kernels are numerically wrong on purpose.

## The question

The shipped `sec2_top_fp16` kernel is flat from N=1024 upward — 63.1 / 57.9 / 64.9 / 66.1 TFLOPS
across a 512x increase in work, against SYCL-TLA's 24.3 / 86.4 / 188.9 / 239.9, which climbs. A
ceiling that does not move with problem size is not occupancy and is not HBM bandwidth. Two live
theories, which prescribe different endeavours:

- **Issue-bound.** We emit ~57 machine instructions per `dpas` against a budget of roughly 7
  (270 TFLOPS peak / 20 Xe-cores / ~2.85 GHz => ~1.16 dpas per cycle per Xe-core, against 8 XVE
  issue slots). If so, only shrinking the instruction stream moves the number, and prefetch —
  which *adds* instructions — is close to neutral.
- **Latency / cache-bound.** The loads stall and the math waits. If so, prefetch depth and
  explicit cache-level control are the endeavour, and instruction count is close to neutral.

Both theories fit some of the existing evidence, so the argument cannot be settled by re-reading
old numbers. It needs an experiment that separates the two halves of the loop.

## The three arms

All three are the **same kernel and the same geometry** as `sec2_top_fp16`: a 128x256 output tile
over 16 subgroups, `(8 16 16)` mma shape, K-step 32, `:coop-matrix` lowering. Exactly one thing
differs per arm.

| kernel | loads in the K loop | dpas in the K loop | what it is |
|---|---:|---:|---|
| `probe_full.crisp`  | 16 | 32 | the real kernel, unmodified |
| `probe_loads.crisp` | 16 |  0 | `mma-accumulate-via-tile` deleted |
| `probe_math.crisp`  |  0 | 32 | the two `load-tile`s hoisted out of the K loop |

Those counts are **verified in the emitted SPIR-V**, not assumed — see "Verification" below.

## How to read the result

Let `T_full`, `T_loads`, `T_math` be the measured times at one size.

| observation | conclusion | what to do next |
|---|---|---|
| `T_full ~= T_loads` | memory/latency-bound | prefetch depth + cache-level control is the endeavour |
| `T_full ~= T_math` | at peak for our instruction stream | only the lowering moves it (`:xe-native`, address payloads) |
| `T_full ~= T_loads + T_math` | **no overlap at all** — the fetch and the math are serialised | prefetch is the highest-value knob on the board |
| `T_full ~= max(...)`, both well under | neither half explains it | a third limiter; go looking before spending more |

## Integrity — why this is fenced off

`probe_loads` stores an all-zero C. `probe_math` computes K/32 copies of the k=0 slab. **Both are
exactly the "kernel that skips work and posts a great number" failure this benchmark suite has
been bitten by before** (`chap2_tiling` once posted the second-best number in its section while
storing nothing at all). So:

- the directory is **underscore-prefixed**, matching `_iso` / `_kdepth` — not a report chapter;
- `_skip()` in `matmul.py` means it runs **only** when named in `--chapters`, never in a sweep;
- it **must** be run with `--scratch`, so its JSON lands in `benchmarks/results/scratch/`, which
  `report.py` never reads into a canonical table;
- at `N <= VERIFY_MAX_N` (2048) the harness runs the host reference and **discards the two wrong
  arms** as NOT MMA_CORRECT. Include 2048 in the sizes deliberately: seeing `probe_full` verify
  there while the other two are dropped is the proof that the integrity gate still works and that
  the probes really are wrong.

Points at N >= 4096 are recorded with `verified: false`. That flag is the whole reason these
numbers may be used for a *comparison between the three arms* and for nothing else.

## Running

```
./scripts/bench-intel.sh 2048,4096,8192 100 fast _probe_roofline --scratch
```

Docker/Linux is the platform of record for Intel; the same kernel measures up to 29% differently
on Windows-native L0, in size-dependent directions. All three arms must be measured **in one
container run**, back to back — the same unchanged kernel has moved 15% between sessions.

## Verification

The load and dpas counts above are checked in the emitted SPIR-V before any timing is believed,
because both wrong arms have a failure mode that would silently void the experiment:

- `probe_loads` — with the math gone, nothing reads A-tile or B-tile, so the block reads could be
  dead-code-eliminated and the arm would measure an empty loop.
- `probe_math` — the loads must actually leave the K loop rather than being sunk back into it.

```
bin/crisp-compile.exe --ir-target=spv --hardware-profile=bmg --math-precision=fast \
    --log-level=off benchmarks/matmul/_probe_roofline/probe_<arm>.crisp
bin/llvm-spirv.exe --to-text probe_<arm>.spv -o probe_<arm>.spt
```

The SPIR-V is unstructured (Kernel capability, no `LoopMerge`), so loops are found by back-edge:
a `Branch`/`BranchConditional` whose target `Label` appears earlier in the module. Counting the
`CooperativeMatrix{Load,MulAdd}KHR` ops between a back-edge's target and the branch gives the
per-loop-body figures in the table above.

**Confirmed 2026-08-26**, `probe_full` innermost K loop: 16 `CooperativeMatrixLoadKHR`, 32
`CooperativeMatrixMulAddKHR`. That is exactly the geometry arithmetic — per subgroup, a 32x64
slice of the 128x256 tile is 4 M-fragments x 4 N-fragments x 2 native K-steps = 32 dpas, fed by
8 A + 8 B fragment loads. It is also, incidentally, the first direct confirmation that the
`:warps` split takes: if the 16-way subgroup distribution had silently not happened, this loop
would hold 512 dpas, not 32.

`probe_math` reports 43 loads *module-wide*, but they sit in two operand-fill loops that run once
per output tile — the K loop itself holds 32 dpas and zero loads. At N=4096 the K loop runs 128
times, so the fill preamble is amortised ~128x and does not contaminate the arm.

---

# RESULT — 2026-08-26, Arc B580, Docker/Linux, `fast`, iters=100

Median kernel time, all three arms in ONE container run, back to back.

| N | `T_full` | `T_loads` | `T_math` | loads/full | math/full | `T_full` vs perfect overlap |
|---:|---:|---:|---:|---:|---:|---:|
| 2048 | 299.6 us | 274.7 us | 199.5 us | **91.7%** | 66.6% | +9.1% |
| 4096 | 2120.8 us | 2018.1 us | 1294.6 us | **95.2%** | 61.0% | +5.1% |

**`T_full` ~= `T_loads`. The kernel is memory/latency-bound, not issue-bound.** Deleting all
32 dpas per K-iteration buys 5-8%. Deleting the loads buys 39%.

## Three findings, in order of how much they change the plan

**1. The loads are the critical path.** This was the outcome the table above calls
"memory/latency-bound => prefetch depth + cache-level control is the endeavour."

**2. But fetch and math are ALREADY almost perfectly overlapped.** `T_full` is only 5.1% above
`max(T_loads, T_math)` at 4096. So there is ~5% available from overlapping the fetch with the math
better, and no more. The win is NOT in hiding the loads behind the math -- that already happens.
The win is in making `T_loads` itself smaller. Prefetch still bears on this, but through
memory-level parallelism *among the loads*, not through load/math overlap.

**3. There is a second wall behind the first, and it is bigger.** `T_math` says that if operands
were free, this kernel would run at **106 TFLOPS at N=4096** -- against a measured 64.8 and a
hardware peak near 270. So:

```
   64.8 TF   measured
  106.2 TF   if the loads were free          (+64%  -- the memory wall)
 ~270   TF   hardware peak                   (+154% -- the instruction-stream wall)
```

Both walls are real and roughly comparable in size. The memory wall is the one that is
immediately actionable; the instruction-stream wall is the one that still separates us from
SYCL-TLA even after the first is fixed.

## What makes `T_loads` smaller

Not better overlap (worth 5%). One of:

- **Cache-level control.** `%block-prefetch` currently emits `Subgroup2DBlockPrefetchINTEL` with
  NO cache-control decoration -- we do not choose L1 vs L2, the driver default does. Nor do the
  `load-tile` block reads carry one. `SPV_INTEL_cache_controls` is the surface. Costs zero
  instructions, which is why it is worth trying first.
- **Fewer loads per dpas.** The K loop is 16 loads / 32 dpas = 0.5. A 64x128 per-subgroup tile
  would be 0.25 -- half the load traffic for identical math. Blocked by the open bigger-tile
  failures (`TN 128` at 0.14x, `TM 64` will not run, `TN 96` faults).
- **A cheaper load instruction.** `:xe-native` changes the load path, not just the dpas. Its
  "+21% bare" now reads as a load-path win, which is the half that matters.

## Caveats on these numbers

- **Neither wrong arm is verified** (`correct: false` at every size -- the L0 fixture runs its
  host reference at ALL sizes, not only below `VERIFY_MAX_N` as the autobench path does). The
  driver therefore recorded **no JSON points** for `Probe_Loads` / `Probe_Math`; their timings
  above were read from the run log. Only `Probe_Full` has JSON, and it verified at both sizes
  (57.34 / 64.81 TFLOPS -- matching the shipped kernel's 57.9 / 64.9, which is the cross-check
  that this probe is measuring the real geometry).
- **`probe_loads`' loads have no consumer**, so nothing forces them to complete. If that biases
  the number it biases it DOWNWARD, which makes "loads are 95% of the critical path" a lower
  bound and the conclusion stronger.
- **`probe_math` spills** (448 registers/thread requested against a 256 max, same as the shipped
  kernel). Its 106 TFLOPS ceiling therefore includes spill traffic and is itself a floor on what a
  spill-free instruction stream could reach.
- `probe_math` shows a small `max_abs_err` rather than a large one, because the fixture uses
  A=B=1.0 -- every K-slab is identical, so re-using the k=0 slab happens to compute nearly the
  right answer. Irrelevant to timing: the dpas count is unchanged.

---

# ROUND 2 — why is `T_loads` large?

Round 1 answered *which half* is the critical path (the loads, at 95%) and found fetch and math
already ~95% overlapped. So the remaining win has to come from shrinking `T_loads` itself, not
from overlapping it better. These arms ask which mechanism is responsible. Each is `probe_loads`
with exactly ONE change.

| arm | kernel | change | tests |
|---|---|---|---|
| **A** | `probe_loads_cc.crisp` | `CacheControlLoadINTEL` L1+L3 = `Cached` | are we missing cache the peer hits? |
| **B** | `probe_loads_pf2/pf3.crisp` | 24 block prefetches per K-step, 2 or 3 ahead | are we memory-level-parallelism starved? |
| **C** | `probe_loads_fixed.crisp` | loop-invariant load coordinate | **ceiling**: what's left if addressing *and* misses both vanish? |

Arm A's kernel source is **byte-identical** to `probe_loads` (verified with `diff` over the
non-comment lines); only its NAME differs, because the decoration is gated on the file stem via
`CRISP_CACHE_CONTROL_KERNELS`. Both arms therefore compile in the SAME session from the same
source, with one variable between them.

```
CRISP_CACHE_CONTROL=l1c_l3c CRISP_CACHE_CONTROL_KERNELS=probe_loads_cc \
  ./scripts/bench-intel.sh 2048,4096 100 fast _probe_roofline --scratch
```

## Static verification (all arms, before any timing)

| kernel | loads in K loop | dpas | prefetches in K loop | cache-control decorations |
|---|---:|---:|---:|---:|
| `probe_full` | 16 | 32 | 0 | 0 |
| `probe_loads` | 16 | 0 | 0 | **0** |
| `probe_loads_cc` | 16 | 0 | 0 | **32** (16 sites x 2 levels) |
| `probe_loads_fixed` | 16 | 0 | 0 | 0 |
| `probe_loads_pf2/3` | 16 | 0 | **24** | 0 |

Arm B's prefetch tiling covers the load footprint EXACTLY, which is the check that the
coordinates are right rather than merely plausible: A is 8 blocks x 32r x 16c x 2B = 8192 B =
128x32x2, and B is 16 x 32 x 16 x 2 = 16384 B = 32x256x2. A 16-bit 2D prefetch block is at most
**16 columns** wide, and an illegal `:size` fails at MODULE BUILD rather than at Crisp compile
(see `_kdepth/pf1_k32.crisp`), so the shape is not something to guess at.

## Mechanism findings from building arm A — true regardless of what it measures

**1. `-O3` silently strips `!spirv.Decorations`.** Codegen attaches the decoration to all 64
GEPs correctly (`!68 = !{i32 6442, i32 0, i32 1}`), and the opt pipeline drops **every one**:
64 in `.temp.ll`, 0 in `.opt.ll`. LLVM does not know the metadata is semantic, so folding, CSE
and reassociation of address arithmetic discard it. **Attaching decorations in codegen cannot
work for anything that survives to SPIR-V**, however correct the attachment is. The overlay
therefore re-attaches after opt, as a text pass over the `.ll` — the same class of thing
`inject-spir-kernel-metadata` already is, with the advantage of running on the FINAL address
arithmetic. Post-opt there are exactly 16 distinct load pointers and every one is a `getelementptr`.

*This is worth knowing beyond this probe: any future SPIR-V decoration Crisp wants to emit hits
the same wall.*

**2. `llvm-spirv` refuses rather than degrades.** Without `--spirv-ext=+SPV_INTEL_cache_controls`
it errors `RequiresExtension: Feature requires the following SPIR-V extension` instead of quietly
dropping the decoration. The flag is load-bearing, not defensive.

**3. `SPV_INTEL_cache_controls` works end-to-end in the bundled toolchain**, verified by
round-trip: `Capability CacheControlsINTEL`, `Extension "SPV_INTEL_cache_controls"`, and
`Decorate N CacheControlLoadINTEL 0 1` / `1 1`. No new FFI bindings were needed.

**4. SYCL-TLA uses ONE value, everywhere: `kL1C_L3C`** — cached at L1 *and* L3, at all 26 of its
block-load and prefetch call sites, with no variation. It never uses streaming, uncached, or
invalidate-after-read. Any theory that different operands or levels want different policies is
contradicted by the peer's own source.

**5. The route we take is NOT the route the peer takes.** SYCL-TLA calls
`__builtin_IB_subgroup_block_read_cacheopts_*` with the enum as an explicit ARGUMENT. Our
`OpCooperativeMatrixLoadKHR` has no cache operand, so a pointer decoration is the only in-band
route, and whether IGC consults it is exactly what arm A tests. **A flat `T_loads` is a real
result** — it means IGC ignored the decoration — and the fallback is the peer's builtin family.

## Gating

`CRISP_CACHE_CONTROL` is unset by default and the decoration path is then completely inert: zero
decorations, zero capability, zero extension, byte-identical output to before. No shipped kernel
changes. Values follow SYCL-TLA's enum names so the mapping stays legible: `l1c_l3c` (the peer's
choice), `l1s_l3c`, `l1uc_l3c`, `l1c_l3uc`.

## ROUND 2 RESULT — 2026-08-27, Arc B580, Docker/Linux, `fast`, iters=100

All seven arms in ONE container session. Median kernel time.

| arm | N=2048 | vs `probe_loads` | N=4096 | vs `probe_loads` |
|---|---:|---:|---:|---:|
| `probe_full` (real kernel) | 302.8 us | — | 2119.2 us | — |
| `probe_loads` (baseline) | 277.1 us | — | 2020.2 us | — |
| **A** `probe_loads_cc` (cache control) | 274.9 us | **-0.8%** | 1954.3 us | **-3.3%** |
| **B** `probe_loads_pf2` (prefetch 2) | 794.4 us | **+187%** | 5174.8 us | **+156%** |
| **B** `probe_loads_pf3` (prefetch 3) | 812.2 us | **+193%** | 5237.5 us | **+159%** |
| **C** `probe_loads_fixed` (fixed addr) | 114.7 us | **-58.6%** | 751.9 us | **-62.8%** |
| `probe_math` | 199.0 us | — | 1289.2 us | — |

`probe_full` read 302.8 / 2119.2 us against round 1's 299.6 / 2120.8 -- inside 1%, so the two
sessions are comparable and the round-1 conclusions carry.

### A — cache control does nothing. **-3.3%** at 4096, where the six-repeat spread is 3.1%.

Not a lever. **The arm is valid, not inert**: the container-built `probe_loads_cc.spv` carries
58 `CacheControlLoadINTEL 0 1` and 58 `1 1` decorations plus the capability and extension, and
the byte-identical `probe_loads.spv` carries zero. So either IGC does not consult a pointer
decoration when lowering `OpCooperativeMatrixLoadKHR`, or the driver default was already
equivalent to `kL1C_L3C`. Distinguishing those two would need the peer's builtin route, and is
not worth doing given the size of the effect.

### B — prefetch is CATASTROPHIC here. **2.6x to 2.9x SLOWER.**

Far worse than the old single-subgroup Windows readings (1.38x at distance 3, 0.80x at 4) that
retired prefetch the first time.

**READ THIS AS AN API GAP, NOT AS A VERDICT ON PREFETCH.** `prefetch-tile` has no `:warps`
notion, so at 16 subgroups **every subgroup issues all 24 prefetches** -- 384 per workgroup per
K-step against 256 loads. SYCL-TLA partitions its prefetch across subgroups; Crisp currently
cannot express that. So what this measures is *prefetch as Crisp can currently write it at
multi-subgroup geometry*, and the answer is that it is unusable. A staged-prefetch API would
have to carry warp partitioning to be worth building at all.

### C — the load path has **2.7x** of headroom, and it is not cache policy.

Pinning the coordinate cuts load time 62.8%. In bandwidth terms the same 6.44 GB of fragment
traffic moves at **3.19 TB/s** with a moving address and **8.57 TB/s** with a fixed one.

**The crossover matters more than the ratio.** At 751.9 us, arm C is FASTER than `probe_math`
(1289.2 us). So loads that cheap would flip the kernel from load-bound to **math-bound** -- and
`probe_math` is the same 106 TFLOPS ceiling round 1 found. The load path has more than enough
headroom to stop being the constraint.

Arm C still confounds **two** causes, and A being flat does not separate them, because cache
*policy* cannot fix capacity misses:

1. **per-iteration 64-bit address arithmetic** -- Xe has no native 64-bit multiply, so each is
   emulated `mul`/`mach`/`macl`; spec `155/04` pins 26 of them per 8 loads. Fix: address
   payloads / `:xe-native`, i.e. never materialise a 64-bit address, which is exactly what the
   peer does.
2. **L1 locality / L2 bandwidth** -- a fixed address is permanently L1-resident. Fix: a bigger
   per-subgroup register tile, so each loaded byte feeds more dpas.

A follow-up arm can separate them: keep the coordinate MOVING but over a range small enough to
stay L1-resident (alternating between two K-slabs). Full address arithmetic, near-perfect
locality. Fast => locality/bandwidth; slow => address arithmetic.

### Where this leaves the endeavour

Cache control is dead. Prefetch is dead until `prefetch-tile` can be partitioned across
subgroups. Both remaining candidates for arm C's 2.7x -- address arithmetic and L1 locality --
are attacked by things already on the list, and the **bigger per-subgroup register tile** hits
BOTH walls: it cuts loads-per-dpas from 0.5 to 0.25 (the memory wall) and amortises the
instruction stream (the 106 TFLOPS math ceiling). It remains blocked by `TN 128` at 0.14x,
`TM 64` not running, `TN 96` faulting, and `:xe-native` at 32x128 collapsing to 5.6 TFLOPS with
zero spill in the ISA.

### Caveat on the container build

The container's LLVM 21 **unrolled** `probe_loads` (58 module-wide loads across several
back-edges) but not `probe_loads_fixed` (16, simple structure). Total DYNAMIC load count is
unchanged by unrolling, and unrolling generally helps -- so the baseline got a benefit arm C did
not, and the 2.7x is if anything conservative.

---

# ROUND 3 — prefetch, distributed.  2026-08-27, one container session.

Endeavour 158 gave `prefetch-tile` a `:warp-partitioned` keyword, so the prefetch footprint is
divided across the workgroup's subgroups instead of every subgroup issuing every block. At the
shipped geometry that is **2 prefetch instructions per subgroup per K-step instead of 24** --
same coverage, 12x less issue.

## The full kernel (numerically CORRECT, verified at both sizes)

| N | no prefetch | distance 2 | distance 3 |
|---:|---:|---:|---:|
| 2048 | 58.10 TF | 67.66 (**+16.5%**) | 69.11 (**+18.9%**) |
| 4096 | 65.41 TF | **86.33 (+32.0%)** | 80.50 (+23.1%) |

`probe_full` re-measured at 65.41 against round 2's 64.85 -- 0.9% apart, so the sessions are
comparable and +32% is far outside the 3.1% run-to-run spread at this size.

Against round 1's decomposition this captures **51% of the memory wall**: 65.41 -> 86.33 where
106.2 TF was the ceiling if operands were free. In context, 4096 goes from 59% to **78% of
oneMKL** fp16, and from 34% to **46%** of SYCL-TLA's bf16.

## THE LOADS-ONLY ARM IS INVALID FOR THIS MECHANISM

Same prefetch, same distances, same session:

| N | loads base | + prefetch d2 | + prefetch d3 |
|---:|---:|---:|---:|
| 2048 | 273.5 us | 263.0 (-3.8%) | 273.2 (-0.1%) |
| 4096 | 2015.0 us | 2333.8 (**+15.8%**) | 2418.4 (**+20.0%**) |

**Loads-only says prefetch costs 16%. The full kernel says it buys 32%.** Prefetch pays by
filling stalls that only exist while the MMA is competing for issue and latency; deleting the
math removes exactly the condition under which it helps.

So the round-1 guidance in this file -- "watch `T_loads`, not `T_full`" -- is **correct for
measuring what the loads cost and wrong for measuring what prefetch is worth.** A probe arm that
deletes work is only valid for mechanisms whose benefit does not depend on the deleted work. The
loads-only prefetch arms are parked in `matmul.py` for this reason, not deleted.

## What round 2's arm B actually measured

"Prefetch is 2.6-2.9x slower" was **two** errors stacked: a 16x over-issue Crisp could not avoid
because the language had no way to distribute a prefetch, measured on an arm that cannot show
prefetch's benefit even when it works. Same shape as endeavour 156's "premise falsified" --
a mechanism written off because the language could not express it.

## Open

- The optimum distance MOVES with size: 3 wins at 2048, 2 wins at 4096. Same behaviour as K
  depth. Needs a sweep, not a pick -- distances 1-4 across 2048/4096/8192 is running.
- 8192 is where the shipped curve goes flat and where the peer comparison is decided; round 3
  did not reach it.

## THE DISTANCE SWEEP — and a cliff at 8192

Distances 1-4 against the no-prefetch baseline, one session, every point verified correct.

| kernel | N=2048 | N=4096 | N=8192 |
|---|---:|---:|---:|
| no prefetch | 56.49 TF | 64.90 TF | 65.96 TF |
| **distance 1** | 70.62 (**+25.0%**) | **91.17 (+40.5%)** | 29.38 (**-55.5%**) |
| distance 2 | 68.57 (+21.4%) | 87.10 (+34.2%) | 28.86 (-56.3%) |
| distance 3 | 66.96 (+18.5%) | 78.87 (+21.5%) | 28.51 (-56.8%) |
| distance 4 | 66.42 (+17.6%) | 75.16 (+15.8%) | 32.95 (-50.1%) |

**Two findings, and the second is the more important one.**

**1. Shorter is better, monotonically, and distance 1 is the best of the four.** 91.17 TF at
N=4096 is 82% of oneMKL fp16 (110.7), 48% of SYCL-TLA bf16 (188.9), and **86% of the 106.2 TF
ceiling round 1 measured for free operands**. Round 3 concluded "distance 2 beats distance 3"
and inferred an interior optimum; adding distance 1 shows the trend simply runs to the shortest
distance tested. 0 is not a distance, so 1 is the floor.

**2. AT 8192 EVERY DISTANCE COLLAPSES — 2.0x to 2.3x SLOWER than no prefetch at all.** Not a
tail-off; a cliff. Same kernels, same keyword, verified correct, and the no-prefetch baseline at
8192 (65.96) matches the shipped kernel's 66.1, so the baseline is sound.

**Do not ship prefetch unconditionally.** It would lift 1024-4096 substantially and destroy
8192 and up, which is exactly where the peer comparison is decided. This is the same shape as
the levers doc's standing observation that no geometry tested is best at every size -- except
here the penalty is a factor of two, not a few percent.

**Cause is unknown and the obvious explanation does not survive.** "The working set stops
fitting in the 18 MB L2" fails: A+B is 64 MB at 4096 and 256 MB at 8192, so BOTH already exceed
L2 while only one collapses. What does change at 8192 is the resident workgroup count (512 ->
2048, 4x) and the K-loop trip count (128 -> 256, 2x), so aggregate concurrent prefetch pressure
is the better suspect -- prefetches evicting the operands that the tile-visit swizzle is relying
on other workgroups to reuse. That is a HYPOTHESIS. It wants a measurement, not a paragraph.
