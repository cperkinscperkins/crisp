# APPENDIX #2 - Math with Quantized Ints and Microfloat


> These sketches predate the built quantized-integer and microfloat API (endeavours 202-206). Where they
> differ, [Quantized Integers](#quantized-integers-) and [Low Precision Floats](#low-precision-floats-microfloats-)
> are the reference. In particular: there is no zero-point, an accumulator converts with
> `(to-float acc scale)`, a base value widens with `(widen q)`, and a microfloat block is a record over
> two handles, not an element type, so it is decoded with `dequantize-from-XXXX` before any of these run.

