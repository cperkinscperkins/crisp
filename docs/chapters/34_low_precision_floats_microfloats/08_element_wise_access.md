# element-wise access ✅


#### `~` ✅

`(~ MFB index) => (base MFB)`
The raw, unscaled code at `index`. Its type is the block's base format, so it can be stored into a
`(vector (base mf-w) ..)`.

#### `to-float` ✅

`(to-float MFB index) => float`
An overload of `to-float` that takes a microfloat block and an index. It decodes the code at that index,
multiplies it by its block's scale, and returns a "regular" `float`.

Element-wise access is not slow, but each element decodes its block's scale again. Prefer
`dequantize-from-XXXX` for whole tensors.

