# Crisp Benchmark Report

> Generated from verified test sweeps in `benchmarks/results/`.

| device | data captured | source | hardware profile |
|---|---|---|---|
| Intel(R) Graphics [0xe20b] | 2026-10-08 | Crisp `4d2a91de` (docker) | `bmg` (validated) |
| NVIDIA H100 80GB HBM3 | 2026-10-08 | Crisp `75d13e22` (runpod) | `h100-sxm` (supplied*) |

> \* **queried / supplied**: the profile's QUERIED keys were read off the device, but its MEASURED keys (`:tile-visit-strip-width` above all) were never swept for this part and are absent, which selects safe defaults rather than tuned ones. Such a row is honest about the hardware it ran on and fair to compare *within* the device; it may understate Crisp against a row whose profile was fully tuned. A **NONE** row was compiled with no profile at all and is not comparable to published figures.

---

# Suite: reduction

Row variable: **input size** (fp32 elements, shown in bytes). Headline metric is **GB/s of input read**, and **% of the device's MEASURED read peak** (`benchmarks/reduction/ceiling/read_bw.cpp`, never a spec sheet). Every point is verified twice: on the last timed launch, and on a relaunch over different data.

## § 1 — Reduction Ladder · Intel(R) Graphics [0xe20b] · sum fp32 · `fast`

Measured read peak **454.5 GB/s** (`Intel(R) Graphics [0xe20b]`, hash data). † fits in the 18.9 MB cache: that column measures cache, not memory, and can exceed 100%.

| # | step | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | max rel err |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | one atomic per element | 582 ms | 2 (0%) | 2 (1%) | 2 (1%) | *skipped* | *skipped* | *skipped* | 3.1e-03 |
| 1 | work-group tree in SLM, one atomic per group (hand) | 600 ms | 61 (13%) | 60 (13%) | 44 (10%) | 44 (10%) | 44 (10%) | 44 (10%) | 4.3e-04 |
| 2 | warp shuffles, one atomic per group (hand) | 593 ms | 89 (20%) | 85 (19%) | 53 (12%) | 54 (12%) | 54 (12%) | 54 (12%) | 4.3e-04 |
| 3 | + grid-stride: fixed grid, many elements per thread (hand) | 594 ms | 306 (67%) | 1083 (238%) | 437 (96%) | 448 (99%) | 450 (99%) | 450 (99%) | 2.1e-07 |
| 3b | + unrolled x4: four loads in flight per thread (hand) | 608 ms | 325 (72%) | 1367 (301%) | 439 (97%) | 448 (99%) | 450 (99%) | 449 (99%) | 2.1e-07 |
| 4 | `grid-reduce!` -- the language does Phase 1 + 2 | 635 ms | 136 (30%) | 845 (186%) | 415 (91%) | 441 (97%) | 449 (99%) | 449 (99%) | 7.5e-08 |
| 4 | `grid-reduce!` -- the language does Phase 1 + 2 — `sum_atomic` | 598 ms | 310 (68%) | 1097 (241%) | 437 (96%) | 448 (99%) | 450 (99%) | 450 (99%) | 1.4e-07 |
| 5 | `reduce-vec` -- the one-liner | 613 ms | 136 (30%) | 845 (186%) | 414 (91%) | 441 (97%) | 448 (99%) | 449 (99%) | 7.5e-08 |

## § 1b — Strategy Rollup · Intel(R) Graphics [0xe20b] · sum fp32 · `fast`

Every row has the same Phase 0 (`loop-vector-stride` fold) and the same grid (the hoist's occupancy formula, R=1 unless the kernel declares otherwise); rows differ only in how the per-thread partials are combined. Cells are **median kernel µs**; the fastest per size is bold.

| Phase 1 | Phase 2 | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** |
|---|---|---:|---:|---:|---:|---:|---:|
| `reduce-workgroup` | `:atomic` | **3.3** | **15.4** | **153.7** | **598.7** | **2382.8** | **7160.7** |
| `reduce-workgroup` | `:cas` | 1081.1 | 1091.0 | 1222.3 | 1660.9 | 3437.4 | 8210.8 |
| `reduce-workgroup` | `:last-man-standing` | 7.7 | 20.2 | 161.5 | 609.2 | 2393.2 | 7170.1 |
| `reduce-warp` | atomic per warp | 9.8 | 28.3 | 176.6 | 621.3 | 2404.9 | 7179.3 |
| `reduce-warp` | CAS per warp | 5302.9 | 5414.3 | 5531.4 | 5839.6 | 7376.4 | 11437.2 |

*second-stage* is not in the rollup yet: it needs two kernel launches, which the fixture's single-kernel plan cannot express.

## § 2 — Workloads and Contenders · Intel(R) Graphics [0xe20b] · fp32 · `fast`

Crisp's row is its language form (`reduce-vec` / `grid-reduce!` after a `loop-vector-stride` fold, grid from the occupancy policy). Contenders are timed by the HOST CLOCK around call-and-wait (a library call may launch several kernels and return no single event), so at small sizes their numbers include the submission overhead shown; Crisp is timed by its kernel timestamp -- small sizes are NOT a like-for-like comparison. **Device compile** = source to device IR (`crisp-compile`; `icpx -fsycl-device-only` / `nvcc -ptx`). Cells: GB/s of input read (% of measured peak).

### `argmax`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 639 ms | 94 (21%) | 661 (145%) | 405 (89%) | 437 (96%) | 448 (99%) | 450 (99%) | — |
| SYCL_Reduction | 1869 ms | 5 (1%) | 95 (21%) | 221 (49%) | 323 (71%) | 342 (75%) | 404 (89%) | 166 µs |
| oneDPL | 3277 ms | 14 (3%) | 192 (42%) | 291 (64%) | 330 (73%) | 402 (88%) | 433 (95%) | 82 µs |
| oneMKL | 2534 ms | 9 (2%) | 128 (28%) | 126 (28%) | 144 (32%) | 170 (37%) | 174 (38%) | 65 µs |

### `sum`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 621 ms | 136 (30%) | 836 (184%) | 416 (92%) | 441 (97%) | 449 (99%) | 449 (99%) | — |
| SYCL_Reduction | 1909 ms | 9 (2%) | 134 (30%) | 242 (53%) | 330 (73%) | 406 (89%) | 426 (94%) | 66 µs |
| oneDPL | 2903 ms | 12 (3%) | 237 (52%) | 298 (66%) | 331 (73%) | 417 (92%) | 438 (96%) | 73 µs |
| oneMKL | 2605 ms | 5 (1%) | 143 (31%) | 253 (56%) | 317 (70%) | 407 (90%) | 426 (94%) | 63 µs |

### `sum_sumsq`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 639 ms | 134 (30%) | 832 (183%) | 413 (91%) | 440 (97%) | 449 (99%) | 449 (99%) | — |
| SYCL_Reduction | 2006 ms | 14 (3%) | 203 (45%) | 277 (61%) | 321 (71%) | 396 (87%) | 429 (94%) | 65 µs |
| oneDPL | 2975 ms | 15 (3%) | 194 (43%) | 298 (66%) | 315 (69%) | 401 (88%) | 433 (95%) | 69 µs |
| oneMKL | 2699 ms | 6 (1%) | 93 (20%) | 155 (34%) | 179 (39%) | 211 (46%) | 219 (48%) | 67 µs |

### `welford`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 632 ms | 115 (25%) | 661 (145%) | 413 (91%) | 440 (97%) | 448 (99%) | 449 (99%) | — |
| SYCL_Reduction | 1850 ms | 7 (2%) | 108 (24%) | 225 (50%) | 340 (75%) | 348 (77%) | 419 (92%) | 133 µs |
| oneDPL | 2987 ms | 7 (2%) | 206 (45%) | 291 (64%) | 362 (80%) | 396 (87%) | 436 (96%) | 138 µs |

## § 1 — Reduction Ladder · NVIDIA H100 80GB HBM3 · sum fp32 · `fast`

Measured read peak **3178.5 GB/s** (`NVIDIA H100 80GB HBM3`, hash data). † fits in the 52.4 MB cache: that column measures cache, not memory, and can exceed 100%.

| # | step | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **4 GiB** | max rel err |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | one atomic per element | 97 ms | 2 (0%) | 2 (0%) | 2 (0%) | *skipped* | *skipped* | *skipped* | 3.7e-05 |
| 1 | work-group tree in SLM, one atomic per group (hand) | 106 ms | 147 (5%) | 486 (15%) | 554 (17%) | 560 (18%) | 522 (16%) | 558 (18%) | 8.8e-04 |
| 2 | warp shuffles, one atomic per group (hand) | 104 ms | 152 (5%) | 487 (15%) | 555 (17%) | 560 (18%) | 522 (16%) | 558 (18%) | 8.5e-04 |
| 3 | + grid-stride: fixed grid, many elements per thread (hand) | 108 ms | 161 (5%) | 1949 (61%) | 2423 (76%) | 2943 (93%) | 3102 (98%) | 3101 (98%) | 3.5e-07 |
| 3b | + unrolled x4: four loads in flight per thread (hand) | 122 ms | 153 (5%) | 1928 (61%) | 2294 (72%) | 2863 (90%) | 3068 (97%) | 3114 (98%) | 4.2e-07 |
| 4 | `grid-reduce!` -- the language does Phase 1 + 2 | 127 ms | 81 (3%) | 1049 (33%) | 1687 (53%) | 2580 (81%) | 2980 (94%) | 3056 (96%) | 1.7e-08 |
| 4 | `grid-reduce!` -- the language does Phase 1 + 2 — `sum_atomic` | 115 ms | 156 (5%) | 1928 (61%) | 2356 (74%) | 2908 (91%) | 3073 (97%) | 3081 (97%) | 5.4e-07 |
| 5 | `reduce-vec` -- the one-liner | 128 ms | 81 (3%) | 1049 (33%) | 1695 (53%) | 2581 (81%) | 2979 (94%) | 3055 (96%) | 1.7e-08 |

## § 1b — Strategy Rollup · NVIDIA H100 80GB HBM3 · sum fp32 · `fast`

Every row has the same Phase 0 (`loop-vector-stride` fold) and the same grid (the hoist's occupancy formula, R=1 unless the kernel declares otherwise); rows differ only in how the per-thread partials are combined. Cells are **median kernel µs**; the fastest per size is bold.

| Phase 1 | Phase 2 | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **4 GiB** |
|---|---|---:|---:|---:|---:|---:|---:|
| `reduce-workgroup` | `:atomic` | **6.8** | **8.6** | **28.8** | **92.4** | 349.3 | 1394.1 |
| `reduce-workgroup` | `:cas` | 7840.7 | 7870.6 | 7830.6 | 8033.1 | 8222.1 | 9036.9 |
| `reduce-workgroup` | `:last-man-standing` | 13.0 | 16.0 | 39.6 | 103.9 | 360.3 | 1406.0 |
| `reduce-warp` | atomic per warp | 14.3 | 16.0 | 34.0 | 95.2 | **349.3** | **1392.7** |
| `reduce-warp` | CAS per warp | 28011.8 | 28271.6 | 28176.8 | 28386.7 | 28708.9 | 29088.8 |

*second-stage* is not in the rollup yet: it needs two kernel launches, which the fixture's single-kernel plan cannot express.

## § 2 — Workloads and Contenders · NVIDIA H100 80GB HBM3 · fp32 · `fast`

Crisp's row is its language form (`reduce-vec` / `grid-reduce!` after a `loop-vector-stride` fold, grid from the occupancy policy). Contenders are timed by cuda-events on the stream (Thrust: + its small host copy-back): stream-ordered events bracket every kernel a library launches, as Crisp's kernel is timed. **Device compile** = source to device IR (`crisp-compile`; `icpx -fsycl-device-only` / `nvcc -ptx`). Cells: GB/s of input read (% of measured peak).

### `argmax`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **4 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 141 ms | 61 (2%) | 696 (22%) | 1478 (47%) | 2384 (75%) | 2910 (92%) | 3072 (97%) | — |
| CUB | 2018 ms | 129 (4%) | 1529 (48%) | 2159 (68%) | 2835 (89%) | 3091 (97%) | 3128 (98%) | 5 µs |
| Thrust | 2623 ms | 37 (1%) | 97 (3%) | 343 (11%) | 942 (30%) | 1650 (52%) | 2048 (64%) | 5 µs |
| cuBLAS | 882 ms | 99 (3%) | 1268 (40%) | 1764 (55%) | 2305 (73%) | 2483 (78%) | 2514 (79%) | 5 µs |

### `sum`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **4 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 127 ms | 81 (3%) | 1049 (33%) | 1691 (53%) | 2576 (81%) | 2982 (94%) | 3054 (96%) | — |
| CUB | 1851 ms | 137 (4%) | 1613 (51%) | 2289 (72%) | 2897 (91%) | 3140 (99%) | 3190 (100%) | 5 µs |
| Thrust | 1998 ms | 43 (1%) | 101 (3%) | 365 (11%) | 1076 (34%) | 2164 (68%) | 2854 (90%) | 5 µs |
| cuBLAS | 875 ms | 105 (3%) | 1332 (42%) | 1744 (55%) | 2165 (68%) | 2302 (72%) | 2335 (73%) | 5 µs |

### `sum_sumsq`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **4 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 148 ms | 62 (2%) | 698 (22%) | 1510 (48%) | 2450 (77%) | 2930 (92%) | 3037 (96%) | — |
| CUB | 1831 ms | 135 (4%) | 1636 (51%) | 2202 (69%) | 2861 (90%) | 3102 (98%) | 3133 (99%) | 5 µs |
| Thrust | 2153 ms | 43 (1%) | 101 (3%) | 356 (11%) | 1068 (34%) | 2137 (67%) | 2843 (89%) | 5 µs |
| cuBLAS | 885 ms | 60 (2%) | 755 (24%) | 979 (31%) | 1216 (38%) | 1296 (41%) | 1315 (41%) | 5 µs |

### `welford`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **4 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 149 ms | 45 (1%) | 568 (18%) | 1349 (42%) | 2286 (72%) | 2868 (90%) | 3055 (96%) | — |
| CUB | 1914 ms | 116 (4%) | 819 (26%) | 1764 (55%) | 2612 (82%) | 3031 (95%) | 3146 (99%) | 5 µs |
| Thrust | 2422 ms | 41 (1%) | 96 (3%) | 339 (11%) | 1027 (32%) | 2094 (66%) | 2817 (89%) | 5 µs |


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
| 2026-10-08 15:45 | reduction | rollup__warp_atomic | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-08 15:45 | reduction | rollup__warp_cas | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-08 15:45 | reduction | rollup__wg_atomic | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-08 15:45 | reduction | rollup__wg_cas | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-08 15:46 | reduction | rollup__warp_atomic | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:46 | reduction | rollup__wg_last_man | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-08 15:46 | reduction | step4_grid_reduce__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-08 15:46 | reduction | rollup__warp_cas | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:46 | reduction | step4_grid_reduce__sum_atomic | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-08 15:46 | reduction | rollup__wg_atomic | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:46 | reduction | step5_reduce_vec__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-08 15:46 | reduction | rollup__wg_cas | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:46 | reduction | workloads__argmax | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-08 15:46 | reduction | rollup__wg_last_man | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:47 | reduction | workloads__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-08 15:47 | reduction | step3b_grid_stride_unrolled__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:47 | reduction | workloads__sum_sumsq | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-08 15:47 | reduction | step4_grid_reduce__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:47 | reduction | workloads__welford | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-08 15:47 | reduction | step4_grid_reduce__sum_atomic | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:47 | reduction | step5_reduce_vec__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:47 | reduction | workloads__argmax | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:47 | reduction | workloads__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:48 | reduction | workloads__sum_sumsq | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:48 | reduction | workloads__welford | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:48 | reduction | workloads__argmax | CUB | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:48 | reduction | rollup__wg_atomic | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-08 15:48 | reduction | workloads__sum | CUB | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:48 | reduction | rollup__wg_last_man | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-08 15:49 | reduction | workloads__sum_sumsq | CUB | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:49 | reduction | workloads__argmax | Crisp | `64MiB,256MiB,1024MiB,3072MiB` |
| 2026-10-08 15:49 | reduction | workloads__welford | CUB | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:49 | reduction | workloads__argmax | cuBLAS | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:49 | reduction | workloads__sum | cuBLAS | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:50 | reduction | workloads__sum_sumsq | cuBLAS | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:50 | reduction | workloads__argmax | Thrust | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:50 | reduction | workloads__sum | Thrust | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:51 | reduction | _probe_lastman__a_full | Crisp | `64MiB,256MiB,1024MiB` |
| 2026-10-08 15:51 | reduction | _probe_lastman__b_no_fence | Crisp | `64MiB,256MiB,1024MiB` |
| 2026-10-08 15:51 | reduction | _probe_lastman__c_atomic_fence | Crisp | `64MiB,256MiB,1024MiB` |
| 2026-10-08 15:51 | reduction | rollup__wg_atomic | Crisp | `64MiB,256MiB,1024MiB` |
| 2026-10-08 15:51 | reduction | workloads__sum_sumsq | Thrust | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 15:51 | reduction | rollup__wg_last_man | Crisp | `64MiB,256MiB,1024MiB` |
| 2026-10-08 15:51 | reduction | workloads__welford | Thrust | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 16:00 | reduction | _probe_lm_unroll__at_none | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 16:00 | reduction | _probe_lm_unroll__at_u4 | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 16:00 | reduction | _probe_lm_unroll__lm_none | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 16:00 | reduction | _probe_lm_unroll__lm_u2 | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 16:00 | reduction | _probe_lm_unroll__lm_u4 | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 16:00 | reduction | _probe_lm_unroll__lm_u8 | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 16:02 | reduction | rollup__wg_atomic | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 16:02 | reduction | rollup__wg_last_man | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 16:02 | reduction | step4_grid_reduce__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 16:02 | reduction | step4_grid_reduce__sum_atomic | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 16:02 | reduction | step5_reduce_vec__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 16:03 | reduction | workloads__argmax | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 16:03 | reduction | workloads__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 16:03 | reduction | workloads__sum_sumsq | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 16:03 | reduction | workloads__welford | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:13 | reduction | rollup__wg_atomic | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:13 | reduction | step5_reduce_vec__sum | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:13 | reduction | workloads__argmax | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:13 | reduction | workloads__sum | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:13 | reduction | workloads__sum_sumsq | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:13 | reduction | workloads__welford | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:14 | reduction | rollup__wg_atomic | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:14 | reduction | step5_reduce_vec__sum | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:14 | reduction | workloads__argmax | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:14 | reduction | workloads__sum | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:14 | reduction | workloads__sum_sumsq | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:14 | reduction | workloads__welford | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:14 | reduction | rollup__wg_atomic | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:15 | reduction | step5_reduce_vec__sum | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:15 | reduction | workloads__argmax | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:15 | reduction | workloads__sum | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:15 | reduction | workloads__sum_sumsq | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:15 | reduction | workloads__welford | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:15 | reduction | rollup__wg_atomic | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:15 | reduction | step5_reduce_vec__sum | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:16 | reduction | workloads__argmax | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:16 | reduction | workloads__sum | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:16 | reduction | workloads__sum_sumsq | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 17:16 | reduction | workloads__welford | Crisp | `64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 19:00 | reduction | rollup__wg_atomic | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 19:00 | reduction | rollup__wg_last_man | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 19:00 | reduction | step4_grid_reduce__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 19:00 | reduction | step4_grid_reduce__sum_atomic | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 19:01 | reduction | step5_reduce_vec__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 19:01 | reduction | workloads__argmax | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 19:01 | reduction | workloads__sum | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 19:01 | reduction | workloads__sum_sumsq | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 19:01 | reduction | workloads__welford | Crisp | `1MiB,16MiB,64MiB,256MiB,1024MiB,4096MiB` |
| 2026-10-08 19:02 | reduction | rollup__wg_atomic | Crisp | `1024MiB,4096MiB` |
| 2026-10-08 19:02 | reduction | step5_reduce_vec__sum | Crisp | `1024MiB,4096MiB` |
| 2026-10-08 19:02 | reduction | workloads__argmax | Crisp | `1024MiB,4096MiB` |
| 2026-10-08 19:03 | reduction | workloads__sum | Crisp | `1024MiB,4096MiB` |
| 2026-10-08 19:03 | reduction | workloads__sum_sumsq | Crisp | `1024MiB,4096MiB` |
| 2026-10-08 19:03 | reduction | workloads__welford | Crisp | `1024MiB,4096MiB` |