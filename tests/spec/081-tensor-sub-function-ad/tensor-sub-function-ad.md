# Plan: Tensor Sub-Function Autodiff (Feature 081)

## Overview

This feature combines two already-implemented sub-systems:
- **Feature 080** — tensor/vector/matrix gradient machinery (indexed reads/writes in backward kernel)
- **Feature 052** — sub-function AD (generating `_GRAD` companions, calling them in backward walk)

The primary goal is to verify that those two compose correctly: a kernel that reads scalar
elements from tensors, passes them to a `def-function`, and writes results back to a tensor
output should produce a correct backward kernel that calls the sub-function's `_GRAD`
companion and accumulates gradients element-wise into the tensor gradient params.

One small piece of new work is also captured here: an explicit error when `--differentiate`
is used on a kernel that has **no differentiable parameters** (e.g., all inputs are integer
tensors).

---

## Key Insight: How the Combination Works

For a kernel like:
```crisp
(def-kernel vec_sub_op (A B idx &out C)
  (declare #'(in-vec in-vec ulong &out out-vec))
  (set! (~ C idx) (some-operation (~ A idx) (~ B idx))))
```

After ANF expansion the flat body looks like:
```
(%t0  (~ A idx))           ; tensor read
(%t1  (~ B idx))           ; tensor read
(%t2  (some-operation %t0 %t1))  ; sub-function call
(set! (~ C idx) %t2)       ; tensor write
```

The backward walk traverses this in reverse:
1. `(set! (~ C idx) %t2)` → seeds `%t2_adj = (~ C_GRAD idx)`  ← feature 080
2. `(%t2 (some-operation %t0 %t1))` → calls `some_operation_GRAD(%t0, %t1, %t2_adj)`
   → gets `(delta_t0 delta_t1)`, accumulates `%t0_adj += delta_t0`, `%t1_adj += delta_t1`  ← feature 052 Phase B
3. `(%t0 (~ A idx))` → `(set! (~ A_GRAD idx) (+ (~ A_GRAD idx) %t0_adj))`  ← feature 080
4. `(%t1 (~ B idx))` → `(set! (~ B_GRAD idx) (+ (~ B_GRAD idx) %t1_adj))`  ← feature 080

Steps 1, 3, and 4 are already handled. Step 2 is the 052 Phase B extension.
No new mechanism is needed; the combination falls out naturally.

---

## New Work in 081

### 081-1: Non-float tensor error (new, small)

**Location**: `%generate-backward-kernel-ast` or `%compute-backward-kernel-params`
in `src/macros.lisp` (or via overlay redef).

**Trigger**: `--differentiate` on a kernel whose inputs are ALL non-differentiable
(e.g., all integer tensors, no float scalars, no float tensors).

Current behavior: silently generates a backward kernel with no gradient parameters and
an empty backward body. This produces nonsensical (but not crashing) output.

**New behavior**: signal a clear error:
```
Cannot differentiate kernel ~A: no differentiable parameters
(inputs ~A have non-float element types — did you mean to use forward-only?)
```

**Where to add**: at the top of `%generate-backward-kernel-ast`, after computing
`diff-flat-inputs`. If `diff-flat-inputs` is empty AND `flat-inputs` is non-empty,
raise the error.

---

## Dependencies

081 **requires** 052 to be fully implemented (Phases A–E). Once 052 is done, the 081
tests should pass with only the non-float tensor error check as additional work.

The implementation order is therefore:
1. Implement 052 (heavy lift — see `052-differentiate-sub-functions/plan.md`)
2. Add non-float tensor error check (081-1)
3. Verify 081 tests pass
4. Update `tests/ci-stop.txt` to `081-tensor-sub-function-ad`

---

## Test Suite

### Normal Tests

| File | What it tests | Key 052 analogue | Validates |
|------|--------------|-------------------|-----------|
| `01-vec-basic-sub-function.crisp` | `def-function` + 1D vector input | 052/01 | `@vec_sub_op_grad`, `@some_operation_grad`, call, `fadd`, no `idx_GRAD` |
| `02-vec-chain-depth.crisp` | chain `f(g(h(x)))` with vector input | 052/06 | three `_GRAD` companions, chain of calls |
| `03-matrix-basic-sub-function.crisp` | `def-function` + 2D matrix | 052/01 | 2D gradient tensor type, `@scale_and_bias_grad` |
| `04-tensor-basic-sub-function.crisp` | `def-function` + 3D tensor | 052/01 | 3D gradient tensor type, `@combine_grad` |
| `05-vec-multi-value-return.crisp` | sub-function returns two values + vector | 052/03 | two `_GRAD` output delta returns, two tensor grad params |
| `06-vec-fan-out.crisp` | two sub-fn calls using same input var | 052/05 | both sub-fn `_GRAD` calls present |
| `07-vec-mixed-scalar-tensor.crisp` | scalar float + vector inputs through sub-fn | 052/09 + 080/03 | scalar `scale_GRAD` + tensor `A_GRAD` |

### Error Tests

| File | Expected error |
|------|---------------|
| `errors/01-non-float-tensor.crisp` | `FAIL-WITH[--differentiate]: "Cannot differentiate"` |

---

## Validators (to append to `src/metadata-val.lisp` via overlay)

```
validate-vec-basic-sub-grad         ; test 01
validate-vec-chain-depth-grad       ; test 02
validate-mat-basic-sub-grad         ; test 03
validate-tensor-basic-sub-grad      ; test 04
validate-vec-mvb-sub-grad           ; test 05
validate-vec-fan-out-sub-grad       ; test 06
validate-vec-mixed-sub-grad         ; test 07
```

---

## Files Modified

| File | How |
|------|-----|
| `src/macros.lisp` | ADD non-float tensor error check in `%generate-backward-kernel-ast` |
| `src/metadata-val.lisp` | APPEND 7 validator functions (or via overlay) |
| `tests/ci-stop.txt` | UPDATE to `081-tensor-sub-function-ad` when all tests pass |
| `tests/spec/081-tensor-sub-function-ad/` | NEW test files (this directory) |

---

## Status: TDD — awaiting 052 implementation
