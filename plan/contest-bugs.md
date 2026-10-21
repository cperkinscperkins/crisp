# Crisp Contest Engineering & Integration Bugs

This document records bugs, traps, and integration pitfalls encountered while deploying Crisp kernels to competition harnesses (GPU MODE, LeetGPU, Modal, etc.) and their architectural resolutions.

---

## [BUG-001] NVCC PTX Inline Assembly Parameter Shadowing Trap

- **Date Discovered:** 2026-10-16 / 2026-10-19
- **Component:** PTX Inline Assembly Packaging (`ptx_entry_to_inline_asm` in `package_gpumode.py` and contest runners)
- **Severity:** Critical (silent pointer corruption leading to immediate GPU MMU trap / `cudaErrorIllegalAddress`)
- **Status:** Resolved via virtual register prefixing in packager; permanent compiler emitter option under consideration.

### Symptoms
Any kernel compiled from Crisp and embedded into a CUDA C++ submission file via `asm volatile("{\n ... \n}")` immediately crashes upon execution with:
```
torch.AcceleratorError: CUDA error: an illegal memory access was encountered (cudaErrorIllegalAddress)
```
The crash occurs on *all* input sizes, including trivial cases like $N = 1$, even when the kernel logic and bounds checks are completely correct and verified.

### Root Cause Analysis
1. When `nvcc` compiles the outer CUDA host/device wrapper function:
   ```cpp
   __global__ void crisp_kernel_wrapper(uint64_t in_ptr, uint64_t out_ptr, uint64_t len) {
       asm volatile(
           "{\n"
           "    .reg .b64 %rd<81>;\n"
           "    mov.b64 %rd41, %0;\n"
           "    ...\n"
           "}\n"
           : : "l"(in_ptr), "l"(out_ptr), "l"(len) : "memory"
       );
   }
   ```
   `nvcc` creates its own function-level PTX frame and allocates outer registers:
   ```ptx
   .reg .b64 %rd<5>;
   ld.param.u64 %rd1, [in_ptr];
   ld.param.u64 %rd2, [out_ptr];
   ```
2. In the inline assembly block, `nvcc` substitutes `%0` with `%rd1` and `%1` with `%rd2`.
3. However, LLVM's NVPTX backend emits standard PTX virtual register declarations:
   ```ptx
   .reg .b64 %rd<81>;
   ```
4. Under PTX lexical scoping rules, declaring `.reg .b64 %rd<81>;` inside an inner `{ ... }` block creates a **new local register namespace** that **shadows** the outer `%rd1..%rd5` allocated by `nvcc`.
5. Consequently, the substituted instruction:
   ```ptx
   mov.b64 %rd41, %rd1;
   ```
   reads from the *inner uninitialized register `%rd1`* (evaluating to `0` or uninitialized garbage) rather than the outer `%rd1` holding the real GPU device pointer!
6. Any subsequent read or write (e.g. `ld.global` or `atom.global`) dereferences garbage, immediately causing a hardware MMU fault (`cudaErrorIllegalAddress`).

### Resolution & Mitigation
In the Python PTX packager (`ptx_entry_to_inline_asm`), all PTX virtual register declarations and references emitted by Crisp are systematically renamed to a distinct namespace prefix (`%cr_`):
- `%rd<N>` $\rightarrow$ `%cr_rd<N>`
- `%r<N>`  $\rightarrow$ `%cr_r<N>`
- `%p<N>`  $\rightarrow$ `%cr_p<N>`
- `%f<N>`  $\rightarrow$ `%cr_f<N>`
- `%d<N>`  $\rightarrow$ `%cr_d<N>`
- `%rs<N>` $\rightarrow$ `%cr_rs<N>`

Hardware registers (`%ctaid`, `%ntid`, `%tid`, `%nctaid`, `%laneid`, `%warpid`, `%smid`, `%gridid`, `%clock`, etc.) and branch labels (`$L__...`) are strictly excluded from renaming.

Because the inner registers are named `%cr_rd...`, `nvcc`'s outer `%rd1` is never shadowed:
```ptx
{
    .reg .b64 %cr_rd<81>;
    mov.b64 %cr_rd41, %rd1;  // Correctly reads NVCC's outer register!
}
```

### Long-Term Compiler Roadmap Items
- **Option A (Direct Emitter Namespace):** Add a flag `--ptx-reg-prefix=<str>` to `bin/crisp-compile` so LLVM's NVPTX emitter or Crisp's PTX post-pass can output prefixed registers directly.
- **Option B (CUBIN / Driver API):** Package contest entries using compiled `.cubin` / PTX loaded directly via `cuModuleLoadData` / `cuLaunchKernel` or PyTorch's `cuda.CUDAModule`, bypassing `nvcc`'s C++ inline assembly parser entirely.

---

## [BUG-002] FP32 Single-Precision Accumulation Drift vs. Double-Precision Reference Trap

- **Date Discovered:** 2026-10-21
- **Component:** Reduction Kernels (`vectorsum_v2` and future reduction tasks like `softmax`, `norm`, `gemm`)
- **Severity:** High (intermittent `ranked validation failed` in `leaderboard` mode while passing `--mode test` or benchmark sizes)
- **Status:** Resolved via native FP64 accumulation in Crisp registers (`to-double`, `shuffle-xor`, `atom.global.add.f64`).

### Symptoms
A reduction kernel compiles cleanly, runs at high bandwidth, and passes standard test cases (e.g. $N \le 4,096$). However, under official `--mode leaderboard` evaluation, the submission fails with:
```
Application error: Submission <ID> failed: ranked validation failed on <GPU>; submission will not appear on the leaderboard
```

### Root Cause Analysis
1. In competition harnesses like GPU MODE, reference kernels are implemented with high precision to prevent numerical ambiguity:
   ```python
   # reference.py
   def ref_kernel(data):
       data, output = data
       return data.to(torch.float64).sum().to(torch.float32)
   ```
2. Validation checks use strict tolerances:
   ```python
   torch.allclose(received, expected, rtol=1e-05, atol=1e-08)
   ```
3. When reducing $52,428,800$ floats in single precision (`float32`), the 24-bit mantissa loses precision when large numbers are accumulated. Furthermore, if intermediate sums cancel out (e.g., standard normal inputs scaled and offset close to 0), catastrophic cancellation causes relative error to exceed $10^{-5}$ (`atol=1e-08` dominates when the expected sum is small).
4. If tens of thousands of warps perform `atom.global.add.f32` concurrently, non-deterministic addition order introduces random LSB truncation.

### Resolution & Architectural Solution in Crisp
1. **Load 128-bit Vectors:** Keep global memory loads as `float4` (128-bit) to saturate memory bandwidth.
2. **Promote Accumulators to Double in Registers:** Upcast each vector component with `(to-double ...)` and accumulate in 64-bit double registers (`a0..a3` typed as `double`).
3. **Double-Precision Warp Reduction:** Warp shuffles reduce the 64-bit double values across lanes using Crisp's native 64-bit shuffle decomposition.
4. **Native FP64 Global Atomic:** The warp leader issues `atom.global.add.f64` directly into an 8-byte double accumulator.
5. **Final FP32 Cast:** The final scalar sum is cast back to `float32` once at the very end, matching the reference kernel's mathematical definition bit-for-bit.


