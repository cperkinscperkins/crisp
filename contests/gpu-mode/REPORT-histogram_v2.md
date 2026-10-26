# GPU MODE Contest Report: `histogram_v2`

> Generated from [`results/histogram_v2.json`](results/histogram_v2.json) by `python contests/gpu-mode/report.py --all`. Live leaderboard: [https://www.gpumode.com/leaderboard/539?tab=rankings](https://www.gpumode.com/leaderboard/539?tab=rankings) (Crisp commit `0a93bbb2`).

**Workload:** 256-bin histogram of 1D uint8 tensor. task.yml lists 6 benchmarks (1.31M-10.49M bytes; contention 10/40/90%), but kernelbot ranks by RankCriterion.LAST (the default; task.yml sets no ranking_by): the score is the LAST case only, 10,485,760 bytes at 10% contention.

## § 1 — Official Leaderboard Standings

| GPU | Architecture | Rank | Public Score | Secret Score | Achieved BW | % of #1 (`top1`) | Winning Crisp Kernel | Hardware Profile | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|---|
| **B200** | Blackwell (sm_100) | **#29** / 35 | **16.38 µs** | 16.42 µs | 640.2 GB/s | 57.7% (`9.45 µs`) | [`crisp_histogram_lastman_4rep_cs256_adaptive.py`](04-histogram-v2/crisp_histogram_lastman_4rep_cs256_adaptive.py) ([`.crisp`](04-histogram-v2/histogram_lastman_4rep_cs256.crisp)) | — | `2026-10-26 06:21` |
| **H100** | Hopper (sm_90) | **#16** / 29 | **14.90 µs** | 16.87 µs | 703.7 GB/s | 59.7% (`8.89 µs`) | [`crisp_histogram_lastman_u4_cs256.py`](04-histogram-v2/crisp_histogram_lastman_u4_cs256.py) ([`.crisp`](04-histogram-v2/histogram_lastman_u4_cs256.crisp)) | — | `2026-10-26 06:21` |
| **A100** | Ampere (sm_80) | **#20** / 28 | **23.55 µs** | 23.07 µs | 445.3 GB/s | 59.2% (`13.95 µs`) | [`crisp_histogram_lastman_u4_direct64.py`](04-histogram-v2/crisp_histogram_lastman_u4_direct64.py) ([`.crisp`](04-histogram-v2/histogram_lastman_u4.crisp)) | — | `2026-10-26 06:21` |
| **L4** | Ada Lovelace (sm_89) | **#6** / 20 | **63.44 µs** | 64.12 µs | 165.3 GB/s | 96.8% (`61.43 µs`) | [`crisp_histogram_lastman_u4_cs256.py`](04-histogram-v2/crisp_histogram_lastman_u4_cs256.py) ([`.crisp`](04-histogram-v2/histogram_lastman_u4_cs256.crisp)) | — | `2026-10-26 06:21` |

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
| **H100** | Hopper (sm_90) | **22.50 µs** | 466.0 GB/s | **39.5%** (`8.89 µs`) | 66.2% (`14.90 µs`) | [`crisp_histogram_lastman_u4_cs256.py`](04-histogram-v2/crisp_histogram_lastman_u4_cs256.py) | `benchmark` | `#966692` |

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

## § 2 — Technique Ladder & Cross-GPU Ablation (`scored case: 10.49M bytes, 10% contention (ranking_by LAST)`)

Cells show **`benchmark` mean µs** (and **`[LB: public µs]`** when submitted to the official leaderboard). The fastest kernel on each GPU is **bold**.

| Step | Kernel (`.crisp` / `.py`) | Strategy | Regs | Profile | **B200** | **H100** | **A100** | **L4** |
|---|---|---|---:|---|---:|---:|---:|---:|
| 0 | [`histogram_beauty.crisp`](04-histogram-v2/histogram_beauty.crisp) / [`crisp_histogram_beauty.py`](04-histogram-v2/crisp_histogram_beauty.py) | Idiomatic 256-bin workgroup-privatized shared-memory histogram + loop-vector-stride + atomic-inc! + output.zero_() | 24 | — | — | — | — | — |
| 1 | [`histogram_lastman_u4.crisp`](04-histogram-v2/histogram_lastman_u4.crisp) / [`crisp_histogram_lastman_u4.py`](04-histogram-v2/crisp_histogram_lastman_u4.py) | Single-launch Last-Man + 8x warp-privatized shared-memory histogram (8 KB) + 128-bit uint4 loads + Run-of-4 collapse (+4u) | 36 | — | — | 16.8 | — | — |
| 1b | [`histogram_lastman_u4.crisp`](04-histogram-v2/histogram_lastman_u4.crisp) / [`crisp_histogram_lastman_u4_direct64.py`](04-histogram-v2/crisp_histogram_lastman_u4_direct64.py) | Single-launch Last-Man + 8x warp-privatized shared-memory histogram (8 KB) + uint4 Run-of-4 + fine-grained 64B/thread grid (full SM saturation on 1.31M/2.62M) | 36 | — | — | — | **`LB: 23.55`** | — |
| 2 | [`histogram_lastman_u4_cs256.crisp`](04-histogram-v2/histogram_lastman_u4_cs256.crisp) / [`crisp_histogram_lastman_u4_cs256.py`](04-histogram-v2/crisp_histogram_lastman_u4_cs256.py) | Single-launch Last-Man + 8x warp-privatized shared-memory histogram + uint4 Run-of-4 + :cache (:streaming :prefetch 256) | 36 | — | `LB: 19.97` | **16.7 (`LB: 14.90`)** | `LB: 28.90` | **`LB: 63.44`** |
| 2b | [`histogram_lastman_u4_cs256.crisp`](04-histogram-v2/histogram_lastman_u4_cs256.crisp) / [`crisp_histogram_lastman_u4_cs256_adaptive.py`](04-histogram-v2/crisp_histogram_lastman_u4_cs256_adaptive.py) | Step 2 kernel + size-adaptive grid: 64 B/thread up to 4 MiB, 128 B/thread above (uncapped CTA count) | 36 | — | — | `LB: 15.39` | `LB: 25.67` | — |
| 3 | [`histogram_lastman_4rep_cs256.crisp`](04-histogram-v2/histogram_lastman_4rep_cs256.crisp) / [`crisp_histogram_lastman_4rep_cs256_direct64.py`](04-histogram-v2/crisp_histogram_lastman_4rep_cs256_direct64.py) | Single-launch Last-Man + 4x warp-pair shared-memory histogram (4 KB) + uint4 Run-of-4 + :cache (:streaming :prefetch 256) + 64B/thread grid | 34 | — | `LB: 17.09` | — | — | — |
| 3b | [`histogram_lastman_4rep_cs256.crisp`](04-histogram-v2/histogram_lastman_4rep_cs256.crisp) / [`crisp_histogram_lastman_4rep_cs256_adaptive.py`](04-histogram-v2/crisp_histogram_lastman_4rep_cs256_adaptive.py) | Step 3 kernel + size-adaptive grid: 64 B/thread up to 4 MiB, 128 B/thread above | 34 | — | **`LB: 16.38`** | — | — | — |
| 4 | [`histogram_lastman_16rep.crisp`](04-histogram-v2/histogram_lastman_16rep.crisp) / [`crisp_histogram_lastman_16rep.py`](04-histogram-v2/crisp_histogram_lastman_16rep.py) | Single-launch Last-Man + 16x sub-warp-privatized shared-memory histogram (16 KB) + uint4 Run-of-4 (+4u) collapse | 36 | — | — | 18.5 | — | — |
| 5 | [`histogram_lastman_16rep_run16.crisp`](04-histogram-v2/histogram_lastman_16rep_run16.crisp) / [`crisp_histogram_lastman_16rep_run16.py`](04-histogram-v2/crisp_histogram_lastman_16rep_run16.py) | Single-launch Last-Man + 16x sub-warp-privatized shared-memory histogram (16 KB) + Two-level Run-of-16 (+16u) & Run-of-4 (+4u) collapse | 38 | — | — | 20.0 | — | — |

## § 3 — Key Architectural Takeaways

1. **Only the last benchmark is scored:** kernelbot's `LeaderboardTask.ranking_by` defaults to `RankCriterion.LAST`, and `histogram_py/task.yml` does not override it, so the leaderboard score is the 10.49M-byte / 10%-contention case alone (popcorn still labels it "Geomean"). Evidence: L4's 63.44 µs matches its 10.49M time (63.49 µs) while its 6-case geomean is 27.98 µs. Consequences: contention never enters the score, and small-size wins do not count. `--mode benchmark` also times only that one case.
2. **Single-Launch Last-Man Global Bin Reduction + 128-Bit `uint4` Run-of-4 Collapse (`histogram_lastman_u4_cs256.crisp`):** Replacing the two-launch `output.zero_()` + scalar `uchar` shared-memory baseline (`22.5 µs` on H100) with a single-launch Last-Man pattern (`partials[0..255]` + `ticket` reset to 0 by the last CTA via `atomic-xchg!`), 128-bit `uint4` (16 bytes/load) vectorization, and a per-word Run-of-4 check (`(= w (* (logand w 255u) 16843009u))` -> single `atomic-add! +4u`) cut H100 10 MB runtime by **5.8 µs (−25.8%)** down to **16.7 ± 0.03 µs** (**14.90 µs public geomean**).
3. **Grid sizing at the scored size:** bytes/thread matters more than replication count. At 10.49M on H100, 128 B/thread = 15.10 µs vs 16.29 µs at 256 B/thread (CTA count capped by 2xSMs) and 17.73 µs at 64 B/thread; L4 prefers 256. The size-adaptive entries (steps 2b/3b) moved B200 from 17.09 to 16.38 µs; on H100 and A100 the leaderboard runs landed within machine-to-machine noise (H100 public/secret swapped between runs, ~±10%).
4. **Where the time goes (H100, scored case, per-case diagnostic):** empty-kernel floor 4.96 µs; raw uint4 read of the input 10.9 µs; + shared-memory zero/sync/reduce/merge structure ~1.9 µs; + shared atomics ~2.4 µs = 15.2 µs. Hand-written nvcc read kernels take the same ~10.5-11 µs as Crisp's loop, so Crisp's codegen is not the gap. Fence strength (`membar.gl` vs `fence.acq_rel.gpu`) and the last-man tail cost ~0; unroll 8 is slower; cache hints save ~0.2 µs. #1 (8.89 µs) beats a plain read of the input by ~2 µs.
5. **Negative results:** warp aggregation (`match.any`/ballot) cannot help the scored 10%-contention case (a conflict-free probe ceiling was ~0.4 µs even on the full 6-case mix). Per-thread private uchar counters with no atomics (correct, lane-own-bank layout, 64 KB smem) were slower: 17.4 vs 15.2 µs; one shared atomic per byte beats a shared load + store per byte.
6. **Hardware Bit-Field Extraction (`bfe.u32`) via Power-of-2 Division:** Writing byte extraction in Crisp as `(logand (/ w 256u) 255u)` and `(logand (/ w 65536u) 255u)` lowers directly through LLVM NVPTX to single-instruction hardware bit-field extracts (`bfe.u32 %r, %w, 8, 8` and `bfe.u32 %r, %w, 16, 8`), whereas `(ash w -8)` invokes the variable-shift helper `__crisp_ash_uint`.
7. **Compiler bugs found:** BUG 139 (`=> nil` def-function whose `if` mixes a value branch and a void branch emits `store void`; llc fails), BUG 138 (on PTX, `ash`/`popcount` lower to `noinline` helper calls, hence the `(/ w 256u)` idiom above), BUG 140 (CUDA hoist sizes uchar/ushort shared scratch at 4 bytes/element). All in `plan/bugs.md`.

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
| `2026-10-26 01:31:05` | `967741` | **H100** | `leaderboard` | `crisp_histogram_lastman_u4_cs256_adaptive.py` | — | **15.39** | 13.36 |
| `2026-10-26 01:31:05` | `967742` | **A100** | `leaderboard` | `crisp_histogram_lastman_u4_cs256_adaptive.py` | — | **25.67** | 25.60 |
| `2026-10-26 01:31:05` | `967740` | **B200** | `leaderboard` | `crisp_histogram_lastman_4rep_cs256_adaptive.py` | — | **16.38** | 16.42 |
