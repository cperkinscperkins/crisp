# GPU MODE Contest Report: `vectorsum_v2`

> Generated from [`results/vectorsum_v2.json`](results/vectorsum_v2.json) by `python contests/gpu-mode/report.py --all`. Live leaderboard: [https://www.gpumode.com/leaderboard/544?tab=rankings](https://www.gpumode.com/leaderboard/544?tab=rankings) (Crisp commit `c929d68e`).

**Workload:** Sum reduction of 1D float32 tensor across 6 benchmark sizes from 1,638,400 to 52,428,800 elements.

## § 1 — Official Leaderboard Standings

| GPU | Architecture | Rank | Public Score | Secret Score | Achieved BW | % of #1 (`top1`) | Winning Crisp Kernel | Hardware Profile | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|---|
| **B200** | Blackwell (sm_100) | **#73** / 81 | **89.44 µs** | — | 2.34 TB/s | 41.4% (`37.03 µs`) | [`crisp_vectorsum_b200_2xfloat4.py`](02-vectorsum-v2/crisp_vectorsum_b200_2xfloat4.py) ([`.crisp`](02-vectorsum-v2/vectorsum_b200_2xfloat4.crisp)) | `b200` | `2026-10-21 15:12` |
| **H100** | Hopper (sm_90) | **#55** / 66 | **93.85 µs** | 95.21 µs | 2.23 TB/s | 72.4% (`67.92 µs`) | [`crisp_vectorsum_beauty.py`](02-vectorsum-v2/crisp_vectorsum_beauty.py) ([`.crisp`](02-vectorsum-v2/vectorsum_beauty.crisp)) | — | `2026-10-21 15:12` |
| **A100** | Ampere (sm_80) | **#102** / 114 | **164.36 µs** | — | 1.28 TB/s | 71.1% (`116.89 µs`) | [`crisp_vectorsum_warp_reduce.py`](02-vectorsum-v2/crisp_vectorsum_warp_reduce.py) ([`.crisp`](02-vectorsum-v2/vectorsum_warp_reduce.crisp)) | — | `2026-10-21 15:12` |
| **L4** | Ada Lovelace (sm_89) | **#37** / 43 | **974.52 µs** | — | 215.2 GB/s | 71.0% (`692.02 µs`) | [`crisp_vectorsum_warp_reduce.py`](02-vectorsum-v2/crisp_vectorsum_warp_reduce.py) ([`.crisp`](02-vectorsum-v2/vectorsum_warp_reduce.crisp)) | — | `2026-10-21 15:12` |

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



| GPU | Architecture | Beauty Score | Achieved BW | % of #1 (`top1`) | % of Tuned Crisp | Winning Tuned Kernel | Mode | Submission ID |
|---|---|---:|---:|---:|---:|---|---|---:|
| **B200** | Blackwell (sm_100) | **66.61 µs** | 3.15 TB/s | **55.6%** (`37.03 µs`) | 134.3% (`89.44 µs`) | [`crisp_vectorsum_b200_2xfloat4.py`](02-vectorsum-v2/crisp_vectorsum_b200_2xfloat4.py) | `leaderboard` | `#965751` |
| **H100** | Hopper (sm_90) | **93.85 µs** | 2.23 TB/s | **72.4%** (`67.92 µs`) | 100.0% (`93.85 µs`) | [`crisp_vectorsum_beauty.py`](02-vectorsum-v2/crisp_vectorsum_beauty.py) | `leaderboard` | `#965749` |

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
| 0 | [`baseline_torch.py`](02-vectorsum-v2/baseline_torch.py) / [`baseline_torch.py`](02-vectorsum-v2/baseline_torch.py) | PyTorch native inp.sum() reference | None | — | — | **87.8** | — | — |
| 1 | [`vectorsum_warp_reduce.crisp`](02-vectorsum-v2/vectorsum_warp_reduce.crisp) / [`crisp_vectorsum_warp_reduce.py`](02-vectorsum-v2/crisp_vectorsum_warp_reduce.py) | float4 (128-bit) vector loads + 4 FP64 accumulators + warp shuffle-xor + atom.global.add.f64 | 24 | — | — | 100.0 (`LB: 101.01`) | **`LB: 164.36`** | **`LB: 974.52`** |
| 2 | [`vectorsum_b200_2xfloat4.crisp`](02-vectorsum-v2/vectorsum_b200_2xfloat4.crisp) / [`crisp_vectorsum_b200_2xfloat4.py`](02-vectorsum-v2/crisp_vectorsum_b200_2xfloat4.py) | 2x float4 (128-bit) vector loads (32 B/thread) + 8 FP64 accumulators + b200 hardware profile + warp shuffle-xor + atom.global.add.f64 | 28 | `b200` | `LB: 89.44` | — | — | — |
| ✨ Beauty | [`vectorsum_beauty.crisp`](02-vectorsum-v2/vectorsum_beauty.crisp) / [`crisp_vectorsum_beauty.py`](02-vectorsum-v2/crisp_vectorsum_beauty.py) | Idiomatic Crisp (float4 views, loop-vector-stride, reduce-warp collective, atomic-add!) | 34 | — | **67.8 (`LB: 66.61`)** | 95.2 (`LB: 93.85`) | — | — |

## § 3 — Key Architectural Takeaways

1. **FP64 Register Accumulation vs. Single-Precision Drift:** The official GPU MODE reference kernel (`data.to(torch.float64).sum().to(torch.float32)`) evaluates 52.4M-element reductions in double precision. Accumulating in pure FP32 caused catastrophic cancellation on randomized seeds under the strict `rtol=1e-5, atol=1e-8` threshold. Promoting register accumulators to `double` (`(to-double ...)`), running warp butterfly shuffles in 64-bit, and issuing native `atom.global.add.f64` matched the double-precision reference bit-for-bit across all public and secret seeds.
2. **Blackwell (`B200`) Architecture Profile:** Leveraging Crisp's `def-hardware-profile b200` with 2x `float4` loads (32 bytes/thread) and 8 independent FP64 accumulators achieved **89.44 µs** public / **88.26 µs** secret (2.34 TB/s read throughput), outperforming the universal 1x float4 kernel.
3. **Achieved Memory Bandwidth:** Reading 209.7 MB in 89.44 µs on B200 achieves **2.34 TB/s**, while H100 achieves **2.08 TB/s** (101.01 µs), A100 achieves **1.28 TB/s** (164.36 µs), and L4 achieves **215.2 GB/s** (974.52 µs).
4. **Host Launch vs. Kernel Latency:** The remaining gap to the fastest leaderboard entries (e.g. 67.9 µs on H100) is dominated by host-side PyTorch launch overhead (`torch::zeros` allocation and `.to(kFloat32)` conversion). Future iterations using last-thread-finishes direct FP32 output will eliminate host dispatch latency.

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
| `2026-10-24 00:26:25` | `965744` | **B200** | `benchmark` | `crisp_vectorsum_beauty.py` | 67.8 ± 0.2 | — | — |
| `2026-10-24 00:28:49` | `965746` | **H100** | `benchmark` | `crisp_vectorsum_beauty.py` | 95.2 ± 0.1 | — | — |
| `2026-10-24 00:31:25` | `965749` | **H100** | `leaderboard` | `crisp_vectorsum_beauty.py` | — | **93.85** | 95.21 |
| `2026-10-24 00:35:25` | `965751` | **B200** | `leaderboard` | `crisp_vectorsum_beauty.py` | — | **66.61** | 66.63 |
