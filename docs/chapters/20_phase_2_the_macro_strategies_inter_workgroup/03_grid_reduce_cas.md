# `grid-reduce-cas!` ✅


`(grid-reduce-cas! someFunction <someVar> identity return-cell &key local-scratch-vec)`

`grid-reduce-cas!` is a single-pass grid reduction that works with *any* commutative binary operation. It first reduces the variable locally using `reduce-workgroup`, and then the leader thread of each workgroup uses a global Compare-And-Swap (CAS) loop via `atomic-binop!` to safely accumulate its partial result into `return-cell`.

**The Trade-off:**
This macro is the ultimate "low memory escape hatch." Unlike `grid-reduce-last-man!`, it requires zero global scratchpad memory. However, because every workgroup leader is trying to read, compute, and swap the exact same global address at the end of the kernel, it effectively serializes the grid into a massive traffic jam. One thread wins the CAS, while the others fail, loop, and try again. Use this only if your operation cannot use native atomics (`grid-reduce-atomic!`) AND you absolutely cannot afford the memory footprint of a global scratch buffer.

**Arguments:**

* `return-cell`: A `:global` cell of `<someVar>`'s type where the final value is accumulated (a length-1 vector is also accepted). It is accumulated *into*, not written, so it should start at the identity.
* `:local-scratch-vec`: Writeable local memory, one element per warp in the workgroup.
  Optional, like every scratch argument here: if you leave it out, Crisp allocates it for you,
  typed from the identity (see *Full Reductions Made Easy* below).

**Result:**
After the operation, the value of `<someVar>` in any thread is indeterminate. `return-cell` will hold the final global reduction.


