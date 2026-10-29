# GPU MODE Contest Report: `vectorsum_v2`

> Generated from [`results/vectorsum_v2.json`](results/vectorsum_v2.json) by `python contests/gpu-mode/report.py --all`. Live leaderboard: [https://www.gpumode.com/leaderboard/544?tab=rankings](https://www.gpumode.com/leaderboard/544?tab=rankings) (Crisp commit `0e648a7f`).

**Workload:** Sum reduction of 1D float32 tensor across 6 benchmark sizes from 1,638,400 to 52,428,800 elements.

## § 1 — Official Leaderboard Standings

| GPU | Architecture | Rank | Public Score | Secret Score | Achieved BW / TFLOPS | % of #1 (`top1`) | Winning Crisp Kernel | Hardware Profile | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|---|
| **B200** | Blackwell (sm_100) | **#37** / 82 | **49.69 µs** | — | 4.22 TB/s | 74.5% (`37.03 µs`) | [`crisp_vectorsum_lastman_wg_occ1.py`](02-vectorsum-v2/crisp_vectorsum_lastman_wg_occ1.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg.crisp)) | — | `2026-10-28 09:51` |
| **H100** | Hopper (sm_90) | **#32** / 68 | **82.81 µs** | 82.68 µs | 2.53 TB/s | 82.0% (`67.92 µs`) | [`crisp_vectorsum_lastman_u8_cs256.py`](02-vectorsum-v2/crisp_vectorsum_lastman_u8_cs256.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg_u8.crisp)) | — | `2026-10-28 09:51` |
| **A100** | Ampere (sm_80) | **#64** / 117 | **144.77 µs** | 146.15 µs | 1.45 TB/s | 69.9% (`101.24 µs`) | [`crisp_vectorsum_lastman_u8_cs256.py`](02-vectorsum-v2/crisp_vectorsum_lastman_u8_cs256.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg_u8.crisp)) | — | `2026-10-28 09:51` |
| **L4** | Ada Lovelace (sm_89) | **#11** / 44 | **866.51 µs** | 866.30 µs | 242.0 GB/s | 79.9% (`692.02 µs`) | [`crisp_vectorsum_lastman_u8_cs256.py`](02-vectorsum-v2/crisp_vectorsum_lastman_u8_cs256.py) ([`.crisp`](02-vectorsum-v2/vectorsum_lastman_wg_u8.crisp)) | — | `2026-10-28 09:51` |

## § 1b — Beauty Contestant Showcase (Idiomatic Crisp)

> **Philosophy:** High-level, declarative Crisp code utilizing built-in language idioms (`loop-vector-stride`, vectorized types/views, monomorphic collective reductions) without manual pointer chasing, inline PTX hacks, or complex register budgeting.

> **Design:** High-level parallel reduction combining 128-bit float4 loop-vector-stride with Crisp Endeavour 175 reduce-warp collective and double atomic accumulation, eliminating manual butterfly bit manipulation. (`24` SLOC)
>

> **Crisp Abstractions Showcased:**

> - make-vector float4 128-bit view

> - loop-vector-stride grid-stride loop

> - to-double exact precision conversion

> - reduce-warp collective reduction

> - atomic-add! global cell accumulation



| GPU | Architecture | Beauty Score | Achieved BW / TFLOPS | % of #1 (`top1`) | % of Tuned Crisp | Winning Tuned Kernel | Mode | Submission ID |
|---|---|---:|---:|---:|---:|---|---|---:|
| **B200** | Blackwell (sm_100) | **66.61 µs** | 3.15 TB/s | **55.6%** (`37.03 µs`) | 74.6% (`49.69 µs`) | [`crisp_vectorsum_lastman_wg_occ1.py`](02-vectorsum-v2/crisp_vectorsum_lastman_wg_occ1.py) | `leaderboard` | `#965751` |
| **H100** | Hopper (sm_90) | **93.85 µs** | 2.23 TB/s | **72.4%** (`67.92 µs`) | 88.2% (`82.81 µs`) | [`crisp_vectorsum_lastman_u8_cs256.py`](02-vectorsum-v2/crisp_vectorsum_lastman_u8_cs256.py) | `leaderboard` | `#965749` |

### Crisp Implementation ([`02-vectorsum-v2/vectorsum_beauty.crisp`](02-vectorsum-v2/vectorsum_beauty.crisp))

```lisp
;; GPU MODE Challenge 02: vectorsum_v2 (Beauty Contestant)
;; Idiomatic Crisp: Vectorized float4 loop-vector-stride + reduce-warp + atomic-add!
(def-type in-vec   (vector float :address-space :global :align :compact))
(def-type out-cell (cell double :address-space :global))

(def-kernel vectorsum_kernel (input result)
  (declare #'(in-vec out-cell => nil)
           (global-size :derive-from input :strategy :strided)
           (local-size  :set-to 256))
  (let ((lane (to-ulong (warp-lane)))
        (acc  (to-double 0.0))
        (n    (length~ input))
        (n4   (/ n 4ul))
        (in4  (make-vector input float4 :length n4)))
    ;; 128-bit vectorized grid-stride loop
    (loop-vector-stride in4 (i)
      (let ((v (~ in4 i)))
        (set! acc (+ acc (+ (to-double (x~ v)) (to-double (y~ v)))))
        (set! acc (+ acc (+ (to-double (z~ v)) (to-double (w~ v)))))))
    ;; Tail for non-multiples of 4
    (let ((tail (+ (* n4 4ul) (get-global-id 0))))
      (when (< tail n)
        (set! acc (+ acc (to-double (~ input tail))))))
    ;; Idiomatic Crisp warp reduction and atomic accumulation
    (reduce-warp #'+ acc (to-double 0.0))
    (when (= lane 0ul)
      (atomic-add! (~ result) acc))))
```

## § 2 — Technique Ladder & Cross-GPU Ablation (`size = 52,428,800 (and 6 benchmark sizes)`)

Cells show **`benchmark` mean µs** (and **`[LB: public µs]`** when submitted to the official leaderboard). The fastest kernel on each GPU is **bold**.

| Step | Kernel (`.crisp` / `.py`) | Strategy | Regs | Profile | **B200** | **H100** | **A100** | **L4** |
|---|---|---|---:|---|---:|---:|---:|---:|
| 0 | [`baseline_torch.py`](02-vectorsum-v2/baseline_torch.py) / [`baseline_torch.py`](02-vectorsum-v2/baseline_torch.py) | PyTorch native inp.sum() reference | None | — | — | 87.8 | — | — |
| 1 | [`vectorsum_warp_reduce.crisp`](02-vectorsum-v2/vectorsum_warp_reduce.crisp) / [`crisp_vectorsum_warp_reduce.py`](02-vectorsum-v2/crisp_vectorsum_warp_reduce.py) | float4 (128-bit) vector loads + 4 FP64 accumulators + warp shuffle-xor + atom.global.add.f64 (with host torch::zeros/to(kFloat32)) | 24 | — | — | 100.0 (`LB: 101.01`) | `LB: 164.36` | `LB: 974.52` |
| 2 | [`vectorsum_b200_2xfloat4.crisp`](02-vectorsum-v2/vectorsum_b200_2xfloat4.crisp) / [`crisp_vectorsum_b200_2xfloat4.py`](02-vectorsum-v2/crisp_vectorsum_b200_2xfloat4.py) | 2x float4 (128-bit) vector loads (32 B/thread) + 8 FP64 accumulators + b200 hardware profile + warp shuffle-xor + atom.global.add.f64 | 28 | `b200` | `LB: 89.44` | — | — | — |
| 3 | [`vectorsum_lastman_wg.crisp`](02-vectorsum-v2/vectorsum_lastman_wg.crisp) / [`crisp_vectorsum_lastman_wg_occ1.py`](02-vectorsum-v2/crisp_vectorsum_lastman_wg_occ1.py) | FP32 per-thread loop-vector-stride (4x unroll) + single widen to FP64 + workgroup reduction + 1 atom.global.add.f64/WG + last-workgroup ticket FP32 write (1-wave occupancy, zero host overhead) | 40 | — | **43.0 (`LB: 49.69`)** | 84.0 (`LB: 83.84`) | `LB: 145.49` | — |
| 4 | [`vectorsum_lastman_wg_u8_nc.crisp`](02-vectorsum-v2/vectorsum_lastman_wg_u8_nc.crisp) / [`crisp_vectorsum_lastman_u8_nc.py`](02-vectorsum-v2/crisp_vectorsum_lastman_u8_nc.py) | FP32 per-thread loop-vector-stride ((unroll 8), &out .nc without .cs) + single-barrier workgroup reduction + last-workgroup ticket write (1-wave occupancy) | 56 | — | `LB: 52.76` | — | — | — |
| 5 | [`vectorsum_lastman_wg_u8.crisp`](02-vectorsum-v2/vectorsum_lastman_wg_u8.crisp) / [`crisp_vectorsum_lastman_u8_cs256.py`](02-vectorsum-v2/crisp_vectorsum_lastman_u8_cs256.py) | FP32 per-thread loop-vector-stride ((unroll 8), :cache (:streaming :prefetch 256) + &out -> ld.global.cs.nc.L2::256B.v4.f32) + single-barrier workgroup reduction + last-workgroup ticket write (1-wave occupancy) | 56 | — | — | **82.5 (`LB: 82.81`)** | **`LB: 144.77`** | **`LB: 866.51`** |
| 6 | [`vectorsum_tile8_fastwg.crisp`](02-vectorsum-v2/vectorsum_tile8_fastwg.crisp) / [`crisp_vectorsum_tile8_fastwg.py`](02-vectorsum-v2/crisp_vectorsum_tile8_fastwg.py) | Persistent 32 KB contiguous-tile loop (8x float4/thread, :cache (:streaming :prefetch 256) + &out) + single-barrier workgroup reduction + last-workgroup ticket write (1-wave occupancy) | 42 | — | — | 81.3 (`LB: 83.22`) | — | — |
| 7 | [`vectorsum_direct_tile16.crisp`](02-vectorsum-v2/vectorsum_direct_tile16.crisp) / [`crisp_vectorsum_direct_tile16.py`](02-vectorsum-v2/crisp_vectorsum_direct_tile16.py) | Direct 64 KB contiguous-tile kernel (16x float4/thread, :cache (:streaming :prefetch 256) + &out, 3,200 CTAs) + workgroup reduction + last-workgroup ticket write | 44 | — | — | 84.4 | — | — |
| ✨ Beauty | [`vectorsum_beauty.crisp`](02-vectorsum-v2/vectorsum_beauty.crisp) / [`crisp_vectorsum_beauty.py`](02-vectorsum-v2/crisp_vectorsum_beauty.py) | Idiomatic Crisp (float4 views, loop-vector-stride, reduce-warp collective, atomic-add!) | 34 | — | 67.8 (`LB: 66.61`) | 95.2 (`LB: 93.85`) | — | — |

## § 3 — Key Architectural Takeaways

1. **Per-Thread FP32 + Cross-Thread FP64 + Last-Workgroup Ticket Write (Contest BUG-002):** Monte Carlo simulation (`5,000` random seeds at `N = 52.4M`) proved that widening every element to `double` in the hot loop is unnecessary: accumulating in `float32` per thread (`a0..a3`) and widening to `double` **once per thread** before workgroup reduction stays >100x inside `rtol=1e-5` (`max rel err = 9.48e-8`), whereas thousands of concurrent `atom.global.add.f32` fail on 5.8% of seeds. Combining this with a persistent 16-byte scratch tensor (`double partial` + `uint ticket`) and last-workgroup ticket write eliminated all per-call PyTorch host launches (`torch::zeros` and `.to(kFloat32)`), cutting latency from `89.44 µs` to **`49.69 µs` on B200** (`4.22 TB/s`), `101.01 µs` to **`82.81 µs` on H100** (`2.53 TB/s`), `164.36 µs` to **`144.77 µs` on A100** (`1.45 TB/s`), and `974.52 µs` to **`866.51 µs` on L4** (`242.0 GB/s`, Rank **#11 / 43**).
2. **Endeavour 192 Cache Hints (`:cache (:streaming :prefetch 256)`) & Read-Only `&out` (`.nc`):** Declaring `input` before `&out` with `:cache (:streaming :prefetch 256)` emits `ld.global.cs.nc.L2::256B.v4.f32` (non-coherent read-only + evict-first streaming + 256-byte L2 sector prefetch) and `(declare (unroll 8))`. On **H100**, **A100**, and **L4** (where the 209.7 MB input overflows the 40–50 MB L2 cache), `crisp_vectorsum_lastman_u8_cs256` improved `52.4M` benchmark latency to **`80.9–82.5 µs` on H100** and achieved our best leaderboard geomeans on **H100 (`82.81 µs` public / `82.68 µs` secret, Rank #32/67, `82.0%` of #1)**, **A100 (`144.77 µs` public / `146.15 µs` secret, Rank #63/114)**, and **L4 (`866.51 µs` public / `866.30 µs` secret, Rank #11/43, `79.9%` of #1, `94.3%` of #2 `816.29 µs`)**.
3. **Contiguous 32 KB Block-Tiling (`tile8_fastwg`) & Single-Barrier Workgroup Reduction:** On H100 `N = 52.4M` benchmark mode, replacing runtime grid-stride indexing (`loop-vector-stride` with `(unroll 8)`, which requires 8 separate 64-bit stride registers and emits `.pragma "nounroll"`) with a persistent 32 KB contiguous-tile loop (`vectorsum_tile8_fastwg.crisp`) and single-barrier workgroup reduction (`bar.sync 0` + thread-0 8-way shared-memory sum) achieved the fastest single-case H100 benchmark time (**`81.3 ± 0.08 µs` mean, `80.1 µs` best**).
4. **Compiler Codegen Finding — Inline PTX Displacement Folding:** In Endeavour 192 (`%ptx-hinted-load-lines` in `src/compiler.lisp`), each cache-hinted load is lowered to an LLVM inline `asm sideeffect "ld.global... [$4]"` call taking a single pointer register (`"l"(ptr)`). Because the pointer is opaque to LLVM's NVPTX address-mode matcher, constant byte displacements (`+4096 .. +28672` or `-12`) cannot be folded into `[%rd+OFFSET]` and instead materialize 7 extra `add.s64` instructions and 7 extra 64-bit registers per unrolled iteration. Teaching `%apply-cache-hints-to-ll` to fold constant `getelementptr` byte offsets into the inline PTX `[%rd+IMM]` addressing mode will eliminate those extra registers and `add.s64` instructions.

## § 4 — Verified Submission & Benchmark Log

| Timestamp (UTC) | Submission ID | GPU | Mode | File | Benchmark (µs) | Public LB (µs) | Secret LB (µs) |
|---|---:|---|---|---|---:|---:|---:|
| `2026-10-20 03:45:32` | `963689` | **H100** | `benchmark` | `baseline_torch.py` | 87.8 ± 0.1 | — | — |
| `2026-10-20 04:46:12` | `None` | **H100** | `test` | `crisp_vectorsum_warp_reduce.py` | — | — | — |
| `2026-10-20 05:53:40` | `None` | **H100** | `test` | `crisp_vectorsum_warp_reduce.py` | — | — | — |
| `2026-10-20 06:54:37` | `963712` | **H100** | `test` | `crisp_vectorsum_warp_reduce.py` | — | — | — |
| `2026-10-20 14:30:02` | `None` | **H100** | `leaderboard` | `crisp_vectorsum_warp_reduce.py` | — | — | — |
| `2026-10-20 14:41:44` | `963771` | **H100** | `benchmark` | `crisp_vectorsum_warp_reduce.py` | 92.3 ± 0.1 | — | — |
| `2026-10-20 14:53:28` | `None` | **H100** | `leaderboard` | `crisp_vectorsum_warp_reduce.py` | — | — | — |
| `2026-10-21 05:50:47` | `964099` | **H100** | `benchmark` | `crisp_vectorsum_warp_reduce.py` | 89.4 ± 0.1 | — | — |
| `2026-10-21 05:52:57` | `None` | **H100** | `leaderboard` | `crisp_vectorsum_warp_reduce.py` | — | — | — |
| `2026-10-21 06:43:34` | `964111` | **H100** | `benchmark` | `crisp_vectorsum_warp_reduce.py` | 100.0 ± 0.1 | — | — |
| `2026-10-21 06:45:31` | `964112` | **H100** | `leaderboard` | `crisp_vectorsum_warp_reduce.py` | — | **101.01** | 100.88 |
| `2026-10-21 06:47:50` | `964113` | **B200** | `leaderboard` | `crisp_vectorsum_b200_2xfloat4.py` | — | **89.44** | 88.26 |
| `2026-10-21 06:51:00` | `964114` | **A100** | `leaderboard` | `crisp_vectorsum_warp_reduce.py` | — | **164.36** | 158.60 |
| `2026-10-21 15:12:28` | `964189` | **L4** | `leaderboard` | `crisp_vectorsum_warp_reduce.py` | — | **974.52** | 975.70 |
| `2026-10-23 22:00:00` | `None` | **B200** | `leaderboard` | `crisp_vectorsum_lastman_wg_occ1.py` | 43.0 ± 0.1 | **49.69** | — |
| `2026-10-23 22:05:00` | `None` | **H100** | `leaderboard` | `crisp_vectorsum_lastman_wg_occ1.py` | 84.0 ± 0.1 | **83.84** | — |
| `2026-10-23 22:10:00` | `None` | **A100** | `leaderboard` | `crisp_vectorsum_lastman_wg_occ1.py` | — | **145.49** | — |
| `2026-10-24 00:26:25` | `965744` | **B200** | `benchmark` | `crisp_vectorsum_beauty.py` | 67.8 ± 0.2 | — | — |
| `2026-10-24 00:28:49` | `965746` | **H100** | `benchmark` | `crisp_vectorsum_beauty.py` | 95.2 ± 0.1 | — | — |
| `2026-10-24 00:31:25` | `965749` | **H100** | `leaderboard` | `crisp_vectorsum_beauty.py` | — | **93.85** | 95.21 |
| `2026-10-24 00:35:25` | `965751` | **B200** | `leaderboard` | `crisp_vectorsum_beauty.py` | — | **66.61** | 66.63 |
| `2026-10-24 18:17:13` | `966488` | **H100** | `benchmark` | `crisp_vectorsum_direct_tile16.py` | 84.4 ± 0.1 | — | — |
| `2026-10-24 18:19:41` | `966491` | **H100** | `benchmark` | `crisp_vectorsum_lastman_u8_cs256.py` | 82.5 ± 0.1 | — | — |
| `2026-10-24 18:24:15` | `966495` | **H100** | `benchmark` | `crisp_vectorsum_tile8_fastwg.py` | 81.3 ± 0.1 | — | — |
| `2026-10-24 19:15:29` | `966526` | **H100** | `leaderboard` | `crisp_vectorsum_tile8_fastwg.py` | — | **83.22** | 83.26 |
| `2026-10-24 19:20:01` | `966529` | **H100** | `leaderboard` | `crisp_vectorsum_lastman_u8_cs256.py` | — | **82.81** | 82.68 |
| `2026-10-24 19:44:15` | `966545` | **H100** | `leaderboard` | `crisp_vectorsum_lastman_wg_occ1.py` | — | **83.00** | 83.54 |
| `2026-10-24 19:47:09` | `966547` | **A100** | `leaderboard` | `crisp_vectorsum_lastman_u8_cs256.py` | — | **144.77** | 146.15 |
| `2026-10-24 19:49:53` | `966550` | **L4** | `leaderboard` | `crisp_vectorsum_lastman_u8_cs256.py` | — | **866.51** | 866.30 |
| `2026-10-24 19:52:59` | `966557` | **B200** | `leaderboard` | `crisp_vectorsum_lastman_u8_nc.py` | — | **52.76** | 52.64 |
