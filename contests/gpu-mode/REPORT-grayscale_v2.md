# GPU MODE Contest Report: `grayscale_v2`

> Generated from [`results/grayscale_v2.json`](results/grayscale_v2.json) by `python contests/gpu-mode/report.py --all`. Live leaderboard: [https://www.gpumode.com/leaderboard/538?tab=rankings](https://www.gpumode.com/leaderboard/538?tab=rankings) (Crisp commit `0a93bbb2`).

**Workload:** Y = 0.2989 R + 0.5870 G + 0.1140 B across 6 square image sizes from 512x512 to 16384x16384 (at 16384x16384: 3.221 GB RGB input read + 1.074 GB grayscale output write = 4.295 GB = 4.00 GiB total DRAM traffic).

## § 1 — Official Leaderboard Standings

| GPU | Architecture | Rank | Public Score | Secret Score | Achieved BW | % of #1 (`top1`) | Winning Crisp Kernel | Hardware Profile | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|---|
| **B200** | Blackwell (sm_100) | **#25** / 48 | **601.52 µs** | 605.34 µs | 7.14 TB/s | 98.1% (`590.12 µs`) | [`crisp_grayscale_direct_vec4.py`](03-grayscale-v2/crisp_grayscale_direct_vec4.py) ([`.crisp`](03-grayscale-v2/grayscale_direct_vec4.crisp)) | — | `2026-10-26 06:21` |
| **H100** | Hopper (sm_90) | **#25** / 36 | **1379.23 µs** | 1379.64 µs | 3.11 TB/s | 84.5% (`1164.98 µs`) | [`crisp_grayscale_direct_vec4.py`](03-grayscale-v2/crisp_grayscale_direct_vec4.py) ([`.crisp`](03-grayscale-v2/grayscale_direct_vec4.crisp)) | — | `2026-10-26 06:21` |
| **A100** | Ampere (sm_80) | **#29** / 131 | **2394.84 µs** | 2392.06 µs | 1.79 TB/s | 97.9% (`2345.08 µs`) | [`crisp_grayscale_direct_vec4_nc.py`](03-grayscale-v2/crisp_grayscale_direct_vec4_nc.py) ([`.crisp`](03-grayscale-v2/grayscale_direct_vec4_nc.crisp)) | — | `2026-10-26 06:21` |
| **L4** | Ada Lovelace (sm_89) | **#19** / 30 | **17181.70 µs** | 17181.01 µs | 250.0 GB/s | 92.9% (`15962.79 µs`) | [`crisp_grayscale_direct_vec4.py`](03-grayscale-v2/crisp_grayscale_direct_vec4.py) ([`.crisp`](03-grayscale-v2/grayscale_direct_vec4.crisp)) | — | `2026-10-26 06:21` |

## § 1b — Beauty Contestant Showcase (Idiomatic Crisp)

> **Philosophy:** High-level, declarative Crisp code utilizing built-in language idioms (`loop-vector-stride`, vectorized types/views, monomorphic collective reductions) without manual pointer chasing, inline PTX hacks, or complex register budgeting.

> **Design:** 15-line Crisp kernel expressing ITU-R BT.601 RGB-to-grayscale conversion via an inlined helper function `rgb-to-y` using hardware `op-fma`, read-only `&out` parameter qualification, and `loop-vector-stride`. (`15` SLOC)
>

> **Crisp Abstractions Showcased:**

> - def-function inline device helper

> - op-fma hardware fused multiply-add

> - &out read-only input qualification (.nc)

> - loop-vector-stride grid-stride loop



| GPU | Architecture | Beauty Score | Achieved BW | % of #1 (`top1`) | % of Tuned Crisp | Winning Tuned Kernel | Mode | Submission ID |
|---|---|---:|---:|---:|---:|---|---|---:|
| **H100** | Hopper (sm_90) | **1549.00 µs** | 2.77 TB/s | **75.2%** (`1164.98 µs`) | 89.0% (`1379.23 µs`) | [`crisp_grayscale_direct_vec4.py`](03-grayscale-v2/crisp_grayscale_direct_vec4.py) | `benchmark` | `#966630` |

### Crisp Implementation ([`03-grayscale-v2/grayscale_beauty.crisp`](03-grayscale-v2/grayscale_beauty.crisp))

```lisp
;; GPU MODE Challenge 03: grayscale_v2 (Beauty Contestant)
;; Converts contiguous (H, W, 3) RGB float32 tensor to (H, W) grayscale:
;;   Y = 0.2989 * R + 0.5870 * G + 0.1140 * B

(def-type in-vec  (vector float :address-space :global :align :compact))
(def-type out-vec (vector float :address-space :global :align :compact))

(def-function rgb-to-y (r g b)
  (declare #'(float float float => float))
  (op-fma 0.2989 r (op-fma 0.5870 g (* 0.1140 b))))

(def-kernel grayscale_kernel (input &out output)
  (declare #'(in-vec &out out-vec => nil)
           (global-size :derive-from output :strategy :strided)
           (local-size  :set-to 256))
  (loop-vector-stride output (i)
    (let ((i3 (* i 3ul)))
      (set! (~ output i)
            (rgb-to-y (~ input i3)
                      (~ input (+ i3 1ul))
                      (~ input (+ i3 2ul)))))))
```

## § 2 — Technique Ladder & Cross-GPU Ablation (`size = 16,384 x 16,384 (4.295 GB total traffic)`)

Cells show **`benchmark` mean µs** (and **`[LB: public µs]`** when submitted to the official leaderboard). The fastest kernel on each GPU is **bold**.

| Step | Kernel (`.crisp` / `.py`) | Strategy | Regs | Profile | **B200** | **H100** | **A100** | **L4** |
|---|---|---|---:|---|---:|---:|---:|---:|
| 0 | [`grayscale_beauty.crisp`](03-grayscale-v2/grayscale_beauty.crisp) / [`crisp_grayscale_beauty.py`](03-grayscale-v2/crisp_grayscale_beauty.py) | Idiomatic scalar loop-vector-stride + def-function rgb-to-y (op-fma) + &out (.nc) | 38 | — | — | 1549.0 | — | — |
| 1 | [`grayscale_direct_vec4.crisp`](03-grayscale-v2/grayscale_direct_vec4.crisp) / [`crisp_grayscale_direct_vec4.py`](03-grayscale-v2/crisp_grayscale_direct_vec4.py) | Direct 128-bit float4 3:1 vector packet (4 pixels/thread, 3x ld.global.nc.v4 [+0,+16,+32] + 1x st.global.cs.v4.f32) | 28 | — | **`LB: 601.52`** | **1379.0 (`LB: 1379.23`)** | `LB: 2485.25` | **`LB: 17181.70`** |
| 1b | [`grayscale_direct_vec4_nc.crisp`](03-grayscale-v2/grayscale_direct_vec4_nc.crisp) / [`crisp_grayscale_direct_vec4_nc.py`](03-grayscale-v2/crisp_grayscale_direct_vec4_nc.py) | Direct 128-bit float4 3:1 vector packet (4 pixels/thread, 3x ld.global.nc.v4 [+0,+16,+32] + 1x native st.global.v4.b32) | 28 | — | — | 1380.0 | **`LB: 2394.84`** | — |
| 2 | [`grayscale_direct_vec4_cs256.crisp`](03-grayscale-v2/grayscale_direct_vec4_cs256.crisp) / [`crisp_grayscale_direct_vec4_cs256.py`](03-grayscale-v2/crisp_grayscale_direct_vec4_cs256.py) | Direct float4 3:1 packet + Endeavour 192 :cache (:streaming :prefetch 256) on input + :cache :streaming on output | 28 | — | — | 1450.0 | — | — |
| 3 | [`grayscale_direct_2xvec4.crisp`](03-grayscale-v2/grayscale_direct_2xvec4.crisp) / [`crisp_grayscale_direct_2xvec4.py`](03-grayscale-v2/crisp_grayscale_direct_2xvec4.py) | Direct 2x float4 (8 pixels = 128B/thread, 131,072 CTAs, 6x folded ld.global.nc.v4 + 2x st.global.cs.v4.f32) | 42 | — | — | 1384.0 | — | — |
| 4 | [`grayscale_direct_2xvec4_nc.crisp`](03-grayscale-v2/grayscale_direct_2xvec4_nc.crisp) / [`crisp_grayscale_direct_2xvec4_nc.py`](03-grayscale-v2/crisp_grayscale_direct_2xvec4_nc.py) | Direct 2x float4 (8 pixels = 128B/thread, pure native .nc + native st.global.v4 with all 6 loads and 2 stores offset-folded) | 42 | — | `LB: 604.74` | — | — | — |
| 5 | [`grayscale_stride_vec4_cs256.crisp`](03-grayscale-v2/grayscale_stride_vec4_cs256.crisp) / [`crisp_grayscale_stride_vec4_cs256.py`](03-grayscale-v2/crisp_grayscale_stride_vec4_cs256.py) | Persistent grid-stride loop-vector-stride over float4 3:1 packets + :cache (:streaming :prefetch 256) | 48 | — | — | — | — | — |
| 6 | [`grayscale_smem_coalesced.crisp`](03-grayscale-v2/grayscale_smem_coalesced.crisp) / [`crisp_grayscale_smem_coalesced.py`](03-grayscale-v2/crisp_grayscale_smem_coalesced.py) | Stride-1 coalesced ld.global.nc.v2.b64 (+0,+4096,+8192) -> 12 KB shared memory -> conflict-free stride-3 ld.shared.b32 -> stride-1 st.global.b32 | 27 | — | — | 1380.0 | — | — |

## § 3 — Key Architectural Takeaways

1. **128-Bit `float4` 3:1 Vector Packet Decomposition (grayscale_direct_vec4.crisp):** Because each RGB pixel is 3 `float32`s (12 bytes), loading 1 pixel per thread (input[3*i + 0..2]) issues 3 scalar 32-bit loads at stride 3 (1,549.0 µs on H100). Grouping **4 consecutive RGB pixels (12 floats = 48 bytes) per thread** maps onto **3 consecutive 16-byte-aligned `float4` loads** (`v0` = in4[3*gid], `v1` = in4[3*gid+1], `v2` = in4[3*gid+2]) and **1 `float4` output store** (##(y0 y1 y2 y3)), cutting H100 runtime by **170 µs (−11.0%)** down to **1,379.0 µs** (**3.11 TB/s = 93.0% of H100 HBM3 peak**).
2. **Selective Cache Hints — .nc Input Residency vs. .cs Streaming Output Stores:** Across a 32-lane warp, the 3 `float4` loads (3*gid + 0..2) are strided by 48 bytes and share the exact same twelve 128-byte L1 cache lines. Using &out (.nc without :streaming .cs) on in-vec keeps those lines resident in L1 so the +16 and +32 loads hit L1 (1,379 µs vs 1,450 µs when :streaming .cs evicts L1 lines prematurely), while applying :cache :streaming (st.global.cs.v4.f32) to out-vec prevents the 1.07 GB output write from polluting L2 cache (601.52 µs on B200, **98.1% of #1**).
3. **Shared-Memory De-Interleaving vs. Hardware L1 MSHR Coalescing (grayscale_smem_coalesced.crisp):** Staging 768 contiguous `float4`s (12 KB) per CTA via stride-1 ld.global.nc.v2.b64 ([+0], [+4096], [+8192]) into shared memory and reading at conflict-free stride 3 (gcd(3, 32) = 1) achieved **1,380.0 ± 0.2 µs** on H100—confirming that H100 L1 MSHRs already merge the three back-to-back [+0, +16, +32] ld.global.nc.v4.b32 instructions into full 128-byte cache-line requests with zero replay penalty.
4. **Compiler Uniformity Analysis Finding (`calculate-uniformity-state`):** In `src/analysis/core.lisp`, calls to pure tensor metadata accessors (`(length~ output)`, `(extents~ output)`, `(strides~ output)`) on a `:uniform` kernel tensor argument currently fall through to `:unknown` in `calculate-uniformity-state`, causing workgroup-uniform guards like `(when (< (* bid 1024ul) (length~ output)) (sync-workgroup))` to be rejected as potentially thread-divergent unless wrapped in `(to-workgroup-uniform ...)`.

## § 4 — Verified Submission & Benchmark Log

| Timestamp (UTC) | Submission ID | GPU | Mode | File | Benchmark (µs) | Public LB (µs) | Secret LB (µs) |
|---|---:|---|---|---|---:|---:|---:|
| `2026-10-24 21:30:02` | `966617` | **H100** | `benchmark` | `crisp_grayscale_direct_vec4.py` | 1379.0 ± 0.4 | — | — |
| `2026-10-24 21:32:29` | `966619` | **H100** | `benchmark` | `crisp_grayscale_smem_coalesced.py` | 1380.0 ± 0.2 | — | — |
| `2026-10-24 21:33:58` | `966622` | **H100** | `benchmark` | `crisp_grayscale_direct_vec4_cs256.py` | 1450.0 ± 1.4 | — | — |
| `2026-10-24 21:36:03` | `966624` | **H100** | `benchmark` | `crisp_grayscale_direct_2xvec4.py` | 1384.0 ± 0.4 | — | — |
| `2026-10-24 21:38:42` | `966627` | **H100** | `benchmark` | `crisp_grayscale_direct_vec4_nc.py` | 1380.0 ± 0.5 | — | — |
| `2026-10-24 21:40:50` | `966630` | **H100** | `benchmark` | `crisp_grayscale_beauty.py` | 1549.0 ± 0.8 | — | — |
| `2026-10-24 21:42:52` | `966634` | **H100** | `leaderboard` | `crisp_grayscale_direct_vec4.py` | — | **1379.23** | 1379.64 |
| `2026-10-24 21:45:13` | `966635` | **B200** | `leaderboard` | `crisp_grayscale_direct_vec4.py` | — | **601.52** | 605.34 |
| `2026-10-24 21:47:15` | `966638` | **A100** | `leaderboard` | `crisp_grayscale_direct_vec4.py` | — | **2485.25** | 2373.63 |
| `2026-10-24 21:49:40` | `966640` | **L4** | `leaderboard` | `crisp_grayscale_direct_vec4.py` | — | **17181.70** | 17181.01 |
| `2026-10-24 21:52:54` | `966644` | **B200** | `leaderboard` | `crisp_grayscale_direct_2xvec4_nc.py` | — | **604.74** | 605.66 |
| `2026-10-24 21:55:01` | `966645` | **A100** | `leaderboard` | `crisp_grayscale_direct_vec4_nc.py` | — | **2394.84** | 2392.06 |
