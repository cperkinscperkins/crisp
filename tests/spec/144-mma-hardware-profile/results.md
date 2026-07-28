Endeavor 144 — Measurements
===========================

Baselines and per-phase before/after numbers.  See `mma-hardware-profile.md` for the plan.


Phase 0 — device-queried hardware facts
---------------------------------------

### BMG — Intel Arc B580 (queried 2026-07-27)

Queried with `put_temp_files_here/hw-profile-query/query.cpp` (Level Zero
`zeDeviceGetProperties` / `…ComputeProperties` / `…CacheProperties`), built with the same
toolchain `validate-l0-host-run` uses.  **These are measured, not spec-sheet, values.**

| Property | Value | Profile key |
|---|---|---|
| name / deviceId | Intel(R) Arc(TM) B580 Graphics / `0xe20b` | — |
| coreClockRate | 2850 MHz | — |
| numSlices | 5 | — |
| numSubslicesPerSlice | 4 | — |
| numEUsPerSubslice | 8 | — |
| numThreadsPerEU | 8 | — |
| **Xe-cores** (slices × subslices) | **20** | `:compute-units` (Phase 6 decision) |
| total EUs | 160 | — |
| **`_hw_threads`** (the L0 hoist formula) | **1280** | — see spill note below |
| physicalEUSimdWidth | 16 | `:simd-width` |
| subGroupSizes | **16, 32** | `:simd-width` is a *choice*, not fixed |
| maxTotalGroupSize | 1024 | `:max-total-threads-per-block` |
| maxGroupSizeX/Y/Z | 1024 / 1024 / 1024 | `:max-work-group-dims` |
| maxSharedLocalMemory | 131072 B = **128 KB** | `:max-shared-memory-per-block` |
| cache[0] | 18874368 B = **18 MB** | `:l2-cache-size` |
| device memory | 11.6 GB DDR | — |
| compute queue groups | 1 (numQueues 1) | `:max-concurrent-kernels` — see note |

Not exposed by the L0 API, so these must come from the ISA/spec rather than a query:

- `:native-cache-line-size` — Xe2 LSC line is **64 B** (believed; not queryable).
- `:max-registers-per-thread` — GRF is **128 registers × 32 B = 4096 B/thread** default,
  256 × 32 B = 8192 B in large-GRF mode (believed; not queryable).  See Phase 4.
- `:max-registers-per-cu` — not queryable; derivable as GRF/thread × numThreadsPerEU ×
  numEUsPerSubslice if we decide we want it.
- `:mma-shapes` — an ISA fact, not a device property.  BMG tf32 XMX is `(8 16 8)`, already
  established by the working kernel.

**`:max-concurrent-kernels` note:** the device reports a single compute queue group with
`numQueues 1`, which is not a "concurrent kernels" count in any useful sense.  Reinforces
the Out-of-Scope call on that key.

**Proposed `bmg` builtin** (queried values + the three ISA facts):

```lisp
(def-hardware-profile bmg
  :simd-width 16
  :compute-units 20                     ; Xe-cores — Phase 6 settles the mapping
  :max-registers-per-thread 128         ; GRF regs (32 B each) — UNITS DECISION, Phase 4
  :max-total-threads-per-block 1024
  :max-work-group-dims '(1024 1024 1024)
  :max-shared-memory-per-block 128KB
  :l2-cache-size 18MB
  :native-cache-line-size 64
  :mma-shapes '((8 16 8)))
```

Note this contradicts the current 2-key inline `bmg` in
`benchmarks/matmul/intel_prefetch/matmul_bmg_prefetch.crisp:1` only by ADDING keys — the
two it sets (`:simd-width 16`, `:mma-shapes ((8 16 8))`) are both confirmed correct.

### H100 — DEFERRED

Needs a runpod.io instance (user, 2026-07-27).  The Phase-0 NVIDIA half is blocked on it.
Open question when we get there: [REPORT.md](../../../benchmarks/REPORT.md) says **H100
PCIe** (114 SMs) but topology.md's example profile says `132`, which is the **SXM** part.
Since `:compute-units` now overrides the device SM query in the CUDA launch grid, that
distinction directly mis-sizes the grid if wrong — query it, don't assume.


FINDING — every BMG benchmark kernel spills registers
-----------------------------------------------------

Probed with `put_temp_files_here/hw-profile-query/kernel-probe.cpp` (loads the shipped
`.spv`, reads `ze_kernel_properties_t`):

| Kernel | spillMemSize | localMemSize | privateMemSize | subgroup |
|---|---:|---:|---:|---:|
| `intel_prefetch/matmul_bmg_prefetch` | **1792 B** | 0 | 0 | 16 |
| `chap0_sync/matmul_bmg` | **2560 B** | 0 | 0 | 16 |
| `chap1_async_linear/matmul_bmg_async` | **2752 B** | 0 | 0 | 16 |

**Why this matters.**  The L0 hoist derates occupancy 2x when `spillMemSize > 0`
(hoist-l0/main.lisp:561-562).  The undreated `_hw_threads` for a B580 is 5×4×8×8 = **1280**,
yet endeavor 143's notes record `_hw_threads=640` on this exact card — exactly 1280/2.  So
the derate has been firing all along, on all three kernels, and the "640" baseline in the
143 dispatch-geometry analysis is a *spill-derated* number, not the hardware ceiling.

At 1792 B against a believed 4096 B GRF, `intel_prefetch` is spilling ~44% of a register
file's worth — and it is our **best** Intel kernel (86.5% of oneMKL).  This is direct
evidence for finding #5 (the SPV register model hole) and it promotes that phase from
"plausible candidate for the last 13.5%" to "measured defect with a known mechanism."

Caveats, stated honestly:

- Spill ≠ the cause of the remaining 13.5%.  Spill costs latency *and* triggers the
  occupancy derate, but oneMKL may also simply be better tuned.  This is a lead, not a
  diagnosis.
- The GRF size (4096 B) is a believed ISA figure, not queried — the 44% figure moves if
  that is wrong.
- `localMemSize 0` on chap0/chap1 is *probably* not a bug: Crisp's `:local` scratch becomes
  implicit kernel arguments (note 45 vs 27 `numKernelArgs`), so SLM set per-launch would not
  appear as statically-declared module SLM.  Worth confirming, not assuming.

**Suggested plan change:** Phase 4 (Intel GRF) should move up.  It now has a measured
defect, a mechanism, and a cheap success metric — `spillMemSize` back to 0 in this same
probe, plus `_hw_threads` recovering 640 → 1280.  Recommend promoting the probe to
`scripts/` since it is a reusable oracle for that phase.


Phase 4 — BEFORE/AFTER: large-GRF eliminates the spill (measured 2026-07-27)
---------------------------------------------------------------------------

### Theory

`intel_prefetch` at `local-size 16` (one SIMD16 subgroup) holds, per lane:

| Tile | Shape | floats/lane |
|---|---|---:|
| `C-tile` | 32×32 register tile | 1024/16 = **64** |
| `A-ring` | 2 × (32×8) | 512/16 = **32** |
| `B-ring` | 2 × (8×32) | 512/16 = **32** |
| | | **128 floats/lane** |

On Xe2 a GRF register is 32 B, so one float-per-lane across a SIMD16 subgroup is
16 × 4 = 64 B = **2 GRF registers**.  128 × 2 = **256 GRF registers required** — against
**128** in IGC's default mode.  Exactly 2x over, and exactly what large-GRF mode (256)
provides.

### Test 1 — does the mode fix the spill?  YES, all three kernels

Same `.spv`, rebuilt under each IGC register-file mode via `kernel-probe.cpp`:

| Kernel | default (128 GRF) | `-ze-opt-large-register-file` |
|---|---:|---:|
| `intel_prefetch` | 1792 B | **0 B** |
| `chap0_sync` | 2560 B | **0 B** |
| `chap1_async_linear` | 2752 B | **0 B** |

### Test 2 — does it make it FASTER?  YES, 1.5–2x

Hoist-generated launcher (`--mma-test=S,S,S --mma-bench=100`), patched only to read IGC
build flags from `CRISP_L0_BUILD_FLAGS`.  **Same kernel, same .spv, same binary, same
grid, same iteration counts — only `pBuildFlags` differs.**

| Size | default | large-GRF | speedup | correctness |
|---|---:|---:|---:|---|
| 256 | 2.52 TFLOPS (13.31 µs) | **4.08 TFLOPS** (8.22 µs) | **1.62x** | MMA_CORRECT both |
| 512 | 9.06 TFLOPS (29.64 µs) | **14.03 TFLOPS** (19.14 µs) | **1.55x** | MMA_CORRECT both |
| 1024 | 11.61 TFLOPS (184.91 µs) | **24.01 TFLOPS** (89.44 µs) | **2.07x** | MMA_CORRECT both |

**Confound ruled out:** the generated launcher for this kernel uses 143's *exact tile cover*
(`_gx = ceil(c_ext0/32)`, `_gy = ceil(c_ext1/32)`) — it never queries `spillMemSize` and
never applies the occupancy derate.  So the grid is identical in both runs and the gain is
attributable to spill elimination alone, not to a changed dispatch.

### Caveats — read before quoting these numbers

- **The RATIO is solid; the ABSOLUTE numbers are not directly comparable to REPORT.md.**  My
  default-mode 1024 reading is 11.61 TFLOPS where REPORT.md records 10.36, because the
  official driver uses `scaled_counts` warmup/iters and I used a fixed 100.  Trust the 1.5–2x;
  re-derive the absolutes from a real `scripts/crisp_bench/matmul.py` run.
- **24 TFLOPS would be ~2x oneMKL's 11.98 at 1024.**  That is a large claim and it is NOT
  confirmed yet.  It is not *implausible* — B580 tf32 peak is well above this, so 24 TFLOPS
  is a plausible fraction of peak, and oneMKL's tf32 path on consumer Battlemage may simply
  be immature — but an official head-to-head run is required before we put it in REPORT.md.
- **Large-GRF is not free.** It halves threads/EU (8 → 4), so it trades occupancy for
  registers.  It wins here because this kernel was spilling; it would LOSE on a
  low-register-pressure kernel.  That is precisely why the decision must be
  compiler-computed from register demand, not a global flag.

### Consequence for the phase

The mechanism was proven end-to-end BEFORE any compiler code was written.  Phase 4's job was
then well-defined: compute per-thread GRF demand, compare against the profile's budget, and
select the register-file mode — carrying the choice through the metacrisp so the hoist emits
`pBuildFlags` (was hardcoded `nullptr` at hoist-l0/main.lisp:458).


Phase 4 — IMPLEMENTED 2026-07-27
--------------------------------

Four steps, all landed as overlay appends:

1. **Schema (D4).**  `:max-registers-per-thread` now takes a scalar OR an ascending list of
   selectable modes (`:pos-int-or-modes`).  Accessors `%hp-register-modes` /
   `%hp-registers-per-thread-default` / `%hp-registers-per-thread-max`; both pre-existing
   consumers (`%register-tile-fit-check`, `%wgmma-acc-fit-check`) were switched to the
   accessor so a list value cannot break them.
2. **Accounting.**  Tallied in `analyze-make-register-fragment`, because
   `%explode-register-tiles` already emits one fragment per slot *per ring slot* and already
   divides by participating warps — so per-thread demand falls out exactly, ring depth and
   `:warps` distribution included, without redefining the 90-line explosion.  Keyed on
   (kernel . source-location) and **assigned, not incremented**, so multipass re-analysis is
   idempotent.  Units: elements × 4 B / 32 B per GRF register.
3. **Metacrisp.**  `:selected-registers-per-thread` rides inside the existing
   `(:hardware-profile …)` form — `parse-metacrisp-file`'s cond silently DROPS unknown
   top-level forms, so a new form would need a reader change while the profile plist already
   passes through whole.  The value is the MAX over the module's kernels, which is exact
   rather than approximate: IGC's register mode is a per-MODULE build flag.
4. **Hoist.**  `generate-module-loading` emits `pBuildFlags` when the selected allocation
   exceeds the profile's default mode.

### Verified: the compiler derives the same number three independent ways agreed on

| Kernel | hand-computed | compiler | IGC evidence |
|---|---:|---:|---|
| `intel_prefetch` | 256 | **256** | spills at 128, clean at 256 |

### END-TO-END perf, no manual patching anywhere

Compile → hoist → build → run, with the compiler choosing the mode:

| Size | before (default GRF) | after (compiler-selected) | speedup |
|---|---:|---:|---:|
| 256 | 2.52 TFLOPS | **4.08** | 1.62x |
| 512 | 9.06 TFLOPS | **14.03** | 1.55x |
| 1024 | 11.61 TFLOPS | **23.33** | **2.01x** |

All `MMA_CORRECT`.  Reproduces the manual A/B (4.08 / 14.03 / 24.01) within run-to-run
variance, confirming the compiler-driven path and the hand experiment agree.

### A real model flaw caught by the tests (worth recording)

The first spec run reported **272** registers for a 32×64 tile instead of 256 — one extra
8×16 fragment.  Cause: `%emit-per-frag-fill` expands `fill-tile` into a `set!` of every
fragment the tile ALREADY owns, and each `set!` re-enters `make-register-fragment`.  Those
allocate nothing, so counting them charged a tile extra registers merely for being filled.

Two things worth noting.  First, the over-count was only **+1** fragment rather than +16
because all sixteen synthesized forms share one source location and collapsed into a single
hash entry — i.e. the idempotence keying accidentally masked most of the error, which is
exactly the kind of thing that hides a modelling bug.  Second, the measured kernel was
unaffected (`intel_prefetch` has no `fill-tile`), so the validated 256 was never wrong —
the flaw only showed on kernels that fill.

Fixed properly rather than by adjusting the expectation: fill-emitted fragments are tagged
`:tally nil` and the analyzer skips them.  Post-fix all three kernels report their exact
hand-computed values (256 / 512 / 256 unchanged).

### Tests

- `03-grf-selects-large-mode.crisp` — 32×64 tile → 256 regs → selects the larger mode.
- `04-grf-exceeds-every-mode.crisp` — 64×64 tile → 512 regs → warns (spills in any mode).
- `errors/01-register-modes-descending.crisp` — descending mode list is a definition error.

### Regression: clean

| Suite | Result | Baseline |
|---|---|---|
| E2E specs | **941/941** | 936 + 5 new |
| Unit | **253/253** | 253 |
| Negative | **210/210** | 209 + 1 new |

### Repo change beyond the overlays

`benchmarks/matmul/intel_prefetch/matmul_bmg_prefetch.crisp` — its inline `bmg` profile
gained `:max-registers-per-thread (128 256)`.  Without that key the profile cannot express
the modes and no selection happens.  Per D2 the durable fix is a **builtin** `bmg` profile
(Phase 0's remaining Intel half); this inline key is the interim.


Phase 1 prerequisite — tile-stride order-dependence survey
----------------------------------------------------------


Phase 1 prerequisite — tile-stride order-dependence survey
----------------------------------------------------------

Phase 1 reorders `tile-stride`'s workgroup→tile mapping.  That is within the macro's
contract (coverage, not order — decision D1), but a body whose writes are NOT a pure
function of its own `(grid-y, grid-x)` would change results under reordering.  Surveyed all
64 `tile-stride` kernels in `tests/`, `benchmarks/`, `performance/`.

**Axis 1 — atomics / cross-tile accumulation: CLEAN.**  64 tile-stride kernels, 17 kernels
using atomics anywhere in the repo, **exact set intersection is empty**.  No tile-stride
body performs an atomic, so no FP-summation-order hazard exists.

**Axis 2 — non-coordinate writes: effectively clean.**  Three tile-stride kernels use
`store-tile-at` (absolute element coords rather than tile-IDs):
`111/11-store-tile-1d`, `111/12-roundtrip-tile-stride`, `113/03-async-store-tile-1d`.  All
three are 1-D spec fixtures whose `-at` offsets are derived from the tile origin, so they
remain coord-determined.  Worth a re-read when Phase 1 lands, but not a blocker.

**Conclusion: Phase 1's reordering is safe.**  No kernel in the repo depends on tile visit
order.

### Side finding (pre-existing, NOT caused by Phase 1)

Three benchmark kernels declare `C-tile` OUTSIDE the tile loop and never reset it per tile:

| Kernel | reset present | accumulator scope |
|---|---|---|
| `chap0_sync/matmul.crisp` | no | outside the macro |
| `chap0_sync/matmul_bmg.crisp` | no | outside the macro |
| `chap1_async_linear/matmul_bmg_async.crisp` | no | outside the macro |
| `chap1.5_async_block/matmul_async_block.crisp` | yes (`fill-tile`) | outside |
| `chap2_pipelined_block/matmul_pipe.crisp` | yes (`fill-tile`) | outside |
| `chap3_wgmma/matmul_wgmma.crisp` | yes (`set! D`) | outside |
| `intel_prefetch/matmul_bmg_prefetch.crisp` | n/a — declared INSIDE `tile-stride` | inside (correct by construction) |

topology.md is explicit: "When a workgroup owns more than one C-tile, the register C-tile is
reused across tiles, so reset it... A one-tile-per-workgroup launch does not need this."
None of these kernels declares `global-size` at all — the grid comes from 143's inferred
`:tile-shape` exact tile cover, which *is* one-tile-per-workgroup, so **the three are
correct today**.  But they are silently correct: they would produce wrong results under an
oversubscribed or under-dispatched grid, and nothing in the source says so.

This is orthogonal to Phase 1 (reordering preserves exact cover), and the pattern tracks
when the discipline was learned — the Chapter-0/1 kernels predate it, everything from
Chapter 1.5 on has it.  Recommend adding the reset to those three for robustness, as a
tidy-up rather than a bug fix.


Phase 2 — wgmma accumulator register accounting: IMPLEMENTED 2026-07-27
----------------------------------------------------------------------

Finding #2 closed.  Implemented as an APPEND in `overlays/crisp-compiler-overlay.lisp`
(two new definitions + one redefinition, all marked `;; src/mma.lisp`):

- `*wgmma-acc-occupancy-warn-fraction*` (1/2)
- `%wgmma-acc-fit-check (m n location)`
- `analyze-make-wgmma-accumulator` — now calls the check

Two tiers, per decision D3:

| Tier | Condition | Behavior |
|---|---|---|
| hard overflow | accumulator regs/thread > budget | **error** (mirrors `%register-tile-fit-check`) |
| occupancy cost | accumulator regs/thread ≥ ½ budget | **warning** to `*error-output*` (raw `format`, survives `--log-level=off`) |

### Verified manually on real kernels (not just via validators)

| Case | Command | Result |
|---|---|---|
| chap3 `matmul_wgmma.crisp` (n256), default budget | `--ir-target=ptx --ir-target-arch=sm_90` | exit 0 + `WARNING: … 64x256 reserves 128 of 255 registers/thread (50.2%) … 16384 registers per 128-thread warpgroup` |
| n128, default budget | same | exit 0, **no** wgmma warning (64/255 = 25%, below threshold) |
| n256, profile `:max-registers-per-thread 64` | `--hardware-profile=tiny` | exit **1** + `needs 128 registers/thread …, exceeding the register budget of 64` |

### Note: the ERROR tier is reachable only through a profile

`%check-wgmma-shape` caps N at 256, so the worst legal accumulator is 128 regs/thread —
always under the 255 default.  The error therefore only fires under a deliberately
shrunken profile.  That is not a defect (it is topology.md's "Empty Room Fallacy"
use case), but it means the DEFAULT-budget signal is the *warning*, and the warning is
what matters for the chap3 N-sweep.

### Rough edge left deliberately un-fixed (your call)

chap3 emits the warning **twice**, because the kernel contains two
`make-wgmma-accumulator` forms (the `let` binding plus the per-tile
`(set! D (make-wgmma-accumulator …))`).  That is factually correct — two forms, two
reservations — but noisy.  Deduping needs per-compile state keyed on (kernel, M, N), and
any such cache risks leaking across files in the in-process spec runner and silently
swallowing a warning an `EXPECT-STDERR` test depends on.  I judged hidden state worse than
duplication; say the word and I'll add it with an explicit `initialize-compiler` reset.

### Tests

- `01-wgmma-acc-register-budget.crisp` — `COMPILE-WITH[--hardware-profile=small-regs]: FAIL
  "register budget"` (error tier)
- `02-wgmma-acc-occupancy-warn.crisp` — `EXPECT-STDERR[--hardware-profile=derated]:
  "reserves 128 of 200 registers/thread"` (warning tier).  Budget deliberately **200**, not
  255, so the substring can only be produced by actually reading the profile — a 255 test
  would pass even if the profile were ignored.

Both need `SKIP-DEFAULT-PASS` (as every 140-wgmma spec does): the default pass validates
generic LLVM IR, which cannot digest the NVVM wgmma intrinsics.

### Regression: clean

| Suite | Result | Baseline (143) |
|---|---|---|
| E2E specs | **938/938** | 936 + the 2 new |
| Unit | **253/253** | 253 |
| Negative | **209/209** | 209 |

`tests/ci-stop.txt` was advanced to `144-mma-hardware-profile` to run the new specs, then
**restored to `142-mma-prefetch`** — endeavor 144 is in progress, so per the TDD convention
ci-stop advances only when the endeavor completes.

### Doc drift found while doing this

`docs/tests.md` says of `EXPECT-STDERR`: "the target is fixed to `spv`."  It is not —
`run-spec-expect-stderr-pass` (run-specs.lisp:611) passes **no** `--ir-target` at all and
says so in its own docstring.  Worth correcting; it is the reason this directive works for
a PTX-only wgmma kernel.
