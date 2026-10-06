# Crisp Benchmark Report

> Generated from verified test sweeps in `benchmarks/results/`.

| device | data captured | source | hardware profile |
|---|---|---|---|
| Intel(R) Graphics [0xe20b] | 2026-10-06 | Crisp `57b66028` (docker) | `bmg` (validated) |

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