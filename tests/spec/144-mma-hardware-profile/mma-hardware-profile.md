Endeavor 144 — Leveraging Hardware Profiles in MMA
==================================================

> **Three documents here.**
> - `mma-hardware-profile.md` (this file) — the plan: phases, decisions, status.
> - `results.md` — the lab notebook: every measurement, in the order taken, with the wrong
>   turns left in.
> - **`FINDINGS.md` — the writeup for OUTSIDE readers.**  Portable, vendor-neutral lessons
>   about GEMM tile rasterization, Intel GRF mode selection, and two measurement traps that
>   produced convincing wrong answers.  Start there if you are not us.

Premise: endeavors 132–143 built the MMA stack, and the benchmark ladder now runs
1.3% → 63.6% of cuBLAS (H100) and 12.5% → 86.5% of oneMKL (BMG).  The remaining gap is
partly *information the compiler already has but does not use*.  Hardware profiles
(endeavor 130) were built and then consumed only ad hoc by the MMA endeavors.  This
endeavor makes that deliberate.


Findings — what the profile feeds today
---------------------------------------

| Key | Consumer | Where |
|---|---|---|
| `:simd-width` | warp count for register-tile fragment distribution | mma.lisp:435-446 |
| `:mma-shapes` | SPV instruction shape (first entry) + PTX membership check | mma.lisp:70-80, mma.lisp:558-577 |
| `:max-registers-per-thread` | `make-register-tile` fit check (NVIDIA only) | mma.lisp:698-713 |
| `:max-shared-memory-per-block` | scratch/SLM cap | hardware-profile.lisp:225 |
| `:max-total-threads-per-block`, `:max-work-group-dims` | local-size bounds | hardware-profile.lisp:157 |
| `:compute-units` | CUDA hoist `_numSMs` literal | hoist-cuda/main.lisp:1296 |

**Idle keys:** `:max-registers-per-cu`, `:l2-cache-size`, `:native-cache-line-size`,
`:max-concurrent-kernels`.

Two things jumped out.  First, only the Intel kernels carry a profile, and
`matmul_bmg_prefetch.crisp:1` sets exactly two keys — `:simd-width` and `:mma-shapes` —
because `prefetch-tile` hard-requires a profile (mma.lisp:241).  The NVIDIA chapters pass
none, so five consumers there run on silent defaults (warp-size 32, 255-register budget,
`(16 8 8)` forced).  Second, 130's own plan doc is stale: it marks Phase 3 and Phase 4
not-done, but the MMA endeavors implemented both along the way.


What's being left on the table
------------------------------

**1. `:max-registers-per-cu` — no occupancy model at all.**  Today the register check asks
"does this tile fit in one thread?" (a spill question).  It never asks "how many blocks fit
per SM?" — the performance question.  With `:max-registers-per-cu` (65536 on H100) +
`:max-shared-memory-per-block` + local-size, that is computable at compile time.  Note the
L0 hoist currently compensates by derating occupancy 2x *at runtime* when
`spillMemSize > 0` (hoist-l0/main.lisp:561-562) — we detect register pressure host-side,
after the fact, when a profile would have told us at compile time.

**2. wgmma accumulators sit entirely outside the register model.**
`%register-tile-fit-check` is only called from `make-register-tile` (mma.lisp:1097, 1126);
`analyze-make-wgmma-accumulator` (mma.lisp:1320) does no register accounting whatsoever.
That is the exact form chap3 is built on — our best NVIDIA kernel, the 63.6% one.  Its
`(64 256)` D is 128 f32 regs/thread for the accumulator alone, and the N-sweep
(128/192/256) is the main lever there.  Right now that sweep is pure empiricism; the
profile would make it arithmetic.

**3. `:l2-cache-size` → tile visit order.  The biggest one.**  `tile-stride` maps
workgroup→output tile linearly (row-major over tiles).  CUTLASS/cuBLAS group that mapping
into column strips so concurrently-resident blocks share A row-blocks and B col-blocks and
hit L2 instead of re-streaming HBM.  The optimal strip width is a function of exactly
(L2 bytes, tile bytes, resident block count).  Crisp owns the grid→tile mapping inside
`tile-stride`, so this needs no kernel edit on either vendor.  Known to be worth
several-to-15% at 2048–4096 for tf32 GEMM; helps BMG too.

**4. Ring depth from the SLM budget.**  chap2 uses 8 KB of H100's 227 KB — 3.5%.  The depth
is a hand-written literal that topology.md notes must be *repeated* because Crisp has no
constant form.  A profile-aware `:ring-count :max` is straightforward.  Caveat: 138
measured a pipelining/occupancy crossover (-6% at 4096), so the profile's job is to *bound
and report* the tradeoff, not blindly maximize.

**5. Intel's last mile: the SPV register model is a hole.**  `%register-tile-fit-check`
explicitly skips `:spirv` ("the driver owns register residency") — yet the Intel arc's own
doctrine in topology.md is "Register Pressure is the Only Limit," with pipeline depth
bounded by GRF.  So on the one backend where register pressure is the *stated* binding
constraint, we have zero compile-time model.  Plausible candidate for BMG's last 13.5%.

**6. `:compute-units` on L0** — hoist-l0/main.lisp:550-554 defers the generic→Intel-hierarchy
mapping "until we actually benchmark on BMG."  143 did that, so the decision is now
informed.  Lower MMA priority since 143 found exact tile cover beats occupancy for tiled
kernels.

**7. `:native-cache-line-size` → `check-coalesce`.**  Diagnostic, not speed.  Relevant to
the epilogue store (`store-tile` of a register / wgmma accumulator to global).  Stretch
goal; see Out of Scope.


Decisions taken up front
------------------------

**D1 — No user-facing key for tile visit order (settled 2026-07-26).**  Considered
`:rasterize` / `:visit` on `tile-stride`.  Rejected: the production taxonomy collapses to
ONE family.  Linear row-major (today), linear column-major, and grouped-strip swizzle are
all the same family — grouped with width W, where **W=1 degenerates to linear** — and W is
an integer *derived* from `:l2-cache-size`, not chosen by the user.  (Morton/Z-order is the
only genuinely different option; it is parameter-free but costlier to compute and no better
for 2-D GEMM tiles.)  A one-value enum is worse than no key.

Critically, `tile-stride`'s contract is **coverage, not order** — it guarantees every tile
is visited, never that consecutive workgroups get consecutive tiles.  So changing the order
is *within* the existing contract: a doc clarification, not a new surface.

- The A/B switch is **`--hardware-profile` itself**: no profile → no L2 size → keep the
  current linear order; profile → derived strip width.  Same kernel, compiled twice.
- Escape hatch for bisecting is a **compiler flag** (`--tile-visit=linear|grouped`), not
  kernel syntax — a debugging tool, never language surface.
- If a kernel-level knob is ever genuinely wanted, the name is `:visit` (not `:rasterize`).
- Exact swizzle may be target-dependent.

**D2 — Profile library: split by purpose.**  Spec tests keep MINIMAL inline
`def-hardware-profile` forms — they test the *consumer*, and 130 already deliberately tests
"missing key → check skipped" (10-slm-partial-skips).  Benchmarks get REAL, COMPLETE
profiles as compiler **builtins** (`bmg`, `h100`), because a benchmark's claim is "this is
what the machine actually is."  This also settles a doc lie: topology.md already advertises
`bmg` as predefined, which is currently untrue — nothing is builtin today, and the bench
kernel defines a 2-key `bmg` inline.

**D3 — Occupancy findings WARN, they do not error.**  Every existing profile consumer
errors.  Occupancy is not a correctness bound, so erroring would break kernels that work
today.  Use `EXPECT-STDERR[flags]:` (endeavor 126) to test the warnings — do NOT build
`CHECK-WARN` for this (still unimplemented; tests.md:248, scramble.md:1050/1068).

**D4 — Schema changes are allowed, and land as 130 tests.**  If `:max-registers-per-thread`
must split or gain backend-dependent units (see Phase 4), update
`*hardware-profile-schema*` and add/update tests in `tests/spec/130-hardware-profile/`,
not here.


STATUS 2026-07-28 (morning session — ALL PHASES COMPLETE)
---------------------------------------------------------

**All six phases are done.**  Phase 0 (builtin queried profiles + bench wiring), Phase 1
(grouped tile visit order), Phase 2 (wgmma register accounting), Phase 3 (register-occupancy
diagnostic — RE-SCOPED), Phase 4 (Intel GRF mode selection), Phase 5 (SLM utilization reporting
— RE-SCOPED), Phase 6 (`:compute-units` on L0).

Two phases were deliberately RE-SCOPED during the unattended session, under standing
authorization to decide and document.  Both are reversible; rationale is in `results.md` and in
the overlay block comments:

- **Phase 5** was `:ring-count :max` (auto-pick the deepest ring that fits SLM).  Not shipped:
  endeavor 138 already measured a pipelining/occupancy crossover on that exact axis, Phase 4
  measured that more-of-a-resource can cost -38%, and Phase 1 measured that occupancy REASONING
  got the sign wrong twice.  Ships as SLM utilization reporting — the plan's own "bound and
  report, do not blindly maximize".
- **Phase 3** was a full occupancy model feeding Phase 1's strip-width formula.  That formula
  was retired by Phase 1's measurement, and the SLM half needs a new schema key.  Ships as a
  register-side occupancy diagnostic using only existing keys.

### Cross-cutting, also done

- `run-on-pod.sh` hardened: apt reachability preflight + mirror fallback + timeouts.  Bootstrap
  went from ~2 hours (hung on an unreachable Ubuntu mirror) to **~7 minutes, all green**.
- `report.py` made **deterministic**: files are processed oldest-first so the newest run wins
  per key, instead of `glob` order deciding arbitrarily.  Verified byte-identical across three
  regenerations.  This is why REPORT.md numbers used to drift with no code change; the `ieee`
  duplicate sets are now harmless and your data was left untouched.
- Hardware-profile query tools promoted to `scripts/hw-profile/` with a README explaining what
  each answers and, for the kernel probe, why `spillMemSize > 0` is NOT an instruction to widen
  the register file.

### Validated on real hardware

| Suite | local (BMG box) | H100 pod (CUDA-only) |
|---|---|---|
| E2E specs | **943/943** | **943/943** |
| Unit | 253/253 | — |
| Negative | 211/211 | — |

The pod run matters independently: it is the only machine that exercises the SPIR-V *skip*
paths, and it caught a fifth un-wired entry point (the FFI harness) that the local suite
structurally cannot see.

### Still open for you

- **`CRISP_TILE_VISIT` should graduate** to `--tile-visit=linear|grouped|grouped:N`.  Env var
  only because a real flag needs `main.lisp` surgery.
- ~~The 8192 cliff question~~ **ANSWERED**: no cliff at 16x L2 (linear keeps scaling,
  230.18 TFLOPS at 8192).  But the data added a nuance worth a future experiment — grouping's
  sign depends on TILE SHAPE (+3.0% for a 64x64 tile at 8192, -17.4% for 64x256), suggesting
  strip width should scale inversely with tile width rather than being purely per-machine.
- The overlay blocks are all tagged with their `src/` destinations for when you apply them;
  three note that they are folded into an existing hook only to avoid redefining
  `compile-module` / `initialize-compiler`.

Net measured effect, BMG @2048: **8.37 -> 28.01 TFLOPS (3.35x)**, no kernel source change.
NVIDIA: the same phases are behaviourally neutral (Phase 4 is SPV-only; Phase 1 is gated off by
measurement), and the ladder now reaches **69.5% of cuBLAS at 4096**.

Suites green at this state: 943/943 E2E, 253/253 unit, 211/211 negative.

### Decisions still needing you

- **Phase 3 needs a schema decision** and is therefore NOT started.  A real occupancy model wants
  resident-blocks-per-CU, which needs shared memory per *CU* — `:max-shared-memory-per-block` is
  per-block (227KB) and the per-SM figure (228KB on H100) is a different quantity.  That is a new
  key, i.e. a D4-class decision, so it waits for you rather than being invented unattended.
  Phase 1's measurement also removed Phase 3's original justification (width turned out not to
  matter), so its remaining value is diagnostic — worth re-scoping before building.
- **`ieee` result duplication**: `benchmarks/results/` still holds 22 files for 11 keys in each
  `ieee` set, so those REPORT.md tables are nondeterministic (report.py assigns over an unsorted
  glob).  The `fast`/ftz set was fixed; the `ieee` sets are your data and untouched.
- **Pod script robustness** (offered, not done): `run-on-pod.sh` has no apt timeout — a pod with an
  unreachable default mirror hangs indefinitely — and `matmul.py` invokes `nvcc` bare although
  these images keep it at `/usr/local/cuda/bin`.  Both cost real time this session.
- **`CRISP_TILE_VISIT` should graduate** to a `--tile-visit=linear|grouped|grouped:N` flag.  It is
  an env var only because that needed no `main.lisp` surgery.


Phases
------

### [x] Phase 0 — profiles exist, and the flag reaches the benchmarks.  DONE 2026-07-28

`bmg` + `h100` are compiler BUILTINS, both queried from real devices (B580 2026-07-27,
H100 PCIe 2026-07-28).  Inline copies removed from the three BMG benchmark kernels; bench
driver wired via `NVIDIA_HW_PROFILE` / `INTEL_HW_PROFILE` constants.

MEASURED ALONE, as the plan required — and the answer is that on NVIDIA the profile is
**behaviourally neutral on the benchmark path**: `.ptx` and the generated launcher are
byte-identical with and without it, because `:compute-units` only reaches the launcher
through the `:strided` occupancy path and `--mma-bench` overrides the grid outright.  So no
re-sweep was needed (identical artifacts cannot produce different numbers), and Phase 0's
NVIDIA value is validation + unblocking Phases 1 and 3.

Also settled a wrong hypothesis: chap0/chap1 do NOT want large-GRF (forcing it costs 38% /
11%), so the Phase 4 model is correct to leave them in the default allocation.  Details in
`results.md`.


There is currently NO NVIDIA profile anywhere, and the CUDA bench path cannot forward one:
`scripts/crisp_bench/matmul.py:178` and `:562` pass `--ir-target-arch=sm_90` but no
`--hardware-profile`, while the Intel path hardcodes `=bmg` (matmul.py:269-270, 408).

- Mint complete builtin `h100` and `bmg` profiles (per D2).
- Wire `--hardware-profile` through the CUDA bench driver; parameterize the Intel one.
- **HARD CONSTRAINT:** `h100`'s `:mma-shapes` MUST include `(16 8 8)` or chap0 / chap1 /
  chap1.5 / chap2 fail instantly at `%check-mma-shape` (mma.lisp:558).  Verified safe:
  `wgmma-accumulate-via-tile` validates via its own `%check-wgmma-shape` (mma.lisp:1296)
  and never consults `:mma-shapes`, so chap3's `(64 256 32)` is unaffected.
- **Measure this phase on its own.**  Switching a full profile on activates FIVE dormant
  consumers at once — including `:compute-units` replacing the device SM query in the CUDA
  launch grid (hoist-cuda/main.lisp:1296), which changes dispatch geometry.  143 showed
  dispatch geometry is worth up to 7.6x.  If Phase 0 is folded in as a silent prerequisite
  to Phase 1, every later before/after number is contaminated.
- **Regression gate:** full spec + negative + unit suites here, not just at the end.
  Baseline from 143: 936/936 E2E, 253 unit, 209 negative.

### [x] Phase 1 — `:l2-cache-size` → grouped tile visit order  DONE 2026-07-28

RESULT: **+63% at 2048 on BMG** (17.16 → 27.96 TFLOPS), MMA_CORRECT.  It removes an L2 CLIFF —
under linear order the kernel gets *slower* from 1024 to 2048 (23.6 → 17.2) despite better
arithmetic intensity; grouped restores the scaling (23.2 → 28.0).  Costs ~2% at sizes that
already fit L2, which is unavoidable without runtime size knowledge.

Width sweep says the win is essentially BINARY (any W>=2 captures ~60%; width within 2..16 is
worth ~4%), so **Phase 3 is a refinement here, not a prerequisite** — the opposite of what the
theory predicted.  Clamp fitted to 4.  Implemented as a bijective linearize→strip→delinearize
mapping so coverage holds for any grid.  Details + the methodology post-mortem in `results.md`.

Still open: confirm on H100 (more SMs ⇒ larger resident set ⇒ possibly a wider strip), and
graduate `CRISP_TILE_VISIT` to a real `--tile-visit=` flag.

### [~] Phase 1 (original plan text, kept for the record)

Per D1: implicit, profile-gated, inside `tile-stride`.  Derive strip width from L2 bytes,
tile bytes, and resident-block count.

- **Order-dependence survey first.**  `tile-stride`'s contract is coverage, not order, but
  a body with cross-tile *FP* side effects (atomic accumulate into a scratch cell) will
  change bit-wise under reordering.  Survey the 61 `tile-stride` kernels; cheap insurance.
- Measurement: L2 effects only manifest when the working set exceeds L2 (50 MB on H100) —
  that is 2048–4096.  A spec-dir hoist test CANNOT show it (harness allocates dim-extent 4;
  small sizes fit L2 entirely).  So the spec test proves **correctness preserved + the
  grouped mapping present in the PTX/SPV**; the NUMBERS come from `benchmarks/matmul` at
  ≥2048.
- Docs: topology.md `tile-stride` — state the coverage-not-order contract explicitly and
  document the profile-driven visit order.

### [x] Phase 2 — wgmma register accounting (finding #2)  DONE 2026-07-27

Done FIRST (ahead of Phase 1) because it is the smallest isolated change and doubles as a
live-fire check of the profile plumbing.  Compile-time only — no perf measurement.

- `analyze-make-wgmma-accumulator` now runs `%wgmma-acc-fit-check`: N/2 f32 registers per
  thread, × 128 threads/warpgroup.
- Two tiers rather than warn-only: hard overflow ERRORS (mirroring
  `%register-tile-fit-check` — the accumulator cannot fit, so the kernel cannot work), high
  occupancy cost WARNS (D3).  The error tier turns out to be reachable only under a shrunken
  profile, since `%check-wgmma-shape` caps N at 256 → 128 regs < the 255 default.
- Landed as an APPEND in `overlays/crisp-compiler-overlay.lisp`, marked `;; src/mma.lisp`.
- Regression clean: 938/938 E2E, 253/253 unit, 209/209 negative.
- Full detail + manual verification transcript in `results.md`.

### [ ] Phase 3 — `:max-registers-per-cu` → the occupancy model (finding #1)

- Compute resident-blocks-per-SM at compile time from `:max-registers-per-cu` +
  `:max-shared-memory-per-block` + local-size + accounted register use.
- Warn on low occupancy (D3).
- **Precedence question to settle:** `:occupancy` (143's grid multiplier), `:compute-units`,
  and this derived resident-block count all now bear on the launch grid AND on Phase 1's
  strip width.  Define which wins where before implementing, or they will fight.
- Feeds the hoist: replaces the runtime `spillMemSize > 0` 2x derate guesswork with a
  compile-time number.

### [x] Phase 4 — Intel GRF model (finding #5)  DONE 2026-07-27  ← PROMOTED, ran 2nd

RESULT: **1.55–2.01x on BMG, end-to-end, all MMA_CORRECT** (256: 2.52→4.08, 512: 9.06→14.03,
1024: 11.61→23.33 TFLOPS).  Mechanism proven by experiment BEFORE any compiler code was
written; then implemented in 4 steps (schema/D4, accounting, metacrisp, hoist pBuildFlags).
Regression 941/941 + 253 + 210.  Full detail in `results.md`.

D4 resolved (user chose option B): `:max-registers-per-thread` takes a scalar OR an ascending
list of selectable modes.  Register WIDTH stays a backend fact, not a profile key.

Still open from this phase: the `:simd-width` 16-vs-32 lever on Intel (BMG reports both) is
untouched — SIMD32 halves thread count but doubles per-thread GRF pressure.  Worth a sweep
now that the demand model exists to predict it.



**Promotion case (measured 2026-07-27, see results.md).**  This phase was scoped as a
"plausible candidate for BMG's last 13.5%."  It is now a **measured defect**: all three BMG
benchmark kernels spill registers — `intel_prefetch` 1792 B, `chap0_sync` 2560 B,
`chap1_async_linear` 2752 B — against a believed 4096 B GRF.  The L0 hoist's
`spillMemSize > 0` 2x occupancy derate has been firing on every one of them, which is why
143 recorded `_hw_threads=640` on a card whose undreated formula gives 1280.

That gives the phase a mechanism AND a cheap binary success metric: `spillMemSize` back to 0
in `put_temp_files_here/hw-profile-query/kernel-probe.cpp`, and `_hw_threads` recovering
640 → 1280.  Recommend promoting the probe to `scripts/` as that oracle.

Also relevant: BMG reports subGroupSizes of **both 16 and 32**, so `:simd-width` on Intel is
selecting among hardware options, not recording a fixed fact — SIMD32 halves the thread
count but doubles per-thread GRF pressure.  That is a lever this phase should consider.

- **Unit collision to resolve first (D4).**  `:max-registers-per-thread` currently means
  NVIDIA 32-bit registers, max 255.  Intel GRF is 128 (or 256 large-GRF) registers of
  **32 bytes each** — so a BMG profile saying `128` reads as "tighter than NVIDIA" rather
  than "4 KB/thread."  Decide: backend-dependent interpretation, or a distinct key.
- This is a NEW accounting function, not a tweak: `%register-tile-fit-check`'s
  `regs-per-frag 4` is NVIDIA-specific, and the SPV path holds opaque coop matrices.  Model
  bytes per coop operand × ring depth.
- Possible stretch: drive large-GRF mode selection as a SPIR-V execution mode.

### [ ] Phase 5 — `:ring-count :max` from the SLM budget (finding #4)

Per the finding's caveat: bound and report, do not blindly maximize.

### [ ] Phase 6 — `:compute-units` on L0 (finding #6)

Decide the generic→Intel-hierarchy mapping (`:compute-units` vs numSubslices / Xe-cores /
a distinct key) now that 143's BMG data exists.  Independent of every other phase.


At each phase
-------------

- [ ] if appropriate, write TDD spec tests.
- [ ] write BEFORE and AFTER measurements in this directory, even where existing benchmarks
      already cover it.  Record in `results.md` here (not in test preambles — they drift).
      Simple is fine: one precision, a couple of sizes.  **But see each phase's
      measurement note** — some phases are compile-time-only (nothing to measure), and some
      cannot be measured by a spec test at all (Phase 1 needs ≥2048 via the benchmarks).
- [ ] implement
- [ ] measure the AFTER.  record.
- [ ] if appropriate, run the matching benchmark to see whether the gain shows there too.
- [ ] if required, update docs (topology.md for any new surface / contract clarification)
      and/or record here the doc change that should occur.


Cross-cutting tasks
-------------------

- [ ] **Fix 130's stale plan doc.**  `tests/spec/130-hardware-profile/hardware-profile.md`
      marks Phase 3 (`:max-registers-per-thread`) and Phase 4 (`:simd-width`) as not-done;
      both were implemented by the MMA endeavors (mma.lisp:698, mma.lisp:435-446).  Update
      the checkboxes and note WHICH endeavor landed each.
- [ ] **Profile accuracy is now load-bearing.**  Once the compiler makes *optimization*
      decisions from a profile (not just validation), a wrong number silently costs
      performance instead of erroring.  Propose `--verify-hardware-profile`: compare the
      declared profile against the device-queried values and warn on mismatch.  Both hoists
      already query device properties (L0: `zeDeviceGetProperties`; CUDA: the SM-count
      attribute), so the plumbing largely exists.  This also guards the deliberately
      "shrunken profile" use case from being mistaken for a typo.
- [ ] **topology.md** — the `bmg` builtin claim becomes true at Phase 0; add `h100`.


Out of scope
------------

- `:max-concurrent-kernels` — no plausible MMA consumer.  Stays parse-only.
- `:native-cache-line-size` / `check-coalesce` (finding #7) — genuinely useful for the
  epilogue store, but diagnostic rather than perf.  Deferred; revisit if Phase 1–5 land
  early.
- Auto-tuning.  topology.md is explicit that Crisp does not auto-optimize kernels.  Every
  phase here either VALIDATES, ADVISES, or makes a decision that is already the compiler's
  to make (D1).  Nothing here chooses an algorithm for the user.
