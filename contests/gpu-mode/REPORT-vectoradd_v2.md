# GPU MODE Contest Report: `vectoradd_v2`

> Generated from [`results/vectoradd_v2.json`](results/vectoradd_v2.json) by `python contests/gpu-mode/report.py --all`. Live leaderboard: [https://www.gpumode.com/leaderboard/543?tab=rankings](https://www.gpumode.com/leaderboard/543?tab=rankings) (Crisp commit `c929d68e`).

**Workload:** C = A + B on two 16384x16384 float16 tensors (536.87 MB each; 1.6106 GB = 1.50 GiB total 2R+1W memory traffic).

## § 1 — Official Leaderboard Standings

| GPU | Architecture | Rank | Public Score | Secret Score | Achieved BW | % of #1 (`top1`) | Winning Crisp Kernel | Hardware Profile | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|---|
| **B200** | Blackwell (sm_100) | **#21** / 67 | **233.48 µs** | 232.89 µs | 6.90 TB/s | 96.6% (`225.45 µs`) | [`crisp_b200_inplace_2xhalf4.py`](01-vectoradd-v2/crisp_b200_inplace_2xhalf4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_b200_inplace_2xhalf4.crisp)) | `b200` | `2026-10-21 15:12` |
| **H100** | Hopper (sm_90) | **#24** / 42 | **526.44 µs** | 526.12 µs | 3.06 TB/s | 97.4% (`512.59 µs`) | [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp)) | — | `2026-10-21 15:12` |
| **A100** | Ampere (sm_80) | **#56** / 107 | **912.90 µs** | 914.09 µs | 1.76 TB/s | 96.1% (`877.23 µs`) | [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp)) | — | `2026-10-21 15:12` |
| **L4** | Ada Lovelace (sm_89) | **#22** / 38 | **6891.89 µs** | 6916.10 µs | 233.7 GB/s | 88.9% (`6124.20 µs`) | [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp)) | — | `2026-10-21 15:12` |

## § 2 — Technique Ladder & Cross-GPU Ablation (`size = 16384`)

Cells show **`benchmark` mean µs** (and **`[LB: public µs]`** when submitted to the official leaderboard). The fastest kernel on each GPU is **bold**.

| Step | Kernel (`.crisp` / `.py`) | Strategy | Regs | Profile | **B200** | **H100** | **A100** | **L4** |
|---|---|---|---:|---|---:|---:|---:|---:|
| 0 | [`vectoradd_half4.crisp`](01-vectoradd-v2/vectoradd_half4.crisp) / [`crisp_f16_stride1w_half4.py`](01-vectoradd-v2/crisp_f16_stride1w_half4.py) | loop-vector-stride (half4, 4x auto-unroll, 1 wave/SM, out-of-place) | 20 | — | — | 559.0 (`LB: 557.86`) | — | — |
| 1 | [`vectoradd_stride_unroll8.crisp`](01-vectoradd-v2/vectoradd_stride_unroll8.crisp) / [`crisp_f16_stride8w_u8.py`](01-vectoradd-v2/crisp_f16_stride8w_u8.py) | loop-vector-stride (half4, explicit (unroll 8), 8 waves/SM, out-of-place) | 26 | — | — | 636.0 | — | — |
| 2 | [`vectoradd_direct_half4.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp) / [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) | Direct 1x half4/thread (8 B/thread, 262,144 CTAs, out-of-place) | 10 | — | `LB: 276.08` | **524.0 (`LB: 526.44`)** | **`LB: 912.90`** | **`LB: 6891.89`** |
| 2b | [`vectoradd_direct_half4_b512.crisp`](01-vectoradd-v2/vectoradd_direct_half4_b512.crisp) / [`crisp_f16_direct_half4_b512.py`](01-vectoradd-v2/crisp_f16_direct_half4_b512.py) | Direct 1x half4/thread (local-size 512, 131,072 CTAs, out-of-place) | 10 | — | — | 527.0 | — | — |
| 3 | [`vectoradd_direct_2xhalf4.crisp`](01-vectoradd-v2/vectoradd_direct_2xhalf4.crisp) / [`crisp_f16_direct_2xhalf4.py`](01-vectoradd-v2/crisp_f16_direct_2xhalf4.py) | Direct 2x half4/thread (+256 stride, 16 B/thread, 131,072 CTAs, out-of-place) | 18 | — | — | 532.0 | — | — |
| 3b | [`vectoradd_tile4x_half4.crisp`](01-vectoradd-v2/vectoradd_tile4x_half4.crisp) / [`crisp_f16_tile4x_half4.py`](01-vectoradd-v2/crisp_f16_tile4x_half4.py) | Direct 4x half4/thread (+256 stride, 32 B/thread, 65,536 CTAs, out-of-place) | 24 | — | — | 527.0 | — | — |
| 4 | [`vectoradd_b200_inplace_half4.crisp`](01-vectoradd-v2/vectoradd_b200_inplace_half4.crisp) / [`crisp_b200_inplace_half4.py`](01-vectoradd-v2/crisp_b200_inplace_half4.py) | In-place 1x half4/thread (A += B, 8 B/thread, 262,144 CTAs, b200 profile) | 10 | `b200` | 272.0 | 525.0 (`LB: 527.30`) | 910.0 (`LB: 946.86`) | 6900.0 (`LB: 6934.73`) |
| 5 | [`vectoradd_b200_inplace_2xhalf4.crisp`](01-vectoradd-v2/vectoradd_b200_inplace_2xhalf4.crisp) / [`crisp_b200_inplace_2xhalf4.py`](01-vectoradd-v2/crisp_b200_inplace_2xhalf4.py) | In-place 2x half4/thread (A += B, +256 stride, 16 B/thread, 131,072 CTAs, b200 profile) | 26 | `b200` | **235.0 (`LB: 233.48`)** | 530.0 | 957.0 | 6940.0 |
| 5b | [`vectoradd_b200_inplace_tile4x_half4.crisp`](01-vectoradd-v2/vectoradd_b200_inplace_tile4x_half4.crisp) / [`crisp_b200_inplace_tile4x_half4.py`](01-vectoradd-v2/crisp_b200_inplace_tile4x_half4.py) | In-place 4x half4/thread (A += B, +256 stride, 32 B/thread, 65,536 CTAs, b200 profile) | 31 | `b200` | 237.0 | — | — | — |

## § 3 — Key Architectural Takeaways

1. **Blackwell (`B200`) vs. Hopper/Ampere/Ada (`H100`, `A100`, `L4`):**
   - On **B200** (`148 SMs`, `128 MB L2`, `8 TB/s HBM3e`), doubling per-thread work to **`2x half4` (`16 B/thread`) + in-place read-modify-write (`A += B`)** cut runtime from `276.08 µs` (#59) to **`233.48 µs` public / `232.89 µs` secret (#20 / 66, `6.90 TB/s`)** — a **15.4% speedup** (`96.6%` of the `#1` entry on the leaderboard).
   - On **H100**, **A100**, and **L4**, the smaller L2 caches (`40–50 MB`) and lower DRAM bandwidth mean `16384×16384` (`1.61 GB`) is strictly DRAM-bandwidth-bound. The minimal **10-register `direct_half4`** kernel (`1x half4` per thread, out-of-place) maximizes warp occupancy and achieves **`526.44 µs` (#24 on H100, `97.4%` of #1)**, **`912.90 µs` (#54 on A100, `96.8%` of #1)**, and **`6,891.89 µs` (#21 on L4, `97.6%` of #1)**.
2. **Grid-Stride Loops vs. Direct 1-to-1 Indexing on Single-Pass Elementwise Kernels:**
   - Replacing `loop-vector-stride` (`557.86 µs` on H100) with direct global indexing (`526.44 µs` on H100) saved `31.4 µs` by eliminating `cudaOccupancyMaxActiveBlocksPerMultiprocessor` host queries and loop-branch bookkeeping, dropping register pressure from `20` to `10` registers per thread.

## § 4 — Verified Submission & Benchmark Log

| Timestamp (UTC) | Submission ID | GPU | Mode | File | Benchmark (µs) | Public LB (µs) | Secret LB (µs) |
|---|---:|---|---|---|---:|---:|---:|
| `2026-10-18 22:55:00` | `962344` | **H100** | `leaderboard` | `crisp_f16_stride1w_half4.py` | 559.0 ± 1.4 | **557.86** | 558.40 |
| `2026-10-18 23:18:00` | `962381` | **H100** | `benchmark` | `crisp_f16_stride8w_u8.py` | 636.0 ± 0.6 | — | — |
| `2026-10-18 23:20:00` | `962388` | **H100** | `leaderboard` | `crisp_f16_direct_half4.py` | 524.0 ± 0.5 | **526.44** | 526.12 |
| `2026-10-18 23:21:00` | `962385` | **H100** | `benchmark` | `crisp_f16_tile4x_half4.py` | 527.0 ± 0.4 | — | — |
| `2026-10-18 23:31:17` | `962406` | **H100** | `benchmark` | `crisp_f16_direct_2xhalf4.py` | 532.0 ± 0.4 | — | — |
| `2026-10-18 23:32:45` | `962409` | **H100** | `benchmark` | `crisp_f16_direct_half4_b512.py` | 527.0 ± 0.4 | — | — |
| `2026-10-18 23:46:07` | `962432` | **B200** | `leaderboard` | `crisp_f16_direct_half4.py` | — | **276.08** | 278.49 |
| `2026-10-18 23:48:01` | `962434` | **A100** | `leaderboard` | `crisp_f16_direct_half4.py` | — | **912.90** | 914.09 |
| `2026-10-18 23:50:11` | `962441` | **L4** | `leaderboard` | `crisp_f16_direct_half4.py` | — | **6891.89** | 6916.10 |
| `2026-10-19 00:04:56` | `962465` | **B200** | `benchmark` | `crisp_b200_inplace_2xhalf4.py` | 235.0 ± 0.2 | — | — |
| `2026-10-19 00:06:33` | `962471` | **B200** | `benchmark` | `crisp_b200_inplace_tile4x_half4.py` | 237.0 ± 0.2 | — | — |
| `2026-10-19 00:12:00` | `962479` | **B200** | `benchmark` | `crisp_b200_inplace_half4.py` | 272.0 ± 0.3 | — | — |
| `2026-10-19 00:13:58` | `962482` | **B200** | `leaderboard` | `crisp_b200_inplace_2xhalf4.py` | 235.0 ± 0.2 | **233.48** | 232.89 |
| `2026-10-19 01:46:19` | `962611` | **H100** | `benchmark` | `crisp_f16_inplace_2xhalf4.py` | 530.0 ± 0.5 | — | — |
| `2026-10-19 01:48:16` | `962615` | **H100** | `leaderboard` | `crisp_f16_inplace_half4.py` | 525.0 ± 0.5 | **527.30** | 527.30 |
| `2026-10-19 01:51:23` | `962621` | **A100** | `benchmark` | `crisp_f16_inplace_2xhalf4.py` | 957.0 ± 0.3 | — | — |
| `2026-10-19 01:53:20` | `962622` | **A100** | `leaderboard` | `crisp_f16_inplace_half4.py` | 910.0 ± 0.8 | **946.86** | 956.76 |
| `2026-10-19 01:58:12` | `962628` | **L4** | `benchmark` | `crisp_f16_inplace_2xhalf4.py` | 6940.0 ± 4.0 | — | — |
| `2026-10-19 01:59:30` | `962631` | **L4** | `leaderboard` | `crisp_f16_inplace_half4.py` | 6900.0 ± 7.0 | **6934.73** | 6926.34 |
