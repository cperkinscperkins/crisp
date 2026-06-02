# Major Features of the Crisp language and tools


- Distinct Execution Contexts:  A formal context system (thread, grid, dispatch) separates sequential per-thread code from parallel grid-level operations.  This makes a whole class of subtle but catastrophic parallel programming bugs (like nesting grid-level operations) impossible to write by turning them into clear, compile-time errors.

- Explicit Output Parameters:  The `&out` modifier explicitly marks output-only parameters in function signatures.  This creates a clear, compiler-enforced contract that prevents race conditions and bugs caused by reading from uninitialized or partially-written output buffers.

- Guaranteed Termination:  Crisp is intentionally not Turing-complete (no unbounded recursion or loops).  This provides a mathematical guarantee that kernels will always finish, preventing GPU hangs. It also unlocks a suite of powerful static analysis tools that are impossible in general-purpose languages, and is key to supporting auto differentiable kernels

- First-Class GPU Primitives:  Common but complex GPU patterns like grid-strides, warp shuffles, and parallel reductions are provided as high-level, built-in language constructs.  This allows developers to write powerful, performant code that is both readable and correct, without having to reinvent these difficult algorithms from scratch.

- Automated Scratch Memory:  High-level primitives (like reductions and sorts) can automatically manage their own temporary local and global memory via a "side-channel" mechanism.  This eliminates tedious and error-prone manual buffer allocation and management.

- Flexible Data Layouts:  Crisp provides distinct types and specialized accessors for both "Array of Structs" (`vector`) and "Struct of Arrays" (`soa-vector`).  This gives developers the tools to choose the most performant memory layout for their algorithm without sacrificing type safety or readability.

- Optimized Memory Access: Crisp provides explicit control over data layouts (`:aos`, `:soa`, `:compact`, `:strided`) and GPU-native iteration patterns (`loop-vector-stride`, `load-tile`). These features are designed to enable and encourage coalesced memory access, allowing kernels to achieve maximum memory bandwidth, a key factor for high performance on GPUs. The opt-in `check-coalesce` static analysis further helps developers verify these critical access patterns.

- Compile-Time Verification:  Special variants of control-flow forms (`if*`, `dotimes+`) and declarations (`uniform`, `constexpr`) allow programmers to assert their performance expectations.  The compiler verifies these assertions, catching unintended performance bugs (like warp divergence or non-constant loop bounds) at compile time.

- Strict Memory Layout Standard:  All Crisp structs adhere to a strict "scalar" memory layout standard.  This guarantees a predictable and performant memory layout, ensuring seamless and correct data interoperability between the host (C++/Python) and the device.

- Pragmatic Error Handling:  A simple maybe type is integrated into the language.  This provides a lightweight, compiler-assisted mechanism for handling potential failures in a way that minimizes control-flow divergence, a major performance killer on GPUs.

- Powerful Metaprogramming:  A Lisp-based syntax with defmacro and a rich templating system (`with-template-type`).  Developers can extend the language with new abstractions, control structures, and code generators, creating domain-specific solutions that are clean and expressive.

- Static Typing with Powerful Generics: Crisp is statically typed with a robust templating system and compile-time type constraints. This provides the compile-time safety and performance benefits typical of C++, preventing runtime type errors, while offering a level of generic programming and code generation via metaprogramming that surpasses traditional C++ templates and is absent in dynamic languages like Python or Common Lisp.

- Unified Quantized Math: Crisp provides first-class support for the entire spectrum of modern, high-performance numeric types. This includes both quantized integers (like `qint8`) and low-precision "microfloats" (like `fp8-e4m3`). The type system ensures mathematical safety by enforcing nominal "branded" types preventing you from mixing incompatible formats. It also enforces overflow-safe math, providing a direct, unified, and safe path to the massive performance gains of specialized AI hardware (like Tensor Cores) for both integer and floating-point acceleration. 

- Automated Hoisting Code:  The Crisp compiler can optionally generate a complete, runnable `main()` function in C++ or Python.  This automates the tedious and error-prone task of writing host-side launch code, providing an instant, working "blueprint" that demonstrates how to allocate memory, set arguments, and correctly launch a kernel.

- Opt-In Static Analysis:  The compiler includes a suite of advanced, opt-in checks.  This allows the compiler to act as an expert performance coach, automatically detecting subtle but critical issues like memory-coalescing failures, shared memory bank conflicts, and potential barrier deadlocks.

- In-Memory Compilation API:  Crisp is designed as a compiler library with a C/Python API.  This enables fast, in-memory JIT compilation, allowing applications to dynamically generate and run new kernels on the fly without disk I/O.

- Auto-Differentiation for GPU Kernels: The `--differentiate` compiler flag automatically generates high-performance reverse-mode gradient kernels from your forward code.  Write your math once. Crisp handles the calculus, generating the "backward pass" for you. Whether you're training neural networks, optimizing physical simulations, or performing sensitivity analysis, you can focus on the model and let the compiler worry about the derivatives. No manual backprop, no "calculus bugs," and no need to wrap your kernels in a heavy external framework.



