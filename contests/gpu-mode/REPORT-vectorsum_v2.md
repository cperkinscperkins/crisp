# GPU MODE Contest Report: `vectorsum_v2`

> Generated from [`results/vectorsum_v2.json`](results/vectorsum_v2.json) by `python contests/gpu-mode/report.py --all`. Live leaderboard: [https://www.gpumode.com/leaderboard/544?tab=rankings](https://www.gpumode.com/leaderboard/544?tab=rankings) (Crisp commit `c929d68e`).

**Workload:** Sum reduction of 1D float32 tensor across 6 benchmark sizes from 1,638,400 to 52,428,800 elements.

## § 1 — Official Leaderboard Standings

| GPU | Architecture | Rank | Public Score | Secret Score | Achieved BW | % of #1 (`top1`) | Winning Crisp Kernel | Hardware Profile | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|---|
| **B200** | Blackwell (sm_100) | **#73** / 81 | **89.44 µs** | — | 0.0 GB/s | 41.4% (`37.03 µs`) | [`crisp_vectorsum_b200_2xfloat4.py`](02-vectorsum-v2/crisp_vectorsum_b200_2xfloat4.py) ([`.crisp`](02-vectorsum-v2/vectorsum_b200_2xfloat4.crisp)) | `b200` | `2026-10-21 15:12` |
| **H100** | Hopper (sm_90) | **#55** / 66 | **88.81 µs** | — | 0.0 GB/s | 76.5% (`67.92 µs`) | [`baseline_torch.py`](02-vectorsum-v2/baseline_torch.py) ([`.crisp`](02-vectorsum-v2/baseline_torch.py)) | — | `2026-10-21 15:12` |
| **A100** | Ampere (sm_80) | **#102** / 114 | **164.36 µs** | — | 0.0 GB/s | 71.1% (`116.89 µs`) | [`crisp_vectorsum_warp_reduce.py`](02-vectorsum-v2/crisp_vectorsum_warp_reduce.py) ([`.crisp`](02-vectorsum-v2/vectorsum_warp_reduce.crisp)) | — | `2026-10-21 15:12` |
| **L4** | Ada Lovelace (sm_89) | **#37** / 43 | **974.52 µs** | — | 0.0 GB/s | 71.0% (`692.02 µs`) | [`crisp_vectorsum_warp_reduce.py`](02-vectorsum-v2/crisp_vectorsum_warp_reduce.py) ([`.crisp`](02-vectorsum-v2/vectorsum_warp_reduce.crisp)) | — | `2026-10-21 15:12` |

## § 2 — Technique Ladder & Cross-GPU Ablation (`size = 16384`)

Cells show **`benchmark` mean µs** (and **`[LB: public µs]`** when submitted to the official leaderboard). The fastest kernel on each GPU is **bold**.

| Step | Kernel (`.crisp` / `.py`) | Strategy | Regs | Profile | **B200** | **H100** | **A100** | **L4** |
|---|---|---|---:|---|---:|---:|---:|---:|
| 0 | [`baseline_torch.py`](02-vectorsum-v2/baseline_torch.py) / [`baseline_torch.py`](02-vectorsum-v2/baseline_torch.py) | PyTorch native inp.sum() reference | None | — | — | **87.8** | — | — |
| 1 | [`vectorsum_warp_reduce.crisp`](02-vectorsum-v2/vectorsum_warp_reduce.crisp) / [`crisp_vectorsum_warp_reduce.py`](02-vectorsum-v2/crisp_vectorsum_warp_reduce.py) | float4 (128-bit) vector loads + 4 independent accumulators + warp shuffle-xor + SLM warp reduction + atomic add | 24 | — | — | 100.0 (`LB: 101.01`) | **`LB: 164.36`** | **`LB: 974.52`** |
| 2 | [`vectorsum_b200_2xfloat4.crisp`](02-vectorsum-v2/vectorsum_b200_2xfloat4.crisp) / [`crisp_vectorsum_b200_2xfloat4.py`](02-vectorsum-v2/crisp_vectorsum_b200_2xfloat4.py) | 2x float4 (128-bit) vector loads (32 B/thread) + 8 accumulators + b200 hardware profile + warp shuffle-xor + SLM reduction + atomic add | 28 | `b200` | **`LB: 89.44`** | — | — | — |

## § 3 — Key Architectural Takeaways

1. **Blackwell (`B200`) vs. Hopper/Ampere/Ada (`H100`, `A100`, `L4`):**
   - On **B200** (`148 SMs`, `128 MB L2`, `8 TB/s HBM3e`), doubling per-thread work to **`2x half4` (`16 B/thread`) + in-place read-modify-write (`A += B`)** cut runtime from `276.08 µs` (#59) to **`233.48 µs` public / `232.89 µs` secret (#20 / 66, `6.90 TB/s`)** — a **15.4% speedup** (`96.6%` of the `#1` entry on the leaderboard).
   - On **H100**, **A100**, and **L4**, the smaller L2 caches (`40–50 MB`) and lower DRAM bandwidth mean `16384×16384` (`1.61 GB`) is strictly DRAM-bandwidth-bound. The minimal **10-register `direct_half4`** kernel (`1x half4` per thread, out-of-place) maximizes warp occupancy and achieves **`526.44 µs` (#24 on H100, `97.4%` of #1)**, **`912.90 µs` (#54 on A100, `96.8%` of #1)**, and **`6,891.89 µs` (#21 on L4, `97.6%` of #1)**.
2. **Grid-Stride Loops vs. Direct 1-to-1 Indexing on Single-Pass Elementwise Kernels:**
   - Replacing `loop-vector-stride` (`557.86 µs` on H100) with direct global indexing (`526.44 µs` on H100) saved `31.4 µs` by eliminating `cudaOccupancyMaxActiveBlocksPerMultiprocessor` host queries and loop-branch bookkeeping, dropping register pressure from `20` to `10` registers per thread.

## § 4 — Verified Submission & Benchmark Log

| Timestamp (UTC) | Submission ID | GPU | Mode | File | Benchmark (µs) | Public LB (µs) | Secret LB (µs) |
|---|---:|---|---|---|---:|---:|---:|
| `2026-10-20 03:45:32` | `963689` | **H100** | `benchmark` | `baseline_torch.py` | 87.8 ± 0.1 | — | — |
| `2026-10-20 04:46:12` | `None` | **H100** | `test` | `crisp_vectorsum_warp_reduce.py` | — | — | — |
| `2026-10-20 05:53:40` | `None` | **H100** | `test` | `crisp_vectorsum_warp_reduce.py` | — | — | — |
| `2026-10-20 06:54:37` | `963712` | **H100** | `test` | `crisp_vectorsum_warp_reduce.py` | — | — | — |
| `2026-10-20 14:30:02` | `None` | **H100** | `leaderboard` | `crisp_vectorsum_warp_reduce.py` | — | — | — |
| `2026-10-20 14:41:44` | `963771` | **H100** | `benchmark` | `crisp_vectorsum_warp_reduce.py` | 92.3 ± 0.1 | — | — |
| `2026-10-20 14:53:28` | `None` | **H100** | `leaderboard` | `crisp_vectorsum_warp_reduce.py` | — | — | — |
| `2026-10-21 05:50:47` | `964099` | **H100** | `benchmark` | `crisp_vectorsum_warp_reduce.py` | 89.4 ± 0.1 | — | — |
| `2026-10-21 05:52:57` | `None` | **H100** | `leaderboard` | `crisp_vectorsum_warp_reduce.py` | — | — | — |
| `2026-10-21 06:43:34` | `964111` | **H100** | `benchmark` | `crisp_vectorsum_warp_reduce.py` | 100.0 ± 0.1 | — | — |
| `2026-10-21 06:45:31` | `964112` | **H100** | `leaderboard` | `crisp_vectorsum_warp_reduce.py` | — | **101.01** | 100.88 |
| `2026-10-21 06:47:50` | `964113` | **B200** | `leaderboard` | `crisp_vectorsum_b200_2xfloat4.py` | — | **89.44** | 88.26 |
| `2026-10-21 06:51:00` | `964114` | **A100** | `leaderboard` | `crisp_vectorsum_warp_reduce.py` | — | **164.36** | 158.60 |
| `2026-10-21 15:12:28` | `964189` | **L4** | `leaderboard` | `crisp_vectorsum_warp_reduce.py` | — | **974.52** | 975.70 |
