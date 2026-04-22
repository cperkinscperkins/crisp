# Tensor / Vector / Matrix Auto-Differentiation
## Feature: 080-tensor-ad

---

## How the Current AD System Works (Cells)

The core lives in `src/autodiff.lisp` and `src/macros.lisp`.
Flow for a kernel like `cell_add (A B &out C)`:

1. **ANF transform** flattens the body into bindings:
   `(tmp1 (~ A))`, `(tmp2 (~ B))`, `(tmp3 (+ tmp1 tmp2))`, `(set! (~ C) tmp3)`

2. **`generate-backward-walk`** reverses that:
   - **B4 case** — `(set! (~ C) tmp3)`: C is output → seed `adj(tmp3) += (~ C_GRAD)`
   - **Single-value backward** — `(tmp3 (+ tmp1 tmp2))`: + rule → accumulate into `adj(tmp1)`, `adj(tmp2)`
   - **`~` case (line 68-70)** — `(tmp1 (~ A))`: treats as identity, `adj(A) += adj(tmp1)`
   - **Final loop**: for each input, emit `(set! (~ A_GRAD) adj(A))` for cells

3. The kernel signature gets `A_GRAD B_GRAD` appended as `&out` params with the same types as `A B`.

---

## What Needs to Change for Tensors

For a kernel `(set! (~ C i) (+ (~ A i) (~ B i)))`, the ANF is:

```
(i   (get-global-id 0))
(tmp1 (~ A i))
(tmp2 (~ B i))
(tmp3 (+ tmp1 tmp2))
(set! (~ C i) tmp3)
```

The desired backward output:

```lisp
(let ((tmp3_adj 0.0) (tmp1_adj 0.0) (tmp2_adj 0.0))
  (set! tmp3_adj  (+ tmp3_adj (~ C_GRAD i)))         ; seed from output grad — same index
  (set! tmp1_adj  (+ tmp1_adj tmp3_adj))              ; + backward
  (set! tmp2_adj  (+ tmp2_adj tmp3_adj))
  (set! (~ A_GRAD i) (+ (~ A_GRAD i) tmp1_adj))      ; write gradient tensor — same index
  (set! (~ B_GRAD i) (+ (~ B_GRAD i) tmp2_adj)))
```

### Five Structural Changes Required

**1. `%handle-single-value-backward` — `~` case (`autodiff.lisp` line 68)**
Currently catches both `(~ cell)` and `(~ tensor i j k)` and accumulates `adj(src) += adj(v)`.
For the tensor case (more than one argument to `~`), instead emit directly:
`(set! (~ src_GRAD idx...) (+ (~ src_GRAD idx...) adj(v)))`

**2. `generate-backward-walk` B4 (`autodiff.lisp` line 227)**
Currently handles `(set! (~ target) val)` for cell outputs.
Also handle `(set! (~ target idx...) val)` for tensor outputs — seed from `(~ target_GRAD idx...)`.

**3. Final emit loop (`autodiff.lisp` line 245)**
Currently emits `(set! (~ in_GRAD) adj(in))` for cell inputs.
For tensor inputs: **skip** — per-element accumulation already done in change 1.

**4. `%compute-backward-kernel-params` (`macros.lisp` line 536)**
Gradient output types for tensor inputs need `:access :read-write` (the backward reads AND
writes the gradient tensor). Strip existing access qualifier and substitute `:read-write`.

**5. `%compute-backward-kernel-params` — filter non-differentiable scalar inputs**
Integer scalar inputs (e.g. `ulong idx`) must NOT generate gradient output parameters.
Currently the function passes all non-record flat inputs through to `non-rec-scalar-in-grad-params`
regardless of type. An integer gradient output `idx_GRAD ulong` would be emitted and then
`(set! idx_GRAD 0.0)` would be written — a float/integer type mismatch.

Fix: only generate gradient outputs for inputs whose type satisfies `%crisp-float-type-p` OR is
a tensor/vector/matrix of float. Integer scalar params (ulong, long, int, etc.) pass through to
the backward kernel as regular inputs (so the backward body can use them as indices) but never
get a `_GRAD` counterpart.

The `diff-flat-inputs` list used by `generate-backward-walk` must be filtered by the same rule,
so the final emit loop does not try to write an integer adjoint.

---

## atomic-add! Decision

For the primary use case — element-wise GPU kernels where thread `i` exclusively owns index `i`
— non-atomic read-modify-write is both correct and faster. Atomics are only required for
reduction-style kernels (scatter patterns where multiple threads may write the same gradient
index). Those are out of scope for this initial feature.

`atomic-add!` is currently a stub (`src/analysis/ops.lisp:126`):
```lisp
(defun analyze-atomic-add!-expression (expr env context location)
  (declare (ignore expr env context location))
  (error "atomic-add! not implemented"))
```
A placeholder comment has been inserted just above that stub identifying the codegen work needed
(LLVM binding for `LLVMBuildAtomicRMW`, semantic analysis, IR emission). `atomic-add!` will be
implemented as a follow-on feature.

**Limitation to document:** tensor AD backward is correct when each gradient element is written
by at most one thread (guaranteed for element-wise kernels; not guaranteed for scatter/reduction
patterns).

---

## Gradient Tensor Access Mode

When an input is `(vector float :global :read-only)`, its gradient output `A_GRAD` must be
`(vector float :global :read-write)` — the backward kernel reads the current accumulated value
AND writes the new accumulated value. `%compute-backward-kernel-params` will strip the original
access qualifier and substitute `:read-write` for tensor gradient outputs.

---

## Scope: All Three at Once

Vectors, matrices, and tensors all use the same `~` operator with index arguments.
The four code changes above are identical for all three. There is no benefit to phasing.

---

## Existing Tests — No Re-work Needed

| Directory | Reason no tensor variant needed |
|---|---|
| `041-non-differentiable-kernels` | Tests forward-only mechanism, orthogonal to storage handle type |
| `043-differentiable-kernels` | Validates cell AD pathway; tensor pathway validated in `080` |
| `044-autodiff-execution` | GPU execution — deferred |
| `049-auto-diff-record-at-kernel-boundary` | Record-specific explosion logic, orthogonal |
| `050-differentiate-and-metadata` | Cell metadata + AD; tensor metadata covered by existing tensor metadata tests |
| `052-differentiate-sub-functions` | Sub-function tensor AD is complex (requires sub-fn backward to handle tensor reads); deferred |

---

## Proposed Test Plan for `080-tensor-ad`

| File | What it covers |
|---|---|
| `01-vec-add.crisp` | Simplest case: 1D vector, one index, addition |
| `02-vec-multiply.crisp` | Product rule through vector elements |
| `03-vec-mixed.crisp` | Scalar + vector inputs mixed |
| `04-matrix-add.crisp` | 2D, two indices |
| `05-tensor-add.crisp` | 3D, three indices |
| `06-vec-transcendental.crisp` | `sin`/`cos` through vector elements |
| `errors/01-mutation.crisp` | Mutating an input tensor — should error |

All tests use `--ir-target=llvmir --differentiate` and validate the generated backward kernel
LLVM-IR (signature, gradient accumulation pattern, index reuse).

---

## Notes on `idx` as Kernel Parameter (vs `get-global-id`)

Tests use explicit `ulong` index parameters (`idx`, `row col`, `d0 d1 d2`) rather than
`get-global-id`. This is intentional:

- `get-global-id` is not yet implemented in the compiler.
- Using explicit parameters does **not** limit AD capability. The backward walk sees `idx` as
  a symbol in the ANF and carries it through to gradient reads/writes identically to how it
  would handle a locally-computed `(get-global-id 0)` binding.
- When `get-global-id` is added, its ANF binding `(idx (get-global-id 0))` just needs one
  addition: add `get-global-id` to `%backward-skip-fn-p` so the backward walk skips it
  silently. No other AD changes required.

`idx` (and `row`, `col`, `d0`…) are `ulong` — not float — so change 5 above ensures they
are **not** given `_GRAD` output parameters in the backward kernel.

---

## Implementation Order

1. Write the seven test files (TDD) ✓
2. `%crisp-tensor-type-p` predicate (analogous to `%crisp-float-type-p`) ✓
   - Also added `%crisp-float-tensor-type-p` (tensor with float element type)
3. Extend `%handle-single-value-backward` — `~` case ✓
4. Extend `generate-backward-walk` B4 ✓
5. Update final emit loop (skip tensor inputs) ✓
6. Update `%compute-backward-kernel-params` ✓
   a. filter non-float scalar inputs from gradient outputs (change 5)
   b. fix access mode for tensor gradient outputs to `:read-write` (change 4)
   c. also include cells in differentiability predicate (regression fix)
7. Remove `SKIP-WITH[--differentiate]` tags from tensor kernel boundary tests ✓
   - Removed: 068/05, 068/06, 071/03
   - Kept (still legitimately skip): 068/04 vector long, 068/07 template T, 070+/non-float tensors
8. Update `ci-stop.txt` ✓ (→ `080-advanced-ad`)
