# Crisp Benchmark Report

## Hardware: NVIDIA H100

### Summary — Crisp vs. cuBLAS ceiling (fast / tf32)

| Chapter | Technique | Size | Crisp (TFLOPS) | cuBLAS (TFLOPS) | Crisp % of cuBLAS |
|---|---|---:|---:|---:|---:|
| chap0_sync | Synchronous tiling (fp32, no tensor cores) | 1024 | 1.5 | 135.4 | 1.1% |
| chap1_async_linear | Async linear pipelining (fp32) | 1024 | 2.5 | 135.4 | 1.9% |
| chap1.5_async_block | Block TMA load + tf32 MMA | 1024 | 27.8 | 135.4 | 20.5% |
| chap2_pipelined_block | Pipelined block + tf32 MMA | 1024 | 31.1 | 135.4 | 23.0% |
| chap3_wgmma | Hopper warpgroup MMA (wgmma, tf32) | 1024 | 90.0 | 135.4 | 66.5% |

> Largest measured size per chapter, `fast` precision (Crisp and cuBLAS both tf32). The ladder runs from naive fp32 tiling to Hopper wgmma.

### chap0_sync — Synchronous tiling (fp32, no tensor cores)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.96 | 0.01 | 2.50 | 0.01 | 0.10 | 0.34 | 1.7% | 4.0% |
| 512x512x512 | 34.44 | 0.01 | 4.72 | 0.06 | 0.38 | 0.71 | 1.1% | 8.1% |
| 1024x1024x1024 | 135.41 | 0.02 | 5.45 | 0.39 | 1.55 | 1.39 | 1.1% | 28.4% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.01 | 0.01 | 2.50 | 0.01 | 0.10 | 0.33 | 3.3% | 4.0% |
| 512x512x512 | 17.87 | 0.02 | 4.71 | 0.06 | 0.38 | 0.70 | 2.1% | 8.1% |
| 1024x1024x1024 | 38.43 | 0.06 | 5.45 | 0.39 | 1.55 | 1.38 | 4.0% | 28.5% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.02 | 0.01 | 2.50 | 0.01 | 0.10 | 0.33 | 3.3% | 4.0% |
| 512x512x512 | 18.16 | 0.01 | 4.72 | 0.06 | 0.38 | 0.71 | 2.1% | 8.0% |
| 1024x1024x1024 | 38.46 | 0.06 | 5.45 | 0.39 | 1.55 | 1.38 | 4.0% | 28.5% |

### chap1_async_linear — Async linear pipelining (fp32)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.96 | 0.01 | 2.35 | 0.01 | 0.15 | 0.22 | 2.5% | 6.5% |
| 512x512x512 | 34.44 | 0.01 | 4.00 | 0.07 | 0.62 | 0.43 | 1.8% | 15.5% |
| 1024x1024x1024 | 135.41 | 0.02 | 4.54 | 0.47 | 2.51 | 0.86 | 1.9% | 55.2% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.01 | 0.01 | 2.37 | 0.01 | 0.15 | 0.22 | 5.0% | 6.4% |
| 512x512x512 | 17.87 | 0.02 | 4.02 | 0.07 | 0.62 | 0.43 | 3.5% | 15.5% |
| 1024x1024x1024 | 38.43 | 0.06 | 4.55 | 0.47 | 2.49 | 0.86 | 6.5% | 54.7% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.02 | 0.01 | 2.36 | 0.01 | 0.15 | 0.22 | 5.0% | 6.5% |
| 512x512x512 | 18.16 | 0.01 | 4.01 | 0.07 | 0.62 | 0.43 | 3.4% | 15.5% |
| 1024x1024x1024 | 38.46 | 0.06 | 4.55 | 0.47 | 2.51 | 0.86 | 6.5% | 55.1% |

### chap1.5_async_block — Block TMA load + tf32 MMA

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.96 | 0.01 | 2.39 | 0.01 | 1.60 | 0.02 | 26.9% | 66.9% |
| 512x512x512 | 34.44 | 0.01 | 4.05 | 0.07 | 7.11 | 0.04 | 20.6% | 175.6% |
| 1024x1024x1024 | 135.41 | 0.02 | 4.58 | 0.47 | 27.80 | 0.08 | 20.5% | 607.1% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.01 | 0.01 | 2.40 | 0.01 | 1.61 | 0.02 | 53.3% | 67.0% |
| 512x512x512 | 17.87 | 0.02 | 4.05 | 0.07 | 7.07 | 0.04 | 39.6% | 174.8% |
| 1024x1024x1024 | 38.43 | 0.06 | 4.58 | 0.47 | 27.88 | 0.08 | 72.5% | 608.3% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.02 | 0.01 | 2.39 | 0.01 | 1.60 | 0.02 | 53.0% | 67.0% |
| 512x512x512 | 18.16 | 0.01 | 4.02 | 0.07 | 7.07 | 0.04 | 38.9% | 175.9% |
| 1024x1024x1024 | 38.46 | 0.06 | 4.55 | 0.47 | 27.83 | 0.08 | 72.4% | 611.8% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap2_pipelined_block — Pipelined block + tf32 MMA

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 5.96 | 0.01 | 2.19 | 0.02 | 1.79 | 0.02 | 30.1% | 81.8% |
| 512x512x512 | 34.44 | 0.01 | 3.58 | 0.07 | 8.00 | 0.03 | 23.2% | 223.3% |
| 1024x1024x1024 | 135.41 | 0.02 | 3.98 | 0.54 | 31.08 | 0.07 | 23.0% | 780.2% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.01 | 0.01 | 2.19 | 0.02 | 1.79 | 0.02 | 59.3% | 81.6% |
| 512x512x512 | 17.87 | 0.02 | 3.58 | 0.07 | 7.95 | 0.03 | 44.5% | 222.0% |
| 1024x1024x1024 | 38.43 | 0.06 | 3.98 | 0.54 | 31.18 | 0.07 | 81.1% | 782.7% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.02 | 0.01 | 2.18 | 0.02 | 1.78 | 0.02 | 59.1% | 81.6% |
| 512x512x512 | 18.16 | 0.01 | 3.57 | 0.08 | 7.94 | 0.03 | 43.7% | 222.8% |
| 1024x1024x1024 | 38.46 | 0.06 | 3.95 | 0.54 | 30.84 | 0.07 | 80.2% | 779.8% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap3_wgmma — Hopper warpgroup MMA (wgmma, tf32)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 5.96 | 0.01 | 2.77 | 0.01 | 46.5% |
| 512x512x512 | 34.44 | 0.01 | 16.56 | 0.02 | 48.1% |
| 1024x1024x1024 | 135.41 | 0.02 | 89.99 | 0.02 | 66.5% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 3.01 | 0.01 | 2.74 | 0.01 | 90.8% |
| 512x512x512 | 17.87 | 0.02 | 16.47 | 0.02 | 92.2% |
| 1024x1024x1024 | 38.43 | 0.06 | 90.05 | 0.02 | 234.3% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 3.02 | 0.01 | 2.76 | 0.01 | 91.3% |
| 512x512x512 | 18.16 | 0.01 | 16.49 | 0.02 | 90.8% |
| 1024x1024x1024 | 38.46 | 0.06 | 89.95 | 0.02 | 233.9% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### Compile Times (avg across precision)

| Chapter | Competitor | Avg Compile (ms) | × vs Crisp |
|---|---|---:|---:|
| chap0_sync | Crisp | 354 | 1.0× (baseline) |
| chap0_sync | CUBLAS_Optimal | 1445 | 4.1× slower |
| chap0_sync | CUDA_Apples | 1609 | 4.5× slower |
| chap1_async_linear | Crisp | 355 | 1.0× (baseline) |
| chap1_async_linear | CUDA_Apples | 2539 | 7.2× slower |
| chap1.5_async_block | Crisp | 330 | 1.0× (baseline) |
| chap1.5_async_block | CUDA_Apples | 2541 | 7.7× slower |
| chap2_pipelined_block | Crisp | 405 | 1.0× (baseline) |
| chap2_pipelined_block | CUDA_Apples | 2561 | 6.3× slower |
| chap3_wgmma | Crisp | 434 | 1.0× (baseline) |
| chap3_wgmma | CUBLAS_Optimal | 1407 | 3.2× slower |

> Crisp compiles a kernel to PTX; the native competitors invoke `nvcc`. Lower is better; `× vs Crisp` is how much longer than Crisp that toolchain takes.
