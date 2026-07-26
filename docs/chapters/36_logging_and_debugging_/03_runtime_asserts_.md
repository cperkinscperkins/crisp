# Runtime Asserts ⚠️


There are various asserts available at runtime. They are available if the debug output is enabled or not, but their behavior changes slightly.

The runtime asserts always evaluation their test expression.  If it is `true`, then
the kernel continues on unperturbed. If it is false, then `die` is called.

If logging output is on (via `--logging-output`)
then these asserts evaluate all their remaining expression arguments and output them into the relevant logging
buffer subdivision before calling die to terminate the kernel execution.

If debug output is NOT on, the assert still calls `(die)` on failure. 

These all use `die` underneath, so some amount of thread id and line numbers, etc are recorded.



#### `r-t-workgroup-assert` 📝

`(r-t-workgroup-assert <testExpression>  <expr1> ... <exprN>)`

Akin to `assert` in C. This macro will result in an evaluation of `<testExpression>`. If true, fine. The
kernel execution continues normally. But if if false, then it behaves like the assert behavior described above
and then terminates calling `die`.


Note that `<testExpression>` reduced across ALL the threads in a workgroup. If it is false in ANY of them,
then the assert behavior is tripped.  So `r-t-workgroup-assert` is protected from "firehose" problems.


#### `r-t-assert` ✅
```
(r-t-assert <testExpression>  <expr1> ... <exprN>)
(r-t-assert-0 <testExpression>  <expr1> ... <exprN>)
```

Behaves like the asserts described above.  Ultimately, will call `die` if `<testExpression>` is false.

`r-t-assert` is engaged by EVERY thread.  It is not screened or limited to a single workgroup.

In contrast, the variant `r-t-assert-0` uses the `when-thread-is 0` guard and so the 
check and output is only performed in one thread.

##### WARNING - FIREHOSE
If `r-t-assert` appears loose in your kernel, it could result in many threads simultaneously
trying to dump strings into a debug buffer. Use the debugging subdivisions to control it (see [Debugging Implementation](#debugging-implementation)), or consider using `r-t-workgroup-assert` instead, or `r-t-assert-0`, or
surroud `r-t-assert` in one of the other thread guards.

```
(when-thread-in-group-is 0
   (r-t-assert (< 0 lives) "no lives left"))
```

