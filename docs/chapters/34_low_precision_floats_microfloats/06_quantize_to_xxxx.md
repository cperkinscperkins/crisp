# quantize-to-XXXX ✅


```lisp
(quantize-to-XXXX float-vec &out w)
```

A grid function. It strides over the scales handle, one thread per block, so launch it with
`(global-size :derive-from s :strategy :strided)` on the scales `s`.

For each block:

1. The scale is the block's largest magnitude divided by the format's largest value (`6.0` for `fp4`),
   encoded in the scale format **rounding up**. So the block's largest element always fits, and is never
   clipped. Rounding to the nearest scale would give a slightly smaller error on most blocks, and clip
   the largest element on the rest.
2. Each element, divided by the decoded scale, is encoded round-to-nearest, ties to even, saturating.

Details:

- `fp4` packs the even element in the low nibble and the odd element in the high nibble. This follows
  the NVFP4 layout as remembered, and it has not yet been checked against a real checkpoint 📝.
- NaN encodes as the format's NaN, or as `0` in `fp4`, which has none.
- `-0.0` encodes as `+0`. A small negative value that rounds to zero keeps its sign (code 8 in `fp4`).
- A block of zeros gets a zero scale. `fp8-e8m0` has no zero, so there it gets its smallest code,
  `2^-127`, a float denormal that a GPU may flush to zero. The elements are zero either way, and a zero
  or flushed scale never produces a NaN.

