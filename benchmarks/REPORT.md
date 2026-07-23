# Crisp Benchmark Report

## Hardware: NVIDIA H100

### Summary — Crisp vs. cuBLAS ceiling (fast / tf32)

| Chapter | Technique | Size | Crisp (TFLOPS) | cuBLAS (TFLOPS) | Crisp % of cuBLAS |
|---|---|---:|---:|---:|---:|
| chap0_sync | Synchronous tiling (fp32, no tensor cores) | 1024 | 1.5 | 142.3 | 1.1% |
| chap1_async_linear | Async linear pipelining (fp32) | 1024 | 2.5 | 142.3 | 1.8% |
| chap1.5_async_block | Block TMA load + tf32 MMA | 1024 | 28.1 | 142.3 | 19.8% |
| chap2_pipelined_block | Pipelined block + tf32 MMA | 1024 | 31.1 | 142.3 | 21.9% |
| chap3_wgmma | Hopper warpgroup MMA (wgmma, tf32) | 1024 | 87.4 | 142.3 | 61.4% |

> Largest measured size per chapter, `fast` precision (Crisp and cuBLAS both tf32). The ladder runs from naive fp32 tiling to Hopper wgmma.

### chap0_sync — Synchronous tiling (fp32, no tensor cores)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.04 | 0.01 | 2.51 | 0.01 | 0.10 | 0.33 | 1.7% | 4.0% |
| 512x512x512 | 34.30 | 0.01 | 4.72 | 0.06 | 0.38 | 0.70 | 1.1% | 8.2% |
| 1024x1024x1024 | 142.30 | 0.02 | 5.45 | 0.39 | 1.53 | 1.41 | 1.1% | 28.0% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.70 | 0.01 | 2.53 | 0.01 | 0.10 | 0.34 | 2.7% | 3.9% |
| 512x512x512 | 18.10 | 0.01 | 4.72 | 0.06 | 0.39 | 0.70 | 2.1% | 8.2% |
| 1024x1024x1024 | 38.53 | 0.06 | 5.46 | 0.39 | 1.54 | 1.40 | 4.0% | 28.2% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.68 | 0.01 | 2.51 | 0.01 | 0.10 | 0.33 | 2.7% | 4.0% |
| 512x512x512 | 18.13 | 0.01 | 4.71 | 0.06 | 0.39 | 0.69 | 2.2% | 8.3% |
| 1024x1024x1024 | 38.54 | 0.06 | 5.45 | 0.39 | 1.54 | 1.40 | 4.0% | 28.2% |

### chap1_async_linear — Async linear pipelining (fp32)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.04 | 0.01 | 2.37 | 0.01 | 0.15 | 0.22 | 2.5% | 6.4% |
| 512x512x512 | 34.30 | 0.01 | 4.02 | 0.07 | 0.62 | 0.43 | 1.8% | 15.5% |
| 1024x1024x1024 | 142.30 | 0.02 | 4.55 | 0.47 | 2.51 | 0.85 | 1.8% | 55.3% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.70 | 0.01 | 2.38 | 0.01 | 0.15 | 0.22 | 4.1% | 6.4% |
| 512x512x512 | 18.10 | 0.01 | 4.02 | 0.07 | 0.62 | 0.43 | 3.4% | 15.5% |
| 1024x1024x1024 | 38.53 | 0.06 | 4.55 | 0.47 | 2.50 | 0.86 | 6.5% | 54.8% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.68 | 0.01 | 2.37 | 0.01 | 0.15 | 0.22 | 4.2% | 6.4% |
| 512x512x512 | 18.13 | 0.01 | 4.02 | 0.07 | 0.62 | 0.43 | 3.4% | 15.5% |
| 1024x1024x1024 | 38.54 | 0.06 | 4.55 | 0.47 | 2.52 | 0.85 | 6.5% | 55.3% |

### chap1.5_async_block — Block TMA load + tf32 MMA

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.04 | 0.01 | 2.37 | 0.01 | 1.64 | 0.02 | 27.1% | 69.1% |
| 512x512x512 | 34.30 | 0.01 | 4.03 | 0.07 | 7.11 | 0.04 | 20.7% | 176.4% |
| 1024x1024x1024 | 142.30 | 0.02 | 4.55 | 0.47 | 28.12 | 0.08 | 19.8% | 618.1% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.70 | 0.01 | 2.37 | 0.01 | 1.63 | 0.02 | 44.0% | 68.6% |
| 512x512x512 | 18.10 | 0.01 | 4.03 | 0.07 | 7.10 | 0.04 | 39.2% | 176.4% |
| 1024x1024x1024 | 38.53 | 0.06 | 4.55 | 0.47 | 28.11 | 0.08 | 73.0% | 617.9% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.68 | 0.01 | 2.37 | 0.01 | 1.63 | 0.02 | 44.3% | 68.7% |
| 512x512x512 | 18.13 | 0.01 | 4.02 | 0.07 | 7.10 | 0.04 | 39.1% | 176.5% |
| 1024x1024x1024 | 38.54 | 0.06 | 4.55 | 0.47 | 28.09 | 0.08 | 72.9% | 617.6% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap2_pipelined_block — Pipelined block + tf32 MMA

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.04 | 0.01 | 2.20 | 0.02 | 1.78 | 0.02 | 29.6% | 81.2% |
| 512x512x512 | 34.30 | 0.01 | 3.57 | 0.08 | 8.00 | 0.03 | 23.3% | 224.3% |
| 1024x1024x1024 | 142.30 | 0.02 | 3.96 | 0.54 | 31.13 | 0.07 | 21.9% | 786.8% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.70 | 0.01 | 2.20 | 0.02 | 1.78 | 0.02 | 48.1% | 80.9% |
| 512x512x512 | 18.10 | 0.01 | 3.56 | 0.08 | 8.00 | 0.03 | 44.2% | 224.7% |
| 1024x1024x1024 | 38.53 | 0.06 | 3.95 | 0.54 | 31.10 | 0.07 | 80.7% | 786.4% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.68 | 0.01 | 2.20 | 0.02 | 1.78 | 0.02 | 48.5% | 81.1% |
| 512x512x512 | 18.13 | 0.01 | 3.57 | 0.08 | 8.01 | 0.03 | 44.1% | 224.5% |
| 1024x1024x1024 | 38.54 | 0.06 | 3.96 | 0.54 | 31.12 | 0.07 | 80.8% | 786.7% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap3_wgmma — Hopper warpgroup MMA (wgmma, tf32)

#### Precision: fast (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 6.04 | 0.01 | 2.76 | 0.01 | 45.8% |
| 512x512x512 | 34.30 | 0.01 | 16.63 | 0.02 | 48.5% |
| 1024x1024x1024 | 142.30 | 0.02 | 87.41 | 0.02 | 61.4% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 3.70 | 0.01 | 2.75 | 0.01 | 74.4% |
| 512x512x512 | 18.10 | 0.01 | 16.73 | 0.02 | 92.4% |
| 1024x1024x1024 | 38.53 | 0.06 | 87.85 | 0.02 | 228.0% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 3.68 | 0.01 | 2.76 | 0.01 | 75.0% |
| 512x512x512 | 18.13 | 0.01 | 16.72 | 0.02 | 92.2% |
| 1024x1024x1024 | 38.54 | 0.06 | 88.02 | 0.02 | 228.4% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### Compile Times (avg across precision)

| Chapter | Competitor | Avg Compile (ms) | × vs Crisp |
|---|---|---:|---:|
| chap0_sync | Crisp | 277 | 1.0× (baseline) |
| chap0_sync | CUBLAS_Optimal | 1096 | 4.0× slower |
| chap0_sync | CUDA_Apples | 1252 | 4.5× slower |
| chap1_async_linear | Crisp | 278 | 1.0× (baseline) |
| chap1_async_linear | CUDA_Apples | 2020 | 7.3× slower |
| chap1.5_async_block | Crisp | 259 | 1.0× (baseline) |
| chap1.5_async_block | CUDA_Apples | 2050 | 7.9× slower |
| chap2_pipelined_block | Crisp | 331 | 1.0× (baseline) |
| chap2_pipelined_block | CUDA_Apples | 2045 | 6.2× slower |
| chap3_wgmma | Crisp | 349 | 1.0× (baseline) |
| chap3_wgmma | CUBLAS_Optimal | 1096 | 3.1× slower |

> Crisp compiles a kernel to PTX; the native competitors invoke `nvcc`. Lower is better; `× vs Crisp` is how much longer than Crisp that toolchain takes.
