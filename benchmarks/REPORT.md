# Crisp Benchmark Report

> Generated from verified test sweeps in `benchmarks/results/`.

| device | data captured | source | hardware profile |
|---|---|---|---|
| Intel(R) Graphics [0xe20b] | 2026-09-12 | Crisp `25f64059` (docker) | `bmg` (validated) |

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
| 1 | hand-rolled XMX coop-matrix | 0.1 | 0.5 | 1.7 | 1.7 | 1.9 | 1.7 | 1.6 |
| 2 | matrix-multiply-tile-stride | 0.1 | 0.5 | 1.7 | 1.7 | 1.7 | 1.7 | 1.6 |
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
| 256 | 0.1 (0.278) | 0.2 (0.202) | 0.72× | 0.85× |
| 512 | 0.5 (0.589) | 0.5 (0.497) | 0.84× | **2.97×** |
| 1024 | 1.7 (1.297) | 1.5 (1.394) | 1.07× | **10.82×** |
| 2048 | 1.7 (10.149) | 1.8 (9.387) | 0.92× | **12.20×** |
| 4096 | 1.9 (73.933) | 2.0 (67.427) | 0.91× | **14.85×** |
| 8192 | 1.7 (649.091) | 2.1 (512.207) | 0.79× | **24.10×** |
| 16384 | 1.6 (5444.190) | — | — | — |

#### Ch 2 — What does tiling buy?
matrix-multiply-tile-stride

| N | Crisp TFLOPS (ms) | Control TFLOPS (ms) | vs Control | vs ch 1 |
|---:|---:|---:|---:|---:|
| 256 | 0.1 (0.278) | 1.3 (0.026) | 0.09× | 1.00× |
| 512 | 0.5 (0.589) | 1.5 (0.184) | 0.31× | 1.00× |
| 1024 | 1.7 (1.290) | 1.5 (1.404) | 1.09× | 1.01× |
| 2048 | 1.7 (10.136) | 1.4 (12.082) | 1.19× | 1.00× |
| 4096 | 1.7 (78.690) | 1.3 (104.985) | 1.33× | 0.94× |
| 8192 | 1.7 (661.082) | 1.3 (844.365) | 1.28× | 0.98× |
| 16384 | 1.6 (5485.950) | — | — | 0.99× |

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
| 4096 | 13.5 (10.218) | 21.1 (6.522) | 0.64× | **7.70×** |
| 8192 | 11.8 (93.357) | 6.7 (164.532) | **1.76×** | **7.08×** |
| 16384 | 13.2 (668.724) | 6.1 (1449.499) | **2.17×** | **8.20×** |

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

## § 1b — The Technique Ladder in 16-bit · Intel(R) Graphics [0xe20b]

*The same chapters as section 1, in bfloat16. Each kernel is its tf32 twin with two things changed: the operand element type, and the K step 8 → 16 (the native XMX shape for 16-bit operands is (8 16 16), not (8 16 8)). The C accumulator stays f32 in both.*

Cells read **bf16 TFLOPS (× vs the same chapter in tf32)**. The 32-bit baseline is **tf32 on XMX**, not fp32 on the vector engines — the BMG shape ladder is (8 16 8) tf32, (8 16 16) bf16, (8 16 32) int8, i.e. same M×N with K doubling per step. No Control/Peer/Ceiling columns: the chapter SYCL controls are tf32 only, so this is a Crisp-vs-Crisp ladder.

| chapter | N=256 | N=512 | N=1024 | N=2048 | N=4096 | N=8192 | N=16384 |
|---|---:|---:|---:|---:|---:|---:|---:|
| Ch 0 naive (no XMX) | 0.1 (1.01×) | 0.2 (1.18×) | 0.1 (0.97×) | 0.1 (1.05×) | 0.1 (1.17×) | 0.1 (**1.84×**) | — |
| Ch 1 hand-rolled MMA | 0.2 (1.76×) | 0.8 (1.78×) | 2.4 (1.45×) | 2.5 (1.47×) | 2.2 (1.18×) | 1.9 (1.13×) | 1.6 (0.99×) |
| Ch 2 tiling macro | 0.2 (1.76×) | 0.8 (1.78×) | 2.4 (1.45×) | 2.5 (1.47×) | 2.2 (1.26×) | 1.9 (1.15×) | 1.6 (1.00×) |
| Ch 3 async staging | 0.0 (**2.55×**) | 0.0 (**2.55×**) | 0.0 (**2.56×**) | 0.0 (**2.59×**) | 0.0 (tf32 n/a) | — | — |
| Ch 4 register-resident | 4.7 (1.59×) | 20.6 (1.72×) | 48.1 (**2.00×**) | 38.2 (**2.30×**) | 26.7 (**1.99×**) | 26.3 (**2.23×**) | 26.9 (**2.04×**) |
| Ch 5 ring + prefetch | 5.3 (1.54×) | 15.7 (1.56×) | 39.6 (1.78×) | 49.7 (1.77×) | 31.4 (**1.82×**) | 22.1 (1.74×) | 15.0 (**2.27×**) |

## § 2 — Top MMA Benchmarks

*How does Crisp actually stand?* Best mainloop against **all three contender classes**.

### Intel(R) Graphics [0xe20b] · tf32 · `fast`

| N | Crisp | Control<br>SYCL_Apples | **Peer**<br>SYCL-TLA | Ceiling<br>oneMKL | vs Peer | vs Ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 3.4 (0.010) `chap5_multistage_ring` | 1.9 (0.017) | N/A* | 5.3 (0.006) | — | 65% |
| 512 | 12.0 (0.022) `chap4_cheap_fetch` | 14.3 (0.019) | N/A* | 9.8 (0.027) | — | 122% |
| 1024 | 32.2 (0.067) `sec2_top` | 11.5 (0.186) | N/A* | 12.0 (0.178) | — | **268%** |
| 2048 | 31.1 (0.553) `sec2_top` | 12.6 (1.363) | N/A* | 13.8 (1.245) | — | **225%** |
| 4096 | 22.6 (6.088) `sec2_top` | 10.4 (13.254) | N/A* | — | — | — |
| 8192 | 16.4 (67.011) `sec2_top` | 8.2 (133.396) | N/A* | 14.2 (77.557) | — | 116% |
| 16384 | 13.2 (668.724) `chap4_cheap_fetch` | 6.1 (1449.499) | N/A* | — | — | — |

> *\*Note: SYCL-TLA does not implement TF32 DPAS on Xe2 (only BF16/FP16/FP8). See §2.1 below for the native 270+ TFLOPS BF16 suite.*

> *Reading **vs Ceiling** at tf32: oneMKL is requested at tf32, but its best tf32 point here is 14.2 TFLOPS against 114.6 for its own bf16 path. That gap suggests oneMKL's tf32 does not run on the matrix engines on Xe2 (as SYCL-TLA's does not), so a cell above 100% is Crisp against oneMKL's tf32 path, not against the hardware limit. Unconfirmed; the bf16 table is the like-for-like ceiling comparison.*


<details><summary><b>Compilation & Build Overhead</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 719 ms | 721 ms | 1.00× |
| **SYCL_Apples** | Control | 1.77 s | 4.02 s | **2.5× slower** |

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
| 256 | 3.6 (0.009) `pfw2` | 2.9 | 2.2 (0.015) | 0.5 (0.074) | 9.8 (0.003) | **8.01×** | 37% |
| 512 | 19.0 (0.014) `pfw2` | 15.3 | 8.2 (0.033) | 3.3 (0.082) | 41.0 (0.007) | **5.80×** | 46% |
| 1024 | 73.7 (0.029) `wg256xepf2` | 73.7 | 16.5 (0.130) | 23.7 (0.091) | 75.4 (0.029) | **3.12×** | 98% |
| 2048 | 81.9 (0.210) `wg256xepf2` | 81.9 | 19.0 (0.907) | 62.9 (0.273) | 88.4 (0.194) | 1.30× | 93% |
| 4096 | 107.5 (1.278) `wg256xepf2` | 107.5 | 18.9 (7.262) | 87.3 (1.574) | 110.9 (1.240) | 1.23× | 97% |
| 8192 | 111.1 (9.899) `wg256xepf2` | 111.1 | 16.1 (68.463) | 91.0 (12.089) | 111.6 (9.853) | 1.22× | 100% |
| 16384 | 77.2 (113.970) `wg256xe` | 56.6 | 11.3 (780.846) | 91.7 (95.887) | 110.9 (79.329) | 0.84× | 70% |

> **⚠ SIGN FLIPS — these variants reverse with problem size.**
> Each wins somewhere and loses somewhere, both beyond the measured run-to-run
> spread, so a single fixed choice is not available and the envelope above is
> assembled from *different kernels*. Picking by one size will mislead you at another.

> | variant | wins at | loses at |
> |---|---|---|
> | `pfw1` | 256 (+7%), 512 (+12%), 2048 (+12%), 4096 (+29%) | **8192 (-17%)**, **16384 (-80%)** |
> | `pfw2` | 256 (+9%), 512 (+15%), 2048 (+12%), 4096 (+28%) | **8192 (-18%)**, **16384 (-80%)** |
> | `pfw3` | 256 (+8%), 512 (+12%), 2048 (+10%), 4096 (+26%) | **8192 (-15%)**, **16384 (-81%)** |
> | `pfw4` | 256 (+7%), 512 (+11%), 2048 (+8%), 4096 (+23%) | **8192 (-5%)**, **16384 (-81%)** |
> | `wg256` | 1024 (+2%) | **256 (-17%)**, **512 (-15%)**, **2048 (-9%)**, **4096 (-10%)**, **8192 (-7%)**, **16384 (-8%)** |
> | `wg256pf1` | 2048 (+10%), 4096 (+27%), 8192 (+35%) | **256 (-22%)**, **512 (-17%)**, **1024 (-2%)**, **16384 (-54%)** |
> | `wg256pf2` | 2048 (+10%), 4096 (+25%), 8192 (+34%) | **256 (-22%)**, **512 (-17%)**, **1024 (-3%)**, **16384 (-64%)** |
> | `wg256pf2cc` | 2048 (+9%), 4096 (+26%), 8192 (+34%) | **256 (-22%)**, **512 (-18%)**, **1024 (-3%)**, **16384 (-64%)** |
> | `wg256xe` | 1024 (+10%), 2048 (+8%), 4096 (+9%), 8192 (+15%), 16384 (+12%) | **256 (-11%)**, **512 (-5%)** |
> | `wg256xepf2` | 1024 (+13%), 2048 (+28%), 4096 (+49%), 8192 (+60%) | **256 (-13%)**, **512 (-7%)**, **16384 (-18%)** |


<details><summary><b>Compilation & Build Overhead (FP16)</b></summary>

| contender | class | device codegen (SPIR-V) | total build | **vs Crisp codegen** |
|---|---|---:|---:|---:|
| **Crisp** | Crisp | 886 ms | 887 ms | 1.00× |
| **SYCL_Apples_FP16** | Control | 1.71 s | 3.86 s | **1.9× slower** |
| **SYCL-TLA_FP16** | Peer | 28.11 s | 53.12 s | **31.7× slower** |
| **oneMKL_FP16** | Ceiling | *precompiled* | 6.29 s | — |

</details>

## § 3 — Situational Techniques

*Techniques whose honest answer is "it depends."* Controlled pairs:

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

## § 5 — Scaling Out

| topic | status |
|---|---|
| Out of core (stream from host) | candidate for 1.0 |
| Hardware multi-tile (PVC 2T/4T) | deferred — needs `def-topology` |
| Multi-GPU | deferred — needs `def-topology` + `def-orchestration` |


# Appendix — runs excluded from canonical tables

Debug and exploratory runs are written to `benchmarks/results/scratch/`, which the report never reads into canonical tables.

*No scratch runs present.*