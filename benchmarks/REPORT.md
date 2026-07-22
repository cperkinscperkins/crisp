# Crisp Benchmark Report

## Hardware: NVIDIA H100

### Summary — Crisp vs. cuBLAS ceiling (fast / tf32)

| Chapter | Technique | Size | Crisp (TFLOPS) | cuBLAS (TFLOPS) | Crisp % of cuBLAS |
|---|---|---:|---:|---:|---:|
| chap0_sync | Synchronous tiling (fp32, no tensor cores) | 4096 | 5.7 | 433.3 | 1.3% |
| chap1_async_linear | Async linear pipelining (fp32) | 4096 | 9.2 | 433.3 | 2.1% |
| chap1.5_async_block | Block TMA load + tf32 MMA | 4096 | 80.0 | 433.3 | 18.5% |
| chap2_pipelined_block | Pipelined block + tf32 MMA | 4096 | 78.4 | 433.3 | 18.1% |
| chap3_wgmma | Hopper warpgroup MMA (wgmma, tf32) | 4096 | 289.8 | 433.3 | 66.9% |

> Largest measured size per chapter, `fast` precision (Crisp and cuBLAS both tf32). The ladder runs from naive fp32 tiling to Hopper wgmma.

### chap0_sync — Synchronous tiling (fp32, no tensor cores)

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.01 | 0.01 | 2.49 | 0.01 | 0.10 | 0.34 | 1.7% | 4.0% |
| 512x512x512 | 33.93 | 0.01 | 4.71 | 0.06 | 0.38 | 0.70 | 1.1% | 8.2% |
| 1024x1024x1024 | 141.79 | 0.02 | 5.45 | 0.39 | 1.51 | 1.42 | 1.1% | 27.7% |
| 2048x2048x2048 | 363.30 | 0.05 | 5.72 | 3.01 | 5.63 | 3.05 | 1.6% | 98.6% |
| 4096x4096x4096 | 433.31 | 0.32 | 5.74 | 23.93 | 5.69 | 24.15 | 1.3% | 99.1% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.05 | 0.01 | 2.53 | 0.01 | 0.10 | 0.34 | 3.2% | 3.9% |
| 512x512x512 | 18.38 | 0.01 | 4.72 | 0.06 | 0.39 | 0.69 | 2.1% | 8.2% |
| 1024x1024x1024 | 38.48 | 0.06 | 5.46 | 0.39 | 1.54 | 1.39 | 4.0% | 28.3% |
| 2048x2048x2048 | 50.83 | 0.34 | 5.72 | 3.00 | 5.64 | 3.05 | 11.1% | 98.6% |
| 4096x4096x4096 | 52.34 | 2.63 | 5.74 | 23.92 | 5.68 | 24.18 | 10.9% | 99.0% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.01 | 0.01 | 2.51 | 0.01 | 0.10 | 0.34 | 3.3% | 4.0% |
| 512x512x512 | 18.30 | 0.01 | 4.72 | 0.06 | 0.38 | 0.70 | 2.1% | 8.1% |
| 1024x1024x1024 | 38.50 | 0.06 | 5.46 | 0.39 | 1.50 | 1.43 | 3.9% | 27.5% |
| 2048x2048x2048 | 50.79 | 0.34 | 5.72 | 3.00 | 5.63 | 3.05 | 11.1% | 98.5% |
| 4096x4096x4096 | 52.34 | 2.63 | 5.74 | 23.92 | 5.68 | 24.18 | 10.9% | 99.0% |

### chap1_async_linear — Async linear pipelining (fp32)

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.01 | 0.01 | 2.37 | 0.01 | 0.15 | 0.22 | 2.5% | 6.4% |
| 512x512x512 | 33.93 | 0.01 | 4.02 | 0.07 | 0.62 | 0.43 | 1.8% | 15.5% |
| 1024x1024x1024 | 141.79 | 0.02 | 4.55 | 0.47 | 2.49 | 0.86 | 1.8% | 54.7% |
| 2048x2048x2048 | 363.30 | 0.05 | 4.74 | 3.62 | 8.91 | 1.93 | 2.5% | 187.7% |
| 4096x4096x4096 | 433.31 | 0.32 | 4.78 | 28.78 | 9.21 | 14.92 | 2.1% | 192.9% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.05 | 0.01 | 2.38 | 0.01 | 0.15 | 0.22 | 5.0% | 6.4% |
| 512x512x512 | 18.38 | 0.01 | 4.03 | 0.07 | 0.62 | 0.43 | 3.4% | 15.4% |
| 1024x1024x1024 | 38.48 | 0.06 | 4.55 | 0.47 | 2.51 | 0.86 | 6.5% | 55.1% |
| 2048x2048x2048 | 50.83 | 0.34 | 4.74 | 3.62 | 9.10 | 1.89 | 17.9% | 191.9% |
| 4096x4096x4096 | 52.34 | 2.63 | 4.78 | 28.78 | 9.21 | 14.92 | 17.6% | 192.9% |

#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.01 | 0.01 | 2.38 | 0.01 | 0.15 | 0.22 | 5.0% | 6.4% |
| 512x512x512 | 18.30 | 0.01 | 4.06 | 0.07 | 0.62 | 0.44 | 3.4% | 15.2% |
| 1024x1024x1024 | 38.50 | 0.06 | 4.58 | 0.47 | 2.50 | 0.86 | 6.5% | 54.7% |
| 2048x2048x2048 | 50.79 | 0.34 | 4.78 | 3.60 | 9.04 | 1.90 | 17.8% | 189.3% |
| 4096x4096x4096 | 52.34 | 2.63 | 4.81 | 28.56 | 9.21 | 14.92 | 17.6% | 191.5% |

### chap1.5_async_block — Block TMA load + tf32 MMA

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.01 | 0.01 | 2.38 | 0.01 | 1.64 | 0.02 | 27.2% | 68.7% |
| 512x512x512 | 33.93 | 0.01 | 4.03 | 0.07 | 7.11 | 0.04 | 21.0% | 176.7% |
| 1024x1024x1024 | 141.79 | 0.02 | 4.55 | 0.47 | 27.98 | 0.08 | 19.7% | 615.2% |
| 2048x2048x2048 | 363.30 | 0.05 | 4.74 | 3.62 | 75.11 | 0.23 | 20.7% | 1583.1% |
| 4096x4096x4096 | 433.31 | 0.32 | 4.78 | 28.78 | 80.02 | 1.72 | 18.5% | 1675.6% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.05 | 0.01 | 2.38 | 0.01 | 1.63 | 0.02 | 53.3% | 68.2% |
| 512x512x512 | 18.38 | 0.01 | 4.05 | 0.07 | 7.09 | 0.04 | 38.6% | 174.8% |
| 1024x1024x1024 | 38.48 | 0.06 | 4.58 | 0.47 | 27.99 | 0.08 | 72.7% | 610.6% |
| 2048x2048x2048 | 50.83 | 0.34 | 4.78 | 3.59 | 74.79 | 0.23 | 147.1% | 1564.6% |
| 4096x4096x4096 | 52.34 | 2.63 | 4.81 | 28.56 | 80.18 | 1.71 | 153.2% | 1666.3% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.01 | 0.01 | 2.25 | 0.01 | 1.62 | 0.02 | 53.9% | 72.3% |
| 512x512x512 | 18.30 | 0.01 | 4.05 | 0.07 | 7.17 | 0.04 | 39.2% | 177.0% |
| 1024x1024x1024 | 38.50 | 0.06 | 4.58 | 0.47 | 28.12 | 0.08 | 73.0% | 613.7% |
| 2048x2048x2048 | 50.79 | 0.34 | 4.78 | 3.59 | 75.47 | 0.23 | 148.6% | 1578.8% |
| 4096x4096x4096 | 52.34 | 2.63 | 4.81 | 28.56 | 80.00 | 1.72 | 152.8% | 1662.5% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap2_pipelined_block — Pipelined block + tf32 MMA

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.01 | 0.01 | 2.18 | 0.02 | 1.78 | 0.02 | 29.6% | 81.7% |
| 512x512x512 | 33.93 | 0.01 | 3.56 | 0.08 | 7.97 | 0.03 | 23.5% | 223.8% |
| 1024x1024x1024 | 141.79 | 0.02 | 3.96 | 0.54 | 31.08 | 0.07 | 21.9% | 785.8% |
| 2048x2048x2048 | 363.30 | 0.05 | 4.12 | 4.17 | 72.85 | 0.24 | 20.1% | 1768.5% |
| 4096x4096x4096 | 433.31 | 0.32 | 4.19 | 32.82 | 78.44 | 1.75 | 18.1% | 1873.2% |
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.05 | 0.01 | 2.19 | 0.02 | 1.78 | 0.02 | 58.3% | 81.1% |
| 512x512x512 | 18.38 | 0.01 | 3.56 | 0.08 | 8.07 | 0.03 | 43.9% | 226.7% |
| 1024x1024x1024 | 38.48 | 0.06 | 3.95 | 0.54 | 31.43 | 0.07 | 81.7% | 794.8% |
| 2048x2048x2048 | 50.83 | 0.34 | 4.12 | 4.17 | 72.77 | 0.24 | 143.2% | 1766.9% |
| 4096x4096x4096 | 52.34 | 2.63 | 4.19 | 32.82 | 78.33 | 1.75 | 149.7% | 1870.5% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 3.01 | 0.01 | 2.18 | 0.02 | 1.78 | 0.02 | 59.2% | 81.6% |
| 512x512x512 | 18.30 | 0.01 | 3.56 | 0.08 | 7.98 | 0.03 | 43.6% | 224.0% |
| 1024x1024x1024 | 38.50 | 0.06 | 3.95 | 0.54 | 31.07 | 0.07 | 80.7% | 785.6% |
| 2048x2048x2048 | 50.79 | 0.34 | 4.12 | 4.17 | 72.81 | 0.24 | 143.3% | 1767.6% |
| 4096x4096x4096 | 52.34 | 2.63 | 4.19 | 32.82 | 78.53 | 1.75 | 150.0% | 1875.1% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.
> ⚠️ **Apples is naive:** `CUDA_Apples` in this chapter is a naive kernel, not a tensor-core mirror of the Crisp algorithm — the "Crisp vs Apples" figures are not apples-to-apples.


### chap3_wgmma — Hopper warpgroup MMA (wgmma, tf32)

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 6.01 | 0.01 | 2.77 | 0.01 | 46.2% |
| 512x512x512 | 33.93 | 0.01 | 16.57 | 0.02 | 48.8% |
| 1024x1024x1024 | 141.79 | 0.02 | 88.70 | 0.02 | 62.6% |
| 2048x2048x2048 | 363.30 | 0.05 | 242.38 | 0.07 | 66.7% |
| 4096x4096x4096 | 433.31 | 0.32 | 289.80 | 0.47 | 66.9% |

#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 3.05 | 0.01 | 2.77 | 0.01 | 90.7% |
| 512x512x512 | 18.38 | 0.01 | 16.80 | 0.02 | 91.4% |
| 1024x1024x1024 | 38.48 | 0.06 | 88.41 | 0.02 | 229.8% |
| 2048x2048x2048 | 50.83 | 0.34 | 241.82 | 0.07 | 475.7% |
| 4096x4096x4096 | 52.34 | 2.63 | 290.11 | 0.47 | 554.3% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp vs Optimal (%) |
|---|---:|---:|---:|---:|---:|
| 256x256x256 | 3.01 | 0.01 | 2.77 | 0.01 | 92.1% |
| 512x512x512 | 18.30 | 0.01 | 16.68 | 0.02 | 91.1% |
| 1024x1024x1024 | 38.50 | 0.06 | 88.78 | 0.02 | 230.6% |
| 2048x2048x2048 | 50.79 | 0.34 | 242.19 | 0.07 | 476.8% |
| 4096x4096x4096 | 52.34 | 2.63 | 290.69 | 0.47 | 555.4% |
> ⚠️ **Crisp is still tf32 here — not IEEE.** This chapter's Crisp kernel uses tf32 tensor cores by construction, so it does *not* honor the IEEE request (a Crisp kernel would emit a precision warning); meanwhile IEEE cuBLAS drops to true fp32. So the ">100% of Optimal" figures are tf32-vs-fp32, not IEEE-vs-IEEE — the `fast` table is the only honest tensor-core comparison.


### Compile Times (avg across precision)

| Chapter | Competitor | Avg Compile (ms) | × vs Crisp |
|---|---|---:|---:|
| chap0_sync | Crisp | 331 | 1.0× (baseline) |
| chap0_sync | CUBLAS_Optimal | 1326 | 4.0× slower |
| chap0_sync | CUDA_Apples | 1495 | 4.5× slower |
| chap1_async_linear | Crisp | 333 | 1.0× (baseline) |
| chap1_async_linear | CUDA_Apples | 2451 | 7.4× slower |
| chap1.5_async_block | Crisp | 312 | 1.0× (baseline) |
| chap1.5_async_block | CUDA_Apples | 2447 | 7.9× slower |
| chap2_pipelined_block | Crisp | 405 | 1.0× (baseline) |
| chap2_pipelined_block | CUDA_Apples | 2469 | 6.1× slower |
| chap3_wgmma | Crisp | 427 | 1.0× (baseline) |
| chap3_wgmma | CUBLAS_Optimal | 1379 | 3.2× slower |

> Crisp compiles a kernel to PTX; the native competitors invoke `nvcc`. Lower is better; `× vs Crisp` is how much longer than Crisp that toolchain takes.
