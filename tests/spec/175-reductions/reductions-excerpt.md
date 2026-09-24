

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

**Possible Implementation:**

```lisp
;; -- reduce-warp --
(defmacro reduce-warp (someFunction someVar identity &optional (active-threads (get-warp-size)))
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  `(in-warp (lane-id)
    (declare (warp-convergent)) ;; <-- tells compiler cannot be called in divergent branch.
    
    ;; Active threads use their value. Inactive threads use the identity.
    (let ((val (if (< lane-id ,active-threads)
                    ,someVar
                    ,identity)))

      ;; Perform the full, unconditional reduction on 'val'.
      ;; The loop bounds are always based on the full warp size.
      (dec-times-by-half+ (s (/ (get-warp-size) 2))
        (set! val (funcall ,someFunction (shuffle-xor val s) val)))

      ;; Write the final result (from lane 0) back into someVar for all threads.
      (set! ,someVar (shuffle val 0)))))

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

**Possible Implementation:**

```lisp
;; -- reduce-workgroup --
(defmacro reduce-workgroup (someFunction someVar identity &key message 
                                                             (local-scratch-vec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup :msg message))
                                                             return-vec)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (if return-vec (is-type-of (element-type return-vec) (type-of someVar)) T) "type mismatch of return-vec and someVar")

  `(progn
    ; After this local-scratch-vec contains partial sum from each warp in the wg
    (declare (workgroup-level))
    (reduce-warp ,someFunction ,someVar ,identity)
    (when-thread-in-warp-is 0
      (set! (~ ,local-scratch-vec (get-warp-id)) ,someVar))
    (sync-workgroup)

    ; inter warp reduction
    (let ((num-warps (ceil (get-local-work-size) (get-warp-size)))
          (local-id (get-local-id)))
        ; Only a subset of threads needed for this phase.
        (when (< local-id num-warps)
          ; The loop iterates s => num_warps/2, num_warps/4, ... , 1
          (dec-times-by-half (s (floor num-warps 2))
            ; The first 's' threads are active in this pass.
            (when (< local-id s)
              (let ((partner-idx (+ local-id s)))
                ; Each active thread combines its value with its partner's.
                (set! (~ ,local-scratch-vec local-id)
                      (funcall ,someFunction
                              (~ ,local-scratch-vec local-id)
                              (~ ,local-scratch-vec partner-idx))))))
          ; barrier needed between each pass 
          (sync-workgroup)))

      ; The final result is in local-scratch-vec[0]. Load it to thread 0
      (when-thread-in-group-is 0
        (set! ,someVar (~ ,local-scratch-vec 0))
        (when ,return-vec (set! (~ ,return-vec (get-group-id)) ,someVar)))
      
      ; broadcast to entire workgroup
      (when-thread-in-group-is 0
        (set! (~ ,local-scratch-vec 0) ,someVar))
      (sync-workgroup)
      
      (set! ,someVar (~ ,local-scratch-vec 0))))

```

---

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

**Possible Implementation:**


```lisp
;; -- grid-reduce-atomic! --
(defmacro grid-reduce-atomic! (someFunction someVar identity return-vec &key local-scratch-vec message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (is-type-of someVar (element-type return-vec)) "type mismatch between someVar and return-vec")
  (c-t-assert (or (= someFunction #'+) (= someFunction #'min) (= someFunction #'max)) "only #'+, #'min or #'max are accepted operations for grid-reduce-atomic!")
  (c-t-assert local-scratch-vec "local-scratch-vec is required and must be allocated by the caller")

  `(let ((atomic-op (get-atomic-equivalent ,someFunction)))
     (declare (grid-level))
    
    ;; Phase 1: Micro Strategy (Intra-Workgroup)
    (reduce-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,local-scratch-vec)

    ;; Phase 2: Macro Strategy (Inter-Workgroup)
    ;; Global atomic combination using native hardware atomics
    (when-thread-in-group-is 0
      (funcall atomic-op (~ ,return-vec 0) ,someVar)))) 

```


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

**Possible Implementation:**

```lisp
;; -- grid-reduce-cas! --
(defmacro grid-reduce-cas! (someFunction someVar identity return-vec &key local-scratch-vec message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (is-type-of someVar (element-type return-vec)) "type mismatch between someVar and return-vec")
  (c-t-assert local-scratch-vec "local-scratch-vec is required and must be allocated by the caller")
  
  `(progn
    (declare (grid-level))
    
    ;; Phase 1: Micro Strategy (Intra-Workgroup)
    (reduce-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,local-scratch-vec)

    ;; Phase 2: Macro Strategy (Inter-Workgroup)
    ;; Global atomic combination via Compare-And-Swap loop
    (when-thread-in-group-is 0
      (atomic-binop! (~ ,return-vec 0) ,someFunction ,someVar))))

```

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

**Possible Implementation:**

```lisp
;; -- grid-reduce-last-man! --
(defmacro grid-reduce-last-man! (someFunction someVar identity return-vec 
                                 &key local-scratch-vec global-scratch-vec atomic-counter election-flag-cell message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (is-type-of someVar (element-type return-vec)) "type mismatch between someVar and return-vec")
  (c-t-assert local-scratch-vec "local-scratch-vec is required and must be allocated by the caller")
  (c-t-assert global-scratch-vec "global-scratch-vec is required and must be allocated by the caller")
  (c-t-assert atomic-counter "atomic-counter is required and must be allocated by the caller")
  (c-t-assert election-flag-cell "election-flag-cell is required and must be allocated by the caller")

  `(progn
     (declare (grid-level))
     (r-t-assert-0 (<= (get-num-groups) (get-local-work-size)) "number of groups cannot be larger than local_work_size for grid-reduce-last-man!")
     
     ;; Phase 1: Micro Strategy (Intra-Workgroup)
     (reduce-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,local-scratch-vec)

     ;; Phase 2: Macro Strategy (Inter-Workgroup)
     (let ((group-id (get-group-id))
           (num-groups (get-num-groups)))
       
       (when-thread-in-group-is 0
         ;; 1. Store this WG's partial result
         (set! (~ ,global-scratch-vec group-id) ,someVar)
         
         ;; 2. Ensure memory is globally visible before incrementing counter
         (memory-barrier :global)
         
         ;; 3. Increment counter to signal this WG is done
         ;; atomic-add! returns the value *before* addition
         (let ((ticket (atomic-add! (~ ,atomic-counter 0) 1)))
           ;; Flag the dedicated election cell if we are the final workgroup
           (set! (~ ,election-flag-cell 0) (if (= ticket (- num-groups 1)) 1 0))))
           
       (sync-workgroup)
       
       ;; The Last Man Standing Sweep
       (when (= (~ ,election-flag-cell 0) 1)
         (let ((local-id (get-local-id))
               ;; Fetch partials. Inactive threads get the identity.
               (val (if (< local-id num-groups) 
                        (~ ,global-scratch-vec local-id) 
                        ,identity)))
             
             ;; Phase 3: Final reduction by the last workgroup
             (reduce-workgroup ,someFunction val ,identity :local-scratch-vec ,local-scratch-vec)
             
             ;; Thread 0 of the last workgroup writes the ultimate answer
             (when-thread-in-group-is 0
               (set! (~ ,return-vec 0) val)))))))

```


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

**Possible Implementation:**

```lisp
;; -- grid-reduce-second-stage! -- 
(defmacro grid-reduce-second-stage! (someFunction someVar identity in-scratch-vec return-vec &key local-scratch-vec message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert local-scratch-vec "local-scratch-vec is required and must be allocated by the caller")
  
  `(progn
    (declare (grid-level) (num-groups :max 1))
    
    (r-t-assert-0 (== (get-num-groups) 1) "grid-reduce-second-stage! must be launched with exactly one workgroup")
    (r-t-assert-0 (<= (length~ ,in-scratch-vec) (get-local-work-size)) "local_work_size must be >= the length of in-scratch-vec")

    (let ((num-items (length~ ,in-scratch-vec))
          (local-id (get-local-id)))
      
      ;; Load partials into the local variable. Inactive threads get the identity.
      (set! ,someVar (if (< local-id num-items)
                         (~ ,in-scratch-vec local-id)
                         ,identity))
                         
      ;; Perform a standard workgroup reduction
      (reduce-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,local-scratch-vec)
      
      ;; Thread 0 writes the ultimate answer
      (when-thread-in-group-is 0
        (set! (~ ,return-vec 0) ,someVar)))))

```


### `Strategy D: Cooperative Grid Sync (Hardware Dependent)`

On specific modern architectures (such as Nvidia GPUs supporting Cooperative Groups via PTX, or specific SPIR-V targets supporting Cross-Workgroup execution barriers), hardware-level grid synchronization is possible.

In a cooperative sync, workgroups perform Phase 1, write to the global scratchpad, and then hit a global execution barrier. Once the barrier drops, a single workgroup sweeps the global buffer.

* **Pros:** The "Holy Grail" of reductions. Single pass, highly performant, zero atomic contention.
* **Cons:** Hardware dependent. More critically, it carries a strict **Deadlock Risk**: the total grid size must fit entirely within the GPU's concurrent hardware capacity. If the grid requires preemption or swapping, the active workgroups will wait forever for pending workgroups that cannot launch.
* **Implementation:** *TBD (`grid-reduce-cooperative!`). Currently requires custom inline assembly or runtime-specific launch parameters to guarantee residency.*

---

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

### `grid-reduce` 📝
```
(grid-reduce someFunction <someVar> identity &out return-cell &key strategy message)
```

`grid-reduce` performs a `reduce-workgroup` on `<someVar>` as Phase 1, and then uses the `strategy` (which muust be from `reduction-strategy`) for the Phase 2 reduction, storing the final value in `return-cell` which should be a `cell` of the same type as `<someVar>`. 

```
(grid-reduce #'+ sumF 0.0f float-c :strategy :cas :message "gridwise reduction of sumF")
```



## Multiple Value Reductions

The reductions we've seen so far have all been for a single variable. But oftentimes you'll need 
to reduce to multiple values (like finding both the min and max value).  It could be quite
inefficient to schedule one reduction and then another. Crisp makes it easy to bind multiple reduction variables and reduce them all. These multiple value reductions break into the same "phases" like the single values. Phase 1 for warps or workgroups, and a full grid-wise Phase 2 where you elect a strategy. 

### `reduce-warp-multi` 📝

```
(reduce-warp-multi (<warp-instructions>...) &optional (active-threads (get-warp-size)))
;; where a warp-instruction is
(<Function> <variable> <identity>)   
```

Example: 
```
(reduce-warp-multi
  ((#'+   <sumVar> 0.0)
   (#'max <maxVar> -99.0)))
```

`reduce-warp-multi` will reduce multiple values simultaneously in the same reduction.

### `reduce-workgroup-multi` 📝

```
(reduce-workgroup-multi (<wg-instructions>...) &key message)
;; where a wg-instruction is
(<Function> <variable> <identity> &optional local-vec)
```

Example: 
```
(reduce-workgroup-multi
  ((#'+   <sumVar> 0.0)
   (#'max <maxVar> -99.0)))
```


 `local-vec`: (Optional) Writeable local memory used to bridge the warps. Its size must equal the number of warps in a single workgroup (`local_work_size / get-warp-size`). If omitted, Crisp will automatically generate this scratchpad for you.




 ### `reduce-grid-multi`

 ```
 (reduce-grid-multi  (<instructions> ...)  &key strategy message)
 ;; where an instruction is
(<Function> <variable> <identity> <result-cell> &optional local-vec)
 ```

 `result-cell` should be a cell of the same type as `<variable>`

```
 (reduce-grid-multi 
  ((#'+   sumVar 0.0  sumCell)
   (#'max maxVar -99.0 maxCell))
   :strategy :last-man-standing)
```

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

