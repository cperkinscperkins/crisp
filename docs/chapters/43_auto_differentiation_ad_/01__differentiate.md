# `--differentiate`


The `--differentiate` flag enables the Crisp Automatic Differentiation (AD) engine. When this flag is active, the compiler performs a reverse-mode transformation on compatible GPU kernels, generating a corresponding gradient kernel (the "adjoint") for every forward kernel defined in the source.



### Requirements for Differentiable Kernels

To be compatible with `--differentiate`, a kernel must meet the following criteria:

- Explicit Output (`&out`): A differentiable kernel must have at least one `&out` parameter. This parameter represents the "primal" result of the calculation.
- No Recursion: As with all Crisp kernels, recursion is disallowed, which ensures a statically determinable execution graph for the backward pass.
- Opt-out via `forward-only`: If a kernel performs non-differentiable side effects (like logging or specific data-shuffling), it should be marked with `(declare forward-only)`. The compiler will skip gradient generation for these kernels.
- Input Types: Float, double, and integer scalars are all differentiable inputs.
  Integer inputs receive *promoted* adjoints (small ints → `float`, `long`/`ulong` →
  `double`) since gradients are inherently continuous. A kernel whose inputs are
  *exclusively* non-differentiable (e.g. all `ulong` indices with no float math)
  receives a trivial backward — the gradient kernel is still emitted but contains
  no chain-rule computation.
- Composite Inputs: Records, structs (including nested), tensors, and cells are
  all supported at the kernel boundary. See "Generated Gradient Signature" below
  for how each is paired with its adjoint.


### The Generated Gradient Signature

The backward kernel's signature mirrors the forward kernel's, with each
differentiable parameter paired to a corresponding adjoint. The shape of that
pairing depends on the parameter's type.

#### Scalar primals

For a forward kernel with scalar inputs and outputs:

```
;; Forward:
(def-kernel foo (A B &out C D) ...)
;; Generated Backward:
(def-kernel foo_grad (A B C D C_grad D_grad &out A_grad B_grad) ...)
```

- Primals (A, B, C, D): The original inputs and outputs are provided so the
  backward pass can use them to compute local derivatives.
- Incoming adjoints (C_grad, D_grad): The seed gradients flowing back from
  downstream. Carry the *promoted* type of their primal.
- Outgoing adjoints (A_grad, B_grad): The computed input gradients,
  populated via the chain rule.

#### Records at the kernel boundary

A record parameter is destructured into one `&out` grad-cell per leaf field.
Nested records recurse field-by-field. Given:

```
(def-record Point ((x float) (y float)))
(def-kernel foo (P &out C) ...)
```

the generated backward exposes one grad-cell per primitive leaf:

```
(def-kernel foo_grad (P C C_grad &out P.x_grad P.y_grad) ...)
```

#### Structs at the kernel boundary (Shadow Structs)

Unlike records, structs are *not* destructured — they cross the boundary as a
single value. To carry their gradient, the compiler auto-mints a paired
**shadow struct** for every `def-struct NAME`: a parallel struct named
`NAME_ADJ` with each field replaced by its promoted adjoint type. Nested
structs recursively reference the inner struct's shadow.

Given:

```
(def-struct Point ((x int) (y float)))     ;; auto-mints Point_ADJ with
                                            ;; (x float) (y float)
(def-kernel foo (P &out C) ...)
```

the backward kernel carries a single `&out` cell of the shadow type:

```
(def-kernel foo_grad (P C C_grad &out P_adj) ...)
```

where `P_adj` is `(cell Point_ADJ :address-space :global)`. The backward
walk writes per-field adjoints into the shadow's fields, then a final
`set!` lands the assembled shadow.

#### Tensors and cells at the kernel boundary

Tensor and cell primals are paired by a same-shape grad-handle whose element
type is the promoted adjoint type. Accumulation into indexed slots uses
atomic-add by default (or `set!` under `one-thread-per-element`).


### Memory Safety and Accumulation

Because multiple threads may contribute to the gradient of a single input element (a common occurrence in "scatter" operations), the generated gradient kernel defaults to using Atomic Operations for all writes to `&out` gradient handles. This ensures mathematical correctness even in complex, non-injective mappings.

However, if the kernel strategy is declared as `one-thread-per-element`, then the generated gradient kernel will use `set!` instead of atomic operations.

### Sub-Function Differentiation

`def-function`s called from a differentiable kernel are themselves
differentiated. Each receives a `_GRAD` companion whose signature uses a
**mixed convention**:

- Scalar contributions return through Crisp's multi-value return — the
  `_GRAD` function's primary return is the original return value, with
  per-scalar-input gradients trailing.
- Handle contributions (tensors, cells) are passed as additional `&out`
  grad-handles, since their gradient lands by atomic accumulation at indexed
  slots rather than by value.
- Record and struct sub-function arguments use the same conventions as at
  the kernel boundary (per-field grad cells for records, shadow-struct
  cells for structs).

This mixed convention lets the backward pass thread gradients through
helper functions without forcing tensor-shaped gradients onto the
multi-value return path.



### Implementation Note for the User

The `--differentiate` flag significantly increases the complexity of the generated SPIR-V, as it effectively doubles the logic and may increase register pressure to store intermediate "primal" values. Use the `check-registers` and `check-divergence` flags in conjunction with `--differentiate` to ensure your adjoint kernels remain performant on your target hardware.

### Output File Naming

When using the `--differentiate` flag, the compiler will append `_grad` to the output filename. For example, if compiling `my-kernel.crisp` with `--differentiate` and the `--ir-target=spv` flag, the output file will be named `my-kernel_grad.spv`.





