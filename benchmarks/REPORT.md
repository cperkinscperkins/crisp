# Crisp Benchmark Report

> Generated from verified test sweeps in `benchmarks/results/`.

| device | data captured | source | hardware profile |
|---|---|---|---|
| Intel(R) Graphics [0xe20b] | 2026-09-12 | Crisp `375ffd14` (docker) | `bmg` (validated) |
| NVIDIA H100 80GB HBM3 | 2026-09-13 | Crisp `cc116e8c` (runpod) | `h100-80gb-hbm3` (queried*) |

> \* **queried / supplied**: the profile's QUERIED keys were read off the device, but its MEASURED keys (`:tile-visit-strip-width` above all) were never swept for this part and are absent, which selects safe defaults rather than tuned ones. Such a row is honest about the hardware it ran on and fair to compare *within* the device; it may understate Crisp against a row whose profile was fully tuned. A **NONE** row was compiled with no profile at all and is not comparable to published figures.

---

# Suite: matmul

Row variable: **N**, the square matrix dimension. Matmul cost grows as N³ while memory grows as N².

| bucket | N | what it exercises |
|---|---|---|
| small | 512, 1024 | launch overhead and occupancy dominate |
| medium | 2048, 4096 | the machine saturates (~0.97 residency waves) |
| large | 8192, 16384 | steady state |
| xl | 32768, 40960 | device permitting |
| devmax | the largest N this card holds | per-ladder: tf32/bf16/f64 differ |

## § 1 — MMA Techniques

*How do you make a matmul fast, one step at a time?*

**Contenders: Control only.** The column carrying the story is **vs previous chapter**.

### Intel(R) Graphics [0xe20b] · tf32 · `fast`

**Rollup — Crisp TFLOPS, every chapter × every N.**

| # | technique | **N=256** | **N=512** | **N=1024** | **N=2048** | **N=4096** | **N=8192** | **N=16384** |
|---|---|---|---|---|---|---|---|---|
| 0 | naive loops, no XMX | 0.1 | 0.2 | 0.2 | 0.1 | 0.1 | 0.1 | — |
| 1 | hand-rolled XMX coop-matrix | 0.1 | 0.5 | 1.7 | 1.7 | 1.7 | 1.6 | 1.5 |
| 2 | matrix-multiply-tile-stride | 0.1 | 0.5 | 1.7 | 1.7 | 1.8 | 1.7 | 1.6 |
| 3 | OpGroupAsyncCopy | 0.0 | 0.0 | 0.0 | 0.0 | — | — | — |
| 4 | register-resident load (global→GRF) | 2.9 | 12.0 | 24.0 | 16.6 | 13.5 | 11.8 | 13.2 |
| 5 | register ring + prefetch | 3.4 | 10.1 | 22.3 | 28.0 | 17.3 | 12.8 | 6.6 |
| 6 | blocked — 3 known reasons | — | — | — | — | — | — | — |
| 7 | GRF-bounded tile sweep | — | — | — | — | — | — | — |

<details><summary><b>Per-chapter detail</b></summary>

#### Ch 0 — Does it run at all?
naive loops, no XMX

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control |
|---:|---:|---:|---:|
| 256 | 0.1 (0.236) | 0.5 (0.074) | 0.31× |
| 512 | 0.2 (1.749) | 0.6 (0.449) | 0.26× |
| 1024 | 0.2 (14.032) | 0.7 (3.172) | 0.23× |
| 2048 | 0.1 (123.801) | 0.7 (25.613) | 0.21× |
| 4096 | 0.1 (1097.550) | 0.3 (525.815) | 0.48× |
| 8192 | 0.1 (15643.200) | 0.3 (4055.810) | 0.26× |
| 16384 | — | — | — |

#### Ch 1 — Can we reach the tensor cores?
hand-rolled XMX coop-matrix

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 0 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.278) | 0.2 (0.202) | 0.73× | 0.85× |
| 512 | 0.5 (0.590) | 0.5 (0.495) | 0.84× | **2.97×** |
| 1024 | 1.7 (1.295) | 1.5 (1.396) | 1.08× | **10.84×** |
| 2048 | 1.7 (10.139) | 1.8 (9.412) | 0.93× | **12.21×** |
| 4096 | 1.7 (79.276) | 2.0 (67.726) | 0.85× | **13.84×** |
| 8192 | 1.6 (681.490) | 2.2 (510.788) | 0.75× | **22.95×** |
| 16384 | 1.5 (5813.000) | — | — | — |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 1 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.278) | 1.3 (0.026) | 0.09× | 1.00× |
| 512 | 0.5 (0.590) | 1.5 (0.184) | 0.31× | 1.00× |
| 1024 | 1.7 (1.294) | 1.5 (1.405) | 1.09× | 1.00× |
| 2048 | 1.7 (10.191) | 1.4 (12.338) | 1.21× | 0.99× |
| 4096 | 1.8 (74.982) | 1.3 (104.903) | 1.40× | 1.06× |
| 8192 | 1.7 (655.255) | 1.3 (842.344) | 1.29× | 1.04× |
| 16384 | 1.6 (5597.630) | — | — | 1.04× |

#### Ch 3 — Can the fetch overlap the math?
OpGroupAsyncCopy

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 2 |
|---:|---:|---:|---:|---:|
| 256 | 0.0 (27.010) | 1.3 (0.026) | 0.00× | 0.01× |
| 512 | 0.0 (215.816) | 1.5 (0.184) | 0.00× | 0.00× |
| 1024 | 0.0 (1734.450) | 1.5 (1.399) | 0.00× | 0.00× |
| 2048 | 0.0 (14071.700) | 1.5 (11.741) | 0.00× | 0.00× |
| 4096 | — | 1.3 (104.606) | — | — |
| 8192 | — | 1.3 (840.523) | — | — |
| 16384 | — | — | — | — |

#### Ch 4 — Can the fetch itself be cheap?
register-resident load (global→GRF)

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 3 |
|---:|---:|---:|---:|---:|
| 256 | 2.9 (0.011) | 3.5 (0.010) | 0.84× | **2361.01×** |
| 512 | 12.0 (0.022) | 14.3 (0.019) | 0.84× | **9651.88×** |
| 1024 | 24.0 (0.089) | 30.6 (0.070) | 0.78× | **19392.23×** |
| 2048 | 16.6 (1.035) | 22.6 (0.761) | 0.73× | **13598.47×** |
| 4096 | 13.5 (10.218) | 21.1 (6.522) | 0.64× | **7.34×** |
| 8192 | 11.8 (93.357) | 6.7 (164.532) | **1.76×** | **7.02×** |
| 16384 | 13.2 (668.724) | 6.1 (1449.499) | **2.17×** | **8.37×** |

#### Ch 5 — Can several fetches be in flight?
register ring + prefetch

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 4 |
|---:|---:|---:|---:|---:|
| 256 | 3.4 (0.010) | 1.9 (0.017) | **1.77×** | 1.17× |
| 512 | 10.1 (0.027) | 5.7 (0.047) | **1.77×** | 0.84× |
| 1024 | 22.3 (0.096) | 11.6 (0.186) | **1.93×** | 0.93× |
| 2048 | 28.0 (0.613) | 12.6 (1.363) | **2.22×** | **1.69×** |
| 4096 | 17.3 (7.962) | 10.3 (13.408) | **1.68×** | 1.28× |
| 8192 | 12.8 (86.223) | 7.9 (138.443) | **1.61×** | 1.08× |
| 16384 | 6.6 (1332.330) | 4.9 (1811.329) | 1.36× | 0.50× |

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
| 256 | — | — | — | — |
| 512 | — | — | — | — |
| 1024 | — | — | — | — |
| 2048 | — | — | — | — |
| 4096 | — | — | — | — |
| 8192 | — | — | — | — |
| 16384 | — | — | — | — |

</details>

### NVIDIA H100 80GB HBM3 · tf32 · `fast`

**Rollup — Crisp TFLOPS, every chapter × every N.**

| # | technique | **N=256** | **N=512** | **N=1024** | **N=2048** | **N=4096** | **N=8192** | **N=16384** | **N=32768** | **N=61440** | **N=77824** |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | naive loops, no tensor cores | 0.9 | 0.9 | 0.9 | 1.0 | 1.0 | 1.0 | 1.0 | — | — | — |
| 1 | hand-rolled mma-accumulate-via-tile | 0.1 | 0.4 | 1.5 | 4.5 | 3.2 | 4.2 | 4.2 | 4.2 | — | — |
| 2 | matrix-multiply-tile-stride | 0.1 | 0.4 | 1.5 | 5.6 | 5.7 | 5.6 | 5.5 | 5.4 | — | — |
| 3 | cp.async | 0.2 | 0.6 | 2.5 | 9.0 | 9.1 | 9.2 | 9.4 | 9.5 | — | — |
| 4 | TMA descriptor (CUtensorMap) | 1.6 | 7.0 | 27.8 | 75.1 | 79.5 | 80.2 | 69.5 | 57.4 | 56.3 | — |
| 5 | SMEM ring | 1.8 | 8.1 | 31.4 | 73.4 | 77.0 | 79.6 | 82.6 | 57.0 | 50.5 | — |
| 6 | warp specialization | 3.6 | 17.9 | 64.8 | 85.0 | 88.5 | 88.2 | 54.3 | 52.0 | 48.6 | — |
| 7 | wgmma | 3.2 | 19.4 | 102.8 | 259.6 | 310.0 | 259.4 | 224.5 | 255.2 | 261.3 | — |

<details><summary><b>Per-chapter detail</b></summary>

#### Ch 0 — Does it run at all?
naive loops, no tensor cores

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control |
|---:|---:|---:|---:|
| 256 | 0.9 (0.038) | 0.8 (0.043) | 1.12× |
| 512 | 0.9 (0.288) | 0.9 (0.304) | 1.06× |
| 1024 | 0.9 (2.267) | 0.9 (2.385) | 1.05× |
| 2048 | 1.0 (17.527) | 0.9 (18.593) | 1.06× |
| 4096 | 1.0 (140.186) | 0.9 (148.231) | 1.06× |
| 8192 | 1.0 (1111.450) | 0.9 (1183.444) | 1.06× |
| 16384 | 1.0 (8886.080) | 0.9 (9463.327) | 1.06× |
| 32768 | — | — | — |
| 61440 | — | — | — |
| 77824 | — | — | — |

#### Ch 1 — Can we reach the tensor cores?
hand-rolled mma-accumulate-via-tile

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 0 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.338) | — | — | 0.11× |
| 512 | 0.4 (0.702) | — | — | 0.41× |
| 1024 | 1.5 (1.440) | — | — | **1.57×** |
| 2048 | 4.5 (3.836) | — | — | **4.57×** |
| 4096 | 3.2 (42.748) | — | — | **3.28×** |
| 8192 | 4.2 (260.446) | — | — | **4.27×** |
| 16384 | 4.2 (2081.390) | — | — | **4.27×** |
| 32768 | 4.2 (16801.600) | — | — | — |
| 61440 | — | — | — | — |
| 77824 | — | — | — | — |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 1 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.338) | 2.5 (0.013) | 0.04× | 1.00× |
| 512 | 0.4 (0.696) | 4.7 (0.057) | 0.08× | 1.01× |
| 1024 | 1.5 (1.418) | 5.5 (0.394) | 0.28× | 1.02× |
| 2048 | 5.6 (3.076) | 5.7 (3.005) | 0.98× | 1.25× |
| 4096 | 5.7 (24.266) | 5.7 (23.924) | 0.99× | **1.76×** |
| 8192 | 5.6 (196.283) | 5.8 (190.892) | 0.97× | 1.33× |
| 16384 | 5.5 (1612.640) | 5.8 (1515.353) | 0.94× | 1.29× |
| 32768 | 5.4 (12948.500) | 5.8 (12210.801) | 0.94× | 1.30× |
| 61440 | — | — | — | — |
| 77824 | — | — | — | — |

#### Ch 3 — Can the fetch overlap the math?
cp.async

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 2 |
|---:|---:|---:|---:|---:|
| 256 | 0.2 (0.219) | 2.4 (0.014) | 0.06× | **1.54×** |
| 512 | 0.6 (0.432) | 4.0 (0.066) | 0.15× | **1.61×** |
| 1024 | 2.5 (0.859) | 4.5 (0.472) | 0.55× | **1.65×** |
| 2048 | 9.0 (1.906) | 4.7 (3.621) | **1.90×** | **1.61×** |
| 4096 | 9.1 (15.156) | 4.8 (28.781) | **1.90×** | **1.60×** |
| 8192 | 9.2 (118.961) | 4.8 (227.995) | **1.92×** | **1.65×** |
| 16384 | 9.4 (938.538) | 4.8 (1836.583) | **1.96×** | **1.72×** |
| 32768 | 9.5 (7423.230) | 4.8 (14689.758) | **1.98×** | **1.74×** |
| 61440 | — | — | — | — |
| 77824 | — | — | — | — |

#### Ch 4 — Can the fetch itself be cheap?
TMA descriptor (CUtensorMap)

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 3 |
|---:|---:|---:|---:|---:|
| 256 | 1.6 (0.021) | 2.4 (0.014) | 0.68× | **10.58×** |
| 512 | 7.0 (0.038) | 4.0 (0.067) | **1.75×** | **11.32×** |
| 1024 | 27.8 (0.077) | 4.5 (0.472) | **6.12×** | **11.14×** |
| 2048 | 75.1 (0.229) | 4.7 (3.622) | **15.83×** | **8.33×** |
| 4096 | 79.5 (1.730) | 4.8 (28.784) | **16.64×** | **8.76×** |
| 8192 | 80.2 (13.704) | 4.8 (229.785) | **16.77×** | **8.68×** |
| 16384 | 69.5 (126.562) | 4.8 (1836.498) | **14.51×** | **7.42×** |
| 32768 | 57.4 (1225.710) | 4.8 (14684.799) | **11.98×** | **6.06×** |
| 61440 | 56.3 (8235.570) | — | — | — |
| 77824 | — | — | — | — |

#### Ch 5 — Can several fetches be in flight?
SMEM ring

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 4 |
|---:|---:|---:|---:|---:|
| 256 | 1.8 (0.019) | 2.2 (0.015) | 0.82× | 1.11× |
| 512 | 8.1 (0.033) | 3.6 (0.075) | **2.26×** | 1.14× |
| 1024 | 31.4 (0.068) | 4.0 (0.543) | **7.93×** | 1.13× |
| 2048 | 73.4 (0.234) | 4.1 (4.171) | **17.82×** | 0.98× |
| 4096 | 77.0 (1.784) | 4.2 (32.824) | **18.40×** | 0.97× |
| 8192 | 79.6 (13.809) | 4.2 (262.164) | **18.99×** | 0.99× |
| 16384 | 82.6 (106.464) | 4.2 (2096.016) | **19.69×** | 1.19× |
| 32768 | 57.0 (1235.200) | 4.2 (16765.449) | **13.57×** | 0.99× |
| 61440 | 50.5 (9189.640) | — | — | 0.90× |
| 77824 | — | — | — | — |

#### Ch 6 — Can the math stop waiting on bookkeeping?
warp specialization

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 5 |
|---:|---:|---:|---:|---:|
| 256 | 3.6 (0.009) | — | — | **2.03×** |
| 512 | 17.9 (0.015) | — | — | **2.23×** |
| 1024 | 64.8 (0.033) | — | — | **2.07×** |
| 2048 | 85.0 (0.202) | — | — | 1.16× |
| 4096 | 88.5 (1.553) | — | — | 1.15× |
| 8192 | 88.2 (12.469) | — | — | 1.11× |
| 16384 | 54.3 (161.881) | — | — | 0.66× |
| 32768 | 52.0 (1353.440) | — | — | 0.91× |
| 61440 | 48.6 (9541.440) | — | — | 0.96× |
| 77824 | — | — | — | — |

#### Ch 7 — Can one instruction do more math?
wgmma

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 6 |
|---:|---:|---:|---:|---:|
| 256 | 3.2 (0.011) | — | — | 0.87× |
| 512 | 19.4 (0.014) | — | — | 1.08× |
| 1024 | 102.8 (0.021) | — | — | **1.59×** |
| 2048 | 259.6 (0.066) | — | — | **3.06×** |
| 4096 | 310.0 (0.443) | — | — | **3.50×** |
| 8192 | 259.4 (4.239) | — | — | **2.94×** |
| 16384 | 224.5 (39.181) | — | — | **4.13×** |
| 32768 | 255.2 (275.765) | — | — | **4.91×** |
| 61440 | 261.3 (1775.050) | — | — | **5.38×** |
| 77824 | — | — | — | — |

</details>

## § 1.5 — MMA Techniques (16-bit)

*Does the 32-bit ladder still rank the same way at bf16?*

**Contenders: Crisp only.** The column carrying the story is **vs previous chapter**. A rung with no 16-bit kernel shows `—`.

### Intel(R) Graphics [0xe20b] · bf16 · `fast`

**Rollup — Crisp TFLOPS, every 16-bit chapter × every N.**

| # | technique | **N=256** | **N=512** | **N=1024** | **N=2048** | **N=4096** | **N=8192** | **N=16384** |
|---|---|---|---|---|---|---|---|---|
| 0 | naive loops, no XMX | 0.1 | 0.2 | 0.1 | 0.1 | 0.1 | 0.1 | — |
| 1 | hand-rolled XMX coop-matrix | 0.2 | 0.8 | 2.4 | 2.5 | 2.2 | 1.9 | 1.6 |
| 2 | matrix-multiply-tile-stride | 0.2 | 0.8 | 2.4 | 2.5 | 2.2 | 1.9 | 1.6 |
| 3 | OpGroupAsyncCopy | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | — | — |
| 4 | register-resident load (global→GRF) | 4.7 | 20.6 | 48.1 | 38.2 | 26.7 | 26.3 | 26.9 |
| 5 | register ring + prefetch | 5.3 | 15.7 | 39.6 | 49.7 | 31.4 | 22.1 | 15.0 |
| 6 | blocked — 3 known reasons | — | — | — | — | — | — | — |
| 7 | GRF-bounded tile sweep | — | — | — | — | — | — | — |

**Fastest rung per size** — N=256: **ch 5** (5.3) · N=512: **ch 4** (20.6) · N=1024: **ch 4** (48.1) · N=2048: **ch 5** (49.7) · N=4096: **ch 5** (31.4) · N=8192: **ch 4** (26.3) · N=16384: **ch 4** (26.9)

<details><summary><b>Per-chapter detail (16-bit)</b></summary>

#### Ch 0 — Does it run at all?
naive loops, no XMX

| N | Crisp bf16 TFLOPS |
|---:|---:|
| 256 | 0.1 |
| 512 | 0.2 |
| 1024 | 0.1 |
| 2048 | 0.1 |
| 4096 | 0.1 |
| 8192 | 0.1 |
| 16384 | — |

#### Ch 1 — Can we reach the tensor cores?
hand-rolled XMX coop-matrix

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 0.2 | 1.48× |
| 512 | 0.8 | **4.46×** |
| 1024 | 2.4 | **16.19×** |
| 2048 | 2.5 | **17.07×** |
| 4096 | 2.2 | **15.02×** |
| 8192 | 1.9 | **14.84×** |
| 16384 | 1.6 | — |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 0.2 | 1.00× |
| 512 | 0.8 | 1.00× |
| 1024 | 2.4 | 1.00× |
| 2048 | 2.5 | 1.00× |
| 4096 | 2.2 | 1.00× |
| 8192 | 1.9 | 1.00× |
| 16384 | 1.6 | 1.00× |

#### Ch 3 — Can the fetch overlap the math?
OpGroupAsyncCopy

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 0.0 | 0.01× |
| 512 | 0.0 | 0.00× |
| 1024 | 0.0 | 0.00× |
| 2048 | 0.0 | 0.00× |
| 4096 | 0.0 | 0.00× |
| 8192 | — | — |
| 16384 | — | — |

#### Ch 4 — Can the fetch itself be cheap?
register-resident load (global→GRF)

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 4.7 | **1477.20×** |
| 512 | 20.6 | **6516.11×** |
| 1024 | 48.1 | **15170.15×** |
| 2048 | 38.2 | **12050.38×** |
| 4096 | 26.7 | **8623.36×** |
| 8192 | 26.3 | **13.77×** |
| 16384 | 26.9 | **16.79×** |

#### Ch 5 — Can several fetches be in flight?
register ring + prefetch

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 5.3 | 1.13× |
| 512 | 15.7 | 0.76× |
| 1024 | 39.6 | 0.82× |
| 2048 | 49.7 | 1.30× |
| 4096 | 31.4 | 1.18× |
| 8192 | 22.1 | 0.84× |
| 16384 | 15.0 | 0.56× |

</details>

### NVIDIA H100 80GB HBM3 · bf16 · `fast`

**Rollup — Crisp TFLOPS, every 16-bit chapter × every N.**

| # | technique | **N=256** | **N=512** | **N=1024** | **N=2048** | **N=4096** | **N=8192** | **N=16384** | **N=32768** | **N=77824** |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | naive loops, no tensor cores | — | — | — | — | — | — | — | — | — |
| 1 | hand-rolled mma-accumulate-via-tile | 0.2 | 0.6 | 2.4 | 6.6 | 6.7 | 6.5 | 7.1 | 7.2 | — |
| 2 | matrix-multiply-tile-stride | 0.2 | 0.6 | 2.6 | 8.4 | 8.5 | 8.4 | 8.4 | 8.3 | — |
| 3 | cp.async | — | — | — | — | — | — | — | — | — |
| 4 | TMA descriptor (CUtensorMap) | 1.7 | 9.0 | 34.6 | 64.2 | 103.3 | 109.8 | 110.0 | 109.5 | — |
| 5 | SMEM ring | 1.7 | 9.2 | 32.1 | 46.8 | 73.1 | 82.9 | 86.9 | 87.5 | — |
| 6 | warp specialization | 2.1 | 11.9 | 32.2 | 58.2 | 74.6 | 79.4 | 83.3 | 83.8 | — |
| 7 | wgmma | 2.2 | 16.1 | 98.3 | 334.8 | 484.2 | 569.3 | 449.7 | 435.4 | — |

**Fastest rung per size** — N=256: **ch 7** (2.2) · N=512: **ch 7** (16.1) · N=1024: **ch 7** (98.3) · N=2048: **ch 7** (334.8) · N=4096: **ch 7** (484.2) · N=8192: **ch 7** (569.3) · N=16384: **ch 7** (449.7) · N=32768: **ch 7** (435.4)

<details><summary><b>Per-chapter detail (16-bit)</b></summary>

#### Ch 1 — Can we reach the tensor cores?
hand-rolled mma-accumulate-via-tile

| N | Crisp bf16 TFLOPS |
|---:|---:|
| 256 | 0.2 |
| 512 | 0.6 |
| 1024 | 2.4 |
| 2048 | 6.6 |
| 4096 | 6.7 |
| 8192 | 6.5 |
| 16384 | 7.1 |
| 32768 | 7.2 |
| 77824 | — |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 0.2 | 1.04× |
| 512 | 0.6 | 1.04× |
| 1024 | 2.6 | 1.10× |
| 2048 | 8.4 | 1.26× |
| 4096 | 8.5 | 1.27× |
| 8192 | 8.4 | 1.29× |
| 16384 | 8.4 | 1.18× |
| 32768 | 8.3 | 1.14× |
| 77824 | — | — |

#### Ch 4 — Can the fetch itself be cheap?
TMA descriptor (CUtensorMap)

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 1.7 | **10.46×** |
| 512 | 9.0 | **13.83×** |
| 1024 | 34.6 | **13.22×** |
| 2048 | 64.2 | **7.67×** |
| 4096 | 103.3 | **12.23×** |
| 8192 | 109.8 | **13.15×** |
| 16384 | 110.0 | **13.13×** |
| 32768 | 109.5 | **13.27×** |
| 77824 | — | — |

#### Ch 5 — Can several fetches be in flight?
SMEM ring

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 1.7 | 1.02× |
| 512 | 9.2 | 1.03× |
| 1024 | 32.1 | 0.93× |
| 2048 | 46.8 | 0.73× |
| 4096 | 73.1 | 0.71× |
| 8192 | 82.9 | 0.75× |
| 16384 | 86.9 | 0.79× |
| 32768 | 87.5 | 0.80× |
| 77824 | — | — |

#### Ch 6 — Can the math stop waiting on bookkeeping?
warp specialization

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 2.1 | 1.21× |
| 512 | 11.9 | 1.29× |
| 1024 | 32.2 | 1.00× |
| 2048 | 58.2 | 1.24× |
| 4096 | 74.6 | 1.02× |
| 8192 | 79.4 | 0.96× |
| 16384 | 83.3 | 0.96× |
| 32768 | 83.8 | 0.96× |
| 77824 | — | — |

#### Ch 7 — Can one instruction do more math?
wgmma

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 2.2 | 1.08× |
| 512 | 16.1 | 1.35× |
| 1024 | 98.3 | **3.06×** |
| 2048 | 334.8 | **5.76×** |
| 4096 | 484.2 | **6.49×** |
| 8192 | 569.3 | **7.17×** |
| 16384 | 449.7 | **5.40×** |
| 32768 | 435.4 | **5.20×** |
| 77824 | — | — |

</details>

## § 1b — The Technique Ladder in 16-bit · Intel(R) Graphics [0xe20b]

*The same chapters as section 1, in bfloat16. Each kernel is its tf32 twin with two things changed: the operand element type, and the K step 8 → 16 (the native XMX shape for 16-bit operands is (8 16 16), not (8 16 8)). The C accumulator stays f32 in both.*

Cells read **bf16 TFLOPS (× vs the same chapter in tf32)**. The 32-bit baseline is **tf32 on XMX**, not fp32 on the vector engines — the BMG shape ladder is (8 16 8) tf32, (8 16 16) bf16, (8 16 32) int8, i.e. same M×N with K doubling per step. No Control/Peer/Ceiling columns: the chapter SYCL controls are tf32 only, so this is a Crisp-vs-Crisp ladder.

| chapter | N=256 | N=512 | N=1024 | N=2048 | N=4096 | N=8192 | N=16384 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Ch 0 naive (no XMX) | 0.1 (1.01×) | 0.2 (1.18×) | 0.1 (0.97×) | 0.1 (1.05×) | 0.1 (1.17×) | 0.1 (**1.84×**) | — |
| Ch 1 hand-rolled MMA | 0.2 (1.76×) | 0.8 (1.78×) | 2.4 (1.45×) | 2.5 (1.47×) | 2.2 (1.27×) | 1.9 (1.19×) | 1.6 (1.06×) |
| Ch 2 tiling macro | 0.2 (1.76×) | 0.8 (1.78×) | 2.4 (1.45×) | 2.5 (1.48×) | 2.2 (1.20×) | 1.9 (1.14×) | 1.6 (1.02×) |
| Ch 3 async staging | 0.0 (**2.55×**) | 0.0 (**2.55×**) | 0.0 (**2.56×**) | 0.0 (**2.59×**) | 0.0 (tf32 n/a) | — | — |
| Ch 4 register-resident | 4.7 (1.59×) | 20.6 (1.72×) | 48.1 (**2.00×**) | 38.2 (**2.30×**) | 26.7 (**1.99×**) | 26.3 (**2.23×**) | 26.9 (**2.04×**) |
| Ch 5 ring + prefetch | 5.3 (1.54×) | 15.7 (1.56×) | 39.6 (1.78×) | 49.7 (1.77×) | 31.4 (**1.82×**) | 22.1 (1.74×) | 15.0 (**2.27×**) |

## § 1b — The Technique Ladder in 16-bit · NVIDIA H100 80GB HBM3

*The same chapters as section 1, in bfloat16. Each kernel is its tf32 twin with two things changed: the operand element type, and the K step 8 → 16 (the native tensor-core shape for 16-bit operands is (8 16 16), not (8 16 8)). The C accumulator stays f32 in both.*

Cells read **bf16 TFLOPS (× vs the same chapter in tf32)**. The 32-bit baseline is **tf32 on the tensor cores**, not fp32 on the vector units. No Control/Peer/Ceiling columns: the chapter controls are tf32 only, so this is a Crisp-vs-Crisp ladder. § 1.5 above carries the full 16-bit ladder for this GPU; this table adds only the tf32 ratio.

| chapter | N=256 | N=512 | N=1024 | N=2048 | N=4096 | N=8192 | N=16384 | N=32768 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Ch 1 hand-rolled MMA | 0.2 (1.57×) | 0.6 (1.63×) | 2.4 (1.59×) | 6.6 (1.48×) | 6.7 (**2.07×**) | 6.5 (1.53×) | 7.1 (1.68×) | 7.2 (1.73×) |
| Ch 2 tiling macro | 0.2 (1.63×) | 0.6 (1.68×) | 2.6 (1.73×) | 8.4 (1.50×) | 8.5 (1.49×) | 8.4 (1.49×) | 8.4 (1.54×) | 8.3 (1.52×) |
| Ch 4 register-resident | 1.7 (1.04×) | 9.0 (1.27×) | 34.6 (1.24×) | 64.2 (0.85×) | 103.3 (1.30×) | 109.8 (1.37×) | 110.0 (1.58×) | 109.5 (**1.91×**) |
| Ch 5 ring + prefetch | 1.7 (0.96×) | 9.2 (1.15×) | 32.1 (1.02×) | 46.8 (0.64×) | 73.1 (0.95×) | 82.9 (1.04×) | 86.9 (1.05×) | 87.5 (1.54×) |

## § 1c — The Technique Ladder in 64-bit · NVIDIA H100 80GB HBM3

*The same chapters at IEEE double. Cells read **fp64 TFLOPS**, and the rightmost column is each rung's ratio to the Chapter 0 vector-fp64 floor.*

**Chapter 7 is absent by hardware, not unmeasured.** wgmma covers fp16/bf16/tf32/fp8/int8; there is no fp64 warpgroup MMA in any form, so Chapter 6 is the top of this ladder.

**These rows are not comparable cell-for-cell with the tf32 ladder.** An fp64 accumulator fragment is 8×8 holding 2 doubles per lane = 4 registers, so the tf32 chapters' 64×64 tile would need 256 registers/thread — one over the architectural 255. Every 64-bit rung therefore runs at 64×32. fp64 costs 2× the registers at equal tile size, which is part of the 64-bit result rather than a tuning choice.

*Expectation under test (from § 2): the fp64 tensor core measured only 1.20–1.53× over vector fp64, while cuBLAS sits ~1.9× above the best CUTLASS DMMA config — both DMMA, so that larger gap is scheduling. If that holds, the distance on this ladder should be in chapters 2–6, not chapter 1.*

| chapter | N=256 | N=512 | N=1024 | N=2048 | N=4096 | N=8192 | N=16384 | N=32768 | N=45056 | vs Ch 0 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Ch 0 naive (no tensor cores) | 0.4 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | — | — | 1.00× |
| Ch 1 hand-rolled MMA | 0.2 | 0.7 | 2.4 | 2.9 | 3.4 | 3.5 | 3.5 | 3.5 | — | 4.87× |
| Ch 2 tiling macro | 0.2 | 0.7 | 2.9 | 4.4 | 4.3 | 4.2 | 4.3 | 4.3 | — | 6.16× |
| Ch 3 async staging (cp.async) | 0.2 | 0.6 | 2.6 | 4.0 | 6.0 | 6.7 | 7.0 | 7.1 | — | 7.94× |
| Ch 4 TMA (:block) | 0.6 | 2.4 | 10.2 | 14.3 | 23.1 | 21.9 | 21.3 | 20.4 | 19.2 | 27.48× |
| Ch 5 ring + prefetch | 0.6 | 2.7 | 11.2 | 15.4 | 24.9 | 29.4 | 21.8 | 19.9 | 19.0 | 31.04× |
| Ch 6 warp specialization | 1.0 | 4.8 | 12.4 | 16.0 | 22.7 | 22.6 | 23.3 | 21.7 | 19.2 | 30.16× |

## § 2 — Top MMA Benchmarks

*How does Crisp actually stand?* Best mainloop against **all three contender classes**.

### Intel(R) Graphics [0xe20b] · tf32 · `fast`

| N | Crisp | Control<br>SYCL_Apples | **Peer**<br>SYCL-TLA | Ceiling<br>oneMKL | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.4 (0.010) `chap5_multistage_ring` | 1.9 (0.017) | N/A* | 5.3 (0.006) | — | 65% |
| 512 | 12.0 (0.022) `chap4_cheap_fetch` | 14.3 (0.019) | N/A* | 9.8 (0.027) | — | 122% |
| 1024 | 32.1 (0.067) `sec2_top` | 11.6 (0.186) | N/A* | — | — | — |
| 2048 | 30.6 (0.561) `sec2_top` | 12.6 (1.368) | N/A* | 13.8 (1.242) | — | **222%** |
| 4096 | 22.3 (6.161) `sec2_top` | 10.4 (13.231) | N/A* | 14.3 (9.602) | — | **156%** |
| 8192 | 16.3 (67.252) `sec2_top` | 7.9 (139.036) | N/A* | — | — | — |
| 16384 | 13.2 (668.724) `chap4_cheap_fetch` | 6.1 (1449.499) | N/A* | 14.4 (611.413) | — | 91% |

> *\*Note: SYCL-TLA does not implement TF32 DPAS on Xe2 (only BF16/FP16/FP8). See §2.1 below for the native 270+ TFLOPS BF16 suite.*

> *Reading **vs Ceiling** at tf32: oneMKL is requested at tf32, but its best tf32 point here is 14.4 TFLOPS against 114.6 for its own bf16 path. That gap suggests oneMKL's tf32 does not run on the matrix engines on Xe2 (as SYCL-TLA's does not), so a cell above 100% is Crisp against oneMKL's tf32 path, not against the hardware limit. Unconfirmed; the bf16 table is the like-for-like ceiling comparison.*


<details><summary><b>Compilation & Build Overhead</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 719 ms | 721 ms | 1.00× |
| **SYCL_Apples** | Control | 1.77 s | 4.02 s | **2.5× slower** |
| **oneMKL** | Ceiling | *precompiled* | 6.72 s | — |

</details>

### Intel(R) Graphics [0xe20b] · bf16 · `fast` *(Native 270+ TFLOPS Matrix Engines)*

Crisp is **outside-in**: the user picks the configuration, exactly as SYCL-TLA's pipeline depth is a template argument. So two Crisp columns, and the gap between them is *what tuning is worth*. **Envelope** is the best variant at each size, naming which one. **Best single** is the one fixed choice that does best across all sizes (`wg256xepf2`) — what you get without per-size tuning. 5 variants measured.

| N | Crisp BF16<br>**envelope** | Crisp BF16<br>best single (`wg256xepf2`) | Control<br>SYCL_Apples_BF16 | **Peer**<br>SYCL-TLA_BF16 | Ceiling<br>oneMKL_BF16 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.5 (0.009) `pfw1` | 2.9 | 2.2 (0.015) | 0.4 (0.077) | 9.8 (0.003) | **8.18×** | 36% |
| 512 | 18.4 (0.015) `pfw1` | 15.3 | 8.2 (0.033) | 3.4 (0.080) | 41.0 (0.007) | **5.47×** | 45% |
| 1024 | 73.7 (0.029) `wg256xepf2` | 73.7 | 16.5 (0.130) | 23.8 (0.090) | 75.1 (0.029) | **3.10×** | 98% |
| 2048 | 82.3 (0.209) `wg256xepf2` | 82.3 | 18.9 (0.910) | 58.3 (0.295) | 88.4 (0.194) | 1.41× | 93% |
| 4096 | 107.5 (1.279) `wg256xepf2` | 107.5 | 18.9 (7.280) | 84.4 (1.628) | 104.9 (1.310) | 1.27× | 102% |
| 8192 | 111.0 (9.905) `wg256xepf2` | 111.0 | 16.1 (68.445) | 90.3 (12.173) | 113.0 (9.733) | 1.23× | 98% |
| 16384 | 112.9 (77.923) `wg256xepf2` | 112.9 | 11.2 (782.679) | 92.6 (95.031) | 114.6 (76.724) | 1.22× | 98% |

> **⚠ SIGN FLIPS — these variants reverse with problem size.**
> Each wins somewhere and loses somewhere, both beyond the measured run-to-run
> spread, so a single fixed choice is not available and the envelope above is
> assembled from *different kernels*. Picking by one size will mislead you at another.

> | variant | wins at | loses at |
> |---|---|---|
> | `pfw1` | 256 (+7%), 512 (+12%), 2048 (+12%), 4096 (+29%) | **8192 (-13%)**, **16384 (-79%)** |
> | `wg256pf2` | 2048 (+10%), 4096 (+26%), 8192 (+34%) | **256 (-22%)**, **512 (-17%)**, **16384 (-64%)** |
> | `wg256xe` | 1024 (+12%), 2048 (+8%), 4096 (+10%), 8192 (+15%), 16384 (+12%) | **256 (-11%)**, **512 (-5%)** |
> | `wg256xepf2` | 1024 (+13%), 2048 (+29%), 4096 (+49%), 8192 (+60%), 16384 (+63%) | **256 (-13%)**, **512 (-7%)** |


<details><summary><b>Compilation & Build Overhead (BF16)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 854 ms | 855 ms | 1.00× |
| **SYCL_Apples_BF16** | Control | 1.73 s | 3.90 s | **2.0× slower** |
| **SYCL-TLA_BF16** | Peer | 28.13 s | 62.11 s | **33.0× slower** |
| **oneMKL_BF16** | Ceiling | *precompiled* | 6.40 s | — |

</details>

### Intel(R) Graphics [0xe20b] · fp16 · `fast` *(Native 270+ TFLOPS Matrix Engines)*

Crisp is **outside-in**: the user picks the configuration, exactly as SYCL-TLA's pipeline depth is a template argument. So two Crisp columns, and the gap between them is *what tuning is worth*. **Envelope** is the best variant at each size, naming which one. **Best single** is the one fixed choice that does best across all sizes (`wg256xepf2`) — what you get without per-size tuning. 11 variants measured.

| N | Crisp FP16<br>**envelope** | Crisp FP16<br>best single (`wg256xepf2`) | Control<br>SYCL_Apples_FP16 | **Peer**<br>SYCL-TLA_FP16 | Ceiling<br>oneMKL_FP16 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.6 (0.009) `pfw2` | 2.9 | 2.2 (0.015) | 0.5 (0.072) | 10.1 (0.003) | **7.75×** | 36% |
| 512 | 18.8 (0.014) `pfw2` | 15.3 | 8.2 (0.033) | 2.7 (0.100) | 41.0 (0.007) | **7.04×** | 46% |
| 1024 | 73.5 (0.029) `wg256xepf2` | 73.5 | 16.5 (0.130) | 24.6 (0.087) | 75.1 (0.029) | **2.99×** | 98% |
| 2048 | 81.9 (0.210) `wg256xepf2` | 81.9 | 19.0 (0.905) | 54.7 (0.314) | 86.6 (0.198) | 1.50× | 95% |
| 4096 | 107.6 (1.277) `wg256xepf2` | 107.6 | 18.9 (7.276) | 88.6 (1.551) | 110.8 (1.241) | 1.21× | 97% |
| 8192 | 111.0 (9.902) `wg256xepf2` | 111.0 | 16.1 (68.483) | 91.2 (12.059) | 111.7 (9.846) | 1.22× | 99% |
| 16384 | 114.1 (77.092) `wg256xepf2` | 114.1 | 11.3 (780.376) | 92.3 (95.347) | 110.1 (79.859) | 1.24× | 104% |

> **⚠ SIGN FLIPS — these variants reverse with problem size.**
> Each wins somewhere and loses somewhere, both beyond the measured run-to-run
> spread, so a single fixed choice is not available and the envelope above is
> assembled from *different kernels*. Picking by one size will mislead you at another.

> | variant | wins at | loses at |
> |---|---|---|
> | `pfw1` | 256 (+8%), 512 (+12%), 2048 (+11%), 4096 (+29%) | **8192 (-14%)**, **16384 (-79%)** |
> | `pfw2` | 256 (+9%), 512 (+15%), 2048 (+11%), 4096 (+28%) | **8192 (-17%)**, **16384 (-81%)** |
> | `pfw3` | 256 (+8%), 512 (+12%), 2048 (+10%), 4096 (+26%) | **8192 (-12%)**, **16384 (-81%)** |
> | `pfw4` | 256 (+7%), 512 (+11%), 2048 (+7%), 4096 (+24%) | **1024 (-3%)**, **8192 (-7%)**, **16384 (-80%)** |
> | `wg256pf1` | 2048 (+10%), 4096 (+27%), 8192 (+35%) | **256 (-22%)**, **512 (-17%)**, **16384 (-56%)** |
> | `wg256pf2` | 2048 (+9%), 4096 (+26%), 8192 (+34%) | **256 (-22%)**, **512 (-17%)**, **1024 (-2%)**, **16384 (-64%)** |
> | `wg256pf2cc` | 2048 (+9%), 4096 (+26%), 8192 (+34%) | **256 (-21%)**, **512 (-17%)**, **1024 (-3%)**, **16384 (-63%)** |
> | `wg256xe` | 1024 (+9%), 2048 (+10%), 4096 (+10%), 8192 (+15%), 16384 (+12%) | **256 (-11%)**, **512 (-5%)** |
> | `wg256xepf2` | 1024 (+12%), 2048 (+28%), 4096 (+50%), 8192 (+60%), 16384 (+65%) | **256 (-13%)**, **512 (-7%)** |


<details><summary><b>Compilation & Build Overhead (FP16)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 846 ms | 847 ms | 1.00× |
| **SYCL_Apples_FP16** | Control | 1.76 s | 3.98 s | **2.1× slower** |
| **SYCL-TLA_FP16** | Peer | 28.15 s | 52.57 s | **33.3× slower** |
| **oneMKL_FP16** | Ceiling | *precompiled* | 6.43 s | — |

</details>

### NVIDIA H100 80GB HBM3 · tf32 · `fast`

| N | Crisp | Control<br>CUDA_Apples | **Peer**<br>CUTLASS | Ceiling<br>cuBLAS | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.6 (0.009) `chap6_warp_specialization` | — | 2.4 (0.014) | 6.1 (0.006) | **1.53×** | 60% |
| 512 | 19.5 (0.014) `sec2_top` | 3.6 (0.075) | 15.2 (0.018) | 34.6 (0.008) | 1.28× | 56% |
| 1024 | 102.8 (0.021) `chap7_wgmma` | — | 84.2 (0.025) | 142.0 (0.015) | 1.22× | 72% |
| 2048 | 260.4 (0.066) `sec2_top` | 4.1 (4.171) | 263.2 (0.065) | 364.3 (0.047) | 0.99× | 71% |
| 4096 | 310.0 (0.443) `chap7_wgmma` | — | 325.1 (0.423) | 432.1 (0.318) | 0.95× | 72% |
| 8192 | 274.1 (4.011) `sec2_top` | 4.2 (260.295) | 336.3 (3.269) | 457.8 (2.402) | 0.82× | 60% |
| 16384 | 225.9 (38.945) `sec2_top` | 4.2 (2081.208) | 257.1 (34.216) | 397.5 (22.128) | 0.88× | 57% |
| 32768 | 255.2 (275.765) `chap7_wgmma` | — | 149.5 (470.626) | 449.4 (156.567) | **1.71×** | 57% |
| 61440 | 261.3 (1775.050) `chap7_wgmma` | — | 137.7 (3369.616) | 407.2 (1139.215) | **1.90×** | 64% |

<details><summary><b>Compilation & Build Overhead</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 356 ms | 356 ms | 1.00× |
| **CUTLASS** | Peer | 11.51 s | 26.69 s | **32.4× slower** |
| **cuBLAS** | Ceiling | *precompiled* | 1.12 s | — |

</details>

### NVIDIA H100 80GB HBM3 · bf16 · `fast` *(Native 270+ TFLOPS Matrix Engines)*

Crisp is **outside-in**: the user picks the configuration, exactly as CUTLASS's pipeline depth is a template argument. So two Crisp columns, and the gap between them is *what tuning is worth*. **Envelope** is the best variant at each size, naming which one. **Best single** is the one fixed choice that does best across all sizes (`2wg_deep`) — what you get without per-size tuning. 2 variants measured.

| N | Crisp BF16<br>**envelope** | Crisp BF16<br>best single (`2wg_deep`) | Control<br>CUDA_Apples_BF16 | **Peer**<br>CUTLASS_BF16 | Ceiling<br>cuBLAS_BF16 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 256 | 2.2 (0.015) `base` | 1.6 | 2.2 (0.015) | 3.1 (0.011) `64x128x64` | 3.5 (0.010) | 0.71× | 64% |
| 512 | 16.1 (0.017) `base` | 11.8 | 3.7 (0.073) | 21.9 (0.012) `64x128x64` | 25.3 (0.011) | 0.73× | 63% |
| 1024 | 97.9 (0.022) `base` | 75.9 | 4.2 (0.511) | 127.6 (0.017) `64x128x64` | 106.0 (0.020) | 0.77× | 92% |
| 2048 | 342.9 (0.050) `2wg_deep` | 342.9 | 4.4 (3.898) | 381.8 (0.045) `128x256x64` | 460.0 (0.037) | 0.90× | 75% |
| 4096 | 540.5 (0.254) `2wg_deep` | 540.5 | 4.5 (30.751) | 560.1 (0.245) `128x256x64` | 735.7 (0.187) | 0.96× | 73% |
| 8192 | 613.5 (1.792) `2wg_deep` | 613.5 | 4.5 (244.429) | 641.6 (1.714) `256x128x64` | 884.4 (1.243) | 0.96× | 69% |
| 16384 | 621.1 (14.162) `2wg_deep` | 621.1 | 4.5 (1954.023) | 617.4 (14.246) `128x128x64c2` | 858.3 (10.248) | 1.01× | 72% |
| 32768 | 604.7 (116.365) `2wg_deep` | 604.7 | 4.5 (15636.013) | 441.8 (159.281) `128x128x64c2` | 850.9 (82.696) | 1.37× | 71% |
| 77824 | — | — | — | 309.7 (3043.495) `128x128x64c2` | 856.7 (1100.359) | — | — |

> **⚠ SIGN FLIPS — these variants reverse with problem size.**
> Each wins somewhere and loses somewhere, both beyond the measured run-to-run
> spread, so a single fixed choice is not available and the envelope above is
> assembled from *different kernels*. Picking by one size will mislead you at another.

> | variant | wins at | loses at |
> |---|---|---|
> | `2wg_deep` | 2048 (+3%), 4096 (+14%), 8192 (+8%), 16384 (+38%), 32768 (+39%) | **256 (-26%)**, **512 (-27%)**, **1024 (-22%)** |


<details><summary><b>Compilation & Build Overhead (BF16)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 624 ms | 624 ms | 1.00× |
| **CUDA_Apples_BF16** | Control | 839 ms | 2.48 s | **1.3× slower** |
| **CUTLASS_BF16** | Peer | 9.05 s | 22.20 s | **14.5× slower** |
| **cuBLAS_BF16** | Ceiling | *precompiled* | 1.67 s | — |

</details>

### NVIDIA H100 80GB HBM3 · fp16 · `fast` *(Native 270+ TFLOPS Matrix Engines)*

Crisp is **outside-in**: the user picks the configuration, exactly as CUTLASS's pipeline depth is a template argument. So two Crisp columns, and the gap between them is *what tuning is worth*. **Envelope** is the best variant at each size, naming which one. **Best single** is the one fixed choice that does best across all sizes (`2wg_deep`) — what you get without per-size tuning. 2 variants measured.

| N | Crisp FP16<br>**envelope** | Crisp FP16<br>best single (`2wg_deep`) | Control<br>CUDA_Apples_FP16 | **Peer**<br>CUTLASS_FP16 | Ceiling<br>cuBLAS_FP16 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 256 | 2.2 (0.015) `base` | 1.7 | 2.2 (0.015) | 3.1 (0.011) `64x128x64` | 3.7 (0.009) | 0.72× | 61% |
| 512 | 16.0 (0.017) `base` | 11.9 | 3.7 (0.072) | 21.8 (0.012) `64x128x64` | 25.3 (0.011) | 0.73× | 63% |
| 1024 | 98.2 (0.022) `base` | 76.2 | 4.2 (0.507) | 127.8 (0.017) `64x128x64` | 148.1 (0.015) | 0.77× | 66% |
| 2048 | 342.7 (0.050) `2wg_deep` | 342.7 | 4.4 (3.869) | 382.4 (0.045) `128x256x64` | 460.8 (0.037) | 0.90× | 74% |
| 4096 | 544.9 (0.252) `2wg_deep` | 544.9 | 4.5 (30.542) | 558.9 (0.246) `128x256x64` | 685.3 (0.201) | 0.97× | 80% |
| 8192 | 610.6 (1.801) `2wg_deep` | 610.6 | 4.5 (244.494) | 644.3 (1.707) `256x128x64` | 885.1 (1.242) | 0.95× | 69% |
| 16384 | 620.2 (14.182) `2wg_deep` | 620.2 | 4.5 (1941.440) | 618.8 (14.216) `128x128x64c2` | 796.1 (11.049) | 1.00× | 78% |
| 32768 | 600.9 (117.107) `2wg_deep` | 600.9 | 4.5 (15536.183) | 427.8 (164.498) `128x128x64c2` | 719.5 (97.808) | 1.40× | 84% |
| 77824 | — | — | — | 308.3 (3057.600) `128x128x64c2` | 812.7 (1159.999) | — | — |

> **⚠ SIGN FLIPS — these variants reverse with problem size.**
> Each wins somewhere and loses somewhere, both beyond the measured run-to-run
> spread, so a single fixed choice is not available and the envelope above is
> assembled from *different kernels*. Picking by one size will mislead you at another.

> | variant | wins at | loses at |
> |---|---|---|
> | `2wg_deep` | 2048 (+3%), 4096 (+12%), 8192 (+7%), 16384 (+38%), 32768 (+38%) | **256 (-25%)**, **512 (-26%)**, **1024 (-22%)** |


<details><summary><b>Compilation & Build Overhead (FP16)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 609 ms | 609 ms | 1.00× |
| **CUDA_Apples_FP16** | Control | 778 ms | 2.29 s | **1.3× slower** |
| **CUTLASS_FP16** | Peer | 9.02 s | 21.99 s | **14.8× slower** |
| **cuBLAS_FP16** | Ceiling | *precompiled* | 1.66 s | — |

</details>

### NVIDIA H100 80GB HBM3 · f64 · `ieee` *(IEEE double · DMMA tensor cores)*

*IEEE double. Cells read **TFLOPS (kernel ms)**, and Crisp's envelope names the variant that produced each cell. Chapter 7 has no fp64 form: wgmma covers fp16/bf16/tf32/fp8/int8 and there is no fp64 warpgroup MMA in any form.*

**`64F_PEDANTIC` is reported but is NOT a disable-tensor-cores switch.** That reading is imported from fp32, where PEDANTIC forbids tf32; it does not transfer, because DMMA is bit-identical IEEE double and PEDANTIC has no numerical reason to refuse it. The DMMA-vs-vector question is answered by the CUTLASS `OpClassTensorOp` / `OpClassSimt` pair in the reference table below, where the lowering is chosen rather than inferred.

Crisp is **outside-in**: the user picks the configuration, exactly as CUTLASS's pipeline depth is a template argument. So two Crisp columns, and the gap between them is *what tuning is worth*. **Envelope** is the best variant at each size, naming which one. **Best single** is the one fixed choice that does best across all sizes (`warpspec`) — what you get without per-size tuning. 2 variants measured.

| N | Crisp F64<br>**envelope** | Crisp F64<br>best single (`warpspec`) | Control<br>CUDA_Apples_F64 | **Peer**<br>CUTLASS_F64 | Ceiling<br>cuBLAS_F64 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 256 | 1.0 (0.033) `warpspec` | 1.0 | — | 2.0 (0.016) `64x64x16w32x32s4` | 2.6 (0.013) | 0.50× | 39% |
| 512 | 4.7 (0.057) `warpspec` | 4.7 | — | 10.3 (0.026) `64x64x16w32x32s4` | 16.2 (0.017) | 0.46× | 29% |
| 1024 | 12.3 (0.174) `warpspec` | 12.3 | — | 27.5 (0.078) `64x64x16w32x32s4` | 43.9 (0.049) | 0.45× | 28% |
| 2048 | 15.9 (1.082) `warpspec` | 15.9 | — | 30.6 (0.562) `128x64x16w64x32s3` | 59.4 (0.289) | 0.52× | 27% |
| 4096 | 24.8 (5.550) `base` | 22.6 | — | 31.4 (4.380) `128x64x16w64x32s3` | 62.9 (2.185) | 0.79× | 39% |
| 8192 | 29.1 (37.802) `base` | 22.7 | — | 32.1 (34.275) `128x64x16w64x32s3` | 64.2 (17.132) | 0.91× | 45% |
| 16384 | 23.0 (382.104) `warpspec` | 23.0 | — | 32.5 (270.508) `128x64x16w64x32s3` | 65.5 (134.368) | 0.71× | 35% |
| 32768 | 21.8 (3233.740) `warpspec` | 21.8 | — | 32.6 (2155.845) `128x64x16w64x32s3` | 65.5 (1073.761) | 0.67× | 33% |
| 45056 | 19.2 (9521.070) `warpspec` | 19.2 | — | 32.6 (5606.065) `128x64x16w64x32s3` | 64.3 (2846.567) | 0.59× | 30% |

**Reference builds (F64).** Not contenders: each isolates a lowering or a compute type, and is excluded from the columns above so those stay one build per class.

| reference | N=256 | N=512 | N=1024 | N=2048 | N=4096 | N=8192 | N=16384 | N=32768 | N=45056 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| cuBLAS `64F_PEDANTIC` (compute type, still DMMA) | 2.5 | 14.4 | 40.9 | 44.1 | 45.2 | 45.4 | 46.1 | 46.2 | 45.8 |
| CUTLASS SIMT (vector fp64, no tensor cores) | 0.7 | 3.0 | 12.6 | 25.0 | 25.7 | 25.5 | 25.1 | 25.1 | 25.1 |


> **⚠ SIGN FLIPS — these variants reverse with problem size.**
> Each wins somewhere and loses somewhere, both beyond the measured run-to-run
> spread, so a single fixed choice is not available and the envelope above is
> assembled from *different kernels*. Picking by one size will mislead you at another.

> | variant | wins at | loses at |
> |---|---|---|
> | `warpspec` | 256 (+67%), 512 (+77%), 1024 (+11%), 2048 (+4%), 16384 (+5%), 32768 (+9%) | **4096 (-9%)**, **8192 (-22%)** |


<details><summary><b>Compilation & Build Overhead (F64)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 353 ms | 354 ms | 1.00× |
| **CUTLASS_F64** | Peer | 2.08 s | 7.35 s | **5.9× slower** |
| **cuBLAS_F64** | Ceiling | *precompiled* | 1.67 s | — |

</details>

## § 3 — Situational Techniques

*Techniques whose honest answer is "it depends."* Controlled pairs:

### TMA Multicast · NVIDIA H100 80GB HBM3

*Same 64×128 cluster kernel with and without TMA multicast. Cells are TFLOPS; the last row is `(multicast / cluster − 1)`, so positive means multicast won.*

| contender | N=256 | N=512 | N=1024 | N=2048 | N=4096 | N=8192 | N=16384 | N=32768 | N=61440 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Crisp cluster 64×128 | 3.8 | 23.6 | 115.9 | 163.5 | 191.4 | 188.8 | 171.2 | 151.6 | 129.5 |
| Crisp + TMA multicast | 3.5 | 21.5 | 107.4 | 199.0 | 220.8 | 235.1 | 172.9 | 156.9 | 140.8 |
| cuBLAS (Ceiling) | 6.1 | 34.5 | 142.1 | 363.6 | 431.7 | 457.1 | 391.4 | 449.9 | 418.2 |
| multicast vs cluster | -7.3% | -8.9% | -7.3% | +21.7% | +15.3% | +24.5% | +1.0% | +3.5% | +8.7% |

### MMA Lowering: `:xe-native` vs `:coop-matrix` (Intel only) · Intel(R) Graphics [0xe20b]

*Same kernel, same 32x64 bf16 geometry over one subgroup; only the lowering differs. `tuned` adds ring depth 2 and prefetch distance 2, which makes its `:coop-matrix` arm the shipped section 2.1 kernel.*

Each cell reads **`:coop-matrix` TFLOPS -> `:xe-native` TFLOPS (change)**, where the change is `(xe_native / coop_matrix - 1)`. Higher TFLOPS is faster, so a positive change means `:xe-native` won at that size.

| pairing | N=256 | N=512 | N=1024 | N=2048 | N=4096 | N=8192 | N=16384 |
|---|---:|---:|---:|---:|---:|---:|---:|
| bare (no ring, no prefetch) | 3.7→4.6 (**+24.3%**) | 16.5→19.7 (**+19.1%**) | 56.0→54.6 (−2.4%) | 54.2→59.7 (**+10.1%**) | 48.3→52.1 (**+7.7%**) | 47.8→58.5 (**+22.5%**) | 43.1→39.0 (**−9.7%**) |
| tuned (ring 2, prefetch 2) | 3.9→5.2 (**+33.9%**) | 16.9→22.3 (**+31.9%**) | 48.9→48.2 (−1.4%) | 55.9→64.7 (**+15.7%**) | 48.8→54.0 (**+10.7%**) | 37.1→33.5 (**−9.8%**) | 26.2→21.6 (**−17.4%**) |

Positive means `:xe-native` is faster. It wins bare and loses tuned: the lowering is better in isolation and does **not** compose with the register-tile ring. See `docs/topology.md`, `mma-lowering`.

## § 4 — MMA + Activation

*What does fusing an arbitrary activation buy?*

| contender | arbitrary activation? | what Crisp claims |
|---|---|---|
| cuBLASLt, oneDNN (**Ceiling**) | **No** — fixed enum / post-op set | **capability** — off-menu costs 2nd kernel + HBM round trip |
| CUTLASS, SYCL-TLA (**Peer**) | **Yes** — monomorphised functor | **expressiveness & compile time** (~165× faster build) |

### Intel(R) Graphics [0xe20b] · tf32 · `fast`

#### Ch 1 — Standard Epilogue (ReLU)

| N | Crisp Fused | **Peer**<br>SYCL-TLA Fused | **Ceiling**<br>oneDNN Fused | Baseline+2nd Kernel<br>oneMKL + ReLU | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.2 (0.011) | N/A* | 5.5 (0.006) | 3.8 (0.009) | — | 58% |
| 512 | 9.6 (0.028) | N/A* | 9.8 (0.027) | 8.7 (0.031) | — | 97% |
| 1024 | 21.2 (0.102) | N/A* | 13.3 (0.161) | — | — | **159%** |
| 2048 | 24.8 (0.693) | N/A* | 14.0 (1.223) | 13.2 (1.298) | — | **176%** |
| 4096 | 16.2 (8.479) | N/A* | 14.3 (9.586) | 13.9 (9.895) | — | 113% |
| 8192 | 11.7 (93.659) | N/A* | 14.5 (76.083) | 13.9 (78.842) | — | 81% |
| 16384 | 6.9 (1272.630) | N/A* | 14.5 (608.382) | — | — | 48% |

> *\*Note: SYCL-TLA only implements BF16/FP16/FP8 on Xe2.*


<details><summary><b>Compilation & Build Overhead (Fused ReLU)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 772 ms | 878 ms | 1.00× |
| **oneDNN Fused** | Ceiling | *precompiled* | 5.18 s | — |

</details>

#### Ch 2 — Custom Epilogue (Arbitrary User Function)

> *Ceilings (oneDNN / cuBLASLt) cannot fuse arbitrary user functions — forced to pay 2nd kernel + HBM round-trip.*

| N | Crisp Fused | **Peer**<br>SYCL-TLA Fused | Ceiling (2nd Kernel)<br>oneDNN + Custom | vs Peer | **vs Ceiling (2nd Kernel)** |
|---:|---:|---:|---:|---:|---:|
| 256 | 3.1 (0.011) | N/A* | 3.8 (0.009) | — | **82%** |
| 512 | 9.5 (0.028) | N/A* | 8.7 (0.031) | — | **110%** |
| 1024 | 20.9 (0.103) | N/A* | 11.4 (0.188) | — | **183%** |
| 2048 | 24.7 (0.695) | N/A* | 13.2 (1.300) | — | **187%** |
| 4096 | 16.5 (8.310) | N/A* | 13.9 (9.868) | — | **119%** |
| 8192 | 11.7 (94.120) | N/A* | 13.9 (78.834) | — | **84%** |
| 16384 | 6.8 (1301.110) | N/A* | 14.3 (617.174) | — | **47%** |

<details><summary><b>Compilation & Build Overhead (Fused Custom)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 772 ms | 919 ms | 1.00× |
| **oneDNN + Custom** | Ceiling | *precompiled* | 6.11 s | — |

</details>

### NVIDIA H100 80GB HBM3 · tf32 · `fast`

#### Ch 1 — Standard Epilogue (ReLU)

| N | Crisp Fused | **Peer**<br>CUTLASS Fused | **Ceiling**<br>cuBLASLt Fused | Baseline+2nd Kernel<br>cuBLAS + ReLU | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.2 (0.011) | — | 3.3 (0.010) | 2.1 (0.016) | — | 96% |
| 512 | 19.4 (0.014) | — | 21.7 (0.012) | 14.4 (0.019) | — | 90% |
| 1024 | 102.0 (0.021) | — | 89.4 (0.024) | 68.2 (0.031) | — | 114% |
| 2048 | 260.2 (0.066) | — | 318.8 (0.054) | 244.1 (0.070) | — | 82% |
| 4096 | 309.9 (0.444) | — | 424.7 (0.324) | 358.9 (0.383) | — | 73% |
| 8192 | 267.1 (4.116) | — | 460.0 (2.390) | 415.0 (2.650) | — | 58% |
| 16384 | 226.1 (38.897) | — | 397.6 (22.123) | 373.8 (23.531) | — | 57% |
| 32768 | 254.4 (276.648) | — | 451.6 (155.819) | 439.1 (160.270) | — | 56% |
| 61440 | 261.3 (1775.230) | — | 444.8 (1042.760) | 414.7 (1118.623) | — | 59% |

<details><summary><b>Compilation & Build Overhead (Fused ReLU)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 481 ms | 481 ms | 1.00× |
| **cuBLASLt Fused** | Ceiling | *precompiled* | 1.66 s | — |

</details>

#### Ch 2 — Custom Epilogue (Arbitrary User Function)

> *Ceilings (oneDNN / cuBLASLt) cannot fuse arbitrary user functions — forced to pay 2nd kernel + HBM round-trip.*

| N | Crisp Fused | **Peer**<br>CUTLASS Fused | Ceiling (2nd Kernel)<br>cuBLASLt + Custom | vs Peer | **vs Ceiling (2nd Kernel)** |
|---:|---:|---:|---:|---:|---:|
| 256 | 3.1 (0.011) | — | 2.7 (0.012) | — | **115%** |
| 512 | 19.0 (0.014) | — | 17.9 (0.015) | — | **106%** |
| 1024 | 100.1 (0.021) | — | 77.0 (0.028) | — | **130%** |
| 2048 | 251.3 (0.068) | — | 259.1 (0.066) | — | **97%** |
| 4096 | 296.6 (0.463) | — | 366.5 (0.375) | — | **81%** |
| 8192 | 261.3 (4.208) | — | 421.4 (2.609) | — | **62%** |
| 16384 | 226.0 (38.918) | — | 377.5 (23.300) | — | **60%** |
| 32768 | 249.5 (282.069) | — | 438.8 (160.377) | — | **57%** |
| 61440 | 260.2 (1782.680) | — | 436.3 (1063.245) | — | **60%** |

<details><summary><b>Compilation & Build Overhead (Fused Custom)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 489 ms | 489 ms | 1.00× |
| **cuBLASLt + Custom** | Ceiling | *precompiled* | 1.69 s | — |

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