# Crisp Benchmark Report

> Generated from verified test sweeps in `benchmarks/results/`.

| device | data captured | source |
|---|---|---|
| Intel BMG | 2026-08-27 | Crisp `3e8ab19` (docker) |
| NVIDIA H100 NVL | 2026-08-22 | Crisp `209687fd` (runpod) |

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
| 0 | naive loops, no XMX | 0.1 | 0.2 | 0.1 | 0.1 | 0.1 | 0.1 | — |
| 1 | hand-rolled XMX coop-matrix | 0.1 | 0.4 | 1.4 | 1.4 | 1.4 | 1.3 | — |
| 2 | matrix-multiply-tile-stride | 0.1 | 0.4 | 1.4 | 1.4 | 1.5 | 1.3 | — |
| 3 | OpGroupAsyncCopy | 0.1 | 0.2 | 0.8 | 0.8 | 0.7 | 0.7 | — |
| 4 | register-resident load (global→GRF) | 2.9 | 11.9 | 26.0 | 16.4 | 12.5 | 9.2 | — |
| 5 | register ring + prefetch | 3.0 | 9.5 | 21.5 | 23.9 | 16.0 | 13.0 | — |
| 6 | blocked — 3 known reasons | — | — | — | — | — | — | — |
| 7 | GRF-bounded tile sweep | 3.0 | 9.6 | 21.8 | 24.7 | 15.8 | 11.7 | — |

<details><summary><b>Per-chapter detail</b></summary>

#### Ch 0 — Does it run at all?
naive loops, no XMX

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control |
|---:|---:|---:|---:|
| 256 | 0.1 (0.237) | 0.5 (0.074) | 0.31× |
| 512 | 0.2 (1.754) | 0.6 (0.450) | 0.26× |
| 1024 | 0.1 (16.168) | 0.7 (3.177) | 0.20× |
| 2048 | 0.1 (128.418) | 0.5 (31.491) | 0.25× |
| 4096 | 0.1 (1225.500) | 0.3 (524.917) | 0.43× |
| 8192 | 0.1 (17888.200) | 0.3 (4054.830) | 0.23× |
| 16384 | — | — | — |

#### Ch 1 — Can we reach the tensor cores?
hand-rolled XMX coop-matrix

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 0 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.308) | 0.2 (0.209) | 0.68× | 0.77× |
| 512 | 0.4 (0.693) | 0.5 (0.511) | 0.74× | **2.53×** |
| 1024 | 1.4 (1.572) | 1.9 (1.146) | 0.73× | **10.29×** |
| 2048 | 1.4 (12.557) | 1.6 (11.003) | 0.88× | **10.23×** |
| 4096 | 1.4 (98.401) | 1.7 (79.138) | 0.80× | **12.45×** |
| 8192 | 1.3 (850.870) | 1.7 (639.945) | 0.75× | **21.02×** |
| 16384 | — | — | — | — |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 1 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.308) | 1.3 (0.026) | 0.08× | 1.00× |
| 512 | 0.4 (0.692) | 1.5 (0.183) | 0.26× | 1.00× |
| 1024 | 1.4 (1.587) | 1.5 (1.402) | 0.88× | 0.99× |
| 2048 | 1.4 (12.059) | 1.5 (11.636) | 0.96× | 1.04× |
| 4096 | 1.5 (92.395) | 1.3 (104.945) | 1.14× | 1.07× |
| 8192 | 1.3 (821.016) | 1.3 (849.943) | 1.04× | 1.04× |
| 16384 | — | — | — | — |

#### Ch 3 — Can the fetch overlap the math?
OpGroupAsyncCopy

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 2 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.413) | 1.3 (0.025) | 0.06× | 0.75× |
| 512 | 0.2 (1.090) | 1.5 (0.183) | 0.17× | 0.64× |
| 1024 | 0.8 (2.776) | 1.5 (1.403) | 0.51× | 0.57× |
| 2048 | 0.8 (21.353) | 1.5 (11.593) | 0.54× | 0.56× |
| 4096 | 0.7 (186.632) | 1.3 (104.125) | 0.56× | 0.50× |
| 8192 | 0.7 (1475.660) | 1.3 (843.605) | 0.57× | 0.56× |
| 16384 | — | — | — | — |

#### Ch 4 — Can the fetch itself be cheap?
register-resident load (global→GRF)

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 3 |
|---:|---:|---:|---:|---:|
| 256 | 2.9 (0.012) | 3.2 (0.011) | 0.92× | **35.82×** |
| 512 | 11.9 (0.022) | 13.2 (0.020) | 0.90× | **48.53×** |
| 1024 | 26.0 (0.083) | 27.5 (0.078) | 0.95× | **33.62×** |
| 2048 | 16.4 (1.050) | 20.4 (0.842) | 0.80× | **20.34×** |
| 4096 | 12.5 (10.984) | 20.3 (6.784) | 0.62× | **16.99×** |
| 8192 | 9.2 (119.586) | 6.6 (166.309) | 1.39× | **12.34×** |
| 16384 | — | — | — | — |

#### Ch 5 — Can several fetches be in flight?
register ring + prefetch

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 4 |
|---:|---:|---:|---:|---:|
| 256 | 3.0 (0.011) | 1.5 (0.022) | **1.99×** | 1.05× |
| 512 | 9.5 (0.028) | 5.1 (0.052) | **1.85×** | 0.79× |
| 1024 | 21.5 (0.100) | 10.2 (0.211) | **2.12×** | 0.83× |
| 2048 | 23.9 (0.718) | 11.1 (1.543) | **2.15×** | 1.46× |
| 4096 | 16.0 (8.587) | 9.5 (14.479) | **1.69×** | 1.28× |
| 8192 | 13.0 (84.664) | 7.6 (144.065) | **1.70×** | 1.41× |
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
| 512 | 9.6 (0.028) | 5.1 (0.052) | **1.86×** | 1.01× |
| 1024 | 21.8 (0.099) | 10.1 (0.212) | **2.15×** | 1.01× |
| 2048 | 24.7 (0.696) | 11.3 (1.527) | **2.19×** | 1.03× |
| 4096 | 15.8 (8.719) | 9.6 (14.386) | **1.65×** | 0.98× |
| 8192 | 11.7 (93.626) | 7.6 (144.065) | **1.54×** | 0.90× |
| 16384 | — | — | — | — |

</details>

### NVIDIA H100 NVL · tf32 · `fast`

**Rollup — Crisp TFLOPS, every chapter × every N.**

| # | technique | **N=256** | **N=512** | **N=1024** | **N=2048** | **N=4096** | **N=8192** | **N=16384** | **N=32768** |
|---|---|---|---|---|---|---|---|---|---|
| 0 | naive loops, no tensor cores | 0.8 | 0.8 | 0.9 | 0.9 | 0.9 | 0.9 | 0.9 | — |
| 1 | hand-rolled mma-accumulate-via-tile | 0.1 | 0.3 | 1.3 | 3.7 | 3.0 | 3.6 | 3.7 | — |
| 2 | matrix-multiply-tile-stride | 0.1 | 0.3 | 1.3 | 4.8 | 8.8 | 8.9 | 9.0 | 9.1 |
| 3 | cp.async | 0.1 | 0.6 | 2.2 | 7.9 | 7.9 | 8.0 | 8.1 | 8.2 |
| 4 | TMA descriptor (CUtensorMap) | 1.4 | 6.4 | 25.4 | 68.7 | 71.9 | 72.3 | 59.5 | 51.8 |
| 5 | SMEM ring | 1.6 | 7.1 | 27.7 | 64.3 | 68.5 | 66.6 | 52.2 | 48.3 |
| 6 | warp specialization | 3.2 | 15.8 | 55.4 | 71.4 | 75.1 | 60.6 | 47.3 | 46.6 |
| 7 | wgmma | 2.8 | 17.4 | 92.4 | 253.1 | 293.0 | 295.3 | 184.0 | 145.7 |

<details><summary><b>Per-chapter detail</b></summary>

#### Ch 0 — Does it run at all?
naive loops, no tensor cores

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control |
|---:|---:|---:|---:|
| 256 | 0.8 (0.043) | 0.7 (0.047) | 1.11× |
| 512 | 0.8 (0.319) | 0.8 (0.339) | 1.06× |
| 1024 | 0.9 (2.520) | 0.8 (2.667) | 1.06× |
| 2048 | 0.9 (19.600) | 0.8 (20.801) | 1.06× |
| 4096 | 0.9 (156.851) | 0.8 (165.800) | 1.06× |
| 8192 | 0.9 (1248.030) | 0.8 (1324.871) | 1.06× |
| 16384 | 0.9 (9947.690) | 0.8 (10586.247) | 1.06× |
| 32768 | — | — | — |

#### Ch 1 — Can we reach the tensor cores?
hand-rolled mma-accumulate-via-tile

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 0 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.379) | 2.3 (0.014) | 0.04× | 0.11× |
| 512 | 0.3 (0.789) | 3.7 (0.073) | 0.09× | 0.40× |
| 1024 | 1.3 (1.622) | 4.1 (0.524) | 0.32× | **1.55×** |
| 2048 | 3.7 (4.632) | 4.3 (4.016) | 0.87× | **4.23×** |
| 4096 | 3.0 (46.093) | 4.3 (31.916) | 0.69× | **3.40×** |
| 8192 | 3.6 (306.077) | — | — | **4.08×** |
| 16384 | 3.7 (2355.760) | — | — | **4.22×** |
| 32768 | — | — | — | — |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 1 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.377) | 2.5 (0.014) | 0.04× | 1.01× |
| 512 | 0.3 (0.777) | 4.3 (0.062) | 0.08× | 1.02× |
| 1024 | 1.3 (1.622) | 4.9 (0.438) | 0.27× | 1.00× |
| 2048 | 4.8 (3.562) | 5.1 (3.340) | 0.94× | 1.30× |
| 4096 | 8.8 (15.649) | 5.2 (26.590) | **1.70×** | **2.95×** |
| 8192 | 8.9 (124.204) | 5.1 (215.101) | **1.73×** | **2.46×** |
| 16384 | 9.0 (976.926) | 5.0 (1747.057) | **1.79×** | **2.41×** |
| 32768 | 9.1 (7753.640) | 5.0 (14146.727) | **1.82×** | — |

#### Ch 3 — Can the fetch overlap the math?
cp.async

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 2 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.244) | 2.3 (0.015) | 0.06× | **1.54×** |
| 512 | 0.6 (0.485) | 3.6 (0.074) | 0.15× | **1.60×** |
| 1024 | 2.2 (0.965) | 4.1 (0.524) | 0.54× | **1.68×** |
| 2048 | 7.9 (2.183) | 4.3 (4.022) | **1.84×** | **1.63×** |
| 4096 | 7.9 (17.295) | 4.3 (31.977) | **1.85×** | 0.90× |
| 8192 | 8.0 (138.193) | 4.3 (257.462) | **1.86×** | 0.90× |
| 16384 | 8.1 (1088.230) | 4.2 (2073.899) | **1.91×** | 0.90× |
| 32768 | 8.2 (8593.500) | 4.2 (16818.006) | **1.96×** | 0.90× |

#### Ch 4 — Can the fetch itself be cheap?
TMA descriptor (CUtensorMap)

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 3 |
|---:|---:|---:|---:|---:|
| 256 | 1.4 (0.023) | 2.3 (0.014) | 0.62× | **10.51×** |
| 512 | 6.4 (0.042) | 3.7 (0.074) | **1.74×** | **11.47×** |
| 1024 | 25.4 (0.084) | 4.1 (0.524) | **6.21×** | **11.42×** |
| 2048 | 68.7 (0.250) | 4.3 (4.022) | **16.08×** | **8.73×** |
| 4096 | 71.9 (1.912) | 4.3 (31.926) | **16.70×** | **9.05×** |
| 8192 | 72.3 (15.199) | 4.3 (255.466) | **16.81×** | **9.09×** |
| 16384 | 59.5 (147.840) | 4.3 (2064.429) | **13.96×** | **7.36×** |
| 32768 | 51.8 (1358.110) | 4.2 (16800.723) | **12.37×** | **6.33×** |

#### Ch 5 — Can several fetches be in flight?
SMEM ring

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 4 |
|---:|---:|---:|---:|---:|
| 256 | 1.6 (0.021) | 2.1 (0.016) | 0.75× | 1.11× |
| 512 | 7.1 (0.038) | 3.2 (0.083) | **2.20×** | 1.12× |
| 1024 | 27.7 (0.078) | 3.6 (0.603) | **7.77×** | 1.09× |
| 2048 | 64.3 (0.267) | 3.7 (4.638) | **17.37×** | 0.94× |
| 4096 | 68.5 (2.007) | 3.8 (36.420) | **18.15×** | 0.95× |
| 8192 | 66.6 (16.505) | 3.7 (294.523) | **17.84×** | 0.92× |
| 16384 | 52.2 (168.354) | 3.7 (2372.799) | **14.09×** | 0.88× |
| 32768 | 48.3 (1456.710) | 3.6 (19326.156) | **13.27×** | 0.93× |

#### Ch 6 — Can the math stop waiting on bookkeeping?
warp specialization

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 5 |
|---:|---:|---:|---:|---:|
| 256 | 3.2 (0.010) | — | — | **2.01×** |
| 512 | 15.8 (0.017) | — | — | **2.23×** |
| 1024 | 55.4 (0.039) | — | — | **2.00×** |
| 2048 | 71.4 (0.241) | — | — | 1.11× |
| 4096 | 75.1 (1.830) | — | — | 1.10× |
| 8192 | 60.6 (18.138) | — | — | 0.91× |
| 16384 | 47.3 (185.777) | — | — | 0.91× |
| 32768 | 46.6 (1511.680) | — | — | 0.96× |

#### Ch 7 — Can one instruction do more math?
wgmma

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 6 |
|---:|---:|---:|---:|---:|
| 256 | 2.8 (0.012) | — | — | 0.88× |
| 512 | 17.4 (0.015) | — | — | 1.10× |
| 1024 | 92.4 (0.023) | — | — | **1.67×** |
| 2048 | 253.1 (0.068) | — | — | **3.54×** |
| 4096 | 293.0 (0.469) | — | — | **3.90×** |
| 8192 | 295.3 (3.724) | — | — | **4.87×** |
| 16384 | 184.0 (47.807) | — | — | **3.89×** |
| 32768 | 145.7 (482.919) | — | — | **3.13×** |

</details>

## § 2 — Top MMA Benchmarks

*How does Crisp actually stand?* Best mainloop against **all three contender classes**.

### Intel BMG · tf32 · `fast`

| N | Crisp | Control<br>SYCL_Apples | **Peer**<br>SYCL-TLA | Ceiling<br>oneMKL | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.0 (0.011) `chap5_multistage_ring` | 1.5 (0.022) | N/A* | 5.2 (0.006) | — | 58% |
| 512 | 9.6 (0.028) `sec2_top` | 5.1 (0.052) | N/A* | 9.8 (0.027) | — | 99% |
| 1024 | 30.9 (0.070) `sec2_top` | 10.2 (0.211) | N/A* | 12.0 (0.179) | — | **258%** |
| 2048 | 31.7 (0.541) `sec2_top` | 11.3 (1.527) | N/A* | 13.8 (1.243) | — | **230%** |
| 4096 | 27.5 (5.000) `sec2_top` | 9.6 (14.333) | N/A* | 14.3 (9.603) | — | **192%** |
| 8192 | 15.9 (69.111) `sec2_top` | 7.6 (144.065) | N/A* | 14.2 (77.573) | — | 112% |
| 16384 | 10.1 (867.832) `sec2_top` | 4.8 (1820.566) | N/A* | 14.4 (611.618) | — | 70% |

> *\*Note: SYCL-TLA does not implement TF32 DPAS on Xe2 (only BF16/FP16/FP8). See §2.1 below for the native 270+ TFLOPS BF16 suite.*


<details><summary><b>Compilation & Build Overhead</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 762 ms | 1.67 s | 1.00× |
| **SYCL_Apples** | Control | 1.82 s | 4.99 s | **2.4× slower** |
| **oneMKL** | Ceiling | *precompiled* | 6.69 s | — |

</details>

### Intel BMG · bf16 · `fast` *(Native 270+ TFLOPS Matrix Engines)*

| N | Crisp BF16 | Control<br>SYCL_Apples_BF16 | **Peer**<br>SYCL-TLA_BF16 | Ceiling<br>oneMKL_BF16 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.0 (0.011) | 2.0 (0.017) | 0.3 (0.112) | 9.8 (0.003) | **9.96×** | 31% |
| 512 | 15.3 (0.018) | 7.5 (0.036) | 3.6 (0.074) | 41.0 (0.007) | **4.23×** | 37% |
| 1024 | 63.3 (0.034) | 15.3 (0.141) | 24.3 (0.088) | 75.1 (0.029) | **2.61×** | 84% |
| 2048 | 57.6 (0.298) | 17.7 (0.973) | 86.4 (0.199) | 87.4 (0.196) | 0.67× | 66% |
| 4096 | 64.9 (2.119) | 17.9 (7.687) | 188.9 (0.727) | 105.0 (1.309) | 0.34× | 62% |
| 8192 | 66.1 (16.643) | 15.2 (72.119) | 239.9 (4.583) | 112.8 (9.744) | 0.28× | 59% |
| 16384 | — | 11.0 (801.056) | 248.2 (35.435) | 114.5 (76.830) | — | — |

<details><summary><b>Compilation & Build Overhead (BF16)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Control codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 1.34 s | 1.34 s | 0.70× |
| **SYCL_Apples_BF16** | Control | 1.92 s | 4.24 s | 1.00× |
| **SYCL-TLA_BF16** | Peer | 30.91 s | 65.37 s | **16.1× slower** |
| **oneMKL_BF16** | Ceiling | *precompiled* | 7.33 s | — |

</details>

### Intel BMG · fp16 · `fast` *(Native 270+ TFLOPS Matrix Engines)*

Crisp is **outside-in**: the user picks the configuration, exactly as SYCL-TLA's pipeline depth is a template argument. So two Crisp columns, and the gap between them is *what tuning is worth*. **Envelope** is the best variant at each size, naming which one. **Best single** is the one fixed choice that does best across all sizes (`base`) — what you get without per-size tuning. 5 variants measured.

| N | Crisp FP16<br>**envelope** | Crisp FP16<br>best single (`base`) | Control<br>SYCL_Apples_FP16 | **Peer**<br>SYCL-TLA_FP16 | Ceiling<br>oneMKL_FP16 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.1 (0.011) `pfw3` | 3.0 | 2.0 (0.017) | — | 9.8 (0.003) | — | 32% |
| 512 | 16.4 (0.016) `pfw2` | 15.3 | 7.5 (0.036) | — | 41.0 (0.007) | — | 40% |
| 1024 | 63.0 (0.034) `pfw1` | 62.2 | 15.3 (0.140) | — | 75.1 (0.029) | — | 84% |
| 2048 | 70.9 (0.242) `pfw1` | 57.8 | 17.7 (0.972) | — | 87.9 (0.195) | — | 81% |
| 4096 | 91.4 (1.503) `pfw1` | 65.2 | 17.9 (7.691) | — | 110.8 (1.241) | — | 83% |
| 8192 | 65.9 (16.674) `base` | 65.9 | 15.2 (72.165) | — | 111.5 (9.863) | — | 59% |
| 16384 | — | — | 11.0 (801.185) | — | 111.1 (79.180) | — | — |

> **⚠ SIGN FLIPS — these variants reverse with problem size.**
> Each wins somewhere and loses somewhere, both beyond the measured run-to-run
> spread, so a single fixed choice is not available and the envelope above is
> assembled from *different kernels*. Picking by one size will mislead you at another.

> | variant | wins at | loses at |
> |---|---|---|
> | `pfw1` | 256 (+4%), 512 (+7%), 2048 (+23%), 4096 (+40%) | **8192 (-55%)** |
> | `pfw2` | 256 (+4%), 512 (+8%), 2048 (+19%), 4096 (+33%) | **8192 (-56%)** |
> | `pfw3` | 256 (+5%), 512 (+8%), 2048 (+16%), 4096 (+24%) | **8192 (-58%)** |
> | `pfw4` | 256 (+5%), 512 (+7%), 2048 (+14%), 4096 (+19%) | **8192 (-54%)** |


<details><summary><b>Compilation & Build Overhead (FP16)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Control codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 1.30 s | 1.30 s | 0.69× |
| **SYCL_Apples_FP16** | Control | 1.88 s | 4.13 s | 1.00× |
| **oneMKL_FP16** | Ceiling | *precompiled* | 6.52 s | — |

</details>

### NVIDIA H100 NVL · tf32 · `fast`

| N | Crisp | Control<br>CUDA_Apples | **Peer**<br>CUTLASS | Ceiling<br>cuBLAS | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.2 (0.010) `chap6_warp_specialization` | 2.1 (0.016) | — | 5.4 (0.006) | — | 59% |
| 512 | 17.4 (0.015) `sec2_top` | 3.2 (0.083) | — | 30.7 (0.009) | — | 57% |
| 1024 | 92.4 (0.023) `chap7_wgmma` | 3.6 (0.603) | — | 141.3 (0.015) | — | 65% |
| 2048 | 253.9 (0.068) `sec2_top` | 3.7 (4.632) | — | 326.6 (0.053) | — | 78% |
| 4096 | 295.8 (0.465) `sec2_top` | 3.8 (36.420) | — | 386.3 (0.356) | — | 77% |
| 8192 | 295.3 (3.724) `chap7_wgmma` | 3.7 (293.820) | — | 408.3 (2.693) | — | 72% |
| 16384 | 184.0 (47.807) `chap7_wgmma` | 3.7 (2359.985) | — | 282.7 (31.112) | — | 65% |
| 32768 | 145.7 (482.919) `chap7_wgmma` | 3.6 (19326.156) | — | 308.6 (227.998) | — | 47% |

<details><summary><b>Compilation & Build Overhead</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 330 ms | 330 ms | 1.00× |
| **CUDA_Apples** | Control | 727 ms | 2.07 s | **2.2× slower** |
| **CUTLASS** | Peer | 445 ms | 1.86 s | **1.3× slower** |
| **cuBLAS** | Ceiling | *precompiled* | 1.05 s | — |

</details>

## § 3 — Situational Techniques

*Techniques whose honest answer is "it depends."* Controlled pairs:

### TMA Multicast (NVIDIA only) · H100 NVL
| tile | AI | N=1024 | N=2048 | N=4096 |
|---|---:|---:|---:|---:|
| 64×256 | 25.6 | −6.1% | **−7.0%** | −9.7% |
| **64×128** | 21.3 | −6.1% | **+15.5%** | **+10.7%** |
| 64×64 | 16.0 | +0.4% | +1.1% | +4.4% |

### MMA Lowering: `:xe-native` vs `:coop-matrix` (Intel only) · Intel BMG

*Same kernel, same 32x64 bf16 geometry over one subgroup; only the lowering differs. `tuned` adds ring depth 2 and prefetch distance 2, which makes its `:coop-matrix` arm the shipped section 2.1 kernel.*

Each cell reads **`:coop-matrix` TFLOPS -> `:xe-native` TFLOPS (change)**, where the change is `(xe_native / coop_matrix - 1)`. Higher TFLOPS is faster, so a positive change means `:xe-native` won at that size.

| pairing | N=256 | N=512 | N=1024 | N=2048 | N=4096 | N=8192 |
|---|---:|---:|---:|---:|---:|---:|
| bare (no ring, no prefetch) | 3.8→4.6 (**+21.4%**) | 16.9→20.5 (**+21.4%**) | 53.8→65.3 (**+21.5%**) | 51.9→58.1 (**+11.9%**) | 47.8→52.0 (**+8.8%**) | 46.0→52.3 (**+13.7%**) |
| tuned (ring 2, prefetch 2) | 3.8→5.0 (**+30.8%**) | 16.9→22.1 (**+30.8%**) | 49.9→45.1 (**−9.6%**) | 60.9→51.7 (**−15.2%**) | 57.6→43.9 (**−23.7%**) | 37.0→36.5 (−1.5%) |

Positive means `:xe-native` is faster. It wins bare and loses tuned: the lowering is better in isolation and does **not** compose with the register-tile ring. See `docs/topology.md`, `mma-lowering`.

## § 1b — The Technique Ladder in 16-bit (Intel) · Intel BMG

*The same chapters as section 1, in bfloat16. Each kernel is its tf32 twin with two things changed: the operand element type, and the K step 8 → 16 (the native XMX shape for 16-bit operands is (8 16 16), not (8 16 8)). The C accumulator stays f32 in both.*

Cells read **bf16 TFLOPS (× vs the same chapter in tf32)**. The 32-bit baseline is **tf32 on XMX**, not fp32 on the vector engines — the BMG shape ladder is (8 16 8) tf32, (8 16 16) bf16, (8 16 32) int8, i.e. same M×N with K doubling per step. No Control/Peer/Ceiling columns: the chapter SYCL controls are tf32 only, so this is a Crisp-vs-Crisp ladder.

| chapter | N=256 | N=512 | N=1024 | N=2048 | N=4096 | N=8192 |
|---|---:|---:|---:|---:|---:|---:|
| Ch 0 naive (no XMX) | 0.1 (1.00×) | 0.2 (1.16×) | 0.1 (1.03×) | 0.1 (1.03×) | 0.1 (1.15×) | 0.1 (1.63×) |
| Ch 1 hand-rolled MMA | 0.2 (**2.03×**) | 0.8 (**2.19×**) | 2.3 (1.68×) | 2.3 (1.67×) | 2.1 (1.49×) | 1.9 (1.46×) |
| Ch 2 tiling macro | 0.2 (tf32 n/a) | 0.8 (tf32 n/a) | 2.3 (tf32 n/a) | 2.3 (tf32 n/a) | 2.0 (tf32 n/a) | 1.9 (tf32 n/a) |
| Ch 3 async staging | — | 0.0 (0.01×) | — | — | — | — |
| Ch 4 register-resident | 4.5 (1.56×) | 19.7 (1.65×) | 46.5 (1.79×) | 37.3 (**2.28×**) | 26.4 (**2.11×**) | 25.6 (**2.79×**) |
| Ch 5 ring + prefetch | 4.7 (1.56×) | 15.7 (1.66×) | 39.5 (**1.84×**) | 42.5 (1.78×) | 34.2 (**2.13×**) | 26.6 (**2.04×**) |

## § 4 — MMA + Activation

*What does fusing an arbitrary activation buy?*

| contender | arbitrary activation? | what Crisp claims |
|---|---|---|
| cuBLASLt, oneDNN (**Ceiling**) | **No** — fixed enum / post-op set | **capability** — off-menu costs 2nd kernel + HBM round trip |
| CUTLASS, SYCL-TLA (**Peer**) | **Yes** — monomorphised functor | **expressiveness & compile time** (~165× faster build) |

### Intel BMG · tf32 · `fast`

#### Ch 1 — Standard Epilogue (ReLU)

| N | Crisp Fused | **Peer**<br>SYCL-TLA Fused | **Ceiling**<br>oneDNN Fused | Baseline+2nd Kernel<br>oneMKL + ReLU | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.2 (0.011) | N/A* | 5.4 (0.006) | 3.8 (0.009) | — | 59% |
| 512 | 9.6 (0.028) | N/A* | 9.8 (0.027) | 8.6 (0.031) | — | 98% |
| 1024 | 21.3 (0.101) | N/A* | 13.3 (0.162) | 11.4 (0.189) | — | **160%** |
| 2048 | 24.1 (0.713) | N/A* | 14.1 (1.222) | 13.2 (1.302) | — | **171%** |
| 4096 | 16.7 (8.225) | N/A* | 14.3 (9.586) | 13.9 (9.905) | — | 117% |
| 8192 | 13.5 (81.290) | N/A* | 14.5 (76.083) | 13.9 (78.980) | — | 94% |
| 16384 | 10.3 (849.994) | N/A* | 14.5 (608.340) | 14.3 (617.230) | — | 72% |

> *\*Note: SYCL-TLA only implements BF16/FP16/FP8 on Xe2.*


<details><summary><b>Compilation & Build Overhead (Fused ReLU)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 791 ms | 791 ms | 1.00× |
| **oneDNN Fused** | Ceiling | *precompiled* | 5.97 s | — |

</details>

#### Ch 2 — Custom Epilogue (Arbitrary User Function)

> *Ceilings (oneDNN / cuBLASLt) cannot fuse arbitrary user functions — forced to pay 2nd kernel + HBM round-trip.*

| N | Crisp Fused | **Peer**<br>SYCL-TLA Fused | Ceiling (2nd Kernel)<br>oneDNN + Custom | vs Peer | **vs Ceiling (2nd Kernel)** |
|---:|---:|---:|---:|---:|---:|
| 256 | 3.1 (0.011) | N/A* | 3.7 (0.009) | — | **83%** |
| 512 | 9.5 (0.028) | N/A* | 8.5 (0.032) | — | **111%** |
| 1024 | 21.2 (0.101) | N/A* | 11.3 (0.190) | — | ****188%**** |
| 2048 | 24.1 (0.711) | N/A* | 13.2 (1.301) | — | ****183%**** |
| 4096 | 16.7 (8.242) | N/A* | 13.7 (9.999) | — | **121%** |
| 8192 | 13.8 (79.612) | N/A* | 13.9 (78.980) | — | **99%** |
| 16384 | 10.0 (876.373) | N/A* | 14.3 (617.241) | — | **70%** |

<details><summary><b>Compilation & Build Overhead (Fused Custom)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 751 ms | 751 ms | 1.00× |
| **oneDNN + Custom** | Ceiling | *precompiled* | 7.01 s | — |

</details>

### NVIDIA H100 NVL · tf32 · `fast`

#### Ch 1 — Standard Epilogue (ReLU)

| N | Crisp Fused | **Peer**<br>CUTLASS Fused | **Ceiling**<br>cuBLASLt Fused | Baseline+2nd Kernel<br>cuBLAS + ReLU | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 2.8 (0.012) | — | 3.5 (0.009) | 2.3 (0.015) | — | 80% |
| 512 | 17.4 (0.015) | — | 22.3 (0.012) | 14.8 (0.018) | — | 78% |
| 1024 | 92.5 (0.023) | — | 99.4 (0.022) | 72.9 (0.029) | — | 93% |
| 2048 | 254.3 (0.068) | — | 292.9 (0.059) | 228.6 (0.075) | — | 87% |
| 4096 | 296.2 (0.464) | — | 376.6 (0.365) | 325.2 (0.423) | — | 79% |
| 8192 | 295.0 (3.727) | — | 406.2 (2.707) | 375.3 (2.930) | — | 73% |
| 16384 | 183.8 (47.846) | — | 283.7 (31.005) | 274.2 (32.084) | — | 65% |
| 32768 | 146.5 (480.205) | — | 308.3 (228.220) | 299.2 (235.156) | — | 48% |

<details><summary><b>Compilation & Build Overhead (Fused ReLU)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 421 ms | 421 ms | 1.00× |
| **cuBLASLt Fused** | Ceiling | *precompiled* | 1.61 s | — |

</details>

#### Ch 2 — Custom Epilogue (Arbitrary User Function)

> *Ceilings (oneDNN / cuBLASLt) cannot fuse arbitrary user functions — forced to pay 2nd kernel + HBM round-trip.*

| N | Crisp Fused | **Peer**<br>CUTLASS Fused | Ceiling (2nd Kernel)<br>cuBLASLt + Custom | vs Peer | **vs Ceiling (2nd Kernel)** |
|---:|---:|---:|---:|---:|---:|
| 256 | 2.8 (0.012) | — | 2.8 (0.012) | — | **101%** |
| 512 | 17.2 (0.016) | — | 17.9 (0.015) | — | **96%** |
| 1024 | 91.6 (0.023) | — | 80.6 (0.027) | — | **114%** |
| 2048 | 246.5 (0.070) | — | 227.1 (0.076) | — | **109%** |
| 4096 | 289.9 (0.474) | — | 327.1 (0.420) | — | **89%** |
| 8192 | 251.6 (4.369) | — | 375.4 (2.929) | — | **67%** |
| 16384 | 182.8 (48.113) | — | 273.4 (32.172) | — | **67%** |
| 32768 | 141.6 (496.865) | — | 305.6 (230.295) | — | **46%** |

<details><summary><b>Compilation & Build Overhead (Fused Custom)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 434 ms | 434 ms | 1.00× |
| **cuBLASLt + Custom** | Ceiling | *precompiled* | 1.63 s | — |

</details>

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
| 2026-08-24 01:04 | matmul | sec2_top | Crisp | `256,512,1024,2048,4096,8192` |
| 2026-08-24 01:05 | matmul | sec2_top | SYCL_Apples | `` |
| 2026-08-24 01:05 | matmul | sec2_top | OneMKL_Optimal | `256,512,1024,2048,4096,8192,16384` |
| 2026-08-26 14:31 | matmul | sec2_top_bf16 | Crisp | `1024,2048,4096,8192` |
| 2026-08-26 14:31 | matmul | sec2_top_fp16 | Crisp | `1024,2048,4096,8192` |
| 2026-08-26 14:32 | matmul | sec2_top_bf16 | Crisp | `2048` |
| 2026-08-26 14:33 | matmul | sec2_top_bf16 | Crisp | `1024,2048,4096,8192` |
| 2026-08-26 14:33 | matmul | sec2_top_fp16 | Crisp | `1024,2048,4096,8192` |
| 2026-08-26 14:33 | matmul | sec2_top_bf16 | Crisp | `1024,2048,4096,8192` |
| 2026-08-26 14:34 | matmul | sec2_top_fp16 | Crisp | `1024,2048,4096,8192` |
| 2026-08-27 06:21 | matmul | _probe_roofline | Probe_Full | `2048,4096` |
| 2026-08-27 06:21 | matmul | _probe_roofline | Probe_Loads | `` |
| 2026-08-27 06:21 | matmul | _probe_roofline | Probe_Math | `` |
| 2026-08-27 07:33 | matmul | _probe_roofline | Probe_Full | `2048,4096` |
| 2026-08-27 07:33 | matmul | _probe_roofline | Probe_Loads | `` |
| 2026-08-27 07:33 | matmul | _probe_roofline | Probe_Math | `` |
| 2026-08-27 07:33 | matmul | _probe_roofline | Probe_Loads_CC | `` |
| 2026-08-27 07:33 | matmul | _probe_roofline | Probe_Loads_PF2 | `` |
| 2026-08-27 07:33 | matmul | _probe_roofline | Probe_Loads_PF3 | `` |
| 2026-08-27 07:33 | matmul | _probe_roofline | Probe_Loads_Fixed | `` |
| 2026-08-27 17:16 | matmul | _probe_roofline | Probe_Full | `2048,4096` |
| 2026-08-27 17:16 | matmul | _probe_roofline | Probe_Loads | `` |
| 2026-08-27 17:16 | matmul | _probe_roofline | Probe_Loads_PFW2 | `` |
| 2026-08-27 17:16 | matmul | _probe_roofline | Probe_Loads_PFW3 | `` |
| 2026-08-27 17:16 | matmul | _probe_roofline | Probe_Full_PFW2 | `2048,4096` |
| 2026-08-27 17:16 | matmul | _probe_roofline | Probe_Full_PFW3 | `2048,4096` |
| 2026-08-27 18:06 | matmul | _probe_roofline | Probe_Full | `2048,4096,8192` |
| 2026-08-27 18:06 | matmul | _probe_roofline | Probe_Loads | `` |
| 2026-08-27 18:06 | matmul | _probe_roofline | Probe_Full_PFW1 | `2048,4096,8192` |
| 2026-08-27 18:06 | matmul | _probe_roofline | Probe_Full_PFW2 | `2048,4096,8192` |
| 2026-08-27 18:07 | matmul | _probe_roofline | Probe_Full_PFW3 | `2048,4096,8192` |
| 2026-08-27 18:07 | matmul | _probe_roofline | Probe_Full_PFW4 | `2048,4096,8192` |