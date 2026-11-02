# max-registers / warn-max-registers ✅


```
;; in a kernel:
(declare (max-registers 64))
(declare (warn-max-registers 64))
```

This analysis cannot be elected in `declaim`. It is kernel specific: on a function that is not a
kernel it is refused, because a function is compiled into the kernel that calls it. The value is a
positive integer literal, in registers per thread.

`max-registers` and `warn-max-registers` are advanced checks. These checks are slightly 
easier to use if you have performed compilations already
and are looking at the register usage enumerated in the metadata file. 

These checks set a "performance budget" that sets an upper bound on how many registers a kernel requires.
The compiler can estimate how many registers a kernel will require. If its estimate exceeds
the declared budget, a warning is issued. The estimate counts only what the kernel explicitly
reserves, such as `wgmma` accumulators, so a kernel can exceed its budget without a warning.

For example:

> WARNING: Register pressure for 'my_kernel' is estimated at 72, exceeding the declared budget of 64. 
> This may lead to reduced occupancy.


For `warn-max-registers`, there is only the warning emitted, no other change occurs.

`max-registers`, on the other hand, is NORMATIVE. In addition to the warning, 
the compiler will TRY TO FIT the kernel 
to `max-registers`, which may mean that other variables will experience "register spill"
and be moved to local memory. Only use `max-registers` if you know what you are about.

On PTX it becomes the entry's `.maxnreg`, and ptxas does the fitting. If the kernel cannot fit,
because a `wgmma` accumulator alone needs more registers than the budget, ptxas refuses it when the
kernel is loaded. On SPIR-V there is no such limit, so it compiles with a warning and has no effect.

**You rarely need this to make a kernel launch.** A GPU refuses a kernel whose registers per thread,
times its threads per workgroup, do not fit on one compute unit. At 256 threads or fewer that limit
cannot be reached. Above 256, a kernel with a compile-time `(local-size :set-to ...)` tells ptxas
its workgroup size with `.maxntid`, and ptxas keeps the kernel under the true limit, for example 168
registers at 288 threads. `max-registers` is for a kernel above 256 threads whose workgroup size is not
fixed at compile time, or for setting a tighter budget on purpose. When a kernel still cannot launch,
the hoisted harness prints the error, says what to do about it, and stops.


