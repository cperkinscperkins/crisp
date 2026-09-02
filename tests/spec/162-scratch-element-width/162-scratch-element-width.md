# Endeavour 162 — scratch element width: 16-bit CUDA kernels reserve twice the shared memory they use

Opened 2026-09-02, found while compile-verifying a two-warpgroup bf16 variant for the 16-bit
perf work. **Not yet fixed — this document is the finding and the plan.**

---

## The finding

`%cuda-local-param-bytes` (`src/hoist-cuda/main.lisp:629`) sizes every dynamic-shared scratch
parameter with:

```lisp
(elem-bytes (if (or (string-equal elem-str "double")
                    (string-equal elem-str "int64_t")
                    (string-equal elem-str "uint64_t"))
                8 4))
```

**Everything that is not 64-bit gets 4 bytes — `bfloat16` and `half` included.** So a 16-bit
scratch tile reserves exactly twice the shared memory it occupies.

Measured, not inferred. Compiling against a profile with a smaller cap makes the compiler state
the total:

| kernel | scratch elements | reported bytes | bytes/element |
|---|---:|---:|---:|
| `chap7_wgmma` (tf32) | 20,480 | < 131,072 (≈81,920) | 4 ✓ correct |
| `chap7_wgmma_bf16` | 40,960 | **163,840** | **4** ✗ should be 2 |
| `_variant_wgmma_bf16_2wg` | 49,152 | **196,608** | **4** ✗ |
| `_variant_wgmma_bf16_2wg_deep` (ring 4) | 98,304 | **393,216** | **4** ✗ — *refused* |

`40,960 x 4 = 163,840` exactly. At the correct 2 bytes it is 81,920.

### Why the kernels are still numerically correct

`%cuda-shared-layout` computes the launch request **and** the per-tile offsets from this same
function — deliberately, so they cannot disagree (that divergence was BUG 046). So every tile
starts at a correctly-spaced, merely over-generous offset, TMA writes packed 2-byte data into
the front of each region, and wgmma reads it packed from that base. The back half of every
16-bit tile region is dead space. Correctness holds; that is why `MMA_CORRECT` never caught it.

### Why this is an oversight and not a deliberate ABI

**The codebase already contains the correct table.** `%elem-type-bytes`
(`src/hoist-l0/main.lisp:1396`) handles 64-bit, 16-bit *and* 8-bit widths properly, and Intel's
SLM emitter uses it:

| function | scope | rule |
|---|---|---|
| `%l0-emit-local-scratch-tensor-arg` | Intel SLM | **correct** (bf16 -> 2) |
| `%l0-emit-tensor-arg` | Intel tensors | **correct** |
| `%l0-emit-global-scratch-tensor-arg` | Intel global scratch | naive 8-else-4 |
| `%cuda-local-param-bytes` | **CUDA shared** | naive 8-else-4 |
| `%hp-scratch-elem-bytes` | profile bound check | naive 8-else-4 |

Nobody writes a correct width table and then chooses 4 bytes for the same types elsewhere in
the same file on purpose. **Intel's local scratch is already right, so BMG's bf16 results are
NOT affected** — consistent with BMG bf16 reaching 102% of oneMKL while the NVIDIA 16-bit
ladder underperforms.

## Why it should matter

H100 has 228KB of shared memory per SM and a 227KB per-block opt-in cap.

| kernel | reserved | needs | CTAs/SM |
|---|---:|---:|---|
| `chap7_wgmma` (tf32) | ~80KB | 80KB | **2** |
| `chap7_wgmma_bf16` | **160KB** | 80KB | **1** |
| `sec2_top_bf16` / `sec2_top_fp16` | 160KB | 80KB | **1** |

Registers permit two CTAs at 160 threads (160 x ~166 = 26,560; two = 53,120 <= 65,536), so
**shared memory is the binding constraint and it is binding on a number that is twice too
large.** The §2 headline kernels are affected.

`chap7_wgmma_bf16`'s own comment picks a K-block of 64 specifically to keep an *"identical
shared-memory footprint"* to its tf32 twin. It is not identical; it is double.

It also **refuses kernels that would fit**: the ring-depth-4 variant was rejected at 393,216
bytes, which is 196,608 at the correct width — inside the cap.

## Confidence, per claim

| claim | confidence | basis |
|---|---|---|
| CUDA 16-bit shared scratch is reserved at 2x | **~95%** | three code reads; exact arithmetic; correct counterpart exists in-tree |
| That costs `chap7_wgmma_bf16` a CTA/SM | **~85%** | register/SMEM arithmetic above; register estimate ~166 is borrowed from the tf32 rung, not measured for bf16 |
| Fixing it yields a measurable speedup | **~65%** | a deeply warp-specialized, software-pipelined kernel can be largely occupancy-insensitive — the whole point of the pipeline is to hide latency without needing a second CTA |

The third is the one worth designing an experiment around, and Phase 1 does so **without
touching the compiler**.

## Plan

### Phase 0 — CONFIRMED at the launcher, 2026-09-02 (was: confirm, not infer)

**DONE, and it holds.** The emitted `matmul_matmul_CUDA.cu` for `chap7_wgmma_bf16` states it
outright, having correctly identified the element type and then sized it wrong:

```c
// LOCAL scratch tensor: b-ring (rank=3, uint16_t, 32768 elems, 131072 bytes, shared offset 0)
// LOCAL scratch tensor: a-ring (rank=3, uint16_t,  8192 elems,  32768 bytes, shared offset 131072)
cuFuncSetAttribute(kernel, CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES, 163840);
cuLaunchKernel(kernel, ..., 163840, 0, ...);
```

32,768 `uint16_t` sized at 131,072 bytes is 4 bytes each. The a-ring's offset (131,072) is pushed
out by the inflated b-ring, so the offsets move under the fix as predicted. This is the LAUNCHER,
not the checker: the kernel really requests and occupies 160KB where 80KB would do.

**Claim 1 revised to ~99% and claim 2 to ~95%** — claim 2 is now arithmetic on a confirmed
number (163,840 x 2 = 327,680 > 228KB per SM, so one CTA; 81,920 x 2 = 163,840, so two).
Claim 3 is unchanged at ~65% and remains the only open question.

<!-- superseded plan text below kept for the record -->
### Phase 0 (original) — confirm the request directly, not by inference (local)
Read the emitted `matmul_matmul_CUDA.cu` for `chap7_wgmma_bf16` and find the literal
`sharedMemBytes` passed at launch. The 163,840 above comes from the compiler's *checker*; the
launcher is a separate emitter and must be read on its own terms. Also confirm the per-tile
offsets are 4-byte-spaced. **If the launcher already requests 81,920, the whole finding
collapses to a checker-only bug** — still worth fixing (it refuses valid kernels) but with no
performance story.

### Phase 1 — test the occupancy claim WITHOUT changing the compiler (needs a pod, ~5 min)
Build `chap7_wgmma_bf16` with **K-block 32** instead of 64. That halves the element count, so
it reserves 81,920 bytes under the *current* buggy rule and gets 2 CTAs/SM — the exact
occupancy the fix would deliver, reachable today.

* faster => occupancy is the lever; claims 2 and 3 hold; the fix is worth the ABI risk.
* not faster => the kernel is occupancy-insensitive, the fix is correctness-and-headroom only,
  and the 16-bit deficit is somewhere else entirely.

It is not a perfectly clean control — a K-block of 32 is two k16 slices rather than four, which
changes the pipelining as well as the occupancy. Its *negative* result is therefore stronger
than its positive one. Run it alongside the unmodified kernel and the two 2wg variants.

### Phase 2 — the fix (local)
One shared width table, used by everything: `%hp-scratch-elem-bytes`, `%cuda-local-param-bytes`,
and `%l0-emit-global-scratch-tensor-arg`. `%elem-type-bytes` is the model; it already knows
8/4/2/1.

**The sizer and every emitter must move together.** `%cuda-local-param-bytes`' own docstring says
it "exists so the sizer and the emitters cannot disagree, which is only true if it computes what
they compute" — and BUG 046 was precisely that divergence. Before changing it, enumerate every
consumer of the 4-byte assumption, including `%cuda-emit-cell-arg` and
`*cuda-shared-cell-offset*`.

Widening the *profile check* alone is safe and independent, and could ship first.

### Phase 3 — re-verify (needs a pod)
Every offset in every 16-bit CUDA kernel moves. `MMA_CORRECT` on: chapters 4/5/6/7 bf16,
`sec2_top_bf16`, `sec2_top_fp16`, plus the 16-bit specs under `--hoist`. This is the real risk
of the endeavour — the change is small and its blast radius is every 16-bit kernel's addressing.

### Phase 4 — re-measure (needs a pod)
§1.5 NVIDIA bf16 ladder and §2 bf16/fp16, against the numbers recorded 2026-09-02
(456.7 / 461.4 TFLOPS at N=4096, 71.3% / 68.2% of cuBLAS).

## Status

- [x] Finding recorded, confidence stated per claim
- [x] Phase 0 — launcher confirmed: `cuLaunchKernel(..., 163840, ...)`; claim 1 ~99%, claim 2 ~95%
- [ ] Phase 1 — K-block-32 occupancy probe on metal
- [ ] Phase 2 — unify the width table
- [ ] Phase 3 — re-verify 16-bit CUDA kernels on metal
- [ ] Phase 4 — re-measure §1.5 and §2

## Related

* `_variant_wgmma_bf16_2wg` / `_variant_wgmma_bf16_2wg_deep` — the two-warpgroup variants whose
  compile-verification surfaced this. The deep one is blocked until Phase 2.
* Endeavour 161 — the previous "compile-time refusal beats silent wrongness" case. This is the
  same shape: a number that was wrong for months and that no runtime check could catch.

---

# PHASE 2 DONE 2026-09-02 — the fix, verified locally

`%hoist-elem-type-bytes` (correct 8/4/2/1 table) now drives the three functions that govern the
CUDA shared blob, all of which had to move together because `%cuda-shared-layout` derives the
launch request AND the tile offsets from the same numbers:
`%cuda-local-param-bytes`, `%cuda-emit-local-scratch-tensor-arg`, `%cuda-emit-cell-arg`.
`%hp-scratch-elem-bytes` got the matching Crisp-symbol table.

**Emitted launcher for `chap7_wgmma_bf16`, before -> after:**

| | before | after |
|---|---:|---:|
| b-ring (32,768 x uint16_t) | 131,072 | **65,536** |
| a-ring (8,192 x uint16_t) | 32,768 | **16,384** |
| a-ring shared offset | 131,072 | **65,536** |
| `cuFuncSetAttribute(... MAX_DYNAMIC_SHARED_SIZE_BYTES ...)` | 163,840 | **81,920** |

Two CTAs now need 163,840 bytes against 228KB per SM, so **2 CTAs/SM instead of 1**.

**The confirmation that pleases most:** `chap7_wgmma_bf16` now reports 81,920 -- *identical* to
its tf32 twin, which is exactly what its own comment claimed as the reason for choosing a
K-block of 64. The comment was right all along; the compiler was not.

Checks: tf32 control unchanged at 81,920 (float is still 4). `sec2_top_bf16` and `sec2_top_fp16`
both halved to 81,920. The ring-depth-4 variant, previously REFUSED at 393,216 bytes, now
compiles. **1057/1057 E2E + 232/232 negative + 291/291 unit.**

## Two things learned that cost a build each

* **SBCL had BAKED the old return type.** It derived `%hp-scratch-elem-bytes` as
  `(OR (INTEGER 4 4) (INTEGER 8 8))` -- it had only ever returned 4 or 8 -- and inlined that into
  its caller, so returning 2 raised *"The value 2 is not of type (OR (INTEGER 4 4) (INTEGER 8 8))
  from the function type declaration."* Fixed the documented way: `declaim` the widened ftype,
  then re-append the CALLER (`%hp-kernel-shared-bytes`) verbatim so it recompiles. Same shape as
  the `%cuda-tensor-map-data-type` case.
* **`overlays/hoist-common/` is never loaded by either hoist build.** `build-hoist-cuda.lisp`
  loads only `overlays/hoist-cuda/`, and the L0 build only its own. The shared table was
  therefore invisible to the hoister binary. The table now lives in the CUDA overlay; when the
  Intel global-scratch path is fixed, it must move somewhere shared AND both `build-hoist-*.lisp`
  taught to load it -- a second copy would be the exact duplication that caused this bug.

## Status

- [x] Phase 0 — launcher confirmed at 163,840
- [x] Phase 2 — fix landed; launcher now 81,920; full regression green
- [ ] Phase 3 — re-verify 16-bit CUDA kernels on metal (offsets moved; THIS IS THE RISK)
- [ ] Phase 4 — re-measure §1.5 and §2 against 456.7 / 461.4 TFLOPS @4096
- [ ] Phase 1 — the K-block-32 probe is now REDUNDANT: the fix is the unconfounded A/B, since
      only the reservation changes. Dropped unless Phase 4 is ambiguous.
- [ ] Deferred: Intel `%l0-emit-global-scratch-tensor-arg`, CUDA `%cuda-emit-global-scratch-tensor-arg`
      and `%cuda-emit-tensor-arg` still carry the naive rule. Neither touches SHARED memory --
      they over-allocate GLOBAL memory for 16-bit types, which is waste, not occupancy.

---

# PHASES 3 + 4 MEASURED 2026-09-02, H100 NVL — claim 3 FALSIFIED, and the fix pays anyway

## Phase 3 — the gate PASSED
Every 16-bit kernel still verifies with the halved reservation and the moved offsets:
`chap7_wgmma_bf16`, `sec2_top_bf16`, `sec2_top_fp16` all `verified=True` at 1024/2048/4096.

## Phase 4 — doubling occupancy bought almost nothing

| kernel | N | pre-fix | post-fix | delta |
|---|---|---:|---:|---:|
| sec2_top_bf16 | 1024 | 91.6 | 91.1 | -0.5% |
| | 2048 | 333.4 | 332.8 | -0.2% |
| | 4096 | 456.7 | **466.4** | **+2.1%** |
| sec2_top_fp16 | 4096 | 461.4 | 466.8 | +1.2% |

**Claim 3 (~65%) is FALSIFIED.** 2 CTAs/SM instead of 1 is worth ~1-2% at 4096 and nothing
below it. The competing explanation was right: a deeply warp-specialized, software-pipelined
kernel hides latency without needing a second CTA -- that is what the pipeline is FOR.

**A measurement-hygiene note.** The first post-fix run read 70.4 TFLOPS at N=1024; a re-run of
the same binary gave 90.2. A 28% swing means **N=1024 on this harness is too noisy to carry a
conclusion on its own**, and the -25% "regression" that first run appeared to show was an
artifact. Re-running before reporting is what caught it.

## The fix pays for itself somewhere else entirely

Its real value is not occupancy -- it is that `_variant_wgmma_bf16_2wg_deep` **could not be
built at all** before it (refused at 393,216 bytes; 196,608 at the true width).

| kernel | 1024 | 2048 | 4096 |
|---|---:|---:|---:|
| `chap7_wgmma_bf16` (64x256, ring 2) | **90.2** | **329.8** | 463.9 |
| `_variant_wgmma_bf16_2wg` (128x256, ring 2) | 66.6 | 273.9 | 402.1 |
| `_variant_wgmma_bf16_2wg_deep` (128x256, ring 4) | 70.7 | 321.2 | **486.5** |
| cuBLAS bf16 | 97.4 | 426.4 | 651.9 |

**Both predictions scored.** `_2wg` was written down as PREDICTED TO LOSE and it loses at every
size -- 0.87x at 4096, closely matching the tf32 twin's measured 0.91x at 154/03. And the deep
variant, the arm the reasoning actually favoured, is **the fastest Crisp 16-bit kernel to date:
486.5 TFLOPS at N=4096, +4.9% over chapter 7 and 74.6% of cuBLAS** (up from 71.5%).

The asymmetry argument held exactly as written: the tall tile alone is a loss, but it has ALREADY
paid occupancy down to one CTA, so the deeper pipeline is free there while it would cost the
64-row kernel its second CTA. Tall tile alone: worse. Tall tile + deep pipeline: best.

Below 4096 the deep variant still loses, consistent with the occupancy penalty dominating when
there is less work to hide behind it.

## Status

- [x] Phase 0/2 — fix landed and confirmed at the launcher (163,840 -> 81,920)
- [x] Phase 3 — all 16-bit kernels verify with moved offsets
- [x] Phase 4 — measured: fix alone ~+1-2% at 4096; claim 3 falsified and recorded as such
- [x] Variants measured; `_2wg_deep` is a new best at 4096
- [ ] Promote `_2wg_deep` into the ladder/§2 as a real rung (it is currently an underscore variant)
- [ ] Sweep ring depth 3/5/6 on the 128x256 geometry -- depth 4 was a first guess, not a tuned one
- [ ] Deferred: the naive rule still lives in `%cuda-emit-global-scratch-tensor-arg`,
      `%cuda-emit-tensor-arg`, `%l0-emit-global-scratch-tensor-arg` (GLOBAL memory: waste, not occupancy)

## Pod-setup friction worth fixing before the next rental

`scripts/run-on-pod.sh` stalled TWICE with zero remote activity and had to be abandoned:
* Ubuntu 22.04 **needrestart** prompts block `apt` forever at "Processing triggers for libc-bin".
  Fix: `$nrconf{restart}='a'` in `/etc/needrestart/conf.d/` before any apt call.
* The SBCL install uses `wget -q` on a SourceForge URL; SourceForge was **unreachable** from this
  pod (SSL timeout) and `-q` hid it, so the `&&` chain silently skipped install. apt's SBCL
  (2.1.11) built Crisp fine -- worth preferring, or at least falling back to.
* Quicklisp was installed WITHOUT `(ql:add-to-init-file)`, so the build died on
  "Package QL does not exist".
* Only `llvm-as` was symlinked to its `-21` name; `llc` was not, so codegen failed with exit 127.

---

# BIG-MATRIX VERIFICATION — the diagnosis, and a theory of mine that DIED

## What is actually broken

Both mechanisms that were supposed to make large-N verification affordable **exist and work**:

* **Sampling** -- both fixtures check a ~64x64 STRIDED grid, `smax = 64`, so at most 4096 output
  elements at any N, each costing O(K). At N=K=65536 that is ~5e8 FLOPs: seconds, not hours.
* **Time gating** -- `BENCH_TIMEOUT = 900.0` seconds per benchmark binary, verification included.

So big-N verification is **not slow. It FAILS**, and the report drops unverified points, which
renders as an empty cell indistinguishable from "never ran":

| plat | N | verified | unverified |
|---|---:|---:|---:|
| BMG | 4096 | 33 | 47 |
| BMG | 8192 | 29 | 29 |
| BMG | **16384** | **0** | 6 |
| H100 | 8192 | **1** | 29 |
| H100 | **16384** | **1** | 29 |
| H100 | **32768** | **0** | 23 |

## A theory I had, and why it is WRONG

I proposed that the fixed `tol = 1e-3 * max(1, |acc|)` was too tight, since fp32 accumulation
error grows about K*eps -- 9.8e-4 at K=16384, 2.0e-3 at K=32768. The cliff matched the data
almost perfectly.

**It is wrong, and the harness says so in a comment I had already read.** The inputs are
`A[i] = i % 5` and `B[i] = i % 3` -- small integers. Products are at most 8, so `acc <= 8K`,
which is 524,288 at K=65536: **exactly representable in fp32** (< 2^24). Nothing rounds.
Verification is an EXACT comparison, exactly as the fill comment claims, and the confirming
evidence was already in hand -- chapter 7 verifies with `max_abs_err: 0`, not "small", *zero*.

I fitted a plausible curve to a coincidence without checking what the inputs were. Recorded
because it is the same failure mode as endeavour 160's descriptor argument and BUG 052's
probes: **a plausible argument standing in for a measurement.**

**Consequences.** Do NOT scale the tolerance -- it would mask real defects. And the large-N
timings are NOT recoverable data: they belong to kernels that computed WRONG ANSWERS.
A failure at N>=8192 is a real defect, not a near-miss.

## Fixes made (local)

1. **`max_abs_err` and `verify_samples` are now PERSISTED** into the result JSON via
   `VerificationMetrics`. Both fixtures computed them and the collector discarded them, so no
   large-N failure could be diagnosed after the fact. This matters MORE now that we know a
   failure means real wrongness: the magnitude separates "a few wrong tiles" from "everything
   wrong", which points at the mechanism.
2. **Failing points are RECORDED as unverified rather than DROPPED.** The report already filters
   on `verified`, so nothing wrong gets published, but the evidence survives.
3. **The host no longer allocates or copies back all of C** -- only the ~64 sampled ROWS.
   O(64*N) instead of O(N^2). This is what actually caps the big runs; device HBM does not.

## Device memory is not the limit

H100 NVL is 94 GB; footprint is A+B+C:

| N | 16-bit (8N^2) | tf32 (12N^2) |
|---:|---:|---:|
| 16384 | 2.1 GB | 3.2 GB |
| 32768 | 8.6 GB | 12.9 GB |
| 65536 | 34.4 GB | 51.5 GB |

**64K fits for both.** The binding constraint was the host side, which fix 3 removes.

## NOT DONE / next

* **`bench_harness.cu` is NOT COMPILE-VERIFIED** -- there is no nvcc on the dev box. Braces
  balance and the edit is contained, but it must be built before it is trusted.
* The same host-C reduction has NOT been applied to `bench_harness_l0.cpp` (Intel).
* `bench_harness_l0.cpp`'s verification header still reads "full host reference ... Checked at
  EVERY size, not sampled", contradicting the sampling code 17 lines below it. Stale comment.
* **The real question is now open: WHY do kernels fail verification at N>=8192?** With
  `max_abs_err` persisted, one sweep at 4096/8192/16384 will characterise it. A 32-bit index
  overflow is one candidate at 32768 (M*N = 2^30 elements, so byte offsets exceed 2^32), but it
  does not explain 16384, where both counts still fit.

---

# TESTED LOCALLY ON THE BMG (Docker), 2026-09-02 — and it produced the first 16k data

Run on the actual Intel Arc B580 in the dev box via `scripts/bench-intel.sh` (Docker, the
established Intel path). The L0 harness was NOT modified, so this is a clean single-variable
test of the collector changes.

## 1. The collector fix works
`verification` is now populated on real runs:
`{'verified': True, 'mode': 'spot_check', 'max_abs_err': 0, 'samples': 4096}`.
`samples: 4096` also CONFIRMS the sampling is doing what it claims at every size.
(Peer harnesses -- SYCL/oneMKL -- do not emit `verify_samples`, so `samples` is None for them.)

## 2. FIRST EVER verified 16384 measurements on BMG — six of them

| chapter | variant | N=16384 TFLOPS |
|---|---|---:|
| sec2_top_bf16 | `wg256xe` | **78.4** |
| sec2_top_bf16 | Crisp (wg256xepf2 base) | 69.1 |
| sec2_top_bf16 | `wg256xepf2` | 25.1 |
| sec2_top_bf16 | `wg256pf2` | 24.3 |
| sec2_top_bf16 | `pfw1` | 16.1 |
| sec2_top (tf32) | Crisp | 8.6 |

**Every one has `max_abs_err = 0`** -- exact, as the integer fill guarantees. Before today the
entire results corpus held **zero** verified Crisp points at N=16384 on BMG. §2 now renders
16384 for both BMG tf32 (8.6) and bf16 (78.4 = 0.85x SYCL-TLA, 68% of oneMKL) where it showed
em-dashes.

## 3. A NEW finding the 16k data immediately exposed

**The variant ranking INVERTS at 16384.** `wg256xepf2` is the best single choice from 1024
through 8192 -- and collapses to **25.1** at 16384, while `wg256xe` holds **78.4**, a 3.1x
reversal. The report's existing SIGN FLIPS warning covered 256..8192; this is a far larger flip
at the size nobody had measured. Any tuning conclusion drawn at <=8192 is unsafe to extrapolate.

## 4. A correction to the previous section's alarm

The previous entry concluded the large-N failures were "real wrongness". **That over-read the
data.** Re-running the exact case that showed 0/6 verified at 16384 -- `sec2_top` tf32 -- it now
verifies cleanly with max_abs_err 0. The historical large-N dashes were, at least here, absence
of successful runs rather than a standing numerical defect. Genuine unverified points DO remain
at 8192 for chap1/chap2/chap3 (one of which reports 0.0 TFLOPS and is independently broken), so
"some are real" stands -- but the blanket claim does not.

## Still untested

* **`bench_harness.cu` (CUDA) remains NOT COMPILE-VERIFIED** -- no nvcc on the dev box, and the
  Intel path exercises `bench_harness_l0.cpp`, which this change did not touch. Build it first
  thing on the next pod.
* The host-C reduction has NOT been applied to `bench_harness_l0.cpp`; today's BMG run still
  allocates and copies the full C. It completed at 16384 (1 GB) but would be the limit at 32k+.

---

# BMG PUSHED TO 32768 — a per-allocation cap, not a memory ceiling

## The L0 harness did NOT need the CUDA fix
`bench_harness_l0.cpp` allocates A, B and C with **`zeMemAllocShared`** -- one unified
allocation each, no host mirror, no copy back. The CUDA change (host `std::vector` mirrors plus
an O(N^2) D2H) has no counterpart here; porting it would have been invented work. Only the
stale verification header needed correcting (it claimed a full non-sampled reference seventeen
lines above the `smax = 64` sampling).

## What actually blocked 32768

Every Crisp variant died at `allocA` with **`L0 error 78000009`** while oneMKL and SYCL-TLA
completed the same size -- which is what proved it was not VRAM exhaustion. From the local
headers, `0x78000009 = ZE_RESULT_ERROR_UNSUPPORTED_SIZE`: *"size argument is not supported by
the device (e.g., too large)"*. At N=32768 the bf16 A operand is 32768^2 x 2 = **exactly 2 GiB**
-- a single allocation past the device's `maxMemAllocSize`.

Level Zero ships the documented remedy, and the harness simply was not using it:

```cpp
ze_relaxed_allocation_limits_exp_desc_t relaxed{
    ZE_STRUCTURE_TYPE_RELAXED_ALLOCATION_LIMITS_EXP_DESC, nullptr,
    ZE_RELAXED_ALLOCATION_LIMITS_EXP_FLAG_MAX_SIZE};
ze_device_mem_alloc_desc_t dmem{ZE_STRUCTURE_TYPE_DEVICE_MEM_ALLOC_DESC, &relaxed};
```

Zero allocation errors afterwards; all five variants ran and verified.

## FIRST 32768 measurements on BMG (all verified, max_abs_err 0, 4096 samples)

| contender | N=32768 TFLOPS |
|---|---:|
| oneMKL_BF16 (ceiling) | 99.6 |
| SYCL-TLA_BF16 (peer) | 90.2 |
| **Crisp `wg256xe`** | **50.1** |
| Crisp `wg256pf2` | 10.0 |
| Crisp `wg256xepf2` | 9.7 |
| Crisp `pfw1` | 7.8 |
| SYCL_Apples_BF16 (control) | 6.9 |

§2 BMG bf16 now reads 0.56x peer / 51% of ceiling at 32768.

## The finding that matters more than the number

**The variant ranking does not just flip at large N -- it collapses.**

| variant | 8192 | 16384 | 32768 |
|---|---:|---:|---:|
| `wg256xepf2` (best single choice <= 8192) | **110.9** | 25.1 | **9.7** |
| `wg256xe` | -- | **78.4** | **50.1** |

`wg256xepf2` is the tuned favourite through 8192 and loses **11x** of its throughput by 32768,
while `wg256xe` degrades gracefully. The spread between them widens 3.1x at 16384 to **5.2x** at
32768. Every tuning conclusion in the report drawn at <= 8192 is unsafe to extrapolate, and the
existing SIGN FLIPS table -- which only covers 256..8192 -- understates the problem badly.

This is exactly the class of result that was invisible while the big sizes went unmeasured.

## Status

- [x] L0 harness: stale verification comment corrected
- [x] L0 harness: relaxed allocation limits -> 32768 now runs on a 12 GB B580
- [x] First BMG data at 16384 AND 32768, all verified with exact-zero error
- [ ] 65536 on BMG is out of reach on 12 GB (8N^2 = 34.4 GB); it is an H100 question (fits in 94 GB)
- [ ] `bench_harness.cu` (CUDA) still NOT compile-verified -- no nvcc on this box
- [ ] Re-check whether the NVIDIA side hits the same per-allocation cap at 32768+

---

# H200, 2026-09-02 — the endeavour pays off: 90% of cuBLAS at N=32768

Setup succeeded FIRST TRY in ~10 minutes using the four fixes this endeavour identified
(needrestart pinned, apt SBCL instead of the unreachable SourceForge, `(ql:add-to-init-file)`,
ALL LLVM tools symlinked). The previous pod lost roughly 70 minutes to those same four.

**`bench_harness.cu` COMPILE-VERIFIED** (`nvcc -O3 -arch=sm_90`, rc=0) -- the outstanding
unverified change from the previous session. The sampled-row D2H is sound.

## Ring depth: a first guess was a 45% understatement

Depth 4 was picked only because it was the largest that fit after the element-width fix. Swept
properly -- and 2/3/4 is the COMPLETE sweep, since depth 5 needs 240KB against a 227KB cap:

| ring depth | 4096 | 8192 | 16384 |
|---:|---:|---:|---:|
| 2 | 436.7 | 524.9 | 528.9 |
| 3 | 515.8 | 614.4 | 663.4 |
| **4 (cap)** | **569.3** | **686.0** | **737.1** |

Monotonic in depth at every size, with the margin widening as N grows.

## The full H200 picture, bf16, all verified with max_abs_err = 0

| contender | 4096 | 8192 | 16384 | 32768 | 65536 |
|---|---:|---:|---:|---:|---:|
| cuBLAS | -- | 885.0 | 894.2 | 811.1 | 817.7 |
| **`_2wg_deep` (128x256, ring 4)** | **569.3** | **686.0** | **737.1** | **731.0** | **701.9** |
| `chap7_wgmma_bf16` (64x256, ring 2) | 523.7 | 567.0 | 507.5 | 491.7 | -- |
| `sec2_top_bf16` (shipped §2 kernel) | -- | 585.1 | 507.8 | 491.0 | 496.4 |

**vs cuBLAS: 77% at 8192, 82% at 16384, 90% at 32768, 86% at 65536.** The shipped §2 kernel sits
at 57-66% across the same range, so the new geometry is worth **+45% at 16384** and **+49% at
32768** over what the report currently publishes.

**N=65536 measured and verified for the first time anywhere** -- 701.9 TFLOPS, max_abs_err 0.
CUDA showed no per-allocation cap at any size, unlike L0 (which needed the relaxed-limits
extension); the sampled-row D2H is what makes the host side affordable there.

## Why this vindicates the endeavour rather than the occupancy theory

The SMEM fix itself was worth only ~1-2% directly, and claim 3 stays falsified. Its value is
entirely that it made ring depth 3 and 4 REPRESENTABLE on this geometry -- depth 4 was refused
at 393,216 bytes before the fix and is 192KB after. The win is 45%, and none of it is occupancy.

## Next

- [ ] **Promote `_2wg_deep` into the ladder and §2** -- it now beats the shipped kernel at every
      size measured, by a wide and growing margin. This is the tuned configuration, not a guess.
- [ ] fp16 twin of `_2wg_deep` (159: never assume the formats track)
- [ ] Re-measure the small sizes (1024/2048), where the tall tile lost on H100; the H200 picture
      may differ and §2 needs a single defensible choice across the range.
- [ ] Re-run the H100 comparison so the two machines are directly comparable at the new geometry.
