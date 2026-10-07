# Crisp Benchmark Reports

> Generated from verified sweeps in `benchmarks/results/` by `python scripts/crisp_bench/report.py --all`.  The detail lives in one report per suite:

| suite | report | what it measures |
|---|---|---|
| matmul | [REPORT-matmul.md](REPORT-matmul.md) | MMA technique ladder, 16- and 64-bit ladders, Crisp vs SYCL/CUDA, SYCL-TLA/CUTLASS and oneMKL/cuBLAS; compile time |
| reduction | [REPORT-reduction.md](REPORT-reduction.md) | reduction ladder, Phase-2 strategy rollup, multi-variable workloads vs SYCL/oneDPL/oneMKL and CUB/Thrust/cuBLAS; % of MEASURED peak bandwidth; compile time |

## Devices

| device | data captured | Crisp commit | environment | hardware profile |
|---|---|---|---|---|
| Intel(R) Graphics [0xe20b] | 2026-10-06 | `56cb083b` | docker | `bmg` |
| NVIDIA H100 80GB HBM3 | 2026-09-13 | `cc116e8c` | runpod | `h100-80gb-hbm3` |
| NVIDIA H200 | 2026-09-13 | `66a7911d` | runpod | `h200` |
| NVIDIA H100 NVL | 2026-10-06 | `dd7edf5e` | runpod | `h100-nvl` |

## Matmul

Sections of [REPORT-matmul.md](REPORT-matmul.md): § 1 — MMA Techniques; § 1.5 — MMA Techniques (16-bit); § 1b — The Technique Ladder in 16-bit; § 1c — The Technique Ladder in 64-bit; § 2 — Top MMA Benchmarks; § 3 — Situational Techniques; § 4 — MMA + Activation; § 5 — Scaling Out.

## Reduction — headlines

Fp32, at the largest size measured on each device.  % = share of the device's MEASURED read peak.  Compile = source to device IR (`crisp-compile`; `icpx -fsycl-device-only` / `nvcc -ptx`).  Every number is verified twice (last timed launch, and a relaunch on different data).

### Intel(R) Graphics [0xe20b]

| workload | **Crisp** | best peer | top of line |
|---|---|---|---|
| argmax (3 GiB) | **57%** · 0.62 s | oneDPL 95% · 3.3 s | oneMKL 38% |
| sum (3 GiB) | **58%** · 0.57 s | oneDPL 96% · 2.9 s | oneMKL 94% |
| sum_sumsq (3 GiB) | **58%** · 0.58 s | oneDPL 95% · 3.0 s | oneMKL 48% |
| welford (3 GiB) | **56%** · 0.62 s | oneDPL 96% · 3.0 s | — |

Crisp compiles **3–5x faster** than the peer libraries here.

Ladder, sum at 3 GiB: hand-unrolled grid-stride (ladder 3b) 98%; `grid-reduce! :atomic` 58%; `reduce-vec` (default last-man) 58%.

### NVIDIA H100 NVL

| workload | **Crisp** | best peer | top of line |
|---|---|---|---|
| argmax (4 GiB) | **52%** · 0.24 s | CUB 98% · 3.7 s | cuBLAS 70% |
| sum (4 GiB) | **42%** · 0.19 s | CUB 101% · 2.6 s | cuBLAS 64% |
| sum_sumsq (4 GiB) | **33%** · 0.23 s | CUB 100% · 2.3 s | cuBLAS 35% |
| welford (4 GiB) | **40%** · 0.26 s | Thrust 70% · 2.8 s | — |

Crisp compiles **9–19x faster** than the peer libraries here.

Ladder, sum at 4 GiB: hand-unrolled grid-stride (ladder 3b) 96%; `grid-reduce! :atomic` 91%; `reduce-vec` (default last-man) 42%.

**Known gaps, both recorded as endeavours with measurements and a plan:**

- [Endeavour 180 — loop unrolling](../tests/spec/180-loop-unroll/loop-unroll.md): the SPIR-V stride loop issues one load per trip; an unroll hint takes `reduce-vec` from 57% to 98% on BMG (measured).  NVIDIA's backend already unrolls.
- [Endeavour 181 — last-man sweep](../tests/spec/181-last-man-sweep/last-man-sweep.md): last-man (the default, and the only dependent strategy) is capped at groups <= local size, a quarter of an H100's resident groups; the same sum with `:atomic` reaches 91%.

## Regenerating

```
python scripts/crisp_bench/report.py --all      # REPORT.md + REPORT-matmul.md + REPORT-reduction.md
```
