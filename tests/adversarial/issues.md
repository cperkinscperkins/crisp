# Adversarial Testing Issues

This file tracks bugs and edge-case failures discovered by the adversarial testing suite.

When an issue is added here, the corresponding adversarial test should be tagged with `;; KNOWN-ISSUE: <ID>`. The spec runner will intercept failures for this test and mark them as `KNOWN-FAIL` (allowing CI to pass). If the test unexpectedly passes, it will mark it as `UNEXPECTED-PASS` (failing the CI), which indicates the bug was fixed and this issue can be closed.

## Active Issues

### ADV-001: Shadowed Type Promotions (Nested Lets)
* **Location:** `tests/adversarial/nested-let-conversions/01-shadowing-type-promotions.crisp`
* **Description:** Auto-diff fails when variables are shadowed in nested `let` forms. The adjoint routing gets confused and emits incorrect gradients (e.g., AD returns 4.0 instead of 6.0). 
* **Scope:** `[verify-autodiff]`

### ADV-002: Shadowed Variables in Phi Nodes (Branching)
* **Location:** `tests/adversarial/branching-phi-shadowing/01-shadowed-phi-node.crisp`
* **Description:** Auto-diff completely loses the adjoint (returns 0.0 instead of 4.0) when a variable is shadowed inside a branch and then returned via a phi node.
* **Scope:** `[verify-autodiff]`

### ADV-003: Differentiating Templates with Multiple-Value-Bind
* **Location:** `tests/adversarial/nested-template-mvb/01-template-mvb.crisp`
* **Description:** The differentiation pass crashes with "Function MY-OUTER-TEMP is not differentiable" when a template function internally uses `let` for multiple-value binding from another template.
* **Scope:** `[differentiate]`

### ADV-004: Differentiating Data-Dependent Template Branches
* **Location:** `tests/adversarial/template-branching-autodiff/01-differentiate-template-branches.crisp`
* **Description:** The compiler fails to differentiate a template function instantiated inside a data-dependent branch. It crashes with "Function MY-TEMP-CALC is not differentiable" and a type mismatch.
* **Scope:** `[differentiate]`

### ADV-005: Template Type Inference on Enum Values
* **Location:** `tests/adversarial/enum-template-instantiation/01-enum-template.crisp`
* **Description:** When an enum value (like `:forward`) is passed to a template function, the type inference engine incorrectly infers its type as `(KEYWORD :FORWARD)` instead of the enum type. This crashes the template instantiator with "Unknown type".
* **Scope:** none (fails on all passes)

### ADV-006: Compile-Time Output of Template Variables
* **Location:** `tests/adversarial/c-t-output-polymorphic/01-poly-c-t-output.crisp`
* **Description:** Embedding `c-t-output` inside a template function crashes the compiler. The macro tries to `EVAL` the template variable at compile-time, throwing an "unbound variable" error.
* **Scope:** none (fails on all passes)

### ADV-007: Auto-Diff Branching with Enums
* **Location:** `tests/adversarial/enum-branching-autodiff/01-enum-branching.crisp`
* **Description:** The auto-diff engine crashes when a branch depends on an enum. It first fails because `EQ` is not considered differentiable. Then it fails because `IF` cannot unify the keyword branches to the enum type.
* **Scope:** none (fails on all passes)

### ADV-008: Kernel-Boundary Struct Mutation Loophole
* **Location:** `tests/adversarial/struct-mutation-loophole/01-struct-mutation.crisp`
* **Description:** The compiler fails to correctly track struct mutability when a `def-struct` passed directly at the kernel boundary is passed to a sub-function that mutates it.
* **Scope:** none (fails on all passes)

### ADV-009: Poor Error Reporting for Illegal Recursive/Forward Types
* **Location:** `tests/adversarial/struct-self-reference/01-struct-self-ref.crisp`
* **Description:** Crisp intentionally does not support recursive types, containers, or forward declarations. However, the compiler fails to elegantly catch and report this violation. Instead of emitting a clear user-facing error about illegal recursive types, it crashes or throws a generic unknown type error.
* **Scope:** none (fails on all passes)

### ADV-010: Struct Accessors as Higher-Order Functions
* **Location:** `tests/adversarial/struct-accessor-hof/01-struct-hof.crisp`
* **Description:** The compiler crashes when attempting to pass a struct accessor (e.g. `#'x~`) as a higher-order function. Struct accessors are not properly registered as functions for template monomorphization.
* **Scope:** none (fails on all passes)

### ADV-011: Macro-Generated Template Autodiff Loophole
* **Location:** `tests/adversarial/macro-local-template/011-macro-template.crisp`
* **Description:** The autodiff engine fails to differentiate templates that are generated via top-level macro expansion. Because AD runs before or independently of full macro expansion, it considers the macro-generated template function invisible/non-differentiable.
* **Scope:** `[differentiate]`

### ADV-012: Compile-Time Property Overload Resolution Failure
* **Location:** `tests/adversarial/overload-c-t-property/012-c-t-overload.crisp`
* **Description:** The compiler strips `:c-t` compile-time properties during the overload resolution phase. Therefore, it is impossible to overload a function based on different `:c-t` property constraints (e.g., `(:mode :fast)` vs `(:mode :safe)`), resulting in an ambiguous or non-matching overload error.
* **Scope:** none (fails on all passes)

### ADV-013: Phi-Node Compile-Time Property Stripping
* **Location:** `tests/adversarial/phi-node-c-t-unification/013-phi-unification.crisp`
* **Description:** A major loophole allows converting complete types into incomplete types at runtime via `IF` branching (phi-nodes). When a true branch produces `(config-rec :mode :fast)` and a false branch produces `(config-rec :mode :slow)`, the phi-node unifies them by simply stripping the `:c-t` property, returning an incomplete type. If this incomplete type is then passed to a helper that enforces a specific `:c-t` property, it crashes the compiler. This circumvents the static safety of complete types.
* **Scope:** none (fails on all passes)

### ADV-014: Cell of Incomplete Type Loophole
* **Location:** `tests/adversarial/cell-incomplete-type/014-cell-incomplete.crisp`
* **Description:** The compiler successfully compiles a kernel that takes a `cell` whose element type is incomplete (e.g., missing required `:c-t` properties). The type checker should enforce that `cell` element types are complete at the kernel boundary (since pointer arithmetic requires size/layout), but it erroneously permits them, leading to undefined runtime behavior.
* **Scope:** none (fails on all passes)

### ADV-015: Nested Cell Type Parsing Failure
* **Location:** `tests/adversarial/cell-nested/015-cell-nested.crisp`
* **Description:** The type-specifier parser for `def-type` crashes when attempting to parse a nested `cell` declaration like `(cell (cell float :address-space :global) :address-space :global)`. The macro expander mangles the nested keyword arguments (stripping the keyword colon or the value itself), leading to a `Missing value for :ADDRESS-SPACE` compilation error.
* **Scope:** none (fails on all passes)

### ADV-016: Autodiff Over Advanced Signatures
* **Location:** `tests/adversarial/autodiff-advanced-signatures/016-autodiff-optional.crisp`
* **Description:** The differentiation engine crashes with an "Unsupported form" error when attempting to differentiate functions that use advanced signatures like `&optional` (and likely `&key`). The engine fails to handle the `is-set?` special form or the optional parameters themselves, blocking differentiation. Additionally, this seems to cause a memory corruption segfault in SBCL during teardown.
* **Scope:** differentiate

### ADV-017: Autodiff Over Scratch Cells
* **Location:** `tests/adversarial/autodiff-scratch-cell/017-autodiff-scratch.crisp` and `tests/adversarial/scratch-cell-template/017-scratch-template.crisp`
* **Description:** The differentiation engine throws a "Function is not differentiable" error when encountering functions that allocate scratch cells via `make-scratch-cell`. This indicates that implicit `scratch-cell` allocation (and SROA) is completely unsupported during backward passes. Like ADV-016, this also appears to trigger an SBCL memory corruption fault at shutdown.
* **Scope:** differentiate

### ADV-018: Def-Type Struct Alias Accessor Failure
* **Location:** `tests/adversarial/def-type-struct-props/018-def-type-props.crisp`
* **Description:** When using `def-type` to alias a `def-struct` (e.g., locking in a compile-time property like `(def-type fast-cfg (my-cfg :exec :fast))`), the struct accessor macros (like `val~`) fail with `Unknown struct type FAST-CFG in extraction.` This means struct accessors do not resolve `def-type` aliases before type-checking, breaking struct field access on aliased types.
* **Scope:** none (fails on all passes)

### ADV-019: Exact Kernel Name Collision Loophole
* **Location:** `tests/adversarial/k-exact-collision/020-collision.crisp`
* **Description:** The `gen-XXXX` form for `def-kernel-exact` requires an explicit C-style string for the emitted kernel name. However, the compiler frontend completely fails to validate the uniqueness of these names. If two different templates generate kernels with the same exact string name (e.g., `"my_colliding_kernel"`), the compiler silently emits both into the same IR module, which will cause linker or backend compiler failures later in the pipeline.
* **Scope:** none (fails on all passes)

### ADV-020: Marshall Cell Accepts Incomplete Types
* **Location:** `tests/adversarial/k-exact-marshall-incomplete/020-marshall-incomplete.crisp`
* **Description:** The `marshall-cell` routine is documented to require a fully complete cell type expression. However, the type-checker fails to validate this when a cell type alias (`def-type out-c (cell my-cfg :address-space :global)`) wraps an incomplete struct (`my-cfg` missing its compile-time properties). The kernel compiles without error, bypassing layout safety checks and injecting an incomplete type into the exact kernel boundary.
* **Scope:** none (fails on all passes)

### ADV-021: Voidp Type Escapes Kernel Constraints
* **Location:** `tests/adversarial/k-exact-voidp-escape/020-voidp-escape.crisp`
* **Description:** The `voidp` type is explicitly documented to be valid *only* in the context of `def-kernel-exact`. However, the type-checker entirely fails to enforce this constraint. It is possible to successfully declare and compile standard `def-function` signatures that accept and return `voidp`. The `voidp` type leaks out of the exact kernel layer and pollutes the general language type system.
* **Scope:** none (fails on all passes)
