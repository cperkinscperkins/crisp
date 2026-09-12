# check-barriers 📝


```
;; in a kernel or function progn:
(declare (check-barriers))

;; top level of file
(declaim (check-barriers #'some-function #'other-function))
```

If a `(sync-workgroup)` is placed inside a conditional branch that not all threads in a workgroup will execute, the kernel will deadlock.
Crisp performs this check automatically for any use of `when-thread-in-group-is`, whether this check has been elected or not.
But with this check declared, Crisp will try to analyze other thread divergences and barriers looking for deadlock potential.

`check-barriers` will examine the Crisp branching control flow constructs (like `if` and `cond` etc) to 
see if perhaps a barrier is performed in one branch but not another, and warn about it.  


