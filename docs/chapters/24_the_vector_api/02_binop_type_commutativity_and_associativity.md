# **Binop-Type, Commutativity and Associativity ✅**


Whether you are shopping local or acting global, the `someFunction` you pass to these constructs must have a `binop-type` signature: `#'(T T => T)`.  (A dependent reduction's combiner is the k-value generalisation, `#'(T1 ... Tk T1 ... Tk => T1 ... Tk)`.)

Unlike reductions in some CPU languages, GPU reductions **guarantee neither the order nor the grouping** in which values are combined. Your operations must therefore be both **commutative** (`(someF a b)` equals `(someF b a)`) and **associative** (`(someF (someF a b) c)` equals `(someF a (someF b c))`). Addition, multiplication, min and max work; subtraction and division fail catastrophically.

Floating-point addition is only approximately associative, so a float sum can differ in its last bits from run to run. That is normal on GPUs, not a bug.

