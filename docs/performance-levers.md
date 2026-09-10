# Performance Levers: MMA Matmul

This document defines the tuning surface for Crisp **MMA matmul** kernels. It covers algorithms
using a `tile-stride` over the output, tiles for A/B/C, a K loop, an MMA accumulate, and a
`store-tile` epilogue.

**You have already chosen the algorithm.** This is the list of knobs for making that algorithm
go faster on a given part — not a guide to picking a different one.

### Read the vendor column

The two backends do not have the same tuning surface, and the difference is not cosmetic:

|  | Intel (Xe2 / BMG) | NVIDIA (Hopper) |
| --- | --- | --- |
| Where operands live | **registers** (`make-register-tile-ring`) | **shared memory** (`make-scratch-matrix-ring`) |
| What the ring costs | register budget → spilling | SMEM budget → resident blocks |
| Register file | selectable modes `(128 256)` | fixed 255/thread |
| MMA altitude | one: per-subgroup fragments | **two**: fragment *or* warpgroup (wgmma) |
| Getting operands in | `prefetch-tile` | `cp.async` (`:linear`) or TMA (`:block`) |

Sections marked **[Intel]** or **[NVIDIA]** apply to one backend only. Everything else is shared.

---

## 1. Kernel-Level Levers (Layer 1)

These are the primary directives set within the Crisp kernel. Many of these levers are highly coupled; tuning one usually requires re-tuning its pair.

### Geometry

Matrix geometry balances register pressure against arithmetic intensity.

| Lever | Location | Heuristics & Constraints |
| --- | --- | --- |
| **Per-Subgroup Tile ($TM \times TN$)** | `(tile-stride C (TM TN) ...)` | Drives per-thread register demand. **[Intel]** typical safe maximum is `32x64`; beyond it (`TN > 64`, `TM > 32`) risks register exhaustion or driver faults. **[NVIDIA]** fragment path runs `64x64`; the wgmma path is fixed at `64xN`. |
| **Workgroup Tile ($M \times N$)** | `(tile-stride C ...)` + `:warps` | Scales data reuse (arithmetic intensity). **Decoupled from subgroup tile:** you can scale the workgroup tile up (e.g., to `256x256`) by adding subgroups without increasing per-thread register pressure. |
| **Subgroup Count** | `:warps '(true true …)` on `make-register-tile` | List length equals subgroups. Must agree with `local-size / simd-width`. |
| **K-Tile Extent** | A/B tile inner dim, and K-loop divisor | Sets work in flight per loop iteration. Typically 32 or 64. |
| **MMA Shape** | `(mma-accumulate-via-tile (M N K) ...)` | Must match a shape in the profile's `:mma-shapes`, or it is a **hard compile error**. Narrower element types double K: **[Intel]** `8x16x8` tf32 → `8x16x16` bf16/fp16 → `8x16x32` int8; **[NVIDIA]** `16x8x8` tf32 → `16x8x16` fp16/bf16. fp64 has exactly one shape, `8x8x4`. |

> **Coupling Rule: Subgroup Count vs. K-Tile Extent**
> K-extent optimum moves inversely with subgroup count. A single subgroup might prefer K=64, while 16 subgroups require smaller steps (e.g., K=32) to prevent register spilling while keeping all participants fed. Never tune one without re-evaluating the other.

### [Intel] Pipelining & Memory Access

NVIDIA's equivalents are in the async-staging section below; `prefetch-tile` and
`make-register-tile-ring` are Xe2 facilities.

| Lever | Location | Mechanism & Constraints |
| --- | --- | --- |
| **Prefetch Distance** | K-steps ahead the loop issues `prefetch-tile` | Generally, shorter is better monotonically ($d1 \ge d2 > d3$). Highly effective when combined with large workgroup tiles and `:xe-native`. |
| **Prefetch Distribution** | `:warp-partitioned true` on `prefetch-tile` | **Mandatory at multi-subgroup geometry.** Without this, every subgroup issues every block, multiplying loads and severely degrading throughput. |
| **Ring Depth** | `:ring-count N` on `make-register-tile-ring` | Count of register *buffers*, not logical pipeline stages. Deep rings (e.g., depth 3) on large per-subgroup tiles cause catastrophic spilling. |
| **Barrier Pacing** | `(sync-workgroup)` in the K loop | Fused vs. split vs. no barrier. At wide subgroup counts (e.g., 16), omitting the barrier is typically fastest. |

### [NVIDIA] Warpgroup MMA (wgmma)

Hopper offers a **second MMA altitude**, and it is the single largest lever on the NVIDIA side —
it is the instruction cuBLAS itself uses. A fragment-level kernel and a warpgroup-level kernel
are different algorithms wearing the same shape.

| Lever | Location | Mechanism & Constraints |
| --- | --- | --- |
| **Altitude** | `wgmma-accumulate-via-tile` + `make-wgmma-accumulator` vs `mma-accumulate-via-tile` + `make-register-tile` | Warpgroup MMA issues one instruction across **128 threads (4 warps)**. The accumulator is a warpgroup object, not a per-thread register tile. |
| **wgmma Shape** | `(wgmma-accumulate-via-tile (M N K) D A B)` | **M is always 64** — that is what a warpgroup is. `N` must be a multiple of 8 in `[8, 256]`. `K` is 8 for tf32, 16 for fp16/bf16. Checked against the profile's `:wgmma-shapes` when it declares them, otherwise against the sm_90a rules. |
| **N width** | the `N` in the shape and the accumulator | The arithmetic-intensity knob. Wide `N` (256) buys reuse at large problem sizes; it costs registers, so it trades against ring depth. |
| **Hopper-only** | `--ir-target-arch=sm_90` | wgmma and TMA are Hopper-class features; they do not exist on earlier architectures, so a wgmma kernel is not portable down. The shapes are validated at compile time, so an illegal one is an error rather than a silent fallback. Note that a *reference* or host compile placed alongside such a kernel may itself need `nvcc -arch=sm_90a`. |

> **There is no fp64 wgmma.** Warpgroup MMA covers fp16/bf16/tf32/fp8/int8 only, so a double-precision
> kernel tops out at the fragment path. This is a hardware fact, not a Crisp gap.

### [NVIDIA] Warp Specialization

Splitting a workgroup into **producer** warps (which fetch) and **consumer** warps (which do math)
lets the fetch run ahead without the consumers stalling on it.

| Lever | Location | Mechanism & Constraints |
| --- | --- | --- |
| **Producer / consumer split** | `(with-warp-specialization (:producer P :consumer C) ...)` | **Two consumers is the usual sweet spot.** More consumers is not monotonically better — adding a second *pair* has been measured to regress. |
| **`local-size` must agree** | `(local-size :set-to (* 32 (+ P C)))` | `96` = 1 producer + 2 consumers. `160` = 1 producer + one full 4-warp warpgroup for wgmma. Getting this wrong is a launch failure, not a slowdown. |
| **Producer gets no C tile** | `:warps '(false true true)` on `make-register-tile` | The `false` slot is the producer. Omitting it distributes the accumulator across a warp that never does math, wasting its share of the tile. |
| **Where the accumulator is built** | inside `:consumer`, not before the block | A `:warps`-distributed tile constructed outside the specialization does not belong to the consumers. |

### [NVIDIA] Async Staging: cp.async vs TMA

| Lever | Location | Mechanism & Constraints |
| --- | --- | --- |
| **Copy engine** | `:mode` on `make-async-barrier` / `make-async-barrier-ring` | `:linear` = `cp.async` (per-element, no descriptor). `:block` = **TMA** via a `CUtensorMap` descriptor — the hardware copy engine, and the faster path for 2-D tiles. |
| **Barrier arrivals** | `:arrivals N` | How many participants the barrier waits for. Must match the number of warps that actually signal, which changes when you re-tune the producer/consumer split. |
| **Ring phase seeding** | `:initial-state :signaled` / `:waiting` | An `empty` ring starts `:signaled` (buffers are free); a `full` ring starts `:waiting`. Swapping these deadlocks rather than slows down. |
| **SMEM Ring Depth** | `:ring-count N` on `make-scratch-matrix-ring` | **[NVIDIA] this spends shared memory, not registers** — the opposite resource from Intel. Deeper rings buy overlap until SMEM caps resident blocks per SM, at which point occupancy falls and the pipelining stops paying. |

### Lowering & Math

| Lever | Location | Impact |
| --- | --- | --- |
| **MMA Lowering** **[Intel]** | `(declare (mma-lowering :xe-native))` | Selects DPAS + 2-D block loads instead of the portable `:coop-matrix` path. Yields peak FP16 throughput when combined with peer geometry and warp-partitioned prefetch; less effective in isolation. Only offered by profiles whose `:mma-lowerings` lists it. NVIDIA has no lowering choice — the altitude choice (fragment vs wgmma) is the equivalent knob. |
| **Precision** | `(declaim (precision fast))` | Enables contraction and reassociation. **Note:** `fast` flushes denormals unconditionally, ignoring `--denormal-handling=preserve`. |

### Dispatch Declarations

Grid sizes are decided *in the kernel* and emitted to the `.metacrisp` file.

* **`local-size`**: Threads per workgroup. Divided by `:simd-width`, this must match the length of your `:warps` list.
* **`:tile-shape`**: Defines the grid rank and shape (inferred from `tile-stride` if omitted). **Trap:** Using a 1-D grid under an N-D `tile-stride` will serialize an axis and destroy performance.
* **`:occupancy`**: A grid-size multiplier against max-resident-workgroups. Only applies when there is no exact `:tile-shape`.

---

## 2. Compiler & Environment (Layer 2)

### High-Impact Compiler Flags

* **`--hardware-profile=`**: The most critical flag. Dictates MMA shapes, lowerings, register budgets, and tile-visit swizzles.
* **`--math-precision=fast|ieee`**: Toggles contraction/reassociation.
* **`--differentiate`**: Generates `_GRAD` twins; creates an entirely different module footprint.

### Key Profile Directives (`.metacrisp`)

* **Register Mode Selection [Intel]:** The compiler calculates register bytes per thread and selects from `:max-registers-per-thread`. For large tiles, forcing large-GRF (`-ze-opt-large-register-file`) can be crucial, but for distributed subgroups, the standard allocation often wins. **[NVIDIA] there is no equivalent** — the register file is a fixed 255/thread, so a tile that does not fit spills and the only remedy is smaller geometry or more warps.
* **Tile-Visit Swizzle:** Controlled by `:tile-visit-strip-width` (overrideable via `CRISP_TILE_VISIT` for sweeps). A measured constant per profile, **not derivable from L2 size** — it has been measured as a large win on one part and a monotonic loss on another. Absent means linear, which is the safe default. **[NVIDIA] measured harmful on H100; leave it out.**
* **Occupancy reporting [NVIDIA]:** When the profile supplies `:max-registers-per-cu`, the compiler reports blocks-per-SM as limited by registers, and warns at one block — the case where there is no second block to hide memory latency behind. Treat that warning as "your tile is too big or too concentrated", answerable by a smaller accumulator or a wider `:warps` spread.
* **Shared-memory cap [NVIDIA]:** `:max-shared-memory-per-block` must be the **opt-in** figure (~227KB), not the 48KB default. SMEM rings deeper than a couple of stages exceed 48KB immediately.
* **`:compute-units` is load-bearing:** it *overrides* the device SM query when the launch grid is sized. A profile naming the wrong variant (H100 PCIe's 114 vs a 132-SM part) under-dispatches every kernel, silently.

---

## 3. Host Enqueue Rules (Layer 3)

The host's primary job is to **reproduce what the compiler assumed**. Disagreements between the host launch params and the `.metacrisp` usually result in silent correctness bugs that masquerade as performance shifts.

* **Grid and Local Size:** Do not override the kernel's derived 2-D local sizes with 1-D groups on the host.
* **JIT Build Flags [Intel]:** The host must pass the compiler's chosen register mode to the JIT (`pBuildFlags`).
* **Dynamic SMEM opt-in [NVIDIA]:** A kernel asking for more than 48KB of shared memory needs `cuFuncSetAttribute(CU_FUNC_ATTRIBUTE_MAX_DYNAMIC_SHARED_SIZE_BYTES, …)` before launch. Without it the launch fails outright; the generated hoist reads the requirement from the `.metacrisp` and emits the call.
* **TMA descriptors [NVIDIA]:** A `:block`-mode copy needs its `CUtensorMap` built on the host with the same extents and element type the kernel assumed. A descriptor that disagrees is a correctness bug, not a slow path.
* **Warmup/Iters:** Under-warming reads low. Conversely, batching too many re-submits of an in-flight L0 command list can artificially inflate GFLOPS due to coalescing **[Intel]** — the CUDA path does not coalesce this way.

---

## 4. Platform & Driver Variance (Layer 4)

* **Platform Disparities [Intel]:** Windows-native L0 and Linux/Docker L0 can disagree significantly (up to 30% deltas at large $N$, often reordering kernel rankings entirely). **A screen taken on one platform is not evidence for the other.**
* **Part Variance [NVIDIA]:** SM count differs across parts of the same architecture (H100 PCIe 114, SXM/NVL/H200 132). Because `:compute-units` sizes the grid, a number from one variant does not transfer to another even at identical clocks.
* **Signal vs. Noise:** Run-to-run variance on a stable container is typically 1-3%. Treat deltas under 5% as noise unless proven otherwise.

---

## 5. Known Anti-Patterns (What Not to Do)

Do not waste time retrying these approaches for this specific algorithm class; they are measured dead ends.

**[Intel]**

1. **SLM Staging of Operands:** `SPV_INTEL_2d_block_io` is a global-memory facility. Staging through SLM drops the 2D block load entirely, resulting in catastrophic throughput loss on Xe2.
2. **Cache Control Directives:** Manually applying `SPV_INTEL_cache_controls` (e.g., L1/L3 caching) has proven ineffective or slightly regressive. The driver default for 2D block IO already matches or ignores these pointer decorations.
3. **Deep Rings on Large Tiles:** Ring depth $\ge 3$ on `32x64` subgroup tiles guarantees register collapse.
4. **More subgroups as a throughput lever:** scaling the workgroup tile across many subgroups does *not* beat a single well-tuned subgroup on this part. It is a correctness-preserving geometry change, not a speedup.

**[NVIDIA]**

5. **Clusters and TMA multicast:** forming a cluster is cheap, but multicasting operands across it has measured *slower* than the plain TMA ring. The operand-fetch path is not the bottleneck it appears to be.
6. **`:tile-visit-strip-width` on Hopper:** a loss at every width tried, degrading monotonically as the strip widens. Wide output tiles already span most of the matrix, so the swizzle has nothing left to exploit. Omit the key.
7. **Adding consumer warps past two:** the second producer/consumer *pair* has measured a regression. Two consumers is the sweet spot; more warps split the accumulator further without adding useful overlap.
8. **Assuming deeper SMEM rings keep paying:** past the point where shared memory caps resident blocks per SM, extra depth buys overlap and loses occupancy, and the trade turns negative at large problem sizes.

---

## Benchmarking Discipline

1. **Measure A/B in one session.** Driver and environment drift is real. An old number is a different experiment.
2. **Use the platform of record.** For Intel, standard benchmarking occurs in Docker/Linux (`scripts/bench-intel.sh`). For NVIDIA it is a rented pod (`scripts/bench-on-pod.sh`).
3. **Match the profile to the part.** The benchmark harness refuses to sweep on hardware with no validated hardware profile, because a profile for the wrong variant produces wrong numbers rather than slow ones. See `benchmarks/README.md`.
4. **Check `verified` output.** A kernel that skips a `store-tile` step will look incredibly fast. Ensure the math is actually executing.
5. **Trust the `.metacrisp`.** If the host harness and the `.metacrisp` disagree on geometry, lowering, or register mode, the benchmark is invalid.
