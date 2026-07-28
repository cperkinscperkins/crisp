# Crisp Benchmark Report

## Hardware: Intel BMG

### Summary — Crisp vs. oneMKL ceiling (fast / tf32)

| Chapter | Technique | Size | Crisp (TFLOPS) | oneMKL (TFLOPS) | Crisp % of oneMKL |
|---|---|---:|---:|---:|---:|
| chap0_sync | Synchronous coop-matrix tiling (XMX tf32) | 1024 | 1.5 | 12.0 | 12.5% |
| chap1_async_linear | OpGroupAsyncCopy staging (XMX tf32) | 1024 | 0.8 | 12.0 | 6.5% |
| intel_prefetch | Register-ring + Subgroup2DBlockPrefetch (XMX tf32) | 1024 | 23.7 | 12.0 | 198.0% |

> Largest measured size per chapter, `fast` precision (Crisp and oneMKL both tf32). The ladder runs low-to-high on the optimization axis for this hardware.

### chap0_sync — Synchronous coop-matrix tiling (XMX tf32)

#### Precision: fast (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.31 | 0.03 | 0.11 | 0.29 | 2.2% | 8.7% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.42 | 0.64 | 4.2% | 28.4% |
| 1024x1024x1024 | 11.97 | 0.18 | 1.53 | 1.40 | 1.49 | 1.44 | 12.5% | 97.4% |

#### Precision: ieee (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.32 | 0.03 | 0.11 | 0.29 | 2.2% | 8.6% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.42 | 0.65 | 4.2% | 28.3% |
| 1024x1024x1024 | 11.98 | 0.18 | 1.54 | 1.40 | 1.50 | 1.44 | 12.5% | 97.2% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.32 | 0.03 | 0.11 | 0.29 | 2.2% | 8.6% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.42 | 0.65 | 4.2% | 28.3% |
| 1024x1024x1024 | 11.97 | 0.18 | 1.53 | 1.40 | 1.49 | 1.44 | 12.5% | 97.6% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### chap1_async_linear — OpGroupAsyncCopy staging (XMX tf32)

#### Precision: fast (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.32 | 0.03 | 0.08 | 0.41 | 1.6% | 6.2% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.26 | 1.05 | 2.6% | 17.5% |
| 1024x1024x1024 | 11.97 | 0.18 | 1.53 | 1.40 | 0.78 | 2.74 | 6.5% | 51.2% |

#### Precision: ieee (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.32 | 0.03 | 0.08 | 0.41 | 1.6% | 6.2% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.26 | 1.04 | 2.6% | 17.6% |
| 1024x1024x1024 | 11.98 | 0.18 | 1.53 | 1.40 | 0.78 | 2.74 | 6.5% | 51.2% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.32 | 0.03 | 0.08 | 0.41 | 1.6% | 6.2% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.26 | 1.04 | 2.6% | 17.6% |
| 1024x1024x1024 | 11.97 | 0.18 | 1.53 | 1.40 | 0.78 | 2.74 | 6.5% | 51.1% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### intel_prefetch — Register-ring + Subgroup2DBlockPrefetch (XMX tf32)

#### Precision: fast (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 2.02 | 0.02 | 3.19 | 0.01 | 60.4% | 158.4% |
| 512x512x512 | 9.81 | 0.03 | 4.19 | 0.06 | 10.98 | 0.02 | 111.9% | 262.1% |
| 1024x1024x1024 | 11.97 | 0.18 | 6.88 | 0.31 | 23.71 | 0.09 | 198.0% | 344.8% |

#### Precision: ieee (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 2.02 | 0.02 | 3.19 | 0.01 | 60.4% | 158.4% |
| 512x512x512 | 9.81 | 0.03 | 4.17 | 0.06 | 10.98 | 0.02 | 111.9% | 263.4% |
| 1024x1024x1024 | 11.98 | 0.18 | 6.89 | 0.31 | 23.63 | 0.09 | 197.3% | 342.8% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 2.02 | 0.02 | 3.23 | 0.01 | 61.0% | 160.0% |
| 512x512x512 | 9.81 | 0.03 | 4.20 | 0.06 | 10.98 | 0.02 | 111.9% | 261.3% |
| 1024x1024x1024 | 11.97 | 0.18 | 6.88 | 0.31 | 23.57 | 0.09 | 196.9% | 342.8% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### Compile Times (avg across precision)

| Chapter | Competitor | Avg Compile (ms) | × vs Crisp |
|---|---|---:|---:|
| chap0_sync | Crisp | 809 | 1.0× (baseline) |
| chap0_sync | OneMKL_Optimal | 6567 | 8.1× slower |
| chap0_sync | SYCL_Apples | 4298 | 5.3× slower |
| chap1_async_linear | Crisp | 664 | 1.0× (baseline) |
| chap1_async_linear | SYCL_Apples | 4082 | 6.2× slower |
| intel_prefetch | Crisp | 1425 | 1.0× (baseline) |
| intel_prefetch | SYCL_Apples | 3947 | 2.8× slower |

> Crisp compiles a kernel to SPIR-V; the native competitors invoke `icpx` (SYCL / oneMKL). Lower is better; `× vs Crisp` is how much longer than Crisp that toolchain takes.

## Hardware: NVIDIA H100 PCIe

### Summary — Crisp vs. cuBLAS ceiling (fast / tf32)

| Chapter | Technique | Size | Crisp (TFLOPS) | cuBLAS (TFLOPS) | Crisp % of cuBLAS |
|---|---|---:|---:|---:|---:|
| chap0_sync | Synchronous tiling (fp32, no tensor cores) | 4096 | 4.0 | 298.7 | 1.3% |
| chap1_async_linear | Async linear pipelining (fp32) | 4096 | 6.5 | 298.7 | 2.2% |
| chap1.5_async_block | Block TMA load + tf32 MMA | 4096 | 59.7 | 298.7 | 20.0% |
| chap2_pipelined_block | Pipelined block + tf32 MMA | 4096 | 55.8 | 298.7 | 18.7% |
| chap3_wgmma | Hopper warpgroup MMA (wgmma, tf32) | 4096 | 207.6 | 298.7 | 69.5% |

> Largest measured size per chapter, `fast` precision (Crisp and cuBLAS both tf32). The ladder runs low-to-high on the optimization axis for this hardware.

### chap0_sync — Synchronous tiling (fp32, no tensor cores)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1024x1024x1024 | 104.71 | 0.02 | 4.30 | 0.50 | 1.37 | 1.56 | 1.3% | 31.9% |
| 2048x2048x2048 | 199.90 | 0.09 | 4.40 | 3.90 | 2.58 | 6.66 | 1.3% | 58.6% |
| 4096x4096x4096 | 298.69 | 0.46 | 4.40 | 31.21 | 4.03 | 34.09 | 1.3% | 91.5% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.62 | 0.01 | 2.06 | 0.02 | 0.09 | 0.38 | 2.4% | 4.3% |
| 512x512x512 | 14.23 | 0.02 | 3.49 | 0.08 | 0.34 | 0.79 | 2.4% | 9.7% |
| 1024x1024x1024 | 28.04 | 0.08 | 4.28 | 0.50 | 1.32 | 1.63 | 4.7% | 30.8% |
| 2048x2048x2048 | 34.45 | 0.50 | 4.39 | 3.91 | 2.62 | 6.57 | 7.6% | 59.6% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.77 | 0.01 | 2.07 | 0.02 | 0.09 | 0.38 | 2.4% | 4.3% |
| 512x512x512 | 14.08 | 0.02 | 3.51 | 0.08 | 0.34 | 0.79 | 2.4% | 9.7% |
| 1024x1024x1024 | 28.18 | 0.08 | 4.29 | 0.50 | 1.32 | 1.63 | 4.7% | 30.6% |
| 2048x2048x2048 | 34.43 | 0.50 | 4.40 | 3.91 | 2.63 | 6.54 | 7.6% | 59.8% |

### chap1_async_linear — Async linear pipelining (fp32)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1024x1024x1024 | 104.71 | 0.02 | 3.57 | 0.60 | 2.12 | 1.01 | 2.0% | 59.3% |
| 2048x2048x2048 | 199.90 | 0.09 | 3.65 | 4.71 | 3.98 | 4.32 | 2.0% | 109.0% |
| 4096x4096x4096 | 298.69 | 0.46 | 3.66 | 37.58 | 6.48 | 21.22 | 2.2% | 177.1% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.62 | 0.01 | 1.80 | 0.02 | 0.13 | 0.25 | 3.7% | 7.5% |
| 512x512x512 | 14.23 | 0.02 | 3.23 | 0.08 | 0.55 | 0.49 | 3.8% | 16.9% |
| 1024x1024x1024 | 28.04 | 0.08 | 3.58 | 0.60 | 2.11 | 1.02 | 7.5% | 59.0% |
| 2048x2048x2048 | 34.45 | 0.50 | 3.64 | 4.71 | 3.96 | 4.34 | 11.5% | 108.6% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.77 | 0.01 | 1.82 | 0.02 | 0.13 | 0.25 | 3.6% | 7.4% |
| 512x512x512 | 14.08 | 0.02 | 3.22 | 0.08 | 0.55 | 0.49 | 3.9% | 17.0% |
| 1024x1024x1024 | 28.18 | 0.08 | 3.56 | 0.60 | 2.11 | 1.02 | 7.5% | 59.2% |
| 2048x2048x2048 | 34.43 | 0.50 | 3.65 | 4.71 | 3.97 | 4.33 | 11.5% | 108.7% |

### chap1.5_async_block — Block TMA load + tf32 MMA

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1024x1024x1024 | 104.71 | 0.02 | 3.60 | 0.60 | 25.20 | 0.09 | 24.1% | 699.6% |
| 2048x2048x2048 | 199.90 | 0.09 | 3.68 | 4.67 | 36.94 | 0.47 | 18.5% | 1003.9% |
| 4096x4096x4096 | 298.69 | 0.46 | 3.69 | 37.29 | 59.74 | 2.30 | 20.0% | 1620.8% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.62 | 0.01 | 1.80 | 0.02 | 1.44 | 0.02 | 39.7% | 79.6% |
| 512x512x512 | 14.23 | 0.02 | 3.23 | 0.08 | 6.34 | 0.04 | 44.5% | 196.5% |
| 1024x1024x1024 | 28.04 | 0.08 | 3.56 | 0.60 | 24.24 | 0.09 | 86.4% | 681.3% |
| 2048x2048x2048 | 34.45 | 0.50 | 3.67 | 4.68 | 36.09 | 0.48 | 104.8% | 982.9% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.77 | 0.01 | 1.78 | 0.02 | 1.44 | 0.02 | 38.3% | 80.9% |
| 512x512x512 | 14.08 | 0.02 | 3.23 | 0.08 | 6.30 | 0.04 | 44.8% | 195.4% |
| 1024x1024x1024 | 28.18 | 0.08 | 3.56 | 0.60 | 24.15 | 0.09 | 85.7% | 679.0% |
| 2048x2048x2048 | 34.43 | 0.50 | 3.65 | 4.71 | 35.83 | 0.48 | 104.1% | 982.2% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap2_pipelined_block — Pipelined block + tf32 MMA

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1024x1024x1024 | 104.71 | 0.02 | 3.14 | 0.68 | 28.82 | 0.07 | 27.5% | 919.0% |
| 2048x2048x2048 | 199.90 | 0.09 | 3.19 | 5.39 | 39.17 | 0.44 | 19.6% | 1227.9% |
| 4096x4096x4096 | 298.69 | 0.46 | 3.23 | 42.51 | 55.75 | 2.47 | 18.7% | 1724.4% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.62 | 0.01 | 1.59 | 0.02 | 1.59 | 0.02 | 44.0% | 100.5% |
| 512x512x512 | 14.23 | 0.02 | 2.84 | 0.09 | 7.05 | 0.04 | 49.5% | 248.4% |
| 1024x1024x1024 | 28.04 | 0.08 | 3.09 | 0.69 | 26.01 | 0.08 | 92.8% | 840.9% |
| 2048x2048x2048 | 34.45 | 0.50 | 3.16 | 5.43 | 39.45 | 0.44 | 114.5% | 1247.1% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.77 | 0.01 | 1.54 | 0.02 | 1.58 | 0.02 | 42.0% | 102.5% |
| 512x512x512 | 14.08 | 0.02 | 2.86 | 0.09 | 6.98 | 0.04 | 49.6% | 244.0% |
| 1024x1024x1024 | 28.18 | 0.08 | 3.11 | 0.69 | 26.02 | 0.08 | 92.3% | 837.5% |
| 2048x2048x2048 | 34.43 | 0.50 | 3.16 | 5.43 | 39.13 | 0.44 | 113.6% | 1236.8% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap3_wgmma — Hopper warpgroup MMA (wgmma, tf32)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 1024x1024x1024 | 104.71 | 0.02 | 75.31 | 0.03 | 71.9% |
| 2048x2048x2048 | 199.90 | 0.09 | 124.80 | 0.14 | 62.4% |
| 4096x4096x4096 | 298.69 | 0.46 | 207.64 | 0.66 | 69.5% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 3.62 | 0.01 | 2.42 | 0.01 | 66.9% |
| 512x512x512 | 14.23 | 0.02 | 14.79 | 0.02 | 103.9% |
| 1024x1024x1024 | 28.04 | 0.08 | 79.40 | 0.03 | 283.1% |
| 2048x2048x2048 | 34.45 | 0.50 | 127.17 | 0.14 | 369.2% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 3.77 | 0.01 | 2.42 | 0.01 | 64.3% |
| 512x512x512 | 14.08 | 0.02 | 14.81 | 0.02 | 105.1% |
| 1024x1024x1024 | 28.18 | 0.08 | 78.96 | 0.03 | 280.2% |
| 2048x2048x2048 | 34.43 | 0.50 | 127.79 | 0.13 | 371.1% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### Compile Times (avg across precision)

| Chapter | Competitor | Avg Compile (ms) | × vs Crisp |
|---|---|---:|---:|
| chap0_sync | Crisp | 354 | 1.0× (baseline) |
| chap0_sync | CUBLAS_Optimal | 1400 | 4.0× slower |
| chap0_sync | CUDA_Apples | 1648 | 4.7× slower |
| chap1_async_linear | Crisp | 350 | 1.0× (baseline) |
| chap1_async_linear | CUDA_Apples | 2960 | 8.5× slower |
| chap1.5_async_block | Crisp | 336 | 1.0× (baseline) |
| chap1.5_async_block | CUDA_Apples | 2847 | 8.5× slower |
| chap2_pipelined_block | Crisp | 413 | 1.0× (baseline) |
| chap2_pipelined_block | CUDA_Apples | 2761 | 6.7× slower |
| chap3_wgmma | Crisp | 430 | 1.0× (baseline) |
| chap3_wgmma | CUBLAS_Optimal | 1466 | 3.4× slower |

> Crisp compiles a kernel to PTX; the native competitors invoke `nvcc`. Lower is better; `× vs Crisp` is how much longer than Crisp that toolchain takes.
