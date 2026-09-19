# `grid-reduce-last-man!` 📝


`(grid-reduce-last-man! someFunction <someVar> identity &out return-vec &optional localScratchVec globalScratchVec atomicCounter &key message)`

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
* `localScratchVec`: (Optional) Writeable local memory sized to the number of warps in the workgroup. Generated automatically if omitted.
* `globalScratchVec`: (Optional) Writeable global memory. Its size must equal the number of workgroups (`global_work_size / local_work_size`). Generated automatically if omitted.
* `atomicCounter`: (Optional) A single global memory cell (usually `:uint32`) initialized to 0, used to track completed workgroups. Generated automatically if omitted.
* `:message`: (Optional) String attached to auto-generated scratch allocations to inform the hoisting code.

**Post-Conditions & Return:**

* **Variable State:** After the operation, the value of `<someVar>` in any thread is indeterminant.
* **Memory State:** `return-vec[0]` will hold the final global reduction.
* **Scratch State:** The state of all three scratch buffers is indeterminant.
* **Returns:** `nil`.

**Possible Implementation:**

```lisp
;; -- grid-reduce-last-man! --
(defmacro grid-reduce-last-man! (someFunction someVar identity return-vec
                                 &optional (localScratchVec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup :msg message))
                                           (globalScratchVec (make-scratch-vector (type-of someVar) :match-num-workgroups :address-space :global :msg message))
                                           (atomicCounter (make-scratch-cell :uint32 :address-space :global :msg message))
                                 &key message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (is-type-of someVar (element-type return-vec)) "type mismatch between someVar and return-vec")

  `(progn
     (declare (grid-level))
     (r-t-assert-0 (<= (get-num-groups) (get-local-work-size)) "number of groups cannot be larger than local_work_size for grid-reduce-last-man!")
     
     ;; Phase 1: Micro Strategy (Intra-Workgroup)
     (reduce-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,localScratchVec)

     ;; Phase 2: Macro Strategy (Inter-Workgroup)
     (let ((group-id (get-group-id))
           (num-groups (get-num-groups)))
       
       (when-thread-in-group-is 0
         ;; 1. Store this WG's partial result
         (set! (~ ,globalScratchVec group-id) ,someVar)
         
         ;; 2. Ensure memory is globally visible before incrementing counter
         (memory-barrier :global)
         
         ;; 3. Increment counter to signal this WG is done
         ;; atomic-add! returns the value *before* addition
         (let ((ticket (atomic-add! (~ ,atomicCounter 0) 1)))
           ;; Flag the scratchpad if we are the final workgroup
           (set! (~ ,localScratchVec 0) (if (= ticket (- num-groups 1)) 1 0))))
           
       (sync-workgroup)
       
       ;; The Last Man Standing Sweep
       (when (= (~ ,localScratchVec 0) 1)
         (let ((local-id (get-local-id))
               ;; Fetch partials. Inactive threads get the identity.
               (val (if (< local-id num-groups) 
                        (~ ,globalScratchVec local-id) 
                        ,identity)))
             
             ;; Phase 3: Final reduction by the last workgroup
             (reduce-workgroup ,someFunction val ,identity :local-scratch-vec ,localScratchVec)
             
             ;; Thread 0 of the last workgroup writes the ultimate answer
             (when-thread-in-group-is 0
               (set! (~ ,return-vec 0) val)))))))

```

