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

[ ] Phase 2 — `:max-shared-memory-per-block` (scratch / SLM bounds)
    Sum a kernel's `make-scratch-*` allocations, validate against the cap.
    - Hoisting: no.
    - Test: in-budget compiles; over-budget -> FAIL-WITH[--hardware-profile].
    - Buildable now: yes (the compiler already knows scratch sizes).

[ ] Phase 3 — `:max-registers-per-thread` (register-tile bounds)
    Sum explicit `make-register-tile` reservations, validate against the cap. Scope to
    EXPLICIT reservations — true register pressure isn't known until ptxas, so this checks
    what the developer explicitly reserved, not the final count.
    - Hoisting: no.
    - Test: register-tile size drives positive/negative.
    - Buildable now: yes (with that caveat).

[ ] Phase 4 — `:simd-width` (PARTIAL)
    Real consumer is warp-specialization divisibility (workgroup a multiple of
    Σlabels × simd-width) — but `with-warp-specialization` isn't implemented, so the strong
    check is future. A lighter check (warn when `local-size` isn't a multiple of `simd-width`)
    is doable now if wanted; otherwise defer.
    - Hoisting: no.
    - Test: the strong version waits on warp-spec; the light version is a positive/warn check.
    - Buildable now: partial — light check yes, real check deferred.

[ ] Phase 5 — `:compute-units` (+ `:max-registers-per-cu`): occupancy / grid-size — HOISTING ENTERS HERE
    The first key that drives *launch configuration*: the grid-size heuristic uses the
    profile's numEUs instead of a runtime device query. The metacrisp gains the launch subset,
    and the hoist learns "when a profile is active, its numbers OVERRIDE the device query"
    (needed so a deliberately shrunken profile actually takes effect host-side — see
    topology.md, the "orthogonal / shrunken profile" note).
    - Hoisting: YES — the only hoist-affecting phase. Metacrisp change + hoist codegen change +
      the override-the-query policy.
    - Test: TEST-HOIST — assert the generated launcher's grid formula uses the profile's
      compute-units, not a query; ideally on-metal (BMG) showing a shrunken profile changes the
      launch grid.
    - Buildable now: yes, but the heaviest phase — do it last, after the pure-validation phases
      are green.


Can't support yet — known keys, consumer deferred
-------------------------------------------------

Parse-and-store from Phase 0 (valid, typo-checked, but inert). Their checks / optimizations
wait for their respective future endeavors:

[ ] :mma-shapes             — consumer is `mma-accumulate-via-tile` (future MMA / tensor-core work).
                              Validated as a list of (M N K) triples now; the shape-membership check waits.
[ ] :cache-line-size        — consumer is `check-coalesce` static analysis (not implemented).
[ ] :l2-cache-size          — no consumer yet (tiling heuristics are future).
[ ] :max-concurrent-kernels — consumer is orchestration / scheduling (not implemented).


Shape of the endeavor
---------------------

Phases 0–3 are a clean, fully-local, compile-time-only run (no hoisting, all TDD-able).
Phase 4 is partial. Phase 5 is the one that touches hoisting and the metacrisp, saved for last.
The only infrastructure investment along the way is the flag-carrying FAIL-WITH in Phase 1,
which pays for itself across every consumer phase.
