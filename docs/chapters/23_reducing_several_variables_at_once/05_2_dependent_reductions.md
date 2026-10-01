# 2. Dependent Reductions


Use this form when the values are entangled, such as keeping an index aligned with an extreme
value, or tracking a streaming variance.

The combiner takes two *states*, A and B, of `k` values each, and returns the combined state of
`k` values. Its signature is:

```
#'(T1 ... Tk  T1 ... Tk  =>  T1 ... Tk)
```

where `Ti` is the type of the variable in clause `i`. Argument `i`, argument `k+i`, and return
value `i` all share that type. Clause order is argument order: the first clause names the first
value of each state, and so on. The combiner returns its state as multiple values
(`(return v1 ... vk)`).

```lisp
(def-function argmax-combine (val-a idx-a val-b idx-b)
  (declare #'(float ulong float ulong => float ulong))
  (if (or (> val-a val-b)
          (and (= val-a val-b) (< idx-a idx-b))) ; tie-break: lower index wins
      (return val-a idx-a)
      (return val-b idx-b)))

(let ((my-val (do-some-math (get-global-id)))
      (my-idx (get-global-id)))
  (reduce-warp #'argmax-combine
               ((my-val (type-min float))
                (my-idx (type-max ulong)))))
```

The combiner is checked against the clauses: with clause variables of types `T1 ... Tk`, it must be
`#'(T1 ... Tk T1 ... Tk => T1 ... Tk)`, and anything else is a compilation error that shows both the
signature the clauses need and the one the combiner has. Each combine step calls it once, with all
`k` values of both states.

**Autodiff is not supported yet for the dependent form.** Its variables interact inside your combiner,
so Crisp has no backward rule for it, and a kernel that differentiates through one is a compilation
error rather than a silently wrong gradient. (The independent form *is* differentiable: each clause
is differentiated on its own.)

