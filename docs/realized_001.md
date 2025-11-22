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

It also supports two (three) flags:

### -g / --debug
DWARF symbols are inserted when using the `-g` or `--debug` flags.

### --single-pass
By default the compiler uses multiple passes. But with the `--single-pass` flag it will attempt
to compile in a single pass. If using `--single-pass` all forms must be in reverse dependency order, 
else errors (see below).

Pipeline
========

The compiler
- reads and parses .crisp files
- macroexpands
- builds an AST with all semantic structures
- walks the semantic node tree to generate LLVM-IR
- DWARF markup is also supported


Available Language Constructs
=============================


### def-function
`def-function` is available and working E2E (through the whole pipeline).
Presently these features of `def-function` are NOT implemented yet:
- `&optional` , `&key` arguments
- `&out` arguments
- multiple value return
- limited `(declare)`
- ther is no enforcement of the limit to thread level operations, ie no grid level calls
- the colon joinging var to type syntax is not yet supported ( `x:int`)

### Basic Numeric Types
`int` `long` `half` `float` etc etc as documented in ideal_001.md are all supported E2E

### Type Promotion

Type promotion, including errors, as documented in ideal_001.md is functional and should be complete.

### let

The `let` binding is now implemented and tested. It correctly supports:
- **`let*` Semantics**: Bindings are evaluated sequentially, and each new variable is available to subsequent bindings in the same `let` form.
- **Mutable Variables**: `let`-bound variables are allocated on the stack and can be mutated (though `set!` is not yet implemented).
- **Single-Variable Bindings**: Forms like `(let ((x 10)) ...)` are fully supported.
- **Known Limitation**: Multiple-value-bind `(let ((q r (/ 10 3))) ...)` is not yet implemented.

### declare
`declare` is available as the first s-expression in the body of a `def-function`. It is
not yet available in the first position of the `let` form.
The following declarations are supported
- `(type <var0> ... <varN> <T>)`  declare the type of a parameter(s).
- `(return-type <T>)` declare the return type of a function.
- `#'(<T> <U> => <V>)` declare parameter types, arrow, return type.
