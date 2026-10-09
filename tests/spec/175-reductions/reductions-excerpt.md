
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
`reduce-warp` applies `someFunction` to the `<someVar>` expression in the current thread and another thread in the same warp. It combines the values of every lane whose lane ID is less than `active-threads`; lanes at or past `active-threads` contribute the identity, and every lane of the warp -- active or not -- ends up holding the result.

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
* `:local-scratch-vec`: (Optional) Writeable local memory used to bridge the warps. Its size must equal the number of warps in a single workgroup (`local_work_size / get-warp-size`). If omitted, Crisp allocates this scratchpad for you, typed from the identity (see *Full Reductions Made Easy* below).
* `:message`: (Optional, reserved) A string saying why Crisp generated scratch memory on your behalf. It is accepted today but not yet attached to the implicit allocations.

**Post-Conditions & Return:**

* **Variable State:** `<someVar>` in *all* threads of the workgroup will be bound to the final value of the reduction.
* **Memory State:** `:return-vec` (if provided) will store the result of this specific workgroup's reduction at index `(get-group-id)`.
* **Scratch State:** The contents of `local-scratch-vec` are indeterminate after completion.
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

Once your `reduce-workgroup` finishes, every thread of the workgroup holds that workgroup's partial result. To get the final global sum, we must cross the grid boundary.

Crisp offers four Inter-Workgroup strategies to gather these partial results (a fifth, hardware-dependent one is sketched at the end). Because crossing the grid boundary involves hardware trade-offs between memory footprint and execution contention, you should choose the strategy that best fits your algorithm's constraints.

### **Phase 2 Trade-off Matrix**

| Strategy | Supported Operations | Extra Global Memory Needed | Performance Profile |
| --- | --- | --- | --- |
| **`grid-reduce-atomic!`** | `#'+`, `#'min`, `#'max` only | **None** | **Fast.** Hardware optimized atomics. |
| **`grid-reduce-last-man!`** | Any Commutative | Size of `num_workgroups` | **Very Fast.** Single pass, zero contention. |
| **`grid-reduce-cas!`** | Any Commutative | **None** | **Slow (High Contention).** CAS loop serializes grid. |
| **`grid-reduce-second-stage!`** | Any Commutative | Size of `num_workgroups` | **Moderate.** Safe, but requires manual 2nd kernel launch. |

#### Launching the Kernel Again

A host program usually launches the same kernel many times. What each strategy needs between launches:

| Strategy | Before every launch | Why |
| --- | --- | --- |
| `grid-reduce-atomic!` | the return cell must hold the **identity** | the atomics combine *into* it |
| `grid-reduce-cas!` | the return cell must hold the **identity** | the CAS loop combines *into* it |
| `grid-reduce-last-man!` | nothing | it *overwrites* the return cell, and the elected workgroup puts its ticket counter back to zero after the final sweep |
| `grid-reduce-second-stage!` | nothing | the partials are overwritten every launch |

The kernel cannot initialise an `:atomic` or `:cas` return cell itself: deciding which workgroup is first would need a grid-wide synchronisation, the very thing these strategies avoid. So the compiler records the requirement in the kernel's `.metacrisp`, on the output parameter:

```lisp
(:name "out" :type out-c :direction :out ... :launch-init (:identity 0.0))
```

The value is the reduction's identity as a number (`(type-max float)` is written out as `3.4028235e38`), `:infinity` / `:-infinity` for `(type-infinity T)`, or `(:identity-form "...")` when the identity is not a constant the compiler can see. The annotation is only possible when the return cell is the kernel's own parameter; otherwise the compiler logs a warning.

An implicit `:atomic-counter` must be zero before the **first** launch only; the generated host code arranges that. A counter you pass yourself is your responsibility, once.

### `grid-reduce-atomic!` ✅

`(grid-reduce-atomic! someFunction <someVar> identity return-cell &key local-scratch-vec message)`

`grid-reduce-atomic!` is the "dead simple" single-pass inter-workgroup reduction. It first reduces the variable locally using `reduce-workgroup` (Phase 1), and then the leader thread of each workgroup safely accumulates its partial result into the global `return-cell` using a native hardware atomic operation (Phase 2).

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
* `return-cell`: A `:global` cell of `<someVar>`'s type where the final value is accumulated (a length-1 vector is also accepted). It is accumulated *into*, not written, so it should start at the identity.
* `:local-scratch-vec`: Writeable local memory used for the Phase 1 `reduce-workgroup` sweep, one
  element per warp in the workgroup (`:match-num-warps-per-workgroup` sizes it for you).
  Optional, like every scratch argument here: if you leave it out, Crisp allocates it for you,
  typed from the identity (see *Full Reductions Made Easy* below).
* `:message`: (Optional, reserved) Accepted, but not yet attached to the implicit allocations.

**Post-Conditions & Return:**

* **Variable State:** After the operation, the value of `<someVar>` in any thread is indeterminate.
* **Memory State:** `return-cell` will hold the final global reduction.
* **Scratch State:** The state of `local-scratch-vec` is indeterminate.
* **Returns:** `nil`.



### `grid-reduce-cas!` ✅

`(grid-reduce-cas! someFunction <someVar> identity return-cell &key local-scratch-vec)`

`grid-reduce-cas!` is a single-pass grid reduction that works with *any* commutative binary operation. It first reduces the variable locally using `reduce-workgroup`, and then the leader thread of each workgroup uses a global Compare-And-Swap (CAS) loop via `atomic-binop!` to safely accumulate its partial result into `return-cell`.

**The Trade-off:**
This macro is the ultimate "low memory escape hatch." Unlike `grid-reduce-last-man!`, it requires zero global scratchpad memory. However, because every workgroup leader is trying to read, compute, and swap the exact same global address at the end of the kernel, it effectively serializes the grid into a massive traffic jam. One thread wins the CAS, while the others fail, loop, and try again. Use this only if your operation cannot use native atomics (`grid-reduce-atomic!`) AND you absolutely cannot afford the memory footprint of a global scratch buffer.

**Arguments:**

* `return-cell`: A `:global` cell of `<someVar>`'s type where the final value is accumulated (a length-1 vector is also accepted). It is accumulated *into*, not written, so it should start at the identity.
* `:local-scratch-vec`: Writeable local memory, one element per warp in the workgroup.
  Optional, like every scratch argument here: if you leave it out, Crisp allocates it for you,
  typed from the identity (see *Full Reductions Made Easy* below).

**Result:**
After the operation, the value of `<someVar>` in any thread is indeterminate. `return-cell` will hold the final global reduction.


### `grid-reduce-last-man!` ✅

`(grid-reduce-last-man! someFunction <someVar> identity return-cell &key local-scratch-vec global-scratch-vec atomic-counter election-flag-cell message)`

`grid-reduce-last-man!` is usually the fastest, most flexible single-pass grid reduction available. It works with *any* commutative binary operation without incurring the massive contention penalty of a global Compare-And-Swap loop, and without the scheduling overhead of launching a second "continuation" kernel.

**Mechanics:**
It accomplishes this via a cooperative finish.

1. **Phase 1:** Every workgroup reduces its threads locally using `reduce-workgroup`.
2. **Phase 2:** The leader thread of each workgroup writes its partial result into its `global-scratch-vec`, fences, and then increments a global `atomic-counter` -- store, fence, signal, in that one thread's program order (the release). Only the leader fences: the other threads published nothing.
3. **The Sweep:** The workgroup that increments the counter to `num_workgroups - 1` knows it is the *last* one to finish. Each of its threads fences once (the acquire), then that final workgroup reads the `global-scratch-vec` -- each of its threads folding partials `lid`, `lid + local_work_size`, `lid + 2*local_work_size`, ... so any number of workgroups is covered -- and performs one final `reduce-workgroup` to calculate the ultimate answer.

**The Trade-off:**

* **Pros:** Works with *any* commutative operation (unlike `grid-reduce-atomic!`). Zero contention on the final result cell. Requires only a single kernel launch.
* **Cons:** Requires allocating a global scratch buffer sized to the number of workgroups, plus a secondary atomic counter cell. Any number of workgroups: the final sweep is strided -- each thread of the last workgroup folds every `local_work_size`-th partial before the closing `reduce-workgroup` -- so its order is fixed by the grid and the result is reproducible run to run.

**Arguments:**

* `someFunction`: Any commutative `binop-type` `#(T T => T)`.
* `<someVar>`: The local variable being reduced.
* `identity`: The identity value for `someFunction`.
* `return-cell`: A `:global` cell of `<someVar>`'s type (a length-1 vector is also accepted). Last-man *writes* it, so it needs no initial value.
* `:local-scratch-vec`: Writeable local memory, one element per warp in the workgroup.
* `:global-scratch-vec`: Writeable **`:global`** memory, one element per WORKGROUP
  (`global_work_size / local_work_size`), holding the partials -- `:match-num-workgroups` when you
  allocate it yourself, which is also how Crisp sizes it when you leave it out.  A shorter buffer
  would be written past its end; under `--runtime-checks` the kernel refuses to run instead.
* `:atomic-counter`: A zero-initialised `:global` `uint` cell, used to draw tickets.
* `:election-flag-cell`: A **workgroup-local** `uint` cell, which broadcasts the ticket result from
  thread 0 to the rest of its workgroup.  It is what lets the LOSING workgroups retire
  immediately instead of sweeping a buffer whose result they would discard -- the early
  retirement that is this strategy's whole advantage over a second kernel launch.  It is always
  `uint`, never the reduction's element type, so it does not follow `<someVar>`.
  Optional, like every scratch argument here: if you leave it out, Crisp allocates it for you,
  typed from the identity (see *Full Reductions Made Easy* below).
* `:message`: (Optional, reserved) Accepted, but not yet attached to the implicit allocations.

**Post-Conditions & Return:**

* **Variable State:** After the operation, the value of `<someVar>` in any thread is indeterminate.
* **Memory State:** `return-cell` will hold the final global reduction.
* **Scratch State:** The state of all three scratch buffers is indeterminate.
* **Returns:** `nil`.



### `grid-reduce-second-stage!` ✅

`(grid-reduce-second-stage! someFunction <someVar> identity in-scratch-vec return-cell &key local-scratch-vec)`

`grid-reduce-second-stage!` is designed exclusively for the final sweep of a dual-pass reduction. It is meant to be called inside a continuation kernel launched with a single workgroup. It reads the partial results from `in-scratch-vec` (populated by Kernel 1), reduces them, and stores the ultimate answer in `return-cell`.

**Special Constraints:**
This macro executes an assertion ensuring it is launched with exactly one workgroup (`num_groups == 1`), and that the `local_work_size` is large enough to handle the number of elements in `in-scratch-vec`.

**Arguments:**

* `someFunction`: Any commutative `binop-type` `#(T T => T)`.
* `<someVar>`: A local binding to hold the intermediate calculations.
* `identity`: The identity value for `someFunction`.
* `in-scratch-vec`: The `:global` vector containing the partial results from the first kernel pass.
* `return-cell`: A `:global` cell of `<someVar>`'s type that receives the final value (a length-1 vector is also accepted).
* `:local-scratch-vec`: Writeable local memory used for the final sweep, one element per warp in
  the workgroup.
  Optional, like every scratch argument here: if you leave it out, Crisp allocates it for you,
  typed from the identity (see *Full Reductions Made Easy* below).

**Post-Conditions & Return:**

* **Memory State:** `return-cell` will hold the final global reduction.
* **Returns:** `nil`.



### `Strategy D: Cooperative Grid Sync (Hardware Dependent)`

On specific modern architectures (such as Nvidia GPUs supporting Cooperative Groups via PTX, or specific SPIR-V targets supporting Cross-Workgroup execution barriers), hardware-level grid synchronization is possible.

In a cooperative sync, workgroups perform Phase 1, write to the global scratchpad, and then hit a global execution barrier. Once the barrier drops, a single workgroup sweeps the global buffer.

* **Pros:** The "Holy Grail" of reductions. Single pass, highly performant, zero atomic contention.
* **Cons:** Hardware dependent. More critically, it carries a strict **Deadlock Risk**: the total grid size must fit entirely within the GPU's concurrent hardware capacity. If the grid requires preemption or swapping, the active workgroups will wait forever for pending workgroups that cannot launch.
* **Implementation:** *TBD (`grid-reduce-cooperative!`). Currently requires custom inline assembly or runtime-specific launch parameters to guarantee residency.*



## **Matchy Matchy: Putting it Together**

By combining Phase 1 and Phase 2, you create your algorithms.  Every grid-level construct runs its own
Phase 1 -- a `reduce-workgroup`, which is itself a warp shuffle followed by a shared-memory sweep -- and
must be reached by every thread, so in practice you choose the Phase 2 strategy:

**The Speed Demon:** `grid-reduce!` (its default, `:last-man-standing`)
One kernel, no contention on the result, any commutative function, any number of workgroups, and a
result that is the same bit for bit from run to run.

**The Easy Button:** `grid-reduce!` with `:strategy :atomic`
Summing (or taking the min or max of) a massive grid: no global scratch at all, at the cost of
contention on a single address.

And when one warp is all you need, `reduce-warp` alone is the fastest of all: registers only, no barriers.

## Full Reductions Made Easy: strategy

In most of the reduction interfaces we've seen so far there are requirements for local or global scratch memory, maybe an election cell. But Crisp has its implicit "side channel" scratch memory support. Those arguments are always optional and if elided Crisp will just ensure the kernel implicit parameter slots for them and pass them down to the call chain wherever they are needed.  This makes using the routines above a lot simpler.

There is one condition. Crisp sizes and types that scratch memory before it has analyzed your code, so it
takes the element type from the **identity**, which must already have the variable's type. When you let
Crisp allocate the scratch, write the identity so its type is visible on its face: a literal (`0`, `0.0`,
`0ul`, `1.5f`), `(type-min T)`, `(type-max T)`, `(type-infinity T)` or its negation, or a conversion such
as `(to-ulong x)`. An identity whose type cannot be seen (a variable, say), or whose type differs from
the variable being reduced (`0` for a `ulong`, where `0ul` is meant), is a compilation error. Passing
the scratch arguments yourself lifts the requirement.

Another thing Crisp can do to make things simpler is to simply elect a Phase 2 strategy by name.  We see this in `grid-reduce!`, and in the multi-variable and vector reductions below.

```
(def-enum reduction-strategy :atomic :last-man-standing :cas )
```

### `grid-reduce!` ✅
```
(grid-reduce! someFunction <someVar> identity return-cell
              &key strategy message
                   local-scratch-vec global-scratch-vec atomic-counter election-flag-cell)
```

`grid-reduce!` performs a `reduce-workgroup` on `<someVar>` as Phase 1, then uses `:strategy` for Phase 2, storing the final value in `return-cell`:

* `:strategy` is one of `:atomic`, `:cas` or `:last-man-standing`, and defaults to `:last-man-standing`. It must be written as a literal keyword, because it decides which construct the call becomes (`grid-reduce-atomic!`, `grid-reduce-cas!` or `grid-reduce-last-man!`); a value computed at run time is a compilation error. There is no second-stage strategy: that needs a second kernel launch, which one call cannot arrange -- use `grid-reduce-second-stage!` in the second kernel.
* `return-cell` is a `cell` of `<someVar>`'s type (a length-1 vector is also accepted). `:atomic` and `:cas` *accumulate* into it, so it should start at the identity; `:last-man-standing` *writes* it.
* Every scratch argument is optional and is allocated by Crisp when left out, typed from the identity (see the condition above). A scratch key the chosen strategy does not use is a compilation error: `:atomic` and `:cas` take only `:local-scratch-vec`.
* `:atomic` still requires an operator with a native hardware atomic (`#'+`, `#'min`, `#'max`).
* Autodiff works through `grid-reduce!`: it becomes one of the three constructs above, each of which has its own VJP. The exception is the dependent multi-variable form, which is not differentiable yet (see *Reducing Several Variables at Once*).

```
(grid-reduce! #'+ sumF 0.0f float-c :strategy :cas :message "gridwise reduction of sumF")
```






## **Reducing Several Variables at Once ✅**

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
out, Crisp generates it for you, typed from that clause's identity -- so, as above, each clause's
identity must have a visible type.

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

The combiner is checked against the clauses: with clause variables of types `T1 ... Tk`, it must be
`#'(T1 ... Tk T1 ... Tk => T1 ... Tk)`, and anything else is a compilation error that shows both the
signature the clauses need and the one the combiner has. Each combine step calls it once, with all
`k` values of both states.

**Autodiff through a dependent reduction needs one more function from you: a local VJP.** The variables
interact inside your combiner, so Crisp cannot derive the backward rule on its own. You declare it on the
combiner with `(declare (reduction-vjp f))`. Given *this thread's* contribution, the *result*, and the
result's adjoint, `f` returns this thread's adjoint:

```
#'(T1 ... Tk   T1 ... Tk   A1 ... Ak  =>  A1 ... Ak)
   own state   result      result         own adjoint
                           adjoint
```

`Ai` is the adjoint type of `Ti`: `double` for a `double`, and `float` for every other type, integers
included. An index has a `float` adjoint, though it is usually zero.

```lisp
(def-function argmax-combine (val-a idx-a val-b idx-b)
  (declare #'(float ulong float ulong => float ulong)
           (reduction-vjp argmax-local-vjp))          ; the one new line
  (if (or (> val-a val-b)
          (and (= val-a val-b) (< idx-a idx-b)))
      (return val-a idx-a)
      (return val-b idx-b)))

(def-function argmax-local-vjp (v i rv ri rv-bar ri-bar)
  (declare #'(float ulong float ulong float float => float float))
  ;; the winning thread takes the value's gradient; an index has none
  (if (= i ri)
      (return rv-bar 0.0)
      (return 0.0 0.0)))
```

Crisp does the rest. The backward pass recomputes the result and sums the result's adjoint over every
thread that holds it. It then calls `f` once per thread. Threads past `active-threads` get a zero
adjoint: your VJP cannot see `active-threads`, so it need not handle them. The VJP is checked against
the combiner and the clauses on every compile, not only under `--differentiate`, so a mismatch is
reported where you wrote it.

**The limitation:** a thread's adjoint must be computable from its own contribution and the result. That
covers the reductions people actually write:

* selections, such as argmax, argmin, max and min ("am I the winner?");
* sums, counts and means;
* moments and Welford-style variance;
* log-sum-exp (`exp(x - R)`);
* products (`R / x`, away from zero).

It fails only when the gradient needs something the result discarded, such as a runner-up. If you need
that, shape the state to keep it.

Without a `reduction-vjp`, differentiating through a dependent reduction is a compilation error that says
what to add. It is never a silently wrong gradient. Two cases are not differentiable yet, with or without
the declaration:

* a dependent `grid-reduce!` (reduce within the workgroup first);
* `:return-vec` in a dependent clause.

The independent form needs none of this: each of its clauses is differentiated on its own.

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

`:last-man-standing` is the default strategy.

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

  For floating-point types, `(type-min T)` and `(type-max T)` are the most negative and most
  positive *finite* values, in every precision context. (`(type-min float)` is about -3.4e38.
  It is not C's `FLT_MIN`, which is the smallest positive normal.) A finite identity is
  correct whenever the inputs are finite, and under `:fast` precision they must be: `:fast`
  lets the compiler assume that no value is ever infinite, so an infinite identity there is
  undefined. Under `:ieee`, if infinite inputs must win, use `(- (type-infinity T))` and
  `(type-infinity T)` instead. With a finite identity, any PADDING lane (one past `active-threads`,
  say) contributes `(type-min float)`, which beats an input that is all `-inf` -- so the reduction
  returns `(type-min float)`, and argmax reports the padding index.

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

* **NaN is not a state.** Under `:ieee`, every comparison involving a NaN is false, so a
  comparison-based combiner such as `argmax-combine` returns whichever state it was handed
  second. The combiner is then no longer commutative, and the result depends on scheduling. If
  the inputs can contain NaN, filter them out before the reduction, or handle them explicitly
  in the combiner.




## **The Vector API**

### `reduce-vec` ✅

Because reducing a whole vector is so common, Crisp provides a wrapper that writes the grid-stride
loop and the grid reduction for you:

```
(reduce-vec someFunction vec identity out-cell
            &key strategy message unroll
                 local-scratch-vec global-scratch-vec atomic-counter election-flag-cell)
```

Each thread folds its grid-stride share of `vec` into a private partial that starts at `identity`,
and the partials are then combined across the grid by `grid-reduce!` with the chosen `:strategy`.
A call means exactly this:

```lisp
(let ((partial identity))
  (loop-vector-stride vec (i)
    (set! partial (someFunction partial (~ vec i))))
  (grid-reduce! someFunction partial identity out-cell :strategy strategy ...))
```

* `someFunction`: a `binop-type` `#'(T T => T)`, commutative and associative (see below).
* `vec`: a **vector** (a rank-1 tensor) of `T`. Matrices and tensors are not flattened; passing
  one is a compilation error.
* `identity`: the identity of `someFunction`, of type `T` -- the vector's element type. A
  mismatch (`0.0` over an `int` vector) is a compilation error. When Crisp allocates the scratch
  for you, the identity's type must also be visible on its face, exactly as for `grid-reduce!`
  (see *Full Reductions Made Easy* above).
* `out-cell`: a `:global` cell of `T`, as for `grid-reduce!`. `:atomic` and `:cas` *accumulate*
  into it, so it should start at the identity; `:last-man-standing` *writes* it.
* `:strategy`: `:atomic`, `:cas` or `:last-man-standing` (the default), written as a literal
  keyword. There is no second-stage strategy: it needs a second kernel launch, which one call
  cannot arrange.
* The scratch keys and `:message` are passed straight through to `grid-reduce!`. Any scratch you
  leave out is allocated for you, and a key the chosen strategy does not use is a compilation
  error (`:atomic` and `:cas` take only `:local-scratch-vec`).
* `:unroll` belongs to the loop, not to `grid-reduce!`: `:unroll 2` puts `(declare (unroll 2))` at
  the start of the `loop-vector-stride` body. It takes what the declaration takes -- a positive
  integer, `t` or `nil` -- and without it the loop gets `loop-vector-stride`'s default (see
  [unroll](#unroll)).

**The grid does not have to match the vector.** That is the point of the stride: launch about as
many threads as the hardware runs at once, and each folds several elements. A thread that owns no
element at all contributes only the identity. Any grid works with every strategy, `:last-man-standing`
included: its partials are sized one per workgroup and its final sweep is strided.

`reduce-vec` is a grid-level operation, so it cannot be nested inside another grid-level stride.
Several calls in one kernel are fine, one after another; each gets its own scratch. It reduces one
vector with one function: to reduce several variables at once, write the stride loop yourself and
hand the partials to `grid-reduce!` with clauses (see *Reducing Several Variables at Once*).

**Autodiff** works through `reduce-vec` for the `#'+` reduction, under every strategy, exactly as
for `grid-reduce!`: d(out)/d(vec[i]) is d(out) for every element. `min`, `max` and custom functions
are a compilation error under `--differentiate`.

```lisp
;; Example: The "Easy Button" atomic strategy
(reduce-vec #'+ my-large-vector 0.0 result-cell :strategy :atomic)

;; Example: The flexible "Last Man Standing" strategy (the default) for custom operations
(reduce-vec #'my-custom-hash-combine my-large-vector 0u result-cell)

```

*(Note: all `reduce-vec` operations utilize `reduce-workgroup` as their Phase 1 under the hood).*

### **Binop-Type, Commutativity and Associativity ✅**

Whether you are shopping local or acting global, the `someFunction` you pass to these constructs must have a `binop-type` signature: `#'(T T => T)`.  (A dependent reduction's combiner is the k-value generalisation, `#'(T1 ... Tk T1 ... Tk => T1 ... Tk)`.)

Unlike reductions in some CPU languages, GPU reductions **guarantee neither the order nor the grouping** in which values are combined. Your operations must therefore be both **commutative** (`(someF a b)` equals `(someF b a)`) and **associative** (`(someF (someF a b) c)` equals `(someF a (someF b c))`). Addition, multiplication, min and max work; subtraction and division fail catastrophically.

Floating-point addition is only approximately associative, so a float sum can differ in its last bits from run to run. That is normal on GPUs, not a bug.

