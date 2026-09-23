# `grid-reduce-second-stage!` ✅


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
(defmacro grid-reduce-second-stage! (someFunction someVar identity in-scratch-vec return-vec 
                                     &optional (localScratchVec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup :msg message))
                                     &key message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
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
      (reduce-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,localScratchVec)
      
      ;; Thread 0 writes the ultimate answer
      (when-thread-in-group-is 0
        (set! (~ ,return-vec 0) ,someVar)))))

```


