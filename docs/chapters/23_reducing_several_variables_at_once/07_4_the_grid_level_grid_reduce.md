# 4. The Grid Level (`grid-reduce!`)


At the grid level, each clause names the `:global` cell that receives that variable's final
value.

**Independent:**

```lisp
(grid-reduce!
  ((#'min lo    (type-max int) out-min-cell)
   (#'+   total 0.0f           out-sum-cell))
  :strategy :last-man-standing)
```

**Dependent:**

```lisp
(grid-reduce! #'argmax-combine
              ((my-val (type-min float) out-val-cell)
               (my-idx (type-max ulong) out-idx-cell))
              :strategy :last-man-standing)
```

#### Grid Strategy Compatibility

* **Independent form:** All strategies (`:atomic`, `:cas`, `:last-man-standing`) are supported.
  `:atomic` still requires every clause's function to have a hardware atomic (`#'+`, `#'min`,
  `#'max`). A clause that does not is a compilation error.
* **Dependent form:** Only `:last-man-standing` is supported. `:atomic` and `:cas` commit one
  word at a time, so they cannot keep the `k` values of a state together. Asking for either is a
  compilation error. (Packing a small state into one 64-bit CAS word is possible in principle,
  but Crisp does not do it.)

Under `:last-man-standing`, one election serves the whole call. Each workgroup writes a partial
for every variable into that variable's `:global-scratch-vec`, then draws a single ticket from
the shared `:atomic-counter`. The last workgroup sweeps all the variables. A call with `k`
clauses costs one atomic ticket per workgroup, not `k`.

`:last-man-standing` is the default strategy, and it carries its usual limit: the number of
workgroups must not exceed `local_work_size`.

