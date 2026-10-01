# Clauses


Both forms describe each variable with a **clause**, a list that keeps everything belonging to
that one variable (its function, identity, destination, and scratch memory) together in one
place:

| Form        | Clause |
| ---         | --- |
| Independent | `(someFunction <someVar> identity [return-cell] &key ...)` |
| Dependent   | `(<someVar> identity [return-cell] &key ...)` |

The independent clause is exactly the argument list of the single-variable form. The dependent
clause is the same, minus the function, because the combiner is shared and written once, before
the clauses.

`return-cell` appears only at the grid level (`grid-reduce!`), where every reduced variable
needs a destination. `reduce-warp` and `reduce-workgroup` leave their results in the variables
themselves.

The compiler tells the three shapes apart by their structure alone:

```lisp
(reduce-warp #'+ total 0.0f)                        ; single:      function, variable, identity
(reduce-warp ((#'+ total 0.0f) (#'min lo ...)))     ; independent: a list of clauses
(reduce-warp #'combine ((val ...) (idx ...)))       ; dependent:   a function, then a list of clauses
```

