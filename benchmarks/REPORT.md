# Crisp Benchmark Report

## Hardware: Intel BMG

### Summary — Crisp vs. oneMKL ceiling (fast / tf32)

| Chapter | Technique | Size | Crisp (TFLOPS) | oneMKL (TFLOPS) | Crisp % of oneMKL |
|---|---|---:|---:|---:|---:|
| chap0_sync | Synchronous coop-matrix tiling (XMX tf32) | 2048 | 1.5 | 13.8 | 10.9% |
| chap1_async_linear | OpGroupAsyncCopy staging (XMX tf32) | 2048 | 0.8 | 13.8 | 6.1% |
| intel_prefetch | Register-ring + Subgroup2DBlockPrefetch (XMX tf32) | 2048 | 24.2 | 13.8 | 175.0% |

> Largest measured size per chapter, `fast` precision (Crisp and oneMKL both tf32). The ladder runs low-to-high on the optimization axis for this hardware.

### chap0_sync — Synchronous coop-matrix tiling (XMX tf32)

#### Precision: fast (ftz=preserve)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.33 | 0.03 | 0.11 | 0.30 | 2.1% | 8.5% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.41 | 0.66 | 4.2% | 27.9% |
| 1024x1024x1024 | 11.98 | 0.18 | 1.53 | 1.40 | 1.46 | 1.47 | 12.2% | 95.5% |
| 2048x2048x2048 | 13.82 | 1.24 | 1.48 | 11.58 | 1.50 | 11.42 | 10.9% | 101.5% |

### chap1_async_linear — OpGroupAsyncCopy staging (XMX tf32)

#### Precision: fast (ftz=preserve)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.32 | 0.03 | 0.08 | 0.41 | 1.5% | 6.2% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.26 | 1.02 | 2.7% | 18.0% |
| 1024x1024x1024 | 11.98 | 0.18 | 1.53 | 1.40 | 0.80 | 2.68 | 6.7% | 52.4% |
| 2048x2048x2048 | 13.82 | 1.24 | 1.48 | 11.59 | 0.84 | 20.55 | 6.1% | 56.4% |

### intel_prefetch — Register-ring + Subgroup2DBlockPrefetch (XMX tf32)

#### Precision: fast (ftz=preserve)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.99 | 0.02 | 3.07 | 0.01 | 58.1% | 154.3% |
| 512x512x512 | 9.81 | 0.03 | 4.19 | 0.06 | 9.56 | 0.03 | 97.4% | 228.1% |
| 1024x1024x1024 | 11.98 | 0.18 | 6.84 | 0.31 | 21.44 | 0.10 | 179.0% | 313.5% |
| 2048x2048x2048 | 13.82 | 1.24 | 7.54 | 2.28 | 24.19 | 0.71 | 175.0% | 320.8% |

### Compile Times (avg across precision)

| Chapter | Competitor | Avg Compile (ms) | × vs Crisp |
|---|---|---:|---:|
| chap0_sync | Crisp | 678 | 1.0× (baseline) |
| chap0_sync | SYCL_Apples | 1894 | 2.8× slower |
| chap1_async_linear | Crisp | 760 | 1.0× (baseline) |
| chap1_async_linear | SYCL_Apples | 1828 | 2.4× slower |
| intel_prefetch | Crisp | 659 | 1.0× (baseline) |
| intel_prefetch | SYCL_Apples | 1884 | 2.9× slower |

> **Device-only compilation on both sides.**  Crisp `--ir-target=spv`; the competitor `icpx -fsycl -fsycl-device-only -fsycl-targets=spir64`.  Neither figure includes host-code compilation, linking, or the runtime JIT of the resulting IR.  Library ceilings (oneMKL) are omitted — their kernels ship precompiled inside the library, so there is no device compile to measure.  Lower is better.

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
