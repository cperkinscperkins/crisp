
# **Reductions: Shop Local, Act Global 📝**

A fundamental reality of GPU programming is that coordinating threads is cheap locally and expensive globally. A very common practice among GPU algorithm writers is "shop local, act global."

In this practice, a small amount of local memory (or register space) is operated upon by the threads in a single workgroup. Once the workgroup has reduced its data down to a single local value, one leader thread "acts global" by combining that local result with the results from all the other workgroups across the grid.

Crisp embraces this reality. We don't provide a single, monolithic, "one-size-fits-all" reduction. Instead, Crisp provides composable building blocks based on a two-phase strategy:

* **Phase 1: The Micro Strategy (Intra-Workgroup).** How do threads *within* a workgroup combine their data?
* **Phase 2: The Macro Strategy (Inter-Workgroup).** How do the workgroups safely combine their partial results into a final global answer?

By mixing and matching these strategies, you can tailor your reductions for speed, simplicity, or hardware capabilities.

---

## **Phase 1: The Micro Strategies (Intra-Workgroup)**

These are your workhorses. They take a variable (like `<someVar>`) and a commutative operation (like `#'+` or `#'max`), and reduce them across the local execution unit. They do not touch global memory.

### `reduce-warp` ✅

`(reduce-warp someFunction <someVar> identity &optional (active-threads (get-warp-size)))`

The warp shuffle is the undisputed king of speed. `reduce-warp` iteratively applies `someFunction` using register shuffles (`shuffle-xor`), entirely bypassing local memory and barriers.

* **Pros:** Blisteringly fast. Register-only.
* **Cons:** Limited to a single warp (usually 32 threads).

**Mechanics & Constraints:**
`reduce-warp` applies `someFunction` to the `<someVar>` expression in the current thread and another thread in the same warp. It iterates until all threads in the warp whose lane ID is less than `active-threads` have been reduced.

* **Thread Limit:** Using a value for `active-threads` that is GREATER than the warp size for the GPU hardware results in undefined behavior. This reduction cannot reduce more than `+warp-size+` threads.
* **Scope:** While `reduce-warp` coordinates other threads at the warp level, it is not a grid-level operation. This makes it highly versatile—it can be nested and used in a wide variety of contexts and applications.
* **Workgroup Considerations:** You could configure a kernel to run exactly one warp per workgroup via `(declare (local-size :set-to 32))`. While this fits many problems perfectly, a workgroup consisting of multiple warps is often better for hiding latency; if one warp pauses to fetch memory, another warp in the same workgroup can execute in its stead.

**Arguments & Return:**

* `someFunction`: Must be a `binop-type` having the signature `#(T T => T)`, where `T` is the type of `<someVar>`.
* `<someVar>`: The variable being reduced. After completion, `<someVar>` in all threads of the warp will be bound to the final reduced value.
* `identity`: The identity value for `someFunction` (e.g., `0` for `#'+`).
* `active-threads`: (Optional) The number of participating threads. Defaults to the hardware warp size.
* **Returns:** `nil`.

**Example:**
The example below will output "warp total: 640" repeatedly, once for each warp, assuming 32 threads per warp and each warp fully occupied.

```lisp
(let ((someVar 20))
  (reduce-warp #'+ someVar 0)
  (when-thread-in-warp-is 0
    (r-t-output "warp total: " someVar)))  ;; => "warp total: 640" 

```


### `reduce-workgroup` ✅

`(reduce-workgroup someFunction <someVar> identity &key return-vec local-scratch-vec message)`

This is your workhorse construct for the standard **Shared Memory Sweep**. It applies the reduction across all threads in the workgroup. Under the hood, it actually executes a lightning-fast `reduce-warp` for the first pass, and then sweeps up those warp-level results using a small local scratchpad (`local-scratch-vec`) and a workgroup barrier.

* **Pros:** The essential building block for any grid-level algorithm. Highly efficient two-step reduction.
* **Scope:** Like `reduce-warp`, this is **not** a grid-level operation, so it can be nested and used in a wide variety of contexts and situations.

**Mechanics:**
Functionally, `reduce-workgroup` is much the same as `reduce-warp` but expands its reach to all threads in the workgroup. The value `<someVar>` will be `uniform` (identical across all threads in the workgroup) at the completion of this operation.

**Arguments & Keys:**

* `someFunction`: Must be a `binop-type` having the signature `#(T T => T)`.
* `<someVar>`: The variable being reduced.
* `identity`: The identity value for `someFunction`.
* `:return-vec`: (Optional) A vector to store the final results. This vector must have the same element type as `<someVar>` and its address space MUST be `:global`. Its size should be the number of workgroups (calculated as `M = global_work_size / local_work_size`). If not provided, the result is simply kept in `<someVar>` for subsequent in-workgroup operations.
* `:local-scratch-vec`: (Optional) Writeable local memory used to bridge the warps. Its size must equal the number of warps in a single workgroup (`local_work_size / get-warp-size`). If omitted, Crisp will automatically generate this scratchpad for you.
* `:message`: (Optional) If Crisp generates the `:local-scratch-vec` on your behalf, this string message is attached to the allocation to help inform the hoisting code about why the extra scratch memory was needed.

**Post-Conditions & Return:**

* **Variable State:** `<someVar>` in *all* threads of the workgroup will be bound to the final value of the reduction.
* **Memory State:** `:return-vec` (if provided) will store the result of this specific workgroup's reduction at index `(get-group-id)`.
* **Scratch State:** The contents of `local-scratch-vec` are indeterminant after completion.
* **Returns:** `nil`.

**Example:**
This example demonstrates a workgroup calculating a local sum and automatically saving the result to a global output vector, while also retaining the value locally for immediate use.

```lisp
(let ((my-val (do-some-work (get-local-id))))
  
  ;; Reduce my-val across the entire workgroup, store WG result in out-vec
  (reduce-workgroup #'+ my-val 0 :return-vec out-vec :message "wg-sum-scratch")
  
  ;; Every thread in the workgroup now has the same total in my-val
  (when-thread-in-group-is 0
    (r-t-output "Workgroup total: " my-val))) 

```



## **Phase 2: The Macro Strategies (Inter-Workgroup)**

Once your `reduce-workgroup` finishes, thread 0 is holding a partial sum for its specific workgroup. To get the final global sum, we must cross the grid boundary.

Crisp offers four different Inter-Workgroup strategies to gather these partial results. Because crossing the grid boundary involves hardware trade-offs between memory footprint and execution contention, you should choose the strategy that best fits your algorithm's constraints.

### **Phase 2 Trade-off Matrix**

| Strategy | Supported Operations | Extra Global Memory Needed | Performance Profile |
| --- | --- | --- | --- |
| **`grid-reduce-atomic!`** | `#'+`, `#'min`, `#'max` only | **None** | **Fast.** Hardware optimized atomics. |
| **`grid-reduce-last-man!`** | Any Commutative | Size of `num_workgroups` | **Very Fast.** Single pass, zero contention. |
| **`grid-reduce-cas!`** | Any Commutative | **None** | **Slow (High Contention).** CAS loop serializes grid. |
| **`grid-reduce-second-stage!`** | Any Commutative | Size of `num_workgroups` | **Moderate.** Safe, but requires manual 2nd kernel launch. |

### `grid-reduce-atomic!` ✅

`(grid-reduce-atomic! someFunction <someVar> identity &out return-vec &key local-scratch-vec message)`

`grid-reduce-atomic!` is the "dead simple" single-pass inter-workgroup reduction. It first reduces the variable locally using `reduce-workgroup` (Phase 1), and then the leader thread of each workgroup safely accumulates its partial result into the global `return-vec` using a native hardware atomic operation (Phase 2).

**The Trade-off:**

* **Pros:** Very simple to use. It requires absolutely zero global scratchpad memory.
* **Cons:** High contention on a single memory address if the grid is massive. More importantly, it is strictly limited to operations that have native hardware atomic equivalents.

**Supported Operations & Constraints:**
Unlike other grid reductions, `grid-reduce-atomic!` can **only** be used with the following three commutative operations:

* `#'+`
* `#'min`
* `#'max`

Attempting to use this macro with any other operation will result in a compilation error. However, unlike dual-pass strategies, this macro can operate across all threads and is not constrained by maximum workgroup sizes.

**Arguments:**

* `someFunction`: Must be one of `#'+`, `#'min`, or `#'max`.
* `<someVar>`: The local variable being reduced.
* `identity`: The identity value for `someFunction` (e.g., `0` for `#'+`).
* `return-vec`: A required vector of length 1 (a `single-result`) in `:global` memory where the final value is accumulated.
* `:local-scratch-vec`: Writeable local memory used for the Phase 1 `reduce-workgroup` sweep, one
  element per warp in the workgroup (`:match-num-warps-per-workgroup` sizes it for you).
  Required, and allocated by the CALLER -- scratch created inside the construct's own
  expansion is invisible to the Pass-1 scanner that builds a kernel's implicit parameters, so
  Crisp cannot generate it for you.  Auto-generation needs that scanner to learn about
  analyzer-introduced scratch, which is a real feature and not a line of sugar.
* `:message`: (Optional) String attached to the allocation to inform the hoisting code.

**Post-Conditions & Return:**

* **Variable State:** After the operation, the value of `<someVar>` in any thread is indeterminant.
* **Memory State:** `return-vec[0]` will hold the final global reduction.
* **Scratch State:** The state of `localScratchVec` is indeterminant.
* **Returns:** `nil`.



### `grid-reduce-cas!` ✅

`(grid-reduce-cas! someFunction <someVar> identity &out return-vec &key local-scratch-vec)`

`grid-reduce-cas!` is a single-pass grid reduction that works with *any* commutative binary operation. It first reduces the variable locally using `reduce-workgroup`, and then the leader thread of each workgroup uses a global Compare-And-Swap (CAS) loop via `atomic-binop!` to safely accumulate its partial result into the `return-vec`.

**The Trade-off:**
This macro is the ultimate "low memory escape hatch." Unlike `grid-reduce-last-man!`, it requires zero global scratchpad memory. However, because every workgroup leader is trying to read, compute, and swap the exact same global address at the end of the kernel, it effectively serializes the grid into a massive traffic jam. One thread wins the CAS, while the others fail, loop, and try again. Use this only if your operation cannot use native atomics (`grid-reduce-atomic!`) AND you absolutely cannot afford the memory footprint of a global scratch buffer.

**Arguments:**

* `return-vec`: A required vector of length 1 (a `single-result`) where the final value is accumulated.
* `:local-scratch-vec`: Writeable local memory, one element per warp in the workgroup.
  Required, and allocated by the CALLER -- scratch created inside the construct's own
  expansion is invisible to the Pass-1 scanner that builds a kernel's implicit parameters, so
  Crisp cannot generate it for you.  Auto-generation needs that scanner to learn about
  analyzer-introduced scratch, which is a real feature and not a line of sugar.

**Result:**
After the operation, the value of `<someVar>` in any thread is indeterminant. `return-vec[0]` will hold the final global reduction.


### `grid-reduce-last-man!` ✅

`(grid-reduce-last-man! someFunction <someVar> identity &out return-vec &key local-scratch-vec global-scratch-vec atomic-counter election-flag-cell message)`

`grid-reduce-last-man!` is usually the fastest, most flexible single-pass grid reduction available. It works with *any* commutative binary operation without incurring the massive contention penalty of a global Compare-And-Swap loop, and without the scheduling overhead of launching a second "continuation" kernel.

**Mechanics:**
It accomplishes this via a cooperative finish.

1. **Phase 1:** Every workgroup reduces its threads locally using `reduce-workgroup`.
2. **Phase 2:** The leader thread of each workgroup writes its partial result into a `globalScratchVec`, and then increments a global `atomicCounter`.
3. **The Sweep:** The workgroup that increments the counter to `num_workgroups - 1` knows it is the *last* one to finish. That final workgroup immediately reads the `globalScratchVec` and performs one final `reduce-workgroup` to calculate the ultimate answer.

**The Trade-off:**

* **Pros:** Works with *any* commutative operation (unlike `grid-reduce-atomic!`). Zero contention on the final result cell. Requires only a single kernel launch.
* **Cons:** Requires allocating a global scratch buffer sized to the number of workgroups, plus a secondary atomic counter cell. (Note: Like the older dual-pass strategies, this specific implementation requires that the total number of workgroups is less than or equal to the `local_work_size` so the final sweep can happen in one pass).

**Arguments:**

* `someFunction`: Any commutative `binop-type` `#(T T => T)`.
* `<someVar>`: The local variable being reduced.
* `identity`: The identity value for `someFunction`.
* `return-vec`: A required vector of length 1 (a `single-result`) in `:global` memory.
* `:local-scratch-vec`: Writeable local memory, one element per warp in the workgroup.
* `:global-scratch-vec`: Writeable **`:global`** memory, one element per WORKGROUP
  (`global_work_size / local_work_size`), holding the partials.
* `:atomic-counter`: A zero-initialised `:global` `uint` cell, used to draw tickets.
* `:election-flag-cell`: A **workgroup-local** `uint` cell, which broadcasts the ticket result from
  thread 0 to the rest of its workgroup.  It is what lets the LOSING workgroups retire
  immediately instead of sweeping a buffer whose result they would discard -- the early
  retirement that is this strategy's whole advantage over a second kernel launch.  It is always
  `uint`, never the reduction's element type, so it does not follow `<someVar>`.
  Required, and allocated by the CALLER -- scratch created inside the construct's own
  expansion is invisible to the Pass-1 scanner that builds a kernel's implicit parameters, so
  Crisp cannot generate it for you.  Auto-generation needs that scanner to learn about
  analyzer-introduced scratch, which is a real feature and not a line of sugar.
* `:message`: (Optional) String attached to the allocations to inform the hoisting code.

**Post-Conditions & Return:**

* **Variable State:** After the operation, the value of `<someVar>` in any thread is indeterminant.
* **Memory State:** `return-vec[0]` will hold the final global reduction.
* **Scratch State:** The state of all three scratch buffers is indeterminant.
* **Returns:** `nil`.



### `grid-reduce-second-stage!` ✅

`(grid-reduce-second-stage! someFunction <someVar> identity in-scratch-vec &out return-vec &key local-scratch-vec)`

`grid-reduce-second-stage!` is designed exclusively for the final sweep of a dual-pass reduction. It is meant to be called inside a continuation kernel launched with a single workgroup. It reads the partial results from `in-scratch-vec` (populated by Kernel 1), reduces them, and stores the ultimate answer in `return-vec`.

**Special Constraints:**
This macro executes an assertion ensuring it is launched with exactly one workgroup (`num_groups == 1`), and that the `local_work_size` is large enough to handle the number of elements in `in-scratch-vec`.

**Arguments:**

* `someFunction`: Any commutative `binop-type` `#(T T => T)`.
* `<someVar>`: A local binding to hold the intermediate calculations.
* `identity`: The identity value for `someFunction`.
* `in-scratch-vec`: The `:global` vector containing the partial results from the first kernel pass.
* `return-vec`: A required vector of length 1 (a `single-result`) where the final value is accumulated.
* `:local-scratch-vec`: Writeable local memory used for the final sweep, one element per warp in
  the workgroup.
  Required, and allocated by the CALLER -- scratch created inside the construct's own
  expansion is invisible to the Pass-1 scanner that builds a kernel's implicit parameters, so
  Crisp cannot generate it for you.  Auto-generation needs that scanner to learn about
  analyzer-introduced scratch, which is a real feature and not a line of sugar.

**Post-Conditions & Return:**

* **Memory State:** `return-vec[0]` will hold the final global reduction.
* **Returns:** `nil`.



### `Strategy D: Cooperative Grid Sync (Hardware Dependent)`

On specific modern architectures (such as Nvidia GPUs supporting Cooperative Groups via PTX, or specific SPIR-V targets supporting Cross-Workgroup execution barriers), hardware-level grid synchronization is possible.

In a cooperative sync, workgroups perform Phase 1, write to the global scratchpad, and then hit a global execution barrier. Once the barrier drops, a single workgroup sweeps the global buffer.

* **Pros:** The "Holy Grail" of reductions. Single pass, highly performant, zero atomic contention.
* **Cons:** Hardware dependent. More critically, it carries a strict **Deadlock Risk**: the total grid size must fit entirely within the GPU's concurrent hardware capacity. If the grid requires preemption or swapping, the active workgroups will wait forever for pending workgroups that cannot launch.
* **Implementation:** *TBD (`grid-reduce-cooperative!`). Currently requires custom inline assembly or runtime-specific launch parameters to guarantee residency.*



## **Matchy Matchy: Putting it Together**

By combining Phase 1 and Phase 2, you create your algorithms.

**The Speed Demon Combo:** `Warp Shuffle` + `Last Man Standing`
If your problem fits in a single warp per workgroup, doing a warp shuffle into a Last-Man-Standing global sweep is generally the fastest possible reduction on modern GPUs.

**The Easy Button Combo:** `Shared Mem Sweep` + `Atomic Add`
If you are just summing up a massive grid of floats, you do a standard `reduce-workgroup`, and have thread 0 do a `grid-reduce-atomic!`. No global scratchpads to allocate, no counters to manage.

## Full Reductions Made Easy: strategy

In most of the reduction interfaces we've seen so far there are requirements for local or global scratch memory, maybe an election cell. But Crisp has its implicit "side channel" scratch memory support. Those arguments are always optional and if elided Crisp will just ensure the kernel implicit parameter slots for them and pass them down to the call chain wherever they are needed.  This makes using the routines above a lot simpler.

Another thing Crisp can do to make things simpler is to simply elect a Phase 2 strategy by name.  We see this in `grid-reduce` , but also the multiple value reductions and vector reductions below.

```
(def-enum reduction-strategy :atomic :last-man-standing :cas )
```

### `grid-reduce!` 📝
```
(grid-reduce! someFunction <someVar> identity &out return-cell &key strategy message)
;; :strategy is required to be known at compile time.  Defaults to :last-man-standing if not supplied.
```

`grid-reduce!` performs a `reduce-workgroup` on `<someVar>` as Phase 1, and then uses the `strategy` (which muust be from `reduction-strategy`) for the Phase 2 reduction, storing the final value in `return-cell` which should be a `cell` of the same type as `<someVar>`. 

```
(grid-reduce! #'+ sumF 0.0f float-c :strategy :cas :message "gridwise reduction of sumF")
```






## **Reducing Several Variables at Once 📝**

Algorithms often need more than one reduction over the same data: a minimum *and* a sum, or a
maximum *and* the index where it occurred. Running separate reductions one after another pays
for every shuffle, barrier, and grid election again. The three reduction constructs,
`reduce-warp`, `reduce-workgroup`, and `grid-reduce!`, each accept several variables in a single
call, in one of two forms:

* **Independent:** each variable has its own function and identity. The variables share the
  traversal but never influence one another (e.g. a `min` and a `+`).
* **Dependent:** one *combiner* reduces all the variables together, because they are
  entangled (e.g. a value and its index, or a count, mean, and M2 for streaming variance).

### Clauses

Both forms describe each variable with a **clause**, a list that keeps everything belonging to
that one variable (its function, identity, destination, and scratch memory) together in one
place:

| Form        | Clause |
| ---         | --- |
| Independent | `(someFunction <someVar> identity [return-cell] &key ...)` |
| Dependent   | `(<someVar> identity [return-cell] &key ...)` |

The independent clause is exactly the argument list of the single-variable form. The dependent
clause is the same, minus the function, because the combiner is shared and written once, before
the clauses.

`return-cell` appears only at the grid level (`grid-reduce!`), where every reduced variable
needs a destination. `reduce-warp` and `reduce-workgroup` leave their results in the variables
themselves.

The compiler tells the three shapes apart by their structure alone:

```lisp
(reduce-warp #'+ total 0.0f)                        ; single:      function, variable, identity
(reduce-warp ((#'+ total 0.0f) (#'min lo ...)))     ; independent: a list of clauses
(reduce-warp #'combine ((val ...) (idx ...)))       ; dependent:   a function, then a list of clauses
```

### Per-Variable vs. Per-Reduction Arguments

Every resource a reduction uses belongs either to one variable or to the reduction as a whole.
Resources that carry the variable's type go in that variable's clause. Everything else is a
trailing key on the call.

| Argument | Where it goes | Why |
| --- | --- | --- |
| `return-cell` | clause | One destination per variable, of that variable's type. |
| `:return-vec` (`reduce-workgroup`) | clause key | One per-workgroup result vector per variable. |
| `:local-scratch-vec` | clause key | Typed like the variable. |
| `:global-scratch-vec` | clause key | Typed like the variable. |
| `active-threads` (`reduce-warp`) | trailing `&optional` | One shuffle sweep covers every variable. |
| `:strategy` | trailing key | One Phase 2 strategy for the whole call. |
| `:atomic-counter` | trailing key | One ticket covers every variable (see below). |
| `:election-flag-cell` | trailing key | Always `uint`, never follows a variable's type. |
| `:message` | trailing key | Describes the call's allocations. |

Like their single-variable counterparts, all scratch arguments are optional. If you leave one
out, Crisp generates it for you.

A variable may appear in only one clause of a call. Naming the same variable twice is a
compilation error.

### Signatures

```lisp
;; independent
(reduce-warp      (clause ...) &optional active-threads)
(reduce-workgroup (clause ...) &key message)
(grid-reduce!     (clause ...) &key strategy atomic-counter election-flag-cell message)

;; dependent
(reduce-warp      combiner (clause ...) &optional active-threads)
(reduce-workgroup combiner (clause ...) &key message)
(grid-reduce!     combiner (clause ...) &key strategy atomic-counter election-flag-cell message)
```

### 1. Independent Reductions

Use this form when reducing separate metrics that share a traversal without influencing one
another.

```lisp
;; 'lo' and 'total' are existing mutable bindings
(reduce-warp
  ((#'min lo    (type-max int))
   (#'+   total 0.0f)))
```

Each clause's function must be a `binop-type` `#'(T T => T)`, where `T` is the type of that
clause's variable, and its identity must also be of type `T`. The clauses may have different
types.

Under the hood, the compiler interleaves the work for every variable. At the warp level a
single shuffle sweep carries all the variables, and at the workgroup level a single barrier
serves them all.

### 2. Dependent Reductions

Use this form when the values are entangled, such as keeping an index aligned with an extreme
value, or tracking a streaming variance.

The combiner takes two *states*, A and B, of `k` values each, and returns the combined state of
`k` values. Its signature is:

```
#'(T1 ... Tk  T1 ... Tk  =>  T1 ... Tk)
```

where `Ti` is the type of the variable in clause `i`. Argument `i`, argument `k+i`, and return
value `i` all share that type. Clause order is argument order: the first clause names the first
value of each state, and so on. The combiner returns its state as multiple values
(`(return v1 ... vk)`).

```lisp
(def-function argmax-combine (val-a idx-a val-b idx-b)
  (declare #'(float ulong float ulong => float ulong))
  (if (or (> val-a val-b)
          (and (= val-a val-b) (< idx-a idx-b))) ; tie-break: lower index wins
      (return val-a idx-a)
      (return val-b idx-b)))

(let ((my-val (do-some-math (get-global-id)))
      (my-idx (get-global-id)))
  (reduce-warp #'argmax-combine
               ((my-val (type-min float))
                (my-idx (type-max ulong)))))
```

### 3. The Workgroup Level

`reduce-workgroup` takes the same clauses. Each clause may name its own `:return-vec` and
`:local-scratch-vec`:

```lisp
(reduce-workgroup #'argmax-combine
                  ((my-val (type-min float) :return-vec wg-vals)
                   (my-idx (type-max ulong) :return-vec wg-idxs))
                  :message "argmax partials")
```

### 4. The Grid Level (`grid-reduce!`)

At the grid level, each clause names the `:global` cell that receives that variable's final
value.

**Independent:**

```lisp
(grid-reduce!
  ((#'min lo    (type-max int) out-min-cell)
   (#'+   total 0.0f           out-sum-cell))
  :strategy :last-man-standing)
```

**Dependent:**

```lisp
(grid-reduce! #'argmax-combine
              ((my-val (type-min float) out-val-cell)
               (my-idx (type-max ulong) out-idx-cell))
              :strategy :last-man-standing)
```

#### Grid Strategy Compatibility

* **Independent form:** All strategies (`:atomic`, `:cas`, `:last-man-standing`) are supported.
  `:atomic` still requires every clause's function to have a hardware atomic (`#'+`, `#'min`,
  `#'max`). A clause that does not is a compilation error.
* **Dependent form:** Only `:last-man-standing` is supported. `:atomic` and `:cas` commit one
  word at a time, so they cannot keep the `k` values of a state together. Asking for either is a
  compilation error. (Packing a small state into one 64-bit CAS word is possible in principle,
  but Crisp does not do it.)

Under `:last-man-standing`, one election serves the whole call. Each workgroup writes a partial
for every variable into that variable's `:global-scratch-vec`, then draws a single ticket from
the shared `:atomic-counter`. The last workgroup sweeps all the variables. A call with `k`
clauses costs one atomic ticket per workgroup, not `k`.

`:last-man-standing` is the default strategy, and it carries its usual limit: the number of
workgroups must not exceed `local_work_size`.

### Disposition of the Variables

* **`reduce-warp`**: Every lane of the warp receives the final reduced value(s) in its bound
  variables.
* **`reduce-workgroup`**: Every thread of the workgroup receives the final reduced value(s).
  Every reduced variable is `uniform` afterward.
* **`grid-reduce!`**: Results are written to the clauses' return cells. The local variables
  holding the partial states are indeterminate afterward.

*Execution constraint:* Every thread of the warp or workgroup must reach the call. Reductions
cannot be placed inside divergent control paths.

### Choosing the Identity and Function

* **The identity must change nothing.** Threads that contribute no data (e.g. lanes past
  `active-threads`) supply the identity, and the reduction then combines it with real values,
  and with other identities. Two laws must hold for every valid state `x`:
  * `f(x, identity) = x`: combining a real state with the identity returns the real state,
    including in the case of a tie.
  * `f(identity, identity) = identity`: two padding threads combined are still padding.

  Use `(type-min T)` for `max`, `(type-max T)` for `min`, and `(type-max ulong)` for an
  argmax/argmin index, so that when values tie, the real index wins against the padding one.
  For floating-point types, `(type-min T)` and `(type-max T)` are negative and positive
  infinity, so even an infinite input is not lost to the identity.

  The second law is the one that bites dependent combiners. A streaming-variance combiner
  divides by `n-a + n-b`; when two identity states `(0 0 0)` meet, that is `0/0`, and the NaN
  spreads through the whole reduction. Such a combiner must check for an empty state
  (`n = 0`) and return the other state unchanged.

* **Functions must be commutative *and* associative.** GPU reductions guarantee neither the
  order nor the grouping in which values are combined. If an operation is sensitive to ties,
  resolve them explicitly inside the function, as the lower-index tie-break in
  `argmax-combine` does.

  Floating-point addition is only approximately associative, so a float sum can differ in its
  last bits from run to run. That is normal on GPUs, not a bug.




## **The Vector API**

### `reduce-vec` 📝

Because reducing a 1D vector or tensor is so common, Crisp provides a high-level wrapper that automatically handles the grid-stride loops and applies the combinations for you:

`(reduce-vec someFunction vec identity &out out-cell &key strategy)`

Instead of manually writing the strided loops and managing the scratchpads, you simply tell `reduce-vec` which Macro Strategy to employ:


The `strategy` is one of:
```
(def-enum reduction-strategy :atomic :last-man-standing :cas )
```
The "second stage" isn't available because it requires a second kernel enqueue.


```lisp
;; Example: The "Easy Button" atomic strategy
(reduce-vec #'+ my-large-vector 0.0 result-cell :strategy :atomic)

;; Example: The flexible "Last Man Standing" strategy for custom operations
(reduce-vec #'my-custom-hash-combine my-large-vector 0 result-cell :strategy :last-man-standing )

```

*(Note: all `reduce-vec` operations utilize `reduce-workgroup` as their Phase 1 under the hood).*

### **Binop-Type and Commutativity 📝**

Whether you are shopping local or acting global, the `someFunction` you pass to these macros must have a `binop-type` signature: `#(T T => T)`.

Unlike reductions in some CPU languages, GPU reductions **do not guarantee execution order**. Your operations *must* be commutative (where `(someF a b)` is equivalent to `(someF b a)`). Addition, multiplication, min, and max work perfectly. Subtraction and division will fail catastrophically.

