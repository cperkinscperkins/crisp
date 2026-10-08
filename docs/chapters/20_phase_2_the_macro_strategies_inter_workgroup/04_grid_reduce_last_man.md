# `grid-reduce-last-man!` ✅


`(grid-reduce-last-man! someFunction <someVar> identity return-cell &key local-scratch-vec global-scratch-vec atomic-counter election-flag-cell message)`

`grid-reduce-last-man!` is usually the fastest, most flexible single-pass grid reduction available. It works with *any* commutative binary operation without incurring the massive contention penalty of a global Compare-And-Swap loop, and without the scheduling overhead of launching a second "continuation" kernel.

**Mechanics:**
It accomplishes this via a cooperative finish.

1. **Phase 1:** Every workgroup reduces its threads locally using `reduce-workgroup`.
2. **Phase 2:** The leader thread of each workgroup writes its partial result into its `global-scratch-vec`, and then increments a global `atomic-counter`.
3. **The Sweep:** The workgroup that increments the counter to `num_workgroups - 1` knows it is the *last* one to finish. That final workgroup immediately reads the `global-scratch-vec` -- each of its threads folding partials `lid`, `lid + local_work_size`, `lid + 2*local_work_size`, ... so any number of workgroups is covered -- and performs one final `reduce-workgroup` to calculate the ultimate answer.

**The Trade-off:**

* **Pros:** Works with *any* commutative operation (unlike `grid-reduce-atomic!`). Zero contention on the final result cell. Requires only a single kernel launch.
* **Cons:** Requires allocating a global scratch buffer sized to the number of workgroups, plus a secondary atomic counter cell. Any number of workgroups: the final sweep is strided -- each thread of the last workgroup folds every `local_work_size`-th partial before the closing `reduce-workgroup` -- so its order is fixed by the grid and the result is reproducible run to run.

**Arguments:**

* `someFunction`: Any commutative `binop-type` `#(T T => T)`.
* `<someVar>`: The local variable being reduced.
* `identity`: The identity value for `someFunction`.
* `return-cell`: A `:global` cell of `<someVar>`'s type (a length-1 vector is also accepted). Last-man *writes* it, so it needs no initial value.
* `:local-scratch-vec`: Writeable local memory, one element per warp in the workgroup.
* `:global-scratch-vec`: Writeable **`:global`** memory, one element per WORKGROUP
  (`global_work_size / local_work_size`), holding the partials -- `:match-num-workgroups` when you
  allocate it yourself, which is also how Crisp sizes it when you leave it out.  A shorter buffer
  would be written past its end; under `--runtime-checks` the kernel refuses to run instead.
* `:atomic-counter`: A zero-initialised `:global` `uint` cell, used to draw tickets.
* `:election-flag-cell`: A **workgroup-local** `uint` cell, which broadcasts the ticket result from
  thread 0 to the rest of its workgroup.  It is what lets the LOSING workgroups retire
  immediately instead of sweeping a buffer whose result they would discard -- the early
  retirement that is this strategy's whole advantage over a second kernel launch.  It is always
  `uint`, never the reduction's element type, so it does not follow `<someVar>`.
  Optional, like every scratch argument here: if you leave it out, Crisp allocates it for you,
  typed from the identity (see *Full Reductions Made Easy* below).
* `:message`: (Optional, reserved) Accepted, but not yet attached to the implicit allocations.

**Post-Conditions & Return:**

* **Variable State:** After the operation, the value of `<someVar>` in any thread is indeterminate.
* **Memory State:** `return-cell` will hold the final global reduction.
* **Scratch State:** The state of all three scratch buffers is indeterminate.
* **Returns:** `nil`.



