# `reduce-workgroup` ✅


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

