# Crisp 🚧

A Lisp for High-Performance GPU Kernel Development

### Current Status: Design Phase
Crisp is currently in the early implementation phase. As the implementation moves forward, it informs and refines the design. This documentation site contains the living design document for the language and its tooling ecosystem. 

### The Vision 💡
Crisp is a Lisp dialect designed specifically for writing safe, performant, and correct GPU kernels. The focus is on creating a language that:

* **Prioritizes Performance**: The language exposes core GPU idioms like shuffles, reductions, grid strides, and memory layouts as first-class citizens.
* **Clarity and Debugging**: Kernels are guaranteed to terminate, supports a `maybe` type to make error handling explicit and robust, and features optional debug logging that can be elected by recompiling.
* **Simplifies the Workflow**: A "Kernel-First" approach where the compiler can generate the necessary C++ or Python "hoisting" code to manage and launch the kernels, letting the developer focus on the algorithm.

### The Specification
The complete, in-progress design document details the syntax, memory models, compiler APIs, and hardware acceleration mappings. Each feature is tagged with an emoji indicating its implementation status (✅ Completed, ⚠️ Partially Implemented, 📝 Planned).

👉 **[View the Language Specification](ideal_001.md)**
