## `--differentiate`


The `--differentiate` flag enables the Crisp Automatic Differentiation (AD) engine. When this flag is active, the compiler performs a reverse-mode transformation on compatible GPU kernels, generating a corresponding gradient kernel (the "adjoint") for every forward kernel defined in the source.



### Requirements for Differentiable Kernels

To be compatible with `--differentiate`, a kernel must meet the following criteria:

- Explicit Output (`&out`): A differentiable kernel must have at least one `&out` parameter. This parameter represents the "primal" result of the calculation.
- No Recursion: As with all Crisp kernels, recursion is disallowed, which ensures a statically determinable execution graph for the backward pass.
- Opt-out via `forward-only`: If a kernel performs non-differentiable side effects (like logging or specific data-shuffling), it should be marked with `(declare forward-only)`. The compiler will skip gradient generation for these kernels.

### The Generated Gradient Signature

For a forward kernel with the signature `(A B &out C D)`, the compiler generates a gradient kernel with an expanded signature to accommodate the necessary data for the backward pass:

```
;; Forward: (A B &out C D)
;; Generated Backward:
(def-kernel foo_grad (A B C D C_grad D_grad &out A_grad B_grad) ...)

```

- Primals ($A, B, C, D$): The original inputs and outputs are provided so the backward pass can use them to calculate local derivatives (e.g., $x$ is needed to find the derivative of $x^2$).
- Incoming Adjoints ($C\_grad, D\_grad$): These are the "seeds" or loss gradients flowing back from the rest of the program.
- Outgoing Adjoints ($A\_grad, B\_grad$): These are the calculated gradients for the original inputs, which the compiler populates using the chain rule.

### Memory Safety and Accumulation

Because multiple threads may contribute to the gradient of a single input element (a common occurrence in "scatter" operations), the generated gradient kernel defaults to using Atomic Operations for all writes to `&out` gradient handles. This ensures mathematical correctness even in complex, non-injective mappings.

However, if the kernel strategy is declared as `one-thread-per-element`, then the generated gradient kernel will use `set!` instead of atomic operations.


### Implementation Note for the User

The `--differentiate` flag significantly increases the complexity of the generated SPIR-V, as it effectively doubles the logic and may increase register pressure to store intermediate "primal" values. Use the `check-registers` and `check-divergence` flags in conjunction with `--differentiate` to ensure your adjoint kernels remain performant on your target hardware.





