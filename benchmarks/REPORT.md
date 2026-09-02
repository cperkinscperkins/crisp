# Crisp Benchmark Report

> Generated from verified test sweeps in `benchmarks/results/`.

| device | data captured | source |
|---|---|---|
| Intel BMG | 2026-08-29 | Crisp `c16d1f4` (docker) |
| NVIDIA H100 NVL | 2026-09-01 | Crisp `34ab4dd1` (runpod) |
| NVIDIA H100 PCIe | 2026-08-31 | Crisp `5f2c679b` (runpod) |

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
| 0 | naive loops, no XMX | 0.1 | 0.2 | 0.2 | 0.1 | 0.1 | 0.1 | — |
| 1 | hand-rolled XMX coop-matrix | 0.1 | 0.5 | 1.7 | 1.7 | 1.8 | 1.7 | — |
| 2 | matrix-multiply-tile-stride | 0.1 | 0.4 | 1.4 | 1.4 | 1.5 | 1.3 | — |
| 3 | OpGroupAsyncCopy | 0.1 | 0.2 | 0.8 | 0.8 | 0.7 | 0.7 | — |
| 4 | register-resident load (global→GRF) | 2.9 | 12.0 | 25.6 | 15.7 | 13.3 | 13.4 | — |
| 5 | register ring + prefetch | 3.4 | 10.0 | 22.8 | 27.4 | 15.4 | 11.3 | — |
| 6 | blocked — 3 known reasons | — | — | — | — | — | — | — |
| 7 | GRF-bounded tile sweep | 3.0 | 9.6 | 21.8 | 24.7 | 15.8 | 11.7 | — |

<details><summary><b>Per-chapter detail</b></summary>

#### Ch 0 — Does it run at all?
naive loops, no XMX

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control |
|---:|---:|---:|---:|
| 256 | 0.1 (0.236) | 0.5 (0.074) | 0.31× |
| 512 | 0.2 (1.751) | 0.6 (0.450) | 0.26× |
| 1024 | 0.2 (13.898) | 0.7 (3.169) | 0.23× |
| 2048 | 0.1 (123.641) | 0.5 (36.960) | 0.30× |
| 4096 | 0.1 (1105.390) | 0.3 (525.380) | 0.48× |
| 8192 | 0.1 (15755.700) | 0.3 (4054.830) | 0.26× |
| 16384 | — | — | — |

#### Ch 1 — Can we reach the tensor cores?
hand-rolled XMX coop-matrix

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 0 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.278) | 0.2 (0.201) | 0.72× | 0.85× |
| 512 | 0.5 (0.588) | 0.5 (0.496) | 0.84× | **2.98×** |
| 1024 | 1.7 (1.294) | 1.5 (1.397) | 1.08× | **10.74×** |
| 2048 | 1.7 (10.101) | 1.8 (9.360) | 0.93× | **12.24×** |
| 4096 | 1.8 (75.052) | 2.0 (67.620) | 0.90× | **14.73×** |
| 8192 | 1.7 (663.558) | 2.2 (511.393) | 0.77× | **23.74×** |
| 16384 | — | — | — | — |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 1 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.308) | 1.3 (0.026) | 0.08× | 0.90× |
| 512 | 0.4 (0.692) | 1.5 (0.184) | 0.27× | 0.85× |
| 1024 | 1.4 (1.587) | 1.5 (1.400) | 0.88× | 0.82× |
| 2048 | 1.4 (12.059) | 1.5 (11.469) | 0.95× | 0.84× |
| 4096 | 1.5 (92.395) | 1.3 (104.857) | 1.13× | 0.81× |
| 8192 | 1.3 (821.016) | 1.3 (838.490) | 1.02× | 0.81× |
| 16384 | — | — | — | — |

#### Ch 3 — Can the fetch overlap the math?
OpGroupAsyncCopy

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 2 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.413) | 1.3 (0.026) | 0.06× | 0.75× |
| 512 | 0.2 (1.090) | 1.5 (0.184) | 0.17× | 0.64× |
| 1024 | 0.8 (2.776) | 1.5 (1.403) | 0.51× | 0.57× |
| 2048 | 0.8 (21.353) | 1.5 (11.464) | 0.54× | 0.56× |
| 4096 | 0.7 (186.632) | 1.3 (104.419) | 0.56× | 0.50× |
| 8192 | 0.7 (1475.660) | 1.3 (844.132) | 0.57× | 0.56× |
| 16384 | — | — | — | — |

#### Ch 4 — Can the fetch itself be cheap?
register-resident load (global→GRF)

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 3 |
|---:|---:|---:|---:|---:|
| 256 | 2.9 (0.012) | 3.5 (0.009) | 0.82× | **35.82×** |
| 512 | 12.0 (0.022) | 14.3 (0.019) | 0.84× | **48.75×** |
| 1024 | 25.6 (0.084) | 30.5 (0.071) | 0.84× | **33.08×** |
| 2048 | 15.7 (1.094) | 21.8 (0.788) | 0.72× | **19.52×** |
| 4096 | 13.3 (10.316) | 21.0 (6.530) | 0.63× | **18.09×** |
| 8192 | 13.4 (82.212) | 6.6 (167.486) | **2.04×** | **17.95×** |
| 16384 | — | — | — | — |

#### Ch 5 — Can several fetches be in flight?
register ring + prefetch

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 4 |
|---:|---:|---:|---:|---:|
| 256 | 3.4 (0.010) | 1.9 (0.017) | **1.75×** | 1.17× |
| 512 | 10.0 (0.027) | 5.7 (0.047) | **1.75×** | 0.83× |
| 1024 | 22.8 (0.094) | 11.5 (0.186) | **1.98×** | 0.89× |
| 2048 | 27.4 (0.626) | 12.7 (1.350) | **2.15×** | **1.75×** |
| 4096 | 15.4 (8.947) | 10.3 (13.310) | 1.49× | 1.15× |
| 8192 | 11.3 (96.944) | 7.0 (156.531) | **1.61×** | 0.85× |
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
| 256 | 3.0 (0.011) | 1.5 (0.022) | **2.00×** | 0.90× |
| 512 | 9.6 (0.028) | 5.1 (0.052) | **1.86×** | 0.96× |
| 1024 | 21.8 (0.099) | 10.1 (0.212) | **2.15×** | 0.95× |
| 2048 | 24.7 (0.696) | 11.3 (1.527) | **2.19×** | 0.90× |
| 4096 | 15.8 (8.719) | 9.6 (14.386) | **1.65×** | 1.03× |
| 8192 | 11.7 (93.626) | 7.6 (144.065) | **1.54×** | 1.04× |
| 16384 | — | — | — | — |

</details>

### NVIDIA H100 NVL · tf32 · `fast`

**Rollup — Crisp TFLOPS, every chapter × every N.**

| # | technique | **N=256** | **N=512** | **N=1024** | **N=2048** | **N=4096** | **N=8192** | **N=16384** | **N=32768** |
|---|---|---|---|---|---|---|---|---|---|
| 0 | naive loops, no tensor cores | 0.8 | 0.8 | 0.9 | 0.9 | 0.9 | 0.9 | 0.9 | — |
| 1 | hand-rolled mma-accumulate-via-tile | 0.1 | 0.3 | 1.3 | 3.7 | 3.0 | 3.6 | 3.8 | — |
| 2 | matrix-multiply-tile-stride | 0.1 | 0.3 | 1.3 | 4.8 | 8.7 | 8.8 | 9.0 | 9.1 |
| 3 | cp.async | 0.1 | 0.6 | 2.2 | 7.8 | 8.0 | 8.0 | 8.1 | 8.2 |
| 4 | TMA descriptor (CUtensorMap) | 1.5 | 6.4 | 25.5 | 68.7 | 71.8 | 72.5 | 58.5 | 52.0 |
| 5 | SMEM ring | 1.6 | 7.1 | 27.7 | 64.5 | 68.4 | 67.0 | 49.7 | 48.4 |
| 6 | warp specialization | 3.2 | 16.0 | 57.9 | 80.3 | 81.4 | 71.3 | 48.3 | 38.4 |
| 7 | wgmma | 2.9 | 17.5 | 95.2 | 119.5 | 153.1 | 282.2 | 181.7 | 143.3 |

<details><summary><b>Per-chapter detail</b></summary>

#### Ch 0 — Does it run at all?
naive loops, no tensor cores

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control |
|---:|---:|---:|---:|
| 256 | 0.8 (0.042) | 0.7 (0.047) | 1.12× |
| 512 | 0.8 (0.319) | 0.8 (0.341) | 1.07× |
| 1024 | 0.9 (2.517) | 0.8 (2.667) | 1.06× |
| 2048 | 0.9 (19.588) | 0.8 (20.792) | 1.06× |
| 4096 | 0.9 (156.678) | 0.8 (165.749) | 1.06× |
| 8192 | 0.9 (1242.700) | 0.8 (1324.629) | 1.07× |
| 16384 | 0.9 (9948.510) | 0.8 (10584.927) | 1.06× |
| 32768 | — | — | — |

#### Ch 1 — Can we reach the tensor cores?
hand-rolled mma-accumulate-via-tile

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 0 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.376) | 2.3 (0.014) | 0.04× | 0.11× |
| 512 | 0.3 (0.789) | 3.7 (0.073) | 0.09× | 0.40× |
| 1024 | 1.3 (1.626) | 4.1 (0.524) | 0.32× | **1.55×** |
| 2048 | 3.7 (4.647) | 4.3 (4.016) | 0.86× | **4.21×** |
| 4096 | 3.0 (46.542) | 4.3 (31.916) | 0.69× | **3.37×** |
| 8192 | 3.6 (304.179) | — | — | **4.09×** |
| 16384 | 3.8 (2344.910) | — | — | **4.24×** |
| 32768 | — | — | — | — |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 1 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.377) | 2.5 (0.014) | 0.04× | 1.00× |
| 512 | 0.3 (0.777) | 4.3 (0.062) | 0.08× | 1.02× |
| 1024 | 1.3 (1.622) | 4.9 (0.438) | 0.27× | 1.00× |
| 2048 | 4.8 (3.562) | 5.1 (3.336) | 0.94× | 1.30× |
| 4096 | 8.7 (15.742) | 5.2 (26.592) | **1.69×** | **2.96×** |
| 8192 | 8.8 (124.693) | 5.1 (214.145) | **1.72×** | **2.44×** |
| 16384 | 9.0 (978.594) | 5.0 (1742.550) | **1.78×** | **2.40×** |
| 32768 | 9.1 (7755.200) | 5.0 (14101.073) | **1.82×** | — |

#### Ch 3 — Can the fetch overlap the math?
cp.async

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 2 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.244) | 2.3 (0.014) | 0.06× | **1.54×** |
| 512 | 0.6 (0.483) | 3.7 (0.073) | 0.15× | **1.61×** |
| 1024 | 2.2 (0.968) | 4.1 (0.525) | 0.54× | **1.68×** |
| 2048 | 7.8 (2.189) | 4.3 (4.019) | **1.84×** | **1.63×** |
| 4096 | 8.0 (17.256) | 4.3 (31.992) | **1.85×** | 0.91× |
| 8192 | 8.0 (137.720) | 4.3 (256.967) | **1.87×** | 0.91× |
| 16384 | 8.1 (1086.300) | 4.2 (2071.565) | **1.91×** | 0.90× |
| 32768 | 8.2 (8590.120) | 4.2 (16774.963) | **1.95×** | 0.90× |

#### Ch 4 — Can the fetch itself be cheap?
TMA descriptor (CUtensorMap)

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 3 |
|---:|---:|---:|---:|---:|
| 256 | 1.5 (0.023) | 2.3 (0.015) | 0.63× | **10.56×** |
| 512 | 6.4 (0.042) | 3.7 (0.073) | **1.74×** | **11.49×** |
| 1024 | 25.5 (0.084) | 4.1 (0.525) | **6.22×** | **11.47×** |
| 2048 | 68.7 (0.250) | 4.3 (4.017) | **16.07×** | **8.76×** |
| 4096 | 71.8 (1.914) | 4.3 (31.923) | **16.68×** | **9.02×** |
| 8192 | 72.5 (15.171) | 4.3 (257.035) | **16.94×** | **9.08×** |
| 16384 | 58.5 (150.285) | 4.3 (2062.372) | **13.72×** | **7.23×** |
| 32768 | 52.0 (1354.260) | 4.2 (16746.355) | **12.37×** | **6.34×** |

#### Ch 5 — Can several fetches be in flight?
SMEM ring

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 4 |
|---:|---:|---:|---:|---:|
| 256 | 1.6 (0.021) | 2.1 (0.016) | 0.75× | 1.10× |
| 512 | 7.1 (0.038) | 3.2 (0.083) | **2.19×** | 1.12× |
| 1024 | 27.7 (0.077) | 3.6 (0.602) | **7.77×** | 1.09× |
| 2048 | 64.5 (0.266) | 3.7 (4.629) | **17.37×** | 0.94× |
| 4096 | 68.4 (2.010) | 3.8 (36.412) | **18.12×** | 0.95× |
| 8192 | 67.0 (16.406) | 3.7 (295.645) | **18.02×** | 0.92× |
| 16384 | 49.7 (176.937) | 3.7 (2363.975) | **13.36×** | 0.85× |
| 32768 | 48.4 (1452.670) | 3.7 (19247.561) | **13.25×** | 0.93× |

#### Ch 6 — Can the math stop waiting on bookkeeping?
warp specialization

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 5 |
|---:|---:|---:|---:|---:|
| 256 | 3.2 (0.010) | — | — | **2.02×** |
| 512 | 16.0 (0.017) | — | — | **2.24×** |
| 1024 | 57.9 (0.037) | — | — | **2.09×** |
| 2048 | 80.3 (0.214) | — | — | 1.25× |
| 4096 | 81.4 (1.688) | — | — | 1.19× |
| 8192 | 71.3 (15.420) | — | — | 1.06× |
| 16384 | 48.3 (181.954) | — | — | 0.97× |
| 32768 | 38.4 (1832.770) | — | — | 0.79× |

#### Ch 7 — Can one instruction do more math?
wgmma

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 6 |
|---:|---:|---:|---:|---:|
| 256 | 2.9 (0.012) | — | — | 0.89× |
| 512 | 17.5 (0.015) | — | — | 1.10× |
| 1024 | 95.2 (0.023) | — | — | **1.65×** |
| 2048 | 119.5 (0.144) | — | — | 1.49× |
| 4096 | 153.1 (0.898) | — | — | **1.88×** |
| 8192 | 282.2 (3.896) | — | — | **3.96×** |
| 16384 | 181.7 (48.419) | — | — | **3.76×** |
| 32768 | 143.3 (491.067) | — | — | **3.73×** |

</details>

### NVIDIA H100 PCIe · tf32 · `fast`

**Rollup — Crisp TFLOPS, every chapter × every N.**

| # | technique | **N=256** | **N=512** | **N=1024** | **N=2048** | **N=4096** | **N=8192** | **N=16384** | **N=32768** |
|---|---|---|---|---|---|---|---|---|---|
| 0 | naive loops, no tensor cores | 0.5 | 0.7 | 0.7 | 0.7 | 0.7 | 0.8 | 0.8 | — |
| 1 | hand-rolled mma-accumulate-via-tile | 0.1 | 0.3 | 1.3 | 3.7 | 2.5 | 2.7 | 2.7 | — |
| 2 | matrix-multiply-tile-stride | — | — | — | — | 6.3 | 7.4 | 7.7 | 7.8 |
| 3 | cp.async | 0.1 | 0.6 | 2.1 | 4.1 | 6.5 | 7.3 | 7.3 | 7.3 |
| 4 | TMA descriptor (CUtensorMap) | 1.4 | 6.4 | 24.3 | 36.3 | 58.0 | 63.2 | 36.2 | 32.3 |
| 5 | SMEM ring | 1.6 | 7.0 | 25.9 | 39.0 | 54.0 | 62.0 | 41.3 | 31.6 |
| 6 | warp specialization | 3.2 | 15.9 | 49.3 | 54.2 | 71.2 | 68.0 | 32.0 | 30.6 |
| 7 | wgmma | 2.8 | 17.4 | 93.8 | 137.7 | 226.6 | 246.2 | 186.2 | 184.8 |

<details><summary><b>Per-chapter detail</b></summary>

#### Ch 0 — Does it run at all?
naive loops, no tensor cores

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control |
|---:|---:|---:|---:|
| 256 | 0.5 (0.064) | 0.5 (0.070) | 1.10× |
| 512 | 0.7 (0.365) | 0.7 (0.386) | 1.06× |
| 1024 | 0.7 (2.881) | 0.7 (3.028) | 1.05× |
| 2048 | 0.7 (22.954) | 0.7 (24.148) | 1.05× |
| 4096 | 0.7 (184.509) | 0.7 (193.352) | 1.05× |
| 8192 | 0.8 (1462.850) | 0.7 (1544.864) | 1.06× |
| 16384 | 0.8 (11670.100) | 0.7 (12450.993) | 1.07× |
| 32768 | — | — | — |

#### Ch 1 — Can we reach the tensor cores?
hand-rolled mma-accumulate-via-tile

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 0 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.381) | — | — | 0.17× |
| 512 | 0.3 (0.790) | — | — | 0.46× |
| 1024 | 1.3 (1.711) | — | — | **1.68×** |
| 2048 | 3.7 (4.585) | — | — | **5.01×** |
| 4096 | 2.5 (54.811) | — | — | **3.37×** |
| 8192 | 2.7 (406.379) | — | — | **3.60×** |
| 16384 | 2.7 (3297.120) | — | — | **3.54×** |
| 32768 | — | — | — | — |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 1 |
|---:|---:|---:|---:|---:|
| 256 | — | 1.9 (0.017) | — | — |
| 512 | — | 3.5 (0.078) | — | — |
| 1024 | — | 4.3 (0.500) | — | — |
| 2048 | — | 4.4 (3.904) | — | — |
| 4096 | 6.3 (21.989) | 4.4 (31.205) | 1.42× | **2.49×** |
| 8192 | 7.4 (148.308) | 4.4 (249.151) | **1.68×** | **2.74×** |
| 16384 | 7.7 (1137.050) | 4.4 (1992.237) | **1.75×** | **2.90×** |
| 32768 | 7.8 (9078.410) | 4.4 (15934.505) | **1.76×** | — |

#### Ch 3 — Can the fetch overlap the math?
cp.async

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 2 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.247) | 1.7 (0.020) | 0.08× | **1.54×** |
| 512 | 0.6 (0.488) | 3.2 (0.084) | 0.17× | **1.62×** |
| 1024 | 2.1 (0.999) | 3.6 (0.600) | 0.60× | **1.71×** |
| 2048 | 4.1 (4.188) | 3.7 (4.705) | 1.12× | 1.09× |
| 4096 | 6.5 (21.203) | 3.7 (37.559) | **1.77×** | 1.04× |
| 8192 | 7.3 (150.634) | 3.7 (299.983) | **1.99×** | 0.98× |
| 16384 | 7.3 (1205.240) | 3.7 (2397.468) | **1.99×** | 0.94× |
| 32768 | 7.3 (9698.060) | — | — | 0.94× |

#### Ch 4 — Can the fetch itself be cheap?
TMA descriptor (CUtensorMap)

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 3 |
|---:|---:|---:|---:|---:|
| 256 | 1.4 (0.023) | 1.6 (0.020) | 0.88× | **10.66×** |
| 512 | 6.4 (0.042) | 3.1 (0.085) | **2.03×** | **11.60×** |
| 1024 | 24.3 (0.088) | 3.6 (0.601) | **6.81×** | **11.32×** |
| 2048 | 36.3 (0.473) | 3.6 (4.707) | **9.96×** | **8.86×** |
| 4096 | 58.0 (2.368) | 3.7 (37.616) | **15.88×** | **8.95×** |
| 8192 | 63.2 (17.403) | 3.7 (300.194) | **17.25×** | **8.66×** |
| 16384 | 36.2 (243.183) | 3.7 (2398.900) | **9.86×** | **4.96×** |
| 32768 | 32.3 (2178.700) | 3.7 (19181.197) | **8.80×** | **4.45×** |

#### Ch 5 — Can several fetches be in flight?
SMEM ring

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 4 |
|---:|---:|---:|---:|---:|
| 256 | 1.6 (0.021) | 1.5 (0.023) | 1.08× | 1.09× |
| 512 | 7.0 (0.038) | 2.8 (0.095) | **2.49×** | 1.10× |
| 1024 | 25.9 (0.083) | 3.1 (0.686) | **8.25×** | 1.06× |
| 2048 | 39.0 (0.441) | 3.2 (5.380) | **12.21×** | 1.07× |
| 4096 | 54.0 (2.545) | 3.2 (42.445) | **16.68×** | 0.93× |
| 8192 | 62.0 (17.724) | 3.2 (339.187) | **19.14×** | 0.98× |
| 16384 | 41.3 (212.949) | 3.2 (2735.030) | **12.84×** | 1.14× |
| 32768 | 31.6 (2228.450) | — | — | 0.98× |

#### Ch 6 — Can the math stop waiting on bookkeeping?
warp specialization

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 5 |
|---:|---:|---:|---:|---:|
| 256 | 3.2 (0.010) | — | — | **2.04×** |
| 512 | 15.9 (0.017) | — | — | **2.26×** |
| 1024 | 49.3 (0.044) | — | — | **1.91×** |
| 2048 | 54.2 (0.317) | — | — | 1.39× |
| 4096 | 71.2 (1.932) | — | — | 1.32× |
| 8192 | 68.0 (16.180) | — | — | 1.10× |
| 16384 | 32.0 (275.061) | — | — | 0.77× |
| 32768 | 30.6 (2301.440) | — | — | 0.97× |

#### Ch 7 — Can one instruction do more math?
wgmma

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 6 |
|---:|---:|---:|---:|---:|
| 256 | 2.8 (0.012) | — | — | 0.88× |
| 512 | 17.4 (0.015) | — | — | 1.09× |
| 1024 | 93.8 (0.023) | — | — | **1.90×** |
| 2048 | 137.7 (0.125) | — | — | **2.54×** |
| 4096 | 226.6 (0.607) | — | — | **3.18×** |
| 8192 | 246.2 (4.466) | — | — | **3.62×** |
| 16384 | 186.2 (47.242) | — | — | **5.82×** |
| 32768 | 184.8 (380.769) | — | — | **6.04×** |

</details>

## § 1.5 — MMA Techniques (16-bit)

*Does the 32-bit ladder still rank the same way at bf16?*

**Contenders: Crisp only.** The column carrying the story is **vs previous chapter**. A rung with no 16-bit kernel shows `—`.

### Intel BMG · bf16 · `fast`

**Rollup — Crisp TFLOPS, every 16-bit chapter × every N.**

| # | technique | **N=256** | **N=512** | **N=1024** | **N=2048** | **N=4096** | **N=8192** | **N=16384** |
|---|---|---|---|---|---|---|---|---|
| 0 | naive loops, no XMX | 0.1 | 0.2 | 0.2 | 0.1 | 0.1 | 0.1 | — |
| 1 | hand-rolled XMX coop-matrix | 0.2 | 0.8 | 2.4 | 2.5 | 2.2 | 1.9 | — |
| 2 | matrix-multiply-tile-stride | 0.2 | 0.8 | 2.4 | 2.5 | 2.2 | 1.9 | — |
| 3 | OpGroupAsyncCopy | 0.0 | 0.0 | 0.0 | 0.0 | 0.3 | 2.2 | — |
| 4 | register-resident load (global→GRF) | 4.7 | 20.5 | 47.4 | 36.3 | 26.5 | 26.1 | — |
| 5 | register ring + prefetch | 5.3 | 15.5 | 39.3 | 49.0 | 30.5 | 22.7 | — |
| 6 | blocked — 3 known reasons | — | — | — | — | — | — | — |
| 7 | GRF-bounded tile sweep | — | — | — | — | — | — | — |

**Fastest rung per size** — N=256: **ch 5** (5.3) · N=512: **ch 4** (20.5) · N=1024: **ch 4** (47.4) · N=2048: **ch 5** (49.0) · N=4096: **ch 5** (30.5) · N=8192: **ch 4** (26.1)

<details><summary><b>Per-chapter detail (16-bit)</b></summary>

#### Ch 0 — Does it run at all?
naive loops, no XMX

| N | Crisp bf16 TFLOPS |
|---:|---:|
| 256 | 0.1 |
| 512 | 0.2 |
| 1024 | 0.2 |
| 2048 | 0.1 |
| 4096 | 0.1 |
| 8192 | 0.1 |
| 16384 | — |

#### Ch 1 — Can we reach the tensor cores?
hand-rolled XMX coop-matrix

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 0.2 | 1.48× |
| 512 | 0.8 | **4.47×** |
| 1024 | 2.4 | **15.73×** |
| 2048 | 2.5 | **16.85×** |
| 4096 | 2.2 | **14.93×** |
| 8192 | 1.9 | **14.66×** |
| 16384 | — | — |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 0.2 | 1.00× |
| 512 | 0.8 | 1.00× |
| 1024 | 2.4 | 1.00× |
| 2048 | 2.5 | 1.00× |
| 4096 | 2.2 | 1.00× |
| 8192 | 1.9 | 1.01× |
| 16384 | — | — |

#### Ch 3 — Can the fetch overlap the math?
OpGroupAsyncCopy

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 0.0 | 0.01× |
| 512 | 0.0 | 0.00× |
| 1024 | 0.0 | 0.00× |
| 2048 | 0.0 | 0.00× |
| 4096 | 0.3 | 0.13× |
| 8192 | 2.2 | 1.16× |
| 16384 | — | — |

#### Ch 4 — Can the fetch itself be cheap?
register-resident load (global→GRF)

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 4.7 | **1480.75×** |
| 512 | 20.5 | **6466.55×** |
| 1024 | 47.4 | **14929.07×** |
| 2048 | 36.3 | **11464.85×** |
| 4096 | 26.5 | **96.60×** |
| 8192 | 26.1 | **11.86×** |
| 16384 | — | — |

#### Ch 5 — Can several fetches be in flight?
register ring + prefetch

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 5.3 | 1.13× |
| 512 | 15.5 | 0.76× |
| 1024 | 39.3 | 0.83× |
| 2048 | 49.0 | 1.35× |
| 4096 | 30.5 | 1.15× |
| 8192 | 22.7 | 0.87× |
| 16384 | — | — |

</details>

### NVIDIA H100 NVL · bf16 · `fast`

**Rollup — Crisp TFLOPS, every 16-bit chapter × every N.**

| # | technique | **N=256** | **N=512** | **N=1024** | **N=2048** | **N=4096** | **N=8192** | **N=16384** |
|---|---|---|---|---|---|---|---|---|
| 0 | naive loops, no tensor cores | — | — | — | — | — | — | — |
| 1 | hand-rolled mma-accumulate-via-tile | 0.1 | — | 2.1 | 5.5 | 5.8 | — | — |
| 2 | matrix-multiply-tile-stride | 0.1 | — | 2.3 | 7.3 | 7.2 | — | — |
| 3 | cp.async | — | — | — | — | — | — | — |
| 4 | TMA descriptor (CUtensorMap) | 1.7 | — | 31.7 | 59.7 | 92.5 | — | — |
| 5 | SMEM ring | 1.7 | — | 29.4 | 41.6 | 64.2 | — | — |
| 6 | warp specialization | 2.2 | — | 29.6 | 51.0 | 65.9 | — | — |
| 7 | wgmma | — | — | — | — | — | — | — |

**Fastest rung per size** — N=256: **ch 6** (2.2) · N=1024: **ch 4** (31.7) · N=2048: **ch 4** (59.7) · N=4096: **ch 4** (92.5)

<details><summary><b>Per-chapter detail (16-bit)</b></summary>

#### Ch 1 — Can we reach the tensor cores?
hand-rolled mma-accumulate-via-tile

| N | Crisp bf16 TFLOPS |
|---:|---:|
| 256 | 0.1 |
| 512 | — |
| 1024 | 2.1 |
| 2048 | 5.5 |
| 4096 | 5.8 |
| 8192 | — |
| 16384 | — |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 0.1 | 1.04× |
| 512 | — | — |
| 1024 | 2.3 | 1.11× |
| 2048 | 7.3 | 1.34× |
| 4096 | 7.2 | 1.24× |
| 8192 | — | — |
| 16384 | — | — |

#### Ch 4 — Can the fetch itself be cheap?
TMA descriptor (CUtensorMap)

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 1.7 | **11.56×** |
| 512 | — | — |
| 1024 | 31.7 | **13.68×** |
| 2048 | 59.7 | **8.17×** |
| 4096 | 92.5 | **12.84×** |
| 8192 | — | — |
| 16384 | — | — |

#### Ch 5 — Can several fetches be in flight?
SMEM ring

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 1.7 | 1.01× |
| 512 | — | — |
| 1024 | 29.4 | 0.93× |
| 2048 | 41.6 | 0.70× |
| 4096 | 64.2 | 0.69× |
| 8192 | — | — |
| 16384 | — | — |

#### Ch 6 — Can the math stop waiting on bookkeeping?
warp specialization

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 2.2 | 1.27× |
| 512 | — | — |
| 1024 | 29.6 | 1.01× |
| 2048 | 51.0 | 1.23× |
| 4096 | 65.9 | 1.03× |
| 8192 | — | — |
| 16384 | — | — |

</details>

## § 2 — Top MMA Benchmarks

*How does Crisp actually stand?* Best mainloop against **all three contender classes**.

### Intel BMG · tf32 · `fast`

| N | Crisp | Control<br>SYCL_Apples | **Peer**<br>SYCL-TLA | Ceiling<br>oneMKL | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.4 (0.010) `chap5_multistage_ring` | 1.9 (0.017) | N/A* | 5.3 (0.006) | — | 64% |
| 512 | 10.1 (0.027) `sec2_top` | 5.7 (0.047) | N/A* | 9.8 (0.027) | — | 103% |
| 1024 | 32.1 (0.067) `sec2_top` | 11.6 (0.186) | N/A* | 12.0 (0.179) | — | **267%** |
| 2048 | 28.9 (0.595) `sec2_top` | 12.7 (1.350) | N/A* | 13.8 (1.243) | — | **209%** |
| 4096 | 21.5 (6.397) `sec2_top` | 10.3 (13.310) | N/A* | 14.3 (9.602) | — | **150%** |
| 8192 | 16.6 (66.373) `sec2_top` | 7.8 (140.230) | N/A* | 14.2 (77.560) | — | 117% |
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

Crisp is **outside-in**: the user picks the configuration, exactly as SYCL-TLA's pipeline depth is a template argument. So two Crisp columns, and the gap between them is *what tuning is worth*. **Envelope** is the best variant at each size, naming which one. **Best single** is the one fixed choice that does best across all sizes (`wg256xepf2`) — what you get without per-size tuning. 8 variants measured.

| N | Crisp BF16<br>**envelope** | Crisp BF16<br>best single (`wg256xepf2`) | Control<br>SYCL_Apples_BF16 | **Peer**<br>SYCL-TLA_BF16 | Ceiling<br>oneMKL_BF16 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.5 (0.010) `pfw1` | 2.9 | 2.2 (0.015) | 0.5 (0.073) | 9.8 (0.003) | **7.61×** | 36% |
| 512 | 18.3 (0.015) `pfw1` | 15.2 | 8.2 (0.033) | 3.5 (0.077) | 41.0 (0.007) | **5.26×** | 45% |
| 1024 | 74.3 (0.029) `wg256xe` | 73.5 | 16.5 (0.130) | 24.4 (0.088) | 75.4 (0.029) | **3.04×** | 99% |
| 2048 | 81.3 (0.211) `wg256xepf2` | 81.3 | 19.0 (0.903) | 49.3 (0.348) | 87.0 (0.198) | **1.65×** | 94% |
| 4096 | 106.9 (1.286) `wg256xepf2` | 106.9 | 18.9 (7.263) | 90.1 (1.526) | 105.1 (1.308) | 1.19× | 102% |
| 8192 | 107.2 (10.258) `wg256xepf2` | 107.2 | 16.0 (68.523) | 90.6 (12.132) | 112.8 (9.746) | 1.18× | 95% |
| 16384 | — | — | 11.0 (801.056) | — | 114.5 (76.830) | — | — |

> **⚠ SIGN FLIPS — these variants reverse with problem size.**
> Each wins somewhere and loses somewhere, both beyond the measured run-to-run
> spread, so a single fixed choice is not available and the envelope above is
> assembled from *different kernels*. Picking by one size will mislead you at another.

> | variant | wins at | loses at |
> |---|---|---|
> | `pfw1` | 256 (+5%), 512 (+13%), 2048 (+20%), 4096 (+32%) | **8192 (-11%)** |
> | `pfw2` | 2048 (+15%), 4096 (+21%) | **256 (-7%)**, **1024 (-5%)**, **8192 (-57%)** |
> | `pfw3` | 2048 (+14%), 4096 (+16%) | **256 (-7%)**, **1024 (-4%)**, **8192 (-59%)** |
> | `pfw4` | 2048 (+12%), 4096 (+10%) | **256 (-6%)**, **1024 (-5%)**, **8192 (-59%)** |
> | `wg256pf2` | 2048 (+17%), 4096 (+28%), 8192 (+33%) | **256 (-22%)**, **512 (-17%)** |
> | `wg256xe` | 1024 (+14%), 2048 (+8%), 4096 (+10%), 8192 (+13%) | **256 (-12%)**, **512 (-5%)** |
> | `wg256xepf2` | 1024 (+13%), 2048 (+37%), 4096 (+53%), 8192 (+59%) | **256 (-13%)**, **512 (-6%)** |


<details><summary><b>Compilation & Build Overhead (BF16)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 846 ms | 846 ms | 1.00× |
| **SYCL_Apples_BF16** | Control | 1.92 s | 4.24 s | **2.3× slower** |
| **SYCL-TLA_BF16** | Peer | 30.94 s | 59.03 s | **36.6× slower** |
| **oneMKL_BF16** | Ceiling | *precompiled* | 7.33 s | — |

</details>

### Intel BMG · fp16 · `fast` *(Native 270+ TFLOPS Matrix Engines)*

Crisp is **outside-in**: the user picks the configuration, exactly as SYCL-TLA's pipeline depth is a template argument. So two Crisp columns, and the gap between them is *what tuning is worth*. **Envelope** is the best variant at each size, naming which one. **Best single** is the one fixed choice that does best across all sizes (`wg256xepf2`) — what you get without per-size tuning. 11 variants measured.

| N | Crisp FP16<br>**envelope** | Crisp FP16<br>best single (`wg256xepf2`) | Control<br>SYCL_Apples_FP16 | **Peer**<br>SYCL-TLA_FP16 | Ceiling<br>oneMKL_FP16 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.6 (0.009) `pfw2` | 2.9 | 2.2 (0.015) | 0.5 (0.073) | 9.8 (0.003) | **7.79×** | 37% |
| 512 | 18.7 (0.014) `pfw2` | 15.3 | 8.2 (0.033) | 2.7 (0.100) | 41.0 (0.007) | **6.97×** | 46% |
| 1024 | 73.7 (0.029) `wg256xepf2` | 73.7 | 16.5 (0.130) | 24.6 (0.087) | 75.1 (0.029) | **3.00×** | 98% |
| 2048 | 79.8 (0.215) `wg256xepf2` | 79.8 | 18.9 (0.908) | 51.0 (0.337) | 88.9 (0.193) | **1.57×** | 90% |
| 4096 | 107.2 (1.282) `wg256xepf2` | 107.2 | 18.8 (7.310) | 85.9 (1.600) | 110.7 (1.242) | 1.25× | 97% |
| 8192 | 111.0 (9.907) `wg256xepf2` | 111.0 | 16.1 (68.463) | 90.5 (12.149) | 111.4 (9.866) | 1.23× | 100% |
| 16384 | — | — | 11.0 (801.185) | — | 111.1 (79.180) | — | — |

> **⚠ SIGN FLIPS — these variants reverse with problem size.**
> Each wins somewhere and loses somewhere, both beyond the measured run-to-run
> spread, so a single fixed choice is not available and the envelope above is
> assembled from *different kernels*. Picking by one size will mislead you at another.

> | variant | wins at | loses at |
> |---|---|---|
> | `pfw1` | 256 (+7%), 512 (+14%), 2048 (+22%), 4096 (+32%) | **8192 (-13%)** |
> | `pfw2` | 256 (+9%), 512 (+15%), 2048 (+22%), 4096 (+31%) | **8192 (-10%)** |
> | `pfw3` | 256 (+8%), 512 (+14%), 2048 (+16%), 4096 (+27%) | **8192 (-10%)** |
> | `pfw4` | 256 (+8%), 512 (+12%), 2048 (+17%), 4096 (+25%) | **8192 (-3%)** |
> | `wg256pf1` | 2048 (+21%), 4096 (+30%), 8192 (+37%) | **256 (-22%)**, **512 (-17%)** |
> | `wg256pf2` | 2048 (+19%), 4096 (+27%), 8192 (+35%) | **256 (-22%)**, **512 (-17%)** |
> | `wg256pf2cc` | 2048 (+20%), 4096 (+27%), 8192 (+34%) | **256 (-20%)**, **512 (-17%)** |
> | `wg256xe` | 1024 (+12%), 2048 (+12%), 4096 (+13%), 8192 (+15%) | **256 (-10%)**, **512 (-4%)** |
> | `wg256xepf2` | 1024 (+14%), 2048 (+38%), 4096 (+53%), 8192 (+62%) | **256 (-13%)**, **512 (-6%)** |


<details><summary><b>Compilation & Build Overhead (FP16)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 802 ms | 802 ms | 1.00× |
| **SYCL_Apples_FP16** | Control | 1.88 s | 4.13 s | **2.3× slower** |
| **SYCL-TLA_FP16** | Peer | 28.88 s | 57.20 s | **36.0× slower** |
| **oneMKL_FP16** | Ceiling | *precompiled* | 6.52 s | — |

</details>

### NVIDIA H100 NVL · tf32 · `fast`

| N | Crisp | Control<br>CUDA_Apples | **Peer**<br>CUTLASS | Ceiling<br>cuBLAS | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.2 (0.010) `chap6_warp_specialization` | 2.1 (0.016) | — | 5.4 (0.006) | — | 60% |
| 512 | 17.6 (0.015) `sec2_top` | 3.2 (0.083) | — | 30.7 (0.009) | — | 57% |
| 1024 | 95.2 (0.023) `chap7_wgmma` | 3.6 (0.602) | — | 141.3 (0.015) | — | 67% |
| 2048 | 256.3 (0.067) `sec2_top` | 3.7 (4.629) | — | 326.6 (0.053) | — | 78% |
| 4096 | 292.5 (0.470) `sec2_top` | 3.8 (36.412) | — | 386.3 (0.356) | — | 76% |
| 8192 | 282.2 (3.896) `chap7_wgmma` | 3.7 (295.645) | — | 408.3 (2.693) | — | 69% |
| 16384 | 181.7 (48.419) `chap7_wgmma` | 3.7 (2363.975) | — | 282.7 (31.112) | — | 64% |
| 32768 | 143.3 (491.067) `chap7_wgmma` | 3.7 (19247.561) | — | 308.6 (227.998) | — | 46% |

<details><summary><b>Compilation & Build Overhead</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 316 ms | 316 ms | 1.00× |
| **CUDA_Apples** | Control | 741 ms | 2.01 s | **2.3× slower** |
| **CUTLASS** | Peer | 445 ms | 1.86 s | **1.4× slower** |
| **cuBLAS** | Ceiling | *precompiled* | 1.05 s | — |

</details>

### NVIDIA H100 NVL · bf16 · `fast` *(Native 270+ TFLOPS Matrix Engines)*

| N | Crisp BF16 | Control<br>CUDA_Apples_BF16 | **Peer**<br>CUTLASS_BF16 | Ceiling<br>cuBLAS_BF16 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 1024 | 2.3 (0.917) | 3.8 (0.568) | 122.5 (0.018) `64x128x64` | 108.4 (0.020) | 0.02× | 2% |
| 2048 | 7.4 (2.322) | 4.0 (4.328) | 375.7 (0.046) `128x256x64` | 447.4 (0.038) | 0.02× | 2% |
| 4096 | 7.3 (18.803) | 4.0 (34.179) | 538.8 (0.255) `128x256x64` | 666.2 (0.206) | 0.01× | 1% |

<details><summary><b>Compilation & Build Overhead (BF16)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 281 ms | 281 ms | 1.00× |
| **CUDA_Apples_BF16** | Control | 829 ms | 2.37 s | **3.0× slower** |
| **CUTLASS_BF16** | Peer | 11.59 s | 26.55 s | **41.3× slower** |
| **cuBLAS_BF16** | Ceiling | *precompiled* | 1.57 s | — |

</details>

### NVIDIA H100 NVL · fp16 · `fast` *(Native 270+ TFLOPS Matrix Engines)*

| N | Crisp FP16 | Control<br>CUDA_Apples_FP16 | **Peer**<br>CUTLASS_FP16 | Ceiling<br>cuBLAS_FP16 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 0.0 (2.803) | — | — | — | — | — |
| 512 | 0.1 (3.023) | — | — | — | — | — |
| 1024 | 2.3 (0.923) | 3.8 (0.563) | 126.6 (0.017) `64x128x64` | 147.2 (0.015) | 0.02× | 2% |
| 2048 | 7.3 (2.352) | 4.0 (4.298) | 376.5 (0.046) `128x256x64` | 448.1 (0.038) | 0.02× | 2% |
| 4096 | 7.2 (19.062) | 4.0 (33.954) | 546.5 (0.251) `128x256x64` | 708.4 (0.194) | 0.01× | 1% |
| 8192 | 3.2 (341.099) | — | — | — | — | — |
| 16384 | 7.1 (1235.380) | — | — | — | — | — |

<details><summary><b>Compilation & Build Overhead (FP16)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 278 ms | 278 ms | 1.00× |
| **CUDA_Apples_FP16** | Control | 810 ms | 2.37 s | **2.9× slower** |
| **CUTLASS_FP16** | Peer | 11.70 s | 26.32 s | **42.1× slower** |
| **cuBLAS_FP16** | Ceiling | *precompiled* | 1.57 s | — |

</details>

### NVIDIA H100 PCIe · tf32 · `fast`

| N | Crisp | Control<br>CUDA_Apples | **Peer**<br>CUTLASS | Ceiling<br>cuBLAS | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.2 (0.010) `chap6_warp_specialization` | 1.5 (0.023) | — | 3.5 (0.010) | — | 92% |
| 512 | 17.4 (0.015) `sec2_top` | 2.8 (0.095) | — | 27.6 (0.010) | — | 63% |
| 1024 | 93.8 (0.023) `chap7_wgmma` | 3.1 (0.684) | — | 107.9 (0.020) | — | 87% |
| 2048 | 137.7 (0.125) `chap7_wgmma` | 3.2 (5.380) | — | 200.1 (0.086) | — | 69% |
| 4096 | 227.4 (0.604) `sec2_top` | 3.2 (42.445) | — | 304.8 (0.451) | — | 75% |
| 8192 | 246.2 (4.466) `chap7_wgmma` | 3.2 (339.187) | — | 353.7 (3.109) | — | 70% |
| 16384 | 186.4 (47.198) `sec2_top` | 3.2 (2711.815) | — | 206.7 (42.546) | — | 90% |
| 32768 | 185.1 (380.119) `sec2_top` | — | — | 169.8 (414.369) | — | 109% |

<details><summary><b>Compilation & Build Overhead</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 690 ms | 690 ms | 1.00× |
| **cuBLAS** | Ceiling | *precompiled* | 2.19 s | — |

</details>

### NVIDIA H100 PCIe · bf16 · `fast` *(Native 270+ TFLOPS Matrix Engines)*

| N | Crisp BF16 | Control<br>CUDA_Apples_BF16 | **Peer**<br>CUTLASS_BF16 | Ceiling<br>cuBLAS_BF16 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | — | 1.5 (0.023) | — | 2.4 (0.014) | — | — |
| 512 | — | 2.9 (0.093) | — | 17.5 (0.015) | — | — |
| 1024 | — | 3.3 (0.651) | — | 68.5 (0.031) | — | — |
| 2048 | — | 3.4 (5.025) | — | 277.0 (0.062) | — | — |
| 4096 | — | 3.5 (39.827) | — | 534.7 (0.257) | — | — |
| 8192 | — | 3.5 (318.332) | — | 679.3 (1.619) | — | — |
| 16384 | — | 3.4 (2555.382) | — | 666.5 (13.197) | — | — |
| 32768 | — | — | — | 643.0 (109.434) | — | — |

<details><summary><b>Compilation & Build Overhead (BF16)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **CUDA_Apples_BF16** | Control | 1.74 s | 5.23 s | — |
| **cuBLAS_BF16** | Ceiling | *precompiled* | 3.36 s | — |

</details>

### NVIDIA H100 PCIe · fp16 · `fast` *(Native 270+ TFLOPS Matrix Engines)*

| N | Crisp FP16 | Control<br>CUDA_Apples_FP16 | **Peer**<br>CUTLASS_FP16 | Ceiling<br>cuBLAS_FP16 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | — | 1.5 (0.022) | — | 2.5 (0.014) | — | — |
| 512 | — | 2.9 (0.092) | — | 17.0 (0.016) | — | — |
| 1024 | — | 3.3 (0.647) | — | 69.5 (0.031) | — | — |
| 2048 | — | 3.4 (5.028) | — | 270.5 (0.064) | — | — |
| 4096 | — | 3.4 (39.901) | — | 498.4 (0.276) | — | — |
| 8192 | — | 3.4 (319.188) | — | 678.6 (1.620) | — | — |
| 16384 | — | 3.4 (2551.413) | — | 597.8 (14.715) | — | — |
| 32768 | — | — | — | 434.2 (162.083) | — | — |

<details><summary><b>Compilation & Build Overhead (FP16)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **CUDA_Apples_FP16** | Control | 1.57 s | 4.70 s | — |
| **cuBLAS_FP16** | Ceiling | *precompiled* | 3.40 s | — |

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
| bare (no ring, no prefetch) | 3.7→4.6 (**+24.3%**) | 16.5→20.0 (**+20.9%**) | 56.9→55.4 (−2.7%) | 55.3→55.4 (+0.1%) | 48.0→50.4 (**+5.0%**) | 47.0→55.7 (**+18.4%**) |
| tuned (ring 2, prefetch 2) | 3.9→5.1 (**+31.7%**) | 16.9→22.1 (**+30.8%**) | 48.7→48.5 (−0.5%) | 53.3→60.7 (**+13.8%**) | 48.4→53.0 (**+9.4%**) | 37.0→35.6 (−3.7%) |

Positive means `:xe-native` is faster. It wins bare and loses tuned: the lowering is better in isolation and does **not** compose with the register-tile ring. See `docs/topology.md`, `mma-lowering`.

## § 1b — The Technique Ladder in 16-bit (Intel) · Intel BMG

*The same chapters as section 1, in bfloat16. Each kernel is its tf32 twin with two things changed: the operand element type, and the K step 8 → 16 (the native XMX shape for 16-bit operands is (8 16 16), not (8 16 8)). The C accumulator stays f32 in both.*

Cells read **bf16 TFLOPS (× vs the same chapter in tf32)**. The 32-bit baseline is **tf32 on XMX**, not fp32 on the vector engines — the BMG shape ladder is (8 16 8) tf32, (8 16 16) bf16, (8 16 32) int8, i.e. same M×N with K doubling per step. No Control/Peer/Ceiling columns: the chapter SYCL controls are tf32 only, so this is a Crisp-vs-Crisp ladder.

| chapter | N=256 | N=512 | N=1024 | N=2048 | N=4096 | N=8192 |
|---|---:|---:|---:|---:|---:|---:|
| Ch 0 naive (no XMX) | 0.1 (1.01×) | 0.2 (1.18×) | 0.2 (0.99×) | 0.1 (1.06×) | 0.1 (1.18×) | 0.1 (**1.85×**) |
| Ch 1 hand-rolled MMA | 0.2 (1.76×) | 0.8 (1.78×) | 2.4 (1.45×) | 2.5 (1.45×) | 2.2 (1.19×) | 1.9 (1.14×) |
| Ch 2 tiling macro | 0.2 (tf32 n/a) | 0.8 (tf32 n/a) | 2.4 (tf32 n/a) | 2.5 (tf32 n/a) | 2.2 (tf32 n/a) | 1.9 (tf32 n/a) |
| Ch 3 async staging | 0.0 (0.04×) | 0.0 (0.01×) | 0.0 (0.00×) | 0.0 (0.00×) | 0.3 (0.37×) | 2.2 (tf32 n/a) |
| Ch 4 register-resident | 4.7 (1.61×) | 20.5 (1.71×) | 47.4 (**1.85×**) | 36.3 (**2.31×**) | 26.5 (**1.99×**) | 26.1 (**1.95×**) |
| Ch 5 ring + prefetch | 5.3 (1.56×) | 15.5 (1.55×) | 39.3 (1.72×) | 49.0 (1.79×) | 30.5 (**1.98×**) | 22.7 (**2.00×**) |

## § 1b — The Technique Ladder in 16-bit (Intel) · NVIDIA H100 NVL

*The same chapters as section 1, in bfloat16. Each kernel is its tf32 twin with two things changed: the operand element type, and the K step 8 → 16 (the native XMX shape for 16-bit operands is (8 16 16), not (8 16 8)). The C accumulator stays f32 in both.*

Cells read **bf16 TFLOPS (× vs the same chapter in tf32)**. The 32-bit baseline is **tf32 on XMX**, not fp32 on the vector engines — the BMG shape ladder is (8 16 8) tf32, (8 16 16) bf16, (8 16 32) int8, i.e. same M×N with K doubling per step. No Control/Peer/Ceiling columns: the chapter SYCL controls are tf32 only, so this is a Crisp-vs-Crisp ladder.

| chapter | N=256 | N=1024 | N=2048 | N=4096 |
|---|---:|---:|---:|---:|
| Ch 1 hand-rolled MMA | 0.1 (1.57×) | 2.1 (1.59×) | 5.5 (1.48×) | 5.8 (**1.97×**) |
| Ch 2 tiling macro | 0.1 (tf32 n/a) | 2.3 (tf32 n/a) | 7.3 (tf32 n/a) | 7.2 (0.83×) |
| Ch 4 register-resident | 1.7 (1.16×) | 31.7 (1.25×) | 59.7 (0.87×) | 92.5 (1.29×) |
| Ch 5 ring + prefetch | 1.7 (1.06×) | 29.4 (1.06×) | 41.6 (0.64×) | 64.2 (0.94×) |

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
| 512 | 9.5 (0.028) | N/A* | 9.8 (0.027) | 8.7 (0.031) | — | 97% |
| 1024 | 20.9 (0.103) | N/A* | 13.3 (0.161) | 11.3 (0.189) | — | **157%** |
| 2048 | 23.7 (0.726) | N/A* | 14.1 (1.223) | 13.2 (1.300) | — | **168%** |
| 4096 | 16.2 (8.465) | N/A* | 14.3 (9.584) | 13.9 (9.895) | — | 113% |
| 8192 | 11.8 (92.903) | N/A* | 14.5 (76.082) | 13.9 (78.847) | — | 82% |
| 16384 | 10.3 (849.994) | N/A* | 14.5 (608.340) | 14.3 (617.230) | — | 72% |

> *\*Note: SYCL-TLA only implements BF16/FP16/FP8 on Xe2.*


<details><summary><b>Compilation & Build Overhead (Fused ReLU)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 787 ms | 787 ms | 1.00× |
| **oneDNN Fused** | Ceiling | *precompiled* | 5.53 s | — |

</details>

#### Ch 2 — Custom Epilogue (Arbitrary User Function)

> *Ceilings (oneDNN / cuBLASLt) cannot fuse arbitrary user functions — forced to pay 2nd kernel + HBM round-trip.*

| N | Crisp Fused | **Peer**<br>SYCL-TLA Fused | Ceiling (2nd Kernel)<br>oneDNN + Custom | vs Peer | **vs Ceiling (2nd Kernel)** |
|---:|---:|---:|---:|---:|---:|
| 256 | 3.1 (0.011) | N/A* | 3.9 (0.009) | — | **81%** |
| 512 | 9.5 (0.028) | N/A* | 8.7 (0.031) | — | **109%** |
| 1024 | 20.7 (0.104) | N/A* | 11.4 (0.188) | — | ****182%**** |
| 2048 | 23.8 (0.723) | N/A* | 13.2 (1.299) | — | ****180%**** |
| 4096 | 16.2 (8.498) | N/A* | 13.9 (9.897) | — | **116%** |
| 8192 | 11.8 (93.316) | N/A* | 13.9 (78.833) | — | **84%** |
| 16384 | 10.0 (876.373) | N/A* | 14.3 (617.241) | — | **70%** |

<details><summary><b>Compilation & Build Overhead (Fused Custom)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 752 ms | 752 ms | 1.00× |
| **oneDNN + Custom** | Ceiling | *precompiled* | 6.68 s | — |

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

### NVIDIA H100 PCIe · tf32 · `fast`

#### Ch 1 — Standard Epilogue (ReLU)

| N | Crisp Fused | **Peer**<br>CUTLASS Fused | **Ceiling**<br>cuBLASLt Fused | Baseline+2nd Kernel<br>cuBLAS + ReLU | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 2.8 (0.012) | — | 2.3 (0.015) | 1.9 (0.018) | — | 121% |
| 512 | 17.4 (0.015) | — | 16.4 (0.016) | 12.9 (0.021) | — | 106% |
| 1024 | 93.7 (0.023) | — | 62.1 (0.035) | 51.1 (0.042) | — | **151%** |
| 2048 | 136.6 (0.126) | — | 162.6 (0.106) | 138.2 (0.124) | — | 84% |
| 4096 | 227.6 (0.604) | — | 291.0 (0.472) | 248.5 (0.553) | — | 78% |
| 8192 | 244.6 (4.495) | — | 350.7 (3.135) | 319.5 (3.441) | — | 70% |
| 16384 | 185.8 (47.338) | — | 209.2 (42.041) | 201.3 (43.706) | — | 89% |
| 32768 | 185.3 (379.851) | — | 171.3 (410.838) | 168.1 (418.609) | — | 108% |

<details><summary><b>Compilation & Build Overhead (Fused ReLU)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 891 ms | 891 ms | 1.00× |
| **cuBLASLt Fused** | Ceiling | *precompiled* | 3.13 s | — |

</details>

#### Ch 2 — Custom Epilogue (Arbitrary User Function)

> *Ceilings (oneDNN / cuBLASLt) cannot fuse arbitrary user functions — forced to pay 2nd kernel + HBM round-trip.*

| N | Crisp Fused | **Peer**<br>CUTLASS Fused | Ceiling (2nd Kernel)<br>cuBLASLt + Custom | vs Peer | **vs Ceiling (2nd Kernel)** |
|---:|---:|---:|---:|---:|---:|
| 256 | 2.8 (0.012) | — | 2.2 (0.015) | — | **125%** |
| 512 | 17.2 (0.016) | — | 15.0 (0.018) | — | **115%** |
| 1024 | 92.8 (0.023) | — | 54.1 (0.040) | — | ****171%**** |
| 2048 | 135.1 (0.127) | — | 143.1 (0.120) | — | **94%** |
| 4096 | 225.6 (0.609) | — | 250.0 (0.550) | — | **90%** |
| 8192 | 245.1 (4.486) | — | 320.1 (3.435) | — | **77%** |
| 16384 | 186.0 (47.302) | — | 202.6 (43.420) | — | **92%** |
| 32768 | 184.4 (381.623) | — | 168.6 (417.324) | — | **109%** |

<details><summary><b>Compilation & Build Overhead (Fused Custom)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 1.01 s | 1.01 s | 1.00× |
| **cuBLASLt + Custom** | Ceiling | *precompiled* | 3.25 s | — |

</details>

## § 5 — Scaling Out

| topic | status |
|---|---|
| Out of core (stream from host) | candidate for 1.0 |
| Hardware multi-tile (PVC 2T/4T) | deferred — needs `def-topology` |
| Multi-GPU | deferred — needs `def-topology` + `def-orchestration` |


# Appendix — runs excluded from canonical tables

Debug and exploratory runs are written to `benchmarks/results/scratch/`, which the report never reads into canonical tables.

*No scratch runs present.*