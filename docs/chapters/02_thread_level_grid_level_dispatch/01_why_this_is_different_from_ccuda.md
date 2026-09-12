# Why This is Different from C++/CUDA


In C++/CUDA, there is no formal distinction between a "dress pattern" and an "assembly line blueprint". A programmer can accidentally write code that has a single thread try to launch a new, grid-wide operation. The C++ compiler won't prevent this. This code compiles but results in a silent, catastrophic bug: either the logic is fundamentally incorrect, or the performance is thousands of times slower than expected. The developer is left to debug a complex runtime issue with no help from the compiler.

Crisp's context system provides guardrails. By separating `def-function` and `def-grid-function`, the compiler understands the intent of your code. If you try to call a grid-level function from a thread-level context, you get an immediate, clear compile-time error, not a mysterious runtime bug.

In short, this system provides:

 - Safety: It makes a whole class of parallel programming errors impossible to write.
 - Clarity: It makes the code self-documenting. A `def-grid-function` is unambiguously a parallel operation.
 - Readability: It separates the high-level orchestration of a kernel from the low-level, per-thread implementation details, making complex algorithms easier to reason about.


