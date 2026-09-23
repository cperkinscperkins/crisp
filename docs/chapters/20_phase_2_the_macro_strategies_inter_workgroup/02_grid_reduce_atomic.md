# `grid-reduce-atomic!` ✅


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
(defmacro grid-reduce-atomic! (someFunction someVar identity return-vec
                               &optional (localScratchVec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup :msg message))
                               &key message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (is-type-of someVar (element-type return-vec)) "type mismatch between someVar and return-vec")
  (c-t-assert (or (= someFunction #'+) (= someFunction #'min) (= someFunction #'max)) "only #'+, #'min or #'max are accepted operations for grid-reduce-atomic!")

  `(let ((atomic-op (get-atomic-equivalent ,someFunction)))
     (declare (grid-level))
    
    ;; Phase 1: Micro Strategy (Intra-Workgroup)
    (reduce-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,localScratchVec)

    ;; Phase 2: Macro Strategy (Inter-Workgroup)
    ;; Global atomic combination using native hardware atomics
    (when-thread-in-group-is 0
      (funcall atomic-op (~ ,return-vec 0) ,someVar)))) 

```

