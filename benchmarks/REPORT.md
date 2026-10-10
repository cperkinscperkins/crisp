# Crisp Benchmark Reports

> Generated from verified sweeps in `benchmarks/results/` by `python scripts/crisp_bench/report.py --all`.  The detail lives in one report per suite:

| suite | report | what it measures |
|---|---|---|
| matmul | [REPORT-matmul.md](REPORT-matmul.md) | MMA technique ladder, 16- and 64-bit ladders, Crisp vs SYCL/CUDA, SYCL-TLA/CUTLASS and oneMKL/cuBLAS; compile time |
| reduction | [REPORT-reduction.md](REPORT-reduction.md) | reduction ladder, Phase-2 strategy rollup, multi-variable workloads vs SYCL/oneDPL/oneMKL and CUB/Thrust/cuBLAS; % of MEASURED peak bandwidth; compile time |

## Devices

| device | data captured | Crisp commit | environment | hardware profile |
|---|---|---|---|---|
| Intel(R) Graphics [0xe20b] | 2026-10-08 | `4d2a91de` | docker | `bmg` |
| NVIDIA H100 80GB HBM3 | 2026-10-08 | `75d13e22` | runpod | `h100-sxm` |
| NVIDIA H200 | 2026-09-13 | `66a7911d` | runpod | `h200` |

## Matmul

Sections of [REPORT-matmul.md](REPORT-matmul.md): § 1 — MMA Techniques; § 1.5 — MMA Techniques (16-bit); § 1b — The Technique Ladder in 16-bit; § 1c — The Technique Ladder in 64-bit; § 2 — Top MMA Benchmarks; § 3 — Situational Techniques; § 4 — MMA + Activation; § 5 — Scaling Out.

## Reduction — headlines

Fp32, at the largest size measured on each device.  % = share of the device's MEASURED read peak.  Compile = source to device IR (`crisp-compile`; `icpx -fsycl-device-only` / `nvcc -ptx`).  Every number is verified twice (last timed launch, and a relaunch on different data).

### Intel(R) Graphics [0xe20b]

| workload | **Crisp** | best peer | top of line |
|---|---|---|---|
| argmax (3 GiB) | **99%** · 0.64 s | oneDPL 95% · 3.3 s | oneMKL 38% |
| sum (3 GiB) | **99%** · 0.62 s | oneDPL 96% · 2.9 s | oneMKL 94% |
| sum_sumsq (3 GiB) | **99%** · 0.64 s | oneDPL 95% · 3.0 s | oneMKL 48% |
| welford (3 GiB) | **99%** · 0.63 s | oneDPL 96% · 3.0 s | — |

Crisp compiles **3–5x faster** than the peer libraries here.

Ladder, sum at 3 GiB: hand-unrolled grid-stride (ladder 3b) 99%; `grid-reduce! :atomic` 99%; `reduce-vec` (default last-man) 99%.

### NVIDIA H100 80GB HBM3

| workload | **Crisp** | best peer | top of line |
|---|---|---|---|
| argmax (4 GiB) | **97%** · 0.14 s | CUB 98% · 2.0 s | cuBLAS 79% |
| sum (4 GiB) | **96%** · 0.13 s | CUB 100% · 1.9 s | cuBLAS 73% |
| sum_sumsq (4 GiB) | **96%** · 0.15 s | CUB 99% · 1.8 s | cuBLAS 41% |
| welford (4 GiB) | **96%** · 0.15 s | CUB 99% · 1.9 s | — |

Crisp compiles **12–19x faster** than the peer libraries here.

Ladder, sum at 4 GiB: hand-unrolled grid-stride (ladder 3b) 98%; `grid-reduce! :atomic` 97%; `reduce-vec` (default last-man) 96%.

**Closed:** [Endeavour 180 — loop unrolling](../tests/spec/180-loop-unroll/loop-unroll.md) (2026-10-07): `loop-vector-stride` now unrolls by default on SPIR-V (16 bytes in flight per thread), which took `reduce-vec` from 57% to 99% of peak on BMG.  NVIDIA gets no default: its backend already unrolls, and the H100 measured no hint as fastest.

**Known gap, recorded as an endeavour with measurements and a plan:**

- [Endeavour 181 — last-man sweep](../tests/spec/181-last-man-sweep/last-man-sweep.md): last-man (the default, and the only dependent strategy) is capped at groups <= local size, a quarter of an H100's resident groups; the same sum with `:atomic` reaches 91%.

## Regenerating

```
python scripts/crisp_bench/report.py --all      # REPORT.md + REPORT-matmul.md + REPORT-reduction.md
```
