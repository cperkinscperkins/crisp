# Performance Levers — the tuned-matmul surface

Everything that changes the speed of a Crisp **register-resident MMA matmul** — the `sec2_top`
family of benchmark kernels — organised by *who sets it*. Written after a long run of tuning where
the recurring failure was not picking the wrong value for a lever but **not knowing a lever existed**,
or believing two levers were independent when they were not.

**Scope.** Only the "top" algorithm: a `tile-stride` over the output, register tiles for A/B/C, a K
loop, `mma-accumulate-via-tile`, `store-tile` epilogue. Not reductions, scans, sorts, or the
SLM-staged and async chapters, which have their own tuning surfaces.

**Every number below is measured on an Arc B580 (BMG)** unless it names other hardware, and each is
marked `[linux]` or `[windows]` — because those disagree, sometimes by more than any lever in this
document. See [Layer 4](#layer-4--below-us).

---

## Layer 1 — In the Crisp kernel

The largest levers are here, and the two biggest are not independent of each other.

### Geometry

| Lever | Where | Notes |
|---|---|---|
| **Output tile M×N** | `(tile-stride C (TM TN) ...)` | Sets work per workgroup and, with `:warps`, per subgroup. `32x32 → 32x64` was **1.25–1.72×** `[windows]`. Not free at the top: `TN 96` faults, `TN 128` runs at `0.14×`. |
| **Workgroup tile vs per-subgroup tile** | `(tile-stride C (TM TN) ...)` together with the `:warps` length | **These are separable, and conflating them cost an endeavour.** Going `128×256 / 16 subgroups → 256×256 / 32` leaves the per-subgroup tile at **32×64 and register demand at 448/thread — unchanged**. It is pure operand sharing: arithmetic intensity 85.3 → **128 flops/byte**. So the workgroup tile can be doubled *without* touching the `TN 128` / `TM 64` wall, which is a per-subgroup limit. Worth **+36%** at 8192 with prefetch; roughly neutral without it. This is SYCL-TLA's shape, fixed at every N. |
| **Subgroup count + distribution** | `:warps '(true true …)` on each `make-register-tile` | Length = subgroups the tile is split across; must agree with `local-size / simd-width`. A silent no-op on rings until endeavour 156 Phase 2. |
| **K-tile extent** | A-tile is `(TM K)`, B-tile `(K TN)`, and the loop divisor `(/ K (to-ulong K-step))` | **The lever that was missed for months.** Not the same as MMA K. |
| **MMA shape** | `(mma-accumulate-via-tile (M N K) ...)` | Must be one of the profile's `:mma-shapes`. On BMG: `(8 16 8)` tf32, `(8 16 16)` bf16/fp16, `(8 16 32)` int8 — same M×N, K doubles as operands narrow. Choosing a shape the profile lacks is a compile error, not a slowdown. |
| **Element type** | `(matrix bfloat16 …)` vs `half` vs `float` | Changes which MMA shape is native, so it **forces a K-step change**. bf16 and fp16 measure within ~4% of each other; the accumulator stays `float` either way. |

> **K-tile extent and subgroup count are one lever, not two.** Each geometry has its own K optimum
> and it moves with subgroup count: **64 at one subgroup, 32 at sixteen**. Doubling K past the
> optimum regresses hard in both — `59.1 → 37.9` at one subgroup, `55.9 → 47.8` at sixteen
> `[windows]`. Multi-subgroup was written off as a measured loss for a whole endeavour because it was
> only ever tried at K=16, where there is not enough work in flight to pay for the participants.
> **Never tune one without re-tuning the other.**

> **And the same trap caught the workgroup tile.** Endeavour 156 measured 256×256 over 32
> subgroups at **34.6 against 60.8** and banked it — at K=16, and before `prefetch-tile` could
> be warp-partitioned. The geometry only pays *with* the prefetch it could not then express:
> without prefetch it is still slightly behind (62.0 vs 65.1 @4096); with it, +36%; with
> `:xe-native` as well, **+60%**. Endeavour 158.

### Pipelining

| Lever | Where | Measured |
|---|---|---|
| **Ring depth** | `make-register-tile-ring … :ring-count N` | `2 → 3` **collapses** a 32×64 tile, `57 → 23` `[windows]`. At K=32 across 16 subgroups a ring does not fit at all. |
| **Prefetch distance** | how many `prefetch-tile` K-steps ahead the loop issues | **+60% at the peer geometry** (66.2 → 106.0 @8192, with `:xe-native`), and worth +36% even on `:coop-matrix`. **Shorter is better, monotonically** — d1 ≥ d2 > d3 > d4 wherever it helps. `[linux]` |
| **Prefetch distribution** | `:warp-partitioned true` on `prefetch-tile` | **Not optional at multi-subgroup geometry.** Without it every subgroup issues every block — 384 per workgroup per K-step against 256 loads — and prefetch measures **2.6–2.9× SLOWER**. With it, 2 per subgroup. Endeavour 158. |
| **Barrier pacing** | `(sync-workgroup)` or `(sync-workgroup :arrive/:wait)` in the K loop | Fused at 16 subgroups: **−14.7%**. Split: **−1.8%**. No barrier is fastest at that width. Pays only at 4 subgroups (+8.6%), where fused beats split. `[windows]`, endeavour 157. |

> **`:ring-count` is not `Stages`.** Crisp's `:ring-count` is a count of **buffers**; SYCL-TLA's
> `Stages` is a **prefetch depth over a single buffer**. They are different knobs with similar names,
> and conflating them cost real time. Deeper K supplies the pipelining a ring was meant to — two
> native K-steps inside one tile are already two independent MMA chains — without a second buffer's
> register cost.

### Lowering

| Lever | Where | Measured |
|---|---|---|
| **MMA lowering** | `(declare (mma-lowering :xe-native))`, else profile default | **`:xe-native` + peer geometry + warp-partitioned prefetch is the fastest fp16 kernel Crisp has: 106.0 TF @8192, 95% of oneMKL, best at every size ≥1024.** Alone it is only +5% (66.2 → 69.6); the win is the COMBINATION (+60%). Its two recorded failure modes are **scope-limited, not general**: "does not compose" was about the **ring**, never prefetch; and the 32×128 collapse to 5.6 TFLOPS is a live-fragment-count effect that does not arise at a 32×64 per-subgroup tile. Emits 42 machine instructions per dpas against 57. `[linux]`, endeavour 158. |
| **Precision** | `(declaim (precision fast))` / `--math-precision` | `fast` enables contraction and reassociation. Note `fast` **flushes denormals regardless** of `--denormal-handling=preserve`; the compiler warns. |

### Dispatch declarations

`local-size` and `global-size` are declared *in the kernel*, then recorded in the `.metacrisp` for
the host to obey. They are **not** four independent knobs:

```lisp
(declare (global-size :derive-from C :strategy :strided :tile-shape (128 256))
         (local-size  :set-to 256))
```

- **`local-size`** — threads per workgroup. `local-size / :simd-width` = subgroups, which **must**
  match the `:warps` list length.
- **`:tile-shape`** — governs grid **rank and shape** on both backends, and is **inferred from
  `tile-stride`** if not given. Getting the rank wrong is expensive: a 1-D grid under an N-D
  `tile-stride` *serialises an axis* — **7.6×**. Axis 0 tracks dimension 0; reversing it cost ~1.3×.
- **Number of workgroups** — *derived*, `CEIL(extent[k] / tile_shape[k])`. Not separately settable.
- **`:occupancy`** — a **grid-size multiplier** against max-resident-workgroups, and only when there
  is no `:tile-shape`. The 1.0 cap was lifted; measured optimum for `sum_reduce` is **2.0**
  (deliberately 2× oversubscribed), 22.6 → 5.9 µs. For an exact tile cover it does not apply, and
  exact cover beat occupancy at every size tested.

---

## Layer 2 — In the compiler

This is the layer that was blank in the original list, and it contains at least one lever worth 2×.

### Flags

| Flag | Effect on speed |
|---|---|
| `--hardware-profile=` | Selects the entire profile below. **The single highest-leverage compiler flag** — it decides MMA shapes, lowerings, register modes, cache assumptions, and the tile-visit swizzle. |
| `--math-precision=fast\|ieee` | Contraction and reassociation. |
| `--denormal-handling=preserve\|ftz` | Ignored under `fast` (which always flushes). |
| `--ir-target=spv\|ptx`, `--ir-target-arch=` | Backend and arch gating. |
| `--runtime-checks` | Adds bounds checks. Off by default; on, it costs. |
| `--debug` | Emits debug info. Perturbs codegen; do not benchmark with it. |
| `--differentiate` | Changes the *kernel set* (adds `_GRAD` twins) — the forward kernel should be unaffected, but the module is not the same module. |
| `--single-pass` | Different compile path; has had its own bugs (BUG 042, 043). |

### Profile keys that are levers

From `(:hardware-profile …)` in the `.metacrisp` — the record of what the compiler actually assumed:

| Key | Role |
|---|---|
| `:mma-shapes` | The legal `mma-accumulate-via-tile` shapes. |
| `:mma-lowerings` | Ordered, **most-preferred first**; first entry is the default. |
| `:max-registers-per-thread` | Selectable allocations, e.g. `(128 256)` on BMG. |
| `:simd-width` | Subgroup size — **16** on BMG. Divides `local-size` into subgroups. |
| `:tile-visit-strip-width` | Column-strip width for the rank-2 `tile-stride` walk. |
| `:l2-cache-size`, `:native-cache-line-size`, `:compute-units` | Informational to the model. |

### Compiler *decisions* that become runtime flags

- **Register mode selection** (endeavour 144). The compiler computes register-tile bytes per thread,
  picks from `:max-registers-per-thread`, and records `:selected-registers-per-thread`. The hoisted
  harness turns that into **`-ze-opt-large-register-file`**. Getting this wrong was a **14× measurement
  error** when the fixture was first calibrated, and a 3.1× error on a 32×64 tile.
  **It is geometry-dependent, not a general law:** worth ~2× to the single-subgroup 32×32 shape, while
  at 128×128 over 16 subgroups the **default allocation beats large-GRF by 70%** (32.2 → 54.9 @4096).
  SYCL-TLA is *indifferent* to it (185 → 190 forced either way, with 3904 bytes of deliberate spill) —
  avoiding spill is worth ~3× to **our** lowering and nothing to its. That is a property of our
  codegen, not of the hardware.
  The current shipped kernels deliberately request **448 registers/thread against a 256 max** and spill.
- **Subgroup-size pinning** — `!intel_reqd_sub_group_size` from the profile's `:simd-width`, but
  **only when `local-size` is compile-time known and a whole multiple of it**. Otherwise IGC picks,
  and the width Crisp assumed when computing warp counts may not be the width that gets compiled.
- **Tile-visit swizzle** — `:tile-visit-strip-width`, overridable with the `CRISP_TILE_VISIT`
  environment variable for bisecting or sweeping. Was once *derived* from `:l2-cache-size`; that
  derivation was refuted by measurement (+63% on one device, −14% on another, both supplying the key),
  so it is now a measured per-profile constant.
- **Address arithmetic** — currently recomputed per fragment. Spec `155/04` pins the invariant
  (multiplies must be fewer than cooperative loads) and is **RED on purpose**: 26 i64 multiplies for
  8 loads. Xe has no native 64-bit multiply, so each is emulated `mul`/`mach`/`macl`. Hoisting it cut
  multiplies 36% for **+2.9%**, and on the ring kernel gave identical instruction counts **17% slower** —
  so these kernels are *not* issue-bound, and this is a correctness-of-lowering item, not a speed win.

### Environment

| Variable | Effect |
|---|---|
| `CRISP_TILE_VISIT` | Overrides the swizzle width, or `linear`. For sweeps and bisection. |
| `CRISP_USE_SYSTEM_TOOLS` | Use PATH `llc`/`opt`/`llvm-spirv` instead of bundled. Toolchain version differences are real. |

---

## Layer 3 — At enqueue

**These are not free choices.** `local-size`, grid shape and workgroup count are *decided by the
kernel* and recorded in the `.metacrisp`; the host's job is to **reproduce what the compiler assumed**.
A mismatch is usually a correctness bug that reads as a performance result:

- A **1-D group count for a 2-D local size** pinned `grid.y` to 1 — at N=16 that happens to cover the
  matrix, at N=32 half the columns are never written. `chap0_naive` read MMA_CORRECT at 16 and
  MMA_WRONG at 32 with **no MMA in the kernel at all**. The kernel was always fine.
- Not passing the compiler's chosen register mode: **14×**.

Genuinely host-side:

| Lever | Notes |
|---|---|
| **M, N, K of the matrices** | The strongest single determinant of which kernel wins. No shape tested is best at every size. |
| **Build flags to the JIT** | `pBuildFlags` — must carry the compiler's register-mode choice. |
| **Warmup and iteration counts** | Under-warming reads low; batched re-submits of an in-flight L0 command list **coalesce**, which once inflated GFLOPS by exactly `iters`. MMA_CORRECT cannot catch that. |

---

## Layer 4 — Below us

Outside the algorithm, and **larger than anything inside it.**

| Lever | Magnitude |
|---|---|
| **Host platform** | The same unchanged bf16 kernel: `69.3 / 62.3 / 56.0 / 51.3` on Windows-native L0 vs `63.1 / 57.7 / 64.5 / 66.2` on Linux in the bench container. Windows wins small N, Linux wins large — **29% apart at 8192, in opposite directions**. |
| **…and it reorders rankings** | `w64_k64` led a 30-candidate Windows screen at 59.1 @4096 and measures **26.9 on Linux**, last of six. **A screen taken on one platform is not evidence about the other.** |
| **Driver / IGC version** | A month of driver movement once lifted *every* implementation by a similar factor — the signature of an environment change, not a compiler win. |

Run-to-run spread inside the bench container, six repeats: **2.2%** at 1024 and 2048, **3.1%** at 4096,
**0.7%** at 8192. A 6% delta is signal; a 2% one is not.

---

## Measured non-levers

Things tried on this algorithm that did **not** pay. Recorded so they are not re-tried blind — each
cost real hardware time.

| Tried | Result |
|---|---|
| SLM staging of operands | **40× slower** (0.9 vs 41.9 @2048). `SPV_INTEL_2d_block_io` is a *global*-memory facility, so staging through shared local memory loses the 2D block load entirely (`load_block2d` 41 → 0). SYCL-TLA uses **no SLM**. |
| Address hoisting | −36% emulated multiplies for **+2.9%**; on the ring kernel, identical instruction counts **17% slower**. |
| **Cache control** (`SPV_INTEL_cache_controls`) | **DEAD, tested twice.** `CacheControlLoadINTEL` L1+L3 `Cached` — SYCL-TLA's `kL1C_L3C`, which it uses at all 26 of its call sites. Measured −3.3% @4096 (loads only) and **−1.4% @8192 with the PREFETCH decorated too, on the real kernel** (176 decorations vs 0 in a byte-identical twin, so the arm was genuine). Either IGC ignores pointer decorations on 2D-block-io, or the driver default already matches. Do not re-open without new information. |
| Ring depth 3 | +9% at 32×32, collapses 32×64. |
| Split barrier | Removes ~90% of the fused barrier's cost and still loses to no barrier. |
| `TM 64` (64×32) | Does not run. |
| `TN 96` | MMA_WRONG at 0.27 TFLOPS — GPU-fault signature. |

---

## How to change a lever honestly

Learned the hard way, repeatedly:

1. **Measure both arms in one session, back to back.** The same unchanged kernel has moved 15%
   between sessions. Any old number is a different experiment.
2. **Measure on the platform of record** — for Intel that is Docker/Linux
   (`scripts/bench-intel.sh`), not Windows-native, even though Crisp-only numbers *can* be taken
   natively because the fixture needs only `clang++`.
3. **Use the fixture, not a generated harness.** `bench_harness_l0.cpp` is one reviewed apparatus for
   every kernel, so a difference between rows is a difference between kernels.
4. **Check `verified`.** Several "wins" were kernels that skipped work — `chap2_tiling` posted the
   second-best number in its section while storing nothing at all, because it had no `store-tile`.
   The compiler warned on every build; a sweep runs `--log-level=off`.
5. **Know the spread before believing a delta.** Two byte-identical kernels once read 57.7 and 61.7
   at N=2048 in the same run.
6. **Read the `.metacrisp`.** It is the compiler's own record of what it assumed — geometry, lowering,
   register mode. If the harness and the metacrisp disagree, the measurement is of neither.

## Open

- **The remaining SYCL-TLA gap is a lowering gap, and it is now precisely one thing.** At 8192
  Crisp reads **106.0** against ~237. Geometry is matched (256×256 over 32 subgroups — theirs is
  fixed at every size, verified from their peer `.cpp`: compile-time constants, zero
  size-dependent branching). Prefetch is in. Cache policy is dead. The coop-matrix lowering is
  superseded. What is left is the part of their instruction stream we do not emit:
  `createBlock2DAddressPayload` / `setBlockX/Y`, **never materialising a 64-bit address**. Spec
  `155/04` already pins the invariant and is RED on purpose — 26 emulated i64 multiplies for 8
  loads, and Xe has no native 64-bit multiply.
- **The peer column is not yet trustworthy.** SYCL-TLA at N=2048 read 72.1 / 85.1 / 107.9 across
  three sessions on an unchanged binary — a 49% spread — because the bench image has no `ocloc`
  and builds it JIT rather than AOT. That drift is now comparable to the effects being measured.
- The bigger *per-subgroup* tile is still blocked: `TN 128` at 0.14×, `TM 64` will not run,
  `TN 96` faults. Note the 256×256 workgroup tile did **not** need this — per-subgroup work and
  register demand are unchanged at 32×64 and 448 regs/thread.

## The lesson this document keeps having to relearn

**Three times in endeavour 158, a lever recorded here as a measured loss turned out to be a win
once a second lever existed.** The 256×256 geometry ("34.6 vs 60.8", endeavour 156) was measured
at K=16 without warp-partitioned prefetch. Prefetch ("2.6–2.9× slower") was measured while every
subgroup issued every block. `:xe-native` ("does not compose") was measured against a *ring*.
Each negative was honestly taken and correctly recorded, and each was **scoped to a configuration
rather than to the mechanism** — which is how it went on to mislead.

So when writing an entry here: say what was held fixed, not just what was measured. A result that
does not name its configuration will eventually be read as a result about the mechanism.
