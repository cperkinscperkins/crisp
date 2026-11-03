# Endeavour 206: Microfloat Blocks

Delivers section 4 of `tests/spec/205-quantized-integers/proposed-api.md`: records that hold handles, the
microfloat formats, block quantization, and a training path.  Native Blackwell `tcgen05` is a later
endeavour.

```lisp
(def-microfloat-block mf-w :base fp4 :scale fp8-e4m3 :accum float :shape (16))

(def-kernel quant (x &out c s)
  (declare #'(mf-w-floats &out mf-w-codes mf-w-scales)
           (global-size :derive-from s :strategy :strided))   ; one thread per block
  (let ((w (make-mf-w :codes c :scales s)))
    (quantize-to-mf-w x w)))

(dequantize-from-mf-w w x)   ; every element, decoded and scaled
(to-float w i)               ; one element
(~ w i)                      ; its raw code
(fake-quant-mf-w x y)        ; forward through the format, straight through backward
```

The block defines the handle types `NAME-codes`, `NAME-scales` and `NAME-floats`.  `(accum T)`, `(base T)` and
`(scale T)` name its types, including as a handle's element.

## How it is built

`def-microfloat-block` generates ordinary Crisp functions for its two formats, so both backends get them, and
a kernel can call them.  `NAME-decode-code`, `NAME-encode-code`, `NAME-decode-scale`, `NAME-encode-scale`,
`NAME-code`, `NAME-at`, `NAME-block-scale` and `NAME-quantize-block` are all plain `def-function`s.  Each is exact:
every step is an integer shift or a multiply by a power of two.  `quantize-to` strides over the scales handle,
one thread per block.

A record holding handles needed one change: an alias to a handle was not resolved before it was sized.

## Decisions (D-206-n, for review)

1. **A record of handles stays inside the kernel.**  A kernel takes the two handles and builds the block with
   `make-NAME`.  As a kernel parameter it compiled, but what a host would pass is not defined, so it is refused,
   for a block and for a plain record that holds a handle.  Functions and grid functions may take one.
2. **A scale rounds up.**  `quantize-to` encodes `top / max-code` with `ceil`, so the block's largest element is
   never clipped.  Rounding to nearest gives a slightly smaller error on most blocks, and clips the largest
   element on the rest: spec 06 would store 6.75 for 7.  **Worth your review**, since exporters may differ.
   This changes only what we quantize to.  Decoding someone else's blocks is not affected.
3. **fp4 packs the even element in the low nibble.**  This is from my memory of the NVFP4 checkpoint layout.  **It
   has not been checked against a real checkpoint.**  A wrong guess would swap every pair, so check it the first
   time one is loaded.
4. **`fake-quant-NAME` is new.**  The draft had a straight-through gradient but nothing to attach it to, since
   `quantize-to` writes packed integers.  It sends each element through the format and passes the adjoint
   straight back: `dy/dx = 1`.  The scale is held constant, the usual choice.
5. **`quantize-to`, `dequantize-from`, `(to-float w i)` and `(~ w i)` have no gradient.**  Codes are integers.  A
   kernel with a float input that reaches one fails loudly, naming the function (`errors/12`).  Training runs in
   float through `fake-quant-NAME`, as with 205's integer path.
6. **`fp8-e8m0` is a scale only.**  It has no zero and no sign.
7. **NaN and negative zero.**  NaN encodes as the format's NaN, or as 0 in fp4, which has none.  `-0.0` encodes
   as `+0`, because there is no sign-bit test.  A small negative that rounds to zero keeps its sign, code 8.
8. **Blocks are one-dimensional, and every handle holds whole blocks.**  This is not checked: a float handle
   shorter than the scales imply reads past its end.
9. **The optional per-tensor global scale of NVFP4 is deferred.**
10. **`def-type` now resolves an accessor element** when it is defined, so `(vector (base T) ..)` reaches the
    metadata as a real type.  This also fixes `(vector (accum T) ..)` for qints, which did not work before.

## Verified by hand

- **Every code of every format, on BMG, against a separate reference.**  `put_temp_files_here/q206/x/` printed all
  256 codes through the generated functions, and a Lisp reference built from the format definitions in exact
  rationals compared them.  0 wrong for decoding in e4m3, e5m2 and e8m0, for encode after decode, for rounding
  up just above each value, and for ties going to the even code.  This found two real encoder bugs before any
  spec existed: e4m3's top exponent, and NaN.  It is a one-time check, because a spec buffer holds 4 elements;
  specs 03 and 04 keep the round trips on the GPU.
- Hand-derived blocks on BMG: specs 05 to 09 and 12, including a block other than the first.
- The gradient on BMG: `analytical=1.0 numerical=0.0`, which is the point of a straight-through estimate.
- PTX: the 12 metal specs assemble with `ptxas -arch=sm_90a`, their harnesses compile with `nvcc`, and nothing needs
  libdevice.  In spec 05 LLVM folds the scale to `st.global.b8 [%rd3], 48`, the value derived by hand.
- H100 80GB HBM3 (2026-11-02, `b1e691b1`, driver 595.91.07, CUDA 12.8): 24/24 specs, all 11 CUDA hoists ran
  and every buffer matched the same `HOIST-EXPECT` lines BMG passes, including both every-code specs (0
  mismatches).  Spec 10 (the gradient) is L0 only.  182 re-run alongside: 32/32.

## Not covered

- The gradient (spec 10) has run on BMG only.
- `ceil` and `round` are exact in float, but `e8m0` code 0 is `2^-127`, a float denormal.  An element can only
  need it when the block is all zero or nearly so.  `NAME-unscale` keeps a flushed scale from making NaN.
- No throughput has been measured, and none is claimed.  The conversion path is for correctness.
- `(*! w w)` is refused.  The native path is `tcgen05`, on a B200.

## Found along the way

- BUG 153: float `!=` is `fcmp one`, so `(!= x NaN)` is false.
- BUG 154: a stride inside a `def-grid-function` cannot be differentiated, and the error says `SET!`.

## For the fold

- `def-microfloat-block`, `%mf-encode-body`, `%mf-fp8-encode-body` and `%mf-refuse-block-at-boundary` each appear more
  than once.  Take the LAST copy.
- `def-type` is a macro: patch it in `src/macros.lisp`.  The change is its first line.
- These wrappers each become a clause or a call: `register-struct-definition`, `analyze-scaled-float-cast`,
  `analyze-aref-expression`, `analyze-accum-op`, `resolve-type-accessor`, `%register-accum-analyzers`,
  `%check-qint-arith`, `%analyze-min-expression`, `%analyze-max-expression`, `canonicalize-type-specifier`,
  `internal-def-function`, `%185-math-backward` and `%expand-stride-macros-in-form`.  Drop the `*...-206*` variables.
- `%expand-fake-quant-forms` can become a clause beside `reduce-vec`'s in `%expand-stride-macros-in-form`.
- Export `def-microfloat-block` through `src/package.lisp`.
