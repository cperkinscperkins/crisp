# Other `declare` directives


#### `use` 📝
`(declare (use +image-mask+))`
<!-- 
NOTE: should we constrain `use` to ONLY be in def-kernel or def-const-vec ?
  It'd make the compiler's job easier.
  Would it make the users code clearer?
  Having it be usable by any sub-function is actually pretty convenient. Being
  able to call an image convolution and not worry that it needs some luminosity mask
  at the kernel level is nice.  
-->
`use` can appear in funciton or `let` contexts, but it is mostly used with `def-kernel` or 
`def-const-vec`.  It simply declares that some context depends on a constant memory storage item.
See [def-const-vec](#def-const-vec)

#### kernel-name 📝
`(declare (kernel-name "some_name_${T}"))`
Used in `let-kernel` to name a continuation kernel.  See [Continuation Kernels](#continuation-kernels)

#### single-task 📝
`(declare (single-task))`

Communicates back to the hoisting code that this kernel should be run on only one thread. Used in `def-kernel`

#### entrypoint 📝
`(declare (entrypoint))`

For library writers. See the [entrypoint](#entrypoint-1) section

