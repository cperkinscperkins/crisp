# Quantized Integers 📝


A quantized integer (`qint`) is just like a normal integer that's being used
to "fake" a floating-point number. Commonly a `qint8` is a single byte number
that represents any of 256 steps over some amount of number space, a gradient.

It does this in conjunction with a "Scale" and a "Zero Point" which are both 
floating point numbers. These two values define the "number space" that the 
gradient is applied over. 

So two floats (scale and zero-point) and N qints can compactly represent the 
same values as N floats that fall in the same number space. That's a 4x space
saving! 

While it's easy to focus on the precision lost when converting a single float, this viewpoint is flawed. The true power of qints is seen at the vector level. When a Scale and Zero-Point (two floats) are well-chosen to define the number space for an entire dataset, the relationships between the numbers are preserved with high fidelity.

This is the core trade-off: in exchange for a tiny, well-managed loss of precision, you get a 4x reduction in memory size and access to blazingly-fast, specialized integer math hardware. The results are fast, compact, and perfectly workable for domains like AI.

But `qint` base types have a problem when multiplied: that result can easily
be greater than 256, which means it's no longer representable by the base `qint` 
type. For this a second `qint` type is needed: the accumulator. 

For `qint8` the accumulator is usually `qint32`.  

By now, gentle reader, your assignment should be clear: receive data
as some small `qint` base type, operate on it, using temporary `qint` accumulators, 
and get it stored away again back as a the `qint` base type before
anyone notices. What could be easier?

