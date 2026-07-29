Endeavor 144 — Measurements
===========================

Baselines and per-phase before/after numbers.  See `mma-hardware-profile.md` for the plan and
`FINDINGS.md` for the outside-reader writeup.


HEADLINE — BMG, 2048, measured end-to-end through the shipped code path
----------------------------------------------------------------------

`intel_prefetch`, tf32/`fast`, `MMA_CORRECT` at every step.  The baseline row is a genuine
pre-endeavor configuration, reproduced by giving the kernel its ORIGINAL two-key inline `bmg`
profile (a user profile overrides the builtin, so this is the real old behaviour, not a
simulation) plus `CRISP_TILE_VISIT=linear`:

| Configuration | TFLOPS | step |
|---|---:|---|
| linear + default GRF — **pre-endeavor** | **8.37** | baseline |
| linear + large GRF — Phase 4 | 17.16 | **2.05x** |
| grouped W=4 + large GRF — Phase 4 + Phase 1 | **28.01** | **1.63x** |
| | | **3.35x total** |

Both wins come from the hardware profile telling the compiler something it could not otherwise
know: the register file is mode-selectable (Phase 4) and this machine wants a 4-wide tile strip
(Phase 1).  Neither required a kernel source change.

Regression at this state: **943/943 E2E, 253/253 unit, 211/211 negative.**

NOTE the same two phases are NEUTRAL-to-HARMFUL on H100 — see the H100 sections below.  That
asymmetry is the endeavor's most portable finding and is why both consumers are profile-gated.


Phases 3, 5, 6 — completed 2026-07-28 (unattended session)
----------------------------------------------------------

All three were completed under standing authorization to decide and document rather than wait.
TWO OF THE THREE WERE DELIBERATELY RE-SCOPED; the rationale is recorded here and in the overlay
so either can be reversed knowingly.

### Phase 6 — `:compute-units` on the L0 launcher.  Implemented as planned.

Endeavor 130 Phase 5 wired `:compute-units` into the CUDA launcher but deferred Intel, because
CUDA has one obvious "compute unit" and Intel's occupancy formula is
`numSlices × numSubslicesPerSlice × numEUsPerSubslice × numThreadsPerEU`.

**DECISION: `:compute-units` means Xe-cores** — it replaces `numSlices × numSubslicesPerSlice`;
the per-Xe-core terms stay queried.  Reasons:

- It is the same *semantic* as CUDA's SM count ("how many independent compute units do I get"),
  so one key means one thing on both backends.
- The queried terms are micro-architectural.  A user shrinking a profile is saying "I get part
  of the machine", never "EUs are built differently".
- It makes topology.md's shrunken-profile / Empty Room case work: `:compute-units 10` on a
  20-Xe-core B580 yields exactly half the threads.
- Verified no-op for a full-size profile: 5 slices × 4 subslices = 20 Xe-cores, and
  20 × 8 EUs × 8 threads = **1280**, exactly what the unmodified formula produces.

Verified: without a profile the launcher emits the queried product; with `bmg` it emits
`uint32_t _xe_cores = 20;`.  On-metal 089-strategy **27/27**.

Scope: only the `:strided` occupancy path.  Endeavor 143 showed tiled kernels prefer exact tile
cover (`:tile-shape`), which never consults `_hw_threads` — so matmul is unaffected and the
consumers are vector/reduction-shaped kernels.

### Phase 5 — RE-SCOPED from `:ring-count :max` to SLM utilization reporting

**Not shipped: auto-selecting the deepest ring that fits SLM.**  Three reasons, two measured
inside this endeavor:

1. Endeavor 138 already measured a pipelining/occupancy **crossover** on exactly this axis:
   deeper rings bought +7-9% but cost -6% occupancy, and the sign flipped by 4096.  "Deepest
   that fits" is not a maximum of anything the user wants.
2. Phase 4 measured that granting more of a resource can lose badly — large-GRF is 2.01x on a
   register-resident kernel and **-38%** on an occupancy-bound one.
3. Phase 1 measured that occupancy *reasoning* predicted the wrong sign twice in one session.

The plan document's own words were "bound and report the tradeoff, not blindly maximize".  That
is what ships.  (Secondary: `:max` would need `src/macros.lisp` patched, as the ring
constructors are macros the overlay cannot late-bind.)

**Ships instead:** per-kernel SLM utilization against the profile cap — always logged, warning
only above 75% where the number is actionable (SLM, not registers, is then capping residency).
Low utilization is reported, never warned.

Measured on the NVIDIA chapters with `h100`:

| Kernel | SLM used | of cap | |
|---|---:|---:|---|
| chap3_wgmma | 81920 B | 232448 B | 35.2% |
| chap2_pipelined_block | 8192 B | 232448 B | 3.5% |

chap2's 3.5% is the observation that motivated this phase — now surfaced by the compiler
instead of by reading source.

### Phase 3 — RE-SCOPED from a full occupancy model to a register-side diagnostic

**Not shipped as planned**, for two independent reasons:

1. **Its consumer evaporated.**  Phase 3 existed largely to supply
   `W = sqrt(R · tile_M / tile_N)` to Phase 1 — and Phase 1 then measured that the width barely
   matters and the whole optimization is device-specific.  Building a model to feed a retired
   formula would be building the wrong thing carefully.
2. **The SLM half needs a NEW SCHEMA KEY.**  Resident-blocks-per-CU wants shared memory per
   *compute unit*; `:max-shared-memory-per-block` is per *block*.  Inventing a schema key
   unattended is the class of decision to make deliberately (cf. D4), and Phase 5 now reports
   SLM utilization directly, covering the practical need.

**Ships:** a register-side occupancy report built only from existing keys —
`:max-registers-per-cu`, the per-thread demand this endeavor already tallies, and local-size:

```
blocks/CU = :max-registers-per-cu / (registers-per-thread × threads-per-block)
```

Warns only at 1 block/CU, where there is no second block to hide memory stalls behind.

| Kernel | regs/thread | threads | regs/block | blocks/CU |
|---|---:|---:|---:|---:|
| chap3_wgmma | 128 | 160 | 20480 | **3** |
| chap2_pipelined_block | 128 | 32 | 4096 | 16 |
| chap1.5_async_block | 128 | 32 | 4096 | 16 |

#### The diagnostic caught a bug in itself on its first run

It initially reported **256** regs/thread for chap3 — double the truth — and fired a spurious
warning on our best kernel.  Cause: the kernel contains two `make-wgmma-accumulator` sites for
ONE accumulator (the `let` binding, plus a per-tile
`(set! D (make-wgmma-accumulator …))` re-initialization), and the tally summed sites.  Same
class as `fill-tile`'s per-fragment `set!`s, except the user writes this one, so it cannot be
tagged `:tally nil`.

Fixed by keying wgmma reservations on **shape** rather than source site, so repeated
construction of the same accumulator collapses.  Fragments keep per-site keying, since there
each site really is distinct storage.

Known limitation, stated rather than hidden: two genuinely distinct accumulators of identical
shape would be counted once.  That under-counts, which conflicts with an "upper bound" framing —
so the report says "counts explicit reservations".  The alternative over-counted the flagship
kernel by 2x and cried wolf on it, which is worse than a documented edge case.

### One self-inflicted bug worth recording

Phase 5's first build broke `130/08-slm-in-budget` with *"The function CRISP.COMPILER:FLOAT is
undefined"* — because I wrote `(float used)`, and `float` in `:crisp.compiler` is the **Crisp
type symbol**, not `cl:float`.  This is the exact trap `docs/crisp-curios.md` documents.
Isolated by rebuilding with the previous overlay (1/1 passed), then fixed with `cl:float`.
Cost ~10 minutes; would have cost far more without the suite catching it immediately.

### Regression after all three phases

**943/943 E2E, 253/253 unit, 211/211 negative.**

One run emitted an SBCL `CORRUPTION WARNING` / memory fault in a *foreign function* at image
exit, AFTER reporting 943/943.  Not reproducible: a full re-run and two filtered runs were
clean.  Consistent with the `LLVM-C.dll` teardown flakiness CLAUDE.md already documents.
Recorded rather than ignored, since it was absent from every previous run.


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

### H100 PCIe — queried 2026-07-28 on runpod

Queried with `put_temp_files_here/hw-profile-query/query_cuda.cu` (`cudaGetDeviceProperties`).
**Measured, not spec-sheet.**  Confirms the PCIe part: **114 SMs**, not the 132 of topology.md's
SXM example — and since `:compute-units` overrides the device SM query in the CUDA launch grid,
that distinction would have mis-sized every grid.

| Property | Value | Profile key |
|---|---|---|
| name / cc | NVIDIA H100 PCIe / sm_90 | — |
| multiProcessorCount | **114** | `:compute-units` |
| warpSize | 32 | `:simd-width` |
| regsPerMultiprocessor | 65536 | `:max-registers-per-cu` |
| maxThreadsPerBlock | 1024 | `:max-total-threads-per-block` |
| maxThreadsDim | 1024 / 1024 / 64 | `:max-work-group-dims` |
| sharedMemPerBlock | 49152 B (48 KB) | ← the DEFAULT, **not** the cap |
| **sharedMemPerBlockOptin** | **232448 B (227 KB)** | `:max-shared-memory-per-block` |
| l2CacheSize | 52428800 B (**50 MB**) | `:l2-cache-size` — Phase 1 depends on this |
| totalGlobalMem | 79.2 GB | — |
| concurrentKernels | 1 (a BOOLEAN, not a count) | reinforces the out-of-scope call |

Not queryable, from the ISA: `:max-registers-per-thread` **255** (a SCALAR on NVIDIA per D4 —
the list form is specifically for Intel's mode-selectable register file),
`:native-cache-line-size` **128 B**.

**Proposed `h100` builtin:**

```lisp
(def-hardware-profile h100
  :simd-width 32
  :compute-units 114                    ; PCIe.  SXM is 132 — do not copy topology.md's example
  :max-registers-per-cu 65536
  :max-registers-per-thread 255         ; architectural; scalar on NVIDIA (D4)
  :max-total-threads-per-block 1024
  :max-work-group-dims '(1024 1024 64)
  :max-shared-memory-per-block 227KB    ; the OPT-IN cap, not the 48KB default
  :l2-cache-size 50MB
  :native-cache-line-size 128
  :mma-shapes '((16 8 8) (16 8 4) (16 8 16)))   ; (16 8 8) MANDATORY — chap0/1/1.5/2 pass it
```

Toolchain note for future pod sessions: `nvcc` is NOT on `PATH`; it lives at
`/usr/local/cuda/bin/nvcc`.


Phase 0 — COMPLETE 2026-07-28
-----------------------------

### What landed

- **Builtin profiles (D2).**  `bmg` and `h100` are now compiler builtins, registered from
  `register-builtin-hardware-profiles` (called by `register-mma-types`, which
  `initialize-compiler` invokes *after* its `clrhash` of `*hardware-profiles*`).  A user's
  same-named `def-hardware-profile` still WINS, so every existing spec with an inline `bmg`
  is unaffected and needed no edit.  topology.md's long-standing claim that `bmg` is
  predefined is finally true.
- **Inline copies removed** from all three BMG benchmark kernels.  That drift is exactly why
  Phase 4's win initially reached only `intel_prefetch`.
- **Bench driver wired.**  `NVIDIA_HW_PROFILE` / `INTEL_HW_PROFILE` constants replace three
  hardcoded `"bmg"` literals and add the profile to the two NVIDIA compile sites
  (matmul.py:178/179 autobench, :562 fixed-harness), which previously forwarded NO profile at
  all — leaving five consumers dormant on that backend.

### NVIDIA measurement: the profile is behaviourally NEUTRAL on the benchmark path

Measured on the H100 PCIe pod, all five chapters:

| Artifact | With vs without `--hardware-profile=h100` |
|---|---|
| `.ptx` (all 5 chapters) | **byte-identical** |
| generated `_matmul_CUDA.cu` (chap0) | **byte-identical** |
| `_numSMs` occurrences in the launcher | **0** |

Mechanism: `:compute-units` only reaches the launcher through the `:strided` occupancy path,
and the benchmark harness drives these kernels via `--mma-bench` / `--grid-tile`, which
override the grid outright — so that code path is never emitted.  The other four consumers
(workgroup bounds, SLM cap, mma-shape membership, register fit-check) are *validators*: they
accept or reject, they never change codegen.  All five kernels pass them.

**Consequence: a NVIDIA benchmark re-run would measure pure noise, so we did not spend pod
time on one.**  If the compiled artifacts are identical, the numbers cannot move.

So Phase 0's value on NVIDIA is (a) five dormant consumers now actively validating, (b) the
wgmma occupancy diagnostic firing on chap3, and (c) unblocking Phase 1 (`:l2-cache-size`
50 MB) and Phase 3 (`:max-registers-per-cu` 65536), which is where NVIDIA perf change will
actually come from.

### Intel: chap0/chap1 do NOT want large-GRF — the model is right to stay silent

Both now resolve the full builtin `bmg` (with the `(128 256)` modes), yet neither triggers a
mode change: their `32x32` C-tile is 1024 elements = **exactly 128** registers, equal to the
default allocation, so `%spv-decide-register-mode` correctly says nothing.

That looked like an undercount at first — both kernels measurably spill (2560 B / 2752 B) from
transients the model does not track (SLM-staged operand fragments), so a naive reading says
"they'd benefit from large-GRF too."  **Measured, they do not:**

| Kernel @1024 | default | large-GRF forced | |
|---|---:|---:|---|
| `chap0_sync` | 1.66 TFLOPS | 1.03 | **−38%** |
| `chap1_async_linear` | 0.95 TFLOPS | 0.85 | **−11%** |

Large-GRF halves threads-per-EU, and these two are occupancy-bound (SLM staging, many
threads) rather than register-bound like the register-resident prefetch kernel.  So:

- The "free money" hypothesis from the previous session was **wrong**, and measuring first
  avoided shipping a regression.
- A global "always request large-GRF" flag would have cost chap0 **38%**.  The
  demand-driven, compiler-computed decision (D4 / Phase 4) is vindicated — this is precisely
  the case it exists to get right.
- No model change is warranted.  Counting transients would push these two over 128 and
  wrongly select the larger mode.

### Regression: clean

941/941 E2E, 253/253 unit, 210/210 negative — with the builtins live.  Confirmed no
profile-name collisions: 130's negatives use `bogus` / `tiny` / `big` / `nomem` / `test-gpu`.


### Pod run 2026-07-28 — 14 spec FAILURES, all environmental (NOT regressions)

Every failing spec shares one directive: `COMPILE-WITH[… --ir-target=spv]`.  Root cause chain:

1. `.gitignore` excludes `bin/` wholesale, so the 41 MB `llvm-spirv` translator is never
   checked in and a fresh pod clone does not have it.
2. `./bin/crisp-compile --ir-target=spv …` therefore dies with **exit 127** (command not found)
   on the llvm-spirv invocation.  Confirmed directly on the pod.
3. `run-spec-compile-with-pass` (run-specs.lisp:642) does **not** honor `SKIP_SPIRV_TESTS`,
   unlike `run-single-spec-pass` (line 717) which does.  `SKIP_SPIRV_TESTS` was not set on the
   pod either way.

So SPV-targeted specs hard-FAIL on a CUDA-only box where they should SKIP.  This is the same
defect as the remembered "BMG tests are somehow being run on NVIDIA" — SPV/Intel specs running
where there is no SPIR-V toolchain.

144/03 and 144/04 are in this set for exactly this reason, not because of a Phase 4 bug — both
pass locally where `llvm-spirv` exists.

### FIXED 2026-07-28 — auto-detected SPIR-V availability

`spirv-toolchain-available-p` probes `llvm-spirv --version` through the compiler's own
`resolve-tool-executable`, so it honors the same `bin/`-then-PATH search and the
`CRISP_LLVM_SPIRV` override the real compile path uses.  Result cached per runner invocation.
Detection rather than an env var because a var must be remembered on every new pod; probing is
self-correcting.  `SKIP_SPIRV_TESTS` is still honored as an explicit opt-out.

Wired into all FIVE SPIR-V entry points so the harness agrees with itself about what the
machine can do:

| Entry point | Directive | Was |
|---|---|---|
| `run-spec-compile-with-pass` | `COMPILE-WITH[--ir-target=spv]` | no guard → exit 127 FAIL |
| `run-spec-expect-stderr-pass` | `EXPECT-STDERR[--ir-target=spv]` | no guard → exit 127 FAIL |
| `run-single-spec-pass` | `TEST-WITH[--ir-target=spv]` | env var only, no detection |
| `run-spec-with-hoist` (L0) | `TEST-HOIST[L0]` | needs a .spv; only probed for an Intel *GPU* |
| `run-spec-ffi` | `FFI-LINK` + `TEST-WITH[--ir-target=spv]` | env var only, no detection |

**The fifth was found the hard way, and it was my miss.**  I wrote "all four SPIR-V entry
points" on 2026-07-28 and the first full run on a real CUDA-only H100 came back **936/943** —
seven FFI specs (122-ffi x2, 123-ffi-ad x5) failing on the translator's exit 127.  The FFI
harness has its OWN skip path (`run-spec-ffi`, run-specs.lisp:292) which tested
`SKIP_SPIRV_TESTS` alone.  Fixed the same way; verified in both directions locally (present ->
`FFI[spv] PASS`, simulated-absent -> `SKIP`) and then on the pod.

**Final state: 943/943 on the CUDA-only H100, identical to local.**  Worth noting that the
local suite could never have caught this — the machine has a working translator, so the FFI spv
path always ran.  Only the CUDA-only box exercises the skip.

Note the L0-hoist auto-skip on non-Intel hardware **already existed** (endeavor 140
reconcile, run-specs.lisp:1301) and worked correctly on the pod — the 133/10-12 failures came
from their `COMPILE-WITH[--ir-target=spv]` pass, not from the hoist.  So the remembered "that
was fixed a while ago" was right about the hoist and the gap was elsewhere.  The new hoist
guard covers the remaining case (Intel GPU present, translator missing).

Verified both directions:

| | 144 | 142 | 133 | 135 | full suite |
|---|---|---|---|---|---|
| translator FORCED MISSING (`CRISP_LLVM_SPIRV=/nonexistent`) | 5/5 | 9/9 | 10/10 | 10/10 | — |
| translator present (normal local run) | — | — | — | — | **941/941, 0 spurious skips** |

Plus 253/253 unit and 210/210 negative.  The "forced missing" column is the pod's condition
reproduced locally; before the fix those same filters gave 5/5, 6/9, 1/10, 5/10.


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


Phase 1 — IMPLEMENTED 2026-07-28.  It removes an L2 CLIFF.
---------------------------------------------------------

### The headline

Linear tile order has a **performance cliff** when the problem outgrows L2.  Grouping removes
it.  B580, `intel_prefetch`, tf32/fast, `MMA_CORRECT` throughout:

| Size | working set | linear | grouped (W=4) | |
|---|---|---:|---:|---|
| 1024 | 12.6 MB — **fits** 18 MB L2 | 23.63 TFLOPS | 23.18 | −1.9% |
| 2048 | 50 MB — **exceeds** L2 | **17.16** | **27.96** | **+63%** |

Read the columns vertically: under **linear**, going 1024 → 2048 makes the kernel *slower*
(23.6 → 17.2) even though a bigger GEMM has strictly better arithmetic intensity — that is the
cliff, the moment A/B stop being re-read from L2.  Under **grouped** the scaling is restored
(23.2 → 28.0).  Phase 1 is not a few-percent tuning win; it is the difference between having
that cliff and not.

### Width sweep at 2048 — the win is essentially BINARY

| W | 1 (linear) | 2 | 4 | 8 | 16 |
|---|---:|---:|---:|---:|---:|
| TFLOPS | 17.14 | 27.62 | 27.89 | 26.87 | 28.05 |

Any `W >= 2` captures nearly all of it: grouped-vs-linear is worth ~60%, the width *within*
2..16 only ~4%.  W=8 sits in a reproducible local dip (confirmed at 1024 too: W=4 23.2 vs
W=8 22.4), so `*tile-visit-max-strip-width*` was moved from 8 to **4**.

**This inverts the theory-first conclusion.**  Before measuring, the algebra said the optimal
width is `sqrt(R · tile_M / tile_N)` with R the resident block count — i.e. that Phase 1 needed
Phase 3's occupancy model to pick W properly.  Measured, the width barely matters; only
*engaging at all* does.  So Phase 3 is a refinement of Phase 1, **not** a prerequisite.

### Implementation

`%expand-tile-stride-form` now chooses between the untouched linear expansion and
`%expand-tile-stride-swizzled`.  The swizzled form replaces the per-axis nest with ONE
grid-strided loop over the flat tile index, delinearized through a W-wide column strip
(`tpg = W·nt_rows`, `grp = tid/tpg`, `gc = min(W, nt_cols − grp·W)`, `row = idg/gc`,
`col = grp·W + idg mod gc`).

That mapping is a **bijection** over `[0, nt_rows·nt_cols)`, which is why coverage survives any
grid size — including oversubscribed or under-dispatched ones, where the cheaper "swizzle the
per-axis start" trick would double-visit or miss tiles.  Bijectivity holds because every strip
but the last has exactly `tpg` tiles and the partial strip is last, so `tid/tpg` never
mis-assigns.

Scope: rank-2 `tile-stride` with a compile-time `(M N)` size-list and an active profile
supplying `:l2-cache-size`.  Everything else falls through to the original expansion, which is
why this hooks the short `%expand-tile-stride-form` rather than rewriting the 100-line loop
builder.  Per D1 there is NO new kernel syntax; `CRISP_TILE_VISIT=linear|grouped|grouped:N` is
the bisect/sweep hatch and should graduate to `--tile-visit=`.

### Known cost, stated plainly

Grouping costs ~2% when the working set already fits L2, and the compiler cannot know the
runtime problem size, so that is unavoidable without a runtime switch.  Net strongly positive
(−2% below the cliff, +63% above it), but it is a real trade, not free.

### Regression: clean

941/941 E2E, 253/253 unit, 210/210 negative — with the swizzle live, which changes the emitted
loop for every rank-2 tile-stride kernel under a profile.  Notably that includes the on-metal
BMG `MMA_CORRECT` specs (133/10-12, 135/04, 135/08, 135/09, 142/01, 142/12), so the reordering
is hardware-verified correct, not merely compile-clean.

### H100 confirmation attempt (2026-07-28) — NEUTRAL at 2048, unlike BMG

Same sweep on an H100 PCIe, via `matmul.py`'s autobench path (identical flags, per-chapter
`--grid-tile`, `nvcc -arch=sm_90a -fopenmp`).  All rows `MMA_CORRECT`.

| Chapter @2048 | linear | W=2 | W=4 | W=8 | W=16 | best vs linear |
|---|---:|---:|---:|---:|---:|---:|
| chap1.5_async_block | 36.95 | 36.77 | 36.68 | 37.63 | **38.19** | +3.4% |
| chap2_pipelined_block | **38.52** | 38.42 | 38.31 | 38.36 | 38.15 | −0.3% |
| chap3_wgmma | 123.85 | 125.83 | 125.21 | **127.42** | 126.99 | +2.9% |

**Essentially neutral** (−0.3% .. +3.4%) where BMG showed +63%.  Two things follow.

First, **2048 is the wrong size on this device.**  Three fp32 matrices at 2048² = 50 MB, and
H100's L2 is 50 MB — this measurement sits exactly AT the cache boundary, whereas BMG's 2048 was
~3x past its 18 MB L2.  The comparable H100 size is 4096 (200 MB, 4x L2).

Second, and more interesting: at 4096 **linear order does not fall off a cliff on H100** —
chap1.5 linear reaches 59.6 TFLOPS at 4096 versus 36.95 at 2048, i.e. it keeps scaling.  On BMG
linear went *backwards* (23.6 → 17.2).  So the BMG cliff is **not** explained by "working set >
L2" alone; H100 pairs a 2.8x larger L2 with far higher HBM bandwidth, and the latter appears to
absorb the re-streaming that strangled the B580.  If that reading is right, tile rasterization is
worth most on **bandwidth-starved** parts, not simply on large problems — which is a more useful
rule than the one we started with, and it argues for keeping the optimization profile-gated
rather than making it unconditional.

Note also that the derived W=4 was never the best pick on H100 (W=8 or W=16 won every chapter),
consistent with 114 SMs giving a much larger resident set than BMG's 20 Xe-cores.  The clamp is
deliberately NOT retuned on this data: fitting a width to a measurement taken at the cache
boundary, where the total effect is ~3%, would be fitting noise.

### H100 at 4096 — the hypothesis is REFUTED, and grouping actively HURTS

| Chapter @4096 | linear | W=2 | W=4 | W=8 | W=16 |
|---|---:|---:|---:|---:|---:|
| chap1.5_async_block | 59.60 | 59.34 | 59.26 | **60.01** | 59.32 |
| chap2_pipelined_block | **55.83** | 54.95 | 55.38 | 54.73 | 54.94 |
| chap3_wgmma | **207.41** | 208.34 | 190.22 | 184.76 | 177.64 |

All `MMA_CORRECT`.  Three conclusions, the first of which kills the prediction:

1. **There is no cliff on H100.**  Linear order keeps scaling right through 4096 —
   chap1.5 goes 36.95 (2048) → 59.60 (4096), chap3 → 207.41.  The predicted 4x-L2 cliff simply
   does not appear.  So "working set > L2" is NOT the mechanism behind the BMG result; H100 pairs
   a 2.8x larger L2 with far more HBM bandwidth, and something in that combination absorbs the
   re-streaming that costs the B580 40% of its throughput.
2. **Grouping is neutral-to-harmful here.**  chap2 is worse at every width.  chap3 degrades
   MONOTONICALLY with strip width: −8.3% at W=4, −10.9% at W=8, **−14.4% at W=16**.  A clean
   monotonic trend across four points is a real effect, not noise.
3. **The chap3 trend has a plausible mechanism.**  Its tile is 64x256 — four times wider than
   chap2's 64x64 — so a W-wide strip spans 256·W columns of C.  At W=16 that is 4096 columns, the
   entire matrix: the "strip" degenerates to the whole width and the mapping contributes pure
   arithmetic while discarding the locality linear order already had.  This is the direction the
   `W = sqrt(R · tile_M / tile_N)` algebra predicts (wide tiles want narrow strips), though not
   the magnitude — for chap3 it suggests ~5 where the measurement wants 1.

### 8192 (16x L2) — the "cliff is just later" hypothesis is REFUTED, with one nuance

The user's reading was that H100 is simply far more powerful, so its cliff sits at a larger
size rather than being absent.  Tested at 8192, where the working set is 800 MB = **16x** the
50 MB L2 — against BMG, which fell off at only **2.8x** its 18 MB.

| Chapter @8192 | linear | grouped W=4 | |
|---|---:|---:|---|
| chap1.5_async_block (64x64 tile) | 63.77 | **65.70** | **+3.0%** |
| chap3_wgmma (64x256 tile) | **230.18** | 190.17 | **-17.4%** |

Both `MMA_CORRECT`.  Linear scaling across all three sizes:

| | 2048 | 4096 | 8192 |
|---|---:|---:|---:|
| chap1.5 linear | 36.95 | 59.60 | 63.77 |
| chap3 linear | 124.83 | 207.64 | **230.18** |

**No cliff, at four times BMG's crossover multiple.**  Throughput rises monotonically and
merely FLATTENS (chap3: +66% then +11%), which is the signature of approaching a roofline, not
of falling out of cache.  So the BMG cliff is not explained by "working set > L2" at any
multiple, and the H100 result is a genuine difference in kind rather than in degree.

**The nuance, which partly vindicates the intuition:** for the SQUARE 64x64 tile, grouping goes
-0.6% at 4096 to **+3.0%** at 8192 — the benefit does grow with size, just asymptotically
rather than as a cliff.  For the 64x256 tile it goes the other way (-8.3% at 4096 to **-17.4%**
at 8192), the monotonic degradation getting worse.  Both are consistent with strip width having
to scale INVERSELY with tile width: a W-wide strip spans `tile_N x W` columns, so a wide tile
saturates the matrix and the grouping degenerates.

Net: the measured-per-machine gate (`:tile-visit-strip-width`, absent on `h100`) remains
correct.  A future refinement could make the width tile-shape-aware rather than per-machine,
which the chap1.5-vs-chap3 divergence at 8192 argues for — but that is a new experiment, not a
conclusion from this data.

#### Measurement note: a 671 MB shell variable

The first 8192 sweep appeared to hang for 15+ minutes on one config, with a `grep` pegged at
94% CPU.  Not a kernel or correctness problem: the generated harness dumps every buffer, so a
single 8192 run emits **671 MB** of text, and capturing that into `$(...)` and regexing it was
quadratic.  Fixed by streaming the binary's output through `grep` instead of capturing it.
Worth remembering before benchmarking any large size through this harness.

### CONSEQUENCE — a live regression, and why the gate is wrong

The gate is "the profile supplies `:l2-cache-size`", and the `h100` builtin supplies it.  So Phase 1
engaged on NVIDIA with the derived W=4 and **cost chap3_wgmma ~8%**.  That is a defect in the
gating, not in the mapping (which is correct and bijective on both vendors — every row above is
MMA_CORRECT).

L2 size is refuted as a predictor: BMG +63% and H100 −14%, both with `:l2-cache-size` present.
Bandwidth-per-FLOP was also considered and does not separate them (B580 ~456 GB/s / ~58 TFLOPS
tf32 vs H100 PCIe ~2000 / ~400 — broadly similar ratios).

**Proposed fix (needs a decision, D4-style):** replace the inference with an explicit measured
machine fact — a profile key `:tile-visit-strip-width <N>`, absent meaning linear.  `bmg` gets 4;
`h100` omits it.  With two devices showing opposite outcomes and no surviving predictor, recording
"this machine wants strip width N" where machine facts live is more honest than a formula that is
wrong half the time.  D1 stays intact: still no kernel syntax, still a profile-level decision.

Nothing shipped is affected — Phase 1 and the builtins are uncommitted.

### NVIDIA benchmark extended to 4096 (2026-07-28) — the ladder's top rung is now 69.5%

Run with the CORRECTED gating (h100 omits `:tile-visit-strip-width`, so linear), `fast`/ftz,
sizes 1024/2048/4096.  `scaled_counts` cubically reduces warmup/iters above 2048 automatically,
so 4096 cost ~1/8 of a full-count run and the correctness check did NOT have to be weakened.

| Chapter | Crisp @2048 | % cuBLAS | Crisp @4096 | % cuBLAS |
|---|---:|---:|---:|---:|
| chap0_sync | 2.6 | 1.3% | 4.0 | 1.3% |
| chap1_async_linear | 4.0 | 2.0% | 6.5 | 2.2% |
| chap1.5_async_block | 36.9 | 18.5% | 59.7 | 20.0% |
| chap2_pipelined_block | 39.2 | 19.6% | 55.8 | 18.7% |
| **chap3_wgmma** | 124.8 | 62.4% | **207.6** | **69.5%** |

cuBLAS scales 199.9 → **298.7** TFLOPS over the same range.

**Correcting an earlier speculation of mine:** having seen chap3 reach 207.4 TFLOPS at 4096, I
noted it exceeded the 199.85 cuBLAS figure REPORT.md carried — and flagged that as
apples-to-oranges since that figure was measured at 2048.  Measured at the SAME size, cuBLAS is
298.7, so Crisp does **not** beat it; it reaches 69.5%.  The caution was warranted and the
cross-size comparison would have been wrong by ~50%.

#### A pre-existing data hazard found while merging

`benchmarks/results/` held **22** NVIDIA `fast`/ftz files for **11** distinct
(chapter, competitor, precision, size) keys — two runs' worth.  `report.py` assigns rather than
reduces (report.py:112) over an unsorted `glob`, so which run won was **arbitrary**, which is
why REPORT.md numbers drifted slightly between regenerations with no code change.  The 22
superseded files were moved to `benchmarks/results/archive-pre-144-phase1/` and replaced by the
11 new ones.

**Still outstanding:** the `ieee`/ftz and `ieee`/preserve sets have the same 22-for-11
duplication.  Left alone deliberately (not this endeavor's data, and no code change touches
them), but they should be deduped or report.py should prefer the newest timestamp per key.

### Methodology note — a bogus first sweep, and why

The first sweep reported 26.8–27.0 TFLOPS for *every* setting including linear, i.e. "the
swizzle does nothing."  Cause: `crisp-compile` resolves `bin/LLVM-C.dll` **relative to CWD**, so
every compile I ran from inside the chapter directory died before doing anything and I
re-measured one stale `.spv` five times.  It looked like a plausible negative result.

Two lessons worth keeping: **check the compiler's exit status** (stderr had been sent to
/dev/null), and **hash artifacts against a known-different control** — the identical md5s were
the tell, and chasing them is what exposed it.  The `tile-visit:` log line now makes the
decision visible so this cannot masquerade as a measurement again.


Phase 1 prerequisite — tile-stride order-dependence survey (done 2026-07-27)
---------------------------------------------------------------------------

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
