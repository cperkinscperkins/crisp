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

#### Multiplying blocks 📝

```lisp
(*! MFB MFB) => A
```

is reserved for the native block-scaled multiply (Blackwell `tcgen05.mma`), which needs tensor memory
and is a later endeavour. On every other target it is refused, with a message pointing at
`dequantize-from`. The `mfb-mult-add` macro of the earlier design is gone for now too.

Until then the path on H100 and BMG is to `dequantize-from` into `half` or `float` and use the existing
MMA forms. That is a conversion, not an emulation. As with quantized integers, the compiler will not
silently emulate a block multiply.

