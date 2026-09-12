# `ring-get` ✅


`(ring-get <ring> <index>)` returns slot `<index>` of the ring.

For a **scratch** or **barrier** ring the index may be a **runtime** value — the pipelining main
loop indexes with `(mod (+ ring-idx 1) stages)`, which is exactly what makes a ring a ring.

For a **register tile ring** it must fold to a **compile-time integer**: the GRF is not
runtime-indexable.  A literal works, and so does `(mod <loop-var> <ring-count>)` in a loop the
compiler unrolls by `:ring-count`.  Anything else is a compile error naming the slot.

