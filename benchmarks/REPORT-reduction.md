# Crisp Benchmark Report

> Generated from verified test sweeps in `benchmarks/results/`.

| device | data captured | source | hardware profile |
|---|---|---|---|
| Intel(R) Graphics [0xe20b] | 2026-10-04 | Crisp `0587fa4e` (docker) | `bmg` (validated) |

---

# Suite: reduction

Row variable: **input size** (fp32 elements, shown in bytes). Headline metric is **GB/s of input read**, and **% of the device's MEASURED read peak** (`benchmarks/reduction/ceiling/read_bw.cpp`, never a spec sheet). Every point is verified twice: on the last timed launch, and on a relaunch over different data.

## § 1 — Reduction Ladder · Intel(R) Graphics [0xe20b] · sum fp32 · `fast`

Measured read peak **454.5 GB/s** (`Intel(R) Graphics [0xe20b]`, hash data). † fits in the 18.9 MB cache: that column measures cache, not memory, and can exceed 100%.

| # | step | device compile | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** | max rel err |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | one atomic per element | 551 ms | 2 (0%) | 2 (1%) | 2 (1%) | *skipped* | *skipped* | *skipped* | 3.2e-03 |
| 1 | work-group tree in SLM, one atomic per group (hand) | 572 ms | 61 (13%) | 66 (15%) | 44 (10%) | 44 (10%) | 44 (10%) | 44 (10%) | 4.5e-04 |
| 2 | warp shuffles, one atomic per group (hand) | 556 ms | 89 (20%) | 101 (22%) | 53 (12%) | 54 (12%) | 54 (12%) | 54 (12%) | 4.2e-04 |
| 3 | + grid-stride: fixed grid, many elements per thread (hand) | 591 ms | 174 (38%) | 547 (120%) | 258 (57%) | 261 (58%) | 262 (58%) | 261 (57%) | 2.7e-07 |
| 3b | + unrolled x4: four loads in flight per thread (hand) | 604 ms | 202 (44%) | 1333 (293%) | 436 (96%) | 448 (99%) | 453 (100%) | 452 (99%) | 3.6e-07 |
| 4 | `grid-reduce!` -- the language does Phase 1 + 2 | 633 ms | 77 (17%) | 421 (93%) | 241 (53%) | 257 (56%) | 260 (57%) | 261 (57%) | 1.7e-08 |
| 4 | `grid-reduce!` -- the language does Phase 1 + 2 — `sum_atomic` | 604 ms | 183 (40%) | 556 (122%) | 259 (57%) | 261 (58%) | 262 (58%) | 261 (57%) | 2.9e-07 |
| 5 | `reduce-vec` -- the one-liner | 604 ms | 78 (17%) | 427 (94%) | 241 (53%) | 257 (56%) | 261 (57%) | 261 (57%) | 1.7e-08 |

## § 1b — Strategy Rollup · Intel(R) Graphics [0xe20b] · sum fp32 · `fast`

Every row has the same Phase 0 (`loop-vector-stride` fold, one work-item per EU-sized grid); rows differ only in how the per-thread partials are combined. Cells are **median kernel µs**; the fastest per size is bold.

| Phase 1 | Phase 2 | **1 MiB†** | **16 MiB†** | **64 MiB** | **256 MiB** | **1 GiB** | **3 GiB** |
|---|---|---:|---:|---:|---:|---:|---:|
| `reduce-workgroup` | `:atomic` | **5.7** | **30.4** | **259.7** | **1025.4** | **4094.9** | **12332.0** |
| `reduce-workgroup` | `:cas` | 2237.1 | 2235.4 | 2565.2 | 3711.8 | 8320.6 | 16619.7 |
| `reduce-workgroup` | `:last-man-standing` | 13.6 | 38.4 | 277.7 | 1048.0 | 4114.7 | 12348.9 |
| `reduce-warp` | atomic per warp | 21.1 | 45.6 | 289.4 | 1060.5 | 4138.4 | 12387.8 |
| `reduce-warp` | CAS per warp | 8213.2 | 8291.8 | 9043.8 | 9841.3 | 12970.9 | 21040.8 |

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