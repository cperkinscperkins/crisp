# `reduce-warp` 📝


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

