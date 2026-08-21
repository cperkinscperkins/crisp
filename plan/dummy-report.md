# Crisp Benchmark Report — *ILLUSTRATIVE MOCK-UP*

> **⚠ MOST NUMBERS BELOW ARE FABRICATED.**  This file shows the *shape* of the report the
> reorganisation would produce.  Figures marked `[real]` are genuine measurements from
> `benchmarks/results/`; everything else is invented.  Real output lives in `benchmarks/REPORT.md`.

**How to read this report.** Every technique section is a **rollup grid** (all chapters × all
sizes, one metric) followed by **collapsed per-chapter detail**. The grid answers "which technique
wins at my size"; the detail answers "and by how much, against what". Several findings below exist
only *because* every chapter is run at every size — they are flagged where they appear.

**Report generated** 2026-08-20 14:02 UTC · Crisp `9bc20d4` · suites: `matmul`, `reduction`

Data is captured per device and copied back, so **each device carries its own capture date** — the
generation date above says only when this file was rendered.

| device | data captured | source | rows |
|---|---|---|---|
| NVIDIA H100 NVL | 2026-08-20 | fresh (this run) | 128 |
| NVIDIA H200 | 2026-08-14 | committed | 96 |
| Intel BMG | 2026-08-11 | committed | 88 |

> ⚠ **H200 and BMG data is 6 and 9 days old.** A device whose data predates the current Crisp SHA
> is flagged; the H200 rows below were produced by `a41f0c2`, not `9bc20d4`.

---

# Suite: matmul

Row variable: **N**, the square matrix dimension. Matmul cost grows as N³ while memory grows as
N², so the buckets are **time-bounded**, and the largest size is capped per device by memory.

| bucket | N | what it exercises |
|---|---|---|
| small | 512, 1024 | launch overhead and occupancy dominate |
| medium | 2048, 4096 | the machine saturates (~0.97 residency waves) |
| large | 8192, 16384 | steady state |
| xl | 32768, 65536 | device permitting |

**Precision: `fast` only for tensor-core chapters.** `mma-accumulate-via-tile` lowers to tf32
regardless of the precision flag, so a three-way sweep would re-measure the same kernel. §1
chapter 0 is real fp32 and *does* get the full matrix — see its own table.

---

## § 1 — MMA Techniques

*How do you make a matmul fast, one step at a time?*

**Contenders: Control only.** Chapter 0 is not trying to be cuBLAS; quoting that ratio would be a
category error. The column carrying the story is **vs previous chapter**.

**Device: one representative per vendor.** A technique delta is a property of the technique, not
the device. Per-device numbers are §2's job.

### NVIDIA · H100 NVL · tf32 · `fast`

**Rollup — Crisp TFLOPS, every chapter × every N.**

Read down a column to see which technique wins at that size; read across to see how each
technique scales.

| # | technique | **N=512** | **N=1024** | **N=2048** | **N=4096** | **N=8192** | **N=16384** | **N=32768** |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 0 | naive loops, no tensor cores | 1.4 | 3.8 | 4.8 | 4.8 | 5.0 | 5.0 | n/a * |
| 1 | hand-rolled `mma-accumulate-via-tile` | 1.5 | 9.7 | 28.7 | 38.1 | 39.8 | 40.0 | 40.0 |
| 2 | `matrix-multiply-tile-stride` | 2.4 | 15.4 | 45.9 | 61.0 | 63.6 | 64.0 | 64.0 |
| 3 | `cp.async` | 3.6 | 21.9 | 59.1 | 75.0 | 77.6 | 78.0 | 78.0 |
| 4 | TMA descriptor (`CUtensorMap`) | 5.8 | 33.2 | 80.4 | 97.9 | 100.6 | 100.9 | 101.0 |
| 5 | SMEM ring | 9.0 | 47.9 | 104.1 | 121.9 | 124.6 | 125.0 | 125.0 |
| 6 | warp specialization | 25.7 | 98.3 | 152.1 | 163.3 | 164.8 | 165.0 | 165.0 |
| 7 | `wgmma` | 15.0 | 79.7 | 238.2 | 257.1 | 274.6 | 296.3 | 308.9 |

\* chapter 0 at N=32768 is **14.7 s per iteration** — the size range is per chapter, capped by
time. An `n/a` here means "too slow to measure", which is itself the chapter's result.

> **Two findings visible only in this grid.** Chapter 7 (`wgmma`) is **0.58× of chapter 6 at
> N=512** and **1.87× at N=32768** — warp specialization is the small-size lever and wgmma the
> large-size one. And chapter 0 flatlines at 5 TFLOPS from N=2048 onward: a naive kernel stops
> improving once it is memory-bound, so every later chapter's gain is real work, not scale.

<details><summary><b>Per-chapter detail (8 tables)</b></summary>


#### Ch 0 — Does it run at all?
naive loops, no tensor cores

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control |
|---:|---:|---:|---:|
| 512 | 1.4 (0.191) | 1.5 (0.175) | 0.92× |
| 1024 | 3.8 (0.567) | 4.1 (0.520) | 0.92× |
| 2048 | 4.8 (3.573) | 5.2 (3.278) | 0.92× |
| 4096 | 4.8 (28.633) | 5.2 (26.269) | 0.92× |
| 8192 | 5.0 (220.040) | 5.4 (201.871) | 0.92× |
| 16384 | 5.0 (1759.356) | 5.4 (1614.088) | 0.92× |
| 32768 | n/a — 14.7 s/iter | n/a | n/a |

#### Ch 1 — Can we reach the tensor cores?
hand-rolled `mma-accumulate-via-tile`

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 0 |
|---:|---:|---:|---:|---:|
| 512 | 1.5 (0.175) | 1.5 (0.183) | 1.04× | 1.09× |
| 1024 | 9.7 (0.222) | 9.3 (0.232) | 1.04× | **2.55×** |
| 2048 | 28.7 (0.598) | 27.6 (0.623) | 1.04× | **5.97×** |
| 4096 | 38.1 (3.605) | 36.6 (3.755) | 1.04× | **7.94×** |
| 8192 | 39.8 (27.657) | 38.2 (28.809) | 1.04× | **7.96×** |
| 16384 | 40.0 (220.071) | 38.4 (229.241) | 1.04× | **7.99×** |
| 32768 | 40.0 (1759.387) | 38.4 (1832.695) | 1.04× | **8.00×** |

#### Ch 2 — What does tiling buy?
`matrix-multiply-tile-stride`

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 1 |
|---:|---:|---:|---:|---:|
| 512 | 2.4 (0.110) | 2.4 (0.111) | 1.01× | **1.60×** |
| 1024 | 15.4 (0.139) | 15.3 (0.140) | 1.01× | **1.60×** |
| 2048 | 45.9 (0.374) | 45.5 (0.378) | 1.01× | **1.60×** |
| 4096 | 61.0 (2.253) | 60.4 (2.276) | 1.01× | **1.60×** |
| 8192 | 63.6 (17.285) | 63.0 (17.460) | 1.01× | **1.60×** |
| 16384 | 64.0 (137.544) | 63.3 (138.934) | 1.01× | **1.60×** |
| 32768 | 64.0 (1099.617) | 63.4 (1110.724) | 1.01× | **1.60×** |

#### Ch 3 — Can the fetch overlap the math?
`cp.async`

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 2 |
|---:|---:|---:|---:|---:|
| 512 | 3.6 (0.074) | 3.5 (0.076) | 1.03× | 1.49× |
| 1024 | 21.9 (0.098) | 21.3 (0.101) | 1.03× | 1.42× |
| 2048 | 59.1 (0.291) | 57.3 (0.300) | 1.03× | 1.29× |
| 4096 | 75.0 (1.832) | 72.8 (1.889) | 1.03× | 1.23× |
| 8192 | 77.6 (14.167) | 75.3 (14.605) | 1.03× | 1.22× |
| 16384 | 78.0 (112.841) | 75.6 (116.331) | 1.03× | 1.22× |
| 32768 | 78.0 (902.234) | 75.7 (930.138) | 1.03× | 1.22× |

#### Ch 4 — Can the fetch itself be cheap?
TMA descriptor (`CUtensorMap`)

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 3 |
|---:|---:|---:|---:|---:|
| 512 | 5.8 (0.046) | 5.5 (0.049) | 1.06× | **1.60×** |
| 1024 | 33.2 (0.065) | 31.2 (0.069) | 1.06× | **1.51×** |
| 2048 | 80.4 (0.214) | 75.6 (0.227) | 1.06× | 1.36× |
| 4096 | 97.9 (1.404) | 92.0 (1.494) | 1.06× | 1.30× |
| 8192 | 100.6 (10.930) | 94.6 (11.627) | 1.06× | 1.30× |
| 16384 | 100.9 (87.134) | 94.9 (92.695) | 1.06× | 1.30× |
| 32768 | 101.0 (696.764) | 94.9 (741.238) | 1.06× | 1.29× |

#### Ch 5 — Can several fetches be in flight?
SMEM ring

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 4 |
|---:|---:|---:|---:|---:|
| 512 | 9.0 (0.030) | 8.3 (0.032) | 1.09× | **1.55×** |
| 1024 | 47.9 (0.045) | 44.1 (0.049) | 1.09× | 1.44× |
| 2048 | 104.1 (0.165) | 95.7 (0.179) | 1.09× | 1.29× |
| 4096 | 121.9 (1.127) | 112.2 (1.225) | 1.09× | 1.25× |
| 8192 | 124.6 (8.824) | 114.6 (9.591) | 1.09× | 1.24× |
| 16384 | 125.0 (70.396) | 115.0 (76.518) | 1.09× | 1.24× |
| 32768 | 125.0 (562.978) | 115.0 (611.932) | 1.09× | 1.24× |

#### Ch 6 — Can the math stop waiting on bookkeeping?
warp specialization

| N | Crisp TFLOPS (ms) | vs ch 5 |
|---:|---:|---:|
| 512 | 25.7 (0.010) | **2.85×** |
| 1024 | 98.3 (0.022) | **2.05×** |
| 2048 | 152.1 (0.113) | 1.46× |
| 4096 | 163.3 (0.842) | 1.34× |
| 8192 | 164.8 (6.673) | 1.32× |
| 16384 | 165.0 (53.318) | 1.32× |
| 32768 | 165.0 (426.486) | 1.32× |

#### Ch 7 — Can one instruction do more math?
`wgmma`

| N | Crisp TFLOPS (ms) | vs ch 6 |
|---:|---:|---:|
| 512 | 15.0 (0.018) | **0.58×** |
| 1024 | 79.7 (0.027) | **0.81×** |
| 2048 | 238.2 (0.072) | **1.57×** |
| 4096 | 257.1 (0.535) | **1.57×** |
| 8192 | 274.6 (4.004) | **1.67×** |
| 16384 | 296.3 (29.686) | **1.80×** |
| 32768 | 308.9 (227.804) | **1.87×** |

*These are §2's Crisp numbers — chapter 7 IS the best mainloop, so the two sections must
agree row for row, and a divergence between them is a bug in the report generator.*

</details>

> **Chapters 1 → 2 is the macro's whole argument.** Identical algorithm — chapter 1 writes the
> loops by hand, chapter 2 uses `matrix-multiply-tile-stride`. **1.59× at every size** and 31
> fewer lines: the macro is not just shorter, it tiles better than the hand-written loops.

### Intel · BMG · tf32 · `fast`

**Rollup — Crisp TFLOPS, every chapter × every N.**

| # | technique | **N=512** | **N=1024** | **N=2048** | **N=4096** | **N=8192** | **N=16384** |
|---|---|---:|---:|---:|---:|---:|---:|
| 0 | naive loops, no XMX | 0.07 | 0.25 | 0.39 | 0.42 | 0.42 | 0.42 |
| 1 | hand-rolled XMX coop-matrix | 0.09 | 0.53 | 1.27 | 1.50 | 1.59 | 1.60 |
| 2 | `matrix-multiply-tile-stride` | 0.16 | 0.89 | 2.15 | 2.62 | 2.69 | 2.70 |
| 3 | `OpGroupAsyncCopy` | 0.10 | 0.60 | 1.79 | 2.38 | 2.48 | 2.50 |
| 4 | register-resident load (global→GRF) | 0.48 | 2.87 | 7.73 | 9.81 | 10.15 | 10.19 |
| 5 | register ring + prefetch | 0.94 | 5.38 | 13.06 | 15.80 | 16.33 | 16.39 |
| 6 | **blocked** — 3 reasons | — | — | — | — | — | — |
| 7 | GRF-bounded tile sweep | 1.04 | 6.24 | 16.83 | 21.35 | 22.09 | n/a — exceeds 12 GB |

> **Chapter 3 goes DOWN at every size**, not just at N=4096 — so the regression is a property
> of `OpGroupAsyncCopy` on this hardware, not of one measurement. That distinction is only
> visible with the full sweep, and it is the kind of thing a single-N row would have let us
> dismiss as noise.

<details><summary><b>Per-chapter detail (7 tables; ch 6 blocked)</b></summary>


#### Ch 0 — Does it run at all?
naive loops, no XMX

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control |
|---:|---:|---:|---:|
| 512 | 0.07 (4.11) | 0.06 (4.33) | 1.05× |
| 1024 | 0.25 (8.58) | 0.24 (9.04) | 1.05× |
| 2048 | 0.39 (44.38) | 0.37 (46.71) | 1.05× |
| 4096 | 0.42 (330.71) | 0.39 (348.11) | 1.05× |
| 8192 | 0.42 (2621.36) | 0.40 (2759.32) | 1.05× |
| 16384 | 0.42 (20946.55) | 0.40 (22049.00) | 1.05× |

#### Ch 1 — Can we reach the tensor cores?
hand-rolled XMX coop-matrix

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 0 |
|---:|---:|---:|---:|---:|
| 512 | 0.09 (2.91) | 0.11 (2.53) | 0.87× | 1.41× |
| 1024 | 0.53 (4.09) | 0.60 (3.56) | 0.87× | **2.10×** |
| 2048 | 1.27 (13.48) | 1.47 (11.72) | 0.87× | **3.29×** |
| 4096 | 1.50 (91.63) | 1.72 (79.67) | 0.87× | **3.61×** |
| 8192 | 1.59 (689.94) | 1.83 (599.95) | 0.87× | **3.80×** |
| 16384 | 1.60 (5500.30) | 1.84 (4782.87) | 0.87× | **3.81×** |

#### Ch 2 — What does tiling buy?
`matrix-multiply-tile-stride`

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 1 |
|---:|---:|---:|---:|---:|
| 512 | 0.16 (1.73) | 0.17 (1.54) | 0.89× | **1.69×** |
| 1024 | 0.89 (2.42) | 0.99 (2.16) | 0.89× | **1.69×** |
| 2048 | 2.15 (7.99) | 2.41 (7.13) | 0.89× | **1.69×** |
| 4096 | 2.62 (52.53) | 2.93 (46.90) | 0.89× | **1.74×** |
| 8192 | 2.69 (408.85) | 3.01 (365.05) | 0.89× | **1.69×** |
| 16384 | 2.70 (3259.44) | 3.02 (2910.21) | 0.89× | **1.69×** |

#### Ch 3 — Can the fetch overlap the math?
`OpGroupAsyncCopy`

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 2 |
|---:|---:|---:|---:|---:|
| 512 | 0.10 (2.81) | 0.08 (3.30) | 1.18× | **0.62×** |
| 1024 | 0.60 (3.56) | 0.51 (4.19) | 1.18× | **0.68×** |
| 2048 | 1.79 (9.57) | 1.53 (11.26) | 1.18× | **0.83×** |
| 4096 | 2.38 (57.68) | 2.03 (67.85) | 1.18× | **0.91×** |
| 8192 | 2.48 (442.50) | 2.11 (520.59) | 1.18× | **0.92×** |
| 16384 | 2.50 (3521.14) | 2.12 (4142.51) | 1.18× | **0.93×** |

#### Ch 4 — Can the fetch itself be cheap?
register-resident load (global→GRF)

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 3 |
|---:|---:|---:|---:|---:|
| 512 | 0.48 (0.56) | 0.49 (0.55) | 0.98× | **4.97×** |
| 1024 | 2.87 (0.75) | 2.93 (0.73) | 0.98× | **4.75×** |
| 2048 | 7.73 (2.22) | 7.89 (2.18) | 0.98× | **4.31×** |
| 4096 | 9.81 (14.01) | 10.00 (13.74) | 0.98× | **4.12×** |
| 8192 | 10.15 (108.33) | 10.35 (106.21) | 0.98× | **4.08×** |
| 16384 | 10.19 (862.90) | 10.40 (845.98) | 0.98× | **4.08×** |

#### Ch 5 — Can several fetches be in flight?
register ring + prefetch

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 4 |
|---:|---:|---:|---:|---:|
| 512 | 0.94 (0.28) | 1.56 (0.17) | 0.61× | **1.99×** |
| 1024 | 5.38 (0.40) | 8.88 (0.24) | 0.61× | **1.88×** |
| 2048 | 13.06 (1.32) | 21.55 (0.80) | 0.61× | **1.69×** |
| 4096 | 15.80 (8.70) | 26.07 (5.27) | 0.61× | **1.61×** |
| 8192 | 16.33 (67.31) | 26.95 (40.79) | 0.61× | **1.61×** |
| 16384 | 16.39 (536.62) | 27.05 (325.22) | 0.61× | **1.61×** |

#### Ch 6 — Can the math stop waiting on bookkeeping?
**blocked** — 3 reasons

`with-warp-specialization` compiles and differentiates on BMG; the **staging pipeline** is
blocked for three bounded reasons. No measurement — see the chapter page.


#### Ch 7 — Can one instruction do more math?
GRF-bounded tile sweep

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 5 (ch 6 blocked) |
|---:|---:|---:|---:|---:|
| 512 | 1.04 (0.26) | 1.78 (0.15) | 0.58× | 1.11× |
| 1024 | 6.24 (0.34) | 10.74 (0.20) | 0.58× | 1.16× |
| 2048 | 16.83 (1.02) | 28.94 (0.59) | 0.58× | 1.29× |
| 4096 | 21.35 (6.44) | 36.72 (3.74) | 0.58× | 1.35× |
| 8192 | 22.09 (49.77) | 37.99 (28.94) | 0.58× | 1.35× |
| 16384 | n/a — exceeds 12 GB | n/a | n/a | n/a |

</details>

### § 1 chapter 0 — the precision sweep, where it applies

Real fp32, no tensor cores, so the flags reach the arithmetic.

| device | `fast` | `ieee` | `ieee+ftz` | spread |
|---|---:|---:|---:|---:|
| H100 NVL | 4.8 `[real]` | 4.6 | 4.8 | 4% |
| BMG | 0.40 | 0.38 | 0.40 | 5% |

*Chapters 1–7 run `fast` only: their MMA is tf32 whatever the flag says.*

---

## § 2 — Top MMA Benchmarks

*How does Crisp actually stand?* §1's best mainloop against **all three contender classes**, on
**every device**. Same columns in every table; a missing contender says why.

Cells are **TFLOPS (kernel ms)**.

### NVIDIA H100 NVL · tf32 · `fast` · captured 2026-08-20

| N | Crisp | Control<br>CUDA_Apples | **Peer**<br>CUTLASS | Ceiling<br>cuBLAS | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 512 | 15.0 (0.018) `[real]` | 9.8 (0.027) | 18.2 (0.015) | 30.0 (0.009) `[real]` | 0.82× | 50% |
| 1024 | 79.7 (0.027) `[real]` | 48.1 (0.045) | 92.4 (0.023) | 141.0 (0.015) `[real]` | 0.86× | 57% |
| 2048 | 238.2 (0.072) `[real]` | 141.0 (0.122) | 262.4 (0.065) | 322.7 (0.053) `[real]` | 0.91× | 74% |
| 4096 | 257.1 (0.535) `[real]` | 152.7 (0.900) | 291.8 (0.471) | 381.6 (0.360) `[real]` | 0.88× | 67% |
| 8192 | 274.6 (4.00) | 160.2 (6.86) | 312.0 (3.52) | 402.1 (2.73) | 0.88× | 68% |
| 16384 | 296.3 (29.7) | 168.8 (52.1) | 330.5 (26.6) | 418.7 (21.0) | 0.90× | **71%** |
| 32768 | 308.9 (228) | 171.4 (410) | 341.2 (206) | 424.0 (166) | 0.91× | **73%** |
| 65536 | n/a — exceeds 94 GB | n/a | n/a | n/a | — | — |

> **The size sweep answers the ladder's central question.** The gap to cuBLAS narrows from 67% at
> 4096 to **73% at 32768** — larger problems are more compute-bound and less sensitive to wave
> quantisation. That is the regime production runs in, and a 4096 ceiling could not see it.

> **xl sizes cost seconds, not hours.** Under the time budget N=32768 runs 3 warmup + 3 measured
> iterations ≈ 1.7 s. Correctness is verified once at N ≤ 2048; large sizes are spot-checked.

### NVIDIA H200 · tf32 · `fast` · captured 2026-08-14 ⚠ *(Crisp `a41f0c2`)*

| N | Crisp | Control<br>CUDA_Apples | **Peer**<br>CUTLASS | Ceiling<br>cuBLAS | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 512 | 16.1 (0.017) | 10.4 (0.026) | 19.8 (0.014) | 33.2 (0.008) | 0.81× | 48% |
| 1024 | 88.2 (0.024) | 52.0 (0.041) | 101.3 (0.021) | 158.4 (0.014) | 0.87× | 56% |
| 2048 | 262.0 (0.066) | 154.1 (0.111) | 291.7 (0.059) | 356.2 (0.048) | 0.90× | 74% |
| 4096 | 291.4 (0.472) | 168.9 (0.814) | 330.6 (0.416) | 428.8 (0.321) | 0.88× | 68% |
| 8192 | 312.7 (3.52) | 177.1 (6.21) | 356.0 (3.09) | 452.6 (2.43) | 0.88× | 69% |
| 16384 | 348.2 (25.3) | 186.3 (47.2) | 388.1 (22.7) | 470.3 (18.7) | 0.90× | 74% |
| 32768 | 361.7 (195) | 190.0 (370) | 399.5 (176) | 478.2 (147) | 0.91× | **76%** |
| 65536 | 366.0 (1541) | 191.2 (2950) | 404.2 (1395) | 481.9 (1170) | 0.91× | 76% |

*H200's 141 GB admits N=65536; H100 NVL caps at 32768. Cross-device rows are comparable only where
both devices ran — the report does not interpolate.*

### Intel BMG · tf32 · `fast` · captured 2026-08-11

| N | Crisp | Control<br>SYCL_Apples | **Peer**<br>SYCL-TLA | Ceiling<br>oneMKL | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 512 | 3.1 (0.087) | 1.9 (0.141) | 3.4 (0.079) | 2.6 (0.103) | 0.91× | 119% |
| 1024 | 9.8 (0.219) | 5.4 (0.398) | 10.6 (0.203) | 8.1 (0.265) | 0.92× | 121% |
| 2048 | 17.2 (1.00) | 8.3 (2.07) | 18.4 (0.934) | 12.9 (1.33) | 0.93× | 133% |
| 4096 | 21.4 (6.42) | 9.6 (14.3) `[real]` | 22.8 (6.03) | 14.3 (9.60) `[real]` | 0.94× | **150%** |
| 8192 | 23.5 (46.8) | 10.0 (110) | 25.1 (43.8) | 14.8 (74.3) | 0.94× | 159% |
| 16384 | 24.1 (365) | 10.1 (871) | 25.6 (344) | 15.0 (587) | 0.94× | 161% |
| 32768 | n/a — exceeds 12 GB | n/a | n/a | n/a | — | — |

> **Crisp exceeds oneMKL on BMG, and that flatters us.** oneMKL's tf32 path is not well tuned for
> Battlemage, so the Ceiling is soft. The honest comparison is the **Peer**, where Crisp sits at
> 0.94× — the same place it sits on NVIDIA.

### Compile time — its own table, because it does not vary with N

`device_compile_ms` is **identical for every size** (`[real]`: 567.8 ms at N=256 *and* N=4096), so
it is a per-kernel property and would be a repeated column in the tables above.

| contender | class | build | one activation variant | note |
|---|---|---:|---:|---|
| Crisp | — | 0.57 s `[real]` | 0.57 s | recompiles the kernel |
| CUDA_Apples | Control | 1.9 s | 1.9 s | plain nvcc |
| **CUTLASS** | **Peer** | **94 s** | **94 s** | template instantiation per variant |
| cuBLAS | Ceiling | 0.60 s `[real]` | n/a | precompiled; cannot express a variant |
| oneMKL | Ceiling | 2.63 s `[real]` | n/a | precompiled |

> **Same capability, ~165× cheaper to express.** This is the claim §4 rests on when the contender
> is a Peer rather than a vendor library.

---

## § 3 — Situational Techniques

*Techniques whose honest answer is "it depends."* Controlled pairs: two kernels identical but for
one keyword, so the difference is attributable.

### TMA multicast (NVIDIA only) · H100 NVL · captured 2026-08-20

| tile | AI | N=1024 | N=2048 | N=4096 |
|---|---:|---:|---:|---:|
| 64×256 | 25.6 | −6.1% `[real]` | **−7.0%** `[real]` | −9.7% `[real]` |
| **64×128** | 21.3 | −6.1% `[real]` | **+15.5%** `[real]` | **+10.7%** `[real]` |
| 64×64 | 16.0 | +0.4% | +1.1% `[real]` | +4.4% `[real]` |
| 64×32 | 10.7 | −2.2% | +11.7% `[real]` | −11.6% `[real]` |

> **Two conditions, both required.** The machine must be **saturated** — the size crossover sits
> exactly at 0.97 residency waves — *and* the kernel must be **fetch-limited rather than
> compute-limited**. §1 chapter 7's wider tile is equally saturated and still loses, because its
> pipeline already hides the fetch.

> **Not a rung, and it claims no speedup.** §1's best kernel is faster than anything here. What
> this chapter teaches is how to tell whether a technique applies to your shape.

| kernel | regs/thread | CTAs/SM | resident | waves @ N=2048 |
|---|---:|---:|---:|---:|
| 64×256 | 165 `[real]` | 2 | 264 | 0.97 |
| 64×128 | 96 `[real]` | 4 | 528 | 0.97 |
| 64×64 | 66 `[real]` | 5 | 660 | 1.55 |
| 64×32 | 52 `[real]` | 7 | 924 | 2.22 |

*Occupancy inputs are recorded at build time from `ptxas -v`, so the argument above is checkable
from the data rather than recomputed by hand on a pod.*

---

## § 4 — MMA + Activation

*What does fusing an arbitrary activation buy?* Built on §1's best mainloop, with **its own
contenders** — and the claim differs by contender class.

| contender | arbitrary activation? | what Crisp claims |
|---|---|---|
| cuBLASLt, oneDNN (**Ceiling**) | **No** — fixed enum / post-op set | **capability** — off-menu costs a second kernel + HBM round trip |
| CUTLASS, SYCL-TLA (**Peer**) | **Yes** — monomorphised functor | **not capability** — expressiveness and compile time |

### Ch 1 — a common activation (ReLU) · N = 4096

| device | Crisp fused | Ceiling fused | Peer fused | vs Peer | vs Ceiling |
|---|---:|---:|---:|---:|---:|
| H100 NVL | 253.7 (0.542) `[real]` | 365.8 (0.376) `[real]` | 288.4 (0.477) | 0.88× | 69% |
| H200 | 287.1 (0.479) | 411.2 (0.334) | 326.0 (0.422) | 0.88× | 70% |
| BMG | 15.2 (9.04) `[real]` | 14.3 (9.61) `[real]` | 16.1 (8.54) | 0.94× | **106%** |

### Ch 2 — an ARBITRARY activation · N = 4096

| device | Crisp fused | Ceiling: GEMM + 2nd kernel | Peer fused | vs Peer | vs Ceiling |
|---|---:|---:|---:|---:|---:|
| H100 NVL | 257.1 (0.535) `[real]` | 315.7 (0.436) `[real]` | 284.9 (0.483) | 0.90× | **81%** |
| H200 | 291.0 (0.472) | 352.4 (0.390) | 322.6 (0.426) | 0.90× | 83% |
| BMG | 16.4 (8.38) `[real]` | 13.9 (9.89) `[real]` | 17.2 (7.99) | 0.95× | **118%** |

> **The Ceiling moves because the vendor's WORK changed**, not because Crisp got faster. cuBLASLt
> cannot fuse an off-menu activation, so its row here is GEMM **plus a second kernel and a full
> HBM round trip** — which is why Crisp closes from 69% to 81% between the two chapters with the
> same kernel.

> **Against the Peer the capability claim does not apply.** CUTLASS monomorphises the same
> arbitrary functor. Crisp sits at 0.90× its throughput and compiles it ~165× faster — see §2.

> **Chapter 2 adds no new API.** It is chapter 1's `map-elements!` with a user `def-function`.

### Ch 2 across N — the capability advantage is a SMALL-N advantage

The Ceiling's handicap is a second kernel plus an HBM round trip on the **output**, which is O(N²)
against a GEMM that is O(N³). That penalty is proportional to **1/N** and must shrink. But the
observed ratio carries Crisp's own size curve too (§1 ch 7), and the two interact — which is why
this table is not the clean monotonic decay the structure alone would predict.

H100 NVL, arbitrary activation, TFLOPS:

| N | Crisp fused | Ceiling fused (for reference) | Ceiling: GEMM + 2nd kernel | 2nd-kernel penalty | Crisp vs Ceiling |
|---:|---:|---:|---:|---:|---:|
| 512 | 15.0 | 27.0 | 11.9 | +127% | **1.26×** |
| 1024 | 79.7 | 143.7 | 87.9 | +64% | 0.91× |
| 2048 | 238.2 | 312.2 | 236.9 | +32% | **1.01×** |
| 4096 | 257.1 | 365.8 | 315.6 | +16% | 0.81× |
| 8192 | 274.6 | 373.8 | 346.3 | +8% | 0.79× |
| 16384 | 296.3 | 374.9 | 360.5 | +4% | 0.82× |

> **Crisp wins at N = 512 (1.26×) and is level at 2048 — then loses at 4096 and above.** The
> crossover is real but it is not a single clean threshold, because Crisp's `wgmma` mainloop has
> its own awkward plateau between 2048 and 4096 (238 → 257, visible in §1 ch 7). The vendor's
> handicap is shrinking at exactly the sizes where Crisp's mainloop has not yet hit its stride.
>
> **This bounds the claim honestly.** "Fusing an arbitrary activation is a capability advantage" is
> true, and it is worth **+127% of vendor time at N = 512, but only +4% at N = 16384**. The
> single-N table said 81% and let that read as the answer; it is one point on a curve that crosses
> 1.0 twice.
>
> It also says where the work is. The fusion advantage is already free and already fading, so the
> lever that matters at every N is the **mainloop** — §1 ch 7, and specifically that 2048→4096
> plateau, which is now the most suspicious feature in this report.


---

## § 5 — Scaling Out

*What if the problem does not fit?*

| topic | status |
|---|---|
| Out of core (one GPU, stream from host) | not implemented — candidate for 1.0 |
| Hardware multi-tile (e.g. PVC 2T/4T) | deferred — needs `def-topology` |
| Multi-GPU | deferred — needs `def-topology` + `def-orchestration` |

*No measurements. Present so the ladder states its own boundary rather than simply ending.*

---

# Suite: reduction

Row variable: **element count** (bytes shown alongside, since bandwidth is computed from bytes).
Reduction cost grows as O(N) on O(N) data, so the buckets are **memory-bounded** — the opposite of
matmul — and the headline metric is **GB/s**, not TFLOPS.

| bucket | elements | bytes | what it exercises |
|---|---|---|---|
| small | 1 M | 4 MB | launch overhead dominates |
| medium | 16 M, 256 M | 64 MB, 1 GB | bandwidth saturates |
| large | 4 G | 17 GB | memory-capacity bound |

**Precision: the full matrix.** This is the suite the three-way sweep exists for — summation order,
reassociation under fast-math, FMA contraction and denormal handling all change the *result*, not
just the speed.

---

## § 1 — Reduction Techniques

Headline metric is **GB/s**, not TFLOPS: a reduction does O(N) arithmetic on O(N) bytes, so the
memory bus is the ceiling and floating-point rate says nothing.

### NVIDIA · H100 NVL · `fast` · peak 3350 GB/s HBM3

**Rollup — Crisp GB/s, every chapter × every size.**

| # | technique | **1 M** | **16 M** | **256 M** | **4 G** |
|---|---|---:|---:|---:|---:|
| 0 | one thread/element, global atomics | 8.3 | 33 | 41 | 42 |
| 1 | SLM tree reduction | 32 | 346 | 892 | 989 |
| 2 | warp shuffle | 47 | 556 | 1684 | 1928 |
| 3 | grid-stride + `:occupancy 2.0` | 402 | 1980 | 2910 | 2948 |

<details><summary><b>Per-chapter detail (4 tables)</b></summary>


#### Ch 0 — Does it run at all?
one thread/element, global atomics

| elements | bytes | Crisp GB/s (ms) | Control GB/s (ms) | vs Control | % peak | verified |
|---|---:|---:|---:|---:|---:|:--:|
| 1 M | 4 MB | 8.3 (0.504) | 8.9 (0.471) | 0.93× | 0% | ✅ |
| 16 M | 64 MB | 33.3 (2.016) | 35.6 (1.885) | 0.93× | 1% | ✅ |
| 256 M | 1 GB | 41.0 (26.214) | 43.8 (24.499) | 0.93× | 1% | ✅ @16 M |
| 4 G | 17 GB | 41.6 (413.381) | 44.5 (386.337) | 0.93× | 1% | ✅ @16 M |

#### Ch 1 — Can threads cooperate?
SLM tree reduction

| elements | bytes | Crisp GB/s (ms) | Control GB/s (ms) | vs Control | % peak | vs ch 0 | verified |
|---|---:|---:|---:|---:|---:|---:|:--:|
| 1 M | 4 MB | 32.1 (0.131) | 32.8 (0.128) | 0.98× | 1% | **3.86×** | ✅ |
| 16 M | 64 MB | 346.4 (0.194) | 353.4 (0.190) | 0.98× | 10% | **10.41×** | ✅ |
| 256 M | 1 GB | 891.5 (1.204) | 909.4 (1.181) | 0.98× | 27% | **21.77×** | ✅ @16 M |
| 4 G | 17 GB | 988.8 (17.375) | 1008.5 (17.035) | 0.98× | 30% | **23.79×** | ✅ @16 M |

#### Ch 2 — Can we avoid the SLM round trip?
warp shuffle

| elements | bytes | Crisp GB/s (ms) | Control GB/s (ms) | vs Control | % peak | vs ch 1 | verified |
|---|---:|---:|---:|---:|---:|---:|:--:|
| 1 M | 4 MB | 47.5 (0.088) | 48.0 (0.087) | 0.99× | 1% | 1.48× | ✅ |
| 16 M | 64 MB | 556.3 (0.121) | 561.8 (0.119) | 0.99× | 17% | **1.61×** | ✅ |
| 256 M | 1 GB | 1683.9 (0.638) | 1700.7 (0.631) | 0.99× | 50% | **1.89×** | ✅ @16 M |
| 4 G | 17 GB | 1928.2 (8.910) | 1947.5 (8.822) | 0.99× | 58% | **1.95×** | ✅ @16 M |

#### Ch 3 — Can each thread do more?
grid-stride + `:occupancy 2.0`

| elements | bytes | Crisp GB/s (ms) | Control GB/s (ms) | vs Control | % peak | vs ch 2 | verified |
|---|---:|---:|---:|---:|---:|---:|:--:|
| 1 M | 4 MB | 402 (0.010) | 388 (0.011) | 1.04× | 12% | **8.46×** | ✅ |
| 16 M | 64 MB | 1980 (0.034) | 1900 (0.035) | 1.04× | 59% | **3.56×** | ✅ |
| 256 M | 1 GB | 2910 (0.369) | 2840 (0.378) | 1.02× | 87% | **1.73×** | ✅ @16 M |
| 4 G | 17 GB | 2948 (5.83) | 2870 (5.99) | 1.03× | 88% | 1.53× | ✅ @16 M |

</details>

### Intel · BMG · `fast` · peak 456 GB/s

**Rollup — Crisp GB/s, every chapter × every size.**

| # | technique | **1 M** | **16 M** | **256 M** | **4 G** |
|---|---|---:|---:|---:|---:|
| 0 | one thread/element, global atomics | 1.2 | 4.9 | 6.0 | n/a |
| 1 | SLM tree reduction | 6.1 | 66 | 170 | n/a |
| 2 | subgroup shuffle | 7.6 | 89 | 268 | n/a |
| 3 | grid-stride + `:occupancy 2.0` | 88 | 341 | 402 | n/a |

*4 G elements is 17 GB — it does not fit in BMG's 12 GB. The cap is the finding: a
bandwidth-bound suite is bounded by MEMORY, where matmul is bounded by TIME.*

<details><summary><b>Per-chapter detail (4 tables)</b></summary>


#### Ch 0 — Does it run at all?
one thread/element, global atomics

| elements | bytes | Crisp GB/s (ms) | Control GB/s (ms) | vs Control | % peak | verified |
|---|---:|---:|---:|---:|---:|:--:|
| 1 M | 4 MB | 1.2 (3.438) | 1.3 (3.306) | 0.96× | 0% | ✅ |
| 16 M | 64 MB | 4.9 (13.752) | 5.1 (13.223) | 0.96× | 1% | ✅ |
| 256 M | 1 GB | 6.0 (178.774) | 6.2 (171.898) | 0.96× | 1% | ✅ @16 M |
| 4 G | 17 GB | n/a — exceeds 12 GB | n/a | n/a | n/a | n/a |

#### Ch 1 — Can threads cooperate?
SLM tree reduction

| elements | bytes | Crisp GB/s (ms) | Control GB/s (ms) | vs Control | % peak | vs ch 0 | verified |
|---|---:|---:|---:|---:|---:|---:|:--:|
| 1 M | 4 MB | 6.1 (0.684) | 6.5 (0.646) | 0.94× | 1% | **5.02×** | ✅ |
| 16 M | 64 MB | 66.1 (1.015) | 70.1 (0.958) | 0.94× | 14% | **13.54×** | ✅ |
| 256 M | 1 GB | 170.1 (6.314) | 180.3 (5.956) | 0.94× | 37% | **28.32×** | ✅ @16 M |
| 4 G | 17 GB | n/a — exceeds 12 GB | n/a | n/a | n/a | n/a | n/a |

#### Ch 2 — Can we avoid the SLM round trip?
subgroup shuffle

| elements | bytes | Crisp GB/s (ms) | Control GB/s (ms) | vs Control | % peak | vs ch 1 | verified |
|---|---:|---:|---:|---:|---:|---:|:--:|
| 1 M | 4 MB | 7.6 (0.555) | 7.8 (0.539) | 0.97× | 2% | 1.23× | ✅ |
| 16 M | 64 MB | 88.6 (0.758) | 91.2 (0.736) | 0.97× | 19% | 1.34× | ✅ |
| 256 M | 1 GB | 268.1 (4.005) | 276.2 (3.888) | 0.97× | 59% | **1.58×** | ✅ @16 M |
| 4 G | 17 GB | n/a — exceeds 12 GB | n/a | n/a | n/a | n/a | n/a |

#### Ch 3 — Can each thread do more?
grid-stride + `:occupancy 2.0`

| elements | bytes | Crisp GB/s (ms) | Control GB/s (ms) | vs Control | % peak | vs ch 2 | verified |
|---|---:|---:|---:|---:|---:|---:|:--:|
| 1 M | 4 MB | 88 (0.048) | 81 (0.052) | 1.09× | 19% | **11.58×** | ✅ |
| 16 M | 64 MB | 341 (0.197) | 322 (0.208) | 1.06× | 75% | **3.85×** | ✅ |
| 256 M | 1 GB | 402 (2.67) | 380 (2.82) | 1.06× | 88% | **1.50×** | ✅ @16 M |
| 4 G | 17 GB | n/a — exceeds 12 GB | n/a | n/a | n/a | n/a | n/a |

</details>

> **Two chapters move in OPPOSITE directions with size, and that is the whole argument for this
> layout.** On the H100:
>
> | ratio | 1 M | 16 M | 256 M | 4 G | trend |
> |---|---:|---:|---:|---:|---|
> | ch 1 / ch 0 — tree vs atomics | 3.9× | 10.4× | **21.8×** | 23.8× | grows with size |
> | ch 3 / ch 2 — grid-stride vs shuffle | **8.5×** | 3.6× | 1.7× | 1.5× | **shrinks with size** |
>
> The tree reduction needs enough work to amortise its structure, so it wins bigger as data grows.
> Grid-stride does the reverse: it wins *most* at 4 MB, because the thing it fixes **is** launch
> overhead — one right-sized launch instead of a million threads doing one add each. By 4 G the
> bus is saturated and there is little left to win.
>
> A single-size table at 256 M would have reported 21.8× and 1.7× as *the* answers and hidden both
> trends. Worse, it would have made grid-stride look like the ladder's weakest rung when it is in
> fact the strongest one at the size most kernels actually run.

> **`:occupancy 2.0` — deliberately oversubscribed — is worth 8.5× at 1 M and 1.7× at 256 M**,
> measured rather than assumed. The same knob is neutral on matmul, which is why it is a chapter
> and not a default.

> **The `verified` column stops being ✅ above 16 M** — a host-reference sum of 4 G elements is
> minutes of CPU. Per `plan/benchmark-harness.md` §5, correctness is established at a small size
> and the large rows inherit it. The column says so rather than implying a check that did not
> happen.

### Precision — the full three-way sweep, at 256 M

This is the suite the sweep exists for. But it pays off on a different axis than expected, and the
two-column-per-flag layout is what makes that visible: **GB/s barely moves; the ANSWER moves a lot.**

| device | chapter | `fast` | `ieee` | `ieee+ftz` | speed spread | rel. error vs fp64 (`fast` → `ieee`) |
|---|---|---:|---:|---:|---:|---|
| H100 NVL | 3 grid-stride | 2910 | 2904 | 2911 | 0.2% | 3.1e-5 → 4.0e-7 (**78× better**) |
| H100 NVL | 1 SLM tree | 892 | 889 | 892 | 0.3% | 2.8e-7 → 1.2e-7 (2.3× better) |
| BMG | 3 grid-stride | 402 | 391 | 403 | 2.8% | 3.4e-5 → 4.2e-7 (**81× better**) |

> **Precision is nearly free here, and that is the finding.** A reduction is bandwidth-bound, so
> the flags cannot reach the bottleneck — `ieee` costs 0.2% on the H100. What it buys is **two
> orders of magnitude of accuracy** on the grid-stride chapter, whose long per-thread partial sums
> are where fp32 error accumulates. The tree reduction is already accurate, because its
> logarithmic depth is the numerically stable shape; it has less to gain.
>
> So the sweep's value is **not** a speed/accuracy trade-off — it is the discovery that on this
> suite there is barely a trade at all. A `fast`-only run would have quietly shipped 3.1e-5.
>
> This is precisely the comparison the matmul chapters cannot make: their MMA is tf32 whatever the
> flag says, which is why `plan/benchmark-harness.md` §1 makes the precision set a property of the
> chapter rather than of the runner.

## § 2 — Top Reduction Benchmarks

One table per platform, same columns.

### NVIDIA H100 NVL · captured 2026-08-20

| elements | bytes | Crisp | Control | **Peer** CUB | Ceiling cuBLAS `asum` | vs Peer |
|---:|---:|---:|---:|---:|---:|---:|
| 1 M | 4 MB | 402 (0.010) | 388 (0.011) | 445 (0.009) | 452 (0.009) | 0.90× |
| 16 M | 64 MB | 1,980 (0.034) | 1,900 (0.035) | 2,140 (0.031) | 2,190 (0.031) | 0.93× |
| 256 M | 1 GB | 2,910 (0.369) | 2,840 (0.378) | 3,050 (0.352) | 3,120 (0.344) | 0.95× |
| 4 G | 17 GB | 2,948 (5.83) | 2,870 (5.99) | 3,081 (5.58) | 3,140 (5.47) | 0.96× |

### Intel BMG · captured 2026-08-11

| elements | bytes | Crisp | Control | **Peer** oneDPL | Ceiling oneMKL | vs Peer |
|---:|---:|---:|---:|---:|---:|---:|
| 1 M | 4 MB | 88 (0.048) | 81 (0.052) | 96 (0.044) | 99 (0.042) | 0.92× |
| 16 M | 64 MB | 341 (0.197) | 322 (0.208) | 366 (0.183) | 378 (0.177) | 0.93× |
| 256 M | 1 GB | 402 (2.67) | 380 (2.82) | 428 (2.51) | 441 (2.43) | 0.94× |
| 4 G | 17 GB | n/a — exceeds 12 GB | n/a | n/a | n/a | — |

*Precision is covered once, in §1 above — the §2 kernel IS chapter 3, so a second
table here would restate the same three numbers.*

---

# Run provenance

| | |
|---|---|
| Crisp (this report) | `9bc20d4` |
| Crisp (H200 data) | `a41f0c2` ⚠ stale |
| CUDA toolkit / driver | 12.4 / 550.90 |
| cuBLAS / CUTLASS | 12.4.5 / 3.5.1 |
| oneAPI / oneMKL | 2025.1 / 2025.1 |
| H100 NVL | 132 SM, 94 GB |
| H200 | 132 SM, 141 GB |
| BMG | 20 Xe cores, 12 GB |

> **Ceiling numbers move with vendor versions.** Without this block a cuBLAS upgrade is
> indistinguishable from a Crisp regression.

---

# Appendix — runs excluded from every table above

Debug and exploratory runs are written to `benchmarks/results/scratch/`, which the report never
reads. Listed here only so they are not invisible.

| when | suite | why it was run | settings |
|---|---|---|---|
| 08-18 09:12 | matmul | endeavour 152 pod-time triage | `warmup=5 iters=30 sizes=1024,2048,4096` |
| 08-18 14:03 | matmul | multicast probe variants (`p_mc*`, `p_no*`) | `sizes=2048,4096` |
| 08-19 22:41 | reduction | single-size smoke test | `sizes=1M` |

> **The first row is a real incident.** During endeavour 152 a `warmup=5 iters=30` sweep produced
> numbers **8–18% below** house protocol and landed in the results directory indistinguishable
> from canonical data. It was nearly published. Debug runs now go to a directory the report cannot
> see, so the mistake is unavailable rather than merely detectable.
