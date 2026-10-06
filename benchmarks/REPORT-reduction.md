# Crisp Benchmark Report

> Generated from verified test sweeps in `benchmarks/results/`.

| device | data captured | source | hardware profile |
|---|---|---|---|
| Intel(R) Graphics [0xe20b] | 2026-10-06 | Crisp `56cb083b` (docker) | `bmg` (validated) |

---

# Suite: reduction

Row variable: **input size** (fp32 elements, shown in bytes). Headline metric is **GB/s of input read**, and **% of the device's MEASURED read peak** (`benchmarks/reduction/ceiling/read_bw.cpp`, never a spec sheet). Every point is verified twice: on the last timed launch, and on a relaunch over different data.

## § 1 — Reduction Ladder · Intel(R) Graphics [0xe20b] · sum fp32 · `fast`

Measured read peak **454.5 GB/s** (`Intel(R) Graphics [0xe20b]`, hash data). † fits in the 18.9 MB cache: that column measures cache, not memory, and can exceed 100%.

| # | step | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | max rel err |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | one atomic per element | 578 ms | 2 (0%) | 2 (1%) | 2 (1%) | *skipped* | *skipped* | *skipped* | 4.2e-03 |
| 1 | work-group tree in SLM, one atomic per group (hand) | 563 ms | 61 (13%) | 59 (13%) | 44 (10%) | 44 (10%) | 44 (10%) | 44 (10%) | 4.6e-04 |
| 2 | warp shuffles, one atomic per group (hand) | 585 ms | 89 (20%) | 73 (16%) | 53 (12%) | 54 (12%) | 54 (12%) | 54 (12%) | 4.4e-04 |
| 3 | + grid-stride: fixed grid, many elements per thread (hand) | 621 ms | 240 (53%) | 398 (88%) | 264 (58%) | 264 (58%) | 264 (58%) | 264 (58%) | 2.0e-07 |
| 3b | + unrolled x4: four loads in flight per thread (hand) | 645 ms | 315 (69%) | 1680 (370%) | 438 (96%) | 448 (99%) | 450 (99%) | 447 (98%) | 1.4e-07 |
| 4 | `grid-reduce!` -- the language does Phase 1 + 2 | 631 ms | 126 (28%) | 285 (63%) | 259 (57%) | 263 (58%) | 263 (58%) | 262 (58%) | 7.5e-08 |
| 4 | `grid-reduce!` -- the language does Phase 1 + 2 — `sum_atomic` | 596 ms | 252 (55%) | 495 (109%) | 264 (58%) | 264 (58%) | 264 (58%) | 262 (58%) | 3.2e-07 |
| 5 | `reduce-vec` -- the one-liner | 657 ms | 128 (28%) | 512 (113%) | 259 (57%) | 263 (58%) | 264 (58%) | 262 (58%) | 7.5e-08 |

## § 1b — Strategy Rollup · Intel(R) Graphics [0xe20b] · sum fp32 · `fast`

Every row has the same Phase 0 (`loop-vector-stride` fold) and the same grid (the hoist's occupancy formula, R=1 unless the kernel declares otherwise); rows differ only in how the per-thread partials are combined. Cells are **median kernel µs**; the fastest per size is bold.

| Phase 1 | Phase 2 | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** |
|---|---|---:|---:|---:|---:|---:|---:|
| `reduce-workgroup` | `:atomic` | **4.1** | **34.0** | **254.5** | **1016.0** | **4069.2** | **12213.5** |
| `reduce-workgroup` | `:cas` | 1081.4 | 1107.0 | 1327.5 | 2072.5 | 5115.7 | 13257.8 |
| `reduce-workgroup` | `:last-man-standing` | 8.3 | 38.4 | 258.8 | 1020.2 | 4073.8 | 12220.5 |
| `reduce-warp` | atomic per warp | 9.9 | 35.5 | 263.1 | 1023.9 | 4087.2 | 12247.5 |
| `reduce-warp` | CAS per warp | 5321.9 | 5437.0 | 5596.3 | 6346.2 | 9351.2 | 17241.2 |

*second-stage* is not in the rollup yet: it needs two kernel launches, which the fixture's single-kernel plan cannot express.

## § 2 — Workloads and Contenders · Intel(R) Graphics [0xe20b] · fp32 · `fast`

Crisp's row is its language form (`reduce-vec` / `grid-reduce!` after a `loop-vector-stride` fold, grid from the occupancy policy). Contenders are timed by the HOST CLOCK around call-and-wait (a library call may launch several kernels), so at small sizes their numbers include the submission overhead shown; Crisp is timed by its kernel timestamp. **Device compile** = source to SPIR-V (`crisp-compile`; `icpx -fsycl-device-only`). Cells: GB/s of input read (% of measured peak).

### `argmax`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 620 ms | 87 (19%) | 391 (86%) | 252 (55%) | 259 (57%) | 260 (57%) | 260 (57%) | — |
| SYCL_Reduction | 1869 ms | 5 (1%) | 95 (21%) | 221 (49%) | 323 (71%) | 342 (75%) | 404 (89%) | 166 µs |
| oneDPL | 3277 ms | 14 (3%) | 192 (42%) | 291 (64%) | 330 (73%) | 402 (88%) | 433 (95%) | 82 µs |
| oneMKL | 2534 ms | 9 (2%) | 128 (28%) | 126 (28%) | 144 (32%) | 170 (37%) | 174 (38%) | 65 µs |

### `sum`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 574 ms | 126 (28%) | 514 (113%) | 259 (57%) | 263 (58%) | 264 (58%) | 264 (58%) | — |
| SYCL_Reduction | 1909 ms | 9 (2%) | 134 (30%) | 242 (53%) | 330 (73%) | 406 (89%) | 426 (94%) | 66 µs |
| oneDPL | 2903 ms | 12 (3%) | 237 (52%) | 298 (66%) | 331 (73%) | 417 (92%) | 438 (96%) | 73 µs |
| oneMKL | 2605 ms | 5 (1%) | 143 (31%) | 253 (56%) | 317 (70%) | 407 (90%) | 426 (94%) | 63 µs |

### `sum_sumsq`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 575 ms | 110 (24%) | 492 (108%) | 257 (57%) | 264 (58%) | 265 (58%) | 265 (58%) | — |
| SYCL_Reduction | 2006 ms | 14 (3%) | 203 (45%) | 277 (61%) | 321 (71%) | 396 (87%) | 429 (94%) | 65 µs |
| oneDPL | 2975 ms | 15 (3%) | 194 (43%) | 298 (66%) | 315 (69%) | 401 (88%) | 433 (95%) | 69 µs |
| oneMKL | 2699 ms | 6 (1%) | 93 (20%) | 155 (34%) | 179 (39%) | 211 (46%) | 219 (48%) | 67 µs |

### `welford`

| contender | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | launch overhead |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| **Crisp** | 618 ms | 108 (24%) | 462 (102%) | 250 (55%) | 254 (56%) | 255 (56%) | 255 (56%) | — |
| SYCL_Reduction | 1850 ms | 7 (2%) | 108 (24%) | 225 (50%) | 340 (75%) | 348 (77%) | 419 (92%) | 133 µs |
| oneDPL | 2987 ms | 7 (2%) | 206 (45%) | 291 (64%) | 362 (80%) | 396 (87%) | 436 (96%) | 138 µs |


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