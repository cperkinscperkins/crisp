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

**Autodiff through a dependent reduction needs one more function from you: a local VJP.** The variables
interact inside your combiner, so Crisp cannot derive the backward rule on its own. You declare it on the
combiner with `(declare (reduction-vjp f))`. Given *this thread's* contribution, the *result*, and the
result's adjoint, `f` returns this thread's adjoint:

```
#'(T1 ... Tk   T1 ... Tk   A1 ... Ak  =>  A1 ... Ak)
   own state   result      result         own adjoint
                           adjoint
```

`Ai` is the adjoint type of `Ti`: `double` for a `double`, and `float` for every other type, integers
included. An index has a `float` adjoint, though it is usually zero.

```lisp
(def-function argmax-combine (val-a idx-a val-b idx-b)
  (declare #'(float ulong float ulong => float ulong)
           (reduction-vjp argmax-local-vjp))          ; the one new line
  (if (or (> val-a val-b)
          (and (= val-a val-b) (< idx-a idx-b)))
      (return val-a idx-a)
      (return val-b idx-b)))

(def-function argmax-local-vjp (v i rv ri rv-bar ri-bar)
  (declare #'(float ulong float ulong float float => float float))
  ;; the winning thread takes the value's gradient; an index has none
  (if (= i ri)
      (return rv-bar 0.0)
      (return 0.0 0.0)))
```

Crisp does the rest. The backward pass recomputes the result and sums the result's adjoint over every
thread that holds it. It then calls `f` once per thread. Threads past `active-threads` get a zero
adjoint: your VJP cannot see `active-threads`, so it need not handle them. The VJP is checked against
the combiner and the clauses on every compile, not only under `--differentiate`, so a mismatch is
reported where you wrote it.

**The limitation:** a thread's adjoint must be computable from its own contribution and the result. That
covers the reductions people actually write:

* selections, such as argmax, argmin, max and min ("am I the winner?");
* sums, counts and means;
* moments and Welford-style variance;
* log-sum-exp (`exp(x - R)`);
* products (`R / x`, away from zero).

It fails only when the gradient needs something the result discarded, such as a runner-up. If you need
that, shape the state to keep it.

Without a `reduction-vjp`, differentiating through a dependent reduction is a compilation error that says
what to add. It is never a silently wrong gradient. Two cases are not differentiable yet, with or without
the declaration:

* a dependent `grid-reduce!` (reduce within the workgroup first);
* `:return-vec` in a dependent clause.

The independent form needs none of this: each of its clauses is differentiated on its own.

