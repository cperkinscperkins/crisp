Crisp 🚧
========
A Lisp for High-Performance GPU Kernel Development

### Current Status: Design Phase
Crisp is currently in the early implementation phase. As the implementation moves forward, it informs and refines the design.  This repository contains the living design document for the language and its tooling ecosystem. 

[Code Coverage Report](https://cperkinscperkins.github.io/crisp/coverage/)


### The Vision 💡
Crisp is a Lisp dialect designed specifically for writing safe, performant, and correct GPU kernels. The focus is on creating a language that:

- Prioritizes Performance: The language exposes core GPU idioms like shuffles, reductions, gride strides, and memory layouts as first-class citizens.

- Clarity and Debugging: Kernels are guaranteed to terminate, supports a maybe type make error handling explicit and robust, has optional debug logging that can elected by recompiling.

- Simplifies the Workflow: A "Kernel-First" approach where the compiler can generate the necessary C++ or Python "hoisting" code to manage and launch the kernels, letting the developer focus on the algorithm.

### The Specification
The complete, in-progress design document can be found in the docs directory. Each feature is tagged with an emoji indicating its implementation status (✅ Completed, ⚠️ Partially Implemented, 📝 Planned).

[View the Current Specification](./docs/ideal_001.md)

## Author

Designed and implemented by *Chris Perkins*.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.


## Third-Party Tools

- `llc`: LLVM compiler (Apache 2.0 with LLVM exceptions)
  - License: See LICENSE-llc.txt
  - Source: https://github.com/llvm/llvm-project

- `llvm-spirv`: LLVM SPIRV Translator
  - License: See LICENSE-llvm-spirv.txt
  - Source: https://github.com/KhronosGroup/SPIRV-LLVM-Translator/blob/main/LICENSE.TXT