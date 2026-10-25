# GPU MODE Contest Report: `histogram_v2`

> Generated from [`results/histogram_v2.json`](results/histogram_v2.json) by `python contests/gpu-mode/report.py --all`. Live leaderboard: [https://www.gpumode.com/leaderboard/539?tab=rankings](https://www.gpumode.com/leaderboard/539?tab=rankings) (Crisp commit `2bbe44fa`).

**Workload:** 256-bin histogram of 1D uint8 tensor across 6 benchmarks (sizes 1.31M to 10.49M bytes; contention 10%, 40%, 90%; geomean size ~3.13 MB).

## § 1 — Official Leaderboard Standings

| GPU | Architecture | Rank | Public Score | Secret Score | Achieved BW | % of #1 (`top1`) | Winning Crisp Kernel | Hardware Profile | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|---|
| **B200** | Blackwell (sm_100) | **#29** / 35 | **17.09 µs** | 17.12 µs | 183.4 GB/s | 55.3% (`9.45 µs`) | [`crisp_histogram_lastman_4rep_cs256_direct64.py`](04-histogram-v2/crisp_histogram_lastman_4rep_cs256_direct64.py) ([`.crisp`](04-histogram-v2/histogram_lastman_4rep_cs256.crisp)) | — | `2026-10-24 23:04` |
| **H100** | Hopper (sm_90) | **#16** / 29 | **14.90 µs** | 16.87 µs | 210.3 GB/s | 59.7% (`8.89 µs`) | [`crisp_histogram_lastman_u4_cs256.py`](04-histogram-v2/crisp_histogram_lastman_u4_cs256.py) ([`.crisp`](04-histogram-v2/histogram_lastman_u4_cs256.crisp)) | — | `2026-10-24 23:04` |
| **A100** | Ampere (sm_80) | **#20** / 28 | **23.55 µs** | 23.07 µs | 133.1 GB/s | 59.2% (`13.95 µs`) | [`crisp_histogram_lastman_u4_direct64.py`](04-histogram-v2/crisp_histogram_lastman_u4_direct64.py) ([`.crisp`](04-histogram-v2/histogram_lastman_u4.crisp)) | — | `2026-10-24 23:04` |
| **L4** | Ada Lovelace (sm_89) | **#6** / 20 | **63.44 µs** | 64.12 µs | 49.4 GB/s | 96.8% (`61.43 µs`) | [`crisp_histogram_lastman_u4_cs256.py`](04-histogram-v2/crisp_histogram_lastman_u4_cs256.py) ([`.crisp`](04-histogram-v2/histogram_lastman_u4_cs256.crisp)) | — | `2026-10-24 23:04` |

## § 1b — Beauty Contestant Showcase (Idiomatic Crisp)

> **Philosophy:** High-level, declarative Crisp code utilizing built-in language idioms (`loop-vector-stride`, vectorized types/views, monomorphic collective reductions) without manual pointer chasing, inline PTX hacks, or complex register budgeting.

> **Design:** 18-line Crisp kernel expressing a 256-bin shared-memory privatized histogram via `make-scratch-vector`, `loop-vector-stride`, `atomic-inc!`, and `atomic-add!`. (`18` SLOC)
>

> **Crisp Abstractions Showcased:**

> - make-scratch-vector shared-memory privatization

> - loop-vector-stride grid-stride loop

> - atomic-inc! shared-memory bin increment

> - atomic-add! global bin flush



| GPU | Architecture | Beauty Score | Achieved BW | % of #1 (`top1`) | % of Tuned Crisp | Winning Tuned Kernel | Mode | Submission ID |
|---|---|---:|---:|---:|---:|---|---|---:|
| **H100** | Hopper (sm_90) | **22.50 µs** | 139.3 GB/s | **39.5%** (`8.89 µs`) | 66.2% (`14.90 µs`) | [`crisp_histogram_lastman_u4_cs256.py`](04-histogram-v2/crisp_histogram_lastman_u4_cs256.py) | `benchmark` | `#966692` |

### Crisp Implementation ([`04-histogram-v2/histogram_beauty.crisp`](04-histogram-v2/histogram_beauty.crisp))

```lisp
;; GPU MODE Challenge 04: histogram_v2 (Beauty Contestant)
;; Counts occurrences of uint8 values [0..255] into 256 int64 bins.
;; Uses a 256-bin workgroup-privatized shared-memory histogram to absorb
;; atomic contention before flushing to global memory.

(def-type in-vec   (vector uchar :address-space :global :align :compact))
(def-type out-vec  (vector ulong :address-space :global :align :compact))
(def-type smem-vec (vector uint  :address-space :local  :align :compact))

(def-kernel histogram_kernel (input &out output)
  (declare #'(in-vec &out out-vec => nil)
           (global-size :derive-from input :strategy :strided)
           (local-size  :set-to 256))
  (let ((shist (make-scratch-vector smem-vec 256))
        (tid   (to-ulong (get-local-id 0))))
    (set! (~ shist tid) 0u)
    (sync-workgroup)
    (loop-vector-stride input (i)
      (atomic-inc! (~ shist (to-ulong (~ input i)))))
    (sync-workgroup)
    (let ((cnt (~ shist tid)))
      (when (> cnt 0u)
        (atomic-add! (~ output tid) (to-ulong cnt))))
    (return)))
```

## § 2 — Technique Ladder & Cross-GPU Ablation (`6-case geomean (sizes 1.31M..10.49M bytes; contention 10%, 40%, 90%)`)

Cells show **`benchmark` mean µs** (and **`[LB: public µs]`** when submitted to the official leaderboard). The fastest kernel on each GPU is **bold**.

| Step | Kernel (`.crisp` / `.py`) | Strategy | Regs | Profile | **B200** | **H100** | **A100** | **L4** |
|---|---|---|---:|---|---:|---:|---:|---:|
| 0 | [`histogram_beauty.crisp`](04-histogram-v2/histogram_beauty.crisp) / [`crisp_histogram_beauty.py`](04-histogram-v2/crisp_histogram_beauty.py) | Idiomatic 256-bin workgroup-privatized shared-memory histogram + loop-vector-stride + atomic-inc! + output.zero_() | 24 | — | — | — | — | — |
| 1 | [`histogram_lastman_u4.crisp`](04-histogram-v2/histogram_lastman_u4.crisp) / [`crisp_histogram_lastman_u4.py`](04-histogram-v2/crisp_histogram_lastman_u4.py) | Single-launch Last-Man + 8x warp-privatized shared-memory histogram (8 KB) + 128-bit uint4 loads + Run-of-4 collapse (+4u) | 36 | — | — | 16.8 | — | — |
| 1b | [`histogram_lastman_u4.crisp`](04-histogram-v2/histogram_lastman_u4.crisp) / [`crisp_histogram_lastman_u4_direct64.py`](04-histogram-v2/crisp_histogram_lastman_u4_direct64.py) | Single-launch Last-Man + 8x warp-privatized shared-memory histogram (8 KB) + uint4 Run-of-4 + fine-grained 64B/thread grid (full SM saturation on 1.31M/2.62M) | 36 | — | — | — | **`LB: 23.55`** | — |
| 2 | [`histogram_lastman_u4_cs256.crisp`](04-histogram-v2/histogram_lastman_u4_cs256.crisp) / [`crisp_histogram_lastman_u4_cs256.py`](04-histogram-v2/crisp_histogram_lastman_u4_cs256.py) | Single-launch Last-Man + 8x warp-privatized shared-memory histogram + uint4 Run-of-4 + :cache (:streaming :prefetch 256) | 36 | — | `LB: 19.97` | **16.7 (`LB: 14.90`)** | `LB: 28.90` | **`LB: 63.44`** |
| 3 | [`histogram_lastman_4rep_cs256.crisp`](04-histogram-v2/histogram_lastman_4rep_cs256.crisp) / [`crisp_histogram_lastman_4rep_cs256_direct64.py`](04-histogram-v2/crisp_histogram_lastman_4rep_cs256_direct64.py) | Single-launch Last-Man + 4x warp-pair shared-memory histogram (4 KB) + uint4 Run-of-4 + :cache (:streaming :prefetch 256) + 64B/thread grid | 34 | — | **`LB: 17.09`** | — | — | — |
| 4 | [`histogram_lastman_16rep.crisp`](04-histogram-v2/histogram_lastman_16rep.crisp) / [`crisp_histogram_lastman_16rep.py`](04-histogram-v2/crisp_histogram_lastman_16rep.py) | Single-launch Last-Man + 16x sub-warp-privatized shared-memory histogram (16 KB) + uint4 Run-of-4 (+4u) collapse | 36 | — | — | 18.5 | — | — |
| 5 | [`histogram_lastman_16rep_run16.crisp`](04-histogram-v2/histogram_lastman_16rep_run16.crisp) / [`crisp_histogram_lastman_16rep_run16.py`](04-histogram-v2/crisp_histogram_lastman_16rep_run16.py) | Single-launch Last-Man + 16x sub-warp-privatized shared-memory histogram (16 KB) + Two-level Run-of-16 (+16u) & Run-of-4 (+4u) collapse | 38 | — | — | 20.0 | — | — |

## § 3 — Key Architectural Takeaways

1. **Single-Launch Last-Man Global Bin Reduction + 128-Bit `uint4` Run-of-4 Collapse (`histogram_lastman_u4_cs256.crisp`):** Replacing the two-launch `output.zero_()` + scalar `uchar` shared-memory baseline (`22.5 µs` on H100) with a single-launch Last-Man pattern (`partials[0..255]` + `ticket` reset to 0 by the last CTA via `atomic-xchg!`), 128-bit `uint4` (16 bytes/load) vectorization, and a per-word Run-of-4 check (`(= w (* (logand w 255u) 16843009u))` -> single `atomic-add! +4u`) cut H100 10 MB runtime by **5.8 µs (−25.8%)** down to **16.7 ± 0.03 µs** (**14.90 µs public geomean**).
2. **Shared-Memory Replication Tradeoff (4x / 8x vs. 16x Sub-Tables) & Small-Case SM Saturation:** Giving each warp (`wid = tid / 32`, `0..7`) its own 256-bin shared-memory sub-table (8 KB total) eliminates cross-warp shared-memory atomic collisions while keeping per-CTA zeroing and reduction overhead to just 8 `st.shared.b32` / `ld.shared.b32` instructions per thread (`16.7 µs` on H100; **Rank #6 / 20 on L4 at 63.44 µs = 96.8% of #1 genuine**). Doubling to 16 sub-tables (16 KB) increased shared-memory init/reduce overhead to `18.5 µs` on H100, while halving to 4 sub-tables (4 KB) paired with 64B/thread CTA sizing improved B200 from `19.97 µs` down to **17.09 µs** and A100 from `28.90 µs` down to **23.55 µs**.
3. **Hardware Bit-Field Extraction (`bfe.u32`) via Power-of-2 Division:** Writing byte extraction in Crisp as `(logand (/ w 256u) 255u)` and `(logand (/ w 65536u) 255u)` lowers directly through LLVM NVPTX to single-instruction hardware bit-field extracts (`bfe.u32 %r, %w, 8, 8` and `bfe.u32 %r, %w, 16, 8`), whereas `(ash w -8)` invokes the variable-shift helper `__crisp_ash_uint`.
4. **Compiler Codegen Bug Identified (`def-function` Returning `=> nil` With Trailing `atomic-add!` inside `if`):** In `histogram_lastman_run16.crisp`, a `def-function` declared `=> nil` whose body contains an `if` expression where one branch ends in `(atomic-add! ...)` and the other ends in a `progn` calling a `=> nil` helper caused an LLVM IR type mismatch in `llc` (`phi` / branch mismatch between `i32` from `atomic-add!` and `void` from `progn`), resolved cleanly by declaring the helper `=> uint` so both branches yield `uint`.

## § 4 — Verified Submission & Benchmark Log

| Timestamp (UTC) | Submission ID | GPU | Mode | File | Benchmark (µs) | Public LB (µs) | Secret LB (µs) |
|---|---:|---|---|---|---:|---:|---:|
| `2026-10-24 22:37:23` | `966682` | **H100** | `test` | `crisp_histogram_lastman_u4.py` | — | — | — |
| `2026-10-24 22:39:19` | `966684` | **H100** | `benchmark` | `crisp_histogram_lastman_u4.py` | 16.8 ± 0.0 | — | — |
| `2026-10-24 22:40:55` | `966686` | **H100** | `benchmark` | `crisp_histogram_lastman_u4_cs256.py` | 16.7 ± 0.0 | — | — |
| `2026-10-24 22:42:15` | `966689` | **H100** | `benchmark` | `crisp_histogram_lastman_16rep.py` | 18.5 ± 0.0 | — | — |
| `2026-10-24 22:43:58` | `966690` | **H100** | `benchmark` | `crisp_histogram_lastman_16rep_run16.py` | 20.0 ± 0.0 | — | — |
| `2026-10-24 22:45:43` | `966692` | **H100** | `benchmark` | `crisp_histogram_beauty.py` | 22.5 ± 0.1 | — | — |
| `2026-10-24 22:49:38` | `966697` | **H100** | `leaderboard` | `crisp_histogram_lastman_u4_cs256.py` | — | **14.90** | 16.87 |
| `2026-10-24 22:51:40` | `966700` | **B200** | `leaderboard` | `crisp_histogram_lastman_u4_cs256.py` | — | **19.97** | 20.47 |
| `2026-10-24 22:53:54` | `966701` | **A100** | `leaderboard` | `crisp_histogram_lastman_u4_cs256.py` | — | **28.90** | 28.67 |
| `2026-10-24 22:56:18` | `966702` | **L4** | `leaderboard` | `crisp_histogram_lastman_u4_cs256.py` | — | **63.44** | 64.12 |
| `2026-10-24 22:59:13` | `966703` | **B200** | `leaderboard` | `crisp_histogram_lastman_4rep_cs256_direct64.py` | — | **17.09** | 17.12 |
| `2026-10-24 23:01:16` | `966708` | **A100** | `leaderboard` | `crisp_histogram_lastman_u4_direct64.py` | — | **23.55** | 23.07 |
