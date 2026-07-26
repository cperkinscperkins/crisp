# Argument Passing and Side Channels ✅


As a general rule, GPU Kernels cannot allocate dynamic memory. This means that the host has to allocate 
and prepare ALL the memory a GPU kernel might need. The host needs to prepare the memory that will receive the result
of the operation. The host will also need to prepare memory for any scratch/intermediate operations the kernel might need.

The normal practice is that the kernel function has its parameter list for incoming arguments and everything the kernel
needs is present in its calling interface, and it passes those arguments down to subfunctions, as appropriate. 


There are two specialized categories of Crisp constructs that can help with this: `make-scratch-XXXX` and `make-implicit-XXXX` (where `XXXX` names a type of Storage Handle )  These operations, discussed in detail below, allow you to "pretend" to allocate memory
in your  kernel.   Each invocation of `make-implicit-XXXX` results in an extra allocation of memory appearing in the example
hoisting code, with a matching pointer passed implicitly as a kernel argument. Uses of `make-scratch-XXXX` are collected
by the compiler and are combined into a single scratch memory pool, which is similarly added as an implicit kernel argument.  These are conveniences.  The compiler calculates the size requirements for these and outputs them to the hoisting example code, but it's ultimately up to your final hoisting code to ensure the memory is sufficient.

Another side channel that adds implicit kernel arguments is the debugging communication channel, which can be enabled during compilation.

Lastly, if the data is constant and known at compile time then `def-constant-vector` and `use` would be better choices. 
These are also discussed below.

Side channels introduce side effects into functions that would otherwise be referentially transparent. For this reason, it's often better to avoid them. Many users choose to explicitly declare all their required memory in the kernel parameter list and pass it to sub-functions rather than introducing this impurity. Crisp supports both formulations. 


