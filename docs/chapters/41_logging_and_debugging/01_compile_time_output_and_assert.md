# Compile Time Output and Assert ✅


#### `c-t-output`  ✅

`(c-t-output <expr1> ... <exprN>)`
"c-t" stands for "compile time".  This variadic macro just takes a series of expressions and it will evaluate them at compile time and output them when compiling.   This can be particularly handy when used with `macroexpand` or `macroexpand-1`. A space character is inserted between each expression. If any of the expressions is
not evaluable at compile time that will merely be noted. 

#### `c-t-assert` ⚠️

> **Implementation status**: enforced at top level.  Inside a function body the assertion is currently **not evaluated** (BUG 114), so a false test there compiles silently.


`(c-t-assert <testExpression>  <expr1> ... <exprN>)`
This is akin to `static_assert` from C. The `<testExpression>` will be evaluated by the compiler. If it is true then
the compilation continues undisturbed.  But if it is false, then the compiler errors and ceases commpilation. The remaining arguments are output along with the error, separated by spaces. If one of the remaining expressions is
not evaluable at compile time that'll be noted in the output. 

If `<testExpression>` is not evaluable at compile time, it will lead to a compilation error.



