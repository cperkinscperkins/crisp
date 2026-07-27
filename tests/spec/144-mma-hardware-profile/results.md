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
