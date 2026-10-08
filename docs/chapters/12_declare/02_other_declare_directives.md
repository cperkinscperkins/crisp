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

#### unroll ✅
```
(dotimes (k n)
  (declare (unroll 4))        ; unroll by 4 -- a remainder loop handles n not a multiple of 4
  ...)

(dotimes (k 8)
  (declare (unroll t))        ; unroll fully -- the trip count must be a compile-time constant
  ...)

(loop-vector-stride v (i)
  (declare (unroll nil))      ; never unroll this loop, whatever the default
  ...)
```

The equivalent of `#pragma unroll` in CUDA, HIP and SYCL. It goes at the start of a loop body --
`dotimes` and its variants (`dotimes+`, `dec-times`, `do-times-by-doubling`, ...) or
`loop-vector-stride` -- and nowhere else. The value is a positive integer literal, `t` or `nil`.
Anything else, a second `unroll` on the same loop, or an `unroll` outside a loop body, is a
compilation error. It is the only declaration a loop body accepts.

Unrolling is a request to the code generator, not a change to the program: the loop computes the
same values, in the same order, with or without it, and autodiff sees the same loop. Crisp passes it
to LLVM as loop metadata (`llvm.loop.unroll.count` / `.full` / `.disable`), and LLVM does the
unrolling and writes the remainder loop. On PTX the factor is final, as with CUDA's `#pragma unroll`:
the loop LLVM unrolled is marked `.pragma "nounroll"`, so `ptxas` does not unroll it further, and
`(unroll nil)` keeps `ptxas` from unrolling it at all.

Why bother: a loop that does little work per trip -- a stream over a large vector -- is limited by
how many loads each thread has in flight, not by arithmetic. Unrolling it puts several independent
loads in flight per thread. On an Intel Arc B580, a `loop-vector-stride` sum went from 57% to 99%
of the memory bus from unrolling alone. The same request can hurt a heavy loop body (code size,
registers), which is why it is a knob. `loop-vector-stride` has a default; see
[loop-vector-stride](#loop-vector-stride).

