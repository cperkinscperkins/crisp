# Crisp Benchmark Report

> Generated from verified test sweeps in `benchmarks/results/`.

| device | data captured | source | hardware profile |
|---|---|---|---|
| Intel(R) Graphics [0xe20b] | 2026-10-08 | Crisp `f894a8fd` (docker) | `bmg` (validated) |
| NVIDIA H100 NVL | 2026-10-06 | Crisp `dd7edf5e` (runpod) | `h100-nvl` (queried*) |

> \* **queried / supplied**: the profile's QUERIED keys were read off the device, but its MEASURED keys (`:tile-visit-strip-width` above all) were never swept for this part and are absent, which selects safe defaults rather than tuned ones. Such a row is honest about the hardware it ran on and fair to compare *within* the device; it may understate Crisp against a row whose profile was fully tuned. A **NONE** row was compiled with no profile at all and is not comparable to published figures.

---

# Suite: reduction

Row variable: **input size** (fp32 elements, shown in bytes). Headline metric is **GB/s of input read**, and **% of the device's MEASURED read peak** (`benchmarks/reduction/ceiling/read_bw.cpp`, never a spec sheet). Every point is verified twice: on the last timed launch, and on a relaunch over different data.

## § 1 — Reduction Ladder · Intel(R) Graphics [0xe20b] · sum fp32 · `fast`

Measured read peak **454.5 GB/s** (`Intel(R) Graphics [0xe20b]`, hash data). † fits in the 18.9 MB cache: that column measures cache, not memory, and can exceed 100%.

| # | step | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | max rel err |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | one atomic per element | 585 ms | 2 (0%) | 2 (0%) | 2 (0%) | *skipped* | *skipped* | *skipped* | 6.4e-03 |
| 1 | work-group tree in SLM, one atomic per group (hand) | 563 ms | 61 (13%) | 60 (13%) | 44 (10%) | 44 (10%) | 44 (10%) | 44 (10%) | 4.4e-04 |
| 2 | warp shuffles, one atomic per group (hand) | 615 ms | 89 (20%) | 85 (19%) | 54 (12%) | 53 (12%) | 53 (12%) | 54 (12%) | 4.3e-04 |
| 3 | + grid-stride: fixed grid, many elements per thread (hand) | 592 ms | 306 (67%) | 708 (156%) | 437 (96%) | 448 (99%) | 451 (99%) | 450 (99%) | 2.6e-07 |
| 3b | + unrolled x4: four loads in flight per thread (hand) | 625 ms | 325 (72%) | 752 (165%) | 439 (97%) | 449 (99%) | 451 (99%) | 450 (99%) | 2.1e-07 |
| 4 | `grid-reduce!` -- the language does Phase 1 + 2 | 633 ms | 140 (31%) | 966 (213%) | 416 (91%) | 441 (97%) | 448 (99%) | 449 (99%) | 7.5e-08 |
| 4 | `grid-reduce!` -- the language does Phase 1 + 2 — `sum_atomic` | 594 ms | 315 (69%) | 1270 (279%) | 438 (96%) | 449 (99%) | 451 (99%) | 450 (99%) | 2.0e-07 |
| 5 | `reduce-vec` -- the one-liner | 633 ms | 138 (30%) | 966 (213%) | 415 (91%) | 441 (97%) | 448 (99%) | 448 (99%) | 7.5e-08 |

## § 1b — Strategy Rollup · Intel(R) Graphics [0xe20b] · sum fp32 · `fast`

Every row has the same Phase 0 (`loop-vector-stride` fold) and the same grid (the hoist's occupancy formula, R=1 unless the kernel declares otherwise); rows differ only in how the per-thread partials are combined. Cells are **median kernel µs**; the fastest per size is bold.

| Phase 1 | Phase 2 | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** |
|---|---|---:|---:|---:|---:|---:|---:|
| `reduce-workgroup` | `:atomic` | **3.4** | 22.0 | **153.6** | **599.5** | **2383.6** | **7163.2** |
| `reduce-workgroup` | `:cas` | 1081.2 | 1094.5 | 1221.1 | 1661.2 | 3441.0 | 8217.7 |
| `reduce-workgroup` | `:last-man-standing` | 7.6 | **17.3** | 161.6 | 609.4 | 2393.9 | 7172.7 |
| `reduce-warp` | atomic per warp | 10.0 | 42.2 | 176.3 | 621.9 | 2406.7 | 7182.8 |
| `reduce-warp` | CAS per warp | 5340.9 | 5321.7 | 5509.0 | 5832.7 | 7354.5 | 11397.1 |

*second-stage* is not in the rollup yet: it needs two kernel launches, which the fixture's single-kernel plan cannot express.

## § 2 — Workloads and Contenders · Intel(R) Graphics [0xe20b] · fp32 · `fast`

Crisp's row is its language form (`reduce-vec` / `grid-reduce!` after a `loop-vector-stride` fold, grid from the occupancy policy). Contenders are timed by the HOST CLOCK around call-and-wait (a library call may launch several kernels and return no single event), so at small sizes their numbers include the submission overhead shown; Crisp is timed by its kernel timestamp -- small sizes are NOT a like-for-like comparison. **Device compile** = source to device IR (`crisp-compile`; `icpx -fsycl-device-only` / `nvcc -ptx`). Cells: GB/s of input read (% of measured peak).

### `argmax`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 651 ms | 100 (22%) | 638 (140%) | 405 (89%) | 437 (96%) | 448 (99%) | 450 (99%) | — |
| SYCL_Reduction | 1869 ms | 5 (1%) | 95 (21%) | 221 (49%) | 323 (71%) | 342 (75%) | 404 (89%) | 166 µs |
| oneDPL | 3277 ms | 14 (3%) | 192 (42%) | 291 (64%) | 330 (73%) | 402 (88%) | 433 (95%) | 82 µs |
| oneMKL | 2534 ms | 9 (2%) | 128 (28%) | 126 (28%) | 144 (32%) | 170 (37%) | 174 (38%) | 65 µs |

### `sum`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 629 ms | 140 (31%) | 955 (210%) | 414 (91%) | 440 (97%) | 449 (99%) | 444 (98%) | — |
| SYCL_Reduction | 1909 ms | 9 (2%) | 134 (30%) | 242 (53%) | 330 (73%) | 406 (89%) | 426 (94%) | 66 µs |
| oneDPL | 2903 ms | 12 (3%) | 237 (52%) | 298 (66%) | 331 (73%) | 417 (92%) | 438 (96%) | 73 µs |
| oneMKL | 2605 ms | 5 (1%) | 143 (31%) | 253 (56%) | 317 (70%) | 407 (90%) | 426 (94%) | 63 µs |

### `sum_sumsq`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 635 ms | 125 (28%) | 911 (201%) | 412 (91%) | 440 (97%) | 449 (99%) | 450 (99%) | — |
| SYCL_Reduction | 2006 ms | 14 (3%) | 203 (45%) | 277 (61%) | 321 (71%) | 396 (87%) | 429 (94%) | 65 µs |
| oneDPL | 2975 ms | 15 (3%) | 194 (43%) | 298 (66%) | 315 (69%) | 401 (88%) | 433 (95%) | 69 µs |
| oneMKL | 2699 ms | 6 (1%) | 93 (20%) | 155 (34%) | 179 (39%) | 211 (46%) | 219 (48%) | 67 µs |

### `welford`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 679 ms | 120 (26%) | 704 (155%) | 415 (91%) | 441 (97%) | 448 (99%) | 450 (99%) | — |
| SYCL_Reduction | 1850 ms | 7 (2%) | 108 (24%) | 225 (50%) | 340 (75%) | 348 (77%) | 419 (92%) | 133 µs |
| oneDPL | 2987 ms | 7 (2%) | 206 (45%) | 291 (64%) | 362 (80%) | 396 (87%) | 436 (96%) | 138 µs |

## § 1 — Reduction Ladder · NVIDIA H100 NVL · sum fp32 · `fast`

Measured read peak **3702.3 GB/s** (`NVIDIA H100 NVL`, hash data). † fits in the 62.9 MB cache: that column measures cache, not memory, and can exceed 100%.

| # | step | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **4 GiB** | max rel err |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | one atomic per element | 141 ms | 2 (0%) | 2 (0%) | 2 (0%) | *skipped* | *skipped* | *skipped* | 8.6e-05 |
| 1 | work-group tree in SLM, one atomic per group (hand) | 157 ms | 144 (4%) | 447 (12%) | 508 (14%) | 497 (13%) | 512 (14%) | 514 (14%) | 8.7e-04 |
| 2 | warp shuffles, one atomic per group (hand) | 167 ms | 148 (4%) | 454 (12%) | 509 (14%) | 497 (13%) | 512 (14%) | 514 (14%) | 8.7e-04 |
| 3 | + grid-stride: fixed grid, many elements per thread (hand) | 182 ms | 111 (3%) | 1432 (39%) | 1893 (51%) | 2248 (61%) | 2373 (64%) | 2428 (66%) | 1.0e-06 |
| 3b | + unrolled x4: four loads in flight per thread (hand) | 186 ms | 139 (4%) | 1513 (41%) | 2404 (65%) | 3223 (87%) | 3512 (95%) | 3536 (96%) | 5.3e-07 |
| 4 | `grid-reduce!` -- the language does Phase 1 + 2 | 192 ms | 99 (3%) | 1193 (32%) | 1161 (31%) | 1427 (39%) | 1515 (41%) | 1541 (42%) | 1.7e-08 |
| 4 | `grid-reduce!` -- the language does Phase 1 + 2 — `sum_atomic` | 210 ms | 114 (3%) | 1664 (45%) | 2394 (65%) | 3113 (84%) | 3360 (91%) | 3353 (91%) | 8.2e-07 |
| 5 | `reduce-vec` -- the one-liner | 188 ms | 89 (2%) | 1028 (28%) | 1135 (31%) | 1413 (38%) | 1516 (41%) | 1541 (42%) | 1.7e-08 |

## § 1b — Strategy Rollup · NVIDIA H100 NVL · sum fp32 · `fast`

Every row has the same Phase 0 (`loop-vector-stride` fold) and the same grid (the hoist's occupancy formula, R=1 unless the kernel declares otherwise); rows differ only in how the per-thread partials are combined. Cells are **median kernel µs**; the fastest per size is bold.

| Phase 1 | Phase 2 | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **4 GiB** |
|---|---|---:|---:|---:|---:|---:|---:|
| `reduce-workgroup` | `:atomic` | **7.5** | **9.6** | **26.8** | **84.9** | **319.2** | **1278.9** |
| `reduce-workgroup` | `:cas` | 11400.0 | 11426.3 | 11380.2 | 11525.8 | 11680.2 | 12608.4 |
| `reduce-workgroup` | `:last-man-standing` | 10.5 | 14.6 | 57.7 | 187.6 | 707.9 | 2785.0 |
| `reduce-warp` | atomic per warp | 16.7 | 18.7 | 35.8 | 92.8 | 328.0 | 1336.0 |
| `reduce-warp` | CAS per warp | 25282.1 | 24987.8 | 24977.8 | 25034.9 | 25533.3 | 26350.6 |

*second-stage* is not in the rollup yet: it needs two kernel launches, which the fixture's single-kernel plan cannot express.

## § 2 — Workloads and Contenders · NVIDIA H100 NVL · fp32 · `fast`

Crisp's row is its language form (`reduce-vec` / `grid-reduce!` after a `loop-vector-stride` fold, grid from the occupancy policy). Contenders are timed by cuda-events on the stream (Thrust: + its small host copy-back): stream-ordered events bracket every kernel a library launches, as Crisp's kernel is timed. **Device compile** = source to device IR (`crisp-compile`; `icpx -fsycl-device-only` / `nvcc -ptx`). Cells: GB/s of input read (% of measured peak).

### `argmax`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **4 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 237 ms | 88 (2%) | 1025 (28%) | 1270 (34%) | 1697 (46%) | 1861 (50%) | 1910 (52%) | — |
| CUB | 3653 ms | 106 (3%) | 1317 (36%) | 2301 (62%) | 3221 (87%) | 3577 (97%) | 3642 (98%) | 5 µs |
| Thrust | 3924 ms | 32 (1%) | 59 (2%) | 302 (8%) | 567 (15%) | 1521 (41%) | 2128 (57%) | 5 µs |
| cuBLAS | 1047 ms | 93 (3%) | 1031 (28%) | 1780 (48%) | 2360 (64%) | 2551 (69%) | 2574 (70%) | 4 µs |

### `sum`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **4 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 190 ms | 99 (3%) | 1124 (30%) | 1158 (31%) | 1428 (39%) | 1516 (41%) | 1540 (42%) | — |
| CUB | 2611 ms | 126 (3%) | 1301 (35%) | 2313 (62%) | 3338 (90%) | 3663 (99%) | 3745 (101%) | 5 µs |
| Thrust | 3518 ms | 38 (1%) | 87 (2%) | 323 (9%) | 1024 (28%) | 2257 (61%) | 3232 (87%) | 5 µs |
| cuBLAS | 1157 ms | 98 (3%) | 990 (27%) | 1715 (46%) | 2085 (56%) | 2308 (62%) | 2357 (64%) | 4 µs |

### `sum_sumsq`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **4 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 233 ms | 73 (2%) | 807 (22%) | 890 (24%) | 1114 (30%) | 1195 (32%) | 1217 (33%) | — |
| CUB | 2303 ms | 128 (3%) | 1369 (37%) | 2199 (59%) | 3279 (89%) | 3622 (98%) | 3684 (100%) | 5 µs |
| Thrust | 2337 ms | 25 (1%) | 45 (1%) | 173 (5%) | 1018 (27%) | 2251 (61%) | 3226 (87%) | 10 µs |
| cuBLAS | 1024 ms | 54 (1%) | 677 (18%) | 956 (26%) | 1251 (34%) | 1330 (36%) | 1306 (35%) | 4 µs |

### `welford`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **4 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 256 ms | 64 (2%) | 637 (17%) | 969 (26%) | 1308 (35%) | 1431 (39%) | 1464 (40%) | — |
| CUB | 2180 ms | 108 (3%) | 665 (18%) | 1613 (44%) | 2818 (76%) | 3251 (88%) | 2566 (69%) | 5 µs |
| Thrust | 2793 ms | 30 (1%) | 44 (1%) | 252 (7%) | 944 (26%) | 2118 (57%) | 2590 (70%) | 7 µs |


# Appendix — runs excluded from canonical tables

Debug and exploratory runs are written to `benchmarks/results/scratch/`, which the report never reads into canonical tables.

| timestamp | suite | chapter | competitor | sizes |
|---|---|---|---|---|
| 2026-10-04 01:11 | reduction | step4_grid_reduce__sum | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-04 01:11 | reduction | step4_grid_reduce__sum_atomic | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-04 01:13 | reduction | step4_grid_reduce__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 01:14 | reduction | step4_grid_reduce__sum_atomic | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 01:27 | reduction | _probe_loop__a_add_index | Crisp | `1MiB,64MiB` |
| 2026-10-04 01:27 | reduction | _probe_loop__b_four_acc | Crisp | `1MiB,64MiB` |
| 2026-10-04 01:28 | reduction | _probe_loop__a_add_index | Crisp | `256MiB,1024MiB` |
| 2026-10-04 01:28 | reduction | _probe_loop__b_four_acc | Crisp | `256MiB,1024MiB` |
| 2026-10-04 01:28 | reduction | step4_grid_reduce__sum_atomic | Crisp | `256MiB,1024MiB` |
| 2026-10-04 01:28 | reduction | step4_grid_reduce__sum_atomic | Crisp | `256MiB,1024MiB` |
| 2026-10-04 01:28 | reduction | step4_grid_reduce__sum_atomic | Crisp | `256MiB,1024MiB` |
| 2026-10-04 01:29 | reduction | step0_atomic_per_element__sum | Crisp | `1MiB,16MiB` |
| 2026-10-04 01:29 | reduction | step1_slm_tree__sum | Crisp | `1MiB,16MiB` |
| 2026-10-04 01:29 | reduction | step2_warp_shuffle__sum | Crisp | `1MiB,16MiB` |
| 2026-10-04 01:29 | reduction | step3_grid_stride__sum | Crisp | `1MiB,16MiB` |
| 2026-10-04 01:29 | reduction | step5_reduce_vec__sum | Crisp | `1MiB,16MiB` |
| 2026-10-04 01:30 | reduction | step3b_grid_stride_unrolled__sum | Crisp | `1MiB,64MiB` |
| 2026-10-04 01:39 | reduction | _probe_loop__a_add_index | Crisp | `256MiB,1024MiB,3072MiB` |
| 2026-10-04 01:39 | reduction | _probe_loop__b_four_acc | Crisp | `256MiB,1024MiB,3072MiB` |
| 2026-10-04 01:39 | reduction | _probe_loop__c_unroll_one_acc | Crisp | `256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:26 | reduction | _probe_unroll__f32_x1 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:26 | reduction | _probe_unroll__f32_x2 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:26 | reduction | _probe_unroll__f32_x4 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:26 | reduction | _probe_unroll__f32_x8 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:26 | reduction | _probe_unroll__f64_x1 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:27 | reduction | _probe_unroll__f64_x2 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:27 | reduction | _probe_unroll__f64_x4 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:27 | reduction | _probe_unroll__f64_x8 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:29 | reduction | _probe_unroll__f32_x1 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:29 | reduction | _probe_unroll__f32_x2 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:30 | reduction | _probe_unroll__f32_x4 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:30 | reduction | _probe_unroll__f32_x8 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:30 | reduction | _probe_unroll__f64_x1 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:30 | reduction | _probe_unroll__f64_x2 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:30 | reduction | _probe_unroll__f64_x4 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 02:30 | reduction | _probe_unroll__f64_x8 | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-04 03:03 | reduction | step4_grid_reduce__sum | Crisp | `16MiB` |
| 2026-10-04 23:28 | reduction | rollup__warp_atomic | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:28 | reduction | rollup__warp_cas | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:28 | reduction | rollup__wg_atomic | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:28 | reduction | rollup__wg_cas | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:29 | reduction | rollup__wg_last_man | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:29 | reduction | step0_atomic_per_element__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:29 | reduction | step1_slm_tree__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:29 | reduction | step2_warp_shuffle__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:29 | reduction | step3_grid_stride__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:29 | reduction | step3b_grid_stride_unrolled__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:29 | reduction | step4_grid_reduce__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:30 | reduction | step4_grid_reduce__sum_atomic | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:30 | reduction | step5_reduce_vec__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:30 | reduction | _probe_unroll__f32_x1 | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:30 | reduction | _probe_unroll__f32_x2 | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:30 | reduction | _probe_unroll__f32_x4 | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:30 | reduction | _probe_unroll__f32_x8 | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:31 | reduction | _probe_unroll__f64_x1 | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:31 | reduction | _probe_unroll__f64_x2 | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:31 | reduction | _probe_unroll__f64_x4 | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:31 | reduction | _probe_unroll__f64_x8 | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:37 | reduction | rollup__warp_atomic | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:37 | reduction | rollup__wg_atomic | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:37 | reduction | step3_grid_stride__sum | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:37 | reduction | step3b_grid_stride_unrolled__sum | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:37 | reduction | step4_grid_reduce__sum_atomic | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:38 | reduction | _probe_unroll__f32_x1 | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:38 | reduction | _probe_unroll__f32_x2 | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:38 | reduction | _probe_unroll__f32_x4 | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:38 | reduction | _probe_unroll__f32_x8 | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:38 | reduction | _probe_unroll__f64_x1 | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:38 | reduction | _probe_unroll__f64_x2 | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:38 | reduction | _probe_unroll__f64_x4 | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:39 | reduction | _probe_unroll__f64_x8 | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:39 | reduction | rollup__wg_last_man | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:39 | reduction | step4_grid_reduce__sum | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-04 23:39 | reduction | step5_reduce_vec__sum | Crisp | `1MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-06 04:31 | reduction | rollup__wg_last_man | Crisp | `16MiB,256MiB` |
| 2026-10-06 04:31 | reduction | step3b_grid_stride_unrolled__sum | Crisp | `16MiB,256MiB` |
| 2026-10-06 04:31 | reduction | step4_grid_reduce__sum | Crisp | `16MiB,256MiB` |
| 2026-10-06 04:31 | reduction | step4_grid_reduce__sum_atomic | Crisp | `16MiB,256MiB` |
| 2026-10-06 04:32 | reduction | rollup__warp_atomic | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:32 | reduction | step3b_grid_stride_unrolled__sum | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:32 | reduction | step4_grid_reduce__sum | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:33 | reduction | step4_grid_reduce__sum_atomic | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:33 | reduction | rollup__warp_atomic | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:33 | reduction | step3b_grid_stride_unrolled__sum | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:33 | reduction | step4_grid_reduce__sum | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:33 | reduction | step4_grid_reduce__sum_atomic | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:33 | reduction | rollup__warp_atomic | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:33 | reduction | step3b_grid_stride_unrolled__sum | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:33 | reduction | step4_grid_reduce__sum | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:33 | reduction | step4_grid_reduce__sum_atomic | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:33 | reduction | rollup__warp_atomic | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:33 | reduction | step3b_grid_stride_unrolled__sum | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:33 | reduction | step4_grid_reduce__sum | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:33 | reduction | step4_grid_reduce__sum_atomic | Crisp | `1MiB,16MiB,256MiB,1024MiB` |
| 2026-10-06 04:42 | reduction | workloads__argmax | Crisp | `1MiB,64MiB` |
| 2026-10-06 04:42 | reduction | workloads__sum_sumsq | Crisp | `1MiB,64MiB` |
| 2026-10-06 04:42 | reduction | workloads__welford | Crisp | `1MiB,64MiB` |
| 2026-10-08 01:51 | reduction | _probe_unroll_hint__hint_none | Crisp | `256MiB,1024MiB,4096MiB` |
| 2026-10-08 01:51 | reduction | _probe_unroll_hint__hint_off | Crisp | `256MiB,1024MiB,4096MiB` |
| 2026-10-08 01:52 | reduction | _probe_unroll_hint__hint_x2 | Crisp | `256MiB,1024MiB,4096MiB` |
| 2026-10-08 01:52 | reduction | _probe_unroll_hint__hint_x4 | Crisp | `256MiB,1024MiB,4096MiB` |
| 2026-10-08 01:52 | reduction | _probe_unroll_hint__hint_x8 | Crisp | `256MiB,1024MiB,4096MiB` |
| 2026-10-08 01:52 | reduction | step5_reduce_vec__sum | Crisp | `256MiB,1024MiB,4096MiB` |