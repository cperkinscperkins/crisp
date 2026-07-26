# declaim ⚠️


We've already seen `declare` introduced earlier. Whereas `declare` must appear in the context of some `progn`, 
`declaim` is done at the top-level of your .crisp file, usually at its beginning.
Like `declare`, `declaim` is enforced at compile-time and is erased from the runtime execution.

Example:
```
(declaim (check-coalesce #'my_kernel #'my_2D_memcpy))
```
In the example above, the "coalescence check" (see below) would be run on `#'my_kernel` and `#'my_2D_memcpy`, but not on any 
other functions or kernels.

If you want a check conducted on EVERY function and kernel in the .crisp file, simply `declaim` it directly.
Note that except for possibly `check-barriers`, running checks like this on EVERY function is probably a bad idea.
It's slow, and you'll likely trip a bunch of warnings that shouldn't really be applied to a particular function.
(Full Disclosure: `check-barriers` is slow too).

```
(declaim (check-barriers))
```
In the example above the "barrier check"  (see below) would be run on every function and kernel.

