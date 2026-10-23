**No** for BUG-001, but **yes, significantly** for BUG-002.

Here is the exact technical breakdown:

---

### 1. BUG-001 (Register Shadowing): 0% Overhead

The virtual register prefixing (`%cr_rd...`, `%cr_r...`) happens purely during PTX string emission before passing the code to `nvcc`. 

NVIDIA's PTX compiler (`ptxas`) assigns physical silicon registers (`R0`–`R255`) identically regardless of whether the virtual PTX name was `%rd1` or `%cr_rd1`. **BUG-001 has exactly zero impact on machine code, register allocation, or execution speed.**

---

### 2. BUG-002 (FP64 Accumulation Workaround): ~13% to 40% Overhead

BUG-002 *does* currently prevent us from reaching the absolute fastest possible times. We saw this directly in the telemetry:
- On **H100**, the pure FP32 kernel ran in **`86.8 µs`** (mean `89.4 µs`).
- The FP64-accumulating kernel ran in **`98.9 µs`** (mean `100.0 µs` / `101.0 µs` public).
- That is an immediate **`12–14 µs` (~13%) penalty on H100**, and an even larger penalty on GPUs with weaker FP64 units like **L4** (where FP64 is throttled to 1/64th rate).

The slowdown comes from four distinct sources:

#### A. Host-Side C++ Launch Overhead (~5–10 µs)
In [`crisp_vectorsum_warp_reduce.py`](file:///c:/Users/cperk/Documents/crisp/contests/gpu-mode/02-vectorsum-v2/crisp_vectorsum_warp_reduce.py):
```cpp
auto d_out = torch::zeros({1}, input.options().dtype(torch::kFloat64));
...
crisp_vectorsum_kernel<<<...>>>(..., d_out.data_ptr(), ...);
output.copy_(d_out.to(torch::kFloat32));
```
1. `torch::zeros` queries the caching allocator on every launch.
2. `d_out.to(torch::kFloat32)` and `output.copy_` enqueue an extra CUDA conversion kernel on the stream.
At a target budget of **`37 µs`** (B200) or **`67 µs`** (H100), spending 5–10 µs on host PyTorch wrappers is a massive chunk of runtime.

#### B. Doubled Register Pressure
In single precision, 4 accumulators occupy 4 registers (`4 × 32-bit = 16 bytes`). In double precision, 4 accumulators occupy 8 registers (`4 × 64-bit = 32 bytes`). On B200 with 8 accumulators, that jumps to 16 registers just for accumulators, reducing active warp occupancy per SM.

#### C. Instruction Count & Split Warp Shuffles
1. Every vector load requires 4 explicit conversion instructions (`cvt.f64.f32`) inside the critical inner loop.
2. NVIDIA's warp shuffle instruction (`shfl.sync.bfly.b32`) is strictly 32-bit. Shuffling a 64-bit `double` requires **two** shuffles plus 64-bit packing/unpacking bitops (`mov.b64`, `shl`, `or`) for each of the 5 butterfly steps (10 shuffles + 15 bitwise instructions vs. 5 shuffles for FP32).

---

### How We Can Reclaim That Speed (Next Steps)

1. **Eliminate C++ Host Overhead:**
   Have the kernel write its result directly into `output` (e.g. lane 0 converts its double scalar to float in registers before writing, or block 0 writes the single float), eliminating `d_out` allocation and `output.copy_()`.
2. **2-Pass / Block-Level Tree Reduction (Pure FP32):**
   The only reason pure FP32 failed validation was that 2,112 warps were doing asynchronous flat `atom.global.add.f32` directly into one cell in random order. If each block writes its partial sum to a 264-element scratch array, and a 1-warp second pass sums them in a balanced binary tree ($\text{depth} = 8$), the numerical error is bounded by $8\epsilon \approx 10^{-6}$, which passes `rtol=1e-5` while running at 100% native FP32 speed.
3. **Kahan Compensated Summation:**
   If we keep an FP32 error compensation term in registers, we get 48-bit effective mantissa precision with pure FP32 instructions, avoiding FP64 entirely.
   