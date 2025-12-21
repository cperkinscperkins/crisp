## Differences From Lisp


While Crisp is an s-expression based language and shares with Common Lisp the very powerful `defmacro` 
construct as well as many other fundamentals ( `if`, `when` `cond`, `let` etc), there are 
marked differences between them.  

### no list data type.  

Crisp does not support the list data type. Nor cons cells. Nor linked lists. Internally, the compiler might be using
them to represent code, but there are no lists available to the Crisp developer.

### no ratios or bignums

Most Lisp and Scheme variants represent numbers in a numeric tower that include
ratios fully storing both numerator and denominator and more. Crisp has no such affordance.
In only exposes the numeric machine types that are availble on GPU hardware. 

### no dynamic memory or garbage collection

Scheme and Lisp implementations have implicit memory allocation and collection. Crisp does not.
It does have "Side Channels" which can be used for intermediate scratch memory and debug logging. To be discussed later.

### static typing, not dynamic

As already mentioned, Crisp is statically typed.  There is no runtime typing of any sort.

### 0 is false

Crisp follows Python and C++ and treats 0 as false.  In Common Lisp, which supports
dynamic typing, there are strong reasons for having 0 be true, but given that Crisp
doesn't support dynamic typing and its intended audience is likely more familiar
with CUDA, C++, Python and OpenCL C, Crisp follows their practice and 0 is false.

### no recursion

Crisp does not support recursive functions, nor mutual recursion. 

### no condition/restart system

Common Lisp has an EXCEPTIONALLY powerful system for handling errors with restarts and more. 
Crisp's has a modest (yet performant) `maybe` type to help catch and log errors with a
minimum of branch divergence.

### no eval

To many a 'REPL' (Read Eval Print Loop) is the most basic requirement to be considered
a Lisp. As Crisp targets GPU kernel (only) this is not possible. 

### no CLOS

The Common Lisp Object System is likely the most powerful object system ever designed.
Crisp has nothing comparable, but instead offers modest structs, derived types, and function overloading. 
These are simple and should be flexible enough to get things done.

### misc

`let` in Crisp is like `let*` in Common Lisp. Asterisk not needed.

`set!` in Crisp is like `setf` in Common Lisp. However, it does NOT return a value. 
You cannot shortcut set and return a value in the same expression.


