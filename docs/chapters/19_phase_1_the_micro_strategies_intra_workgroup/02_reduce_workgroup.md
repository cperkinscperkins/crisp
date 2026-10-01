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



