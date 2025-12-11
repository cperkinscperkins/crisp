CRISP Realized
==============

While the ideal_001.md document lays out a description of the Crisp language and tools in the ideal,
THIS document tracks what is realized and available in the currrent implementation of Crisp.

ideal_001.md informs "where we are going" and realized_001.md "where we are".

Tooling
=======

The compiler itself is buildable. It resides in `bin/crisp-compile.exe`. It is working on both Windows
and Linux. 

Presently it supports the compilation of one (1) .crisp file. 

It also supports three (four) flags:

### -g / --debug
DWARF symbols are inserted when using the `-g` or `--debug` flags.

### --single-pass
By default the compiler uses multiple passes. But with the `--single-pass` flag it will attempt
to compile in a single pass. If using `--single-pass` all forms must be in reverse dependency order, 
else errors (see below).
 
### --log-level=<level>
Sets the logging verbosity. Accepted levels are (from most to least verbose): `trace`, `debug`, `info`, `warn`, `error`, `fatal`.
The default level is `info`.


Pipeline
========

The compiler
- reads and parses .crisp files
- macroexpands
- builds an AST with all semantic structures
- walks the semantic node tree to generate LLVM-IR
- Side Channels are supported (for the cell datatype, which is WIP)
- DWARF markup is also supported


Available Language Constructs
=============================


### def-function
`def-function` is available and working E2E (through the whole pipeline).
Presently these features of `def-function` are NOT implemented yet:
- `&optional` , `&key` arguments
- `&out` arguments
- [x] multiple value return
- limited `(declare)`
- ther is no enforcement of the limit to thread level operations, ie no grid level calls
- the colon joinging var to type syntax is not yet supported ( `x:int`)

### with-template-type   also (<T U> ...)
Yes, you read that right. Templating is now available in Crisp. Fully working for the 
types we support. 

At the moment only `def-function` can be wrapped. 

#### gen-XXXX   
The `gen-XXXX` form is available for anything you template. Can be used at the top of the .crisp file,
or in a def-function body.

### Basic Numeric Types
`int` `long` `half` `float` etc etc as documented in ideal_001.md are all supported E2E

### Type Promotion

Type promotion, including errors, as documented in ideal_001.md is functional and should be complete.

### let

The `let` binding is now implemented and tested. It correctly supports:
- **`let*` Semantics**: Bindings are evaluated sequentially, and each new variable is available to subsequent bindings in the same `let` form.
- **Mutable Variables**: `let`-bound variables are allocated on the stack and can be mutated (though `set!` is not yet implemented).
- **Single-Variable Bindings**: Forms like `(let ((x 10)) ...)` are fully supported.
- **Multiple-Variable Bindings**: Forms like `(let ((q r (/ 10 3))) ...)` are fully supported.

### declare
`declare` is available as the first s-expression in the body of a `def-function`. It is
not yet available in the first position of the `let` form.
The following declarations are supported
- `(type <var0> ... <varN> <T>)`  declare the type of a parameter(s).
- `(return-type <T>)` declare the return type of a function.
- `#'(<T> <U> => <V>)` declare parameter types, arrow, return type.

#### (type a b int)

#### (return-type int)
Also `#'(int int => int int)` for multiple value return.



### cell & make-scratch-cell
The `cell` Storage Handle data type is available as a composit type (only).
It is just a placeholder for now, and cannot do actual work. 
`make-scratch-cell` is similarly available and non-functioning.

### Higher Order Functions
Functions can be passed as arguments to other functions. And, for this, the signature
of one function can be nested in that of another.  #'(#'(int => int) int => int)
Functinos that take other functions as parameters are automatically templated 
and "calling" them results in the template being specialized.

`funcall` is working as well:
`(funcall #'+ 1 2 )`

### defmacro
Ladies and Gentlemen, gather round.  Crisp now supports defmacro !!  Whoo boy. 

It's a tiny bit funky-funky. You use Common Lisp inside defmacro to generate Crisp.

I know, seems weird. But, hey, it took 20 minutes. And this is exactly why we are building
with SBCL and Common Lisp in the first place. A 6-month lift was just gotten for free.

Note: inside defmacro, use the Crisp `let` form.  The one that is sequential and supports 
multiple variable bindings.  The Common Lisp `let` and `let*` forms are not supported.

The document defmacro-utils.md documents exactly which Common Lisp forms are supported.


### if / when / unless / cond  <--  CONDITIONALS
Conditionals are now supported. Codegen included.

Note that default clause of `cond` is NOT `T` like in Common Lisp, it is `else` (like in some Scheme dialects).

Also note that the compile-time predicate check `if+`, `when+`, `unless+`, and `cond+` are FULLY implemented.  Yes!!

But the `*` variants for uniformity are not yet implemented. 

Errors
======

### General Errors
- A Crisp compilation error occurred at (location).
- Unexpected end of file. This usually means a parenthesis or quote is missing.
- Unknown variable ___
- Unsupported form ___ found in function body.
- Recursion is not allowed. Call to ___ is recursive.

### Type System Errors
- Type mismatch! Expected ___ but inferred ___.
- Unknown type '___'.
- Expected ___ but got ___.
- Arity mismatch! Function param list has ___ arguments but type signature declared ___.
- Missing type declarations for parameters: ___
- Operator '+' not supported for types ___ and ___
- Type mismatch for operator '+'. Cannot add ___ and ___ without explicit cast.
- No matching function overload found for '___' with argument types ___.

### Malformed Code Errors
- Malformed make-scratch-cell form: ___. Expected (make-scratch-cell <type>)
- Malformed let form: ___
- Malformed let binding: ___
- Cannot destructure a single-value return into multiple variables at ___
- Not enough return values from ___ to bind ___ variables at ___

### Cast & Conversion Errors
- Invalid cast: Cannot use 'to-...' for float-to-integer conversion. Use 'truncate', 'floor', 'ceil', or 'round' instead.
- Unsupported value cast from ___ to ___

### Internal Compiler/Codegen Errors
- Internal compiler error: analyze-cast-expression called with invalid operator ___
- Compiler bug: Carrier function ___ is missing implicit argument ___ in its environment.
- Missing implicit arguments for make-scratch-cell. Environment keys: ___
- Codegen not implemented for literal of type ___
- Codegen for literal of unknown type category: ___
- Cannot mangle unknown type specifier: ___
- Internal codegen error: Unknown simple type ___
- Internal codegen error: Unknown parameterized type ___
- Internal codegen error: Invalid type specifier ___

Line Numbering
==============

As a Lisp, what with all the macroexpansion and code conversion, line numbers don't
"line up" (pun intended) like they do in C/C++/Rust etc. Crisp uses a s-expression
counting system. You'll see error messages with locations like: (2 3 0 5 8) which means
the error is in the 2nd s-expression, 3rd s-expression, 0th s-expression, 5th s-expression,
8th s-expression of the tree.  It's essentially a branch-and-leaf counting system.  Enjoy.