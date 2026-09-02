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
