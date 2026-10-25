# Crisp GPU MODE Contest Reports

> Generated from verified runs in `contests/gpu-mode/results/` by `python contests/gpu-mode/report.py --all`.

## Contests

| # | Contest | Detail Report | Leaderboard URL | Workload |
|---|---|---|---|---|
| 01 | **`grayscale_v2`** | [REPORT-grayscale_v2.md](REPORT-grayscale_v2.md) | [Leaderboard #538](https://www.gpumode.com/leaderboard/538?tab=rankings) | Y = 0.2989 R + 0.5870 G + 0.1140 B across 6 square image sizes from 512x512 to 16384x16384 (at 16384x16384: 3.221 GB RGB input read + 1.074 GB grayscale output write = 4.295 GB = 4.00 GiB total DRAM traffic) |
| 02 | **`histogram_v2`** | [REPORT-histogram_v2.md](REPORT-histogram_v2.md) | [Leaderboard #539](https://www.gpumode.com/leaderboard/539?tab=rankings) | 256-bin histogram of 1D uint8 tensor across 6 benchmarks (sizes 1.31M to 10.49M bytes; contention 10%, 40%, 90%; geomean size ~3.13 MB) |
| 03 | **`vectoradd_v2`** | [REPORT-vectoradd_v2.md](REPORT-vectoradd_v2.md) | [Leaderboard #543](https://www.gpumode.com/leaderboard/543?tab=rankings) | C = A + B on two 16384x16384 float16 tensors (536.87 MB each; 1.6106 GB = 1.50 GiB total 2R+1W memory traffic) |
| 04 | **`vectorsum_v2`** | [REPORT-vectorsum_v2.md](REPORT-vectorsum_v2.md) | [Leaderboard #544](https://www.gpumode.com/leaderboard/544?tab=rankings) | Sum reduction of 1D float32 tensor across 6 benchmark sizes from 1,638,400 to 52,428,800 elements |

## Headline Standings Across Hardware

| Contest | GPU | Rank | Public Score | Secret Score | Achieved BW | % of #1 | Winning Crisp Kernel | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|
| [`grayscale_v2`](REPORT-grayscale_v2.md) | **B200** | **#25** / 48 | **601.52 µs** | 605.34 µs | 7.14 TB/s | **98.1%** | [`crisp_grayscale_direct_vec4.py`](03-grayscale-v2/crisp_grayscale_direct_vec4.py) ([`.crisp`](03-grayscale-v2/grayscale_direct_vec4.crisp)) | `2026-10-24 21:58` |
| [`grayscale_v2`](REPORT-grayscale_v2.md) | **H100** | **#25** / 36 | **1379.23 µs** | 1379.64 µs | 3.11 TB/s | **84.5%** | [`crisp_grayscale_direct_vec4.py`](03-grayscale-v2/crisp_grayscale_direct_vec4.py) ([`.crisp`](03-grayscale-v2/grayscale_direct_vec4.crisp)) | `2026-10-24 21:58` |
| [`grayscale_v2`](REPORT-grayscale_v2.md) | **A100** | **#24** / 126 | **2394.84 µs** | 2392.06 µs | 1.79 TB/s | **97.9%** | [`crisp_grayscale_direct_vec4_nc.py`](03-grayscale-v2/crisp_grayscale_direct_vec4_nc.py) ([`.crisp`](03-grayscale-v2/grayscale_direct_vec4_nc.crisp)) | `2026-10-24 21:58` |
| [`grayscale_v2`](REPORT-grayscale_v2.md) | **L4** | **#19** / 30 | **17181.70 µs** | 17181.01 µs | 250.0 GB/s | **92.9%** | [`crisp_grayscale_direct_vec4.py`](03-grayscale-v2/crisp_grayscale_direct_vec4.py) ([`.crisp`](03-grayscale-v2/grayscale_direct_vec4.crisp)) | `2026-10-24 21:58` |
| [`histogram_v2`](REPORT-histogram_v2.md) | **B200** | **#29** / 35 | **17.09 µs** | 17.12 µs | 183.4 GB/s | **55.3%** | [`crisp_histogram_lastman_4rep_cs256_direct64.py`](04-histogram-v2/crisp_histogram_lastman_4rep_cs256_direct64.py) ([`.crisp`](04-histogram-v2/histogram_lastman_4rep_cs256.crisp)) | `2026-10-24 23:04` |
| [`histogram_v2`](REPORT-histogram_v2.md) | **H100** | **#16** / 29 | **14.90 µs** | 16.87 µs | 210.3 GB/s | **59.7%** | [`crisp_histogram_lastman_u4_cs256.py`](04-histogram-v2/crisp_histogram_lastman_u4_cs256.py) ([`.crisp`](04-histogram-v2/histogram_lastman_u4_cs256.crisp)) | `2026-10-24 23:04` |
| [`histogram_v2`](REPORT-histogram_v2.md) | **A100** | **#20** / 28 | **23.55 µs** | 23.07 µs | 133.1 GB/s | **59.2%** | [`crisp_histogram_lastman_u4_direct64.py`](04-histogram-v2/crisp_histogram_lastman_u4_direct64.py) ([`.crisp`](04-histogram-v2/histogram_lastman_u4.crisp)) | `2026-10-24 23:04` |
| [`histogram_v2`](REPORT-histogram_v2.md) | **L4** | **#6** / 20 | **63.44 µs** | 64.12 µs | 49.4 GB/s | **96.8%** | [`crisp_histogram_lastman_u4_cs256.py`](04-histogram-v2/crisp_histogram_lastman_u4_cs256.py) ([`.crisp`](04-histogram-v2/histogram_lastman_u4_cs256.crisp)) | `2026-10-24 23:04` |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **B200** | **#21** / 68 | **233.48 µs** | 232.89 µs | 6.90 TB/s | **96.6%** | [`crisp_b200_inplace_2xhalf4.py`](01-vectoradd-v2/crisp_b200_inplace_2xhalf4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_b200_inplace_2xhalf4.crisp)) | `2026-10-24 21:58` |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **H100** | **#24** / 43 | **526.44 µs** | 526.12 µs | 3.06 TB/s | **97.4%** | [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp)) | `2026-10-24 21:58` |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **A100** | **#56** / 107 | **912.90 µs** | 914.09 µs | 1.76 TB/s | **95.1%** | [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp)) | `2026-10-24 21:58` |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **L4** | **#22** / 38 | **6891.89 µs** | 6916.10 µs | 233.7 GB/s | **88.9%** | [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp)) | `2026-10-24 21:58` |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | **B200** | **#37** / 81 | **49.69 µs** | — | 4.22 TB/s | **74.5%** | [`crisp_vectorsum_lastman_wg_occ1.py`](02-vectorsum-v2/crisp_vectorsum_lastman_wg_occ1.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg.crisp)) | `2026-10-24 21:58` |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | **H100** | **#32** / 67 | **82.81 µs** | 82.68 µs | 2.53 TB/s | **82.0%** | [`crisp_vectorsum_lastman_u8_cs256.py`](02-vectorsum-v2/crisp_vectorsum_lastman_u8_cs256.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg_u8.crisp)) | `2026-10-24 21:58` |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | **A100** | **#63** / 114 | **144.77 µs** | 146.15 µs | 1.45 TB/s | **70.1%** | [`crisp_vectorsum_lastman_u8_cs256.py`](02-vectorsum-v2/crisp_vectorsum_lastman_u8_cs256.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg_u8.crisp)) | `2026-10-24 21:58` |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | **L4** | **#11** / 43 | **866.51 µs** | 866.30 µs | 242.0 GB/s | **79.9%** | [`crisp_vectorsum_lastman_u8_cs256.py`](02-vectorsum-v2/crisp_vectorsum_lastman_u8_cs256.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg_u8.crisp)) | `2026-10-24 21:58` |

## ✨ Beauty Contestants — Idiomatic Crisp Showcase

For each contest, Crisp provides a **Beauty Contestant**: a clean, readable, high-level reference implementation relying strictly on Crisp's built-in abstractions (`loop-vector-stride`, typed views, monomorphic reductions) rather than aggressive hardware-specific micro-tuning or manual loop unrolling.

| Contest | Beauty Kernel (`.crisp`) | SLOC | Primary Abstractions | Best GPU | Beauty Score | % of #1 (`top1`) | % of Tuned Crisp |
|---|---|---:|---|---|---:|---:|---:|
| [`grayscale_v2`](REPORT-grayscale_v2.md) | [`grayscale_beauty.crisp`](03-grayscale-v2/grayscale_beauty.crisp) | 15 | def-function inline device helper, op-fma hardware fused multiply-add | **H100** | 1549.00 µs | **75.2%** | 89.0% |
| [`histogram_v2`](REPORT-histogram_v2.md) | [`histogram_beauty.crisp`](04-histogram-v2/histogram_beauty.crisp) | 18 | make-scratch-vector shared-memory privatization, loop-vector-stride grid-stride loop | **H100** | 22.50 µs | **39.5%** | 66.2% |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | [`vectoradd_beauty.crisp`](01-vectoradd-v2/vectoradd_beauty.crisp) | 18 | make-vector half4 view creation, loop-vector-stride collective streaming | **H100** | 556.50 µs | **92.1%** | 94.6% |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | [`vectorsum_beauty.crisp`](02-vectorsum-v2/vectorsum_beauty.crisp) | 24 | make-vector float4 128-bit view, loop-vector-stride grid-stride loop | **H100** | 93.85 µs | **72.4%** | 88.2% |

## Regenerating & Refreshing Live Standings

```bash
# Regenerate REPORT.md and per-contest reports from saved JSON:
python contests/gpu-mode/report.py --all

# Refresh live rankings/entrant counts from gpumode.com API and regenerate:
python contests/gpu-mode/report.py --refresh --all
```
