# dot product ⚠️


The "dot product" is an operation that takes two vectors of the same length
and returns a single scalar number. It's the sum of the products of the corresponding
entries of the two sequences of number. 
Mathematically, for two vectors A and B, the dot product is:
<!-- latex -->
$$A \cdot B = \sum_{i=1}^{n} A_i B_i = A_1B_1 + A_2B_2 + \cdots + A_nB_n$$

I can be thought of as a measure of how much one vector "points in the direction" of another. 
If two vectors are perpendicular, their dot product is zero. If they point in the same direction, their dot product is maximized.

### dot-prod-grid / dot-prod-seq

```
(dot-prod-grid A B &out RESULT)
(dot-prod-seq A B) => RESULT
```

Crisp provides two variants of the dot product function. `dot-prod-grid` is a grid level
function that uses a grid stride and a reduction to quickly calculate the dot product using
all available threads simultaneously. 

`dot-prod-seq` is a thread level sequential function that simply loops in the current thread.

Both accept two matrix arguments. They can
be a `vector`,  or a 1D `tensor`.  Note that `dot-prod-grid` should be
coalesced automatically for `vector`  arguments. But not
necessarily for `tensor`.  A row of a row-major `matrix` would be fine, but
the col or a row-major `matrix` would not be able to have coalesced memory copy.

The `RESULT` argument for `dot-prod-grid` should be a `:global` writeable vector. The
result will be written to index 0.

There are possible implementations below, with the implementations of `matmul`

