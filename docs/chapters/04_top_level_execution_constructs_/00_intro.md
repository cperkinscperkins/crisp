# Top Level Execution Constructs ✅


In Crisp, nearly everything that can be put at the "top level" of a code file begins with "`def-`".  
There are a handful of exceptions (*), but that is the general rule. And every other Crisp expression
is then inside one of these definitions and cannot appear, unchaperoned, at the top level.
Of these "`def-`" expressions, there are three primary ones that serve as execution constructs:
 `def-kernel`, `def-function` and `def-grid-function`.

 (* Exceptions: `declaim`, `with-template-type`, `set-derived` )

