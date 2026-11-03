# Microfloats and Autodiff ✅


Codes are integers, so `quantize-to`, `dequantize-from`, `(to-float w i)` and `(~ w i)` have no gradient.
A kernel whose float input reaches one fails loudly, naming the function. Training runs in float through
`fake-quant-XXXX`, as with the quantized integers' `to-q` / `to-float`.

