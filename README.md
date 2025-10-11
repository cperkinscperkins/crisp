# Crisp
Crisp - Lisp for developing GPU Kernels

Crisp 🚧
========
A Lisp for High-Performance GPU Kernel Development

### Current Status: Design Phase
Crisp is currently in the design and specification phase. There is no working compiler or code at this time. This repository contains the living design document for the language and its tooling ecosystem. The goal is to create a robust and well-thought-out language before implementation begins.

### The Vision 💡
Crisp is a Lisp dialect designed specifically for writing safe, performant, and correct GPU kernels. The focus is on creating a language that:

- Guarantees Safety: Kernels are guaranteed to terminate, and features like the maybe type make error handling explicit and robust.

- Prioritizes Performance: The language exposes core GPU idioms like shuffles, reductions, and memory layouts as first-class citizens.

- Simplifies the Workflow: A "Kernel-First" approach where the compiler can generate the necessary C++ or Python "hoisting" code to manage and launch the kernels, letting the developer focus on the algorithm.

### The Specification
The complete, in-progress design document can be found in the docs directory.