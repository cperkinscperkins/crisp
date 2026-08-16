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

## Hardware: NVIDIA H100 80GB HBM3

### Summary — Crisp vs. cuBLAS ceiling (fast / tf32)

| Chapter | Technique | Size | Crisp (TFLOPS) | cuBLAS (TFLOPS) | Crisp % of cuBLAS |
|---|---|---:|---:|---:|---:|
| chap0_sync | Synchronous tiling (fp32, no tensor cores) | 4096 | 5.7 | 432.2 | 1.3% |
| chap1_async_linear | Async linear pipelining (fp32) | 4096 | 9.0 | 432.2 | 2.1% |
| chap1.5_async_block | Block TMA load + tf32 MMA | 4096 | 80.1 | 432.2 | 18.5% |
| chap2_pipelined_block | Pipelined block + tf32 MMA | 4096 | 78.6 | 432.2 | 18.2% |
| chap3_wgmma | Hopper warpgroup MMA (wgmma, tf32) | 4096 | 287.8 | 432.2 | 66.6% |
| chap5_fused_epilogue | Fused ReLU epilogue (tf32) | 4096 | 281.8 | 432.2 | 65.2% |
| chap6_fused_custom | Fused CUSTOM activation (tf32) | 4096 | 282.7 | 432.2 | 65.4% |

> Largest measured size per chapter, `fast` precision (Crisp and cuBLAS both tf32). The ladder runs low-to-high on the optimization axis for this hardware.

### chap0_sync — Synchronous tiling (fp32, no tensor cores)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 33.73 | 0.01 | 4.72 | 0.06 | 0.38 | 0.71 | 1.1% | 8.0% |
| 1024x1024x1024 | 135.06 | 0.02 | 5.46 | 0.39 | 1.53 | 1.41 | 1.1% | 28.0% |
| 2048x2048x2048 | 356.95 | 0.05 | 5.72 | 3.00 | 5.63 | 3.05 | 1.6% | 98.5% |
| 4096x4096x4096 | 432.18 | 0.32 | 5.74 | 23.93 | 5.68 | 24.19 | 1.3% | 98.9% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 17.84 | 0.02 | 4.72 | 0.06 | 0.38 | 0.70 | 2.1% | 8.1% |
| 1024x1024x1024 | 38.50 | 0.06 | 5.45 | 0.39 | 1.55 | 1.38 | 4.0% | 28.5% |
| 2048x2048x2048 | 50.77 | 0.34 | 5.72 | 3.01 | 5.63 | 3.05 | 11.1% | 98.5% |
| 4096x4096x4096 | 52.26 | 2.63 | 5.74 | 23.93 | 5.67 | 24.23 | 10.9% | 98.8% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 17.87 | 0.02 | 4.72 | 0.06 | 0.38 | 0.70 | 2.2% | 8.1% |
| 1024x1024x1024 | 38.50 | 0.06 | 5.45 | 0.39 | 1.50 | 1.43 | 3.9% | 27.6% |
| 2048x2048x2048 | 50.77 | 0.34 | 5.72 | 3.00 | 5.63 | 3.05 | 11.1% | 98.5% |
| 4096x4096x4096 | 52.34 | 2.63 | 5.74 | 23.93 | 5.68 | 24.21 | 10.8% | 98.8% |

### chap1_async_linear — Async linear pipelining (fp32)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 33.73 | 0.01 | 4.03 | 0.07 | 0.62 | 0.44 | 1.8% | 15.3% |
| 1024x1024x1024 | 135.06 | 0.02 | 4.55 | 0.47 | 2.48 | 0.86 | 1.8% | 54.6% |
| 2048x2048x2048 | 356.95 | 0.05 | 4.74 | 3.62 | 9.09 | 1.89 | 2.5% | 191.6% |
| 4096x4096x4096 | 432.18 | 0.32 | 4.78 | 28.78 | 8.99 | 15.30 | 2.1% | 188.2% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 17.84 | 0.02 | 4.02 | 0.07 | 0.62 | 0.44 | 3.5% | 15.3% |
| 1024x1024x1024 | 38.50 | 0.06 | 4.55 | 0.47 | 2.52 | 0.85 | 6.5% | 55.4% |
| 2048x2048x2048 | 50.77 | 0.34 | 4.74 | 3.62 | 9.10 | 1.89 | 17.9% | 191.9% |
| 4096x4096x4096 | 52.26 | 2.63 | 4.78 | 28.78 | 8.99 | 15.30 | 17.2% | 188.2% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 17.87 | 0.02 | 4.02 | 0.07 | 0.62 | 0.44 | 3.5% | 15.4% |
| 1024x1024x1024 | 38.50 | 0.06 | 4.55 | 0.47 | 2.50 | 0.86 | 6.5% | 55.0% |
| 2048x2048x2048 | 50.77 | 0.34 | 4.74 | 3.62 | 9.10 | 1.89 | 17.9% | 191.9% |
| 4096x4096x4096 | 52.34 | 2.63 | 4.78 | 28.78 | 8.99 | 15.30 | 17.2% | 188.2% |

### chap1.5_async_block — Block TMA load + tf32 MMA

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 33.73 | 0.01 | 4.05 | 0.07 | 7.06 | 0.04 | 20.9% | 174.5% |
| 1024x1024x1024 | 135.06 | 0.02 | 4.58 | 0.47 | 27.83 | 0.08 | 20.6% | 607.3% |
| 2048x2048x2048 | 356.95 | 0.05 | 4.78 | 3.59 | 74.97 | 0.23 | 21.0% | 1568.2% |
| 4096x4096x4096 | 432.18 | 0.32 | 4.81 | 28.56 | 80.09 | 1.72 | 18.5% | 1664.4% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 17.84 | 0.02 | 4.02 | 0.07 | 7.06 | 0.04 | 39.6% | 175.8% |
| 1024x1024x1024 | 38.50 | 0.06 | 4.55 | 0.47 | 27.85 | 0.08 | 72.3% | 612.3% |
| 2048x2048x2048 | 50.77 | 0.34 | 4.74 | 3.62 | 75.01 | 0.23 | 147.7% | 1581.0% |
| 4096x4096x4096 | 52.26 | 2.63 | 4.78 | 28.78 | 80.16 | 1.71 | 153.4% | 1678.6% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 17.87 | 0.02 | 4.04 | 0.07 | 7.06 | 0.04 | 39.5% | 174.7% |
| 1024x1024x1024 | 38.50 | 0.06 | 4.58 | 0.47 | 28.03 | 0.08 | 72.8% | 611.7% |
| 2048x2048x2048 | 50.77 | 0.34 | 4.78 | 3.59 | 75.03 | 0.23 | 147.8% | 1569.7% |
| 4096x4096x4096 | 52.34 | 2.63 | 4.81 | 28.56 | 80.27 | 1.71 | 153.3% | 1668.2% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap2_pipelined_block — Pipelined block + tf32 MMA

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 33.73 | 0.01 | 3.58 | 0.07 | 7.96 | 0.03 | 23.6% | 222.3% |
| 1024x1024x1024 | 135.06 | 0.02 | 3.98 | 0.54 | 30.84 | 0.07 | 22.8% | 774.3% |
| 2048x2048x2048 | 356.95 | 0.05 | 4.15 | 4.14 | 72.77 | 0.24 | 20.4% | 1753.7% |
| 4096x4096x4096 | 432.18 | 0.32 | 4.22 | 32.57 | 78.63 | 1.75 | 18.2% | 1863.5% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 17.84 | 0.02 | 3.56 | 0.08 | 7.90 | 0.03 | 44.3% | 221.7% |
| 1024x1024x1024 | 38.50 | 0.06 | 3.95 | 0.54 | 31.07 | 0.07 | 80.7% | 785.7% |
| 2048x2048x2048 | 50.77 | 0.34 | 4.12 | 4.17 | 72.77 | 0.24 | 143.3% | 1766.6% |
| 4096x4096x4096 | 52.26 | 2.63 | 4.19 | 32.82 | 78.36 | 1.75 | 149.9% | 1871.1% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 17.87 | 0.02 | 3.56 | 0.08 | 7.96 | 0.03 | 44.5% | 223.4% |
| 1024x1024x1024 | 38.50 | 0.06 | 3.95 | 0.54 | 31.09 | 0.07 | 80.8% | 786.4% |
| 2048x2048x2048 | 50.77 | 0.34 | 4.12 | 4.17 | 72.73 | 0.24 | 143.3% | 1765.6% |
| 4096x4096x4096 | 52.34 | 2.63 | 4.19 | 32.82 | 78.49 | 1.75 | 150.0% | 1874.3% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap3_wgmma — Hopper warpgroup MMA (wgmma, tf32)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 512x512x512 | 33.73 | 0.01 | 16.58 | 0.02 | 49.2% |
| 1024x1024x1024 | 135.06 | 0.02 | 89.36 | 0.02 | 66.2% |
| 2048x2048x2048 | 356.95 | 0.05 | 242.83 | 0.07 | 68.0% |
| 4096x4096x4096 | 432.18 | 0.32 | 287.80 | 0.48 | 66.6% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 512x512x512 | 17.84 | 0.02 | 16.45 | 0.02 | 92.2% |
| 1024x1024x1024 | 38.50 | 0.06 | 88.76 | 0.02 | 230.5% |
| 2048x2048x2048 | 50.77 | 0.34 | 242.42 | 0.07 | 477.5% |
| 4096x4096x4096 | 52.26 | 2.63 | 287.28 | 0.48 | 549.7% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 512x512x512 | 17.87 | 0.02 | 16.48 | 0.02 | 92.2% |
| 1024x1024x1024 | 38.50 | 0.06 | 88.82 | 0.02 | 230.7% |
| 2048x2048x2048 | 50.77 | 0.34 | 242.24 | 0.07 | 477.2% |
| 4096x4096x4096 | 52.34 | 2.63 | 287.61 | 0.48 | 549.5% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### chap5_fused_epilogue — Fused ReLU epilogue (tf32)

#### Precision: fast (ftz=ftz)

| Size | CUBLASLt_Fused_Relu (TFLOPS) | CUBLASLt_Fused_Relu (Kernel ms) | CUBLAS_Plus_Relu (TFLOPS) | CUBLAS_Plus_Relu (Kernel ms) | Crisp_Fused_Relu (TFLOPS) | Crisp_Fused_Relu (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 21.24 | 0.01 | 14.24 | 0.02 | 16.71 | 0.02 | 78.7% |
| 1024x1024x1024 | 88.19 | 0.02 | 65.86 | 0.03 | 89.94 | 0.02 | 102.0% |
| 2048x2048x2048 | 307.31 | 0.06 | 241.40 | 0.07 | 241.15 | 0.07 | 78.5% |
| 4096x4096x4096 | 418.45 | 0.33 | 360.35 | 0.38 | 281.83 | 0.49 | 67.4% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLASLt_Fused_Relu (TFLOPS) | CUBLASLt_Fused_Relu (Kernel ms) | CUBLAS_Plus_Relu (TFLOPS) | CUBLAS_Plus_Relu (Kernel ms) | Crisp_Fused_Relu (TFLOPS) | Crisp_Fused_Relu (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 12.32 | 0.02 | 9.43 | 0.03 | 16.68 | 0.02 | 135.4% |
| 1024x1024x1024 | 33.83 | 0.06 | 30.15 | 0.07 | 89.69 | 0.02 | 265.2% |
| 2048x2048x2048 | 50.20 | 0.34 | 48.01 | 0.36 | 240.70 | 0.07 | 479.5% |
| 4096x4096x4096 | 52.19 | 2.63 | 51.10 | 2.69 | 282.75 | 0.49 | 541.7% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | CUBLASLt_Fused_Relu (TFLOPS) | CUBLASLt_Fused_Relu (Kernel ms) | CUBLAS_Plus_Relu (TFLOPS) | CUBLAS_Plus_Relu (Kernel ms) | Crisp_Fused_Relu (TFLOPS) | Crisp_Fused_Relu (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 12.41 | 0.02 | 9.46 | 0.03 | 16.70 | 0.02 | 134.6% |
| 1024x1024x1024 | 34.24 | 0.06 | 30.26 | 0.07 | 89.79 | 0.02 | 262.2% |
| 2048x2048x2048 | 50.26 | 0.34 | 48.06 | 0.36 | 240.89 | 0.07 | 479.2% |
| 4096x4096x4096 | 52.22 | 2.63 | 51.11 | 2.69 | 282.81 | 0.49 | 541.6% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### chap6_fused_custom — Fused CUSTOM activation (tf32)

#### Precision: fast (ftz=ftz)

| Size | CUBLASLt_Plus_Custom (TFLOPS) | CUBLASLt_Plus_Custom (Kernel ms) | CUBLAS_Plus_Custom (TFLOPS) | CUBLAS_Plus_Custom (Kernel ms) | Crisp_Fused_Custom (TFLOPS) | Crisp_Fused_Custom (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 17.48 | 0.02 | 14.34 | 0.02 | 16.80 | 0.02 | 96.1% |
| 1024x1024x1024 | 74.07 | 0.03 | 66.05 | 0.03 | 90.18 | 0.02 | 121.7% |
| 2048x2048x2048 | 251.34 | 0.07 | 240.10 | 0.07 | 240.91 | 0.07 | 95.8% |
| 4096x4096x4096 | 361.83 | 0.38 | 358.09 | 0.38 | 282.67 | 0.49 | 78.1% |
> ⚠️ **cuBLASLt cannot fuse this activation.** Its epilogues are a fixed enum; CUBLASLT_EPILOGUE_RELU covers chap5 but a quadratic sub-threshold tail is not in the set, so cuBLASLt falls back to a second kernel and a full HBM round trip of C. That costs it ~13-18% (418.45 → 361.83 TF at 4096; 307.31 → 251.34 at 2048), which matches the H100's HBM3 bandwidth for a 2·N² round trip. Crisp pays ~0% because its epilogue is a function the user wrote. **The gap to the best library therefore narrows from 67.4% (chap5) to 78.1% (chap6) at 4096** — that shift, not the absolute number, is what this chapter measures.


#### Precision: ieee (ftz=ftz)

| Size | CUBLASLt_Plus_Custom (TFLOPS) | CUBLASLt_Plus_Custom (Kernel ms) | CUBLAS_Plus_Custom (TFLOPS) | CUBLAS_Plus_Custom (Kernel ms) | Crisp_Fused_Custom (TFLOPS) | Crisp_Fused_Custom (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 10.88 | 0.02 | 9.47 | 0.03 | 16.80 | 0.02 | 154.4% |
| 1024x1024x1024 | 31.78 | 0.07 | 30.16 | 0.07 | 90.07 | 0.02 | 283.5% |
| 2048x2048x2048 | 48.20 | 0.36 | 48.01 | 0.36 | 240.59 | 0.07 | 499.2% |
| 4096x4096x4096 | 50.82 | 2.70 | 51.07 | 2.69 | 281.76 | 0.49 | 551.7% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **cuBLASLt cannot fuse this activation.** Its epilogues are a fixed enum; CUBLASLT_EPILOGUE_RELU covers chap5 but a quadratic sub-threshold tail is not in the set, so cuBLASLt falls back to a second kernel and a full HBM round trip of C. That costs it ~13-18% (418.45 → 361.83 TF at 4096; 307.31 → 251.34 at 2048), which matches the H100's HBM3 bandwidth for a 2·N² round trip. Crisp pays ~0% because its epilogue is a function the user wrote. **The gap to the best library therefore narrows from 67.4% (chap5) to 78.1% (chap6) at 4096** — that shift, not the absolute number, is what this chapter measures.


#### Precision: ieee (ftz=preserve)

| Size | CUBLASLt_Plus_Custom (TFLOPS) | CUBLASLt_Plus_Custom (Kernel ms) | CUBLAS_Plus_Custom (TFLOPS) | CUBLAS_Plus_Custom (Kernel ms) | Crisp_Fused_Custom (TFLOPS) | Crisp_Fused_Custom (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|---:|---:|
| 512x512x512 | 10.94 | 0.02 | 9.46 | 0.03 | 16.81 | 0.02 | 153.7% |
| 1024x1024x1024 | 31.90 | 0.07 | 30.12 | 0.07 | 90.11 | 0.02 | 282.5% |
| 2048x2048x2048 | 48.52 | 0.35 | 48.02 | 0.36 | 240.77 | 0.07 | 496.2% |
| 4096x4096x4096 | 51.17 | 2.69 | 51.08 | 2.69 | 283.30 | 0.49 | 553.7% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **cuBLASLt cannot fuse this activation.** Its epilogues are a fixed enum; CUBLASLT_EPILOGUE_RELU covers chap5 but a quadratic sub-threshold tail is not in the set, so cuBLASLt falls back to a second kernel and a full HBM round trip of C. That costs it ~13-18% (418.45 → 361.83 TF at 4096; 307.31 → 251.34 at 2048), which matches the H100's HBM3 bandwidth for a 2·N² round trip. Crisp pays ~0% because its epilogue is a function the user wrote. **The gap to the best library therefore narrows from 67.4% (chap5) to 78.1% (chap6) at 4096** — that shift, not the absolute number, is what this chapter measures.


### Compile Times (avg across precision)

| Chapter | Competitor | Avg Compile (ms) | × vs Crisp |
|---|---|---:|---:|
| chap0_sync | Crisp | 262 | 1.0× (baseline) |
| chap0_sync | CUDA_Apples | 378 | 1.4× slower |
| chap1_async_linear | Crisp | 269 | 1.0× (baseline) |
| chap1_async_linear | CUDA_Apples | 690 | 2.6× slower |
| chap1.5_async_block | Crisp | 256 | 1.0× (baseline) |
| chap1.5_async_block | CUDA_Apples | 683 | 2.7× slower |
| chap2_pipelined_block | Crisp | 334 | 1.0× (baseline) |
| chap2_pipelined_block | CUDA_Apples | 704 | 2.1× slower |
| chap3_wgmma | Crisp | 357 | 1.0× (baseline) |
| chap5_fused_epilogue | Crisp_Fused_Relu | 483 | 1.0× (baseline) |
| chap5_fused_epilogue | CUBLASLt_Fused_Relu | 504 | 1.0× slower |
| chap6_fused_custom | Crisp_Fused_Custom | 499 | 1.0× (baseline) |
| chap6_fused_custom | CUBLASLt_Plus_Custom | 509 | 1.0× slower |

> **Device-only compilation on both sides.**  Crisp `--ir-target=ptx`; the competitor `nvcc -ptx`.  Neither figure includes host-code compilation, linking, or the driver's JIT of the resulting IR.  Library ceilings (cuBLAS) are omitted — their kernels ship precompiled inside the library, so there is no device compile to measure.  Lower is better.

## Hardware: NVIDIA H100 PCIe

### Summary — Crisp vs. cuBLAS ceiling (fast / tf32)

| Chapter | Technique | Size | Crisp (TFLOPS) | cuBLAS (TFLOPS) | Crisp % of cuBLAS |
|---|---|---:|---:|---:|---:|
| chap0_sync | Synchronous tiling (fp32, no tensor cores) | 2048 | 2.7 | 198.4 | 1.4% |
| chap1_async_linear | Async linear pipelining (fp32) | 2048 | 4.1 | 198.4 | 2.1% |
| chap1.5_async_block | Block TMA load + tf32 MMA | 2048 | 37.0 | 198.4 | 18.6% |
| chap2_pipelined_block | Pipelined block + tf32 MMA | 2048 | 39.1 | 198.4 | 19.7% |
| chap3_wgmma | Hopper warpgroup MMA (wgmma, tf32) | 2048 | 126.2 | 198.4 | 63.6% |

> Largest measured size per chapter, `fast` precision (Crisp and cuBLAS both tf32). The ladder runs low-to-high on the optimization axis for this hardware.

### chap0_sync — Synchronous tiling (fp32, no tensor cores)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 4.68 | 0.01 | 2.07 | 0.02 | 0.09 | 0.38 | 1.9% | 4.3% |
| 512x512x512 | 28.66 | 0.01 | 3.53 | 0.08 | 0.34 | 0.78 | 1.2% | 9.7% |
| 1024x1024x1024 | 106.06 | 0.02 | 4.32 | 0.50 | 1.38 | 1.56 | 1.3% | 31.9% |
| 2048x2048x2048 | 198.36 | 0.09 | 4.43 | 3.88 | 2.68 | 6.40 | 1.4% | 60.6% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.89 | 0.01 | 2.08 | 0.02 | 0.09 | 0.38 | 3.1% | 4.3% |
| 512x512x512 | 13.81 | 0.02 | 3.52 | 0.08 | 0.34 | 0.79 | 2.5% | 9.7% |
| 1024x1024x1024 | 27.86 | 0.08 | 4.30 | 0.50 | 1.37 | 1.57 | 4.9% | 31.9% |
| 2048x2048x2048 | 34.34 | 0.50 | 4.40 | 3.90 | 2.66 | 6.47 | 7.7% | 60.4% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.95 | 0.01 | 2.07 | 0.02 | 0.09 | 0.38 | 3.0% | 4.3% |
| 512x512x512 | 13.43 | 0.02 | 3.52 | 0.08 | 0.34 | 0.78 | 2.6% | 9.8% |
| 1024x1024x1024 | 27.69 | 0.08 | 4.31 | 0.50 | 1.37 | 1.57 | 4.9% | 31.8% |
| 2048x2048x2048 | 34.14 | 0.50 | 4.40 | 3.90 | 2.68 | 6.40 | 7.9% | 61.0% |

### chap1_async_linear — Async linear pipelining (fp32)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 4.68 | 0.01 | 1.80 | 0.02 | 0.14 | 0.25 | 2.9% | 7.5% |
| 512x512x512 | 28.66 | 0.01 | 3.21 | 0.08 | 0.55 | 0.49 | 1.9% | 17.1% |
| 1024x1024x1024 | 106.06 | 0.02 | 3.59 | 0.60 | 2.18 | 0.98 | 2.1% | 60.9% |
| 2048x2048x2048 | 198.36 | 0.09 | 3.65 | 4.70 | 4.09 | 4.20 | 2.1% | 111.9% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.89 | 0.01 | 1.80 | 0.02 | 0.13 | 0.25 | 4.7% | 7.5% |
| 512x512x512 | 13.81 | 0.02 | 3.26 | 0.08 | 0.55 | 0.49 | 4.0% | 16.9% |
| 1024x1024x1024 | 27.86 | 0.08 | 3.61 | 0.60 | 2.14 | 1.00 | 7.7% | 59.3% |
| 2048x2048x2048 | 34.34 | 0.50 | 3.68 | 4.67 | 4.09 | 4.20 | 11.9% | 111.1% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.95 | 0.01 | 1.80 | 0.02 | 0.13 | 0.25 | 4.6% | 7.5% |
| 512x512x512 | 13.43 | 0.02 | 3.24 | 0.08 | 0.55 | 0.49 | 4.1% | 17.0% |
| 1024x1024x1024 | 27.69 | 0.08 | 3.58 | 0.60 | 2.15 | 1.00 | 7.7% | 59.8% |
| 2048x2048x2048 | 34.14 | 0.50 | 3.65 | 4.70 | 4.08 | 4.21 | 11.9% | 111.6% |

### chap1.5_async_block — Block TMA load + tf32 MMA

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 4.68 | 0.01 | 1.81 | 0.02 | 1.43 | 0.02 | 30.6% | 79.1% |
| 512x512x512 | 28.66 | 0.01 | 3.18 | 0.08 | 6.42 | 0.04 | 22.4% | 201.7% |
| 1024x1024x1024 | 106.06 | 0.02 | 3.59 | 0.60 | 24.91 | 0.09 | 23.5% | 694.7% |
| 2048x2048x2048 | 198.36 | 0.09 | 3.65 | 4.70 | 36.98 | 0.46 | 18.6% | 1012.5% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.89 | 0.01 | 1.80 | 0.02 | 1.44 | 0.02 | 49.9% | 79.9% |
| 512x512x512 | 13.81 | 0.02 | 3.22 | 0.08 | 6.42 | 0.04 | 46.5% | 199.7% |
| 1024x1024x1024 | 27.86 | 0.08 | 3.59 | 0.60 | 25.16 | 0.09 | 90.3% | 701.6% |
| 2048x2048x2048 | 34.34 | 0.50 | 3.65 | 4.70 | 36.83 | 0.47 | 107.2% | 1008.2% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.95 | 0.01 | 1.82 | 0.02 | 1.44 | 0.02 | 48.6% | 79.0% |
| 512x512x512 | 13.43 | 0.02 | 3.24 | 0.08 | 6.42 | 0.04 | 47.8% | 198.0% |
| 1024x1024x1024 | 27.69 | 0.08 | 3.59 | 0.60 | 25.02 | 0.09 | 90.3% | 697.6% |
| 2048x2048x2048 | 34.14 | 0.50 | 3.65 | 4.70 | 36.92 | 0.47 | 108.1% | 1010.8% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap2_pipelined_block — Pipelined block + tf32 MMA

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 4.68 | 0.01 | 1.59 | 0.02 | 1.69 | 0.02 | 36.0% | 106.1% |
| 512x512x512 | 28.66 | 0.01 | 2.89 | 0.09 | 7.69 | 0.03 | 26.8% | 266.2% |
| 1024x1024x1024 | 106.06 | 0.02 | 3.14 | 0.68 | 28.63 | 0.08 | 27.0% | 910.4% |
| 2048x2048x2048 | 198.36 | 0.09 | 3.20 | 5.38 | 39.09 | 0.44 | 19.7% | 1223.1% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.89 | 0.01 | 1.58 | 0.02 | 1.69 | 0.02 | 58.4% | 106.5% |
| 512x512x512 | 13.81 | 0.02 | 2.86 | 0.09 | 7.71 | 0.03 | 55.8% | 269.2% |
| 1024x1024x1024 | 27.86 | 0.08 | 3.12 | 0.69 | 28.65 | 0.07 | 102.9% | 919.3% |
| 2048x2048x2048 | 34.34 | 0.50 | 3.17 | 5.42 | 38.42 | 0.45 | 111.9% | 1212.9% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.95 | 0.01 | 1.58 | 0.02 | 1.67 | 0.02 | 56.6% | 105.7% |
| 512x512x512 | 13.43 | 0.02 | 2.86 | 0.09 | 7.66 | 0.04 | 57.1% | 268.2% |
| 1024x1024x1024 | 27.69 | 0.08 | 3.12 | 0.69 | 28.58 | 0.08 | 103.2% | 916.9% |
| 2048x2048x2048 | 34.14 | 0.50 | 3.17 | 5.42 | 39.15 | 0.44 | 114.7% | 1235.6% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap3_wgmma — Hopper warpgroup MMA (wgmma, tf32)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 4.68 | 0.01 | 2.33 | 0.01 | 49.9% |
| 512x512x512 | 28.66 | 0.01 | 13.98 | 0.02 | 48.8% |
| 1024x1024x1024 | 106.06 | 0.02 | 74.73 | 0.03 | 70.5% |
| 2048x2048x2048 | 198.36 | 0.09 | 126.22 | 0.14 | 63.6% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 2.89 | 0.01 | 2.34 | 0.01 | 81.2% |
| 512x512x512 | 13.81 | 0.02 | 14.05 | 0.02 | 101.7% |
| 1024x1024x1024 | 27.86 | 0.08 | 74.79 | 0.03 | 268.5% |
| 2048x2048x2048 | 34.34 | 0.50 | 126.25 | 0.14 | 367.6% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 2.95 | 0.01 | 2.31 | 0.01 | 78.4% |
| 512x512x512 | 13.43 | 0.02 | 14.02 | 0.02 | 104.4% |
| 1024x1024x1024 | 27.69 | 0.08 | 74.61 | 0.03 | 269.5% |
| 2048x2048x2048 | 34.14 | 0.50 | 126.53 | 0.14 | 370.6% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### Compile Times (avg across precision)

| Chapter | Competitor | Avg Compile (ms) | × vs Crisp |
|---|---|---:|---:|
| chap0_sync | Crisp | 504 | 1.0× (baseline) |
| chap0_sync | CUDA_Apples | 681 | 1.4× slower |
| chap1_async_linear | Crisp | 521 | 1.0× (baseline) |
| chap1_async_linear | CUDA_Apples | 1298 | 2.5× slower |
| chap1.5_async_block | Crisp | 502 | 1.0× (baseline) |
| chap1.5_async_block | CUDA_Apples | 1356 | 2.7× slower |
| chap2_pipelined_block | Crisp | 620 | 1.0× (baseline) |
| chap2_pipelined_block | CUDA_Apples | 1316 | 2.1× slower |
| chap3_wgmma | Crisp | 648 | 1.0× (baseline) |

> **Device-only compilation on both sides.**  Crisp `--ir-target=ptx`; the competitor `nvcc -ptx`.  Neither figure includes host-code compilation, linking, or the driver's JIT of the resulting IR.  Library ceilings (cuBLAS) are omitted — their kernels ship precompiled inside the library, so there is no device compile to measure.  Lower is better.
