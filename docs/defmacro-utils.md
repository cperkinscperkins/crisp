# Common Lisp Utilities for Crisp Macros

This document lists the Common Lisp symbols that are explicitly exported to the `CRISP-LANGUAGE` package for use in `defmacro` bodies.

> [!IMPORTANT]
> This list MUST may kept in sync with the `(defpackage :crisp-language ...)` definition in `src/package.lisp`.

## Lambda List Keywords
- `&optional`
- `&key`
- `&rest`
- `&body` (Added for macro definitions)

## Control Flow
- `progn`: For grouping forms in macro expansions.
- `if`, `when`, `unless`, `cond`, `case`: Standard conditionals.

## List Manipulation
- `list`, `list*`
- `cons`
- `car`, `cdr`, `first`, `rest`
- `second`, `third`, `fourth`, `fifth`, `sixth`, `seventh`, `eighth`, `ninth`, `tenth`
- `nth`
- `reverse`
- `append`
- `length`
- `mapcar`, `mapc`

## Symbols and Strings
- `gensym`: Essential for hygienic macros.
- `intern`: Creating new symbols.
- `symbol-name`
- `string`: Converting to string.
- `concatenate`: String concatenation.
- `format`: String formatting (often used with `intern` to make new names).

## Predicates
- `null`: Checks for nil/empty list.
- `atom`: Checks if `x` is not a cons cell.
- `consp`: Checks if `x` is a cons cell.
- `listp`: Checks if `x` is a list (cons or nil).
- `symbolp`: Checks if `x` is a symbol.

## Logic
- `not`
- `and`
- `or`
