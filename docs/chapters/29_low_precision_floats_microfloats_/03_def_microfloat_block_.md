# def-microfloat-block ✅


The types above can then be used in `def-microfloat-block`.  Note that blocks can have 1D or 2D arity.

```
(def-microfloat-block mf-celcius :base fp4 :accum fp32 :scale fp8-e4m3 :shape (16))
(def-microfloat-block mf-weights :base fp4 :accum fp32 :scale fp8-e4m3 :shape (4 4))
```

And just like with the quantized types, different block types cannot be intermixed,
even if they are configured with identical parameters. However, if you absolutely must intermix them,
you can do so by using `set-derived`.   

`def-microfloat-block` with `mf-celcius` like above would result in
```
(def-type mf-celsius-base fp4)
(def-type mf-celcius-accum fp32)
(def-type mf-celsius-scale fp8-e4m3)

(def-struct mf-celcius 
  (scale mf-celsius-scale)
  #| the 16 fp4 elements |#) ;; these are not strided tensors or anything. 

;; accum and base are defined for ALL numeric types.
(def-type-function accum (T:mf-celcius) mf-celcius-accum)
(def-type-function base (T:mf-celcius) mf-celcius-base)
;; but scale is only defined for microfloat blocks
(def-type-function scale (T:mf-celcius) mf-celcius-scale)
```

<!--
REMOVE
For each invocation of `def-microfloat-block` Crisp will define the type identifiers
 `XXXX-base`, `XXXX-accum` and `XXXX-scale` as well as compile-time type functions
 `scale`, `count`, and `shape` . `num-rows` and `num-cols` are defined for the 2D variant.
-->


 Additionally,  `quantize-to-XXXX` and `dequantize-from-XXXX` functions
 are defined. These functions operate on vectors of floats and blocks. Read more below

#### Illegal Combinations and Target-Specific Behavior

The entire purpose of Crisp's microfloat types is to leverage the extreme performance of specialized hardware. 
This means the compiler's behavior is strict and depends heavily on your chosen output target.

1. When Compiling (to LLVM IR, SPIR-V, or PTX)

This path is optimized for maximum performance. The compiler acts as a strict gatekeeper 
and knows which combinations (e.g., :base fp8-e4m3, :accum fp32) are supported by hardware intrinsics.

- Supported Combinations: The compiler generates the correct high-performance intrinsic (e.g., `OpFMulAdd` in SPIR-V or `mma.sync` in PTX).
- Unsupported Combinations: If you define a type the hardware doesn't support (e.g., `:base fp16, :accum fp16`), the compiler will emit a compile-time error.
- No Emulation: The compiler will not silently generate a slow "emulation" path. This is a core design choice: it is better to give you a compile-time error than to let you ship a kernel that is 100x slower than you intended.

This strictness also applies to portability. A SPIR-V module compiled for 
one hardware target (e.g., OCP MX) is not portable to another (e.g., NVIDIA). 
The driver will reject the kernel, resulting in a fatal load-time error.

2. When Transpiling (to OpenCL C)

This path is optimized for maximum portability and debugging, not performance. The transpiler has no way to guarantee that specific hardware intrinsics are available.

- Therefore, in this mode, the "unsupported combination" rules are relaxed.
- Crisp will generate a slow, emulated for loop to perform the operation.
- This ensures the transpiled C code is portable and works, but it will have severely suboptimal performance as it will not use Tensor Cores or other hardware accelerators.



