# Crisp GPU MODE Contest Reports

> Generated from verified runs in `contests/gpu-mode/results/` by `python contests/gpu-mode/report.py --all`.

## Contests

| # | Contest | Detail Report | Leaderboard URL | Workload |
|---|---|---|---|---|
| 01 | **`vectoradd_v2`** | [REPORT-vectoradd_v2.md](REPORT-vectoradd_v2.md) | [Leaderboard #543](https://www.gpumode.com/leaderboard/543?tab=rankings) | C = A + B on two 16384x16384 float16 tensors (536.87 MB each; 1.6106 GB = 1.50 GiB total 2R+1W memory traffic) |
| 02 | **`vectorsum_v2`** | [REPORT-vectorsum_v2.md](REPORT-vectorsum_v2.md) | [Leaderboard #544](https://www.gpumode.com/leaderboard/544?tab=rankings) | Sum reduction of 1D float32 tensor across 6 benchmark sizes from 1,638,400 to 52,428,800 elements |

## Headline Standings Across Hardware

| Contest | GPU | Rank | Public Score | Secret Score | Achieved BW | % of #1 | Winning Crisp Kernel | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **B200** | **#21** / 68 | **233.48 µs** | 232.89 µs | 6.90 TB/s | **96.6%** | [`crisp_b200_inplace_2xhalf4.py`](01-vectoradd-v2/crisp_b200_inplace_2xhalf4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_b200_inplace_2xhalf4.crisp)) | `2026-10-24 20:11` |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **H100** | **#24** / 43 | **526.44 µs** | 526.12 µs | 3.06 TB/s | **97.4%** | [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp)) | `2026-10-24 20:11` |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **A100** | **#56** / 107 | **912.90 µs** | 914.09 µs | 1.76 TB/s | **95.1%** | [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp)) | `2026-10-24 20:11` |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **L4** | **#22** / 38 | **6891.89 µs** | 6916.10 µs | 233.7 GB/s | **88.9%** | [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp)) | `2026-10-24 20:11` |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | **B200** | **#37** / 81 | **49.69 µs** | — | 4.22 TB/s | **74.5%** | [`crisp_vectorsum_lastman_wg_occ1.py`](02-vectorsum-v2/crisp_vectorsum_lastman_wg_occ1.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg.crisp)) | `2026-10-24 20:11` |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | **H100** | **#32** / 67 | **82.81 µs** | 82.68 µs | 2.53 TB/s | **82.0%** | [`crisp_vectorsum_lastman_u8_cs256.py`](02-vectorsum-v2/crisp_vectorsum_lastman_u8_cs256.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg_u8.crisp)) | `2026-10-24 20:11` |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | **A100** | **#63** / 114 | **144.77 µs** | 146.15 µs | 1.45 TB/s | **70.1%** | [`crisp_vectorsum_lastman_u8_cs256.py`](02-vectorsum-v2/crisp_vectorsum_lastman_u8_cs256.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg_u8.crisp)) | `2026-10-24 20:11` |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | **L4** | **#11** / 43 | **866.51 µs** | 866.30 µs | 242.0 GB/s | **79.9%** | [`crisp_vectorsum_lastman_u8_cs256.py`](02-vectorsum-v2/crisp_vectorsum_lastman_u8_cs256.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg_u8.crisp)) | `2026-10-24 20:11` |

## ✨ Beauty Contestants — Idiomatic Crisp Showcase

For each contest, Crisp provides a **Beauty Contestant**: a clean, readable, high-level reference implementation relying strictly on Crisp's built-in abstractions (`loop-vector-stride`, typed views, monomorphic reductions) rather than aggressive hardware-specific micro-tuning or manual loop unrolling.

| Contest | Beauty Kernel (`.crisp`) | SLOC | Primary Abstractions | Best GPU | Beauty Score | % of #1 (`top1`) | % of Tuned Crisp |
|---|---|---:|---|---|---:|---:|---:|
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | [`vectoradd_beauty.crisp`](01-vectoradd-v2/vectoradd_beauty.crisp) | 18 | make-vector half4 view creation, loop-vector-stride collective streaming | **H100** | 556.50 µs | **92.1%** | 94.6% |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | [`vectorsum_beauty.crisp`](02-vectorsum-v2/vectorsum_beauty.crisp) | 24 | make-vector float4 128-bit view, loop-vector-stride grid-stride loop | **H100** | 93.85 µs | **72.4%** | 88.2% |

## Regenerating & Refreshing Live Standings

```bash
# Regenerate REPORT.md and per-contest reports from saved JSON:
python contests/gpu-mode/report.py --all

# Refresh live rankings/entrant counts from gpumode.com API and regenerate:
python contests/gpu-mode/report.py --refresh --all
```
