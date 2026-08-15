# Adversarial Testing Issues

This file tracks bugs and edge-case failures discovered by the adversarial testing suite.

When an issue is added here, the corresponding adversarial test should be tagged with `;; KNOWN-ISSUE: <ID>`. The spec runner will intercept failures for this test and mark them as `KNOWN-FAIL` (allowing CI to pass). If the test unexpectedly passes, it will mark it as `UNEXPECTED-PASS` (failing the CI), which indicates the bug was fixed and this issue can be closed.

## Active Issues

### ADV-001: Auto-diff x_adj shadowing
**Discovered in:** `tests/adversarial/nested-let-conversions/01-shadowing-type-promotions.crisp`
**Description:** When lexical variable names are shadowed (e.g., an inner `let` defines an `x` that shadows an outer `x`), the generated backward pass incorrectly accumulates their adjoints into a single shared `x_adj` accumulator variable, rather than generating separate adjoints for the separate lexical scopes. This results in mathematically incorrect analytical gradients (e.g., computing `6.0` instead of `4.0` due to cross-accumulation).
