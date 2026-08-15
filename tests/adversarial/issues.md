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
