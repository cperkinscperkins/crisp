Scenario
---------

forward kernel has signature (A B &out C).  But it calls sub functions.  Trying to understand
what/how/when to differentiate them.

Chris
-----

Are these statemnts correct in this scenario?

If a sub-function doesn't deal with A, B or C, then we don't need to differentiate it.

If a sub-function is passed A or B, but not C and its return value also does not contribute to the final calculation of C, we also don't need to differentiate it.

If a sub-function contributes to C but without involving A or B, we don't need to differentiate it.

If a sub-function returns a value that contributes to C and is also passed A and/or B, then we DO need to differentiate it.  A and B might or might not be scalars or storage handles in the forward kernel. But A_grad and B_grad are _definitely_  storage handles (cells for now). So if we differentiate the function we can amend its signature for &out A_grad, B_grad (as appropriate), or maybe have it return multiple values (res a_g b_g) ?


Claude
------
All four statements are correct. That's clean reasoning — you've essentially described the data-flow reachability condition: a sub-function needs differentiation only if it sits on a path from an input (A or B) to the output (C). If A and B don't reach through it to C, the gradient is zero and there's nothing to compute.

On the gradient output mechanism — one wrinkle on your last point. A_grad and B_grad being storage handles (cells) works at the kernel boundary because the host allocates them as buffers. But inside the kernel, A_grad and B_grad are accumulated locally as scalars in the backward walk (as a_adj, b_adj temporaries) and only written out to the cell at the very end. The sub-function's backward doesn't need to write to a cell — it just needs to return scalar delta values that get added into the running adjoints.

So the sub-function backward signature options rank roughly:

Multiple return values (bkwd-sub-func a b t_grad) -> (a_delta b_delta) — cleanest, backward walk does (set! a_adj (+ a_adj a_delta))
Scalar &out params (bkwd-sub-func a b t_grad &out a_delta b_delta) — consistent with existing kernel style, slightly more verbose
Passing the running adjoint cells directly — conflates accumulation with the function, harder to compose
Option 1 fits naturally if Crisp supports multiple return values from def-function. Does it?


Chris
-----
Yes. Crisp def-function has supported multiple return values since nearly the beginning. High priority.

Claude
------
That makes Option 1 the clear path then. The backward sub-function design becomes very clean:


;; forward
(def-function dot (a b) (* a b))

;; auto-generated backward
(def-function dot_bkwd (a b t_grad)
  (return (values (* b t_grad)    ;; a_delta
                  (* a t_grad)))) ;; b_delta
And the backward walk, when it sees (t1 (dot a b)), emits:


(let ((a_delta b_delta (dot_bkwd a b t1_adj)))
  (set! a_adj (+ a_adj a_delta))
  (set! b_adj (+ b_adj b_delta)))
That's a tight, composable pattern. Multiple return values avoid any cell allocation overhead inside the kernel, which matters for GPU performance. And since the backward function is just a def-function, it can itself be differentiated if it appears in another kernel — the recursion is handled uniformly.

The data-flow reachability check you outlined earlier also becomes straightforward to implement: walk the ANF, build a dependency graph from inputs to c, mark which sub-function calls are on that path, generate backward variants only for those. Sub-functions that are "off the critical path" get skipped entirely.

Good foundation for the 049/050 planning notes.


Chris
------

Thank you.  Question: what about higher order functions? Crisp supports functions as first order args, but not really. Anytime anyone does that, we just convert the function with the function param as a template and then specialize it to the ACTUAL calls.  Monomorphization, in other words.  

How will that tie in?

Gemini
------
Monomorphization is actually the absolute best-case scenario for this. It turns what could be a massive headache into a completely solved problem.

If Crisp resolves higher-order functions (HOFs) by stamping out specialized, first-order copies of them, the Automatic Differentiation system doesn't ever have to know that a higher-order function existed in the first place.

It all comes down to the order of operations in your compiler pipeline. Here is how it ties together perfectly:

### 1. The Compiler Pipeline Order

To make this work seamlessly, your compiler passes just need to happen in this specific sequence:

1. **Monomorphization:** Expand all your generic/HOF calls into specialized first-order functions.
2. **ANF Conversion:** Convert the specialized code into A-Normal Form.
3. **Activity Analysis & AD:** Run the reachability checks and generate the `_bkwd` variants.

If you strictly enforce that order, the autodiff pass is completely blind to the fact that the original code was higher-order.

### 2. How the Generation Unfolds

Let's say you have a higher-order `reduce` function, and the user passes in a custom `multiply` function.

**Step 1: Monomorphization**
Crisp's template system sees `(reduce multiply arr)` and stamps out a brand new, specialized, first-order function. Let's call it `reduce_multiply_specialized`. The function pointer argument is gone, replaced by a direct call to `multiply` inside the generated body.

**Step 2: Activity Analysis**
The AD pass looks at `reduce_multiply_specialized`. It traces the inputs (`arr`) to the output. It sees the hardcoded call to `multiply` sitting directly on the critical path.

**Step 3: Backward Generation**
Because it's just a normal first-order function at this point, the AD pass easily generates `reduce_multiply_specialized_bkwd`. Inside *that* generated function, it emits a call to `multiply_bkwd`.

### Why this is perfect for GPUs

Trying to do autodiff on true higher-order functions usually requires closures or function pointers. GPUs absolutely hate function pointers because they destroy branch prediction and prevent inlining, which forces register spilling.

By monomorphizing first, you are guaranteeing that:

* Every function call is statically known.
* The compiler can aggressively inline the forward and backward passes.
* Your scalar adjoints stay safely in the fast hardware registers.

The only slight gotcha to watch out for is combinatorial explosion. If a user passes 10 different sub-functions to `map`, you generate 10 specialized `map` functions, which means the AD pass will generate 10 distinct `map_specialized_bkwd` functions. But for ahead-of-time GPU kernel compilation, that trade-off (larger binary size for maximum execution speed) is exactly what you want anyway.



Chris
-----
I'm about to embark on this endeavor of expanding our auto-diff to sub function calls. I'll need to write a bunch of TDD tests in advance.  What should I be testing?  What is it I don't want to overlook?

Gemini
------
This is the perfect time to build a safety net. When you transition from differentiating a single flat kernel to traversing a graph of sub-functions, the complexity doesn't just add up; it multiplies.

Here is a breakdown of the specific TDD categories and edge cases you should write tests for before you start hacking on the AST traversal.

### 1. The "Fan-Out" Accumulation (The Most Common AD Bug)

In a forward pass, a single variable can be passed to multiple sub-functions. In the backward pass, the gradients from all those uses must be summed together.

* **The Test:** Create a kernel where variable `A` is passed to sub-function `foo` and also to sub-function `bar`. Both results contribute to `C`.
* **The Verification:** The generated ANF for the backward pass MUST emit `(set! a_adj (+ a_adj foo_a_delta))` and later `(set! a_adj (+ a_adj bar_a_delta))`. If your compiler accidentally overwrites `a_adj` instead of accumulating it, the gradients will be completely wrong.

### 2. The "Same Variable Twice" Trap (Aliasing)

What happens if the user passes the exact same variable to a sub-function multiple times?

* **The Test:** Write a call like `(my-custom-multiply A A)`.
* **The Verification:** The generated backward call will return two deltas: `(let ((delta_1 delta_2 (my-custom-multiply_bkwd A A C_grad))) ...)`. Your test needs to ensure that *both* `delta_1` and `delta_2` are successfully accumulated into `A_adj`.

### 3. Reachability and "Dead" Gradients

You need to aggressively test those four Activity Analysis rules you outlined earlier to ensure you aren't generating useless `_bkwd` functions or allocating registers for dead math.

* **The "Constant" Test:** A sub-function that only processes constants or non-differentiable variables. Verify that the AD pass skips it completely.
* **The "Dead End" Test:** A sub-function that processes active variables (`A` or `B`), but its return value is discarded or never actually makes it into the final calculation of `C`. Verify that no backward variant is generated and no adjoints are calculated for it.

### 4. Multiple Return Value Alignment

Since you are using the `values` mechanism to return scalar deltas, the arity mapping has to be flawless.

* **The Test:** A sub-function `foo(w, x, y, z)` where `w` and `y` are active (require gradients), but `x` and `z` are passive (e.g., integer loop counters or flags).
* **The Verification:** Ensure the generated `foo_bkwd` only returns two values (the deltas for `w` and `y`), and that the caller's `let` binding expects exactly two values and routes them to the correct `w_adj` and `y_adj` accumulators.

### 5. Monomorphization Pipeline Verification

Since you are relying on monomorphization to handle higher-order functions, you need an integration test to ensure the compiler passes fire in the exact right order.

* **The Test:** Pass a custom math function into a higher-order function like a custom `map` or `reduce`.
* **The Verification:** Inspect the final generated AST. You should see a specialized `map_custom_math_bkwd` that internally contains a direct call to `custom_math_bkwd`. If the AD pass trips over the function pointer before monomorphization can resolve it, the test fails.

### 6. Control Flow (If Applicable)

If your Crisp sub-functions allow `if/else` branching, this is the hardest part of sub-function AD. The backward pass must take the *exact same branch* that the forward pass took.

* **The Test:** A sub-function with a conditional `(if (> A 0) (path-one A) (path-two A))`.
* **The Verification:** If you are recalculating the forward pass inside the backward pass to determine the branch, test that the logic holds. (If you are relying on pure ANF without complex control flow inside the sub-functions, you might not need to worry about this yet).

Setting up these specific AST-inspection tests before you write the traversal logic will save you a massive amount of debugging time when you start throwing real, complex math at the GPU.


Chris
-----

Thank you.

structs and records (just virtualized structs) can both appear on the kernel param boundary (records are exploded automatically).  Which means they can contribute to the &out of the forward kernel, which means we need to get their _grad.  This is already in place for the records.  Structs not quite, but they can appear in a cell storage handle as input to the kernel, so effectively yes for this purpose. ( Correct me if I'm wrong ).

ALSO structs and records have property accessors. For example x~ and ~x~, where x~ is an overloadable property access function and ~x~ is NOT.  The auto-diff system right now handles ~x~ just fine, but not x~ (unless it isn't defined and is just defaulting to the non-overloadable ~x~), because we didn't have sub-function support.

But now that we are adding subfunction support, we will need to handle x~  accessors as well.

They could do stuff like 
(def-function x~ (pt)
   ;; skip type declaration
   (+ 10 (~x~ pt)))

or
(def-function x~ (pt)
  ;; skip type declaration
  (+ 20 (y~ pt))) ;; <-- cross!!

What do I need to take into account on this front?


Gemini
------

You are spot on. Since `x~` is just a standard function under the hood, your new sub-function autodiff architecture will naturally subsume it.

However, because the argument being passed into the accessor is a composite type (a struct or record) rather than a simple scalar, it introduces a few very specific wrinkles into the backward pass that you need to test for.

Here is what you need to take into account and test for when extending AD to struct/record accessors:

### 1. The "Struct Gradient" Return Type

When a normal sub-function `(foo a b)` takes two scalars, `foo_bkwd` returns two scalar deltas. But when `(x~ pt)` takes a struct, `x~_bkwd` must return a **struct delta**.

* **The Implication:** If `pt` has fields `x`, `y`, and `z`, the backward pass of `(x~ pt)` needs to return a full `pt` shaped struct (or record) where the `x` field contains the gradient, and the `y` and `z` fields are explicitly zeroed out.
* **The Test:** Verify that the generated `x~_bkwd` function returns a properly shaped gradient struct/record, not just a bare scalar.

### 2. Member-Wise Accumulation (The Fan-Out for Structs)

In a forward kernel, it is practically guaranteed that a user will access multiple properties of the same struct: `(+ (x~ pt) (y~ pt))`.

* **The Implication:** The backward pass will generate two separate struct deltas: one from `x~_bkwd` and one from `y~_bkwd`. Your accumulation logic `(set! pt_adj (+ pt_adj pt_delta))` can no longer be a simple scalar addition. It must be a member-wise addition of the two gradient structs.
* **The Test:** Ensure your AD pass knows how to emit a struct-aware addition operation when accumulating adjoints for composite types.

### 3. The Cross-Property Chain Rule

Your second example, `(def-function x~ (pt) (+ 20 (y~ pt)))`, is actually the beauty of this design: it just works for free if your sub-function AD is completely recursive.

* **The Implication:** `x~_bkwd` will simply be generated to call `y~_bkwd` and pass the gradients along. The `+ 20` drops out perfectly because the derivative of a constant is 0.
* **The Test:** Write an integration test exactly like your example. Verify that `x~_bkwd` successfully generates and internally calls `y~_bkwd`, proving that custom accessors can safely call other custom accessors without breaking the chain rule.

### 4. Primitive Accessor Interception (`~x~`)

In your first example, `(def-function x~ (pt) (+ 10 (~x~ pt)))`, the custom accessor eventually hits the non-overloadable primitive accessor `~x~`.

* **The Implication:** `~x~` is the absolute bottom of the call stack. It does not have a Crisp `def-function` body to traverse. The AD system needs a hardcoded rule for `~x~`.
* **The Test:** Verify that when the AD pass hits the primitive `~x~`, it knows how to instantly map the incoming `t_grad` strictly to the `x` slot of the newly created struct delta, leaving all other fields as 0.

### 5. Exploded Records vs. Cell Pointers

You mentioned records are exploded automatically at the boundary, while structs are in cell storage handles.

* **The Implication:** Inside the sub-functions, they likely look identical (just passing values). But at the kernel boundary where the final `pt_adj` is written out, the compiler needs to handle the routing.
* **The Test:** Ensure that when the backward walk finishes, the accumulated `pt_adj` for an exploded record correctly maps its fields back to the individual `&out` parameters, whereas the `pt_adj` for a struct correctly executes a cell write.

Tackling the member-wise struct accumulation is usually the trickiest part of this specific phase. If the compiler already has a generic `struct-add` or vector-add primitive you can lean on, that will make generating the `set!` accumulations vastly easier.


Chris
-----
What about errors that the compiler should throw?  What are some negative tests I should write to make sure everything is covered?


Gemini
------
Negative tests are just as important as the happy path, especially in a compiler. A good compiler error should catch the user before they generate a completely invalid GPU kernel or, worse, silently compute the wrong math.

Because you are building a tapeless, ahead-of-time AD system (returning scalar/struct deltas rather than dynamically allocating a Wengert list or "tape" at runtime), your compiler has to be very strict about what it allows on the active path.

Here are the critical negative tests you should write to ensure the compiler throws a clear, descriptive error instead of failing mysteriously or generating garbage SPIR-V code:

### 1. The "Black Box" on the Critical Path

If a user calls a function that the compiler cannot look inside and does not have a hardcoded derivative for, the AD pass must halt.

* **The Test:** Write a kernel where an active variable is passed into an opaque FFI call (like a C external function) or an unsupported hardware intrinsic, and the result contributes to `C`.
* **The Expected Error:** `Cannot differentiate opaque function [X]. Function is on the active path but lacks a Crisp definition or an explicit backward rule.`

### 2. Mutation and Side Effects in Sub-functions

AD relies heavily on mathematical purity. If a sub-function mutates a shared state or writes to a pointer *in place* while sitting on the active path, reversing the data flow accurately becomes nearly impossible without a runtime tape.

* **The Test:** Pass an active variable into a sub-function that performs a `set!` on a global variable or an alias, modifying it before returning.
* **The Expected Error:** `Mutation of state detected on the active differentiation path in sub-function [X]. Sub-functions contributing to gradients must be pure.`

### 3. Non-Differentiable Types on the Active Path

You cannot compute the continuous derivative of an integer, a boolean, or a string.

* **The Test:** Create a sub-function that takes a float `A`, casts it to an integer (or uses a floor/ceil operation), does some math, and casts it back to a float to contribute to `C`.
* **The Expected Error:** `Discontinuous type transition on active path. Cannot compute gradient through integer cast in sub-function [X].` (Or, if you prefer, the compiler could intentionally emit a gradient of `0.0`, but throwing an error is usually safer for the user so they know their gradients are being severed).

### 4. Unbounded Recursion

GPUs generally do not support dynamic recursion, and an AOT autodiff system will go into an infinite loop trying to generate the backward pass of a function that calls itself.

* **The Test:** Write a sub-function `fibonacci(A)` that calls itself, and put it on the active path.
* **The Expected Error:** `Unsupported recursion detected in sub-function [X] during backward pass generation.` The compiler should catch this graph cycle during the Activity Analysis phase before it even attempts to generate the `_bkwd` AST.

### 5. Type Mismatch in Custom/Overridden Accessors

Since users can write their own overloadable accessors like `(def-function x~ (pt) ...)`, they can easily mess up the return types.

* **The Test:** Write a custom accessor for a struct that returns a boolean or a completely unrelated type, and place it on the active path.
* **The Expected Error:** When the compiler tries to generate the backward pass and accumulate the adjoints, it should throw a type-checking error: `Type mismatch in gradient accumulation for [pt]. Expected struct delta, received [Type].`

### 6. Active Variables in Branch Conditions

Because you aren't storing a runtime tape, the backward pass has to know which branch the forward pass took. If the branch condition itself is a differentiable variable, things get incredibly sticky.

* **The Test:** Write a sub-function with `(if (> A 0) (* A 2) (* A 3))` where `A` is active.
* **The Expected Error:** Depending on how sophisticated your recomputation logic is inside the `_bkwd` function, you might support this. If you don't support recomputing branch conditions in the backward pass yet, you must explicitly throw: `Active variable [A] used in control flow condition. This is not currently supported in the AD pass.`

Catching these at compile time with a clear AST node reference will make the developer experience of writing Crisp kernels much less frustrating.


RECOMPUTATION STRATEGY for BRANCHING
-------------------------------------

for a kernel with signature (A B &out C), the 
auto-diff signature will be (A B C C_grad &out A_grad B_grad)
with the resulting C of the forward passed to the backward.
We can use a recomputation strategy for handling branching