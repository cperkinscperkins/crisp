# `grid-reduce-dual-pass!` 📝


`(grid-reduce-dual-pass! someFunction <someVar> identity continuation-kernel-name &optional globalScratchVec localScratchVec)`

`grid-reduce-dual-pass!` represents the traditional, highly safe approach to inter-workgroup reduction. Unlike the single-pass strategies, it physically splits the grid reduction across two separate kernel invocations to entirely avoid atomic contention or spinning locks.

**Mechanics:**
It performs Phase 1 of the reduction (`reduce-workgroup`) and stores each workgroup's partial result into a global scratch vector. Then, the macro automatically defines and hoists a brand new **continuation kernel** to handle Phase 2. This second kernel consists of a single workgroup that sweeps up the global scratch buffer and writes the final value to a result cell.

**The Trade-off:**

* **Pros:** Highly safe, works with *any* commutative operation, and involves absolutely zero atomic contention.
* **Cons:** Requires launching two separate kernels, incurring scheduling overhead. It also requires the host (or device graph) to manage the subsequent kernel execution.

**Special Compiler Constraints:**
Because this macro dynamically generates the AST for a completely separate continuation kernel, both `someFunction` and `identity` **must be compile-time identifiable**. The compiler will emit an error if it cannot resolve them at compile time.

Additionally, the continuation kernel will be hoisted with a different execution configuration from the parent kernel. Specifically, its `local_work_size` will be derived to be exactly the size of the `globalScratchVec`.

**Arguments:**

* `someFunction`: Any commutative `binop-type` `#(T T => T)`. (Must be known at compile time).
* `<someVar>`: The local variable being reduced.
* `identity`: The identity value for `someFunction`. (Must be known at compile time).
* `continuation-kernel-name`: A string or symbol used to name the generated Phase 2 kernel.
* `globalScratchVec`: (Optional) Writeable global memory. Its size must equal the number of workgroups. Crisp will generate it if omitted.
* `localScratchVec`: (Optional) Writeable local memory used for the Phase 1 sweep. Its size must equal the number of warps in a single workgroup. Crisp will generate it if omitted.

**Post-Conditions & Return:**

* **Variable State:** After the operation, the value of `<someVar>` in any thread is indeterminant.
* **Continuation Kernel Output:** The generated `continuation-kernel-name` will accept a single-element result cell as its final argument, where the ultimate answer will be stored.
* **Returns:** `nil` (but leaves a `launch-kernel` instruction in the AST for the hoisting code).

**Possible Implementation:**

```lisp
;; -- grid-reduce-dual-pass! --
(defmacro grid-reduce-dual-pass! (someFunction someVar identity continuation-kernel-name
                                  &optional (globalScratchVec (make-scratch-vector (type-of someVar) :match-num-workgroups :address-space :global))
                                            (localScratchVec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup))) 
   (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
   (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
   
   `(let-kernel ((continuation-k  (l-s-v g-s-v result-cell)
                  (declare (kernel-name ,continuation-kernel-name)
                           (type l-s-v (scratch-vec-type (type-of ,someVar)))
                           (type g-s-v (scratch-vec-type (type-of ,someVar) :global))
                           (type result-cell (cell (type-of ,someVar)))
                           (local-size :derive-from g-s-v :msg (string-concat ,continuation-kernel-name "requires a local_work_size at least as big as the global-scratch-vector")))
                      (let ((num-items (length~ g-s-v))
                            (local-id (get-local-id))
                            ;; Each thread in the workgroup loads one partial result.
                            ;; If there are more threads than items, inactive threads get the identity.
                            (val (if (< local-id num-items)
                                      (~ g-s-v local-id)
                                      ,identity)))
                        
                        ;; Perform a standard Phase 1 workgroup reduction on the partial results.
                        (reduce-workgroup ,someFunction val ,identity :local-scratch-vec l-s-v)
                        
                        ;; The final result is now in 'val' of all wg threads.
                        ;; To avoid contention, only thread 0 writes the final result to the output cell.
                        (when (= local-id 0)
                          (set! (~ result-cell) val))) ))

      (declare (grid-level))
      ;; Phase 1: Micro Strategy (Intra-Workgroup)
      ;; After reduce-workgroup, the globalScratchVec will contain one value per group.
      (reduce-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,localScratchVec :return-vec ,globalScratchVec)
      
       ;; This isn't a runtime invocation. It demonstrates to the hoisting code 
       ;; HOW this function expects the continuation kernel to be dispatched.
      (launch-kernel (continuation-k ,globalScratchVec ,localScratchVec (allocate-cell (type-of ,someVar)))))

```

