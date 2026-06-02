# check-coalesce ⚠️


```
;; in a kernel or function progn:
(declare (check-coalesce))  

;; top level of a file.
(declaim (check-coalesce #'some-function))
```

Coalesced memory access is faster than just random memory access. But it requires
- warp-level operation: access to be performed by threads in a single warp
- uniform: all threads execute the same load or the same store instruction at the same time
- contiguous and linear access - the threads' memory addresses should be adjacent and follow
  the same order as the thread id.

The compiler can check for this.  If you put a `check-coalesce` in a kernel or functions `declare` block,
or specify the kernel/function in a top level `declaim`, then this check will be performed
and a warning emitted if the function in question is not using coalesced access and a note if it is ok.


