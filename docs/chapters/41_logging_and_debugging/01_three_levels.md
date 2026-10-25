# Three Levels


The `r-t-` forms are free unless you ask for them. One rule covers all of them: **without a
flag, every `r-t-` form compiles away completely**. The test is not evaluated, and its
arguments are not evaluated either. As with C's `assert` under `NDEBUG`, any side effect in
an `r-t-` form disappears with it.

| compiled with | `r-t-assert`, `r-t-assert-0` | compiler bounds checks | `r-t-output`, `r-t-output-0` | `die` |
|---|---|---|---|---|
| (neither flag) | gone | gone | gone | halts, records its site |
| `--runtime-checks` | `(unless <test> (die))` -- runtime values dropped, strings kept | on | gone | halts, records its site |
| `--logging-output` | as above, plus the message goes into the log | on | written to the log | halts, records its site, and its message goes into the log |

`--logging-output` implies `--runtime-checks`.

`die` is different from the rest: it is a statement you wrote, not an `r-t-` form, so it is
compiled at every level.

Under `--differentiate`, `--logging-output` is ignored: the gradient kernels are compiled without
the log.  `--runtime-checks` still applies.


