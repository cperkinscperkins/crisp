## `def-function`

```
;; -- do-add --
(def-function do-add (x y)
   ;; <type-declaration-here>
   (+ x y)) ; return the sum of x and y
```
`def-function` defines a function, just like you would do in nearly every other programming
language. Functions take arguments and return values, they have mandatory type declarations (see below).
The functions that are defined are "thread level" functions, meaning they are expected to operate in the context
of a single thread and not orchestrating the operation of all threads generally.

Thread level functions
- accept arguments, including higher order function args
- CAN return values
- the body of these functions are a "thread level context"
- can call other thread level functions
- but CANNOT call "grid level" functions or use grid level macros
- can use Lisp-style naming rules. (dashes ok in function names, case insensitive)

