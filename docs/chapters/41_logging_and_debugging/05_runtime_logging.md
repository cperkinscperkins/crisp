# Runtime Logging 📝


#### `r-t-output` 📝

```
(r-t-output <expr1> ... <exprN>)
(r-t-output-0 <expr1> ... <exprN>)
```
"r-t" stands for "run time".  Under `--logging-output` each call writes one message, made of
its expressions, into the log.  Without the flag the form and its arguments are compiled away.

Strings must be compile-time strings.  Everything else must be a scalar.

`r-t-output` is engaged by EVERY thread.  `r-t-output-0` is guarded by `when-thread-is 0`.

##### WARNING - FIREHOSE
A loose `r-t-output` in a kernel means every thread writes a message, possibly millions of
them.  The log is first-come-first-served and simply stops accepting messages when it is full
(see below), so nothing breaks, but the first messages to arrive may not be the ones you
want.  Choose who logs by putting the call inside a guard:

```
(when-thread-is 0
   (r-t-output "reached midpoint" someVal))

(when-thread-in-group-is 0                         ;; one message per workgroup
   (r-t-output "group total" total))

(when (= (get-workgroup-id 0) 42)                  ;; focus on ONE workgroup
   (r-t-output "wg 42 sees" (~ in (get-local-id 0))))
```

Guards are ordinary Crisp and are decided where you can see them.  Earlier versions of this
section moved these choices into compiler flags (`--logging-scope`, `--logging-target`,
`--logging-wg-index`, `--logging-warp-index`, `--logging-by-call-site`, `--logging-mode`); those
flags have been dropped.  So have `r-t-workgroup-assert` and `r-t-workgroup-output-if` (a guard
around a workgroup reduction does the same job), and "last-N" circular logging.  Any of them can
come back if a real need shows up.


