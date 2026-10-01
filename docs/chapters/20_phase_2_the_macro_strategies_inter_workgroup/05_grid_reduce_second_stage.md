# `grid-reduce-second-stage!` ✅


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



