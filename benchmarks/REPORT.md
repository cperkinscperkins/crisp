# Crisp Benchmark Report

## Hardware: Intel BMG

### Summary — Crisp vs. oneMKL ceiling (fast / tf32)

| Chapter | Technique | Size | Crisp (TFLOPS) | oneMKL (TFLOPS) | Crisp % of oneMKL |
|---|---|---:|---:|---:|---:|
| chap0_sync | Synchronous coop-matrix tiling (XMX tf32) | 8192 | 1.3 | 14.2 | 9.4% |
| chap1_async_linear | OpGroupAsyncCopy staging (XMX tf32) | 8192 | 0.7 | 14.2 | 5.3% |
| intel_prefetch | Register-ring + Subgroup2DBlockPrefetch (XMX tf32) | 8192 | 11.7 | 14.2 | 82.8% |
| chap5_fused_epilogue | Fused ReLU epilogue on the prefetch kernel (XMX tf32) | 4096 | 15.2 | 14.3 | 106.0% |
| chap6_fused_custom | Fused CUSTOM activation on the prefetch kernel (XMX tf32) | 4096 | 16.4 | 14.3 | 114.6% |

> Largest measured size per chapter, `fast` precision (Crisp and oneMKL both tf32). The ladder runs low-to-high on the optimization axis for this hardware.

### chap0_sync — Synchronous coop-matrix tiling (XMX tf32)

#### Precision: fast (ftz=preserve)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.31 | 0.03 | 0.11 | 0.31 | 2.1% | 8.3% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.39 | 0.69 | 4.0% | 26.4% |
| 1024x1024x1024 | 11.94 | 0.18 | 1.53 | 1.40 | 1.35 | 1.59 | 11.3% | 88.4% |
| 2048x2048x2048 | 13.83 | 1.24 | 1.39 | 12.38 | 1.42 | 12.06 | 10.3% | 102.7% |
| 4096x4096x4096 | 14.31 | 9.60 | 1.30 | 106.13 | 1.49 | 92.39 | 10.4% | 114.9% |
| 8192x8192x8192 | 14.17 | 77.57 | 1.31 | 841.23 | 1.34 | 821.02 | 9.4% | 102.5% |

### chap1_async_linear — OpGroupAsyncCopy staging (XMX tf32)

#### Precision: fast (ftz=preserve)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.32 | 0.03 | 0.08 | 0.41 | 1.5% | 6.2% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.25 | 1.09 | 2.5% | 16.8% |
| 1024x1024x1024 | 11.94 | 0.18 | 1.53 | 1.40 | 0.77 | 2.78 | 6.5% | 50.4% |
| 2048x2048x2048 | 13.83 | 1.24 | 1.39 | 12.40 | 0.79 | 21.88 | 5.7% | 56.7% |
| 4096x4096x4096 | 14.31 | 9.60 | 1.31 | 104.96 | 0.85 | 162.46 | 5.9% | 64.6% |
| 8192x8192x8192 | 14.17 | 77.57 | 1.30 | 845.02 | 0.75 | 1475.66 | 5.3% | 57.3% |

### intel_prefetch — Register-ring + Subgroup2DBlockPrefetch (XMX tf32)

#### Precision: fast (ftz=preserve)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.52 | 0.02 | 3.04 | 0.01 | 57.5% | 200.0% |
| 512x512x512 | 9.81 | 0.03 | 5.13 | 0.05 | 9.56 | 0.03 | 97.4% | 186.3% |
| 1024x1024x1024 | 11.94 | 0.18 | 10.15 | 0.21 | 21.78 | 0.10 | 182.5% | 214.7% |
| 2048x2048x2048 | 13.83 | 1.24 | 11.25 | 1.53 | 24.69 | 0.70 | 178.5% | 219.4% |
| 4096x4096x4096 | 14.31 | 9.60 | 9.55 | 14.39 | 15.76 | 8.72 | 110.1% | 165.0% |
| 8192x8192x8192 | 14.17 | 77.57 | 7.63 | 144.06 | 11.74 | 93.63 | 82.8% | 153.9% |

### chap5_fused_epilogue — Fused ReLU epilogue on the prefetch kernel (XMX tf32)

#### Precision: fast (ftz=preserve)

| Size | Crisp_Fused_Relu (TFLOPS) | Crisp_Fused_Relu (Kernel ms) | OneDNN_Fused_Relu (TFLOPS) | OneDNN_Fused_Relu (Kernel ms) | OneMKL_Plus_Relu (TFLOPS) | OneMKL_Plus_Relu (Kernel ms) | SYCL_Apples_Relu (TFLOPS) | SYCL_Apples_Relu (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 9.60 | 0.03 | 9.81 | 0.03 | 8.58 | 0.03 | 5.13 | 0.05 | 97.8% | 187.0% |
| 1024x1024x1024 | 21.42 | 0.10 | 13.14 | 0.16 | 11.31 | 0.19 | 10.19 | 0.21 | 163.1% | 210.2% |
| 2048x2048x2048 | 24.11 | 0.71 | 14.04 | 1.22 | 13.19 | 1.30 | 11.32 | 1.52 | 171.7% | 213.1% |
| 4096x4096x4096 | 15.18 | 9.06 | 14.34 | 9.58 | 13.88 | 9.90 | 9.53 | 14.42 | 105.8% | 159.3% |

### chap6_fused_custom — Fused CUSTOM activation on the prefetch kernel (XMX tf32)

#### Precision: fast (ftz=preserve)

| Size | Crisp_Fused_Custom (TFLOPS) | Crisp_Fused_Custom (Kernel ms) | OneDNN_Plus_Custom (TFLOPS) | OneDNN_Plus_Custom (Kernel ms) | OneMKL_Plus_Custom (TFLOPS) | OneMKL_Plus_Custom (Kernel ms) | SYCL_Apples_Custom (TFLOPS) | SYCL_Apples_Custom (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 9.52 | 0.03 | 8.58 | 0.03 | 8.55 | 0.03 | 5.12 | 0.05 | 111.1% | 186.0% |
| 1024x1024x1024 | 21.18 | 0.10 | 12.87 | 0.17 | 11.30 | 0.19 | 10.15 | 0.21 | 164.5% | 208.7% |
| 2048x2048x2048 | 24.03 | 0.71 | 13.54 | 1.27 | 13.18 | 1.30 | 11.23 | 1.53 | 177.5% | 214.0% |
| 4096x4096x4096 | 16.41 | 8.38 | 13.92 | 9.87 | 13.88 | 9.90 | 9.56 | 14.37 | 117.9% | 171.5% |
> ⚠️ **No vendor library fuses this activation.** oneMKL BLAS has no epilogue parameter at all, so it pays a separate kernel and a full HBM round trip of C for *any* activation — relu included (see chap5). **oneDNN** does offer post-ops, but from a fixed set of eltwise primitives, and a quadratic sub-threshold tail is not one of them: it drops from 14.04 TF fused (chap5) to 13.54 here, while Crisp moves 24.11 → 24.03. The claim is measured, not argued.


### Compile Times (avg across precision)

| Chapter | Competitor | Avg Compile (ms) | × vs Crisp |
|---|---|---:|---:|
| chap0_sync | Crisp | 946 | 1.0× (baseline) |
| chap0_sync | SYCL_Apples | 1826 | 1.9× slower |
| chap1_async_linear | Crisp | 644 | 1.0× (baseline) |
| chap1_async_linear | SYCL_Apples | 1791 | 2.8× slower |
| intel_prefetch | Crisp | 699 | 1.0× (baseline) |
| intel_prefetch | SYCL_Apples | 1769 | 2.5× slower |
| chap5_fused_epilogue | Crisp_Fused_Relu | 687 | 1.0× (baseline) |
| chap5_fused_epilogue | OneDNN_Fused_Relu | 1833 | 2.7× slower |
| chap5_fused_epilogue | SYCL_Apples_Relu | 1717 | 2.5× slower |
| chap6_fused_custom | Crisp_Fused_Custom | 685 | 1.0× (baseline) |
| chap6_fused_custom | OneDNN_Plus_Custom | 1904 | 2.8× slower |
| chap6_fused_custom | SYCL_Apples_Custom | 1731 | 2.5× slower |

> **Device-only compilation on both sides.**  Crisp `--ir-target=spv`; the competitor `icpx -fsycl -fsycl-device-only -fsycl-targets=spir64`.  Neither figure includes host-code compilation, linking, or the runtime JIT of the resulting IR.  Library ceilings (oneMKL) are omitted — their kernels ship precompiled inside the library, so there is no device compile to measure.  Lower is better.

## Hardware: NVIDIA H100 NVL

### Summary — Crisp vs. cuBLAS ceiling (fast / tf32)

| Chapter | Technique | Size | Crisp (TFLOPS) | cuBLAS (TFLOPS) | Crisp % of cuBLAS |
|---|---|---:|---:|---:|---:|
| chap0_sync | Synchronous tiling (fp32, no tensor cores) | 4096 | 4.8 | 381.0 | 1.3% |
| chap1_async_linear | Async linear pipelining (fp32) | 4096 | 7.9 | 381.0 | 2.1% |
| chap1.5_async_block | Block TMA load + tf32 MMA | 4096 | 71.5 | 381.0 | 18.8% |
| chap2_pipelined_block | Pipelined block + tf32 MMA | 4096 | 67.9 | 381.0 | 17.8% |
| chap3_wgmma | Hopper warpgroup MMA (wgmma, tf32) | 4096 | 257.1 | 381.0 | 67.5% |
| chap5_fused_epilogue | Fused ReLU epilogue (tf32) | 4096 | 253.7 | 381.0 | 66.6% |
| chap6_fused_custom | Fused CUSTOM activation (tf32) | 4096 | 257.1 | 381.0 | 67.5% |
| c4_12 | CONTROL: cluster (1 2), multicast A only | 4096 | 243.2 | 381.0 | 63.8% |
| c4_21 | CONTROL: cluster (2 1), multicast B only | 4096 | 240.8 | 381.0 | 63.2% |
| c4_c2only | CONTROL: cluster (2 1), NO multicast | 4096 | 258.4 | 381.0 | 67.8% |
| c4_clusteronly | CONTROL: cluster (2 2), NO multicast | 4096 | 223.1 | 381.0 | 58.6% |
| chap4_cluster_multicast | SIDE CHAPTER: does TMA multicast pay? (64x128, wgmma tf32) | 4096 | 188.8 | 381.0 | 49.6% |

> Largest measured size per chapter, `fast` precision (Crisp and cuBLAS both tf32). The ladder runs low-to-high on the optimization axis for this hardware.

### chap0_sync — Synchronous tiling (fp32, no tensor cores)

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.39 | 0.01 | 2.50 | 0.01 | 0.09 | 0.38 | 1.7% | 3.6% |
| 512x512x512 | 30.58 | 0.01 | 4.34 | 0.06 | 0.35 | 0.78 | 1.1% | 8.0% |
| 1024x1024x1024 | 132.43 | 0.02 | 4.92 | 0.44 | 1.32 | 1.62 | 1.0% | 26.9% |
| 2048x2048x2048 | 318.68 | 0.05 | 5.15 | 3.33 | 4.82 | 3.56 | 1.5% | 93.6% |
| 4096x4096x4096 | 380.96 | 0.36 | 5.18 | 26.54 | 4.83 | 28.45 | 1.3% | 93.3% |

### chap1_async_linear — Async linear pipelining (fp32)

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.39 | 0.01 | 2.33 | 0.01 | 0.14 | 0.25 | 2.5% | 5.9% |
| 512x512x512 | 30.58 | 0.01 | 3.70 | 0.07 | 0.55 | 0.49 | 1.8% | 14.9% |
| 1024x1024x1024 | 132.43 | 0.02 | 4.10 | 0.52 | 2.23 | 0.96 | 1.7% | 54.3% |
| 2048x2048x2048 | 318.68 | 0.05 | 4.28 | 4.02 | 7.81 | 2.20 | 2.5% | 182.6% |
| 4096x4096x4096 | 380.96 | 0.36 | 4.31 | 31.92 | 7.89 | 17.42 | 2.1% | 183.2% |

### chap1.5_async_block — Block TMA load + tf32 MMA

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.39 | 0.01 | 2.33 | 0.01 | 1.43 | 0.02 | 26.5% | 61.3% |
| 512x512x512 | 30.58 | 0.01 | 3.69 | 0.07 | 6.31 | 0.04 | 20.6% | 171.3% |
| 1024x1024x1024 | 132.43 | 0.02 | 4.11 | 0.52 | 25.26 | 0.09 | 19.1% | 614.8% |
| 2048x2048x2048 | 318.68 | 0.05 | 4.28 | 4.02 | 68.28 | 0.25 | 21.4% | 1596.2% |
| 4096x4096x4096 | 380.96 | 0.36 | 4.30 | 31.98 | 71.55 | 1.92 | 18.8% | 1664.7% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap2_pipelined_block — Pipelined block + tf32 MMA

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.39 | 0.01 | 2.04 | 0.02 | 1.58 | 0.02 | 29.3% | 77.2% |
| 512x512x512 | 30.58 | 0.01 | 3.24 | 0.08 | 7.05 | 0.04 | 23.0% | 217.8% |
| 1024x1024x1024 | 132.43 | 0.02 | 3.56 | 0.60 | 27.33 | 0.08 | 20.6% | 767.7% |
| 2048x2048x2048 | 318.68 | 0.05 | 3.71 | 4.63 | 63.74 | 0.27 | 20.0% | 1717.7% |
| 4096x4096x4096 | 380.96 | 0.36 | 3.77 | 36.44 | 67.94 | 2.02 | 17.8% | 1801.3% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap3_wgmma — Hopper warpgroup MMA (wgmma, tf32)

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 5.39 | 0.01 | 2.50 | 0.01 | 46.4% |
| 512x512x512 | 30.58 | 0.01 | 14.98 | 0.02 | 49.0% |
| 1024x1024x1024 | 132.43 | 0.02 | 79.69 | 0.03 | 60.2% |
| 2048x2048x2048 | 318.68 | 0.05 | 238.23 | 0.07 | 74.8% |
| 4096x4096x4096 | 380.96 | 0.36 | 257.08 | 0.53 | 67.5% |

### chap5_fused_epilogue — Fused ReLU epilogue (tf32)

#### Precision: fast (ftz=preserve)

| Size | CUBLASLt_Fused_Relu (TFLOPS) | CUBLASLt_Fused_Relu (Kernel ms) | CUBLAS_Plus_Relu (TFLOPS) | CUBLAS_Plus_Relu (Kernel ms) | Crisp_Fused_Relu (TFLOPS) | Crisp_Fused_Relu (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.77 | 0.01 | 2.24 | 0.01 | 2.48 | 0.01 | 89.5% |
| 512x512x512 | 18.24 | 0.01 | 13.34 | 0.02 | 14.88 | 0.02 | 81.6% |
| 1024x1024x1024 | 79.04 | 0.03 | 60.95 | 0.04 | 79.90 | 0.03 | 101.1% |
| 2048x2048x2048 | 264.21 | 0.07 | 211.45 | 0.08 | 234.14 | 0.07 | 88.6% |
| 4096x4096x4096 | 365.78 | 0.38 | 321.05 | 0.43 | 253.68 | 0.54 | 69.4% |

### chap6_fused_custom — Fused CUSTOM activation (tf32)

#### Precision: fast (ftz=preserve)

| Size | CUBLASLt_Plus_Custom (TFLOPS) | CUBLASLt_Plus_Custom (Kernel ms) | CUBLAS_Plus_Custom (TFLOPS) | CUBLAS_Plus_Custom (Kernel ms) | Crisp_Fused_Custom (TFLOPS) | Crisp_Fused_Custom (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 1.59 | 0.02 | 1.28 | 0.03 | 2.46 | 0.01 | 154.7% |
| 512x512x512 | 12.30 | 0.02 | 9.97 | 0.03 | 14.86 | 0.02 | 120.8% |
| 1024x1024x1024 | 57.21 | 0.04 | 52.72 | 0.04 | 79.08 | 0.03 | 138.2% |
| 2048x2048x2048 | 206.17 | 0.08 | 197.96 | 0.09 | 235.90 | 0.07 | 114.4% |
| 4096x4096x4096 | 315.69 | 0.44 | 310.89 | 0.44 | 257.10 | 0.53 | 81.4% |
> ⚠️ **cuBLASLt cannot fuse this activation.** Its epilogues are a fixed enum; CUBLASLT_EPILOGUE_RELU covers chap5 but a quadratic sub-threshold tail is not in the set, so cuBLASLt falls back to a second kernel and a full HBM round trip of C. That costs it ~13-18% (418.45 → 361.83 TF at 4096; 307.31 → 251.34 at 2048), which matches the H100's HBM3 bandwidth for a 2·N² round trip. Crisp pays ~0% because its epilogue is a function the user wrote. **The gap to the best library therefore narrows from 67.4% (chap5) to 78.1% (chap6) at 4096** — that shift, not the absolute number, is what this chapter measures.


### c4_12 — CONTROL: cluster (1 2), multicast A only

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 5.39 | 0.01 | - | - | - |
| 512x512x512 | 30.58 | 0.01 | - | - | - |
| 1024x1024x1024 | 132.43 | 0.02 | 74.22 | 0.03 | 56.0% |
| 2048x2048x2048 | 318.68 | 0.05 | 227.03 | 0.08 | 71.2% |
| 4096x4096x4096 | 380.96 | 0.36 | 243.21 | 0.57 | 63.8% |

### c4_21 — CONTROL: cluster (2 1), multicast B only

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 5.39 | 0.01 | - | - | - |
| 512x512x512 | 30.58 | 0.01 | - | - | - |
| 1024x1024x1024 | 132.43 | 0.02 | 72.62 | 0.03 | 54.8% |
| 2048x2048x2048 | 318.68 | 0.05 | 218.72 | 0.08 | 68.6% |
| 4096x4096x4096 | 380.96 | 0.36 | 240.82 | 0.57 | 63.2% |

### c4_c2only — CONTROL: cluster (2 1), NO multicast

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 5.39 | 0.01 | - | - | - |
| 512x512x512 | 30.58 | 0.01 | - | - | - |
| 1024x1024x1024 | 132.43 | 0.02 | 77.14 | 0.03 | 58.3% |
| 2048x2048x2048 | 318.68 | 0.05 | 233.54 | 0.07 | 73.3% |
| 4096x4096x4096 | 380.96 | 0.36 | 258.39 | 0.53 | 67.8% |

### c4_clusteronly — CONTROL: cluster (2 2), NO multicast

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 5.39 | 0.01 | - | - | - |
| 512x512x512 | 30.58 | 0.01 | - | - | - |
| 1024x1024x1024 | 132.43 | 0.02 | 77.99 | 0.03 | 58.9% |
| 2048x2048x2048 | 318.68 | 0.05 | 138.38 | 0.12 | 43.4% |
| 4096x4096x4096 | 380.96 | 0.36 | 223.10 | 0.62 | 58.6% |

### chap4_cluster_multicast — SIDE CHAPTER: does TMA multicast pay? (64x128, wgmma tf32)

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp_Multicast (TFLOPS) | Crisp_Multicast (Kernel ms) | Crisp vs Optimal (%) | Crisp_Multicast vs Optimal (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.39 | 0.01 | 3.27 | 0.01 | 3.17 | 0.01 | 60.7% | 58.8% |
| 512x512x512 | 30.58 | 0.01 | 20.04 | 0.01 | 19.01 | 0.01 | 65.5% | 62.1% |
| 1024x1024x1024 | 132.43 | 0.02 | 100.31 | 0.02 | 94.20 | 0.02 | 75.7% | 71.1% |
| 2048x2048x2048 | 318.68 | 0.05 | 164.88 | 0.10 | 190.72 | 0.09 | 51.7% | 59.8% |
| 4096x4096x4096 | 380.96 | 0.36 | 188.77 | 0.73 | 212.81 | 0.65 | 49.6% | 55.9% |

### Compile Times (avg across precision)

| Chapter | Competitor | Avg Compile (ms) | × vs Crisp |
|---|---|---:|---:|
| chap0_sync | Crisp | 419 | 1.0× (baseline) |
| chap0_sync | CUDA_Apples | 590 | 1.4× slower |
| chap1_async_linear | Crisp | 308 | 1.0× (baseline) |
| chap1_async_linear | CUDA_Apples | 1141 | 3.7× slower |
| chap1.5_async_block | Crisp | 296 | 1.0× (baseline) |
| chap1.5_async_block | CUDA_Apples | 781 | 2.6× slower |
| chap2_pipelined_block | Crisp | 360 | 1.0× (baseline) |
| chap2_pipelined_block | CUDA_Apples | 796 | 2.2× slower |
| chap3_wgmma | Crisp | 554 | 1.0× (baseline) |
| chap5_fused_epilogue | Crisp_Fused_Relu | 774 | 1.0× (baseline) |
| chap5_fused_epilogue | CUBLASLt_Fused_Relu | 849 | 1.1× slower |
| chap6_fused_custom | Crisp_Fused_Custom | 573 | 1.0× (baseline) |
| chap6_fused_custom | CUBLASLt_Plus_Custom | 998 | 1.7× slower |
| c4_12 | Crisp | 728 | 1.0× (baseline) |
| c4_21 | Crisp | 766 | 1.0× (baseline) |
| c4_c2only | Crisp | 585 | 1.0× (baseline) |
| c4_clusteronly | Crisp | 577 | 1.0× (baseline) |
| chap4_cluster_multicast | Crisp | 301 | 1.0× (baseline) |
| chap4_cluster_multicast | Crisp_Multicast | 294 | — (Crisp variant) |

> **Device-only compilation on both sides.**  Crisp `--ir-target=ptx`; the competitor `nvcc -ptx`.  Neither figure includes host-code compilation, linking, or the driver's JIT of the resulting IR.  Library ceilings (cuBLAS) are omitted — their kernels ship precompiled inside the library, so there is no device compile to measure.  Lower is better.
