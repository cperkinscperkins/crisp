# Runtime Asserts


All runtime asserts go through `die`, so the thread, workgroup and site are always recorded.
Without `--runtime-checks` or `--logging-output` they compile away (see [Three Levels](#three-levels)).

#### `r-t-assert` ✅
```
(r-t-assert <testExpression>  <expr1> ... <exprN>)
(r-t-assert-0 <testExpression>  <expr1> ... <exprN>)
```

If `<testExpression>` is false, `die` is called.  Under `--logging-output` the remaining
expressions are first written to the log as one message (see [The Log](#the-log)).

`r-t-assert` is evaluated by EVERY thread.  `r-t-assert-0` is guarded by [`when-thread-is 0`](#when-thread-is--abs-when-thread-is) (global thread 0),
so the test and the message happen in one thread only.  Use it for conditions that are the
same for every thread: lengths, dispatch geometry.

Asserts don't suffer from the firehose problem: only the first death is recorded.  Their
messages, under `--logging-output`, do; see below.


