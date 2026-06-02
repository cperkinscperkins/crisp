# Compile Time Strings ✅


Most strings in Crisp are compile time. They follow the Common Lisp parsing rules
(which is mostly just begin and end with double quote. "Like Me!!" )

The are mostly output into the hoisting example code.

### `string-concat`

`(string-concat <Expr1> <Expr2> ... <ExprN>) => string`

`string-concat` can be used to string some things up. Each expression can
be a different "printable" type, which is either a numeric type or a string.
The final string result is just all those things together, separated by spaces.

