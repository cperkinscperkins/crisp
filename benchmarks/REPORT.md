# Crisp Benchmark Report

## Hardware: NVIDIA H100

### chap0_sync

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp (Wall ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.11 | 0.01 | 0.00 | 2.49 | 0.01 | 464.32 | 0.10 | 0.34 | 620.82 | 1.6% | 4.0% |
| 512x512x512 | 34.64 | 0.01 | 0.00 | 4.71 | 0.06 | 429.32 | 0.38 | 0.70 | 408.25 | 1.1% | 8.1% |
| 1024x1024x1024 | 135.06 | 0.02 | 0.00 | 5.45 | 0.39 | 353.01 | 1.52 | 1.41 | 496.77 | 1.1% | 28.0% |
| 2048x2048x2048 | 359.73 | 0.05 | 0.00 | 5.72 | 3.00 | 694.75 | 5.58 | 3.08 | 728.76 | 1.6% | 97.6% |
| 4096x4096x4096 | 436.35 | 0.31 | 0.00 | 5.79 | 23.75 | 3314.07 | 5.63 | 24.41 | 3392.12 | 1.3% | 97.3% |



#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp (Wall ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.82 | 0.01 | 0.00 | 2.49 | 0.01 | 304.10 | 0.10 | 0.34 | 326.58 | 3.5% | 4.0% |
| 512x512x512 | 17.79 | 0.02 | 0.00 | 4.72 | 0.06 | 289.87 | 0.38 | 0.70 | 361.50 | 2.2% | 8.2% |
| 1024x1024x1024 | 38.31 | 0.06 | 0.00 | 5.45 | 0.39 | 338.71 | 1.52 | 1.41 | 456.32 | 4.0% | 27.9% |
| 2048x2048x2048 | 50.41 | 0.34 | 0.00 | 5.72 | 3.00 | 677.97 | 5.58 | 3.08 | 677.37 | 11.1% | 97.6% |
| 4096x4096x4096 | 51.99 | 2.64 | 0.00 | 5.74 | 23.92 | 3338.17 | 5.63 | 24.42 | 3344.17 | 10.8% | 97.9% |



#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp (Wall ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.80 | 0.01 | 0.00 | 2.46 | 0.01 | 302.88 | 0.10 | 0.34 | 345.30 | 3.5% | 4.0% |
| 512x512x512 | 18.29 | 0.01 | 0.00 | 4.70 | 0.06 | 301.68 | 0.38 | 0.71 | 378.89 | 2.1% | 8.1% |
| 1024x1024x1024 | 38.27 | 0.06 | 0.00 | 5.45 | 0.39 | 352.02 | 1.54 | 1.40 | 465.62 | 4.0% | 28.2% |
| 2048x2048x2048 | 50.42 | 0.34 | 0.00 | 5.72 | 3.01 | 695.07 | 5.58 | 3.08 | 694.82 | 11.1% | 97.6% |
| 4096x4096x4096 | 51.98 | 2.64 | 0.00 | 5.74 | 23.92 | 3323.27 | 5.63 | 24.43 | 3373.51 | 10.8% | 97.9% |


### chap1.5_async_block

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.11 | 0.01 | 0.00 | 2.34 | 0.01 | 405.74 |
| 512x512x512 | 34.64 | 0.01 | 0.00 | 4.02 | 0.07 | 301.11 |
| 1024x1024x1024 | 135.06 | 0.02 | 0.00 | 4.58 | 0.47 | 362.47 |
| 2048x2048x2048 | 359.73 | 0.05 | 0.00 | 4.78 | 3.59 | 775.15 |
| 4096x4096x4096 | 436.35 | 0.31 | 0.00 | 4.81 | 28.57 | 3904.46 |



#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.82 | 0.01 | 0.00 | 2.39 | 0.01 | 408.65 |
| 512x512x512 | 17.79 | 0.02 | 0.00 | 4.00 | 0.07 | 299.71 |
| 1024x1024x1024 | 38.31 | 0.06 | 0.00 | 4.54 | 0.47 | 353.84 |
| 2048x2048x2048 | 50.41 | 0.34 | 0.00 | 4.74 | 3.62 | 767.51 |
| 4096x4096x4096 | 51.99 | 2.64 | 0.00 | 4.78 | 28.78 | 3958.43 |



#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.80 | 0.01 | 0.00 | 2.34 | 0.01 | 417.36 |
| 512x512x512 | 18.29 | 0.01 | 0.00 | 4.03 | 0.07 | 305.18 |
| 1024x1024x1024 | 38.27 | 0.06 | 0.00 | 4.58 | 0.47 | 347.23 |
| 2048x2048x2048 | 50.42 | 0.34 | 0.00 | 4.78 | 3.59 | 778.09 |
| 4096x4096x4096 | 51.98 | 2.64 | 0.00 | 4.81 | 28.57 | 3902.19 |


### chap1_async_linear

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp (Wall ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.11 | 0.01 | 0.00 | 2.33 | 0.01 | 429.88 | 0.15 | 0.22 | 500.61 | 2.5% | 6.5% |
| 512x512x512 | 34.64 | 0.01 | 0.00 | 4.03 | 0.07 | 332.82 | 0.62 | 0.43 | 360.55 | 1.8% | 15.4% |
| 1024x1024x1024 | 135.06 | 0.02 | 0.00 | 4.57 | 0.47 | 377.93 | 2.49 | 0.86 | 418.58 | 1.8% | 54.3% |
| 2048x2048x2048 | 359.73 | 0.05 | 0.00 | 4.78 | 3.59 | 778.36 | 8.90 | 1.93 | 569.11 | 2.5% | 186.3% |
| 4096x4096x4096 | 436.35 | 0.31 | 0.00 | 4.81 | 28.57 | 3903.67 | 9.05 | 15.18 | 2285.99 | 2.1% | 188.1% |



#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp (Wall ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.82 | 0.01 | 0.00 | 2.36 | 0.01 | 395.00 | 0.15 | 0.22 | 306.95 | 5.4% | 6.5% |
| 512x512x512 | 17.79 | 0.02 | 0.00 | 4.00 | 0.07 | 295.27 | 0.62 | 0.43 | 327.00 | 3.5% | 15.5% |
| 1024x1024x1024 | 38.31 | 0.06 | 0.00 | 4.55 | 0.47 | 355.08 | 2.50 | 0.86 | 382.35 | 6.5% | 55.1% |
| 2048x2048x2048 | 50.41 | 0.34 | 0.00 | 4.74 | 3.62 | 756.03 | 8.98 | 1.91 | 531.43 | 17.8% | 189.3% |
| 4096x4096x4096 | 51.99 | 2.64 | 0.00 | 4.78 | 28.78 | 3892.33 | 9.07 | 15.16 | 2230.98 | 17.4% | 189.9% |



#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) | Crisp (TFLOPS) | Crisp (Kernel ms) | Crisp (Wall ms) | Crisp vs Optimal (%) | Crisp vs Apples (%) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.80 | 0.01 | 0.00 | 2.23 | 0.02 | 606.53 | 0.15 | 0.22 | 306.31 | 5.4% | 6.8% |
| 512x512x512 | 18.29 | 0.01 | 0.00 | 4.04 | 0.07 | 299.44 | 0.62 | 0.43 | 361.07 | 3.4% | 15.4% |
| 1024x1024x1024 | 38.27 | 0.06 | 0.00 | 4.58 | 0.47 | 353.37 | 2.52 | 0.85 | 402.12 | 6.6% | 54.9% |
| 2048x2048x2048 | 50.42 | 0.34 | 0.00 | 4.78 | 3.59 | 772.41 | 8.99 | 1.91 | 535.59 | 17.8% | 188.1% |
| 4096x4096x4096 | 51.98 | 2.64 | 0.00 | 4.81 | 28.57 | 3902.75 | 9.07 | 15.15 | 2230.71 | 17.4% | 188.5% |


### chap2_pipelined_block

#### Precision: fast (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 6.11 | 0.01 | 0.00 | 2.19 | 0.02 | 397.82 |
| 512x512x512 | 34.64 | 0.01 | 0.00 | 3.58 | 0.08 | 292.04 |
| 1024x1024x1024 | 135.06 | 0.02 | 0.00 | 3.98 | 0.54 | 360.51 |
| 2048x2048x2048 | 359.73 | 0.05 | 0.00 | 4.15 | 4.14 | 813.86 |
| 4096x4096x4096 | 436.35 | 0.31 | 0.00 | 4.22 | 32.58 | 4373.71 |



#### Precision: ieee (ftz=ftz)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.82 | 0.01 | 0.00 | 2.17 | 0.02 | 397.59 |
| 512x512x512 | 17.79 | 0.02 | 0.00 | 3.55 | 0.08 | 291.28 |
| 1024x1024x1024 | 38.31 | 0.06 | 0.00 | 3.95 | 0.54 | 352.68 |
| 2048x2048x2048 | 50.41 | 0.34 | 0.00 | 4.12 | 4.17 | 824.14 |
| 4096x4096x4096 | 51.99 | 2.64 | 0.00 | 4.19 | 32.82 | 4406.42 |



#### Precision: ieee (ftz=preserve)

| Size | CUBLAS_Optimal (TFLOPS) | CUBLAS_Optimal (Kernel ms) | CUBLAS_Optimal (Wall ms) | CUDA_Apples (TFLOPS) | CUDA_Apples (Kernel ms) | CUDA_Apples (Wall ms) |
|---|---:|---:|---:|---:|---:|---:|
| 256x256x256 | 2.80 | 0.01 | 0.00 | 2.19 | 0.02 | 405.89 |
| 512x512x512 | 18.29 | 0.01 | 0.00 | 3.58 | 0.07 | 295.11 |
| 1024x1024x1024 | 38.27 | 0.06 | 0.00 | 3.98 | 0.54 | 353.93 |
| 2048x2048x2048 | 50.42 | 0.34 | 0.00 | 4.15 | 4.14 | 815.03 |
| 4096x4096x4096 | 51.98 | 2.64 | 0.00 | 4.22 | 32.58 | 4367.62 |


### Compile Times

| Chapter | Precision | Competitor | Avg Device Compile (ms) | Avg All Compile (ms) |
|---|---|---|---:|---:|
| chap0_sync | fast (ftz=preserve) | CUBLAS_Optimal | 1287.59 | 1287.59 |
| chap0_sync | fast (ftz=preserve) | CUDA_Apples | 1447.27 | 1447.27 |
| chap0_sync | fast (ftz=preserve) | Crisp | 310.69 | 339.95 |
| chap0_sync | ieee (ftz=ftz) | CUBLAS_Optimal | 1270.60 | 1270.60 |
| chap0_sync | ieee (ftz=ftz) | CUDA_Apples | 1451.96 | 1451.96 |
| chap0_sync | ieee (ftz=ftz) | Crisp | 314.49 | 314.87 |
| chap0_sync | ieee (ftz=preserve) | CUBLAS_Optimal | 1252.67 | 1252.67 |
| chap0_sync | ieee (ftz=preserve) | CUDA_Apples | 1431.04 | 1431.04 |
| chap0_sync | ieee (ftz=preserve) | Crisp | 314.90 | 315.29 |
| chap1.5_async_block | fast (ftz=preserve) | CUDA_Apples | 2413.47 | 2413.47 |
| chap1.5_async_block | ieee (ftz=ftz) | CUDA_Apples | 2376.04 | 2376.04 |
| chap1.5_async_block | ieee (ftz=preserve) | CUDA_Apples | 2407.40 | 2407.40 |
| chap1_async_linear | fast (ftz=preserve) | CUDA_Apples | 2395.24 | 2395.24 |
| chap1_async_linear | fast (ftz=preserve) | Crisp | 316.59 | 346.71 |
| chap1_async_linear | ieee (ftz=ftz) | CUDA_Apples | 2399.43 | 2399.43 |
| chap1_async_linear | ieee (ftz=ftz) | Crisp | 316.27 | 316.65 |
| chap1_async_linear | ieee (ftz=preserve) | CUDA_Apples | 2414.15 | 2414.15 |
| chap1_async_linear | ieee (ftz=preserve) | Crisp | 310.47 | 310.86 |
| chap2_pipelined_block | fast (ftz=preserve) | CUDA_Apples | 2412.61 | 2412.61 |
| chap2_pipelined_block | ieee (ftz=ftz) | CUDA_Apples | 2409.37 | 2409.37 |
| chap2_pipelined_block | ieee (ftz=preserve) | CUDA_Apples | 2410.62 | 2410.62 |

