# Quantized Integers ✅


A quantized integer (`qint`) is an ordinary integer standing in for a floating-point number. An 8-bit
`qint` is a single byte that represents one of 256 evenly spaced steps, and a floating-point *scale*
says how big each step is:

```
real = scale * q
```

So one float (the scale) and N 8-bit qints can represent N floats that fall in the same range. That's a
4x space saving!

While it's easy to focus on the precision lost when converting a single float, this viewpoint is flawed.
The true power of qints is seen at the vector level. When the scale is well chosen for an entire tensor,
the relationships between the numbers are preserved with high fidelity.

This is the core trade-off: in exchange for a tiny, well-managed loss of precision, you get a 4x reduction
in memory size and access to blazingly-fast, specialized integer math hardware. The results are fast,
compact, and perfectly workable for domains like AI.

But `qint` base types have a problem when multiplied: the result can easily be greater than 127, which
means it's no longer representable by the base type. For this a second type is needed: the accumulator.
For an 8-bit base the accumulator is usually a 32-bit `int`.

By now, gentle reader, your assignment should be clear: receive data as some small `qint` base type,
operate on it, using temporary accumulators, and get it stored away again back as the base type before
anyone notices. What could be easier?

The scale is a runtime float that you pass where it is needed. Operations that stay inside the integer
world need no scale at all.

Quantization in Crisp is *symmetric*: there is no zero-point, so `0` is always `0.0`. Classic asymmetric
`uint8` activations can still be handled by hand. With symmetric weights,
`sum((a - za) * b) = sum(a * b) - za * sum(b)`, an accumulator subtraction of a precomputed term. A
zero-point may be added later without breaking anything.

