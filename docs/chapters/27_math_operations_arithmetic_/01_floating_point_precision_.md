## Floating Point Precision ✅


### variable type

The Crisp language supports four floating point types that have different levels of precision:

|  Type    | Size   | Aspect |
|----------|--------|--------|
| half     | 16 bit | :bf16  |
| bfloat16 | 16 bit | :fp16  |
| float    | 32 bit |        |
| double   | 64 bit | :fp64  |

The usual trade-offs are in play: larger sizes are more accurate but slower. 
Smaller sizes are less accurate, but faster.

Note that while all platforms support 32 bit, the other sizes aren't always available. If needed use the compile-time checks
`target-has` or `device-has` to partition supporting and unusupporting code. See [target-has/device-has](#target-has--device-has) 

### precision

In addition to choice of variable type, Crisp has a precision control that supports two
different options: `fast` and `ieee`.

With the `ieee` the compiler will choose instructions that guarantee IEEE 754 compliance.
For operations like division or square root, this might mean selecting a slightly slower
but fully precise instruction sequence. This is conditional on the GPU hardware providing
IEEE 754 conforming instructions.
This might also entail disabling automatic FMAD generation, and ensuring that denormalized
numbers are handled correctly (not flushed to zero).

With the `fast` precision option, the compiler will prioritize speed, selecting faster
but potentially approximate instructcions (like `rsqrt.approx`). It might use specific
low-precision instructions if available and appropriate.  
This will likely enable FMAD generation, allow "flush-to-zero" mode for denormal numbers.
Additionally, it might disable `Nan` and `Inf`.  

Consult the Crisp documentation for any particular target for a complete rundown.

### selecting precision

Crisp provides three avenues for selecting precision. In order of specifity, 
from the least specific to the most specific, they are: 

| What                           |  Value           | Descripotion         |
|--------------------------------|------------------|----------------------|
| `--math-precision`             | `fast` or `ieee` | compilation flag     |
| `(declaim (precision <KEY>))`  | `fast` or `ieee` | per-file declamation |
| `(with-precision (<KEY>) ...)` | `fast` or `ieee` | in-function macro    |

If there are competing values for precision, the compiler will favor the MOST specific.

Example:
```
;; 1 
(declaim (precision fast))

;; 2  ... inside some function
    (with-precision (ieee)
        (/ important-divisor important-dividend))

;; 3 ... later
    (/ nobody-divisor nobody-dividend)
```
1. the file uses `declaim` to select fast precision
2. inside some function, the `with-precision` macro is used so the "important" division is highly accurate, regardless of any other setting.
3. the "nobody" division will use less accurate but fast division by virtue of the declaim in #1.
4. in the example above, the `--math-precision` flag would always be ignored. The `declaim` at file level 
would override.

#### overriding precision: `--force-math-precision`

The `--force-math-precision` compiler flag can be used to override ALL other precision choices.
It will override the developers stated intent, and for that reason it should be avoided. This flag is intended for validation and testing purposes and should not be used as part of your release
cycle.  The compiler emits a warning whenever this flag is used. 

