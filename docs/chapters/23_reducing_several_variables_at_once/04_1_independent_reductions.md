# 1. Independent Reductions


Use this form when reducing separate metrics that share a traversal without influencing one
another.

```lisp
;; 'lo' and 'total' are existing mutable bindings
(reduce-warp
  ((#'min lo    (type-max int))
   (#'+   total 0.0f)))
```

Each clause's function must be a `binop-type` `#'(T T => T)`, where `T` is the type of that
clause's variable, and its identity must also be of type `T`. The clauses may have different
types.

Under the hood, the compiler interleaves the work for every variable. At the warp level a
single shuffle sweep carries all the variables, and at the workgroup level a single barrier
serves them all.

