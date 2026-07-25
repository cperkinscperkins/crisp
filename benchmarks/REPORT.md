# Crisp Benchmark Report

## Hardware: Intel BMG

### Summary — Crisp vs. oneMKL ceiling (fast / tf32)

| Chapter | Technique | Size | Crisp (TFLOPS) | oneMKL (TFLOPS) | Crisp % of oneMKL |
|---|---|---:|---:|---:|---:|
| chap0_sync | Synchronous coop-matrix tiling (XMX tf32) | 1024 | 1.5 | 12.0 | 12.5% |
| chap1_async_linear | OpGroupAsyncCopy staging (XMX tf32) | 1024 | 0.8 | 12.0 | 6.6% |

> Largest measured size per chapter, `fast` precision (Crisp and oneMKL both tf32). The ladder runs low-to-high on the optimization axis for this hardware.

### chap0_sync — Synchronous coop-matrix tiling (XMX tf32)

#### Precision: fast (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.20 | 0.01 | 1.32 | 0.03 | 0.11 | 0.29 | 2.2% | 8.6% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.42 | 0.65 | 4.2% | 28.3% |
| 1024x1024x1024 | 11.96 | 0.18 | 1.53 | 1.40 | 1.50 | 1.43 | 12.5% | 97.8% |

#### Precision: ieee (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.32 | 0.03 | 0.11 | 0.29 | 2.2% | 8.6% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.42 | 0.65 | 4.2% | 28.3% |
| 1024x1024x1024 | 11.87 | 0.18 | 1.53 | 1.41 | 1.49 | 1.44 | 12.5% | 97.4% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 1.31 | 0.03 | 0.11 | 0.29 | 2.2% | 8.7% |
| 512x512x512 | 9.81 | 0.03 | 1.47 | 0.18 | 0.42 | 0.65 | 4.2% | 28.4% |
| 1024x1024x1024 | 11.96 | 0.18 | 1.53 | 1.40 | 1.49 | 1.44 | 12.5% | 97.4% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### chap1_async_linear — OpGroupAsyncCopy staging (XMX tf32)

#### Precision: fast (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.20 | 0.01 | 0.01 | 3.55 | 0.08 | 0.41 | 1.6% | 866.5% |
| 512x512x512 | 9.81 | 0.03 | 0.01 | 24.17 | 0.26 | 1.05 | 2.6% | 2308.3% |
| 1024x1024x1024 | 11.96 | 0.18 | 0.01 | 188.65 | 0.78 | 2.74 | 6.6% | 6896.3% |

#### Precision: ieee (ftz=ftz)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 0.01 | 3.55 | 0.08 | 0.41 | 1.6% | 867.6% |
| 512x512x512 | 9.81 | 0.03 | 0.01 | 24.20 | 0.26 | 1.04 | 2.6% | 2321.6% |
| 1024x1024x1024 | 11.87 | 0.18 | 0.01 | 188.58 | 0.78 | 2.74 | 6.6% | 6890.5% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | OneMKL_Optimal (TFLOPS) | OneMKL_Optimal (Kernel ms) | SYCL_Apples (TFLOPS) | SYCL_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.29 | 0.01 | 0.01 | 3.54 | 0.08 | 0.41 | 1.6% | 866.4% |
| 512x512x512 | 9.81 | 0.03 | 0.01 | 24.20 | 0.26 | 1.04 | 2.6% | 2320.5% |
| 1024x1024x1024 | 11.96 | 0.18 | 0.01 | 188.61 | 0.78 | 2.74 | 6.6% | 6883.5% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE oneMKL drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### Compile Times (avg across precision)

| Chapter | Competitor | Avg Compile (ms) | × vs Crisp |
|---|---|---:|---:|
| chap0_sync | Crisp | 834 | 1.0× (baseline) |
| chap0_sync | OneMKL_Optimal | 6357 | 7.6× slower |
| chap0_sync | SYCL_Apples | 4168 | 5.0× slower |
| chap1_async_linear | Crisp | 687 | 1.0× (baseline) |
| chap1_async_linear | SYCL_Apples | 4339 | 6.3× slower |

> Crisp compiles a kernel to SPIR-V; the native competitors invoke `icpx` (SYCL / oneMKL). Lower is better; `× vs Crisp` is how much longer than Crisp that toolchain takes.

## Hardware: NVIDIA H100

### Summary — Crisp vs. cuBLAS ceiling (fast / tf32)

| Chapter | Technique | Size | Crisp (TFLOPS) | cuBLAS (TFLOPS) | Crisp % of cuBLAS |
|---|---|---:|---:|---:|---:|
| chap0_sync | Synchronous tiling (fp32, no tensor cores) | 2048 | 5.6 | 363.6 | 1.5% |
| chap1_async_linear | Async linear pipelining (fp32) | 2048 | 8.9 | 363.6 | 2.4% |
| chap1.5_async_block | Block TMA load + tf32 MMA | 2048 | 75.2 | 363.6 | 20.7% |
| chap2_pipelined_block | Pipelined block + tf32 MMA | 2048 | 72.6 | 363.6 | 20.0% |
| chap3_wgmma | Hopper warpgroup MMA (wgmma, tf32) | 2048 | 241.7 | 363.6 | 66.5% |

> Largest measured size per chapter, `fast` precision (Crisp and cuBLAS both tf32). The ladder runs low-to-high on the optimization axis for this hardware.

### chap0_sync — Synchronous tiling (fp32, no tensor cores)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.10 | 0.01 | 2.50 | 0.01 | 0.10 | 0.34 | 1.6% | 3.9% |
| 512x512x512 | 34.31 | 0.01 | 4.71 | 0.06 | 0.39 | 0.69 | 1.1% | 8.2% |
| 1024x1024x1024 | 143.73 | 0.01 | 5.45 | 0.39 | 1.55 | 1.39 | 1.1% | 28.4% |
| 2048x2048x2048 | 363.64 | 0.05 | 5.72 | 3.00 | 5.62 | 3.06 | 1.5% | 98.2% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.02 | 0.01 | 2.51 | 0.01 | 0.10 | 0.34 | 3.3% | 4.0% |
| 512x512x512 | 17.99 | 0.01 | 4.73 | 0.06 | 0.39 | 0.70 | 2.1% | 8.2% |
| 1024x1024x1024 | 38.61 | 0.06 | 5.46 | 0.39 | 1.54 | 1.40 | 4.0% | 28.2% |
| 2048x2048x2048 | 50.81 | 0.34 | 5.72 | 3.00 | 5.63 | 3.05 | 11.1% | 98.4% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.04 | 0.01 | 2.51 | 0.01 | 0.10 | 0.34 | 3.3% | 4.0% |
| 512x512x512 | 18.35 | 0.01 | 4.73 | 0.06 | 0.38 | 0.70 | 2.1% | 8.1% |
| 1024x1024x1024 | 38.34 | 0.06 | 5.46 | 0.39 | 1.53 | 1.40 | 4.0% | 28.1% |
| 2048x2048x2048 | 50.44 | 0.34 | 5.72 | 3.00 | 5.63 | 3.05 | 11.2% | 98.5% |

### chap1_async_linear — Async linear pipelining (fp32)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.10 | 0.01 | 2.40 | 0.01 | 0.15 | 0.22 | 2.5% | 6.3% |
| 512x512x512 | 34.31 | 0.01 | 4.04 | 0.07 | 0.62 | 0.43 | 1.8% | 15.4% |
| 1024x1024x1024 | 143.73 | 0.01 | 4.58 | 0.47 | 2.51 | 0.86 | 1.7% | 54.7% |
| 2048x2048x2048 | 363.64 | 0.05 | 4.78 | 3.59 | 8.91 | 1.93 | 2.4% | 186.4% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.02 | 0.01 | 2.39 | 0.01 | 0.15 | 0.22 | 5.0% | 6.4% |
| 512x512x512 | 17.99 | 0.01 | 4.04 | 0.07 | 0.62 | 0.43 | 3.5% | 15.4% |
| 1024x1024x1024 | 38.61 | 0.06 | 4.58 | 0.47 | 2.50 | 0.86 | 6.5% | 54.6% |
| 2048x2048x2048 | 50.81 | 0.34 | 4.78 | 3.59 | 9.04 | 1.90 | 17.8% | 189.2% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.04 | 0.01 | 2.39 | 0.01 | 0.15 | 0.22 | 5.0% | 6.4% |
| 512x512x512 | 18.35 | 0.01 | 4.02 | 0.07 | 0.62 | 0.43 | 3.4% | 15.5% |
| 1024x1024x1024 | 38.34 | 0.06 | 4.55 | 0.47 | 2.51 | 0.86 | 6.5% | 55.1% |
| 2048x2048x2048 | 50.44 | 0.34 | 4.74 | 3.62 | 9.08 | 1.89 | 18.0% | 191.4% |

### chap1.5_async_block — Block TMA load + tf32 MMA

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.10 | 0.01 | 2.37 | 0.01 | 1.63 | 0.02 | 26.7% | 68.8% |
| 512x512x512 | 34.31 | 0.01 | 4.03 | 0.07 | 7.14 | 0.04 | 20.8% | 176.9% |
| 1024x1024x1024 | 143.73 | 0.01 | 4.58 | 0.47 | 28.17 | 0.08 | 19.6% | 615.0% |
| 2048x2048x2048 | 363.64 | 0.05 | 4.78 | 3.59 | 75.19 | 0.23 | 20.7% | 1573.2% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.02 | 0.01 | 2.39 | 0.01 | 1.61 | 0.02 | 53.3% | 67.5% |
| 512x512x512 | 17.99 | 0.01 | 4.03 | 0.07 | 7.17 | 0.04 | 39.8% | 177.9% |
| 1024x1024x1024 | 38.61 | 0.06 | 4.58 | 0.47 | 28.41 | 0.08 | 73.6% | 620.6% |
| 2048x2048x2048 | 50.81 | 0.34 | 4.78 | 3.59 | 75.17 | 0.23 | 148.0% | 1572.7% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.04 | 0.01 | 2.38 | 0.01 | 1.60 | 0.02 | 52.7% | 67.2% |
| 512x512x512 | 18.35 | 0.01 | 4.03 | 0.07 | 7.04 | 0.04 | 38.4% | 174.5% |
| 1024x1024x1024 | 38.34 | 0.06 | 4.58 | 0.47 | 27.96 | 0.08 | 72.9% | 610.9% |
| 2048x2048x2048 | 50.44 | 0.34 | 4.78 | 3.59 | 75.18 | 0.23 | 149.1% | 1573.1% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap2_pipelined_block — Pipelined block + tf32 MMA

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.10 | 0.01 | 2.19 | 0.02 | 1.79 | 0.02 | 29.4% | 81.8% |
| 512x512x512 | 34.31 | 0.01 | 3.50 | 0.08 | 7.94 | 0.03 | 23.1% | 226.9% |
| 1024x1024x1024 | 143.73 | 0.01 | 3.95 | 0.54 | 31.07 | 0.07 | 21.6% | 786.1% |
| 2048x2048x2048 | 363.64 | 0.05 | 4.12 | 4.17 | 72.59 | 0.24 | 20.0% | 1762.6% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.02 | 0.01 | 2.21 | 0.02 | 1.78 | 0.02 | 58.9% | 80.5% |
| 512x512x512 | 17.99 | 0.01 | 3.59 | 0.07 | 7.96 | 0.03 | 44.3% | 221.6% |
| 1024x1024x1024 | 38.61 | 0.06 | 3.98 | 0.54 | 31.05 | 0.07 | 80.4% | 779.1% |
| 2048x2048x2048 | 50.81 | 0.34 | 4.15 | 4.14 | 72.68 | 0.24 | 143.1% | 1751.6% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.04 | 0.01 | 2.19 | 0.02 | 1.78 | 0.02 | 58.6% | 81.2% |
| 512x512x512 | 18.35 | 0.01 | 3.59 | 0.07 | 7.94 | 0.03 | 43.3% | 221.2% |
| 1024x1024x1024 | 38.34 | 0.06 | 3.98 | 0.54 | 31.16 | 0.07 | 81.3% | 782.3% |
| 2048x2048x2048 | 50.44 | 0.34 | 4.15 | 4.14 | 72.03 | 0.24 | 142.8% | 1736.1% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap3_wgmma — Hopper warpgroup MMA (wgmma, tf32)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 6.10 | 0.01 | 2.75 | 0.01 | 45.1% |
| 512x512x512 | 34.31 | 0.01 | 16.68 | 0.02 | 48.6% |
| 1024x1024x1024 | 143.73 | 0.01 | 88.38 | 0.02 | 61.5% |
| 2048x2048x2048 | 363.64 | 0.05 | 241.73 | 0.07 | 66.5% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 3.02 | 0.01 | 2.74 | 0.01 | 90.8% |
| 512x512x512 | 17.99 | 0.01 | 16.61 | 0.02 | 92.3% |
| 1024x1024x1024 | 38.61 | 0.06 | 89.11 | 0.02 | 230.8% |
| 2048x2048x2048 | 50.81 | 0.34 | 242.28 | 0.07 | 476.9% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 3.04 | 0.01 | 2.78 | 0.01 | 91.6% |
| 512x512x512 | 18.35 | 0.01 | 16.62 | 0.02 | 90.6% |
| 1024x1024x1024 | 38.34 | 0.06 | 88.38 | 0.02 | 230.5% |
| 2048x2048x2048 | 50.44 | 0.34 | 242.77 | 0.07 | 481.3% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### Compile Times (avg across precision)

| Chapter | Competitor | Avg Compile (ms) | × vs Crisp |
|---|---|---:|---:|
| chap0_sync | Crisp | 354 | 1.0× (baseline) |
| chap0_sync | CUBLAS_Optimal | 1435 | 4.1× slower |
| chap0_sync | CUDA_Apples | 1625 | 4.6× slower |
| chap1_async_linear | Crisp | 354 | 1.0× (baseline) |
| chap1_async_linear | CUDA_Apples | 2581 | 7.3× slower |
| chap1.5_async_block | Crisp | 333 | 1.0× (baseline) |
| chap1.5_async_block | CUDA_Apples | 2595 | 7.8× slower |
| chap2_pipelined_block | Crisp | 403 | 1.0× (baseline) |
| chap2_pipelined_block | CUDA_Apples | 2607 | 6.5× slower |
| chap3_wgmma | Crisp | 442 | 1.0× (baseline) |
| chap3_wgmma | CUBLAS_Optimal | 1418 | 3.2× slower |

> Crisp compiles a kernel to PTX; the native competitors invoke `nvcc`. Lower is better; `× vs Crisp` is how much longer than Crisp that toolchain takes.
