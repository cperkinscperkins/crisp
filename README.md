# Crisp 🚧

**A strictly evaluated, hardware-aware GPGPU compiler that eliminates the performance compromise.**

Crisp is a Lisp for writing GPU kernels, compiling one source to both NVIDIA (PTX) and Intel (SPIR-V) hardware. Portability isn't the point, though — and neither is any single feature. The point is *unification*: the concerns that GPU computing normally scatters across a stack of incompatible tools — the kernel logic, automatic differentiation, numerical precision, memory layout and movement, and execution uniformity — all live inside one language, sharing one type system and one static analysis. Because it's a Lisp, there's no wall between "language" and "library": tiles, precision regions, and derivatives are all s-expressions in one substrate, added *as* the language rather than bolted beside it.

That's what makes the whole greater than the sum of its parts. Because differentiation, precision, tiling, and uniformity aren't separate frameworks but facets of a single semantic model, **they compose** — you can differentiate a fast-precision, tiled reduction that calls a foreign function, and the compiler reasons about all of it at once. The conventional path would have you glue a kernel language to an autodiff framework to manual half-float casts to hand-rolled shared memory to a separate host program, and hope the seams hold. Crisp's bet is that these should be *properties the compiler upholds*, declared once — not idioms you re-implement across a toolchain and hope you got right.

### Current Status: Active Implementation & E2E Validation

Crisp has moved far beyond the initial design phase. The core architecture—including reverse-mode auto-differentiation, topological machine-aware compilation, and native C API/FFI integration—is implemented and actively undergoing cross-backend validation (CUDA, SPIR-V). This repository contains the living design document for the language and its tooling ecosystem.

[Code Coverage Report](https://cperkinscperkins.github.io/crisp/coverage/)

### The Vision: Eliminating the GPGPU Compromise 💡

Historically, GPU programming forces a trade-off: you either write highly abstracted code that sacrifices performance, or you write rigid, low-level kernels that are dangerous and difficult to maintain. Crisp breaks this cycle.

By treating the GPU as a fully integrated compute target rather than an isolated black box, Crisp separates the mathematics from the mechanics.

* **Uncompromised Expressiveness:** Write algorithms in their purest mathematical form. Crisp's macro system, dominant/recessive type system, and scoped precision controls allow you to express complex logic natively. You focus purely on the math; Crisp engineers the silicon.
* **Absolute Analytical Certainty:** By deliberately rejecting Turing completeness, Crisp turns runtime footguns into strict compile-time errors. It guarantees kernel termination and features a mathematically provable, built-in reverse-mode auto-differentiation engine.
* **Hardware-Aware Execution:** The compiler absorbs the structural plumbing. Crisp deeply understands hardware topology (`def-hardware-profile`). It automatically handles Scalar Replacement of Aggregates (SROA), maps implicit memory allocations, unrolls loops to fit exact register limits, and generates the necessary C++ or Python host-side boilerplate.
* **Transparent Observability:** High-performance partitioned debug logging allows you to inspect the exact state of your data across thousands of threads without mutating the silicon's execution characteristics or causing Heisenbugs.

### The Specification

The complete, in-progress design document can be found in the docs directory. Each feature is tagged with an emoji indicating its implementation status (✅ Completed, ⚠️ Partially Implemented, 📝 Planned).

[View the Current Specification](./docs/ideal_001.md)

## Author

Designed and implemented by **Chris Perkins**.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Third-Party Tools

* `llc`: LLVM compiler (Apache 2.0 with LLVM exceptions)
* License: See LICENSE-llc.txt
* Source: [https://github.com/llvm/llvm-project](https://github.com/llvm/llvm-project)


* `llvm-spirv`: LLVM SPIRV Translator
* License: See LICENSE-llvm-spirv.txt
* Source: [https://github.com/KhronosGroup/SPIRV-LLVM-Translator/blob/main/LICENSE.TXT](https://github.com/KhronosGroup/SPIRV-LLVM-Translator/blob/main/LICENSE.TXT)



