# The MMA Chapter Ladder — proposed structure

Draft, 2026-08-20.  Supersedes the "PROPOSED CHAPTER LADDER" sketch in
`tests/spec/152-DSMEM-Cluster/DSMEM-Cluster.md`.  Nothing here is implemented yet; this is the
thing to argue with before any directory is renamed.

---

## Why the current structure has to change

The chapters are named after **techniques**, and the ladder assumes **accretion** — each rung is
the previous one plus a technique, and goes faster.  Three things have broken that:

1. **Techniques are vendor-specific.**  NVIDIA answers "make the fetch cheap" with a TMA
   descriptor; Intel answers it with a register-resident load.  Same question, different
   hardware, and no shared technique to name a chapter after.  Hence `chap1.5`, a missing
   `chap4`, and `intel_prefetch` sitting outside the numbering entirely.
2. **Some techniques do not always help.**  Endeavour 152 measured TMA multicast at **+15.7% on
   a 64×128 tile and −7% on a 64×256 tile**, on the same hardware, in the same session.  Under
   accretion that is an embarrassment.  It is actually a finding.
3. **The same chapter number means different things per vendor.**  `chap0_sync` is a *non*
   tensor-core kernel on NVIDIA and an XMX coop-matrix kernel on Intel.  The report already
   carries two different labels for one directory.

The fix is to **number chapters by the QUESTION each answers**, and let the answer be whatever it
turned out to be.  Three answer shapes, all legitimate:

- *"Yes, +X%"* — an ordinary rung.
- *"Yes, but only when …"* — multicast.
- *"This vendor has no mechanism"* — Intel and clusters.

Gaps become findings instead of numbering holes, and a future technique that does not pan out has
an honest home instead of quietly disappearing.

---

## Three classes of contender

The single most useful clarification to come out of this discussion.  The current harness has two
categories and needs three:

| class | who | the question it answers |
|---|---|---|
| **Ceiling** | cuBLAS, oneMKL | How fast is this problem, at all? |
| **Peer** | **CUTLASS, SYCL-TLA** | Is Crisp competitive *as a way of expressing kernels*? |
| **Control** | CUDA_Apples, SYCL_Apples | Does Crisp's abstraction cost anything vs hand-writing? |

**Peer is the class currently missing, and it is the one Crisp should be judged by.**  Against
cuBLAS we compare a language to a closed, hand-tuned binary.  Against CUTLASS we compare two ways
of *writing* the same kernel — which is the actual claim Crisp makes.

**Adding Peer also changes what §4 is allowed to claim.**  cuBLASLt and oneDNN expose a FIXED
menu of epilogues, so an off-menu activation genuinely costs them a second kernel.  CUTLASS and
SYCL-TLA do not have that limitation — they monomorphise an arbitrary functor at template
instantiation.  So against a Peer the fused-activation claim is not about capability at all.
See §4.

**Not every section uses every class.**  That is the point:

- A *technique* chapter asks "does the abstraction cost anything?" → **Control only.**
- The *top* benchmark asks "how do we stand?" → **all three.**

This is what fixes the "Crisp chapter 0 is 1% of cuBLAS" problem.  That number is a category
error — chapter 0 is not trying to be cuBLAS — so the early chapters simply do not quote a
ceiling.

### Two ratios, and the first one carries the story

| ratio | meaning | where it belongs |
|---|---|---|
| **vs previous chapter** | what this technique bought | every technique chapter |
| **vs ceiling** | how far there is to go | the top benchmark only |

---

## The five sections

Each section is itself a question; each chapter within it is a smaller one.

| § | Section | The question | Contenders |
|---|---|---|---|
| 1 | **MMA Techniques** | How do you make a matmul fast, one step at a time? | Control, and Crisp vs its own previous chapter |
| 2 | **Top MMA Benchmarks** | How does Crisp actually stand? | Ceiling + Peer + Control, **and compile time** |
| 3 | **Situational Techniques** | What about techniques that only sometimes pay? | Crisp vs Crisp, controlled pairs |
| 4 | **MMA + Activation** | What does fusing an arbitrary activation buy? | cuBLASLt / oneDNN (Ceiling) **and CUTLASS / SYCL-TLA (Peer)** |
| 5 | **Scaling Out** | What if the problem does not fit? | TBD — mostly post-1.0 |

### On ordering

Section 2 contains Crisp's **weakest** number (67% of cuBLAS) and section 4 its **strongest**
(118% of oneDNN on Intel).  Putting activation *after* the top benchmark is deliberate: they are
different claims, both true, and the second is the more interesting product statement.  Today that
118% is the last row of a ladder headlined by 67%, which sells it badly.

---

## Section 1 — MMA Techniques

Contenders: **Control** only, plus each chapter against the previous.  No ceiling.

**A chapter is ONE QUESTION and N ANSWERS — one kernel per vendor.**  This is already how the
directories work (`chap0_sync` holds `matmul.crisp` and `matmul_bmg.crisp`); it just needs a
convention rather than ad-hoc naming.  The chapter's `.md` explains why the answers differ.  This
is precisely what the question-based numbering buys: `chap1.5` existed because a *technique* could
not be shared, but a *question* always can.  Where a vendor has no answer at all (Intel and
clusters), the chapter says so, and that is a finding rather than a numbering hole.

**Devices: ONE representative per vendor in this section.**  A technique chapter measures what the
TECHNIQUE bought, and that delta is a property of the technique, not of the device.  Re-running
eight chapters on H100 *and* H200 multiplies pod cost for almost no information.  §2 is where
per-device numbers matter.  Side effect: §1 stays cheap to re-run on every change, and pod money
gets spent deliberately in §2.

**Architecture-gated chapters print the gate, not a blank.**  wgmma and clusters need sm_90+, so a
chapter may legitimately not run on some hardware.  The table should say *"requires sm_90"* so a
gap reads as a gate rather than a missing measurement.

| # | The question | NVIDIA answer | Intel answer |
|---|---|---|---|
| 0 | Does it run at all? | naive nested loops, no tensor cores | same |
| 1 | Can we reach the tensor cores? | hand-rolled `mma-accumulate-via-tile`, explicit loops | hand-rolled XMX coop-matrix |
| 2 | What does tiling buy? | `matrix-multiply-tile-stride` | same |
| 3 | Can the fetch overlap the math? | `cp.async` | `OpGroupAsyncCopy` |
| 4 | Can the fetch itself be cheap? | TMA descriptor (`CUtensorMap`) | register-resident load, global→GRF |
| 5 | Can several fetches be in flight? | SMEM ring | register ring + prefetch distance |
| 6 | Can the math stop waiting on bookkeeping? | warp specialization | **blocked** — three known reasons |
| 7 | Can one instruction do more math? | `wgmma` | GRF-bounded tile shape |

**Chapters 0–2 are new and are the reason to do this.**  Today the ladder starts at a tiled
kernel, so two real measurements are missing: what the tensor cores buy over scalar code, and what
`matrix-multiply-tile-stride` buys over writing the loops yourself.  Chapter 1 exists specifically
to make the macro land as an obvious simplification rather than as magic.

**Chapter 6, Intel is not a dash.**  `with-warp-specialization` compiles, differentiates and has
verified gradients on BMG.  What is blocked is the staging pipeline, for three bounded reasons
recorded in `DSMEM-Cluster.md` — `%warp-spec-check-block-only` may be over-broad for
register-destination loads, there is no `:block`-equivalent SPIR-V barrier, and the shipped kernel
is one sub-group wide so there is no second warp to specialize.

**Chapter 7, Intel is the loosest analogy in the table.**  NVIDIA's rung is a bigger *instruction*;
Intel's is a tile-shape sweep bounded by the GRF model.  Same question, different kind of answer.
Flagged rather than resolved.

---

## Section 2 — Top MMA Benchmarks

The best kernel section 1 produced, against everyone, at every size.

| contender | class | note |
|---|---|---|
| Crisp | — | the best mainloop from section 1 |
| CUDA_Apples / SYCL_Apples | Control | same algorithm, hand-written |
| **CUTLASS / SYCL-TLA** | **Peer** | **the comparison that matters — not yet built** |
| cuBLAS / oneMKL | Ceiling | the horizon |

**Devices: every one we can get.**  This is the section where "how fast is Crisp on an H200?" is
the actual question.  The report already groups by `gpu_model`, so no harness work is needed.

**Compile time is a first-class column here, not a footnote.**  CUTLASS instantiation is famously
minutes per GEMM from template metaprogramming.  The harness already records `device_compile_ms`.
If Crisp emits a competitive kernel in about a second, that is a real claim and it costs nothing
to measure.

---

## Section 3 — Situational Techniques

Techniques whose honest answer is *"it depends"*.  Presented as **controlled pairs**: two kernels
identical but for one keyword, so the difference is attributable.

Currently one member:

**TMA multicast (NVIDIA only).**  Measured on an H100 NVL, tf32, `warmup=20 iters=100`:

| tile | N=2048 | N=4096 |
|---|---|---|
| 64×256 | −7.0% | −9.7% |
| **64×128** | **+15.5%** | **+10.7%** |
| 64×64 | +1.1% | +4.4% |
| 64×32 | +7.7 / +11.7% | −10.7 / −11.6% |

Two conditions, both required: the machine must be **saturated** (the size crossover sits exactly
at 0.97 residency waves) and the kernel must be **fetch-limited, not compute-limited** (chapter 7's
wider tile is equally saturated and still loses, because its pipeline already hides the fetch).

This section is also where the `c4_*` diagnostic variants belong as supporting data — they are
controls, not chapters, and should not appear in the main ladder.

---

## Section 4 — MMA + Activation

Its own story, built on whatever section 1's best mainloop is, with its own contenders.

| # | The question | Answer | API added |
|---|---|---|---|
| 1 | Can we skip the output round trip? | fused epilogue, both vendors | `(map-elements! D #'F)` |
| 2 | Can that epilogue be arbitrary? | yes — and the vendors cannot | **none** |

**Chapter 2's empty API column is the whole point.**  It adds no new form: it is chapter 1's
`map-elements!` with an arbitrary user `def-function` instead of a common one.

### CORRECTION — the claim splits by contender class

An earlier draft of this document said "the vendors cannot".  **That is wrong once Peer is in the
picture**, and the distinction matters:

| contender | can it fuse an ARBITRARY activation? | what Crisp is claiming |
|---|---|---|
| cuBLASLt, oneDNN (**Ceiling**) | **No** — a fixed enum / fixed post-op set | **capability**: off-menu costs them a second kernel and a full HBM round trip |
| CUTLASS, SYCL-TLA (**Peer**) | **Yes** — an arbitrary functor, monomorphised at template instantiation | **not capability** — expressiveness and COMPILE TIME |

So §4 needs Peer timings too, and against a Peer the honest claim is narrower and different in
kind.  This is also where **compile time stops being a curiosity and becomes the argument**:
CUTLASS pays template-instantiation minutes per activation variant; Crisp pays about a second.
*"Same capability, two orders of magnitude cheaper to express"* is defensible.  *"They cannot do
it"* is not.

Against the Ceiling the capability claim stands, and it is the best number in the suite —
**118% of oneDNN on Intel**.

**Why this must be a separate section:** as long as it is chapters 7–8 of the GEMM ladder, every
mainloop improvement silently obsoletes its numbers, and the fusion claim stops being comparable
to anything.  Splitting it means the epilogue kernels rebase on the best mainloop by construction.

---

## Section 5 — Scaling Out

Not speed chapters.  The question is "what if it does not fit?", at three increasing scales.

| topic | what it needs | 1.0? |
|---|---|---|
| **Out of core** (one GPU, stream from host) | async host↔device staging, a host-side chunk loop | **possibly** — does not need a mesh description |
| **Hardware multi-tile** (e.g. PVC 2T/4T) | sub-device enumeration, memory placement, cross-die interconnect | no |
| **Multi-GPU** | `def-topology`, `def-orchestration` | no |

### A term collision worth recording

**"Multi-tile" means two different things** and they defer differently:

- **Software multi-tile** — one workgroup handling several *output* tiles.  Pure scheduling,
  needs no topology, and `tile-stride` already does a form of it.  A persistent / stream-K style
  scheduler belongs in **section 1 or 3**, not here.
- **Hardware multi-tile** — a PVC Max 1550 is physically two dies with their own HBM, exposed by
  Level Zero as composite or separate sub-devices.  That is a *device topology* problem and a
  sibling of multi-GPU.

NVIDIA blurs this differently: a B200 is two dies presented as one logical device, so it is
transparent where Intel's is explicit.  Another vendor asymmetry.

**So deferring `def-topology` defers multi-GPU and hardware multi-tile, but not software
multi-tile, and arguably not single-GPU out-of-core.**

---

## Where things stand today (measured, N=4096, `fast`)

| vendor | best Crisp | ceiling | ratio |
|---|---|---|---|
| NVIDIA | 257.1 (chap3_wgmma) | 381.6 (cuBLAS) | **67%** |
| Intel | 15.8 (intel_prefetch) | ~14.3 (oneMKL) | **~110%** on the fused chapters, lower on plain GEMM |

### Two anomalies the new structure should expose rather than hide

1. **Intel chapter 1 is slower than chapter 0** — 0.8 vs 1.5 TFLOPS, and both are below the
   hand-written control at 1.3.  A ladder rung that goes *down* is either a real finding or a
   stale measurement; the current structure makes it invisible.
2. **NVIDIA `chap2_pipelined_block` (67.9) is slower than `chap1.5_async_block` (71.5).**  Same
   question.

Neither is explained.  Both are the kind of thing a "vs previous chapter" column would have caught
the day it appeared.

---

## Migration from the current directories

| current | becomes |
|---|---|
| — | §1 ch 0 (naive) — **new** |
| — | §1 ch 1 (hand-rolled MMA) — **new** |
| `chap0_sync` | §1 ch 2 (tiling) — and the vendor labels finally diverge honestly |
| `chap1_async_linear` | §1 ch 3 |
| `chap1.5_async_block` | §1 ch 4 |
| `chap2_pipelined_block` | §1 ch 5 |
| `chap3_wgmma` | **splits** into §1 ch 6 (warp specialization) + ch 7 (wgmma) |
| `intel_prefetch` | **splits** into §1 ch 4 (register-resident load) + ch 5 (ring + prefetch) |
| `chap4_cluster_multicast` | §3 (situational) |
| `chap5_fused_epilogue` | §4 ch 1 |
| `chap6_fused_custom` | §4 ch 2 |

**Both splits recover measurement we already own.**  `chap3_wgmma` bundles warp specialization +
wgmma + a bigger tile, which is why the ladder jumps 18.2% → 66.6% with no way to attribute it —
and `benchmarks/matmul/README.md` already records that on plain `mma.sync`, ws2 is 2.0× the ring
at 1024 and +6% at 4096, with `ptxas -v` showing 250 → 167 registers/thread.  So warp
specialization is the **small-size** lever and wgmma is the **large-size** lever, a real finding
the current bundling hides.  `intel_prefetch` likewise jumps 5.3% → 82.8% in one step.

---

## What would 90% take?

Recorded here because it should drive which chapters get written next.

**NVIDIA (67% today).**  One thing is now certain: **the gap is not operand-fetch bandwidth** —
that is what multicast's failure proved.  Cheapest first:

1. **Deeper rings / longer K-step.**  Untested, and 148 KB of the 228 KB shared budget is unused.
   Costs no registers.
2. **Register pressure.**  165 regs/thread → 2 CTAs/SM; under ~136 buys a third.  Endeavour 144
   already built the accounting.
3. **Cluster-distributed accumulator.**  A 128×256 tf32 tile needs >255 registers on one CTA;
   splitting it across a cluster is the *capacity* use of DSMEM, which is what the hardware is
   actually for.  This is the bet for a large jump.
4. **Stream-K / persistent scheduling.**  We have no equivalent.

Guess: 1+2 reach ~75–80%; 3 is what makes 90% plausible.

**Intel (already closer).**  `Subgroup2DBlockLoadINTEL` replacing the coop-matrix loads, and
unblocking warp specialization.  Intel may reach 90% with *less* work than NVIDIA — an asymmetry
worth stating plainly in the docs, alongside the fact that Crisp already leads on fused activation.

---

## Does "fast as possible" need new API?

Asked because it decides the shape of the next two endeavours.  Answer: **Intel almost none;
NVIDIA half the levers are free and the two most promising need real language work.**

| lever | new API? |
|---|---|
| **NVIDIA** deeper rings / longer K-step | **No** — `:ring-count` and tile shapes are existing knobs |
| **NVIDIA** register pressure → a 3rd CTA/SM | **No** language change; compiler-side allocation work |
| **NVIDIA** cluster-distributed accumulator | **Yes, significant** — a tile whose accumulator spans cluster members is a new type or declaration |
| **NVIDIA** stream-K / persistent scheduling | **Yes** — `tile-stride` assumes a static work mapping; a persistent kernel needs a work-queue abstraction |
| **Intel** `Subgroup2DBlockLoadINTEL` | **No** — a lowering change under the existing `load-tile` |
| **Intel** unblock warp specialization | Mostly compiler-side; *possibly* a `:block`-equivalent barrier mode for SPIR-V |
| **Intel** bigger tiles via the GRF model | **No** — `def-hardware-profile` already has the keys |

### The sequencing this implies

**Do the knob-juggling FIRST, precisely because it tells you whether the API work is justified.**
If deeper rings and lower register pressure reach ~85%, the cluster-accumulator endeavour may not
be worth building.  If they reach 72%, the remaining gap is structural and the API work is the
only path.  Either way the information is cheap: no new API, no new specs, a sweep with knobs that
already exist.

Endeavour 152 spent six weeks establishing that multicast was *not* the lever.  Buying the same
class of information for an afternoon this time is the lesson from it.

### And an asymmetry worth stating in the docs

**Intel is closer to parity, needs less new API to close the rest, and already leads on fused
activation.**  That is a materially different product story from the NVIDIA one, and the docs
currently tell neither.

---

## Notes for folding this into topology.md

Two things make the merge easier and one makes it awkward.

**Easier:** `docs/reference.md` is AUTO-GENERATED from docstrings, so topology.md does not have to
be a reference at all.  It is free to be pure narrative and link out for signatures.

**Easier:** the chapters already hold vendor-distinct kernels, so the narrative has real code to
point at per vendor without restructuring the benchmark tree first.

**Awkward: the document is named after its own deferred section.**  topology.md opens with
`def-topology`, `def-orchestration`, torus meshes and fat trees — which under this arc is **§5
Scaling Out**, the part that is not in 1.0.  Following the story means leading with "how do you
make a matmul fast" and ending with "what if it does not fit", at which point `topology.md` is
probably the wrong filename.

**Also awkward:** topology.md is currently ordered by API FORM (`cluster-size`, `load-tile`,
`make-async-barrier`), which is lookup order rather than narrative order.  Reorganising by question
means a reader hunting for `:multicast` can no longer scan the headings for it.  Since
reference.md covers lookup, that is an acceptable trade — but it should be a deliberate choice,
and the narrative should link to the reference generously.

---

## Open questions

- Do sections 1 and 2 share kernels, or does section 2 get its own tuned variant?  Sharing is
  less work and less honest if the top benchmark wants different tile shapes.
- Is a persistent / stream-K scheduler a §1 chapter (it is a technique) or §3 (it may be
  situational)?  Unknown until measured.
- Does §1 ch 0 (naive) need a Control at all, or is Crisp-vs-Crisp enough there?
- CUTLASS as a Peer needs a build story in the harness.  Non-trivial; scope before promising it —
  and note §4 now DEPENDS on it, since the fused-activation claim against a Peer cannot be made
  without Peer numbers.
- Which device is "representative" per vendor for §1?  H100 and BMG today, but that should be
  written down rather than being whichever pod was available.
- If topology.md becomes the narrative, does it keep that name?  See the folding notes above.
