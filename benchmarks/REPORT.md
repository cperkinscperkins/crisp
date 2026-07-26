# Crisp Benchmark Report

## Hardware: Intel BMG

### Summary — Crisp vs. oneMKL ceiling (fast / tf32)

| Chapter | Technique | Size | Crisp (TFLOPS) | oneMKL (TFLOPS) | Crisp % of oneMKL |
|---|---|---:|---:|---:|---:|
| chap0_sync | Synchronous coop-matrix tiling (XMX tf32) | 1024 | 1.5 | 12.0 | 12.5% |
| chap1_async_linear | OpGroupAsyncCopy staging (XMX tf32) | 1024 | 0.8 | 12.0 | 6.6% |
| intel_prefetch | Register-ring + Subgroup2DBlockPrefetch (XMX tf32) | 1024 | 10.4 | 12.0 | 86.5% |

> Largest measured size per chapter, `fast` precision (Crisp and oneMKL both tf32). The ladder runs low-to-high on the optimization axis for this hardware.

### chap0_sync — Synchronous coop-matrix tiling (XMX tf32)

#### Precision: fast (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.20 | 0.01 | 1.32 | 0.03 | 0.11 | 0.29 | 2.2% | 8.6% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.42 | 0.64 | 4.2% | 28.4% |
| 1024x1024x1024 | 11.98 | 0.18 | 1.54 | 1.40 | 1.49 | 1.44 | 12.5% | 97.0% |

#### Precision: ieee (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.31 | 0.03 | 0.11 | 0.29 | 2.2% | 8.7% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.42 | 0.64 | 4.2% | 28.4% |
| 1024x1024x1024 | 11.98 | 0.18 | 1.53 | 1.40 | 1.49 | 1.44 | 12.4% | 97.5% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.20 | 0.01 | 1.32 | 0.03 | 0.11 | 0.29 | 2.2% | 8.6% |
| 512x512x512 | 9.78 | 0.03 | 1.47 | 0.18 | 0.42 | 0.65 | 4.3% | 28.4% |
| 1024x1024x1024 | 11.97 | 0.18 | 1.53 | 1.40 | 1.49 | 1.44 | 12.5% | 97.5% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### chap1_async_linear — OpGroupAsyncCopy staging (XMX tf32)

#### Precision: fast (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.20 | 0.01 | 1.32 | 0.03 | 0.08 | 0.41 | 1.6% | 6.2% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.26 | 1.04 | 2.6% | 17.5% |
| 1024x1024x1024 | 11.98 | 0.18 | 1.53 | 1.40 | 0.78 | 2.74 | 6.6% | 51.3% |

#### Precision: ieee (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.32 | 0.03 | 0.08 | 0.41 | 1.6% | 6.2% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.26 | 1.04 | 2.6% | 17.5% |
| 1024x1024x1024 | 11.98 | 0.18 | 1.53 | 1.40 | 0.78 | 2.74 | 6.5% | 51.1% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.20 | 0.01 | 1.31 | 0.03 | 0.08 | 0.41 | 1.6% | 6.3% |
| 512x512x512 | 9.78 | 0.03 | 1.47 | 0.18 | 0.26 | 1.04 | 2.6% | 17.5% |
| 1024x1024x1024 | 11.97 | 0.18 | 1.53 | 1.40 | 0.78 | 2.75 | 6.5% | 51.1% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### intel_prefetch — Register-ring + Subgroup2DBlockPrefetch (XMX tf32)

#### Precision: fast (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.20 | 0.01 | 2.02 | 0.02 | 2.15 | 0.02 | 41.3% | 106.7% |
| 512x512x512 | 9.81 | 0.03 | 4.16 | 0.06 | 7.80 | 0.03 | 79.5% | 187.3% |
| 1024x1024x1024 | 11.98 | 0.18 | 6.88 | 0.31 | 10.36 | 0.21 | 86.5% | 150.7% |

#### Precision: ieee (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 2.03 | 0.02 | 2.15 | 0.02 | 40.7% | 106.0% |
| 512x512x512 | 9.81 | 0.03 | 4.20 | 0.06 | 7.82 | 0.03 | 79.7% | 186.1% |
| 1024x1024x1024 | 11.98 | 0.18 | 6.86 | 0.31 | 10.35 | 0.21 | 86.3% | 150.9% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.20 | 0.01 | 2.00 | 0.02 | 2.15 | 0.02 | 41.3% | 107.3% |
| 512x512x512 | 9.78 | 0.03 | 4.18 | 0.06 | 7.82 | 0.03 | 80.0% | 187.3% |
| 1024x1024x1024 | 11.97 | 0.18 | 6.88 | 0.31 | 10.49 | 0.20 | 87.6% | 152.5% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### Compile Times (avg across precision)

| Chapter | Competitor | Avg Compile (ms) | × vs Crisp |
|---|---|---:|---:|
| chap0_sync | Crisp | 810 | 1.0× (baseline) |
| chap0_sync | OneMKL_Optimal | 6455 | 8.0× slower |
| chap0_sync | SYCL_Apples | 4201 | 5.2× slower |
| chap1_async_linear | Crisp | 653 | 1.0× (baseline) |
| chap1_async_linear | SYCL_Apples | 3932 | 6.0× slower |
| intel_prefetch | Crisp | 1454 | 1.0× (baseline) |
| intel_prefetch | SYCL_Apples | 3947 | 2.7× slower |

> Crisp compiles a kernel to SPIR-V; the native competitors invoke `icpx` (SYCL / oneMKL). Lower is better; `× vs Crisp` is how much longer than Crisp that toolchain takes.

## Hardware: NVIDIA H100 PCIe

### Summary — Crisp vs. cuBLAS ceiling (fast / tf32)

| Chapter | Technique | Size | Crisp (TFLOPS) | cuBLAS (TFLOPS) | Crisp % of cuBLAS |
|---|---|---:|---:|---:|---:|
| chap0_sync | Synchronous tiling (fp32, no tensor cores) | 2048 | 2.6 | 200.1 | 1.3% |
| chap1_async_linear | Async linear pipelining (fp32) | 2048 | 4.0 | 200.1 | 2.0% |
| chap1.5_async_block | Block TMA load + tf32 MMA | 2048 | 36.1 | 200.1 | 18.0% |
| chap2_pipelined_block | Pipelined block + tf32 MMA | 2048 | 39.5 | 200.1 | 19.8% |
| chap3_wgmma | Hopper warpgroup MMA (wgmma, tf32) | 2048 | 127.2 | 200.1 | 63.6% |

> Largest measured size per chapter, `fast` precision (Crisp and cuBLAS both tf32). The ladder runs low-to-high on the optimization axis for this hardware.

### chap0_sync — Synchronous tiling (fp32, no tensor cores)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.32 | 0.01 | 2.07 | 0.02 | 0.09 | 0.38 | 1.7% | 4.3% |
| 512x512x512 | 30.12 | 0.01 | 3.49 | 0.08 | 0.34 | 0.79 | 1.1% | 9.7% |
| 1024x1024x1024 | 108.69 | 0.02 | 4.27 | 0.50 | 1.32 | 1.62 | 1.2% | 30.9% |
| 2048x2048x2048 | 200.07 | 0.09 | 4.40 | 3.91 | 2.61 | 6.59 | 1.3% | 59.3% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.57 | 0.01 | 2.10 | 0.02 | 0.09 | 0.38 | 2.5% | 4.2% |
| 512x512x512 | 13.96 | 0.02 | 3.50 | 0.08 | 0.34 | 0.79 | 2.4% | 9.7% |
| 1024x1024x1024 | 27.33 | 0.08 | 4.29 | 0.50 | 1.32 | 1.62 | 4.8% | 30.8% |
| 2048x2048x2048 | 34.08 | 0.50 | 4.40 | 3.91 | 2.63 | 6.53 | 7.7% | 59.9% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.60 | 0.01 | 2.08 | 0.02 | 0.09 | 0.38 | 2.5% | 4.3% |
| 512x512x512 | 13.99 | 0.02 | 3.50 | 0.08 | 0.34 | 0.79 | 2.4% | 9.7% |
| 1024x1024x1024 | 27.47 | 0.08 | 4.29 | 0.50 | 1.31 | 1.63 | 4.8% | 30.6% |
| 2048x2048x2048 | 34.03 | 0.50 | 4.39 | 3.91 | 2.61 | 6.57 | 7.7% | 59.5% |

### chap1_async_linear — Async linear pipelining (fp32)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.32 | 0.01 | 1.82 | 0.02 | 0.14 | 0.25 | 2.5% | 7.4% |
| 512x512x512 | 30.12 | 0.01 | 3.23 | 0.08 | 0.54 | 0.49 | 1.8% | 16.9% |
| 1024x1024x1024 | 108.69 | 0.02 | 3.56 | 0.60 | 2.12 | 1.01 | 2.0% | 59.5% |
| 2048x2048x2048 | 200.07 | 0.09 | 3.65 | 4.71 | 3.97 | 4.33 | 2.0% | 108.8% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.57 | 0.01 | 1.80 | 0.02 | 0.14 | 0.25 | 3.8% | 7.5% |
| 512x512x512 | 13.96 | 0.02 | 3.24 | 0.08 | 0.54 | 0.49 | 3.9% | 16.8% |
| 1024x1024x1024 | 27.33 | 0.08 | 3.56 | 0.60 | 2.11 | 1.02 | 7.7% | 59.3% |
| 2048x2048x2048 | 34.08 | 0.50 | 3.65 | 4.71 | 3.84 | 4.47 | 11.3% | 105.3% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.60 | 0.01 | 1.80 | 0.02 | 0.13 | 0.25 | 3.7% | 7.4% |
| 512x512x512 | 13.99 | 0.02 | 3.22 | 0.08 | 0.55 | 0.49 | 3.9% | 17.0% |
| 1024x1024x1024 | 27.47 | 0.08 | 3.58 | 0.60 | 2.11 | 1.02 | 7.7% | 59.0% |
| 2048x2048x2048 | 34.03 | 0.50 | 3.65 | 4.71 | 3.85 | 4.46 | 11.3% | 105.7% |

### chap1.5_async_block — Block TMA load + tf32 MMA

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.32 | 0.01 | 1.80 | 0.02 | 1.44 | 0.02 | 27.1% | 79.9% |
| 512x512x512 | 30.12 | 0.01 | 3.24 | 0.08 | 6.30 | 0.04 | 20.9% | 194.7% |
| 1024x1024x1024 | 108.69 | 0.02 | 3.56 | 0.60 | 24.21 | 0.09 | 22.3% | 679.9% |
| 2048x2048x2048 | 200.07 | 0.09 | 3.65 | 4.71 | 36.10 | 0.48 | 18.0% | 989.2% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.57 | 0.01 | 1.81 | 0.02 | 1.43 | 0.02 | 40.0% | 79.0% |
| 512x512x512 | 13.96 | 0.02 | 3.22 | 0.08 | 6.33 | 0.04 | 45.3% | 196.4% |
| 1024x1024x1024 | 27.33 | 0.08 | 3.56 | 0.60 | 24.21 | 0.09 | 88.6% | 679.9% |
| 2048x2048x2048 | 34.08 | 0.50 | 3.65 | 4.71 | 35.91 | 0.48 | 105.4% | 984.3% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.60 | 0.01 | 1.80 | 0.02 | 1.43 | 0.02 | 39.6% | 79.5% |
| 512x512x512 | 13.99 | 0.02 | 3.21 | 0.08 | 6.34 | 0.04 | 45.3% | 197.4% |
| 1024x1024x1024 | 27.47 | 0.08 | 3.57 | 0.60 | 24.20 | 0.09 | 88.1% | 678.2% |
| 2048x2048x2048 | 34.03 | 0.50 | 3.64 | 4.71 | 35.81 | 0.48 | 105.2% | 982.6% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap2_pipelined_block — Pipelined block + tf32 MMA

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.32 | 0.01 | 1.58 | 0.02 | 1.56 | 0.02 | 29.4% | 99.0% |
| 512x512x512 | 30.12 | 0.01 | 2.85 | 0.09 | 7.00 | 0.04 | 23.2% | 245.6% |
| 1024x1024x1024 | 108.69 | 0.02 | 3.11 | 0.69 | 25.84 | 0.08 | 23.8% | 831.3% |
| 2048x2048x2048 | 200.07 | 0.09 | 3.16 | 5.43 | 39.53 | 0.43 | 19.8% | 1249.7% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.57 | 0.01 | 1.58 | 0.02 | 1.58 | 0.02 | 44.2% | 100.0% |
| 512x512x512 | 13.96 | 0.02 | 2.86 | 0.09 | 7.02 | 0.04 | 50.3% | 245.7% |
| 1024x1024x1024 | 27.33 | 0.08 | 3.10 | 0.69 | 25.77 | 0.08 | 94.3% | 832.2% |
| 2048x2048x2048 | 34.08 | 0.50 | 3.16 | 5.43 | 38.85 | 0.44 | 114.0% | 1228.6% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.60 | 0.01 | 1.58 | 0.02 | 1.57 | 0.02 | 43.4% | 98.8% |
| 512x512x512 | 13.99 | 0.02 | 2.85 | 0.09 | 6.96 | 0.04 | 49.8% | 244.6% |
| 1024x1024x1024 | 27.47 | 0.08 | 3.11 | 0.69 | 25.72 | 0.08 | 93.6% | 827.2% |
| 2048x2048x2048 | 34.03 | 0.50 | 3.16 | 5.43 | 38.76 | 0.44 | 113.9% | 1225.0% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap3_wgmma — Hopper warpgroup MMA (wgmma, tf32)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 5.32 | 0.01 | 2.47 | 0.01 | 46.4% |
| 512x512x512 | 30.12 | 0.01 | 14.65 | 0.02 | 48.6% |
| 1024x1024x1024 | 108.69 | 0.02 | 78.29 | 0.03 | 72.0% |
| 2048x2048x2048 | 200.07 | 0.09 | 127.17 | 0.14 | 63.6% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 3.57 | 0.01 | 2.46 | 0.01 | 68.8% |
| 512x512x512 | 13.96 | 0.02 | 14.62 | 0.02 | 104.7% |
| 1024x1024x1024 | 27.33 | 0.08 | 79.10 | 0.03 | 289.4% |
| 2048x2048x2048 | 34.08 | 0.50 | 127.45 | 0.13 | 373.9% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 3.60 | 0.01 | 2.47 | 0.01 | 68.5% |
| 512x512x512 | 13.99 | 0.02 | 14.61 | 0.02 | 104.5% |
| 1024x1024x1024 | 27.47 | 0.08 | 78.37 | 0.03 | 285.3% |
| 2048x2048x2048 | 34.03 | 0.50 | 127.27 | 0.13 | 374.0% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### Compile Times (avg across precision)

| Chapter | Competitor | Avg Compile (ms) | × vs Crisp |
|---|---|---:|---:|
| chap0_sync | Crisp | 321 | 1.0× (baseline) |
| chap0_sync | CUBLAS_Optimal | 1272 | 4.0× slower |
| chap0_sync | CUDA_Apples | 1513 | 4.7× slower |
| chap1_async_linear | Crisp | 321 | 1.0× (baseline) |
| chap1_async_linear | CUDA_Apples | 2525 | 7.9× slower |
| chap1.5_async_block | Crisp | 300 | 1.0× (baseline) |
| chap1.5_async_block | CUDA_Apples | 2516 | 8.4× slower |
| chap2_pipelined_block | Crisp | 378 | 1.0× (baseline) |
| chap2_pipelined_block | CUDA_Apples | 2550 | 6.8× slower |
| chap3_wgmma | Crisp | 387 | 1.0× (baseline) |
| chap3_wgmma | CUBLAS_Optimal | 1257 | 3.2× slower |

> Crisp compiles a kernel to PTX; the native competitors invoke `nvcc`. Lower is better; `× vs Crisp` is how much longer than Crisp that toolchain takes.
