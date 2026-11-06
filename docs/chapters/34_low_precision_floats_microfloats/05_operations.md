# Operations ✅


| Form | Result |
|---|---|
| `(quantize-to-NAME floats &out w)` | Fills the codes and scales of `w` |
| `(dequantize-from-NAME w &out floats)` | Every element, decoded and scaled |
| `(fake-quant-NAME x &out y)` | Each element of `x` through the format, into `y`.  For training |
| `(to-float w i)` | Element `i`, decoded and scaled: a `float` |
| `(~ w i)` | The raw code of element `i`, of type `(base NAME)` |

Blocks cannot be added or subtracted. `+` and `-` belong to the accumulator, which is an ordinary float.

`max` and `min` are not defined on codes either, because codes from different blocks have different
scales and comparing them means nothing. Decode first.

#### Multiplying blocks ✅ (Blackwell)

A block multiply is a matrix multiply.  On Blackwell (`sm_100a`), `tcgen05-accumulate-via-tile` on two
tiles of the block type is the native block-scaled MMA: NVFP4, MXFP4 and MXFP8, with the scales in a
declared layout (see "Blackwell tensor cores", block-scaled microfloats).

```lisp
(*! MFB MFB) => A
```

on scalars stays refused (D-208-16), with a message pointing at `dequantize-from`.  The `mfb-mult-add`
macro of the earlier design is gone.

On H100 and BMG the path is to `dequantize-from` into `half` or `float` and use the existing
MMA forms. That is a conversion, not an emulation. As with quantized integers, the compiler will not
silently emulate a block multiply.

