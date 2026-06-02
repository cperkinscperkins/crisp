# `def-kernel`


```
;; -- do_something --
(def-kernel do_something (i val VEC)
   ;; <type-declaration-here>
   (set! (~ VEC i) val)) ;; store val into index i of VEC
```
We'll discuss type declarations and type signatures later. For now, just understand that
`def-kernel` is how you define a kernel function that can be enqueued and invoked by some
host application.  The host application can only invoke kernels that you define, no other
functions.
Kernel functions
- accept arguments like a regular function (with a constrained set of available types)
- do not return values
- are not callable by other Crisp functions (see "continuation kernels" for exceptions)
- the body `progn` of the kernel function is a dispatch context
- can call both "thread level" functions and "grid level" functions.
- kernel function names (like "do_something" above) are restricted to C-style naming rules (ie "do_something" with an underscore is valid, but "do-something" with a dash is not).
- kernel function names are case sensitive - unlike nearly everything else in Crisp which is case insensitive.

