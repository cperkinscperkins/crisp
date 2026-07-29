In this endeavor we are going to enable Hardware Profile support in the Crisp compiler and possibly also in the hoisting tools.

The documentation for this feature is in .\docs\topology.md .


Framing
-------

Separate *knowing* a key from *consuming* it. Phase 0 makes the compiler know the ENTIRE
canonical key set (parse it, type-check the value, reject typos) so every profile is complete
and typo-safe from day one. Each later phase then adds ONE consumer that actually reads a key.
So: know all keys immediately; consume them in the phase order below.

Only ONE phase touches hoisting / `.metacrisp` — the occupancy / grid-size phase
(`:compute-units`), because that's the only key that drives launch configuration. Everything
else is compile-time validation.

Testing note: form-level negatives (unknown key, bad value) fire at the *definition*, need no
flag, and are cleanly auto-testable in an `errors/` dir. Consumer-level negatives (a bound
exceeded) need the profile SELECTED — i.e. a flag — which the negative runner can't inject.
Fix: teach `FAIL-WITH[--hardware-profile=X]:` to carry the flag (it already handles
`--differentiate` / `--single-pass`). Folded into Phase 1; every consumer phase after needs it.


Phases
------

[x] Phase 0 — `def-hardware-profile` (form + full schema, no consumer)  DONE 2026-07-03
    Parse the form, register the named proplist, establish the canonical known-key set with a
    per-key value grammar (ints; `KB/MB/GB` size-literals for the memory keys; a 3-int list for
    `:max-work-group-dims`; a list of `(M N K)` triples for `:mma-shapes`).
    Unknown key -> error; malformed value -> error; missing key -> fine.
    - Hoisting: no.
    - Test: positive — a valid (even partial) profile compiles clean. Negative — unknown key /
      bad value -> CHECK-FAIL (fires at the definition, no flag needed; put in an errors/ dir).
    - Buildable now: yes.

[x] Phase 1 — `--hardware-profile` flag + first consumer: workgroup bounds  DONE 2026-07-03
    (Harness: built a general `COMPILE-WITH[flags]: PASS | FAIL "substr"` directive — compiles
     via the binary with the flags and asserts the outcome — instead of overloading FAIL-WITH.
     Cleaner, reusable for later consumer phases, and keeps FAIL-WITH's global-flag semantics.)
    Keys: `:max-total-threads-per-block`, `:max-work-group-dims`
    Flag selects a defined profile (builtin or from a passed .crisp) and binds it active.
    Validate the kernel's `local-size` against those two keys. Stub the flag-XOR-topology
    exclusivity rule (the topology half isn't buildable yet, so only the flag half is live).
    - Hoisting: no (pure compile-time validation).
    - Test: positive — TEST-WITH[--hardware-profile=p] on an in-bounds kernel compiles; a
      profile that OMITS the bound compiles even when oversized (proves "missing key -> check
      skipped"). Negative — profile-not-found errors without a flag (auto); bounds-exceeded
      needs the flag-carrying FAIL-WITH.
    - Infra: extend `FAIL-WITH[--hardware-profile=X]:` to apply the flag and expect failure.
    - Buildable now: yes.

[x] Phase 2 — `:max-shared-memory-per-block` (scratch / SLM bounds)  DONE 2026-07-04
    (Hook is at the END of compile-module, not the analysis hook of Phase 1: the implicit
     scratch signature is finalized only after Pass 2.  %hp-kernel-shared-bytes reuses
     generate-implicit-signature + sums like the hoist's compute-total-shared-bytes.
     size-expr is a scalar for vectors (total = size^rank) or a dim LIST for matrices/tensors
     (total = product); symbolic sizes -> skip.  elem bytes: 64-bit -> 8, else 4.)
    Sum a kernel's `make-scratch-*` allocations, validate against the cap.
    - Hoisting: no.
    - Test: in-budget compiles; over-budget -> FAIL-WITH[--hardware-profile].
    - Buildable now: yes (the compiler already knows scratch sizes).

[x] Phase 3 — `:max-registers-per-thread` (register-tile bounds)  DONE by ENDEAVOR 132 (MMA
    fundamentals), not by 130 itself — checkbox corrected 2026-07-27 during endeavor 144's
    audit.
    Sum explicit `make-register-tile` reservations, validate against the cap. Scope to
    EXPLICIT reservations — true register pressure isn't known until ptxas, so this checks
    what the developer explicitly reserved, not the final count.
    - Implemented: `%register-tile-fit-check` (src/mma.lisp:698), called from the
      make-register-tile analyzers (mma.lisp:1097, 1126).  Falls back to
      `*default-max-registers-per-thread*` = 255 when no profile pins the key.  SKIPPED on
      :spirv (the tile is opaque cooperative matrices there).
    - Test: tests/spec/132-mma-fundamentals/07-fit-check-profile.crisp
    - KNOWN GAPS (endeavor 144 findings #2 and #5):
      * `make-wgmma-accumulator` (mma.lisp:1320) does NO register accounting at all — the
        Hopper warpgroup accumulator is entirely outside this check.  144 Phase 2.
      * The :spirv skip means Intel has no GRF model, on the one backend where register
        pressure is the stated binding constraint.  All three BMG benchmark kernels are
        MEASURED to spill (144 results.md).  144 Phase 4.
    - Hoisting: no.

[x] Phase 4 — `:simd-width`  DONE by ENDEAVORS 132/139, not by 130 itself — checkbox
    corrected 2026-07-27 during endeavor 144's audit.
    Originally scoped as warp-specialization divisibility and deferred because
    `with-warp-specialization` did not exist.  It now does (endeavor 139), and `:simd-width`
    acquired a second, more central consumer along the way:
    - Implemented: `%resolve-workgroup-warp-count` (src/mma.lisp:435-446) — the workgroup's
      warp count (local-size / simd-width) that drives register-tile fragment distribution
      and validates the `:warps` participation mask.  Defaults to 32 with no profile.
      `make-register-tile` REQUIRES a knowable SIMD width (see topology.md).
    - Hoisting: no.
    - NOTE: BMG reports subGroupSizes of BOTH 16 and 32 (144 results.md), so on Intel
      `:simd-width` is selecting among hardware-supported options, not recording a fixed
      fact.  Relevant to 144 Phase 4 (SIMD32 halves thread count but doubles per-thread
      GRF pressure).

[x] Phase 5 — `:compute-units`: occupancy / grid-size — HOISTING ENTERS HERE  (CUDA) DONE 2026-07-04
    The first key that drives *launch configuration*: the grid-size heuristic uses the
    profile's compute-units instead of a runtime device query. The metacrisp gains the WHOLE
    active profile (only the selected one, name preserved — same on-need policy as structs /
    aliases; runtime compilation will want the full thing), and the hoist learns "when a profile
    is active, its numbers OVERRIDE the device query" (so a deliberately shrunken profile
    actually takes effect host-side — see topology.md, the "orthogonal / shrunken profile" note).
    - Implemented: metacrisp `(:hardware-profile (:name "X" ...))` top-level form
      (%hp-serialize-active-profile hooked into generate-metadata-for-file); hoist parses it
      (metacrisp-hardware-profile in hoist/common); CUDA emit-launch :strided emits
      `int _numSMs = <compute-units>;` instead of the CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT
      query when a profile is active.  Harness: HOIST-HARDWARE-PROFILE directive forwards
      --hardware-profile to the hoist compile; validate-cuda-hw-profile-grid asserts the literal
      override AND the absence of the device query.  Spec: 11-hoist-compute-units.
    - L0: the metacrisp already carries the profile generically, but the L0 launcher's occupancy
      formula (numSubslices × numEUsPerSubslice × numThreadsPerEU → _hw_threads) has no single
      "compute-units" scalar — the generic→Intel-hierarchy mapping is a separate decision,
      DEFERRED (see below).
    - Test: TEST-HOIST[CUDA] compile-check (local, no metal) proving the grid formula uses the
      profile's compute-units, not a query.  On-metal (RTX) confirmation deferred to benchmarking.
    - Buildable now: yes.


Can't support yet — known keys, consumer deferred
-------------------------------------------------

Parse-and-store from Phase 0 (valid, typo-checked, but inert). Their checks / optimizations
wait for their respective future endeavors:

[x] :mma-shapes             — DONE by ENDEAVORS 132/133 (checkbox corrected 2026-07-27).  TWO
                              consumers now: the shape-membership check in `%check-mma-shape`
                              (mma.lisp:558 — with no profile, `(16 8 8)` is forced), and
                              `%spv-mma-shape` (mma.lisp:70), which takes the FIRST entry as
                              the SPV cooperative-matrix instruction shape so one source
                              picks Intel `(8 16 8)` vs NVIDIA `(16 8 8)` per profile.
                              CAVEAT: first-entry-wins is fragile if a profile ever lists
                              several SPV shapes.  NOT consulted by
                              `wgmma-accumulate-via-tile`, which validates via its own
                              `%check-wgmma-shape` (mma.lisp:1296) — so the m64nNk8 wgmma
                              family is outside profile validation entirely.
[ ] :native-cache-line-size — consumer is `check-coalesce` static analysis (not implemented).
                              (Doc previously called this `:cache-line-size`; the schema key
                              is `:native-cache-line-size`.)  Endeavor 144 scopes it OUT for
                              now — diagnostic rather than perf.
[ ] :l2-cache-size          — no consumer yet.  ENDEAVOR 144 PHASE 1 claims it: profile-driven
                              grouped tile visit order inside `tile-stride` (L2-aware
                              rasterization).  Implicit + profile-gated, no new user syntax
                              (144 decision D1).
[ ] :max-registers-per-cu   — no consumer yet.  ENDEAVOR 144 PHASE 3 claims it: a compile-time
                              occupancy model (resident blocks per CU), replacing the L0
                              hoist's runtime `spillMemSize > 0` 2x derate guesswork.
[ ] :max-concurrent-kernels — consumer is orchestration / scheduling (not implemented).
                              Endeavor 144 scopes it OUT: BMG reports a single compute queue
                              group with numQueues 1, which is not a useful concurrency count.


Shape of the endeavor
---------------------

Phases 0–3 are a clean, fully-local, compile-time-only run (no hoisting, all TDD-able).
Phase 4 is partial. Phase 5 is the one that touches hoisting and the metacrisp, saved for last.
The only infrastructure investment along the way is the flag-carrying FAIL-WITH in Phase 1,
which pays for itself across every consumer phase.
