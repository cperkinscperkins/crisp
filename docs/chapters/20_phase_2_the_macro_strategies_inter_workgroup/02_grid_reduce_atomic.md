# `grid-reduce-atomic!` ✅


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



