# Crisp Benchmark Report

> Generated from verified test sweeps in `benchmarks/results/`.

| device | data captured | source | hardware profile |
|---|---|---|---|
| Intel(R) Graphics [0xe20b] | 2026-09-14 | Crisp `5999fa7c` (docker) | `bmg` (validated) |
| NVIDIA H100 80GB HBM3 | 2026-09-13 | Crisp `cc116e8c` (runpod) | `h100-80gb-hbm3` (queried*) |
| NVIDIA H200 | 2026-09-13 | Crisp `66a7911d` (runpod) | `h200` (queried*) |

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
| 3 | OpGroupAsyncCopy | 0.1 | 0.2 | 0.6 | 0.5 | 0.5 | 0.5 | 0.5 |
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
| 256 | 0.1 (0.440) | 1.3 (0.026) | 0.06× | 0.63× |
| 512 | 0.2 (1.135) | 1.5 (0.184) | 0.16× | 0.52× |
| 1024 | 0.6 (3.874) | 1.5 (1.404) | 0.36× | 0.33× |
| 2048 | 0.5 (31.694) | 1.5 (11.618) | 0.37× | 0.32× |
| 4096 | 0.5 (258.582) | 1.3 (104.751) | 0.41× | 0.29× |
| 8192 | 0.5 (2215.770) | 1.3 (839.200) | 0.38× | 0.30× |
| 16384 | 0.5 (19028.900) | — | — | 0.29× |

#### Ch 4 — Can the fetch itself be cheap?
register-resident load (global→GRF)

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 3 |
|---:|---:|---:|---:|---:|
| 256 | 2.9 (0.011) | 3.5 (0.010) | 0.84× | **38.42×** |
| 512 | 12.0 (0.022) | 14.3 (0.019) | 0.84× | **50.78×** |
| 1024 | 24.0 (0.089) | 30.6 (0.070) | 0.78× | **43.31×** |
| 2048 | 16.6 (1.035) | 22.6 (0.761) | 0.73× | **30.63×** |
| 4096 | 13.5 (10.218) | 21.1 (6.522) | 0.64× | **25.31×** |
| 8192 | 11.8 (93.357) | 6.7 (164.532) | **1.76×** | **23.73×** |
| 16384 | 13.2 (668.724) | 6.1 (1449.499) | **2.17×** | **28.46×** |

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

### NVIDIA H200 · tf32 · `fast`

**Rollup — Crisp TFLOPS, every chapter × every N.**

| # | technique | **N=256** | **N=512** | **N=1024** | **N=2048** | **N=4096** | **N=8192** | **N=16384** | **N=32768** | **N=86016** | **N=102400** |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | naive loops, no tensor cores | 0.8 | 0.9 | 0.9 | 1.0 | 1.0 | 1.0 | 1.0 | — | — | — |
| 1 | hand-rolled mma-accumulate-via-tile | 0.1 | 0.4 | 1.5 | 4.3 | 3.5 | 4.7 | 5.2 | 5.3 | — | — |
| 2 | matrix-multiply-tile-stride | 0.1 | 0.4 | 1.5 | 5.4 | 5.4 | 5.4 | 5.4 | 5.2 | — | — |
| 3 | cp.async | 0.1 | 0.6 | 2.4 | 4.3 | 7.0 | 8.3 | 8.9 | 9.1 | — | — |
| 4 | TMA descriptor (CUtensorMap) | 1.3 | 6.2 | 25.5 | 40.0 | 62.2 | 70.1 | 65.7 | 64.0 | 63.1 | — |
| 5 | SMEM ring | 1.4 | 6.8 | 25.2 | 42.4 | 66.3 | 70.0 | 69.8 | 69.9 | 64.6 | — |
| 6 | warp specialization | 2.2 | 12.8 | 40.6 | 62.1 | 70.0 | 74.7 | 61.7 | 61.3 | 58.5 | — |
| 7 | wgmma | 2.1 | 13.5 | 72.9 | 241.8 | 310.4 | 293.8 | 253.0 | 256.2 | 293.4 | — |

<details><summary><b>Per-chapter detail</b></summary>

#### Ch 0 — Does it run at all?
naive loops, no tensor cores

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control |
|---:|---:|---:|---:|
| 256 | 0.8 (0.044) | 0.8 (0.044) | 0.99× |
| 512 | 0.9 (0.294) | 0.9 (0.307) | 1.05× |
| 1024 | 0.9 (2.274) | 0.9 (2.403) | 1.06× |
| 2048 | 1.0 (17.669) | 0.9 (18.733) | 1.06× |
| 4096 | 1.0 (141.297) | 0.9 (149.201) | 1.06× |
| 8192 | 1.0 (1119.690) | 0.9 (1192.243) | 1.06× |
| 16384 | 1.0 (8952.390) | 0.9 (9529.743) | 1.06× |
| 32768 | — | — | — |
| 86016 | — | — | — |
| 102400 | — | — | — |

#### Ch 1 — Can we reach the tensor cores?
hand-rolled mma-accumulate-via-tile

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 0 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.343) | — | — | 0.13× |
| 512 | 0.4 (0.715) | — | — | 0.41× |
| 1024 | 1.5 (1.466) | — | — | **1.55×** |
| 2048 | 4.3 (4.023) | — | — | **4.39×** |
| 4096 | 3.5 (39.414) | — | — | **3.58×** |
| 8192 | 4.7 (232.251) | — | — | **4.82×** |
| 16384 | 5.2 (1695.340) | — | — | **5.28×** |
| 32768 | 5.3 (13336.700) | — | — | — |
| 86016 | — | — | — | — |
| 102400 | — | — | — | — |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 1 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.339) | 2.5 (0.013) | 0.04× | 1.01× |
| 512 | 0.4 (0.707) | 4.7 (0.057) | 0.08× | 1.01× |
| 1024 | 1.5 (1.446) | 5.5 (0.394) | 0.27× | 1.01× |
| 2048 | 5.4 (3.184) | 5.7 (3.005) | 0.94× | 1.26× |
| 4096 | 5.4 (25.327) | 5.7 (24.032) | 0.95× | **1.56×** |
| 8192 | 5.4 (203.683) | 5.7 (191.881) | 0.94× | 1.14× |
| 16384 | 5.4 (1642.060) | 5.7 (1533.322) | 0.93× | 1.03× |
| 32768 | 5.2 (13594.800) | 5.7 (12263.406) | 0.90× | 0.98× |
| 86016 | — | — | — | — |
| 102400 | — | — | — | — |

#### Ch 3 — Can the fetch overlap the math?
cp.async

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 2 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.226) | 2.4 (0.014) | 0.06× | **1.50×** |
| 512 | 0.6 (0.442) | 4.0 (0.067) | 0.15× | **1.60×** |
| 1024 | 2.4 (0.893) | 4.5 (0.472) | 0.53× | **1.62×** |
| 2048 | 4.3 (3.998) | 4.7 (3.621) | 0.91× | 0.80× |
| 4096 | 7.0 (19.507) | 4.8 (28.859) | 1.48× | 1.30× |
| 8192 | 8.3 (132.075) | 4.8 (230.454) | **1.74×** | **1.54×** |
| 16384 | 8.9 (988.723) | 4.8 (1840.895) | **1.86×** | **1.66×** |
| 32768 | 9.1 (7753.430) | 4.8 (14732.676) | **1.90×** | **1.75×** |
| 86016 | — | — | — | — |
| 102400 | — | — | — | — |

#### Ch 4 — Can the fetch itself be cheap?
TMA descriptor (CUtensorMap)

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 3 |
|---:|---:|---:|---:|---:|
| 256 | 1.3 (0.027) | 2.4 (0.014) | 0.53× | **8.42×** |
| 512 | 6.2 (0.044) | 4.0 (0.067) | **1.53×** | **10.12×** |
| 1024 | 25.5 (0.084) | 4.5 (0.472) | **5.62×** | **10.63×** |
| 2048 | 40.0 (0.430) | 4.7 (3.621) | **8.43×** | **9.30×** |
| 4096 | 62.2 (2.209) | 4.8 (28.857) | **13.06×** | **8.83×** |
| 8192 | 70.1 (15.683) | 4.8 (230.283) | **14.68×** | **8.42×** |
| 16384 | 65.7 (133.787) | 4.8 (1842.086) | **13.77×** | **7.39×** |
| 32768 | 64.0 (1100.070) | 4.8 (14723.684) | **13.38×** | **7.05×** |
| 86016 | 63.1 (20160.800) | — | — | — |
| 102400 | — | — | — | — |

#### Ch 5 — Can several fetches be in flight?
SMEM ring

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 4 |
|---:|---:|---:|---:|---:|
| 256 | 1.4 (0.025) | 2.2 (0.015) | 0.62× | 1.09× |
| 512 | 6.8 (0.039) | 3.6 (0.075) | **1.91×** | 1.11× |
| 1024 | 25.2 (0.085) | 4.0 (0.543) | **6.37×** | 0.99× |
| 2048 | 42.4 (0.405) | 4.1 (4.172) | **10.29×** | 1.06× |
| 4096 | 66.3 (2.074) | 4.2 (32.845) | **15.84×** | 1.07× |
| 8192 | 70.0 (15.699) | 4.2 (262.263) | **16.71×** | 1.00× |
| 16384 | 69.8 (125.972) | 4.2 (2095.861) | **16.64×** | 1.06× |
| 32768 | 69.9 (1007.350) | 4.2 (16776.646) | **16.65×** | 1.09× |
| 86016 | 64.6 (19702.600) | — | — | 1.02× |
| 102400 | — | — | — | — |

#### Ch 6 — Can the math stop waiting on bookkeeping?
warp specialization

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 5 |
|---:|---:|---:|---:|---:|
| 256 | 2.2 (0.015) | — | — | **1.62×** |
| 512 | 12.8 (0.021) | — | — | **1.88×** |
| 1024 | 40.6 (0.053) | — | — | **1.61×** |
| 2048 | 62.1 (0.276) | — | — | 1.47× |
| 4096 | 70.0 (1.964) | — | — | 1.06× |
| 8192 | 74.7 (14.724) | — | — | 1.07× |
| 16384 | 61.7 (142.633) | — | — | 0.88× |
| 32768 | 61.3 (1147.050) | — | — | 0.88× |
| 86016 | 58.5 (21774.000) | — | — | 0.90× |
| 102400 | — | — | — | — |

#### Ch 7 — Can one instruction do more math?
wgmma

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 6 |
|---:|---:|---:|---:|---:|
| 256 | 2.1 (0.016) | — | — | 0.93× |
| 512 | 13.5 (0.020) | — | — | 1.05× |
| 1024 | 72.9 (0.029) | — | — | **1.80×** |
| 2048 | 241.8 (0.071) | — | — | **3.89×** |
| 4096 | 310.4 (0.443) | — | — | **4.44×** |
| 8192 | 293.8 (3.743) | — | — | **3.93×** |
| 16384 | 253.0 (34.770) | — | — | **4.10×** |
| 32768 | 256.2 (274.620) | — | — | **4.18×** |
| 86016 | 293.4 (4337.690) | — | — | **5.02×** |
| 102400 | — | — | — | — |

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
| 3 | OpGroupAsyncCopy | 0.2 | 0.7 | 2.2 | 2.0 | 2.4 | 2.4 | 2.4 |
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
| 256 | 0.2 | 0.90× |
| 512 | 0.7 | 0.87× |
| 1024 | 2.2 | 0.91× |
| 2048 | 2.0 | 0.82× |
| 4096 | 2.4 | 1.09× |
| 8192 | 2.4 | 1.24× |
| 16384 | 2.4 | 1.48× |

#### Ch 4 — Can the fetch itself be cheap?
register-resident load (global→GRF)

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 4.7 | **24.38×** |
| 512 | 20.6 | **29.42×** |
| 1024 | 48.1 | **21.91×** |
| 2048 | 38.2 | **18.77×** |
| 4096 | 26.7 | **11.13×** |
| 8192 | 26.3 | **11.09×** |
| 16384 | 26.9 | **11.33×** |

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

### NVIDIA H200 · bf16 · `fast`

**Rollup — Crisp TFLOPS, every 16-bit chapter × every N.**

| # | technique | **N=256** | **N=512** | **N=1024** | **N=2048** | **N=4096** | **N=8192** | **N=16384** | **N=32768** | **N=102400** |
|---|---|---|---|---|---|---|---|---|---|---|
| 0 | naive loops, no tensor cores | — | — | — | — | — | — | — | — | — |
| 1 | hand-rolled mma-accumulate-via-tile | 0.2 | 0.6 | 2.4 | 6.4 | 6.6 | 7.2 | 7.3 | 7.3 | — |
| 2 | matrix-multiply-tile-stride | 0.2 | 0.7 | 2.6 | 8.3 | 8.1 | 8.0 | 8.0 | 7.9 | — |
| 3 | cp.async | — | — | — | — | — | — | — | — | — |
| 4 | TMA descriptor (CUtensorMap) | 1.7 | 8.9 | 34.4 | 66.1 | 101.7 | 110.3 | 112.8 | 114.0 | 112.6 |
| 5 | SMEM ring | 1.7 | 9.3 | 32.2 | 47.2 | 73.2 | 82.3 | 84.2 | 84.6 | 84.9 |
| 6 | warp specialization | 2.1 | 12.1 | 32.4 | 58.4 | 74.7 | 78.8 | 80.6 | 81.2 | 81.5 |
| 7 | wgmma | 2.3 | 15.6 | 99.5 | 362.0 | 503.8 | 583.2 | 514.3 | 487.7 | 513.6 |

**Fastest rung per size** — N=256: **ch 7** (2.3) · N=512: **ch 7** (15.6) · N=1024: **ch 7** (99.5) · N=2048: **ch 7** (362.0) · N=4096: **ch 7** (503.8) · N=8192: **ch 7** (583.2) · N=16384: **ch 7** (514.3) · N=32768: **ch 7** (487.7) · N=102400: **ch 7** (513.6)

<details><summary><b>Per-chapter detail (16-bit)</b></summary>

#### Ch 1 — Can we reach the tensor cores?
hand-rolled mma-accumulate-via-tile

| N | Crisp bf16 TFLOPS |
|---:|---:|
| 256 | 0.2 |
| 512 | 0.6 |
| 1024 | 2.4 |
| 2048 | 6.4 |
| 4096 | 6.6 |
| 8192 | 7.2 |
| 16384 | 7.3 |
| 32768 | 7.3 |
| 102400 | — |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 0.2 | 1.04× |
| 512 | 0.7 | 1.05× |
| 1024 | 2.6 | 1.09× |
| 2048 | 8.3 | 1.29× |
| 4096 | 8.1 | 1.23× |
| 8192 | 8.0 | 1.11× |
| 16384 | 8.0 | 1.10× |
| 32768 | 7.9 | 1.08× |
| 102400 | — | — |

#### Ch 4 — Can the fetch itself be cheap?
TMA descriptor (CUtensorMap)

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 1.7 | **10.42×** |
| 512 | 8.9 | **13.74×** |
| 1024 | 34.4 | **13.26×** |
| 2048 | 66.1 | **8.01×** |
| 4096 | 101.7 | **12.51×** |
| 8192 | 110.3 | **13.78×** |
| 16384 | 112.8 | **14.13×** |
| 32768 | 114.0 | **14.43×** |
| 102400 | 112.6 | — |

#### Ch 5 — Can several fetches be in flight?
SMEM ring

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 1.7 | 1.03× |
| 512 | 9.3 | 1.04× |
| 1024 | 32.2 | 0.94× |
| 2048 | 47.2 | 0.71× |
| 4096 | 73.2 | 0.72× |
| 8192 | 82.3 | 0.75× |
| 16384 | 84.2 | 0.75× |
| 32768 | 84.6 | 0.74× |
| 102400 | 84.9 | 0.75× |

#### Ch 6 — Can the math stop waiting on bookkeeping?
warp specialization

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 2.1 | 1.21× |
| 512 | 12.1 | 1.29× |
| 1024 | 32.4 | 1.01× |
| 2048 | 58.4 | 1.24× |
| 4096 | 74.7 | 1.02× |
| 8192 | 78.8 | 0.96× |
| 16384 | 80.6 | 0.96× |
| 32768 | 81.2 | 0.96× |
| 102400 | 81.5 | 0.96× |

#### Ch 7 — Can one instruction do more math?
wgmma

| N | Crisp bf16 TFLOPS | vs previous chapter |
|---:|---:|---:|
| 256 | 2.3 | 1.08× |
| 512 | 15.6 | 1.29× |
| 1024 | 99.5 | **3.08×** |
| 2048 | 362.0 | **6.20×** |
| 4096 | 503.8 | **6.74×** |
| 8192 | 583.2 | **7.40×** |
| 16384 | 514.3 | **6.38×** |
| 32768 | 487.7 | **6.01×** |
| 102400 | 513.6 | **6.30×** |

</details>

## § 1b — The Technique Ladder in 16-bit · Intel(R) Graphics [0xe20b]

*The same chapters as section 1, in bfloat16. Each kernel is its tf32 twin with two things changed: the operand element type, and the K step 8 → 16 (the native XMX shape for 16-bit operands is (8 16 16), not (8 16 8)). The C accumulator stays f32 in both.*

Cells read **bf16 TFLOPS (× vs the same chapter in tf32)**. The 32-bit baseline is **tf32 on XMX**, not fp32 on the vector engines — the BMG shape ladder is (8 16 8) tf32, (8 16 16) bf16, (8 16 32) int8, i.e. same M×N with K doubling per step. No Control/Peer/Ceiling columns: the chapter SYCL controls are tf32 only, so this is a Crisp-vs-Crisp ladder.

| chapter | N=256 | N=512 | N=1024 | N=2048 | N=4096 | N=8192 | N=16384 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Ch 0 naive (no XMX) | 0.1 (1.01×) | 0.2 (1.18×) | 0.1 (0.97×) | 0.1 (1.05×) | 0.1 (1.17×) | 0.1 (**1.84×**) | — |
| Ch 1 hand-rolled MMA | 0.2 (1.76×) | 0.8 (1.78×) | 2.4 (1.45×) | 2.5 (1.47×) | 2.2 (1.27×) | 1.9 (1.19×) | 1.6 (1.06×) |
| Ch 2 tiling macro | 0.2 (1.76×) | 0.8 (1.78×) | 2.4 (1.45×) | 2.5 (1.48×) | 2.2 (1.20×) | 1.9 (1.14×) | 1.6 (1.02×) |
| Ch 3 async staging | 0.2 (**2.51×**) | 0.7 (**2.97×**) | 2.2 (**3.96×**) | 2.0 (**3.75×**) | 2.4 (**4.52×**) | 2.4 (**4.78×**) | 2.4 (**5.13×**) |
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

## § 1b — The Technique Ladder in 16-bit · NVIDIA H200

*The same chapters as section 1, in bfloat16. Each kernel is its tf32 twin with two things changed: the operand element type, and the K step 8 → 16 (the native tensor-core shape for 16-bit operands is (8 16 16), not (8 16 8)). The C accumulator stays f32 in both.*

Cells read **bf16 TFLOPS (× vs the same chapter in tf32)**. The 32-bit baseline is **tf32 on the tensor cores**, not fp32 on the vector units. No Control/Peer/Ceiling columns: the chapter controls are tf32 only, so this is a Crisp-vs-Crisp ladder. § 1.5 above carries the full 16-bit ladder for this GPU; this table adds only the tf32 ratio.

| chapter | N=256 | N=512 | N=1024 | N=2048 | N=4096 | N=8192 | N=16384 | N=32768 | N=102400 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Ch 1 hand-rolled MMA | 0.2 (1.59×) | 0.6 (1.66×) | 2.4 (1.62×) | 6.4 (1.50×) | 6.6 (**1.89×**) | 7.2 (1.52×) | 7.3 (1.40×) | 7.3 (1.39×) | — |
| Ch 2 tiling macro | 0.2 (1.64×) | 0.7 (1.71×) | 2.6 (1.75×) | 8.3 (1.53×) | 8.1 (1.50×) | 8.0 (1.48×) | 8.0 (1.49×) | 7.9 (1.53×) | — |
| Ch 4 register-resident | 1.7 (1.35×) | 8.9 (1.45×) | 34.4 (1.35×) | 66.1 (1.65×) | 101.7 (1.63×) | 110.3 (1.57×) | 112.8 (1.72×) | 114.0 (1.78×) | 112.6 (tf32 n/a) |
| Ch 5 ring + prefetch | 1.7 (1.28×) | 9.3 (1.37×) | 32.2 (1.28×) | 47.2 (1.11×) | 73.2 (1.10×) | 82.3 (1.18×) | 84.2 (1.21×) | 84.6 (1.21×) | 84.9 (tf32 n/a) |

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

## § 1c — The Technique Ladder in 64-bit · NVIDIA H200

*The same chapters at IEEE double. Cells read **fp64 TFLOPS**, and the rightmost column is each rung's ratio to the Chapter 0 vector-fp64 floor.*

**Chapter 7 is absent by hardware, not unmeasured.** wgmma covers fp16/bf16/tf32/fp8/int8; there is no fp64 warpgroup MMA in any form, so Chapter 6 is the top of this ladder.

**These rows are not comparable cell-for-cell with the tf32 ladder.** An fp64 accumulator fragment is 8×8 holding 2 doubles per lane = 4 registers, so the tf32 chapters' 64×64 tile would need 256 registers/thread — one over the architectural 255. Every 64-bit rung therefore runs at 64×32. fp64 costs 2× the registers at equal tile size, which is part of the 64-bit result rather than a tuning choice.

*Expectation under test (from § 2): the fp64 tensor core measured only 1.20–1.53× over vector fp64, while cuBLAS sits ~1.9× above the best CUTLASS DMMA config — both DMMA, so that larger gap is scheduling. If that holds, the distance on this ladder should be in chapters 2–6, not chapter 1.*

| chapter | N=256 | N=512 | N=1024 | N=2048 | N=4096 | N=8192 | N=16384 | N=32768 | N=57344 | vs Ch 0 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Ch 0 naive (no tensor cores) | 0.4 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | 0.5 | — | — | 1.00× |
| Ch 1 hand-rolled MMA | 0.2 | 0.7 | 2.5 | 2.9 | 3.4 | 3.7 | 3.7 | 3.7 | — | 5.00× |
| Ch 2 tiling macro | 0.2 | 0.7 | 2.9 | 4.3 | 4.2 | 4.2 | 4.3 | 4.3 | — | 6.10× |
| Ch 3 async staging (cp.async) | 0.2 | 0.7 | 2.6 | 4.1 | 6.1 | 6.8 | 7.1 | 7.1 | — | 8.03× |
| Ch 4 TMA (:block) | 0.6 | 2.5 | 10.0 | 14.5 | 23.2 | 25.9 | 26.6 | 26.2 | 25.1 | 30.21× |
| Ch 5 ring + prefetch | 0.6 | 2.7 | 10.7 | 15.3 | 24.8 | 29.2 | 30.2 | 29.1 | 27.2 | 33.17× |
| Ch 6 warp specialization | 1.0 | 4.7 | 12.0 | 16.1 | 22.9 | 25.5 | 26.2 | 26.5 | 25.4 | 31.76× |

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

### NVIDIA H200 · tf32 · `fast`

| N | Crisp | Control<br>CUDA_Apples | **Peer**<br>CUTLASS | Ceiling<br>cuBLAS | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 2.2 (0.015) `chap6_warp_specialization` | — | 2.4 (0.014) | 5.9 (0.006) | 0.94× | 37% |
| 512 | 13.5 (0.020) `chap7_wgmma` | — | 15.1 (0.018) | 33.6 (0.008) | 0.89× | 40% |
| 1024 | 72.9 (0.029) `chap7_wgmma` | — | 88.0 (0.024) | 150.8 (0.014) | 0.83× | 48% |
| 2048 | 241.8 (0.071) `chap7_wgmma` | — | 272.7 (0.063) | 355.5 (0.048) | 0.89× | 68% |
| 4096 | 317.2 (0.433) `sec2_top` | 4.2 (32.845) | 350.9 (0.392) | 431.4 (0.319) | 0.90× | 74% |
| 8192 | 293.8 (3.743) `chap7_wgmma` | — | 362.8 (3.031) | 457.1 (2.406) | 0.81× | 64% |
| 16384 | 253.4 (34.706) `sec2_top` | 4.2 (2097.067) | 288.9 (30.452) | 439.2 (20.028) | 0.88× | 58% |
| 32768 | 256.2 (274.620) `chap7_wgmma` | — | 202.5 (347.523) | 432.1 (162.845) | 1.27× | 59% |
| 86016 | 293.8 (4332.600) `sec2_top` | — | 189.4 (6718.942) | 423.0 (3009.047) | **1.55×** | 69% |

<details><summary><b>Compilation & Build Overhead</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 361 ms | 362 ms | 1.00× |
| **CUTLASS** | Peer | 12.31 s | 29.34 s | **34.1× slower** |
| **cuBLAS** | Ceiling | *precompiled* | 2.01 s | — |

</details>

### NVIDIA H200 · bf16 · `fast` *(Native 270+ TFLOPS Matrix Engines)*

Crisp is **outside-in**: the user picks the configuration, exactly as CUTLASS's pipeline depth is a template argument. So two Crisp columns, and the gap between them is *what tuning is worth*. **Envelope** is the best variant at each size, naming which one. **Best single** is the one fixed choice that does best across all sizes (`2wg_deep`) — what you get without per-size tuning. 2 variants measured.

| N | Crisp BF16<br>**envelope** | Crisp BF16<br>best single (`2wg_deep`) | Control<br>CUDA_Apples_BF16 | **Peer**<br>CUTLASS_BF16 | Ceiling<br>cuBLAS_BF16 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 256 | 2.3 (0.015) `base` | 1.7 | 2.2 (0.015) | 3.1 (0.011) `64x128x64` | 3.4 (0.010) | 0.72× | 68% |
| 512 | 16.1 (0.017) `base` | 11.8 | 3.7 (0.073) | 21.7 (0.012) `64x128x64` | 24.5 (0.011) | 0.74× | 66% |
| 1024 | 100.7 (0.021) `base` | 77.4 | 4.2 (0.511) | 128.8 (0.017) `64x128x64` | 98.4 (0.022) | 0.78× | 102% |
| 2048 | 362.1 (0.047) `base` | 354.2 | 4.4 (3.899) | 404.0 (0.043) `128x256x64` | 442.2 (0.039) | 0.90× | 82% |
| 4096 | 573.2 (0.240) `2wg_deep` | 573.2 | 4.5 (30.796) | 596.7 (0.230) `128x256x64` | 729.7 (0.188) | 0.96× | 79% |
| 8192 | 690.8 (1.592) `2wg_deep` | 690.8 | 4.5 (246.160) | 695.7 (1.580) `128x256x64` | 886.9 (1.240) | 0.99× | 78% |
| 16384 | 759.7 (11.578) `2wg_deep` | 759.7 | 4.5 (1968.588) | 669.4 (13.140) `256x128x64` | 886.8 (9.919) | 1.13× | 86% |
| 32768 | 723.4 (97.276) `2wg_deep` | 723.4 | 4.5 (15748.320) | 591.5 (118.966) `128x128x64c2` | 781.1 (90.084) | 1.22× | 93% |
| 102400 | 696.5 (3083.150) `2wg_deep` | 696.5 | — | 406.0 (5289.130) `128x128x64c2` | 755.3 (2843.317) | **1.72×** | 92% |

> **⚠ SIGN FLIPS — these variants reverse with problem size.**
> Each wins somewhere and loses somewhere, both beyond the measured run-to-run
> spread, so a single fixed choice is not available and the envelope above is
> assembled from *different kernels*. Picking by one size will mislead you at another.

> | variant | wins at | loses at |
> |---|---|---|
> | `2wg_deep` | 4096 (+16%), 8192 (+13%), 16384 (+49%), 32768 (+48%), 102400 (+35%) | **256 (-26%)**, **512 (-27%)**, **1024 (-23%)** |


<details><summary><b>Compilation & Build Overhead (BF16)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 644 ms | 645 ms | 1.00× |
| **CUDA_Apples_BF16** | Control | 993 ms | 3.02 s | **1.5× slower** |
| **CUTLASS_BF16** | Peer | 10.28 s | 25.63 s | **15.9× slower** |
| **cuBLAS_BF16** | Ceiling | *precompiled* | 2.15 s | — |

</details>

### NVIDIA H200 · fp16 · `fast` *(Native 270+ TFLOPS Matrix Engines)*

Crisp is **outside-in**: the user picks the configuration, exactly as CUTLASS's pipeline depth is a template argument. So two Crisp columns, and the gap between them is *what tuning is worth*. **Envelope** is the best variant at each size, naming which one. **Best single** is the one fixed choice that does best across all sizes (`2wg_deep`) — what you get without per-size tuning. 2 variants measured.

| N | Crisp FP16<br>**envelope** | Crisp FP16<br>best single (`2wg_deep`) | Control<br>CUDA_Apples_FP16 | **Peer**<br>CUTLASS_FP16 | Ceiling<br>cuBLAS_FP16 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 256 | 2.3 (0.015) `base` | 1.7 | 2.2 (0.015) | 3.1 (0.011) `64x128x64` | 3.5 (0.010) | 0.72× | 64% |
| 512 | 16.0 (0.017) `base` | 11.8 | 3.7 (0.073) | 21.7 (0.012) `64x128x64` | 24.5 (0.011) | 0.74× | 65% |
| 1024 | 99.7 (0.022) `base` | 77.0 | 4.2 (0.507) | 128.8 (0.017) `64x128x64` | 143.7 (0.015) | 0.77× | 69% |
| 2048 | 361.8 (0.047) `base` | 354.7 | 4.4 (3.870) | 405.2 (0.042) `128x256x64` | 448.1 (0.038) | 0.89× | 81% |
| 4096 | 573.4 (0.240) `2wg_deep` | 573.4 | 4.5 (30.587) | 595.7 (0.231) `128x256x64` | 784.2 (0.175) | 0.96× | 73% |
| 8192 | 695.8 (1.580) `2wg_deep` | 695.8 | 4.5 (244.425) | 706.5 (1.556) `128x256x64` | 887.5 (1.239) | 0.98× | 78% |
| 16384 | 743.2 (11.835) `2wg_deep` | 743.2 | 4.5 (1956.233) | 627.7 (14.014) `128x128x64c2` | 772.6 (11.386) | 1.18× | 96% |
| 32768 | 746.2 (94.301) `2wg_deep` | 746.2 | 4.5 (15653.408) | 619.3 (113.633) `128x128x64c2` | 795.1 (88.501) | 1.21× | 94% |
| 102400 | 719.9 (2983.100) `2wg_deep` | 719.9 | — | 405.5 (5295.769) `128x128x64c2` | 756.0 (2840.521) | **1.78×** | 95% |

> **⚠ SIGN FLIPS — these variants reverse with problem size.**
> Each wins somewhere and loses somewhere, both beyond the measured run-to-run
> spread, so a single fixed choice is not available and the envelope above is
> assembled from *different kernels*. Picking by one size will mislead you at another.

> | variant | wins at | loses at |
> |---|---|---|
> | `2wg_deep` | 4096 (+19%), 8192 (+22%), 16384 (+45%), 32768 (+52%), 102400 (+36%) | **256 (-26%)**, **512 (-26%)**, **1024 (-23%)** |


<details><summary><b>Compilation & Build Overhead (FP16)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 632 ms | 633 ms | 1.00× |
| **CUDA_Apples_FP16** | Control | 959 ms | 2.79 s | **1.5× slower** |
| **CUTLASS_FP16** | Peer | 10.21 s | 24.45 s | **16.2× slower** |
| **cuBLAS_FP16** | Ceiling | *precompiled* | 2.17 s | — |

</details>

### NVIDIA H200 · f64 · `ieee` *(IEEE double · DMMA tensor cores)*

*IEEE double. Cells read **TFLOPS (kernel ms)**, and Crisp's envelope names the variant that produced each cell. Chapter 7 has no fp64 form: wgmma covers fp16/bf16/tf32/fp8/int8 and there is no fp64 warpgroup MMA in any form.*

**`64F_PEDANTIC` is reported but is NOT a disable-tensor-cores switch.** That reading is imported from fp32, where PEDANTIC forbids tf32; it does not transfer, because DMMA is bit-identical IEEE double and PEDANTIC has no numerical reason to refuse it. The DMMA-vs-vector question is answered by the CUTLASS `OpClassTensorOp` / `OpClassSimt` pair in the reference table below, where the lowering is chosen rather than inferred.

Crisp is **outside-in**: the user picks the configuration, exactly as CUTLASS's pipeline depth is a template argument. So two Crisp columns, and the gap between them is *what tuning is worth*. **Envelope** is the best variant at each size, naming which one. **Best single** is the one fixed choice that does best across all sizes (`warpspec`) — what you get without per-size tuning. 2 variants measured.

| N | Crisp F64<br>**envelope** | Crisp F64<br>best single (`warpspec`) | Control<br>CUDA_Apples_F64 | **Peer**<br>CUTLASS_F64 | Ceiling<br>cuBLAS_F64 | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 256 | 1.0 (0.033) `warpspec` | 1.0 | — | 2.0 (0.016) `64x64x16w32x32s4` | 2.4 (0.014) | 0.50× | 42% |
| 512 | 4.7 (0.057) `warpspec` | 4.7 | — | 10.3 (0.026) `64x64x16w32x32s4` | 15.2 (0.018) | 0.46× | 31% |
| 1024 | 12.0 (0.179) `warpspec` | 12.0 | — | 27.5 (0.078) `64x64x16w32x32s4` | 43.1 (0.050) | 0.44× | 28% |
| 2048 | 16.0 (1.074) `warpspec` | 16.0 | — | 30.6 (0.562) `128x128x16w32x64s3` | 59.2 (0.290) | 0.52× | 27% |
| 4096 | 24.7 (5.554) `base` | 22.9 | — | 31.4 (4.380) `128x64x16w64x32s3` | 62.8 (2.188) | 0.79× | 39% |
| 8192 | 29.2 (37.627) `base` | 25.5 | — | 32.1 (34.269) `128x64x16w64x32s3` | 64.7 (16.988) | 0.91× | 45% |
| 16384 | 30.3 (290.725) `base` | 26.2 | — | 32.5 (270.400) `128x64x16w64x32s3` | 65.5 (134.228) | 0.93× | 46% |
| 32768 | 29.1 (2417.070) `base` | 26.5 | — | 32.6 (2156.944) `128x64x16w64x32s3` | 65.5 (1075.032) | 0.89× | 44% |
| 57344 | 27.2 (13862.500) `base` | 25.4 | — | 32.6 (11551.680) `128x64x16w64x32s3` | 65.4 (5767.369) | 0.83× | 42% |

**Reference builds (F64).** Not contenders: each isolates a lowering or a compute type, and is excluded from the columns above so those stay one build per class.

| reference | N=256 | N=512 | N=1024 | N=2048 | N=4096 | N=8192 | N=16384 | N=32768 | N=57344 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| cuBLAS `64F_PEDANTIC` (compute type, still DMMA) | 2.4 | 13.7 | 40.3 | 44.1 | 45.5 | 46.0 | 46.3 | 46.5 | 46.4 |
| CUTLASS SIMT (vector fp64, no tensor cores) | 0.7 | 3.0 | 12.6 | 24.8 | 25.4 | 25.3 | 25.2 | 25.3 | 25.3 |


> **⚠ SIGN FLIPS — these variants reverse with problem size.**
> Each wins somewhere and loses somewhere, both beyond the measured run-to-run
> spread, so a single fixed choice is not available and the envelope above is
> assembled from *different kernels*. Picking by one size will mislead you at another.

> | variant | wins at | loses at |
> |---|---|---|
> | `warpspec` | 256 (+67%), 512 (+78%), 1024 (+12%), 2048 (+5%) | **4096 (-8%)**, **8192 (-13%)**, **16384 (-13%)**, **32768 (-9%)**, **57344 (-6%)** |


<details><summary><b>Compilation & Build Overhead (F64)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 425 ms | 425 ms | 1.00× |
| **CUTLASS_F64** | Peer | 2.29 s | 8.30 s | **5.4× slower** |
| **cuBLAS_F64** | Ceiling | *precompiled* | 2.20 s | — |

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

### TMA Multicast · NVIDIA H200

*Same 64×128 cluster kernel with and without TMA multicast. Cells are TFLOPS; the last row is `(multicast / cluster − 1)`, so positive means multicast won.*

| contender | N=256 | N=512 | N=1024 | N=2048 | N=4096 | N=8192 | N=16384 | N=32768 | N=86016 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Crisp cluster 64×128 | 3.9 | 23.9 | 123.5 | 190.8 | 218.1 | 216.9 | 205.3 | 196.0 | 174.3 |
| Crisp + TMA multicast | 3.5 | 21.2 | 109.3 | 211.5 | 251.2 | 257.1 | 235.5 | 214.3 | 203.9 |
| cuBLAS (Ceiling) | 5.9 | 33.5 | 149.8 | 355.1 | 431.3 | 457.1 | 437.7 | 432.2 | 422.6 |
| multicast vs cluster | -9.4% | -11.3% | -11.5% | +10.9% | +15.2% | +18.6% | +14.7% | +9.3% | +17.0% |

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

### NVIDIA H200 · tf32 · `fast`

#### Ch 1 — Standard Epilogue (ReLU)

| N | Crisp Fused | **Peer**<br>CUTLASS Fused | **Ceiling**<br>cuBLASLt Fused | Baseline+2nd Kernel<br>cuBLAS + ReLU | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 2.0 (0.017) | — | 3.2 (0.011) | 2.0 (0.017) | — | 64% |
| 512 | 13.3 (0.020) | — | 20.8 (0.013) | 13.8 (0.019) | — | 64% |
| 1024 | 72.6 (0.030) | — | 92.3 (0.023) | 67.5 (0.032) | — | 79% |
| 2048 | 241.0 (0.071) | — | 304.5 (0.056) | 236.3 (0.073) | — | 79% |
| 4096 | 308.3 (0.446) | — | 418.5 (0.328) | 360.0 (0.382) | — | 74% |
| 8192 | 291.0 (3.779) | — | 455.2 (2.416) | 421.2 (2.610) | — | 64% |
| 16384 | 253.1 (34.758) | — | 436.2 (20.165) | 426.1 (20.644) | — | 58% |
| 32768 | 257.4 (273.365) | — | 432.1 (162.845) | 424.2 (165.889) | — | 60% |
| 86016 | 292.3 (4353.960) | — | 422.7 (3011.460) | 419.8 (3031.842) | — | 69% |

<details><summary><b>Compilation & Build Overhead (Fused ReLU)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 510 ms | 699 ms | 1.00× |
| **cuBLASLt Fused** | Ceiling | *precompiled* | 2.20 s | — |

</details>

#### Ch 2 — Custom Epilogue (Arbitrary User Function)

> *Ceilings (oneDNN / cuBLASLt) cannot fuse arbitrary user functions — forced to pay 2nd kernel + HBM round-trip.*

| N | Crisp Fused | **Peer**<br>CUTLASS Fused | Ceiling (2nd Kernel)<br>cuBLASLt + Custom | vs Peer | **vs Ceiling (2nd Kernel)** |
|---:|---:|---:|---:|---:|---:|
| 256 | 1.9 (0.018) | — | 2.6 (0.013) | — | **74%** |
| 512 | 13.1 (0.021) | — | 17.4 (0.015) | — | **75%** |
| 1024 | 71.5 (0.030) | — | 77.8 (0.028) | — | **92%** |
| 2048 | 233.5 (0.074) | — | 250.3 (0.069) | — | **93%** |
| 4096 | 297.9 (0.461) | — | 365.4 (0.376) | — | **82%** |
| 8192 | 277.6 (3.961) | — | 421.1 (2.611) | — | **66%** |
| 16384 | 252.5 (34.834) | — | 425.0 (20.696) | — | **59%** |
| 32768 | 258.3 (272.432) | — | 424.1 (165.909) | — | **61%** |
| 86016 | 294.0 (4328.710) | — | 419.9 (3031.283) | — | **70%** |

<details><summary><b>Compilation & Build Overhead (Fused Custom)</b></summary>

| contender | class | device codegen (PTX) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp Fused** | Crisp | 517 ms | 759 ms | 1.00× |
| **cuBLASLt + Custom** | Ceiling | *precompiled* | 2.22 s | — |

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