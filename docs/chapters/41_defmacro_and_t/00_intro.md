# `defmacro` and `T`


Remember that `defmacro` executes in a Common Lisp environment, not Crisp. And while it is
common in Crisp to use `T` as a template type placeholder (like in C++), in 
Common Lisp, `T` is reserved and means True.  If using `defmacro` over types, use `typ` or
something.




