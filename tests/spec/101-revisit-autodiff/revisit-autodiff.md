Chris Observes
==============

The Crisp implementation has added Auto Differentiation support in stages.  
In the earliest implementation, A|D required float params, did not auto-diff sub-functions, didn't support records at the kernel boundary, didn't include full tensors, etc etc.

But over time each of those shortcoming have been implemented and now the A|D system is, ostensibly
fairly complete.  Looking through the other spec directories we can see that integer
inputs now produce float output gradients in the backwards kernel production, and that sub-functions ARE differentiated just like kernels, and records at the k.b. are ALSO supported. etc.

Today I went through most of the tests that are marked SKIP-WITH[--differentiate] and checked them.
Dozens (scores) of those once-unsupported tests are now differentiating correctly and have already been re-enabled in the --differentiate test pass. Yes!!

But there were some discoveries as well (boo! knowledge bad!):

- kernels that don't have &out params are not differentiable, and they do error.  
But the error isn't clear. They should say something clear like "kernel ____ does not have any &out param and is not differentiable" or something.

- kernels that don't have input params ARE differentiable, technically. They should be trivial. 
 Probably we SHOULD differentiate these trivialities instead of erroring.

- These kernels are marked now as
   SKIP-WITH[--differentiate]: "kernel has no input param, not differentiable"
  so that'll need to be removed once this trivial differentiation is done.

- About a dozen kernels from 031-def-derived have this:
;; SKIP-WITH[--differentiate]: "Not supported in auto-diff yet"

But from what I can see they SHOULD be differentiable, no?  Yet they seem to fail like so:

    .\bin\crisp-compile.exe .\tests\spec\031-def-derived-type\01-derived-no-subst-struct.crisp --differentiate
    ; --- Starting Pass for Target: GENERIC ---

    Crisp compilation failed in .\tests\spec\031-def-derived-type\01-derived-no-subst-struct.crisp:
    Cannot differentiate kernel MEASURE_DISTANCE: no differentiable parameters (all inputs have non-float types -- add (forward-only) declaration or use float element types).

But, support for non-float type differentiation was added in the 085 endeavor. So I think these should be differentiable.  Let me know if I'm mistaken.



- there are three or four tests in 048-record-at-kernel-boundary that have this:
;; SKIP-WITH[--differentiate] : "TODO: auto-diff needs to be extended for records at kernel boundary"

They have the same error as above.  But, once again, differentiating records at kernel boundary WAS ADDED in the 049 endeavor. So it seems that they should be working.


- there are about a half dozen tests with this:
;; SKIP-WITH[--differentiate] : "hoist has no support for differentiate pass (yet)"

And that is true, that we don't have hoist support for the A|D pass. But the A|D pass itself never hoists and it looks to me like these tests SHOULD be working. Once again, most of them fail with the same error ("no differentiable parameters... use float elements") as above.



- there are a few with this:
;; SKIP-WITH[--differentiate]: "Tensor AD not yet supported"

But, once again, that was added in 080 and 081.   Those tests should be passing, I think.


- There are a series of strategy tests with
;; SKIP-WITH[--differentiate]: "kernel has no differentiable float parameters"
or
;; SKIP-WITH[--differentiate]: "strategy hoist not yet differentiated"


That, to my mind, seem like they should be differentiable. I think they all have input and &out params. 


- Lastly, several tests were recently added with
;; SKIP-WITH[--differentiate]: 'polymorphism test, not relevant to autodiff'

And, once again, while the assertion is correct, those tests seem like they SHOULD be differentiable.


Claude Inveighs
===============



Gemini Thinks about Scalars
===========================
This is a classic "edge case" in Autodiff implementation that separates high-level frameworks from true systems compilers.

The short answer: **Yes, they must be supported**, but the way they are differentiated is fundamentally different from floating-point Storage Handles. In Autodiff terms, integer scalars (and integer handles) are treated as **Constants** with respect to the gradient, even though they are **Variables** in the forward pass.

Here is how you should handle them in the Crisp compiler to ensure your `_grad.spv` remains valid:

### 1. The Zero-Gradient Rule
Mathematically, the derivative of a function with respect to a discrete integer is not defined in standard calculus (it’s a step function, so the derivative is either zero or undefined). 

In the backward walk, when your compiler encounters a scalar integer input:
*   **Forward Pass:** Use the integer value as normal for indexing, loop bounds, or bitwise logic.
*   **Backward Pass:** The "gradient" or adjoint for that integer input is effectively **null** or **zero**. It does not accumulate an adjoint because you cannot "nudge" an integer by a small $\epsilon$ to see how the output changes.

### 2. Implementation: The "Non-Differentiable" Tag
In your ANF graph, you should mark integer types as **non-differentiable nodes**. 

*   When the backward walk reaches an operation like `(get-index vector int-idx)`, the gradient flows back through the `vector` (the Storage Handle), but it **stops** at the `int-idx`. 
*   You do not need to allocate an adjoint register for the integer scalar.
*   The compiler simply ignores it during the chain-rule accumulation.

### 3. Why This Is Critical for Storage Handles
You mentioned integer scalars "possibly in conjunction with" vectors or matrices. This is the most common use case: using an integer scalar as a **stride, offset, or loop limit**.

If you didn't support integer inputs in a differentiable kernel, the user couldn't write a simple `map` or `reduce` that uses a scalar `n` to bound the loop. By supporting them as "non-differentiable inputs," you allow:
```crisp
(def-kernel my-grad-kernel (input-vec : &vector float) (n : int) (&out-vec : &vector float))
```
The backward pass will compute the gradient for `input-vec`, using `n` to know how many elements to process, but it won't attempt to compute a gradient for `n` itself.

### 4. Handling "Integer-to-Float" Casts
One trap to watch for: If a user takes an integer input and casts it to a float to use in a calculation:
```crisp
(let ((f-val (cast float int-input)))
  (* f-val some-other-float))
```
In this case, the `f-val` node in your graph has an adjoint, but when you step back to the `cast` operation, the gradient propagation ends. The "derivative" of that cast with respect to the integer input is zero.

### Summary for your Implementation:
*   **Supported?** Yes.
*   **Adjoint Allocation?** No (for the integer itself).
*   **Backward Walk Behavior:** Act as a "sink" or "leaf" for the gradient. They provide necessary values for the math (like indices), but they do not receive or pass on adjoints.

This keeps your `_grad.spv` lean—you aren't wasting GPU registers on gradients for values that can't actually be optimized via gradient descent.


Chris Asks About Int in A|D
===========================

What about this?  To my mind, this should be differentiable. We just promote the gradients to float instead of int. But maybe I'm not thinking clearly?



(def-record v-point (x int) (y int))

(def-record v-rect (top-left v-point) (bottom-right v-point))

(def-type out-c (cell int :address-space :global))

(def-kernel nested_recs_on_boundary_k (vr &out c)
    (declare #'(v-rect &out out-c))
    (set! (~ c) (* (x~ (top-left~ vr))
                   (y~ (bottom-right~ vr)))))



Gemini On Differenting int 
==========================

This is a classic "Systems vs. Mathematics" crossroads. Whether this is differentiable depends entirely on whether Crisp treats **integers** as *discrete labels* (like a memory index) or as *fixed-point numbers* (representing a physical quantity).

In most Autodiff frameworks (like PyTorch or JAX), integers are strictly non-differentiable because their derivative is zero almost everywhere. However, in a language like Crisp, where you control the code generation and promotion logic, you *could* support this—but there are significant architectural implications.

### 1. The "Promotion" Perspective (Your Intuition)
You are thinking clearly if you view the integers in `v-point` as **quantized values**. If the user is using `int` to save space or because the hardware prefers it, but the mathematical intent is multiplication (a continuous operation), then:
*   $\frac{\partial}{\partial x} (x \cdot y) = y$
*   Even if $x$ and $y$ are `int`, their partial derivatives ($y$ and $x$) are perfectly valid numbers.

**The Implementation Path:**
If you want to support this, your compiler would:
1.  See the `int` inputs.
2.  Generate a backward kernel where the **adjoints** (gradients) are stored as `float` (or your preferred floating-point type).
3.  Perform the multiplication derivative logic as if they were floats.

### 2. The "Discrete" Danger (The Counter-Argument)
The reason most compilers forbid this is the **Loss of Precision and Intent**.
If `x` and `y` are integers, they are often used for things that *cannot* be nudged, like an index into a `vector`. If your compiler starts generating gradients for all integers, it might waste a massive amount of register space and compute cycles calculating gradients for loop counters or array indices that will always mathematically be "ignored" by the optimizer later.

### 3. Proposed Strategy for Crisp: "Explicit Differentiable Integers"
Since you are the author, you have a middle path that preserves high performance (Method #2 logic) without being overly restrictive.

**A. Passive Support (Promote to Float Adjoints):**
In your `generate-backward-walk`, if the terminal node is a multiplication of two integers, you allow the gradient to propagate. You simply emit a `cast` in the backward kernel:
*   `grad_x = (cast float y) * output_grad`
*   `grad_y = (cast float x) * output_grad`

**B. The "Storage Handle" Distinction:**
This is the most important part for Crisp. You should probably distinguish between:
*   **Integers as Values:** (Like your `v-rect` example). These get gradients.
*   **Integers as Indices:** (Like the `idx` in `(~ vector idx)`). The gradient **stops** here. Even if you "nudge" an index by $0.0001$, the value retrieved from the vector doesn't change until you hit the next integer. The derivative of a lookup with respect to its index is zero.

### 4. Verdict on your `nested_recs_on_boundary_k`
Your kernel is a **Pure Math Sink**. It takes four integers and produces one integer.
*   **Yes, it is differentiable** if your goal is to find out how the output changes relative to the values of those coordinates.
*   **Promotion is mandatory:** The gradients *must* be floats. If you try to keep the gradients as integers, you'll lose all the "nudge" information that makes Autodiff useful (gradient descent with integer gradients is basically just a random walk).

**Implementation Note:**
When you generate the `_grad.spv` for this, the input structure `v-rect` remains the same in the forward pass, but the "Adjoint Structure" generated by the compiler should probably be a mirrored version of `v-rect` where every `int` is replaced by a `float`.

Does your current `_grad.spv` validator handle a "mismatch" where the input is a struct of `int` but the output gradient structure is a struct of `float`? That's usually the biggest hurdle in the implementation.


Plan: Option A — Differentiate Integer Inputs (records, scalars, cells)
=======================================================================

## Decision (2026-05-08)

Chris's stance: if a user chose `int` or `long`, assume they had a reason.
Don't second-guess. Differentiate every input type, including integer scalars,
integer cells, and integer record fields.  Integer-only inputs that happen to
be used purely as indices (e.g. `ulong idx` in `(~ A idx)`) end up with a
zero-valued `_GRAD` slot — the chain rule never reaches them via index
operations, so this falls out for free.  No special "differentiable integer"
tagging needed.

Rejected alternatives:
- Option B (only int record fields differentiate): too narrow; fails Chris's
  "user chose int, trust them" principle.
- Option C (dataflow heuristic to distinguish indices from values): risks
  devolving into special-case soup and complicates already-tricky type
  inference on the backward kernel.

## Mathematical foundation

Per Gemini's analysis (above): integer inputs participating in arithmetic are
mathematically differentiable.  Their adjoints are continuous (must be
floating-point).  Indices have zero gradient by chain-rule structure — `(~ A
idx)` has no gradient rule for `idx`, so `idx_adj` stays at its initial zero.
A cell-typed `_GRAD` slot for an index input ends up always-zero — symbolically
present (consistent ABI) but mathematically inert.

## Implementation plan

### 1. Type promotion helpers (`src/autodiff.lisp`)

Add three predicates / promoters parallel to the existing
`%crisp-integer-tensor-type-p` / `%integer-tensor-elem-to-float`:

- `%crisp-integer-scalar-type-p` — alias-resolving int-scalar predicate.
- `%integer-scalar-to-float-scalar` — `int / short / char → float`,
  `long / ulong → double`.
- `%crisp-integer-cell-type-p` — predicate for `(cell <int> ...)` types.
- `%integer-cell-elem-to-float` — promotes the element type, returning the
  4-element keyword form `(cell float-elem :address-space addr)` so
  `marshall-cell` and other downstream consumers accept it.
- `%promote-to-float-adjoint` — single-entry-point wrapper that dispatches
  to the right helper.

### 2. Widen the differentiability gates (`src/macros.lisp`)

Update `differentiable-non-rec-p` and `has-grad-output-p` (currently around
lines 560–573) to accept integer scalars, integer cells, and integer tensors
in addition to the existing float / cell / float-tensor types.

### 3. Promote `_GRAD` types

Two loops to update:
- `non-rec-scalar-in-grad-types` (input `_GRAD` outputs): wrap bare scalars
  (int and float) in `(cell <float-elem> :address-space :global)` so
  gradients can actually flow back to the caller via pointer indirection.
  The current bare-scalar `&out` is a latent bug for floats too — never
  exercised because no existing kernel-level test uses bare float scalar
  inputs.  Cells and tensors stay shape-preserving with element promotion.
- `out-grad-types` (caller-supplied `_GRAD` seeds, parallel to outputs):
  apply `%promote-to-float-adjoint` so an `int`-cell output gets its seed
  as a `float`-cell, etc.

### 4. Type-aware adjoint zero-init (`src/autodiff.lisp` ~line 811)

The let-binding currently emits `(adv 0.0)` for every adjoint.  For
adjoints whose corresponding input promotes to `double`, this leaves the
adj bound to a float, then the final write to a `double` cell trips the
type checker.

Fix: thread a per-adjoint typing-context through `generate-backward-walk`
and emit `0.0d0` (or `(as double 0.0)`) for double-typed adjoints, `0.0`
for float-typed ones.  Defaults to `0.0` for adjoints with no clear
mapping (intermediate / temp values inherit type from chain-rule ops).

### 5. Cell-write the wrapped-scalar grads (`src/autodiff.lisp` ~line 319-331)

The final emit loop currently chooses between
- `(set! (~ in_grad) adj)` — when input is a cell
- `(set! in_grad adj)` — for everything else

After (3), bare-scalar inputs get cell-wrapped `_GRAD` outputs.  The branch
needs to check the *grad-output* type, not the input type.  When the grad
output is a cell, emit the cell-write idiom regardless of the input type.

### 6. Record-field gradients for int fields (`src/autodiff.lisp:570-576`)

`%expand-record-kernel-inputs` currently only emits `_GRAD` cells for float
fields.  Extend the loop to also handle integer fields, with element-type
promotion to float (per the same `%integer-scalar-to-float-scalar` rule).

### 7. Validator updates (`src/metadata-val.lisp`)

About 20 validators hard-code parameter counts that assume integer inputs
are excluded from gradients.  Each needs its expected count bumped to
account for the new `_GRAD` slots.  Each fix is a single number change;
add a comment noting the post-101-endeavor signature.

Specifically affected validator families:
- `validate-rec-kb-not-float` (049/05): `x` field was int, no grad → now has grad.
- `validate-tensor-add-grad` family (080-advanced-ad): `ulong idx` now has
  always-zero `_GRAD` slot.
- 081-tensor-sub-function-ad family: same `ulong` index promotion.
- 082-atomics/10: same.

## Test strategy

1. Probe (`put_temp_files_here/probe-int-ad.crisp`): minimal int-only
   arithmetic kernel.  Already verified to produce correct chain-rule
   backward IR with `sitofp` casts; will use as the regression sentinel.
2. Run full suite default + `--differentiate` after each change to catch
   cascading issues early.
3. Once all-green, sweep the 41 NO-DIFF-PARAMS bucket from the earlier
   sweep — most should now pass when SKIP-WITH is removed.  Tests with
   metadata-validators-under-differentiate (a separate cluster) stay
   skipped.

## Risk

- Surprise type-inference cascade beyond the adjoint zero-init.  If found,
  add a fix; estimate +2-4 hours.
- A test in the 41-bucket might fail for a non-int-AD reason (e.g.
  unrelated bug).  Investigate per-case.
- Validator-update fatigue: if 20 turns out to be 30+, the work expands.

## Estimate

Half a day to a day of work end-to-end.  Code changes ≈ 2 hours.
Validator updates ≈ 2 hours.  Iteration ≈ 2-4 hours.  Verification ≈ 1 hour.



Chris Notes
===========

Reasons we can't -differentiate:

1 - No &out.

2 - the metadata validators are looking for forward kernel, but when --differentiate we
have a backwards one, which doesn't match their assumptions. 
048
;; SKIP-WITH[--differentiate] : "TODO: auto-diff needs to be extended for records at kernel boundary"

031
;; SKIP-WITH[--differentiate]: "Not supported in auto-diff yet"