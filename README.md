# Crisp 🚧

**A new programming language for developing GPGPU kernels**

Crisp is a Lisp for writing GPU kernels.  It is quite different than existing solutions and quite difficult to easily sum up in a paragraph or two. Kernels written in Crisp can be compiled to both PTX and SPIR-V, to support NVidia and Intel hardware. There is no Crisp runtime, instead the Crisp compiler can optionally generate "hoisting" example code. This is .cu / .cpp code that uses CUDA / LevelZero to load, enqueue, and read back results for the specified kernel.

Reading the preceding paragraph you might conclude that portability is a primary goal of Crisp, but that is mistaken. Crisp has several key intersecting goals and their sum is greater than their parts. Here are some of the more unique goals:

- Auto Differentiation.  Crisp can automatically output the backward derivative of a kernel. Simply pass the `--differentiate` flag when compiling to generate the derivative kernel.  
- Explicit hardware profiles for high performance. In addition to the kernel code, the exact profile and capabilities of GPU hardware can be provided to the Crisp compiler for maximum optimization. This aids in MMA shapes, loop unrolling, and countless other optimizations. See `def-hardware-profile` and related.
- Common GPU memes explicitly provided by the Crisp language. Crisp directly exposes several different GPU memes like  grid strides, reductions, and warp specializations as macros that are directly usable. This both reduces errors and helps the compiler maximally optimize the code.
- Meaningful meta declarations. Crisp code can declare certain variables or parameters as tunable, uniform in a workgroup, or constexpr, and more. Additionally kernels and functions can declare their desired enqueue "strategy". All of which serve to not only make the kernel code safe and correct, but also the hoisting example code more useful and, above all, the compilation optimal for performance.
- Template types.  Crisp has C++ like type templating including type functions and constraints (ie C++ "concepts"), as well as advanced derived and branded types that have no comparable in C++.
- Macros.  Crisp gives the user nearly full access to Common Lisp macros in their Crisp code. This is vastly superior to C++ SFINAE both in its power and ease of use. Furthermore, macros mean Crisp developers can write their own GPU memes, strides, reductions, strategies, etc. Crisp has many compile time inspection routines.
- Crisp is not Turing complete.  You read that right. Crisp has no recursion, no unbound loops. This may seem like a liability, but for GPU kernels it simply does not matter. The gains from this decision are considerable: auto-differentiation, guaranteed termination, advanced compile-time analysis like detecting thread hazards and divergence. 

OK, that is getting a little long. I'm trying to summarize Crisp goals, not give a laundry list of every feature (and there are so many more, like quantized types). The point of this list is not that Crisp sports a bunch of things, but rather that it composes them. For example, support for auto-differentiation is only possible because Crisp is not Turing complete and supports advanced type concepts like derived and branded types. Correctness and optimal performance are direct consequences of macro support and hardware profiles. The intersections of these goals is what makes Crisp work.



### Current Status: Active Implementation & E2E Validation

Crisp has moved far beyond the initial design phase. The core architecture—including reverse-mode auto-differentiation, topological machine-aware compilation, and native C API/FFI integration—is implemented and actively undergoing cross-backend validation (CUDA, SPIR-V). This repository contains the living design document for the language and its tooling ecosystem.

[Code Coverage Report](https://cperkinscperkins.github.io/crisp/coverage/)

[Benchmarking Report](./benchmarks/REPORT.md)

### The Specification

The complete, in-progress design document can be found in the docs directory. Each feature is tagged with an emoji indicating its implementation status (✅ Completed, ⚠️ Partially Implemented, 📝 Planned).

[View the Current Specification](./docs/ideal_001.md)

### Just Show Me Some Code!

Maybe reading the spec is a big ask. Understood. Here are two examples of Crisp code, one for Intel hardware, the other for Nvidia. These are real high performance kernels, not "hello world" examples. 

#### Intel MMA

The first is a MMA kernel that is optimized for Intel hardware. For matrices around 1024x1024 or 2048x2048, the code below will compile and execute FASTER than Intel's MKL on a BattleMage GPU.  As the matrix size increases the Crisp advantage will decrease. 

```
;; `bmg` is a Crisp BUILTIN hardware profile 
;;
;; To compile this kernel for a BattleMage GPU:
;; crisp-compile --ir-target=spv --hardware-profile=bmg --math-precision=fast --denormal-handling=ftz matmul_bmg_prefetch.crisp
;; 
;; To generate the LevelZero host harness, pass `--hoist=l0`.
;; crisp-compile --hoist=l0 --hardware-profile=bmg --math-precision=fast --denormal-handling=ftz matmul_bmg_prefetch.crisp
;; The generated C++ code will load the SPIR-V module, manage device memory, and enqueue the kernel.

(def-type a-mat (matrix float :address-space :global :align :compact :contiguous-term :row-major))
(def-type b-mat (matrix float :address-space :global :align :compact :contiguous-term :row-major))
(def-type c-mat (matrix float :address-space :global :align :compact :contiguous-term :row-major))

(def-kernel matmul (A B &out C)
  (declare #'(a-mat b-mat &out c-mat)
           (global-size :derive-from C :strategy :strided)
           (local-size :set-to 16))
  (let ((K      (inner-dimension A B))
        (n-k-steps (/ (inner-dimension A B) 8ul)))

    (tile-stride C (32 32) (grid-y grid-x)
      (let ((A-ring (make-register-tile-ring float (32 8) :ring-count 2 :operand :a))
            (B-ring (make-register-tile-ring float (8 32) :ring-count 2 :operand :b))
            (C-tile (make-register-tile float (32 32) 0.0)))
      
      ;; Prologue
      (prefetch-tile A (grid-y 0) :size (32 8))
      (prefetch-tile B (0 (* grid-x 2ul)) :size (8 16))
      (prefetch-tile B (0 (+ (* grid-x 2ul) 1ul)) :size (8 16))
      (prefetch-tile A (grid-y 1) :size (32 8))
      (prefetch-tile B (1 (* grid-x 2ul)) :size (8 16))
      (prefetch-tile B (1 (+ (* grid-x 2ul) 1ul)) :size (8 16))
      (load-tile A (ring-get A-ring 0) (grid-y 0))
      (load-tile B (ring-get B-ring 0) (0 grid-x))

      (dotimes (grid-k n-k-steps)
        (let ((next-k (+ grid-k 1ul))
              (prefetch-k (+ grid-k 2ul)))
          
          ;; 1. Issue prefetch for future K.
          (when (< prefetch-k n-k-steps)
            (prefetch-tile A (grid-y prefetch-k) :size (32 8))
            (prefetch-tile B (prefetch-k (* grid-x 2ul)) :size (8 16))
            (prefetch-tile B (prefetch-k (+ (* grid-x 2ul) 1ul)) :size (8 16)))

          ;; 2. Issue register load for the NEXT k.
          (when (< next-k n-k-steps)
            (load-tile A (ring-get A-ring (mod (+ grid-k 1ul) 2ul)) (grid-y next-k))
            (load-tile B (ring-get B-ring (mod (+ grid-k 1ul) 2ul)) (next-k grid-x)))

          ;; 3. Compute on the CURRENT k.
          (mma-accumulate-via-tile (8 16 8) C-tile
                                   (ring-get A-ring (mod grid-k 2ul))
                                   (ring-get B-ring (mod grid-k 2ul))))))
      :epilogue
      (store-tile C-tile C (grid-y grid-x))))))

```

#### NVIdia MMA

This second kernel is optimal on NVidia sm_90 hardware. Unlike the Intel one above which uses a prefetch pipeline, this uses warp specialization. This kernel performs well on NVidia hardware but not as well as cuBLAS. Hopefully we'll be matching it soon. 

```
;; To compile this kernel for a Hopper GPU:
;; crisp-compile --ir-target=ptx --ir-target-arch=sm_90 --hardware-profile=h100 --math-precision=fast --denormal-handling=ftz matmul_wgmma.crisp
;; 
;; To generate the CUDA host harness, pass `--hoist=cuda`.
;; crisp-compile --hoist=cuda --ir-target-arch=sm_90 --hardware-profile=h100 --math-precision=fast --denormal-handling=ftz matmul_wgmma.crisp
;; The generated C++ code will load the PTX module, manage device memory, and launch the kernel.

(def-type a-mat (matrix float :address-space :global :align :compact :contiguous-term :row-major))
(def-type b-mat (matrix float :address-space :global :align :compact :contiguous-term :col-major))
(def-type c-mat (matrix float :address-space :global :align :compact :contiguous-term :row-major))

(def-kernel matmul (A B &out C)
  (declare #'(a-mat b-mat &out c-mat)
           (local-size :set-to 160))          ; 4 consumer warps (warpgroup 0) + 1 producer warp
  (let ((A-ring (make-scratch-matrix-ring float (64 32)  :ring-count 2))   ; 2 x 64(M) x 32(K)
        (B-ring (make-scratch-matrix-ring float (256 32) :ring-count 2))   ; 2 x 128(N) x 32(K) B^T
        (D      (make-wgmma-accumulator float (64 256) 0.0))
        (K      (inner-dimension A B))
        (empty  (make-async-barrier-ring :ring-count 2 :mode :block :arrivals 4 :initial-state :signaled))
        (full   (make-async-barrier-ring :ring-count 2 :mode :block :arrivals 2 :initial-state :waiting)))
    (tile-stride C (64 256) (grid-y grid-x)
      (with-warp-specialization (:consumer 4 :producer 1)
        (:consumer
          (set! D (make-wgmma-accumulator float (64 256) 0.0))
          (dotimes (grid-k (/ (to-ulong K) 32ul))
            (let ((slot (mod grid-k 2ul)))
              (await (ring-get full slot))
              (wgmma-accumulate-via-tile (64 256 32) D (ring-get A-ring slot) (ring-get B-ring slot)
                                         :swizzle :128b)
              (signal (ring-get empty slot))))
          (store-tile D C (grid-y grid-x)))
        (:producer
          (dotimes (grid-k (/ (to-ulong K) 32ul))
            (let ((slot (mod grid-k 2ul)))
              (await (ring-get empty slot))
              (load-tile A (ring-get A-ring slot) (grid-y grid-k) :barrier (ring-get full slot) :swizzle :128b)
              (load-tile B (ring-get B-ring slot) (grid-x grid-k) :barrier (ring-get full slot) :swizzle :128b))))))))

```


## Author

Designed by **Chris Perkins**.

## Development

Implementation assisted by Claude Code and Google AntiGravity.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Third-Party Tools

* `llc`: LLVM compiler (Apache 2.0 with LLVM exceptions)
* License: See LICENSE-llc.txt
* Source: [https://github.com/llvm/llvm-project](https://github.com/llvm/llvm-project)


* `llvm-spirv`: LLVM SPIRV Translator
* License: See LICENSE-llvm-spirv.txt
* Source: [https://github.com/KhronosGroup/SPIRV-LLVM-Translator/blob/main/LICENSE.TXT](https://github.com/KhronosGroup/SPIRV-LLVM-Translator/blob/main/LICENSE.TXT)



