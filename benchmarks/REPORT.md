# Crisp Benchmark Report

## Hardware: NVIDIA H100

### chap0_sync

#### Precision: fast (ftz=ftz)

| Size | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp (Wall ms) | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.53 | 0.01 | 0.00 | 0.10 | 0.34 | 0.00 | 5.99 | 0.01 | 0.00 | 3.9% |
| 512x512x512 | 4.73 | 0.06 | 0.00 | 0.39 | 0.70 | 0.00 | 34.64 | 0.01 | 0.00 | 8.1% |
| 1024x1024x1024 | 5.45 | 0.39 | 0.00 | 1.53 | 1.40 | 0.00 | 136.01 | 0.02 | 0.00 | 28.1% |
| 2048x2048x2048 | 5.72 | 3.00 | 0.00 | 5.58 | 3.08 | 0.00 | 359.68 | 0.05 | 0.00 | 97.6% |
| 4096x4096x4096 | 5.79 | 23.75 | 0.00 | 5.63 | 24.40 | 0.00 | 436.17 | 0.32 | 0.00 | 97.3% |



#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.13 | 0.01 | 0.00 | 2.51 | 0.01 | 372.91 |
| 512x512x512 | 34.20 | 0.01 | 0.00 | 4.71 | 0.06 | 276.84 |
| 1024x1024x1024 | 136.03 | 0.02 | 0.00 | 5.45 | 0.39 | 327.98 |
| 2048x2048x2048 | 360.81 | 0.05 | 0.00 | 5.72 | 3.00 | 673.61 |
| 4096x4096x4096 | 436.24 | 0.32 | 0.00 | 5.79 | 23.75 | 3280.85 |



#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.85 | 0.01 | 0.00 | 2.52 | 0.01 | 370.51 |
| 512x512x512 | 17.89 | 0.01 | 0.00 | 4.74 | 0.06 | 277.98 |
| 1024x1024x1024 | 38.55 | 0.06 | 0.00 | 5.49 | 0.39 | 327.65 |
| 2048x2048x2048 | 50.74 | 0.34 | 0.00 | 5.76 | 2.98 | 653.34 |
| 4096x4096x4096 | 52.34 | 2.63 | 0.00 | 5.79 | 23.75 | 3274.60 |



#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.88 | 0.01 | 0.00 | 2.51 | 0.01 | 374.37 |
| 512x512x512 | 18.18 | 0.01 | 0.00 | 4.74 | 0.06 | 274.52 |
| 1024x1024x1024 | 38.55 | 0.06 | 0.00 | 5.49 | 0.39 | 318.25 |
| 2048x2048x2048 | 50.74 | 0.34 | 0.00 | 5.76 | 2.98 | 660.63 |
| 4096x4096x4096 | 52.33 | 2.63 | 0.00 | 5.79 | 23.75 | 3276.17 |


### chap1.5_async_block

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.13 | 0.01 | 0.00 | 2.37 | 0.01 | 268.04 |
| 512x512x512 | 34.20 | 0.01 | 0.00 | 4.04 | 0.07 | 286.16 |
| 1024x1024x1024 | 136.03 | 0.02 | 0.00 | 4.58 | 0.47 | 334.11 |
| 2048x2048x2048 | 360.81 | 0.05 | 0.00 | 4.78 | 3.59 | 743.89 |
| 4096x4096x4096 | 436.24 | 0.32 | 0.00 | 4.81 | 28.57 | 3845.10 |



#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.85 | 0.01 | 0.00 | 2.36 | 0.01 | 269.70 |
| 512x512x512 | 17.89 | 0.01 | 0.00 | 4.03 | 0.07 | 277.55 |
| 1024x1024x1024 | 38.55 | 0.06 | 0.00 | 4.58 | 0.47 | 339.26 |
| 2048x2048x2048 | 50.74 | 0.34 | 0.00 | 4.78 | 3.59 | 730.03 |
| 4096x4096x4096 | 52.34 | 2.63 | 0.00 | 4.81 | 28.57 | 3857.64 |



#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.88 | 0.01 | 0.00 | 2.37 | 0.01 | 282.60 |
| 512x512x512 | 18.18 | 0.01 | 0.00 | 4.03 | 0.07 | 272.19 |
| 1024x1024x1024 | 38.55 | 0.06 | 0.00 | 4.58 | 0.47 | 342.15 |
| 2048x2048x2048 | 50.74 | 0.34 | 0.00 | 4.78 | 3.59 | 735.97 |
| 4096x4096x4096 | 52.33 | 2.63 | 0.00 | 4.81 | 28.57 | 3860.28 |


### chap1_async_linear

#### Precision: fast (ftz=ftz)

| Size | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp (Wall ms) |
|---|---:|---:|---:|
| 256x256x256 | 0.15 | 0.22 | 0.00 |
| 512x512x512 | 0.62 | 0.43 | 0.00 |
| 1024x1024x1024 | 2.52 | 0.85 | 0.00 |
| 2048x2048x2048 | 8.91 | 1.93 | 0.00 |
| 4096x4096x4096 | 9.06 | 15.17 | 0.00 |



#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.13 | 0.01 | 0.00 | 2.37 | 0.01 | 269.90 |
| 512x512x512 | 34.20 | 0.01 | 0.00 | 4.04 | 0.07 | 276.03 |
| 1024x1024x1024 | 136.03 | 0.02 | 0.00 | 4.58 | 0.47 | 335.00 |
| 2048x2048x2048 | 360.81 | 0.05 | 0.00 | 4.78 | 3.59 | 736.80 |
| 4096x4096x4096 | 436.24 | 0.32 | 0.00 | 4.81 | 28.57 | 3873.54 |



#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.85 | 0.01 | 0.00 | 2.38 | 0.01 | 291.21 |
| 512x512x512 | 17.89 | 0.01 | 0.00 | 4.04 | 0.07 | 277.13 |
| 1024x1024x1024 | 38.55 | 0.06 | 0.00 | 4.58 | 0.47 | 340.88 |
| 2048x2048x2048 | 50.74 | 0.34 | 0.00 | 4.78 | 3.59 | 737.22 |
| 4096x4096x4096 | 52.34 | 2.63 | 0.00 | 4.81 | 28.57 | 3941.22 |



#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.88 | 0.01 | 0.00 | 2.37 | 0.01 | 266.78 |
| 512x512x512 | 18.18 | 0.01 | 0.00 | 4.04 | 0.07 | 270.91 |
| 1024x1024x1024 | 38.55 | 0.06 | 0.00 | 4.58 | 0.47 | 320.36 |
| 2048x2048x2048 | 50.74 | 0.34 | 0.00 | 4.78 | 3.59 | 724.35 |
| 4096x4096x4096 | 52.33 | 2.63 | 0.00 | 4.81 | 28.57 | 3849.97 |


### chap2_pipelined_block

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.13 | 0.01 | 0.00 | 2.21 | 0.02 | 271.82 |
| 512x512x512 | 34.20 | 0.01 | 0.00 | 3.57 | 0.08 | 280.21 |
| 1024x1024x1024 | 136.03 | 0.02 | 0.00 | 3.98 | 0.54 | 340.00 |
| 2048x2048x2048 | 360.81 | 0.05 | 0.00 | 4.15 | 4.14 | 798.52 |
| 4096x4096x4096 | 436.24 | 0.32 | 0.00 | 4.22 | 32.58 | 4335.20 |



#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.85 | 0.01 | 0.00 | 2.18 | 0.02 | 284.90 |
| 512x512x512 | 17.89 | 0.01 | 0.00 | 3.58 | 0.08 | 291.06 |
| 1024x1024x1024 | 38.55 | 0.06 | 0.00 | 3.98 | 0.54 | 334.06 |
| 2048x2048x2048 | 50.74 | 0.34 | 0.00 | 4.15 | 4.14 | 791.84 |
| 4096x4096x4096 | 52.34 | 2.63 | 0.00 | 4.22 | 32.58 | 4333.79 |



#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.88 | 0.01 | 0.00 | 2.18 | 0.02 | 273.14 |
| 512x512x512 | 18.18 | 0.01 | 0.00 | 3.58 | 0.08 | 275.52 |
| 1024x1024x1024 | 38.55 | 0.06 | 0.00 | 3.98 | 0.54 | 342.90 |
| 2048x2048x2048 | 50.74 | 0.34 | 0.00 | 4.15 | 4.14 | 794.82 |
| 4096x4096x4096 | 52.33 | 2.63 | 0.00 | 4.22 | 32.58 | 4330.21 |


### Compile Times

| Chapter | Precision | Competitor | Avg Device Compile (ms) | Avg All Compile (ms) |
|---|---|---|---:|---:|
| chap0_sync | fast (ftz=ftz) | CUBLAS_Optimal | 0.00 | 0.00 |
| chap0_sync | fast (ftz=ftz) | CUDA_Apples | 0.00 | 0.00 |
| chap0_sync | fast (ftz=ftz) | Crisp | 0.00 | 0.00 |
| chap0_sync | fast (ftz=preserve) | CUDA_Apples | 0.00 | 0.00 |
| chap0_sync | ieee (ftz=ftz) | CUDA_Apples | 0.00 | 0.00 |
| chap0_sync | ieee (ftz=preserve) | CUDA_Apples | 0.00 | 0.00 |
| chap1.5_async_block | fast (ftz=preserve) | CUDA_Apples | 0.00 | 0.00 |
| chap1.5_async_block | ieee (ftz=ftz) | CUDA_Apples | 0.00 | 0.00 |
| chap1.5_async_block | ieee (ftz=preserve) | CUDA_Apples | 0.00 | 0.00 |
| chap1_async_linear | fast (ftz=ftz) | Crisp | 0.00 | 0.00 |
| chap1_async_linear | fast (ftz=preserve) | CUDA_Apples | 0.00 | 0.00 |
| chap1_async_linear | ieee (ftz=ftz) | CUDA_Apples | 0.00 | 0.00 |
| chap1_async_linear | ieee (ftz=preserve) | CUDA_Apples | 0.00 | 0.00 |
| chap2_pipelined_block | fast (ftz=preserve) | CUDA_Apples | 0.00 | 0.00 |
| chap2_pipelined_block | ieee (ftz=ftz) | CUDA_Apples | 0.00 | 0.00 |
| chap2_pipelined_block | ieee (ftz=preserve) | CUDA_Apples | 0.00 | 0.00 |
| vendor_ceiling | fast (ftz=preserve) | CUBLAS_Optimal | 0.00 | 0.00 |
| vendor_ceiling | ieee (ftz=ftz) | CUBLAS_Optimal | 0.00 | 0.00 |
| vendor_ceiling | ieee (ftz=preserve) | CUBLAS_Optimal | 0.00 | 0.00 |

