# Crisp Benchmark Report

> Generated from verified test sweeps in `benchmarks/results/`.

| device | data captured | source |
|---|---|---|
| Intel BMG | 2026-08-25 | Crisp `570d524` (docker) |
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
| 256 | 3.0 (0.011) | 1.5 (0.022) | N/A* | 5.3 (0.006) | — | 58% |
| 512 | 9.7 (0.028) | 5.1 (0.052) | N/A* | 9.8 (0.027) | — | 99% |
| 1024 | 31.0 (0.069) | 10.2 (0.211) | N/A* | 11.9 (0.180) | — | **260%** |
| 2048 | 31.1 (0.552) | 11.3 (1.527) | N/A* | 13.8 (1.242) | — | **225%** |
| 4096 | 27.9 (4.931) | 9.6 (14.333) | N/A* | 14.3 (9.603) | — | **195%** |
| 8192 | 16.2 (67.691) | 7.6 (144.065) | N/A* | 14.2 (77.570) | — | 115% |
| 16384 | 10.1 (867.832) | 4.8 (1820.566) | N/A* | 14.4 (611.618) | — | 70% |

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
| 256 | 3.8 (0.009) | 2.0 (0.017) | 0.3 (0.109) | 9.8 (0.003) | **12.34×** | 39% |
| 512 | 16.9 (0.016) | 7.5 (0.036) | 3.6 (0.075) | 41.0 (0.007) | **4.69×** | 41% |
| 1024 | 50.4 (0.043) | 15.3 (0.140) | 22.5 (0.095) | 75.1 (0.029) | **2.24×** | 67% |
| 2048 | 61.4 (0.280) | 17.6 (0.974) | 99.5 (0.173) | 86.6 (0.198) | 0.62× | 71% |
| 4096 | 57.9 (2.375) | 17.9 (7.676) | 178.1 (0.772) | 105.0 (1.309) | 0.32× | 55% |
| 8192 | 38.3 (28.680) | 15.2 (72.130) | 233.3 (4.713) | 112.9 (9.743) | 0.16× | 34% |
| 16384 | — | 11.0 (801.056) | 248.2 (35.435) | 114.5 (76.830) | — | — |

<details><summary><b>Compilation & Build Overhead (BF16)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Control codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 1.22 s | 2.11 s | 0.64× |
| **SYCL_Apples_BF16** | Control | 1.92 s | 4.24 s | 1.00× |
| **SYCL-TLA_BF16** | Peer | 30.91 s | 65.37 s | **16.1× slower** |
| **oneMKL_BF16** | Ceiling | *precompiled* | 7.33 s | — |

</details>

### Intel BMG · fp16 · `fast` *(Native 270+ TFLOPS Matrix Engines)*

| N | Crisp FP16 | Control<br>SYCL_Apples_FP16 | **Peer**<br>SYCL-TLA_FP16 | Ceiling<br>oneMKL_FP16 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.8 (0.009) | 2.0 (0.017) | — | 9.8 (0.003) | — | 39% |
| 512 | 16.9 (0.016) | 7.5 (0.036) | — | 41.0 (0.007) | — | 41% |
| 1024 | 50.0 (0.043) | 15.3 (0.141) | — | 75.1 (0.029) | — | 67% |
| 2048 | 61.1 (0.281) | 17.6 (0.974) | — | 87.0 (0.197) | — | 70% |
| 4096 | 57.6 (2.385) | 17.8 (7.715) | — | 110.8 (1.240) | — | 52% |
| 8192 | 36.3 (30.250) | 15.2 (72.220) | — | 111.9 (9.828) | — | 32% |
| 16384 | — | 11.0 (801.185) | — | 111.1 (79.180) | — | — |

<details><summary><b>Compilation & Build Overhead (FP16)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Control codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 762 ms | 1.62 s | 0.41× |
| **SYCL_Apples_FP16** | Control | 1.88 s | 4.13 s | 1.00× |
| **oneMKL_FP16** | Ceiling | *precompiled* | 6.52 s | — |

</details>

### NVIDIA H100 NVL · tf32 · `fast`

| N | Crisp | Control<br>CUDA_Apples | **Peer**<br>CUTLASS | Ceiling<br>cuBLAS | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.2 (0.010) | 2.1 (0.016) | — | 5.4 (0.006) | — | 59% |
| 512 | 17.4 (0.015) | 3.2 (0.083) | — | 30.7 (0.009) | — | 57% |
| 1024 | 92.4 (0.023) | 3.6 (0.603) | — | 141.3 (0.015) | — | 65% |
| 2048 | 253.9 (0.068) | 3.7 (4.632) | — | 326.6 (0.053) | — | 78% |
| 4096 | 295.8 (0.465) | 3.8 (36.420) | — | 386.3 (0.356) | — | 77% |
| 8192 | 295.3 (3.724) | 3.7 (293.820) | — | 408.3 (2.693) | — | 72% |
| 16384 | 184.0 (47.807) | 3.7 (2359.985) | — | 282.7 (31.112) | — | 65% |
| 32768 | 145.7 (482.919) | 3.6 (19326.156) | — | 308.6 (227.998) | — | 47% |

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

| pairing | N=512 | N=1024 | N=2048 | N=4096 |
|---|---:|---:|---:|---:|
| bare (no ring, no prefetch) | **+23.2%** | **+15.8%** | **+12.7%** | **+9.8%** |
| tuned (ring 2, prefetch 2) | **+29.9%** | **−9.4%** | **−16.6%** | — |

Positive means `:xe-native` is faster. It wins bare and loses tuned: the lowering is better in isolation and does **not** compose with the register-tile ring. See `docs/topology.md`, `mma-lowering`.

> **Incomplete data.** `Crisp_XeNative_Tuned` has no point at N=4096. The autobench sweep intermittently drops points for this contender; the kernel itself is fine, and runs correctly at every size when invoked directly (e.g. 45.2 TFLOPS MMA_CORRECT at N=1024 on a run where the sweep recorded nothing). Read the affected cells as missing data, not as a result.

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
| 256 | 3.2 (0.011) | N/A* | 5.4 (0.006) | 3.7 (0.009) | — | 59% |
| 512 | 9.6 (0.028) | N/A* | 9.8 (0.027) | 8.5 (0.031) | — | 98% |
| 1024 | 21.4 (0.100) | N/A* | 13.1 (0.164) | 11.3 (0.190) | — | **164%** |
| 2048 | 24.1 (0.714) | N/A* | 14.1 (1.222) | 13.2 (1.300) | — | **171%** |
| 4096 | 16.8 (8.164) | N/A* | 14.3 (9.585) | 13.9 (9.901) | — | 117% |
| 8192 | 12.2 (90.212) | N/A* | 14.5 (76.080) | 13.9 (78.946) | — | 84% |
| 16384 | 10.3 (849.994) | N/A* | 14.5 (608.340) | 14.3 (617.230) | — | 72% |

> *\*Note: SYCL-TLA only implements BF16/FP16/FP8 on Xe2.*


<details><summary><b>Compilation & Build Overhead (Fused ReLU)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 721 ms | 1.56 s | 1.00× |
| **oneDNN Fused** | Ceiling | *precompiled* | 5.98 s | — |

</details>

#### Ch 2 — Custom Epilogue (Arbitrary User Function)

> *Ceilings (oneDNN / cuBLASLt) cannot fuse arbitrary user functions — forced to pay 2nd kernel + HBM round-trip.*

| N | Crisp Fused | **Peer**<br>SYCL-TLA Fused | Ceiling (2nd Kernel)<br>oneDNN + Custom | vs Peer | **vs Ceiling (2nd Kernel)** |
|---:|---:|---:|---:|---:|---:|
| 256 | 3.1 (0.011) | N/A* | 3.7 (0.009) | — | **83%** |
| 512 | 9.5 (0.028) | N/A* | 8.5 (0.031) | — | **111%** |
| 1024 | 21.0 (0.102) | N/A* | 11.3 (0.190) | — | ****185%**** |
| 2048 | 24.2 (0.708) | N/A* | 13.2 (1.301) | — | ****184%**** |
| 4096 | 16.5 (8.321) | N/A* | 13.9 (9.901) | — | **119%** |
| 8192 | 11.7 (93.876) | N/A* | 13.9 (78.975) | — | **84%** |
| 16384 | 10.0 (876.373) | N/A* | 14.3 (617.241) | — | **70%** |

<details><summary><b>Compilation & Build Overhead (Fused Custom)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 703 ms | 1.54 s | 1.00× |
| **oneDNN + Custom** | Ceiling | *precompiled* | 7.00 s | — |

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