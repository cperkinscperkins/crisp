# Overview


Crisp is a Lisp dialect for developing GPU Kernels.

Its guiding idea is *unification*. The concerns that GPU computing normally scatters across a stack of incompatible tools — the kernel logic, automatic differentiation, numerical precision, memory layout and movement, and execution uniformity — all live inside one language, sharing one type system and one static analysis. Because Crisp is a Lisp, there is no wall between "language" and "library": tiles, precision regions, and derivatives are all s-expressions in one substrate, added *as* the language rather than bolted beside it. And because they are facets of a single semantic model rather than separate frameworks, they *compose* — you can differentiate a fast-precision, tiled reduction that calls a foreign function, and the compiler reasons about all of it at once. Where the conventional path glues a kernel language to an autodiff framework to manual half-float casts to hand-rolled shared memory to a separate host program, Crisp treats these as properties the compiler upholds, declared once. That is the sense in which the whole is meant to be greater than the sum of its parts — and this document is the specification of those parts and how they fit together.

Mechanically: the Crisp compiler takes .crisp files and can output SPIR-V, PTX, or a binary for a specific GPU.
The compiler can ALSO output C++ or Python code snippets that can "hoist" that same kernel.
The snippets can be targeted to: OpenCL, LevelZero, or CUDA, as well as whether to use
Unified Memory/USM/SVM.

Someday soon.


