# `reduce-vec` ✅


Because reducing a whole vector is so common, Crisp provides a wrapper that writes the grid-stride
loop and the grid reduction for you:

```
(reduce-vec someFunction vec identity out-cell
            &key strategy message unroll
                 local-scratch-vec global-scratch-vec atomic-counter election-flag-cell)
```

Each thread folds its grid-stride share of `vec` into a private partial that starts at `identity`,
and the partials are then combined across the grid by `grid-reduce!` with the chosen `:strategy`.
A call means exactly this:

```lisp
(let ((partial identity))
  (loop-vector-stride vec (i)
    (set! partial (someFunction partial (~ vec i))))
  (grid-reduce! someFunction partial identity out-cell :strategy strategy ...))
```

* `someFunction`: a `binop-type` `#'(T T => T)`, commutative and associative (see below).
* `vec`: a **vector** (a rank-1 tensor) of `T`. Matrices and tensors are not flattened; passing
  one is a compilation error.
* `identity`: the identity of `someFunction`, of type `T` -- the vector's element type. A
  mismatch (`0.0` over an `int` vector) is a compilation error. When Crisp allocates the scratch
  for you, the identity's type must also be visible on its face, exactly as for `grid-reduce!`
  (see *Full Reductions Made Easy* above).
* `out-cell`: a `:global` cell of `T`, as for `grid-reduce!`. `:atomic` and `:cas` *accumulate*
  into it, so it should start at the identity; `:last-man-standing` *writes* it.
* `:strategy`: `:atomic`, `:cas` or `:last-man-standing` (the default), written as a literal
  keyword. There is no second-stage strategy: it needs a second kernel launch, which one call
  cannot arrange.
* The scratch keys and `:message` are passed straight through to `grid-reduce!`. Any scratch you
  leave out is allocated for you, and a key the chosen strategy does not use is a compilation
  error (`:atomic` and `:cas` take only `:local-scratch-vec`).
* `:unroll` belongs to the loop, not to `grid-reduce!`: `:unroll 2` puts `(declare (unroll 2))` at
  the start of the `loop-vector-stride` body. It takes what the declaration takes -- a positive
  integer, `t` or `nil` -- and without it the loop gets `loop-vector-stride`'s default (see
  [unroll](#unroll)).

**The grid does not have to match the vector.** That is the point of the stride: launch about as
many threads as the hardware runs at once, and each folds several elements. A thread that owns no
element at all contributes only the identity. Any grid works with every strategy, `:last-man-standing`
included: its partials are sized one per workgroup and its final sweep is strided.

`reduce-vec` is a grid-level operation, so it cannot be nested inside another grid-level stride.
Several calls in one kernel are fine, one after another; each gets its own scratch. It reduces one
vector with one function: to reduce several variables at once, write the stride loop yourself and
hand the partials to `grid-reduce!` with clauses (see *Reducing Several Variables at Once*).

**Autodiff** works through `reduce-vec` for the `#'+` reduction, under every strategy, exactly as
for `grid-reduce!`: d(out)/d(vec[i]) is d(out) for every element. `min`, `max` and custom functions
are a compilation error under `--differentiate`.

```lisp
;; Example: The "Easy Button" atomic strategy
(reduce-vec #'+ my-large-vector 0.0 result-cell :strategy :atomic)

;; Example: The flexible "Last Man Standing" strategy (the default) for custom operations
(reduce-vec #'my-custom-hash-combine my-large-vector 0u result-cell)

```

*(Note: all `reduce-vec` operations utilize `reduce-workgroup` as their Phase 1 under the hood).*

