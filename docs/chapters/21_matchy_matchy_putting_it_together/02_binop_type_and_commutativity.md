# **Binop-Type and Commutativity 📝**


Whether you are shopping local or acting global, the `someFunction` you pass to these macros must have a `binop-type` signature: `#(T T => T)`.

Unlike reductions in some CPU languages, GPU reductions **do not guarantee execution order**. Your operations *must* be commutative (where `(someF a b)` is equivalent to `(someF b a)`). Addition, multiplication, min, and max work perfectly. Subtraction and division will fail catastrophically.



