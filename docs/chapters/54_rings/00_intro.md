# Rings ✅


```
(make-scratch-vector-ring <elem> <dim>        :ring-count <n>)                      => ring
(make-scratch-matrix-ring <elem> (<d0> <d1>)  :ring-count <n>)                      => ring
(make-scratch-tensor-ring <elem> (<dims>...)  :ring-count <n>)                      => ring
(make-register-tile-ring  <elem> (<M> <N>)    :ring-count <n> &key operand warps)   => ring
(make-async-barrier-ring  :ring-count <n> &key mode arrivals initial-state)         => ring

(ring-get <ring> <index>) => <slot>
```

For pipelining we need several pads to cycle through, so one can be filled while another is read.
An async pipeline needs a matching ring of barriers to track the transfers in flight.

`<elem>` is an element type (`float`, `half`, …) or a template type variable.  `:ring-count` is
required everywhere and must be a positive compile-time integer — it becomes a dimension, and
dimensions cannot be runtime values.  `<dims>` are likewise compile-time integers.

> **How a ring is built.**  A ring of N slots is ONE allocation with the ring as a *prepended
> dimension* — `(make-scratch-matrix-ring float (64 8) :ring-count 3)` is a rank-3 scratch tensor
> `(3 64 8)` whose **dim 0 is the slot** — and `ring-get` is an offset view into it.  So the slots
> are contiguous in SLM and a ring costs exactly **one** implicit kernel argument no matter how
> deep it is.  A barrier ring is the same idea: `N` mbarriers laid out contiguously, and a plain
> `(make-async-barrier)` is simply **a ring of 1**.

