# Crisp GPU MODE Contest Reports

> Generated from verified runs in `contests/gpu-mode/results/` by `python contests/gpu-mode/report.py --all`.

## Contests

| # | Contest | Detail Report | Leaderboard URL | Workload |
|---|---|---|---|---|
| 01 | **`grayscale_v2`** | [REPORT-grayscale_v2.md](REPORT-grayscale_v2.md) | [Leaderboard #538](https://www.gpumode.com/leaderboard/538?tab=rankings) | Y = 0.2989 R + 0.5870 G + 0.1140 B across 6 square image sizes from 512x512 to 16384x16384 (at 16384x16384: 3.221 GB RGB input read + 1.074 GB grayscale output write = 4.295 GB = 4.00 GiB total DRAM traffic) |
| 02 | **`histogram_v2`** | [REPORT-histogram_v2.md](REPORT-histogram_v2.md) | [Leaderboard #539](https://www.gpumode.com/leaderboard/539?tab=rankings) | 256-bin histogram of 1D uint8 tensor. task.yml lists 6 benchmarks (1.31M-10.49M bytes; contention 10/40/90%), but kernelbot ranks by RankCriterion.LAST (the default; task.yml sets no ranking_by): the score is the LAST case only, 10,485,760 bytes at 10% contention |
| 03 | **`matmul_v2`** | [REPORT-matmul_v2.md](REPORT-matmul_v2.md) | [Leaderboard #540](https://www.gpumode.com/leaderboard/540?tab=rankings) | C = A @ B with A (M K) and B (K N) row-major fp16, C fp16. task.yml lists 8 benchmarks (128^3 .. 4096x5120x4096); kernelbot ranks by RankCriterion.LAST, so the score is the LAST case only: m=4096 n=5120 k=4096 (171.8 GFLOP). Correctness is checked on the benchmark inputs too at rtol 1e-5: bit-exact fp16 against cuBLAS. |
| 04 | **`prefixsum_v2`** | [REPORT-prefixsum_v2.md](REPORT-prefixsum_v2.md) | [Leaderboard #541](https://www.gpumode.com/leaderboard/541?tab=rankings) | Inclusive prefix sum (cumsum) of 1D float32 tensor across 11 benchmark sizes from 262,144 to 268,435,456 elements |
| 05 | **`vectoradd_v2`** | [REPORT-vectoradd_v2.md](REPORT-vectoradd_v2.md) | [Leaderboard #543](https://www.gpumode.com/leaderboard/543?tab=rankings) | C = A + B on two 16384x16384 float16 tensors (536.87 MB each; 1.6106 GB = 1.50 GiB total 2R+1W memory traffic) |
| 06 | **`vectorsum_v2`** | [REPORT-vectorsum_v2.md](REPORT-vectorsum_v2.md) | [Leaderboard #544](https://www.gpumode.com/leaderboard/544?tab=rankings) | Sum reduction of 1D float32 tensor across 6 benchmark sizes from 1,638,400 to 52,428,800 elements |

## Headline Standings Across Hardware

| Contest | GPU | Rank | Public Score | Secret Score | Achieved BW / TFLOPS | % of #1 | Winning Crisp Kernel | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|
| [`grayscale_v2`](REPORT-grayscale_v2.md) | **B200** | **#24** / 47 | **601.52 µs** | 605.34 µs | 7.14 TB/s | **98.1%** | [`crisp_grayscale_direct_vec4.py`](03-grayscale-v2/crisp_grayscale_direct_vec4.py) ([`.crisp`](03-grayscale-v2/grayscale_direct_vec4.crisp)) | `2026-10-30 06:19` |
| [`grayscale_v2`](REPORT-grayscale_v2.md) | **H100** | **#25** / 36 | **1379.23 µs** | 1379.64 µs | 3.11 TB/s | **84.5%** | [`crisp_grayscale_direct_vec4.py`](03-grayscale-v2/crisp_grayscale_direct_vec4.py) ([`.crisp`](03-grayscale-v2/grayscale_direct_vec4.crisp)) | `2026-10-30 06:19` |
| [`grayscale_v2`](REPORT-grayscale_v2.md) | **A100** | **#23** / 126 | **2394.84 µs** | 2392.06 µs | 1.79 TB/s | **97.9%** | [`crisp_grayscale_direct_vec4_nc.py`](03-grayscale-v2/crisp_grayscale_direct_vec4_nc.py) ([`.crisp`](03-grayscale-v2/grayscale_direct_vec4_nc.crisp)) | `2026-10-30 06:19` |
| [`grayscale_v2`](REPORT-grayscale_v2.md) | **L4** | **#19** / 31 | **17181.70 µs** | 17181.01 µs | 250.0 GB/s | **92.9%** | [`crisp_grayscale_direct_vec4.py`](03-grayscale-v2/crisp_grayscale_direct_vec4.py) ([`.crisp`](03-grayscale-v2/grayscale_direct_vec4.crisp)) | `2026-10-30 06:19` |
| [`histogram_v2`](REPORT-histogram_v2.md) | **B200** | **#29** / 35 | **16.38 µs** | 16.42 µs | 640.2 GB/s | **57.7%** | [`crisp_histogram_lastman_4rep_cs256_adaptive.py`](04-histogram-v2/crisp_histogram_lastman_4rep_cs256_adaptive.py) ([`.crisp`](04-histogram-v2/histogram_lastman_4rep_cs256.crisp)) | `2026-10-30 06:19` |
| [`histogram_v2`](REPORT-histogram_v2.md) | **H100** | **#16** / 30 | **14.90 µs** | 16.87 µs | 703.7 GB/s | **59.7%** | [`crisp_histogram_lastman_u4_cs256.py`](04-histogram-v2/crisp_histogram_lastman_u4_cs256.py) ([`.crisp`](04-histogram-v2/histogram_lastman_u4_cs256.crisp)) | `2026-10-30 06:19` |
| [`histogram_v2`](REPORT-histogram_v2.md) | **A100** | **#19** / 27 | **23.55 µs** | 23.07 µs | 445.3 GB/s | **59.2%** | [`crisp_histogram_lastman_u4_direct64.py`](04-histogram-v2/crisp_histogram_lastman_u4_direct64.py) ([`.crisp`](04-histogram-v2/histogram_lastman_u4.crisp)) | `2026-10-30 06:19` |
| [`histogram_v2`](REPORT-histogram_v2.md) | **L4** | **#6** / 20 | **63.44 µs** | 64.12 µs | 165.3 GB/s | **96.8%** | [`crisp_histogram_lastman_u4_cs256.py`](04-histogram-v2/crisp_histogram_lastman_u4_cs256.py) ([`.crisp`](04-histogram-v2/histogram_lastman_u4_cs256.crisp)) | `2026-10-30 06:19` |
| [`matmul_v2`](REPORT-matmul_v2.md) | **H100** | **#29** / 43 | **229.79 µs** | 228.67 µs | 748 TFLOPS | **89.2%** | [`crisp_matmul_v5.py`](06-matmul-v2/crisp_matmul_v5.py) ([`.crisp`](06-matmul-v2/matmul_h100_2wg_tma.crisp)) | `2026-10-30 06:19` |
| [`matmul_v2`](REPORT-matmul_v2.md) | **A100** | **#54** / 55 | **4961.62 µs** | 4959.40 µs | 35 TFLOPS | **12.0%** | [`crisp_matmul_v3.py`](06-matmul-v2/crisp_matmul_v3.py) ([`.crisp`](06-matmul-v2/matmul_ampere_4w.crisp)) | `2026-10-30 06:19` |
| [`matmul_v2`](REPORT-matmul_v2.md) | **L4** | **#25** / 25 | **7116.96 µs** | 7134.11 µs | 24 TFLOPS | **28.0%** | [`crisp_matmul_v3.py`](06-matmul-v2/crisp_matmul_v3.py) ([`.crisp`](06-matmul-v2/matmul_ampere_4w.crisp)) | `2026-10-30 06:19` |
| [`prefixsum_v2`](REPORT-prefixsum_v2.md) | **B200** | **#15** / 34 | **461.29 µs** | 462.49 µs | 4.66 TB/s | **51.3%** | [`crisp_prefixsum_packed_rfl.py`](05-prefixsum-v2/crisp_prefixsum_packed_rfl.py) ([`.crisp`](05-prefixsum-v2/prefixsum_packed_rfl.crisp)) | `2026-10-30 06:19` |
| [`prefixsum_v2`](REPORT-prefixsum_v2.md) | **H100** | **#10** / 30 | **756.96 µs** | 753.57 µs | 2.84 TB/s | **92.8%** | [`crisp_prefixsum_packed_rfl.py`](05-prefixsum-v2/crisp_prefixsum_packed_rfl.py) ([`.crisp`](05-prefixsum-v2/prefixsum_packed_rfl.crisp)) | `2026-10-30 06:19` |
| [`prefixsum_v2`](REPORT-prefixsum_v2.md) | **A100** | **#21** / 30 | **1692.50 µs** | 1690.42 µs | 1.27 TB/s | **54.5%** | [`crisp_prefixsum_packed_rfl.py`](05-prefixsum-v2/crisp_prefixsum_packed_rfl.py) ([`.crisp`](05-prefixsum-v2/prefixsum_packed_rfl.crisp)) | `2026-10-30 06:19` |
| [`prefixsum_v2`](REPORT-prefixsum_v2.md) | **L4** | **#13** / 24 | **9147.39 µs** | 9161.28 µs | 234.8 GB/s | **70.6%** | [`crisp_prefixsum_packed_rfl.py`](05-prefixsum-v2/crisp_prefixsum_packed_rfl.py) ([`.crisp`](05-prefixsum-v2/prefixsum_packed_rfl.crisp)) | `2026-10-30 06:19` |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **B200** | **#20** / 67 | **233.48 µs** | 232.89 µs | 6.90 TB/s | **96.6%** | [`crisp_b200_inplace_2xhalf4.py`](01-vectoradd-v2/crisp_b200_inplace_2xhalf4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_b200_inplace_2xhalf4.crisp)) | `2026-10-30 06:19` |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **H100** | **#24** / 43 | **526.44 µs** | 526.12 µs | 3.06 TB/s | **97.4%** | [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp)) | `2026-10-30 06:19` |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **A100** | **#55** / 106 | **912.90 µs** | 914.09 µs | 1.76 TB/s | **95.1%** | [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp)) | `2026-10-30 06:19` |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **L4** | **#22** / 38 | **6891.89 µs** | 6916.10 µs | 233.7 GB/s | **88.9%** | [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp)) | `2026-10-30 06:19` |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | **B200** | **#37** / 82 | **49.69 µs** | — | 4.22 TB/s | **74.5%** | [`crisp_vectorsum_lastman_wg_occ1.py`](02-vectorsum-v2/crisp_vectorsum_lastman_wg_occ1.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg.crisp)) | `2026-10-30 06:19` |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | **H100** | **#33** / 69 | **82.81 µs** | 82.68 µs | 2.53 TB/s | **82.0%** | [`crisp_vectorsum_lastman_u8_cs256.py`](02-vectorsum-v2/crisp_vectorsum_lastman_u8_cs256.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg_u8.crisp)) | `2026-10-30 06:19` |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | **A100** | **#64** / 119 | **144.77 µs** | 146.15 µs | 1.45 TB/s | **69.9%** | [`crisp_vectorsum_lastman_u8_cs256.py`](02-vectorsum-v2/crisp_vectorsum_lastman_u8_cs256.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg_u8.crisp)) | `2026-10-30 06:19` |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | **L4** | **#12** / 45 | **866.51 µs** | 866.30 µs | 242.0 GB/s | **79.9%** | [`crisp_vectorsum_lastman_u8_cs256.py`](02-vectorsum-v2/crisp_vectorsum_lastman_u8_cs256.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg_u8.crisp)) | `2026-10-30 06:19` |

## ✨ Beauty Contestants — Idiomatic Crisp Showcase

For each contest, Crisp provides a **Beauty Contestant**: a clean, readable, high-level reference implementation relying strictly on Crisp's built-in abstractions (`loop-vector-stride`, typed views, monomorphic reductions) rather than aggressive hardware-specific micro-tuning or manual loop unrolling.

| Contest | Beauty Kernel (`.crisp`) | SLOC | Primary Abstractions | Best GPU | Beauty Score | % of #1 (`top1`) | % of Tuned Crisp |
|---|---|---:|---|---|---:|---:|---:|
| [`grayscale_v2`](REPORT-grayscale_v2.md) | [`grayscale_beauty.crisp`](03-grayscale-v2/grayscale_beauty.crisp) | 15 | def-function inline device helper, op-fma hardware fused multiply-add | **H100** | 1549.00 µs | **75.2%** | 89.0% |
| [`histogram_v2`](REPORT-histogram_v2.md) | [`histogram_beauty.crisp`](04-histogram-v2/histogram_beauty.crisp) | 18 | make-scratch-vector shared-memory privatization, loop-vector-stride grid-stride loop | **H100** | 22.50 µs | **39.5%** | 66.2% |
| [`matmul_v2`](REPORT-matmul_v2.md) | [`matmul_beauty.crisp`](06-matmul-v2/matmul_beauty.crisp) | 13 | matrix-multiply-tile-stride: output-tile walk + K walk + epilogue in one form, make-register-tile: an f32 accumulator that lives in registers | **H100** | 86000.00 µs | **0.2%** | 0.3% |
| [`prefixsum_v2`](REPORT-prefixsum_v2.md) | [`prefixsum_beauty.crisp`](05-prefixsum-v2/prefixsum_beauty.crisp) | 35 | shuffle-up Kogge-Stone intra-warp prefix scan, do-power-step+ compile-time power-of-two doubling | **L4** | 17969.41 µs | **35.9%** | 50.9% |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | [`vectoradd_beauty.crisp`](01-vectoradd-v2/vectoradd_beauty.crisp) | 18 | make-vector half4 view creation, loop-vector-stride collective streaming | **H100** | 556.50 µs | **92.1%** | 94.6% |
| [`vectorsum_v2`](REPORT-vectorsum_v2.md) | [`vectorsum_beauty.crisp`](02-vectorsum-v2/vectorsum_beauty.crisp) | 24 | make-vector float4 128-bit view, loop-vector-stride grid-stride loop | **H100** | 93.85 µs | **72.4%** | 88.2% |

## Regenerating & Refreshing Live Standings

```bash
# Regenerate REPORT.md and per-contest reports from saved JSON:
python contests/gpu-mode/report.py --all

# Refresh live rankings/entrant counts from gpumode.com API and regenerate:
python contests/gpu-mode/report.py --refresh --all
```
