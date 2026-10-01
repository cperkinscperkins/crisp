# Choosing the Identity and Function


* **The identity must change nothing.** Threads that contribute no data (e.g. lanes past
  `active-threads`) supply the identity, and the reduction then combines it with real values,
  and with other identities. Two laws must hold for every valid state `x`:
  * `f(x, identity) = x`: combining a real state with the identity returns the real state,
    including in the case of a tie.
  * `f(identity, identity) = identity`: two padding threads combined are still padding.

  Use `(type-min T)` for `max`, `(type-max T)` for `min`, and `(type-max ulong)` for an
  argmax/argmin index, so that when values tie, the real index wins against the padding one.

  For floating-point types, `(type-min T)` and `(type-max T)` are the most negative and most
  positive *finite* values, in every precision context. (`(type-min float)` is about -3.4e38.
  It is not C's `FLT_MIN`, which is the smallest positive normal.) A finite identity is
  correct whenever the inputs are finite, and under `:fast` precision they must be: `:fast`
  lets the compiler assume that no value is ever infinite, so an infinite identity there is
  undefined. Under `:ieee`, if infinite inputs must win, use `(- (type-infinity T))` and
  `(type-infinity T)` instead. With a finite identity, any PADDING lane (one past `active-threads`,
  say) contributes `(type-min float)`, which beats an input that is all `-inf` -- so the reduction
  returns `(type-min float)`, and argmax reports the padding index.

  The second law is the one that bites dependent combiners. A streaming-variance combiner
  divides by `n-a + n-b`; when two identity states `(0 0 0)` meet, that is `0/0`, and the NaN
  spreads through the whole reduction. Such a combiner must check for an empty state
  (`n = 0`) and return the other state unchanged.

* **Functions must be commutative *and* associative.** GPU reductions guarantee neither the
  order nor the grouping in which values are combined. If an operation is sensitive to ties,
  resolve them explicitly inside the function, as the lower-index tie-break in
  `argmax-combine` does.

  Floating-point addition is only approximately associative, so a float sum can differ in its
  last bits from run to run. That is normal on GPUs, not a bug.

* **NaN is not a state.** Under `:ieee`, every comparison involving a NaN is false, so a
  comparison-based combiner such as `argmax-combine` returns whichever state it was handed
  second. The combiner is then no longer commutative, and the result depends on scheduling. If
  the inputs can contain NaN, filter them out before the reduction, or handle them explicitly
  in the combiner.




