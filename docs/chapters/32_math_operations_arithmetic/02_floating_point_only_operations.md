# Floating Point Only Operations ✅


Crisp provides the following operations for floating point numbers:

#### Unary Operations ✅

The Unary Operations take just a single argument.
Example:
```
(sqrt x)
```

- `sqrt`  ; under `ieee` correctly rounded (`llvm.sqrt`, no libdevice on PTX); under `fast` the approximate instruction
- `rsqrt` ; $1/\sqrt{x}$ -- under `ieee` computed as `1/sqrt`; under `fast` the approximate hardware instruction (same as `op-rsqrt-approx`)
- `exp`   ; `(exp x)` calculates $e^x$
- `log`
- `log2`
- `sin`
- `cos`
- `tan`
- `asin`
- `acos`
- `atan`


#### Binary Operations  ✅
- `pow`   => `(pow base exponent)`
- `atan2` => `(atan2 y x)`

