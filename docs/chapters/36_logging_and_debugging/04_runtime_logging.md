## Runtime Logging


### `r-t-workgroup-output-if`

`(r-t-workgroup-output-if <testExpression>  <expr1> ... <exprN>)`

If the kernel is compiled with the `--logging-output` flag then this macro will reduce 
`<testExpression>` across all the threads in a workgroup. If it is true in any of them,
then the the logging occurs in just one of them. Afterwards, kernel execution continues normally.

If the compiler flag is not elected, this entire form is compiled away. 

### `r-t-output`

```
(r-t-output <expr1> ... <exprN>)
(r-t-output-0 <expr1> ... <exprN>)
```
"r-t" stands for "run time".  If the kernel is compiled with the `--logging-output` flag then this macro will output
each of its expressions into the debug output memory. Note that this output will have to be retrieved by the hoisting 
code once the kernel is done executing. 
If the `--logging-output` flag is NOT present when the kernel is compiled, then this expression and all arguments
are simply skipped by the compiler. 

`r-t-output` is engaged by EVERY thread.  It is not screened or limited to a single workgroup.

In contrast, the variant `r-t-output-0` uses the `when-thread-is 0` guard and so the 
check and output is only performed in one thread.

#### WARNING - FIREHOSE
If `r-t-output` appears loose in your kernel, it could result in thousands of threads simultaneously
trying to dump strings into a debug buffer. Use the debugging subdivisions to control it (see [Debugging Implementation](#debugging-implementation)), or consider using `r-t-workgroup-output-if` instead, or 
surroud `r-t-output` in one of the thread guards.

```
(when-thread-is 0
   (r-t-output "reached midpoint" someVal))
```



