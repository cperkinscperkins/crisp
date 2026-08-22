# Crisp Benchmark Report

> Generated from verified test sweeps in `benchmarks/results/`.

| device | data captured | source |
|---|---|---|
| Intel BMG | 2026-08-22 | Crisp `f1d4d77` (docker) |
| NVIDIA H100 NVL | 2026-08-19 | Crisp `unknown` (runpod) |

---

# Suite: matmul

Row variable: **N**, the square matrix dimension. Matmul cost grows as N³ while memory grows as N².

| bucket | N | what it exercises |
|---|---|---|
| small | 512, 1024 | launch overhead and occupancy dominate |
| medium | 2048, 4096 | the machine saturates (~0.97 residency waves) |
| large | 8192, 16384 | steady state |
| xl | 32768, 65536 | device permitting |

## § 1 — MMA Techniques

*How do you make a matmul fast, one step at a time?*

**Contenders: Control only.** The column carrying the story is **vs previous chapter**.

### Intel BMG · tf32 · `fast`

**Rollup — Crisp TFLOPS, every chapter × every N.**

| # | technique | **N=256** | **N=512** | **N=1024** | **N=2048** | **N=4096** | **N=8192** | **N=16384** |
|---|---|---|---|---|---|---|---|---|
| 0 | naive loops, no XMX | 0.1 | 0.4 | 1.4 | 1.4 | 1.5 | 1.3 | — |
| 1 | hand-rolled XMX coop-matrix | 0.1 | 0.4 | 1.4 | 1.4 | 1.4 | 0.7 | — |
| 2 | matrix-multiply-tile-stride | 0.1 | 0.4 | 1.4 | 1.4 | 1.5 | 1.3 | — |
| 3 | OpGroupAsyncCopy | 0.1 | 0.2 | 0.8 | 0.8 | 0.7 | 0.7 | — |
| 4 | register-resident load (global→GRF) | 2.9 | 12.0 | 23.1 | 16.2 | 13.0 | — | — |
| 5 | register ring + prefetch | 3.0 | 9.6 | 21.5 | 23.9 | 16.0 | 11.7 | — |
| 6 | blocked — 3 known reasons | — | — | — | — | — | — | — |
| 7 | GRF-bounded tile sweep | 3.0 | 9.6 | 21.8 | 24.7 | 15.8 | 11.7 | — |

<details><summary><b>Per-chapter detail</b></summary>

#### Ch 0 — Does it run at all?
naive loops, no XMX

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control |
|---:|---:|---:|---:|
| 256 | 0.1 (0.308) | 0.5 (0.074) | 0.24× |
| 512 | 0.4 (0.692) | 0.6 (0.451) | 0.65× |
| 1024 | 1.4 (1.587) | 0.7 (3.183) | **2.01×** |
| 2048 | 1.4 (12.059) | 0.5 (31.745) | **2.63×** |
| 4096 | 1.5 (92.395) | 0.3 (524.116) | **5.67×** |
| 8192 | 1.3 (821.016) | 1.3 (841.229) | 1.02× |
| 16384 | — | — | — |

#### Ch 1 — Can we reach the tensor cores?
hand-rolled XMX coop-matrix

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 0 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.308) | 0.2 (0.209) | 0.68× | 1.00× |
| 512 | 0.4 (0.693) | 0.5 (0.512) | 0.74× | 1.00× |
| 1024 | 1.4 (1.578) | 1.8 (1.174) | 0.74× | 1.01× |
| 2048 | 1.4 (12.505) | 1.6 (10.885) | 0.87× | 0.96× |
| 4096 | 1.4 (97.330) | 1.7 (79.421) | 0.82× | 0.95× |
| 8192 | 0.7 (1475.660) | 1.3 (845.016) | 0.57× | 0.56× |
| 16384 | — | — | — | — |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 1 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.308) | 1.3 (0.025) | 0.08× | 1.00× |
| 512 | 0.4 (0.692) | 1.5 (0.183) | 0.26× | 1.00× |
| 1024 | 1.4 (1.587) | 1.5 (1.399) | 0.88× | 0.99× |
| 2048 | 1.4 (12.059) | 1.5 (11.832) | 0.98× | 1.04× |
| 4096 | 1.5 (92.395) | 1.3 (104.036) | 1.13× | 1.05× |
| 8192 | 1.3 (821.016) | 1.3 (841.229) | 1.02× | **1.80×** |
| 16384 | — | — | — | — |

#### Ch 3 — Can the fetch overlap the math?
OpGroupAsyncCopy

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 2 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.413) | 1.3 (0.025) | 0.06× | 0.75× |
| 512 | 0.2 (1.090) | 1.5 (0.183) | 0.17× | 0.64× |
| 1024 | 0.8 (2.776) | 1.5 (1.403) | 0.51× | 0.57× |
| 2048 | 0.8 (21.353) | 1.5 (11.844) | 0.55× | 0.56× |
| 4096 | 0.7 (186.632) | 1.3 (105.607) | 0.57× | 0.50× |
| 8192 | 0.7 (1475.660) | 1.3 (845.016) | 0.57× | 0.56× |
| 16384 | — | — | — | — |

#### Ch 4 — Can the fetch itself be cheap?
register-resident load (global→GRF)

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 3 |
|---:|---:|---:|---:|---:|
| 256 | 2.9 (0.012) | 3.2 (0.011) | 0.90× | **35.50×** |
| 512 | 12.0 (0.022) | 13.3 (0.020) | 0.90× | **48.75×** |
| 1024 | 23.1 (0.093) | 27.7 (0.078) | 0.83× | **29.83×** |
| 2048 | 16.2 (1.058) | 20.1 (0.856) | 0.81× | **20.18×** |
| 4096 | 13.0 (10.544) | 20.3 (6.770) | 0.64× | **17.70×** |
| 8192 | — | — | — | — |
| 16384 | — | — | — | — |

#### Ch 5 — Can several fetches be in flight?
register ring + prefetch

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 4 |
|---:|---:|---:|---:|---:|
| 256 | 3.0 (0.011) | 1.5 (0.022) | **1.99×** | 1.06× |
| 512 | 9.6 (0.028) | 5.1 (0.052) | **1.86×** | 0.80× |
| 1024 | 21.5 (0.100) | 10.2 (0.211) | **2.12×** | 0.93× |
| 2048 | 23.9 (0.720) | 11.1 (1.543) | **2.14×** | 1.47× |
| 4096 | 16.0 (8.599) | 9.5 (14.479) | **1.68×** | 1.23× |
| 8192 | 11.7 (93.626) | 7.6 (144.065) | **1.54×** | **15.76×** |
| 16384 | — | — | — | — |

#### Ch 6 — Can the math stop waiting on bookkeeping?
blocked — 3 known reasons

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 5 |
|---:|---:|---:|---:|---:|
| 256 | — | — | — | — |
| 512 | — | — | — | — |
| 1024 | — | — | — | — |
| 2048 | — | — | — | — |
| 4096 | — | — | — | — |
| 8192 | — | — | — | — |
| 16384 | — | — | — | — |

#### Ch 7 — Can one instruction do more math?
GRF-bounded tile sweep

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 6 |
|---:|---:|---:|---:|---:|
| 256 | 3.0 (0.011) | 1.5 (0.022) | **2.00×** | 1.00× |
| 512 | 9.6 (0.028) | 5.1 (0.052) | **1.86×** | 1.00× |
| 1024 | 21.8 (0.099) | 10.1 (0.212) | **2.15×** | 1.01× |
| 2048 | 24.7 (0.696) | 11.3 (1.527) | **2.19×** | 1.03× |
| 4096 | 15.8 (8.719) | 9.6 (14.386) | **1.65×** | 0.99× |
| 8192 | 11.7 (93.626) | 7.6 (144.065) | **1.54×** | 1.00× |
| 16384 | — | — | — | — |

</details>

### NVIDIA H100 NVL · tf32 · `fast`

**Rollup — Crisp TFLOPS, every chapter × every N.**

| # | technique | **N=256** | **N=512** | **N=1024** | **N=2048** | **N=4096** |
|---|---|---|---|---|---|---|
| 0 | naive loops, no tensor cores | 0.1 | 0.3 | 1.3 | 4.8 | 4.8 |
| 1 | hand-rolled mma-accumulate-via-tile | 0.1 | 0.6 | 2.2 | 7.8 | 7.9 |
| 2 | matrix-multiply-tile-stride | 0.1 | 0.3 | 1.3 | 4.8 | 4.8 |
| 3 | cp.async | 0.1 | 0.6 | 2.2 | 7.8 | 7.9 |
| 4 | TMA descriptor (CUtensorMap) | 1.4 | 6.3 | 25.3 | 68.3 | 71.5 |
| 5 | SMEM ring | 1.6 | 7.0 | 27.3 | 63.7 | 67.9 |
| 6 | warp specialization | 2.5 | 15.0 | 79.7 | 238.2 | 257.1 |
| 7 | wgmma | 2.5 | 15.0 | 79.7 | 238.2 | 257.1 |

<details><summary><b>Per-chapter detail</b></summary>

#### Ch 0 — Does it run at all?
naive loops, no tensor cores

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control |
|---:|---:|---:|---:|
| 256 | 0.1 (0.377) | 2.5 (0.013) | 0.04× |
| 512 | 0.3 (0.777) | 4.3 (0.062) | 0.08× |
| 1024 | 1.3 (1.622) | 4.9 (0.436) | 0.27× |
| 2048 | 4.8 (3.562) | 5.2 (3.334) | 0.94× |
| 4096 | 4.8 (28.447) | 5.2 (26.535) | 0.93× |

#### Ch 1 — Can we reach the tensor cores?
hand-rolled mma-accumulate-via-tile

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 0 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.247) | 2.3 (0.014) | 0.06× | **1.53×** |
| 512 | 0.6 (0.486) | 3.7 (0.073) | 0.15× | **1.60×** |
| 1024 | 2.2 (0.965) | 4.1 (0.524) | 0.54× | **1.68×** |
| 2048 | 7.8 (2.200) | 4.3 (4.016) | **1.83×** | **1.62×** |
| 4096 | 7.9 (17.416) | 4.3 (31.916) | **1.83×** | **1.63×** |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 1 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.377) | 2.5 (0.013) | 0.04× | 0.65× |
| 512 | 0.3 (0.777) | 4.3 (0.062) | 0.08× | 0.63× |
| 1024 | 1.3 (1.622) | 4.9 (0.436) | 0.27× | 0.59× |
| 2048 | 4.8 (3.562) | 5.2 (3.334) | 0.94× | 0.62× |
| 4096 | 4.8 (28.447) | 5.2 (26.535) | 0.93× | 0.61× |

#### Ch 3 — Can the fetch overlap the math?
cp.async

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 2 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.247) | 2.3 (0.014) | 0.06× | **1.53×** |
| 512 | 0.6 (0.486) | 3.7 (0.073) | 0.15× | **1.60×** |
| 1024 | 2.2 (0.965) | 4.1 (0.524) | 0.54× | **1.68×** |
| 2048 | 7.8 (2.200) | 4.3 (4.016) | **1.83×** | **1.62×** |
| 4096 | 7.9 (17.416) | 4.3 (31.916) | **1.83×** | **1.63×** |

#### Ch 4 — Can the fetch itself be cheap?
TMA descriptor (CUtensorMap)

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 3 |
|---:|---:|---:|---:|---:|
| 256 | 1.4 (0.023) | 2.3 (0.014) | 0.61× | **10.49×** |
| 512 | 6.3 (0.043) | 3.7 (0.073) | **1.71×** | **11.42×** |
| 1024 | 25.3 (0.085) | 4.1 (0.523) | **6.15×** | **11.34×** |
| 2048 | 68.3 (0.252) | 4.3 (4.016) | **15.96×** | **8.74×** |
| 4096 | 71.5 (1.921) | 4.3 (31.978) | **16.65×** | **9.07×** |

#### Ch 5 — Can several fetches be in flight?
SMEM ring

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 4 |
|---:|---:|---:|---:|---:|
| 256 | 1.6 (0.021) | 2.0 (0.016) | 0.77× | 1.11× |
| 512 | 7.0 (0.038) | 3.2 (0.083) | **2.18×** | 1.12× |
| 1024 | 27.3 (0.079) | 3.6 (0.603) | **7.68×** | 1.08× |
| 2048 | 63.7 (0.270) | 3.7 (4.629) | **17.18×** | 0.93× |
| 4096 | 67.9 (2.023) | 3.8 (36.438) | **18.01×** | 0.95× |

#### Ch 6 — Can the math stop waiting on bookkeeping?
warp specialization

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 5 |
|---:|---:|---:|---:|---:|
| 256 | 2.5 (0.013) | — | — | **1.58×** |
| 512 | 15.0 (0.018) | — | — | **2.13×** |
| 1024 | 79.7 (0.027) | — | — | **2.92×** |
| 2048 | 238.2 (0.072) | — | — | **3.74×** |
| 4096 | 257.1 (0.535) | — | — | **3.78×** |

#### Ch 7 — Can one instruction do more math?
wgmma

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 6 |
|---:|---:|---:|---:|---:|
| 256 | 2.5 (0.013) | — | — | 1.00× |
| 512 | 15.0 (0.018) | — | — | 1.00× |
| 1024 | 79.7 (0.027) | — | — | 1.00× |
| 2048 | 238.2 (0.072) | — | — | 1.00× |
| 4096 | 257.1 (0.535) | — | — | 1.00× |

</details>

## § 2 — Top MMA Benchmarks

*How does Crisp actually stand?* Best mainloop against **all three contender classes**.

### Intel BMG · tf32 · `fast`

| N | Crisp | Control<br>SYCL_Apples | **Peer**<br>SYCL-TLA | Ceiling<br>oneMKL | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.0 (0.011) | 1.5 (0.022) | 1.5 (0.022) | 5.2 (0.006) | **1.99×** | 58% |
| 512 | 9.6 (0.028) | 5.1 (0.052) | 5.2 (0.052) | 9.8 (0.027) | **1.86×** | 98% |
| 1024 | 21.8 (0.099) | 10.2 (0.211) | 10.1 (0.212) | 12.0 (0.180) | **2.15×** | **182%** |
| 2048 | 24.9 (0.689) | 11.3 (1.527) | 11.2 (1.535) | 13.8 (1.242) | **2.23×** | **180%** |
| 4096 | 16.2 (8.479) | 9.6 (14.275) | 9.5 (14.449) | 14.3 (9.602) | **1.70×** | 113% |
| 8192 | 13.7 (80.362) | 7.6 (144.065) | 7.5 (147.327) | 14.2 (77.562) | **1.83×** | 97% |
| 16384 | 10.4 (845.229) | 4.9 (1810.277) | 4.8 (1826.209) | 14.4 (611.614) | **2.16×** | 72% |

### NVIDIA H100 NVL · tf32 · `fast`

| N | Crisp | Control<br>CUDA_Apples | **Peer**<br>CUTLASS | Ceiling<br>cuBLAS | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 2.5 (0.013) | — | 4.9 (0.007) | 4.9 (0.007) | 0.51× | 51% |
| 512 | 15.0 (0.018) | — | 30.0 (0.009) | 30.0 (0.009) | 0.50× | 50% |
| 1024 | 79.7 (0.027) | — | 141.3 (0.015) | 141.3 (0.015) | 0.56× | 56% |
| 2048 | 238.2 (0.072) | — | 322.7 (0.053) | 322.7 (0.053) | 0.74× | 74% |
| 4096 | 257.1 (0.535) | — | 381.6 (0.360) | 381.6 (0.360) | 0.67× | 67% |

## § 3 — Situational Techniques

*Techniques whose honest answer is "it depends."* Controlled pairs:

### TMA Multicast (NVIDIA only) · H100 NVL
| tile | AI | N=1024 | N=2048 | N=4096 |
|---|---:|---:|---:|---:|
| 64×256 | 25.6 | −6.1% | **−7.0%** | −9.7% |
| **64×128** | 21.3 | −6.1% | **+15.5%** | **+10.7%** |
| 64×64 | 16.0 | +0.4% | +1.1% | +4.4% |

## § 4 — MMA + Activation

*What does fusing an arbitrary activation buy?*

| contender | arbitrary activation? | what Crisp claims |
|---|---|---|
| cuBLASLt, oneDNN (**Ceiling**) | **No** — fixed enum / post-op set | **capability** — off-menu costs 2nd kernel + HBM round trip |
| CUTLASS, SYCL-TLA (**Peer**) | **Yes** — monomorphised functor | **expressiveness & compile time** (~165× faster build) |

## § 5 — Scaling Out

| topic | status |
|---|---|
| Out of core (stream from host) | candidate for 1.0 |
| Hardware multi-tile (PVC 2T/4T) | deferred — needs `def-topology` |
| Multi-GPU | deferred — needs `def-topology` + `def-orchestration` |


# Appendix — runs excluded from canonical tables

Debug and exploratory runs are written to `benchmarks/results/scratch/`, which the report never reads into canonical tables.

| timestamp | suite | chapter | competitor | sizes |
|---|---|---|---|---|
| 2026-08-21 22:14 | matmul | chap0_naive | Crisp | `` |
| 2026-08-21 22:14 | matmul | chap0_naive | SYCL_Apples | `256,512` |
| 2026-08-21 22:14 | matmul | chap1_handrolled_mma | Crisp | `` |
| 2026-08-21 22:14 | matmul | chap1_handrolled_mma | SYCL_Apples | `256,512` |
| 2026-08-21 22:15 | matmul | chap0_naive | Crisp | `256,512` |
| 2026-08-21 22:50 | matmul | chap0_naive | SYCL_Apples | `256,512` |
| 2026-08-21 22:50 | matmul | chap1_handrolled_mma | Crisp | `` |
| 2026-08-21 22:51 | matmul | chap1_handrolled_mma | SYCL_Apples | `256,512` |
| 2026-08-21 22:53 | matmul | chap0_naive | Crisp | `256,512` |
| 2026-08-21 23:28 | matmul | chap0_naive | SYCL_Apples | `256,512` |
| 2026-08-21 23:28 | matmul | chap1_handrolled_mma | Crisp | `` |
| 2026-08-21 23:28 | matmul | chap1_handrolled_mma | SYCL_Apples | `256,512` |
| 2026-08-21 23:29 | matmul | chap1_handrolled_mma | Crisp | `` |
| 2026-08-21 23:29 | matmul | chap1_handrolled_mma | SYCL_Apples | `256,512` |
| 2026-08-21 23:30 | matmul | chap1_handrolled_mma | Crisp | `256,512` |
| 2026-08-21 23:30 | matmul | chap1_handrolled_mma | SYCL_Apples | `256,512` |
| 2026-08-22 00:46 | matmul | chap0_naive | Crisp | `` |
| 2026-08-22 00:50 | matmul | chap0_naive | SYCL_Apples | `256,512` |
| 2026-08-22 00:50 | matmul | chap1_handrolled_mma | Crisp | `256,512` |
| 2026-08-22 00:50 | matmul | chap1_handrolled_mma | SYCL_Apples | `256,512` |
| 2026-08-22 01:32 | matmul | chap1_handrolled_mma | Crisp | `256,512` |
| 2026-08-22 01:32 | matmul | chap1_handrolled_mma | SYCL_Apples | `256,512` |
| 2026-08-22 02:43 | matmul | chap0_naive | Crisp | `` |
| 2026-08-22 02:47 | matmul | chap0_naive | SYCL_Apples | `256,512` |
| 2026-08-22 02:47 | matmul | chap1_handrolled_mma | Crisp | `256,512` |
| 2026-08-22 02:47 | matmul | chap1_handrolled_mma | SYCL_Apples | `256,512` |
| 2026-08-22 02:47 | matmul | chap2_tiling | Crisp | `` |
| 2026-08-22 02:47 | matmul | chap2_tiling | SYCL_Apples | `256,512` |
| 2026-08-22 02:48 | matmul | chap2_tiling | OneMKL_Optimal | `256,512` |
| 2026-08-22 02:48 | matmul | chap3_async | Crisp | `256,512` |
| 2026-08-22 02:48 | matmul | chap3_async | SYCL_Apples | `256,512` |
| 2026-08-22 02:48 | matmul | chap4_cheap_fetch | Crisp | `256,512` |
| 2026-08-22 02:48 | matmul | chap4_cheap_fetch | SYCL_Apples | `256,512` |
| 2026-08-22 02:48 | matmul | chap5_multistage_ring | Crisp | `256,512` |
| 2026-08-22 02:48 | matmul | chap5_multistage_ring | SYCL_Apples | `256,512` |