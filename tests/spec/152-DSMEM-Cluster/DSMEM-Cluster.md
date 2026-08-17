In this endeavor we'll be adding support for DSMEM and Clusters in hopes of further improving MMA performance.


API PHASES

Expand the Crisp API to support `sync-cluster`, `cluster-size`, `:mode :cluster` and `:multicast true`.  

Proposed order of TDD tests and implementation:

0.  Paper: multicast mbarrier completion; cluster.arrive convergence
1.  (declare (cluster-size ...))  — decl, PTX dims, hoist launch, divisibility, metadata
2.  (load-tile :multicast true), ONE-SHOT — no ring; de-risking spike, on metal
3.  (sync-cluster) fused + split; refusals; cluster-size-1 equivalence on metal
4.  autodiff of sync-cluster (skip-list + backward-side fences)
5.  (make-async-barrier :mode :cluster) — single barrier, remote arrive
6.  (make-async-barrier-ring :mode :cluster) — :arrivals scaling by cluster extent
7.  autodiff of :mode :cluster
8.  widen %warp-spec-check-block-only
9.  autodiff of :multicast — or a refusal that names the reduction
10. MMA realization


TDD SPEC MAP (phases 0-2 drafted)
---------------------------------

| plan step | spec | what it pins |
|---|---|---|
| 0 | `00-verification-findings.md` | two paper questions; **not a spec** — fill in before implementing |
| 1 | `01-cluster-size-minimal.crisp` | declaration parses; PTX carries cluster dims |
| 1 | `02-cluster-size-shape.crisp` | rank-2 shape; axis 0 = rows; rank agrees with `:tile-shape` |
| 1 | `03-cluster-size-metadata.crisp` | EFFECTIVE extent is an assertable artefact |
| 1 | `04-cluster-size-on-metal.crisp` | `cudaLaunchKernelEx` + cluster attr; 2 clusters actually launch |
| 1 | `05-cluster-size-spv-degrade.crisp` | degrades on SPV, **with a diagnostic** |
| 2 | `10-multicast-oneshot-ptx.crisp` | `.multicast::cluster` + mask + leader guard in the PTX |
| 2 | `11-multicast-oneshot-metal.crisp` | the bytes land correctly in BOTH workgroups |
| 1 | `errors/01-cluster-size-derive-from.crisp` | no `:derive-from` — and the message says why |
| 1 | `errors/02-cluster-size-rank-mismatch.crisp` | over-specified rank is an error (under-specified is legal) |
| 2 | `errors/10-multicast-no-cluster.crisp` | `:multicast` without a cluster is a HARD error |
| 2 | `errors/11-multicast-varies-on-cluster-axis.crisp` | coords varying on the cluster axis — the silent-corruption case |

**Four new validators are required** and are real work, not glue:
`validate-ptx-cluster-dims`, `validate-metacrisp-cluster-extent`, `validate-cluster-degrade-warning`,
`validate-ptx-multicast`.

**The pair to keep straight:** rung 05 and `errors/10` pin a deliberate asymmetry —
`cluster-size` on an incapable target DEGRADES with a diagnostic, while an unhonourable
`:multicast` is a COMPILE ERROR.  Launch geometry is harmless on its own; an assertion about a
specific load is not.  Anyone who reads one without the other will file it as a bug.

**Rungs 10 and 11 are a pair too, and neither is sufficient alone.**  A multicast that silently
does not fire is byte-identical in the output, so 11 cannot see it; 10 reads the emitted
instruction.  A pass on 11 while 10 fails means we are measuring a fallback.

Still to draft: steps 3-9 (sync-cluster and its refusals, `:mode :cluster` single + ring,
the three AD steps, and the `%warp-spec-check-block-only` widening).


MMA Realization Phase


PROPOSED CHAPTER LADDER (draft — not yet committed to topology.md)
=================================================================

The current chapters are named after **techniques**, and techniques are vendor-specific — which
is why the split is awkward (`chap1.5`, no `chap4`, `intel_prefetch` unnumbered, both vendors
present only in 0/1/5/6).

Proposal: **number the chapters by the QUESTION each one answers.**  Both vendors face the same
questions; they answer with different hardware, and sometimes one of them cannot answer at all.
The gaps then become *findings* ("Intel has no answer to chapter 6") rather than numbering holes.

| # | The question | NVIDIA technique | Intel technique | NVIDIA API accreted | Intel API accreted |
|---|---|---|---|---|---|
| 0 | Can we compute it on tensor cores at all? | sync tiled MMA `(16 8 8)`, B col-major | sync tiled XMX `(8 16 8)`, B row-major | `make-register-tile`, `mma-accumulate-via-tile`, `load-tile`/`store-tile`, `tile-stride`, `inner-dimension` | same |
| 1 | Can the fetch overlap the math? | `cp.async` | `OpGroupAsyncCopy` | `(make-async-barrier :mode :linear)`, `load-tile :barrier`, `await` | same |
| 2 | Can the fetch itself be cheap? | TMA descriptor (`CUtensorMap`) | register-resident load — global→GRF, no SLM | `(make-async-barrier :mode :block)` | `load-tile` into a register tile |
| 3 | Can several fetches be in flight? | SMEM ring | register ring + prefetch distance | `make-async-barrier-ring :ring-count :arrivals`, `make-scratch-matrix-ring`, `ring-get` | `make-register-tile-ring`, `prefetch-tile` |
| 4 | Can the math stop waiting on bookkeeping? | warp specialization (producer/consumer) | construct works, **pipeline blocked** | `with-warp-specialization`, `signal`, `:initial-state`, `make-register-tile :warps` | `with-warp-specialization` only |
| 5 | Can one instruction do more math? | `wgmma` (warpgroup async MMA) | GRF-bounded tile shape | `make-wgmma-accumulator`, `wgmma-accumulate-via-tile` | `def-hardware-profile :max-registers-per-thread`, `--hardware-profile` |
| 6 | Can we stop refetching shared operands? | cluster + TMA multicast | **no mechanism** | `(cluster-size ...)`, `:mode :cluster`, `load-tile :multicast true`, `sync-cluster` | — |
| 7 | Can we skip the output round trip? | fused epilogue | fused epilogue | `(map-elements! D #'F)` | same |
| 8 | Can that epilogue be arbitrary? | custom activation | custom activation | **— none —** | **— none —** |

Notes on individual rows
------------------------

**Ch 4, Intel.**  Not a dash.  `with-warp-specialization` genuinely works on SPV — 146/01
compiles under `--hardware-profile=bmg --ir-target=spv`, differentiates, and has its gradients
verified on BMG.  What is blocked is the *staging pipeline*, for three bounded reasons:
1. `%warp-spec-check-block-only` (src/analysis/control.lisp) refuses any tile op in a role block
   unless it uses a `:block` barrier.  Its rationale is that a workgroup-collective SLM copy
   deadlocks when only one role's warps enter — which **may be over-broad for Intel's
   register-destination loads**, since a sub-group-scoped load into a register fragment would not
   deadlock the same way.  Worth confirming before calling it a bug.
2. There is no `:block`-equivalent barrier on SPIR-V to hand the producer.
3. The shipped Intel kernel is `local-size 16` = ONE sub-group on BMG, so there is no second warp
   to specialize.  Needs a wider workgroup and the register tile distributed via `:warps` first.

**Ch 5, Intel** is the loosest analogy in the table.  NVIDIA's rung is a bigger *instruction*;
Intel's is a tile-shape sweep bounded by the GRF model (Endeavor 144 Phase 4, 1.55–2.01x on BMG).
Same *question* — more math per unit of overhead — different kind of answer.  Keep or split.

**Ch 8's empty API column is the whole point.**  Chapter 8 adds NO new form: it is chapter 7's
`map-elements!` with an arbitrary user `def-function` instead of a common one.  That is precisely
why Crisp wins there and the vendor libraries do not — cuBLASLt's epilogues are a fixed enum and
oneDNN's post-ops a fixed set, so an off-menu activation costs them a second kernel and a full
HBM round trip.  Zero new API, measured advantage.

**Ch 6 is NVIDIA-only** and stays that way — there is no Intel cluster hardware to argue about.

Two chapters need SPLITTING, and both splits recover measurement we already own
-----------------------------------------------------------------------------

- **`chap3_wgmma` is really chapters 4 AND 5.**  It bundles warp specialization + wgmma + the
  bigger tile, which is why the ladder jumps 18.2% -> 66.6% with no way to attribute it.  The
  numbers to separate them are already in `benchmarks/matmul/README.md`: on plain `mma.sync`
  (no wgmma), ws2 is **2.0x the ring at 1024** and **+6% at 4096**, with `ptxas -v` showing
  250 -> 167 registers/thread.  So warp specialization is the SMALL-SIZE lever and wgmma is the
  LARGE-SIZE lever — a real finding the current structure hides.
- **`intel_prefetch` is really chapters 2 AND 3** — the register-resident load, then the ring
  plus prefetch distance.  Which is why Intel jumps 5.3% -> 82.8% in a single step.

Everything else is a rename: `chap1.5` -> 2, `chap2` -> 3, `chap5` -> 7, `chap6` -> 8.

Open levers this makes visible
------------------------------

- `Subgroup2DBlockLoadINTEL` is **not** a chapter — it is a pending improvement to Intel's
  chapter 2, replacing the `CooperativeMatrixLoadKHR` the loads currently go through.
  (`Subgroup2DBlockPrefetchINTEL` IS shipped and is chapter 3's prefetch.)
- Intel chapter 4, per the three blockers above.
- NVIDIA chapter 6 — this endeavor.

Maintenance consequence
-----------------------

Chapters 7 and 8 are not further rungs; they are **a different measurement on whatever the best
mainloop rung is**.  That is why they read LOWER than chapter 5 today (65.2% / 65.4% vs 66.6%).
So landing chapter 6 obsoletes their numbers — the 4-line cluster diff has to be ported into
both epilogue kernels or the fusion claim stops being comparable to anything.


IMPLEMENTATION LOG
==================

Phase 0 — COMPLETE (2026-08-16).  See 00-verification-findings.md.  All four questions
settled; no design change needed; one secondary source (Colfax) was wrong about which CTA
issues expect_tx and is corrected there.

Phase 1 — front half COMPLETE, hoist half OPEN.

DONE:
- `(declare (cluster-size ...))` parses, validates, and stores NORMALISED 3-axis dims.
- PTX entry points carry `.explicitcluster` + `.reqnctapercluster x, y, z`.
- Refusals: `:derive-from`, non-integer / missing `:set-to`, rank > 3, rank exceeding an
  explicit `:tile-shape`, total extent > 8.
- Degrade path: capability-gated (sm_90+), warns once per kernel, records the effective
  extent.
- Metadata emits BOTH `:cluster-size` (as written) and `:effective-cluster-size` (as built).

Verified: rung 01/02 stamp `2, 1, 1`; rung 03 stamps `4, 1, 1` and reports effective
`(4 1 1)`; the same kernel on default sm_80 stamps nothing, warns, and reports `(1 1 1)`;
SPV likewise.  errors/01 and errors/02 refuse with messages that name the reason.
Regression: 1001/1001 specs, 1001/1001 under --differentiate, 213/213 negative, 291 unit.

STILL OPEN in Phase 1 (rung 04 — the hoist half):
- `cudaLaunchKernelEx` + `cudaLaunchAttributeClusterDimension` in the CUDA hoist.
- The divisibility policy: pad for `:strided`, hard error for `:exact`.  Now well-founded
  rather than a guess — the driver rejects a non-divisible grid per axis with
  `cudaErrorInvalidClusterSize` (measured; see 00-verification-findings.md).
- Needs an H100 to verify end to end.  Batch with rung 11 and step 3.

TWO BUGS FOUND AND FIXED IN MY OWN FIRST CUTS (recorded because both were invisible to the
test suite, which only checks that kernels COMPILE):
1. The cluster attribute was gated on `(eq *target-backend* :ptx)` alone, not on the ARCH.
   A default-arch (sm_80) compile would have stamped `.reqnctapercluster` on a target that
   cannot form clusters -- surfacing only at ptxas or JIT time.
2. `:effective-cluster-size` was re-derived inside `serialize-kernels` from
   `*target-backend*`, which is back to its `:generic` default by the time the metacrisp is
   written.  A correct sm_90 kernel therefore reported effective `(1 1 1)` -- the exact
   "silently degraded" misreading the field exists to prevent, produced by the field itself.
   Fixed by recording what codegen ACTUALLY DID, in the dispatch plist (which is cleared per
   module, so the in-process spec runner cannot leak one spec's answer into the next).
A third: the degrade warning was only reachable on the PTX path, so SPIR-V -- the target with
no cluster hardware at all -- degraded silently.  The call now sits outside the backend `case`.


API SHIFTS (running log, per request)
=====================================

None yet that change the documented surface.  Two candidates from Phase 0 research were
RESOLVED IN FAVOUR OF THE EXISTING DESIGN and need no doc change:

- `:arrivals` scaling under `:mode :cluster` -- the Colfax tutorial implied only a leader CTA
  sets transaction bytes, which would have made the compiler's per-workgroup scaling wrong.
  CUTLASS source shows `is_leader` is a lane-0 check WITHIN each CTA, so every workgroup does
  its own local `arrive_and_expect_tx`.  Design stands.
- The `empty`-ring arrival pattern is ALL-TO-ALL within the multicast group (not leader-only),
  and the scaling factor is the MULTICAST GROUP extent -- the row or column length -- not the
  total cluster size.  Same at `(2 1)`, different at `(2 2)`.  Not yet reflected in
  topology.md's `:arrivals` note; worth adding when step 6 lands.

Known nit, not yet fixed: the degrade warning echoes the NORMALISED dims, so a kernel
declaring `(2 1)` is reported as `(cluster-size :set-to (2 1 1))`.  Harmless but it quotes
source the user did not write; fold when this moves into src/.


PHASE 1 — COMPLETE (2026-08-16)
================================

All five cluster-size rungs and both cluster-size error specs are green.  `ci-stop` now sits
at 152-DSMEM-Cluster, so these run in the suite; the only remaining failures are the three
Phase 2 multicast specs, which are correctly red (not implemented).

Rung 04's hoist code is written and inspected but NOT yet run on hardware — see the
assumption below.

WHAT LANDED BEYOND THE FRONT HALF
- CUDA hoist emits cluster grid reconciliation: pad for `:strided`, hard error for `:exact`.
  Verified in generated C++ for BOTH branches.
- `:effective-cluster-size` threaded from metacrisp into the hoist's dispatch-info.
- Three validators: `validate-ptx-cluster-dims`, `validate-metacrisp-cluster-extent`,
  `validate-cluster-degrade-warning`.

ASSUMPTION TO VERIFY ON THE POD (rung 04)
The hoist deliberately does NOT switch to `cuLaunchKernelEx`.  Crisp bakes the shape into the
PTX (`.reqnctapercluster`), making it compile-time fixed -- the case a plain launch handles,
and the reason CUDA C++ pairs `__cluster_dims__` with ordinary `<<<>>>` syntax.
`CU_LAUNCH_ATTRIBUTE_CLUSTER_DIMENSION` is for setting the shape DYNAMICALLY, which Crisp
does not support (there is no `:derive-from`).  If this is wrong the launch fails LOUDLY with
CUDA_ERROR_INVALID_CLUSTER_SIZE, so it is a safe thing to be wrong about -- but it is an
assumption, not a measurement.

NEW FINDING — backward kernels lose the cluster declaration
A `_grad` kernel generated from a clustered forward kernel carries NO cluster records: its
metacrisp has neither `:cluster-size` nor `:effective-cluster-size`.  The AD transform simply
does not propagate the declaration.

Whether a backward kernel SHOULD inherit the forward's cluster shape is a genuine design
question -- it has different memory traffic and may want a different shape, or none -- but
right now the answer is an accident rather than a decision.  It is owed by steps 4/7/9.
Rung 05 is `SKIP-WITH[--differentiate]` until then, with that reason recorded in the spec.

MORE BUGS FOUND IN MY OWN WORK (all invisible to a passing test suite)
4. `%%` in the hoist's C++ generation.  CL's FORMAT only treats `~` specially, so `%%` reached
   the output verbatim -- producing `(gridX %% _ccx)`, which does not compile.  It hid because
   no spec pairs `:strategy :exact` with a cluster, and the `:strided` branch has no modulus.
   A throwaway probe (`put_temp_files_here/152-exact-cluster-probe.crisp`) now exercises it;
   promote to a real spec.

HARNESS DEFECTS FIXED ALONG THE WAY (pre-existing, not introduced here)
- `run-spec-ptx-binary` forwarded exactly ONE flag from a spec's TEST-WITH list
  (`--ir-target-arch=`) and silently dropped the rest.  A spec asking for
  `[--metadata --ir-target=ptx --ir-target-arch=sm_90]` therefore never got a `.metacrisp`
  written, and its validator failed looking for a file that was never generated.  Nothing
  reported the dropped flag.  `--metadata` is now forwarded too.
- The two runner paths resolve validator names in DIFFERENT packages -- the PTX path in
  `:crisp.spec-runner`, the metadata path in `:crisp.compiler` -- so the same validator name
  resolves in one and not the other depending on which flags a spec carries.  Worked around
  by defining `validate-cluster-degrade-warning` in both, delegating to one shared body.
  Worth unifying properly at some point; it will bite again.
