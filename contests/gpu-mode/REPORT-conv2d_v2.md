# GPU MODE Contest Report: `conv2d_v2`

> Generated from [`results/conv2d_v2.json`](results/conv2d_v2.json) by `python contests/gpu-mode/report.py --all`. Live leaderboard: [https://www.gpumode.com/leaderboard/537?tab=rankings](https://www.gpumode.com/leaderboard/537?tab=rankings) (Crisp commit `b0fe7502`).

**Workload:** Y = conv2d(X, W), no padding, stride 1, fp32, checked at rtol = atol = 1e-3 against cuDNN with TF32 disabled.  task.yml lists 5 benchmarks; kernelbot ranks by RankCriterion.LAST, so the score is the LAST case only: size 256, kernelsize 32, channels 128, batch 1 (seed 6252) -- 225x225x128 outputs, each a 131,072-term dot product: 1.699 TFLOP as a direct convolution..

## § 1 — Official Leaderboard Standings

| GPU | Architecture | Rank | Public Score | Secret Score | Achieved BW / TFLOPS | % of #1 (`top1`) | Winning Crisp Kernel | Hardware Profile | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|---|
| **B200** | — | **#20** / 25 | **53575.02 µs** | 53580.96 µs | 32 TFLOPS | 0.9% (`478.53 µs`) | `crisp_conv2d_tiled_p.py` | — | `2026-11-12 03:48` |
| **H100** | — | **#25** / 34 | **66417.54 µs** | 66433.44 µs | 26 TFLOPS | 0.9% (`594.89 µs`) | `crisp_conv2d_tiled_p.py` | — | `2026-11-12 03:48` |
| **A100** | — | **#6** / 23 | **2195.16 µs** | 2188.45 µs | 774 TFLOPS | 39.0% (`855.04 µs`) | `crisp_conv2d_perf.py` | — | `2026-11-12 03:48` |
| **L4** | — | **#10** / 15 | **189378.56 µs** | 187812.56 µs | 9 TFLOPS | 2.5% (`4698.29 µs`) | `crisp_conv2d_tiled_p.py` | — | `2026-11-12 03:48` |

## § 2 — Technique Ladder & Cross-GPU Ablation (`size = 16384`)

Cells show **`benchmark` mean µs** (and **`[LB: public µs]`** when submitted to the official leaderboard). The fastest kernel on each GPU is **bold**.

| Step | Kernel (`.crisp` / `.py`) | Strategy | Regs | Profile | **B200** | **H100** | **A100** | **L4** |
|---|---|---|---:|---|---:|---:|---:|---:|

## § 3 — Key Architectural Takeaways

1. **Performance Tuning:** Performance results recorded and verified on official leaderboard.

## § 4 — Verified Submission & Benchmark Log

| Timestamp (UTC) | Submission ID | GPU | Mode | File | Benchmark (µs) | Public LB (µs) | Secret LB (µs) |
|---|---:|---|---|---|---:|---:|---:|
| `2026-11-11 16:47:07` | `970628` | **H100** | `test` | `crisp_conv2d_beauty.py` | — | — | — |
| `2026-11-11 17:53:05` | `970638` | **H100** | `benchmark` | `crisp_conv2d_tiled.py` | 82800.0 | — | — |
| `2026-11-11 17:53:20` | `970639` | **H100** | `benchmark` | `crisp_conv2d_beauty.py` | 436000.0 | — | — |
| `2026-11-11 18:55:38` | `970658` | **H100** | `leaderboard` | `crisp_conv2d_beauty.py` | — | **432973.69** | 432969.17 |
| `2026-11-11 18:56:25` | `970660` | **H100** | `leaderboard` | `crisp_conv2d_tiled_p.py` | — | **66417.54** | 66433.44 |
| `2026-11-11 18:58:36` | `970661` | **L4** | `leaderboard` | `crisp_conv2d_beauty.py` | — | **1450618.90** | 1466674.47 |
| `2026-11-11 19:01:24` | `970657` | **B200** | `leaderboard` | `crisp_conv2d_beauty.py` | — | **385215.63** | 385013.70 |
| `2026-11-11 19:01:30` | `970659` | **B200** | `leaderboard` | `crisp_conv2d_tiled_p.py` | — | **53575.02** | 53580.96 |
| `2026-11-11 19:21:42` | `970656` | **A100** | `leaderboard` | `crisp_conv2d_beauty.py` | — | **742584.18** | 745629.37 |
| `2026-11-11 20:23:46` | `970671` | **L4** | `leaderboard` | `crisp_conv2d_tiled_p.py` | — | **189378.56** | 187812.56 |
| `2026-11-11 20:42:16` | `970676` | **A100** | `leaderboard` | `crisp_conv2d_perf.py` | — | **3200.07** | 3202.08 |
| `2026-11-11 21:12:22` | `970681` | **A100** | `leaderboard` | `crisp_conv2d_perf.py` | — | **2292.73** | 2291.57 |
| `2026-11-11 22:25:26` | `970698` | **A100** | `leaderboard` | `crisp_conv2d_perf.py` | — | **2195.16** | 2188.45 |
