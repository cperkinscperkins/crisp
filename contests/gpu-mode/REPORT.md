# Crisp GPU MODE Contest Reports

> Generated from verified runs in `contests/gpu-mode/results/` by `python contests/gpu-mode/report.py --all`.

## Contests

| # | Contest | Detail Report | Leaderboard URL | Workload |
|---|---|---|---|---|
| 01 | **`vectoradd_v2`** | [REPORT-vectoradd_v2.md](REPORT-vectoradd_v2.md) | [Leaderboard #543](https://www.gpumode.com/leaderboard/543?tab=rankings) | C = A + B on two 16384x16384 float16 tensors (536.87 MB each; 1.6106 GB = 1.50 GiB total 2R+1W memory traffic) |

## Headline Standings Across Hardware

| Contest | GPU | Rank | Public Score | Secret Score | Achieved BW | % of #1 | Winning Crisp Kernel | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **B200** | **#20** / 66 | **233.48 µs** | 232.89 µs | 6.90 TB/s | **96.6%** | [`crisp_b200_inplace_2xhalf4.py`](01-vectoradd-v2/crisp_b200_inplace_2xhalf4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_b200_inplace_2xhalf4.crisp)) | `2026-10-19 04:59` |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **H100** | **#24** / 41 | **526.44 µs** | 526.12 µs | 3.06 TB/s | **97.4%** | [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp)) | `2026-10-19 04:59` |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **A100** | **#55** / 106 | **912.90 µs** | 914.09 µs | 1.76 TB/s | **96.1%** | [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp)) | `2026-10-19 04:59` |
| [`vectoradd_v2`](REPORT-vectoradd_v2.md) | **L4** | **#21** / 37 | **6891.89 µs** | 6916.10 µs | 233.7 GB/s | **88.9%** | [`crisp_f16_direct_half4.py`](01-vectoradd-v2/crisp_f16_direct_half4.py) ([`.crisp`](01-vectoradd-v2/vectoradd_direct_half4.crisp)) | `2026-10-19 04:59` |

## Regenerating & Refreshing Live Standings

```bash
# Regenerate REPORT.md and per-contest reports from saved JSON:
python contests/gpu-mode/report.py --all

# Refresh live rankings/entrant counts from gpumode.com API and regenerate:
python contests/gpu-mode/report.py --refresh --all
```
