## check-divergence ⚠️


```
;; in a kernel or function progn:
(declare (check-divergence))

;; top level of file
(declaim (check-divergence #'some-function #'other-function))
```

While some divergence is unavoidable, sometimes you may write a function that you believe
should be completely uniform for all threads in a warp.

BUT, it is easy to overlook that some Crisp macros (for example, 'when-thread-id-is`) or
other behaviors may introduce divergence.

This check looks specifically for warp level divergence.
When this check is enabled,  the compiler analyzes all conditional branches (if, cond) inside the function. 
If it finds any branch whose condition is not a uniform value 
(i.e., the condition depends on something like get_lane_id or a non-uniform memory load), 
it will emit a warning.  It will emit a congratulatory note if it is ok.

<!-- NOTE
(declare (convergent)) can be used to declare a block as non-diverging, which will trip this error.
We use that declaration on potentially deadlocking calls.

reduce-to-warp  has it now.  Very important that reduce-to-warp is called by ALL the threads
in the warp, not just some.  

-->


