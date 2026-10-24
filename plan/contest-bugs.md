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

### Why Did Earlier `vectoradd` Submissions Avoid the Crash?
1. In the first contest entry (`fa7ccff4`), winning submission files such as [`crisp_f16_direct_half4.py`](contests/gpu-mode/01-vectoradd-v2/crisp_f16_direct_half4.py) were originally generated with prefixed registers (`%%cr_`).
2. In subsequent commits, refactoring separated `package_gpumode.py` without consolidating the packager, leaving some regeneration scripts using unprefixed registers.
3. Crucially, in simple 3-parameter streaming kernels where all parameters are copied in the very first basic block before inner registers are reused, register allocator luck can sometimes allow NVCC to map outer and inner registers without observable clobbering. However, in kernels with later parameter reads (such as `vectorsum` reading `param_8` zero offset at line 918) or wider register sets, the shadowing collision is 100% deterministic and fatal.

### Resolution & Mitigation
The packaging logic is centralized into a single canonical module: [`contests/ptx_packager.py`](contests/ptx_packager.py).

Instead of maintaining a fragile whitelist of hardware registers, the packager matches LLVM's exact NVPTX virtual register classes via regex:
```python
LLVM_REG_PATTERN = re.compile(r"%(rd|rs|r|fd|f|p|h|hh)(\d+|<[0-9]+>)")
```
All virtual registers (`%rd<N>`, `%r<N>`, `%p<N>`, `%f<N>`, etc.) are prefixed to `%cr_rd...`, `%cr_r...`. All special hardware registers (`%ctaid`, `%ntid`, `%tid`, `%laneid`, `%lanemask_*`, `%globaltimer`, `%cluster_*`, `%nsmid`, `%dynamic_smem_size`, etc.) remain completely untouched.

Because the inner registers are named `%cr_rd...`, `nvcc`'s outer `%rd1` is never shadowed:
```ptx
{
    .reg .b64 %cr_rd<81>;
    mov.b64 %cr_rd41, %rd1;  // Correctly reads NVCC's outer register!
}
```

### Compiler Architecture Decisions
- **Option A (Compiler Flag `--ptx-reg-prefix`): Declined.** Register namespacing for C++ inline assembly is strictly a submission packaging artifact, not a compiler IR concern. The Crisp compiler remains clean and focused on standard PTX emission, with packaging handled in [`contests/ptx_packager.py`](contests/ptx_packager.py).
- **Future Direction (Direct CUBIN / Driver API):** Package contest entries using compiled `.cubin` / PTX loaded directly via `cuModuleLoadData` / `cuLaunchKernel` or PyTorch's `cuda.CUDAModule`, bypassing `nvcc`'s C++ inline assembly parser entirely.

---

## [BUG-002] Concurrent FP32 Global Atomic Drift vs. Per-Thread FP32 / Cross-Thread FP64 Reduction

- **Date Discovered:** 2026-10-21 (Refined 2026-10-24)
- **Component:** Reduction Kernels (`vectorsum_v2` and future reduction tasks like `softmax`, `norm`, `gemm`)
- **Severity:** High (intermittent `ranked validation failed` in `leaderboard` mode while passing `--mode test` or single-seed `benchmark` runs)
- **Status:** Resolved via FP32 per-thread accumulation + single widening `(to-double ...)` per thread + FP64 `reduce-workgroup` + 1 `atom.global.add.f64` per workgroup + last-workgroup ticket write (`vectorsum_lastman_wg_u8.crisp` / `vectorsum_direct_tile16.crisp`).

### Symptoms
A reduction kernel compiles cleanly, runs at high bandwidth, and passes `--mode test` and `--mode benchmark`. However, under official `--mode leaderboard` evaluation, a pure-FP32 global atomic reduction fails with:
```
Application error: Submission <ID> failed: ranked validation failed on <GPU>; submission will not appear on the leaderboard
```

### Root Cause Analysis
1. In GPU MODE `vectorsum_v2`, the reference kernel accumulates in `float64` and casts back to `float32`:
   ```python
   # reference.py
   def ref_kernel(data):
       data, output = data
       return data.to(torch.float64).sum().to(torch.float32)
   ```
   and checks `torch.allclose(received, expected, rtol=1e-05, atol=1e-05)`.
2. Crucially, `benchmark` mode runs `check_implementation` once per case with a fixed seed (`4242`), whereas `leaderboard` mode re-seeds (`seed += 42`) and re-validates on **every timing repetition** — hundreds of random `offset` / `scale` draws across the run.
3. Monte Carlo analysis (`5,000` random seeds at $N = 52,428,800$, matching `task.py`'s generator) proved that **widening every loaded element to `double` in the inner loop is unnecessary** and hurts throughput (since `FP64` runs at 1:64 of `FP32` throughput on L4 `sm_89` and 1:2 on A100/H100/B200, plus 64-bit register pressure):
   - **Thousands of sequential `atom.global.add.f32` into one cell**: maximum relative error $= 3.31 \times 10^{-5}$, failing `rtol = 1e-5` on **5.8% of random seeds** (explaining why single-seed `benchmark` passed while multi-seed `leaderboard` failed).
   - **Per-thread `FP32` accumulation (`a0..a3` as `float`, $\le 200$ adds per accumulator) followed by `FP64` reduction across threads/workgroups**: maximum relative error across 5,000 seeds $= \mathbf{9.48 \times 10^{-8}}$ (**0 failures**, $> 100\times$ inside the $10^{-5}$ tolerance!).

### Resolution & Architectural Solution in Crisp
1. **Load 128-bit Vectors & Accumulate in FP32 Per Thread:** Keep global memory loads as `float4` (with `:cache (:streaming :prefetch 256)` and `&out` read-only `.nc`) and accumulate into four `float` registers (`a0..a3`) inside the inner loop or contiguous block tile.
2. **Widen to FP64 Once Per Thread:** After the per-thread load loop/tile completes, widen the thread's sum once: `(let ((acc (to-double (+ (+ a0 a1) (+ a2 a3))))) ...)`.
3. **Workgroup Reduction in FP64:** Use `(reduce-workgroup #'+ acc 0.0d)` so only thread 0 of each workgroup holds the block's `double` sum (1 atomic per 256-thread block instead of 8 per block).
4. **Single-Launch Last-Workgroup Ticket Pattern:** Thread 0 issues one `atomic-add!` into a persistent `double` scratch cell (`partial`), executes `(mem-fence)`, and increments a `uint` `ticket` cell. The last workgroup to arrive (`(= arrived (- (get-num-groups 0) 1ul))`) executes `(mem-fence)`, resets `partial` via `(atomic-xchg! (~ partial) 0.0d)`, converts the final sum to `float32` (`to-float`), writes `result`, and resets `ticket` to `0u`. This eliminates all per-call host allocation, zeroing, or dtype conversion launches.


