# Endeavour 156 — Workgroup Cooperation

## THE TARGET, STATED ONCE AND PLAINLY

**A 256×256 output tile computed by 32 cooperating subgroups in one workgroup, with the A and B
operands loaded into shared local memory ONCE per workgroup and reused by all 32.**

That is the geometry SYCL-TLA is observed to use on this hardware, and it is the geometry Crisp
does not have. Everything in this endeavour serves that sentence. When a decision is unclear, the
question to ask is "does this get us to 256×256 over 32 subgroups with shared operands?"

Today Crisp ships `local-size :set-to 16` — **one subgroup per workgroup** — computing a 32×64 tile.
Every output tile independently streams its own A row-strip and B column-strip from memory, with
zero sharing between subgroups. That is the thing being changed.

---

## THE EVIDENCE THAT THIS IS THE RIGHT TARGET

Measured on Arc B580, bf16, `--precision=fast`, every Crisp point MMA_CORRECT (2026-08-24):

| N | Crisp | Peer (SYCL-TLA) | Ceiling (oneMKL) | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|
| 256 | 3.8 | 0.4 | 9.8 | **8.67×** | 39% |
| 512 | 17.0 | 3.7 | 40.3 | **4.53×** | 42% |
| 1024 | 49.6 | 24.2 | 75.1 | **2.05×** | 66% |
| 2048 | 60.9 | 108.6 | 86.3 | 0.56× | 71% |
| 4096 | 56.8 | 195.8 | 105.0 | 0.29× | 54% |
| 8192 | 37.5 | 241.1 | 113.1 | 0.16× | 33% |

fp16 tracks this almost exactly (50.0 / 61.2 / 56.6 / 37.4).

**Read the shape, not the worst number.** Crisp BEATS the peer at 256, 512 and 1024 and peaks at
71% of oneMKL. It is not uniformly slow. What it does is *turn over* at 2048 and decline
(60.9 → 56.8 → 37.5) while the peer keeps climbing (108 → 196 → 241). The entire deficit is a
large-N scaling failure, and a turnover-then-decline curve is the signature of a working set that
has outgrown cache.

**Why one subgroup per workgroup produces exactly that curve.** With no sharing, the DRAM traffic
for the whole GEMM is `N³/TM + N³/TN` — every subgroup re-fetches operands that its neighbours are
fetching at the same moment. At small N the redundant fetches all hit L2 (18 MB on BMG) and cost
nothing, so Crisp's low launch overhead wins outright. At 8192 the working set is far past L2, the
redundancy becomes real DRAM traffic, and the kernel becomes bandwidth-bound. Sharing operands
through SLM divides that traffic by the number of cooperating subgroups.

### What has ALREADY been eliminated by measurement — do not re-try these

Endeavour 155 spent a long time on the same gap. These are closed, with numbers:

| Hypothesis | Verdict |
|---|---|
| Barriers / synchronisation cost | ruled out |
| Missing operand reuse within a subgroup | implemented (34→10 loads), **zero** perf change, reverted |
| Register pressure / spilling | ruled out — 256×256 over 32 subgroups runs with NO spill |
| Tile geometry alone | 32×64 already tuned; 32×32 / TN 96 / TN 128 / TM 64 all worse or broken |
| Prefetch distance | d=3 worse than d=2; d=4 actively harmful |
| Code size | ruled out |
| GRF model non-monotonic | **my error** — the harness passed large-GRF to both arms of the A/B |
| **Address arithmetic** (155 Step 4) | **ruled out, with a surprise — see below** |

**The address-arithmetic result is worth carrying forward because it is diagnostic.** The kernel
emitted ~610 mul/mach/macl instructions (64-bit multiply is emulated on Xe) to address SIXTEEN
`dpas`. Hoisting tile addresses to base-plus-delta cut that to 390 (−36%) on the big probe, and on
the shipped kernel produced an ISA of *1833 instructions against 1825* — statistically identical —
yet throughput fell **61.2 → 50.7 TFLOPS**, reproduced across four runs.

Two conclusions, both load-bearing here:

1. **Instruction count does not govern this kernel.** A 36% cut in the most expensive instruction
   class bought +2.9%. The kernel is not issue-bound. It is memory-bound — which is the same
   conclusion the benchmark curve reaches from the other direction.
2. **Independent address chains matter more than short ones.** Identical instruction counts
   differing by 17% is a dependency effect: base-plus-delta made every address in a tile depend on
   one hoisted value, where independent recomputation gave the scheduler parallel chains to
   interleave. Latency hiding through ILP is doing real work in this kernel. Any future change that
   serialises address computation should expect to pay for it.

---

## WHAT BLOCKS THE TARGET TODAY

Three things, in dependency order. Each is verified, not assumed.

### B1 — The subgroup size is not pinned

Crisp computes the workgroup's warp count as `local-size / :simd-width` using the profile's
`:simd-width 16` ([mma.lisp:712-722](../../../src/mma.lisp)). But the generated SPIR-V requests **no
subgroup size at all** — the only `OpExecutionMode` emitted is `4459` (DenormPreserve). IGC is free
to compile the kernel at SIMD8, SIMD16 or SIMD32, and BMG's `subGroupSizes` advertises both 16
and 32.

Today IGC picks SIMD16 for both the shipped kernel and the 32-subgroup probe (confirmed from the
dump filenames, `..._simd16_entry_0001.asm`), so the assumption holds — **by luck of a heuristic,
not by contract.** If IGC ever picks SIMD32 for a larger kernel, a 32-entry `:warps` mask would
describe 16 actual subgroups, every per-warp switch arm would select the wrong slice, and the
result would be silently wrong. This endeavour is about to make kernels much larger, which is
exactly the input that moves IGC's heuristic.

SIMD16 is also the width XMX/DPAS wants on Xe2, so pinning 16 is both the safe and the correct
choice — this is closing a hole, not making a tradeoff.

### B2 — The warp-sliced path is WRONG at 32 subgroups

The 256×256 `:warps` probe over 32 subgroups reports **MMA_WRONG**. This was found while measuring
something else, and proven independent of it: neutering the address change and re-running the
identical probe still gives MMA_WRONG.

**This invalidates earlier measurements.** The endeavour-155 Step 2 scaling numbers (subgroup count
1→8 giving 1.68→13.07 TFLOPS) were taken on these probes and must be treated as unverified until
B2 is fixed. No performance claim about multi-subgroup tiles can be trusted before then.

The shipped kernels are unaffected because at `local-size 16` there is only one subgroup, so no
slicing happens — which is precisely why this bug has stayed hidden.

### B3 — Ring tiles cannot be warp-sliced at all

`%explode-register-tiles` pushes a ring tile as `(NAME :RING M N SLOT-SYMS-LIST OPERAND)` — no
`n-true`, no `first-true` — and the ring branch never reads `:warps`. Every shipped 16-bit kernel
uses `make-register-tile-ring`, so **`:warps` on a shipped kernel is currently a no-op by
construction.** Until the ring entry carries the slice fields, larger workgroups cannot be tested
on any kernel we actually ship.

---

## PHASES

### Phase 0 — Pin the subgroup size (closes B1)

Emit `OpExecutionMode <kernel> SubgroupSize <profile :simd-width>` on the SPIR-V backend so the
value Crisp assumes and the value IGC compiles are the same value by contract.

- Verify in the `.spt` (mode 35 present with operand 16) **and** in the IGC dump filename.
- Negative test: a `:warps` mask whose length disagrees with `local-size / simd-width` already
  errors; confirm the message still names both numbers.
- Cheap, self-contained, and it removes a class of doubt from every measurement that follows.

### Phase 1 — Fix the sliced path (closes B2)

Bisect the subgroup count to find where correctness breaks: does 256×256 fail at 2 subgroups? 4?
8? The threshold names the bug. Prime suspects, in order:

1. `%emit-per-frag-block-load`'s static per-warp switch chain — the `chain`/`arm` recursion selects
   a slice by `wp/gn` (A) or `wp mod gn` (B); an off-by-one in the final arm would corrupt exactly
   one warp's slice.
2. `%warp-grid-dims`'s squarest-factorisation — a grid whose GM×GN does not evenly divide the
   fragment counts leaves fragments unassigned or double-assigned.
3. `%emit-per-frag-store`'s runtime addressing — this one is newer than the others and was changed
   late in 155.

**TDD rungs with on-metal expectations at each subgroup count** (1, 2, 4, 8, 16, 32), so the
threshold is recorded permanently rather than rediscovered. `TEST-HOIST[L0]` + `HOIST-EXPECT`.

### Phase 2 — Teach ring tiles to slice (closes B3)

Extend the ring tile entry to carry `n-true`/`first-true`, read `:warps` in the ring branch of
`%explode-register-tiles`, and follow through in the ring consumers (`ring-get` into load and
accumulate). Structural, mechanical, and testable in isolation once Phase 1 gives a trustworthy
sliced path.

### Phase 3 — Shared operand staging through SLM

**The actual arithmetic-intensity win, and the reason for the whole endeavour.** 32 subgroups each
computing a 32×64 sub-tile of a 256×256 output tile must load A and B into SLM *once per workgroup*
and share, rather than 32 times from memory. Requires a workgroup barrier (exists, endeavour 111),
`:local` address-space allocation (exists), and a cooperative load that distributes the fetch
across subgroups.

BMG has 128 KB SLM per workgroup. A 256×16 bf16 A-strip plus a 16×256 B-strip is 8 KB + 8 KB per
K-step — comfortable, and it leaves room for double-buffering the stage against the MMA.

Carry forward from the address-arithmetic result: **do not serialise the address chains** when
staging. Independent chains measurably outperform short ones here.

### Phase 4 — Benchmark, tune, record

Re-run the 16-bit chapters. The deficit lives at 2048–8192; that is where the number has to move.
Report against both peer and ceiling, and re-measure N=16384 (deferred through 155).

Tuning parameters that become live only after Phase 3: subgroup count, output tile shape, SLM
staging depth, and the split of the tile across the warp grid.

---

## DEFINITION OF DONE

Beyond `plan/definition-of-done.md`:

- [ ] Every on-metal rung MMA_CORRECT at every subgroup count tested (1, 2, 4, 8, 16, 32)
- [ ] Subgroup size pinned and verified in both `.spt` and IGC dump
- [ ] The endeavour-155 Step 2 numbers either re-measured on a correct kernel or struck
- [ ] A shipped 16-bit kernel actually using `local-size :set-to 512`, or a recorded reason why not
- [ ] `--differentiate` still passes for every new spec (the A|D system has few exceptions now)
- [ ] Benchmarks re-run and recorded, including N=16384

## NOT IN SCOPE

- NVIDIA 16-bit (PTX fragment lowering is still tf32-specific) — its own endeavour
- Cache-control hints (L1/L2 targets on prefetch) — considered in 155, never reached
- Folding the 155 overlays into `src/` — a separate cleanup pass

---

# RESULTS

## Phase 0 — DONE (2026-08-24)

Crisp now emits `!intel_reqd_sub_group_size`, which the LLVM→SPIR-V translator turns into
`OpExecutionMode SubgroupSize 16` **together with the `SubgroupDispatch` capability it requires**.
Verified in the shipped bf16 kernel: `ExecutionMode 856 35 16`, `Capability SubgroupDispatch`, and
IGC dumping `..._simd16_entry_0001.asm`. On metal: MMA_CORRECT, 60487 GFLOPS at N=2048 against a
60934/61159 baseline — within noise.

Writing the execution mode directly does **not** work. `SubgroupSize` requires `SubgroupDispatch`,
and the translator will not invent a capability to satisfy a raw mode request — it drops the mode
silently. Asking for the *feature* brings its capability along; asking for the *mode* does not.

### The thing Phase 0 turned up on the way

`inject-spir-kernel-metadata` splices the OpenCL `!kernel_arg_*` refs into a kernel's define line by
taking everything between the signature's `)` and `{` and **replacing** it. Everything LLVM had
already attached was discarded — including `#0`, the attribute-group reference, and `!dbg`. For
entry points only; every non-kernel function kept both.

That is a very plausible explanation for the endeavour-126 finding that the `denormal-fp-math`
function attribute "does NOT reach SPIR-V (verified 2026-07-01)". The attribute was fine. The
reference to its attribute group was being deleted here. 126 worked around it with an explicit
execution mode, which is why denormals behave correctly and why this stayed invisible.

Now appends rather than replaces. 1028/1028 + 218 negative + 291 unit.

## Phase 1 — DONE (2026-08-24). B2 CLOSED.

### The bisection

Fixed 32×64 tile, `gen7.py` (no ring, no prefetch, so nothing but slicing is in play), N=256:

| subgroups | 1 | 2 | 4 | 8 | 16 |
|---|---|---|---|---|---|
| result | CORRECT | CORRECT | **WRONG** | **WRONG** | **WRONG** |

Threshold is 4. With a 4×4 fragment grid, 2 warps give a 1-D warp grid and 4 give the first 2-D one.
Confirmed by forcing the grid's shape at a fixed 4 subgroups:

| tile | m-frags × n-frags | grid | result |
|---|---|---|---|
| 8×128 | 1 × 8 | (1,4) | CORRECT |
| 8×64 | 1 × 4 | (1,4) | CORRECT |
| 32×16 | 4 × 1 | (4,1) | CORRECT |
| 64×16 | 8 × 1 | (4,1) | CORRECT |
| 32×64 | 4 × 4 | (2,2) | **WRONG** |
| 64×64 | 8 × 4 | (2,2) | **WRONG** |

And isolating which side: C distributed with operands **unsliced** was CORRECT at 4 and 8 subgroups
and at 64×64. So the C partition was never the problem — the operand slicing was.

### The cause

The per-warp load switch selected its arm with `(intern "FLOOR" :crisp-language)` for A and
`(intern "MOD" :crisp-language)` for B. Neither is the operator it looks like:

- `FLOOR` resolves to `CRISP.COMPILER:FLOOR`, which returns a **float**
- `MOD` resolves to **NIL** — it does not exist in `crisp-language`, so `intern` **mints a fresh
  symbol** with no operator behind it

`%emit-per-frag-store` had already hit this and moved to integer `/` and `-`, and its comment says
so explicitly. The load switch was never updated to match.

**Why a 2-D grid is exactly where it bites:** the selector divides by `gn`. When the grid is 1-D one
extent is 1, so the divide is by 1 — exact under any semantics — and the *other* operand emits a
bare arm with no selector at all. A 2-D grid is the first case where a selector divides by something
greater than 1.

Fixed to use the same integer construction as the store: `wm = wp / gn`, `wn = wp - (wp / gn) * gn`.

### Result

Every configuration MMA_CORRECT, 1-D grids unaffected:

| tile | warps | result | | tile | warps | result |
|---|---|---|---|---|---|---|
| 32×64 | 1, 2, 4, 8, 16 | CORRECT | | 128×128 | 16 | CORRECT |
| 64×64 | 4 | CORRECT | | **256×256** | **32** | **CORRECT** |
| 64×128 | 8 | CORRECT | | 128×256 | 32 | CORRECT |

**256×256 over 32 subgroups is correct for the first time.** 1028/1028 + 218 + 291.

### Geometry at scale, and what it does and does not show

`gen7.py` throughout — no ring, no prefetch — so this isolates geometry:

| N | 32×64 nw=1 | 64×64 nw=4 | 128×128 nw=16 | 256×256 nw=32 |
|---|---|---|---|---|
| 2048 | **49.8** | 44.3 | 39.9 | 42.2 |
| 4096 | 47.4 | 30.9 | 32.3 | **52.1** |

The big tile wins at 4096 and loses at 2048. **This is the expected shape, and it is not yet the
win.** Slicing alone reduces operand redundancy from nw-fold to gn-fold for A and gm-fold for B —
at an (8,4) grid that is 4× for A and 8× for B, not 1×. Only SLM staging takes it to once per
workgroup, and that is Phase 3. What Phases 0 and 1 bought is that the geometry is now *correct and
therefore measurable*, which it has never been before.

Note these numbers sit below the shipped kernel's 60.9 at 2048 because `gen7` has neither ring nor
prefetch, and the shipped kernel cannot be sliced at all until Phase 2.
