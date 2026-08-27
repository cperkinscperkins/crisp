# Endeavour 157 — Split Workgroup Barrier

## What and why

`(sync-workgroup)` fuses two things: *"I have arrived"* and *"wait for everyone."* A **split**
barrier separates them, so useful work can sit between:

```lisp
(sync-workgroup :arrive)   ; announce arrival, do NOT block
  ... loads, MMA ...       ; runs while peers catch up
(sync-workgroup :wait)     ; block only if we actually outran them
```

**This is an execution rendezvous, not data movement.** `await` / `signal` track a barrier object
that a DMA engine signals — "these bytes are now visible." A split barrier moves no data and
synchronises no memory; it paces control flow. That is why this extends `sync-workgroup` rather than
`await`, and why the keyword pair matches the `sync-cluster :arrive` / `:wait` sketch already in
`docs/topology.md` — cluster, workgroup and warp are one scope ladder and should read alike.

## The measurement that motivates it

Endeavour 156 found that pacing subgroups improves L1 reuse — SYCL-TLA straddles its whole K-loop
body with `barrier_arrive` / `barrier_wait` (`SPV_INTEL_split_barrier`), which is the "L1Staged" in
`MainloopXeL1Staged`. It synchronises no data; it stops 32 subgroups drifting apart in K so a line
fetched by one is still warm for the others.

A **fused** `(sync-workgroup)` in the K loop, bf16, 32×64 per subgroup, K=32 — the expensive version
of the same idea, measured on an Arc B580:

| subgroups | no pacing | fused pacing | |
|---|---|---|---|
| 4 | 60.3 / 61.0 | **65.0 / 64.3** | +8% @4096, +5% @8192 |
| 8 | 65.5 / 69.4 | 57.8 / 57.1 | −12% / −18% |
| 16 | 63.1 / 62.1 | 51.2 / 52.3 | −19% / −16% |

**The benefit is real and the cost is what kills it.** A fused rendezvous stalls every subgroup until
all arrive, and that cost grows with participant count — so it swamps the gain in exactly the 8–32
subgroup regime the peer operates in. Splitting removes the stall, which is the whole point.

This is a hypothesis, not a promise: the fused numbers show pacing *can* pay, not that the split form
will pay at 8+. Phase 3 is what settles it, and a null result there is a real answer.

## Design

```lisp
(sync-workgroup)           ; fused, ordered — unchanged, still the safe default
(sync-workgroup :arrive)   ; non-blocking announcement
(sync-workgroup :wait)     ; block until all have arrived
```

Lowering, SPIR-V only: `__spirv_ControlBarrierArriveINTEL` / `__spirv_ControlBarrierWaitINTEL`,
with `SPV_INTEL_split_barrier` requested **conditionally**, the way endeavour 156 gates
`SPV_INTEL_subgroup_matrix_multiply_accumulate` — a kernel that never splits must not oblige the
driver to support it.

**PTX is refused, not approximated.** NVIDIA has `bar.arrive` / `bar.sync`, but the semantics are not
the same rendezvous and we have no way to test it here. A refusal naming the backend is honest; a
silent mis-mapping is the failure mode this project has been burned by repeatedly.

## The four static analyses

Taken from the `sync-cluster` sketch in `docs/topology.md`, which enumerated them and then declined
to ship the split form without them. That judgement stands, and it is why these are Phase 2 rather
than an afterthought:

1. **Unpaired or nested `:arrive`** — one window at a time, and it must close.
2. **Divergent placement** — inside `if` / `cond` / a warp-spec role block. The fused forms already
   error on this (`%warp-spec-check-sync`), so the analysis exists and needs extending.
3. **Shared access inside the window** — at cluster scope this was DSMEM peer access; at workgroup
   scope it is SLM. **Easier here**, because SLM access is locally analysable where a peer's DSMEM
   is not.
4. **Returning before the `:wait`** — leaves peers waiting on an arrival that never completes.

Deadlocking a GPU is the failure mode, so all four are Phase 2 and none is optional.

**Status: 1 and 2 are in; 3 and 4 are deferred, deliberately.**

1 is a per-kernel counter — `*split-barrier-depth*`, bound by `internal-def-function` and stepped by
`%analyze-gpu-builtin`. A second `:arrive` sees a non-zero depth and refuses; a `:wait` at depth zero
refuses; a depth still open when the body closes refuses. All three name the other half in the
message, because a pairing error is only actionable if you are told where to look.

2 needed no work at all: `%tlc-check-not-divergent` already fires on `sync-workgroup` before the
phase keyword is examined, so `errors/divergent-split` passed the day it was written.

3 and 4 are **deferred until Phase 3 says whether the feature earns its keep**, and Phase 3 says it
does not (below). Writing safety rails around a mechanism that is measurably not worth using is work
spent in the wrong place. Both remain correct rules and both are still wanted if the split form is
ever put on a shipping path:

- **3** is refusable as stated — the barrier's semantics are `AcquireRelease | WorkgroupMemory`, so
  touching SLM inside the window is exactly the race the split creates. Needs address-space
  resolution at the reference site, which the analyzer does not currently thread through.
- **4** cannot be done with the counter at all. A linear count cannot see an early return between the
  halves; that needs control-flow reachability. **The guard does not fire on that path today**, and
  that is a real hole, not an approximation.

## Phase 3 result — the split barrier works, and pacing still does not pay

Nine kernels, `{4, 8, 16}` subgroups × `{none, fused, split}`, bf16, 32×64 per subgroup, K=32,
everything else held constant. Through `bench_harness_l0.cpp` — one apparatus for all nine, so a
difference between rows is a difference between kernels. Arc B580, TFLOPS at N=4096 / N=8192:

| subgroups | no pacing | fused | split | fused vs none | split vs none |
|---|---|---|---|---|---|
| 4  | 50.1 / 48.8 | **54.4 / 51.0** | 52.6 / 49.1 | **+8.6% / +4.5%** | +5.0% / +0.6% |
| 8  | 51.0 / 47.3 | 53.0 / 48.9 | 51.5 / **49.1** | +4.0% / +3.4% | +1.0% / +3.8% |
| 16 | **55.8 / 51.5** | 47.6 / 44.7 | 54.8 / 50.8 | **−14.7% / −13.2%** | −1.8% / −1.4% |

**The mechanism does exactly what it was built to do.** The fused barrier's cost scales with
participant count — harmless at 4, catastrophic at 16 (−14.7%). The split form removes about ninety
percent of that cost: at 16 subgroups it turns a 14.7% loss into a 1.8% one. The stall was the
expense, splitting removes the stall, and the numbers say so cleanly.

**And it still is not worth using.** At 16 subgroups the best kernel is the one with no barrier at
all. A nearly-free version of an operation that does not help is still an operation that does not
help. Where pacing genuinely pays — 4 subgroups — the *fused* form is the better of the two, because
there the rendezvous was never expensive enough to be worth splitting and the split gives back half
the gain. There is no cell in this table where the split form is the right choice.

So the performance claim in "The measurement that motivates it" is **dead**, exactly as that section
allowed for. The split form ships as a correct, tested, refusal-guarded part of the scope ladder; it
is not a recommended optimisation on this hardware, and `docs/topology.md` should say so.

### The finding that outranks it

`mg16_nosync` — 16 subgroups, 128×256 workgroup tile, K=32, no barrier — reads **55.8 / 51.5**
against the shipped `sec2_top_bf16` kernel's **48.2 / 36.9** measured in the same session on the same
apparatus. That is **+16% at 4096 and +40% at 8192**, and it is a change to a kernel file, not to the
compiler. Banking it is worth more than anything in the table above.

### Unreconciled: these numbers are lower than the ones this endeavour was scoped against

The fused-pacing table in "The measurement that motivates it" records `mg8` at 65.5 / 69.4 without
pacing. The same source file, unchanged in git, now measures **50.9 / 47.0** — three runs each,
spread under 1%, so this is not noise.

The control rules out the apparatus and the machine only *partly*: the shipped bf16 kernel reads
36.85 at 8192 against 36.6 recorded, which agrees — but 48.2 at 4096 against 56.5 recorded, which
does not. So one control point matches and one does not, and the earlier k-depth figures were
ad-hoc runs whose apparatus was never written down.

**The honest statement is that 69.4 is not reproducible and cannot be explained from what was
recorded.** It is not being carried forward as a baseline. The Phase 3 comparison above is unaffected
— all nine of its cells come from one session, one apparatus, one machine — but the +89% claim from
the K=32 exploration needs re-measuring through the fixture before it is trusted or repeated. This is
[[154-benchmark-drift-confound]] recurring, and the lesson is the same one: an ad-hoc measurement
that is not reproducible through the fixture is not a result.

## Phases

- **Phase 1** — parse + analyse + lower; `01`/`02`/`03` green. SPIR-V emits the split ops, the fused
  form is untouched, and a split kernel is MMA_CORRECT on metal.
- **Phase 2** — DONE for analyses 1 and 2 (one negative spec each, both green) plus the PTX
  refusal. Analyses 3 and 4 deferred with reasons recorded above; 4 is a known hole.
- **Phase 3** — DONE. Split beats fused at 8+ subgroups, decisively at 16 — and neither beats no
  barrier there, so the performance claim is dead as that section allowed for. Numbers above.

## Definition of done

Beyond `plan/definition-of-done.md`: `(sync-workgroup)` byte-identical in emitted IR (regression
guard `02`); the extension requested only when used; every analysis has a negative spec; and the
Phase 3 numbers recorded whichever way they land.
