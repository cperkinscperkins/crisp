## Hardware Supported Math Operations


### `op-fma` Fused Multiply Add
`(op-fma a b c) => ((a * b) + c)`

Fused Multiply Add is a hardware accelerated multiply and add operation that performs
only one rounding operation.  It is available for all floating point types
 ( `half`, `bfloat16`, `float`, `double` ) as well as their hardware vector variants
 ( `float2`, `float4` etc).

Note that the Crisp compiler outputs LLVM-IR, and if using `:fast` precisions, then the
LLVM-IR should be automatically optimized 
if addition followed by multiplication is detected ... except when it isn't. 

Use `op-fma` when you want this hardware operation, regardless of the math precision setting.

### `op-saturate`  Clamp Between 0.0 and 1.0
`(op-saturate f) => f`

Clamps a floating point value to be between 0.0 and 1.0.  Works with all floating point types, 
including the hardware vector variants.

### `op-imad` Integer Multiply-Add
`(op-imad a b c) => ((a * b) + c)`

Similar to `op-fma` but for integer types (signed and unsigned).

### `op-imad-sat`  Integer Multiply-Add with Saturation

`(op-imad-sat a b c) =>  SATURATE(   ((a * b) + c)   )`

Similar to `op-imad`, this operation not only performs the add and multiply, but also clamps the result so there
is no integer overflow.

### `op-abs-diff` Absolute Value of Difference

`(op-abs-diff a b ) =>  | a - b |`

Available for integer types (signed and unsigned). Takes the absolute value of a subtraction
and avoids a branch/conditional check.

### `op-min3` / `op-max3`  Min / Max of 3 Arguments
```
(op-min3 a b c) => f
(op-max3 a b c) => F
```
This routines find the minimum or maximum between 3 values of the same type. These can be either floating point or integer types. Note that Crisp `(min a b c)` gets
mapped to this same instruction automatically (and this is true for `max` as well), so this is redundant.  


### `op-rsqrt-approx` (Reciprocal Square Root)
```
(op-rsqrt-approx x) => float
```
Most users shouldn't need or use this.  Just choose `(precision fast)` and go about your business.

`op-rsrt-approx` calculates an approximation of the reciprocal square root ($1/\sqrt{x}$)
This op uses the hardware's Special Function Unit (SFU) lookup table to return a value that 
is close to the true mathematical result, but much faster to compute.
- Input: x (a float).
- Output: A float value $y \approx 1/\sqrt{x}$.   
- Use: Normalizing vectors. `normalize(v) = v * rsqrt(dot(v, v))`

The approximation usually has an error of around $2^{-22}$ (for 32-bit floats on modern GPUs), 
which equates to about 22 bits of precision. This is surprisingly good—enough for lighting calculations, 
normalizing vectors, or Monte Carlo simulations—but not enough for scientific simulation or accumulated physics.


### `op-rcp-approx` (Reciprocal)
```
(op-rcp-approx x) => float
```
 - Input: `x` (floating point)
 - Output: $\approx 1/x$
 - Use: Fast division. a / b can be compiled as a * op-rcp-approx(b)

### `op-log2-approx` (Base-2 Logarithm)

```
(op-log2-approx x:float) => float
```
- Input: `x` as some floating point type
- Output: $\approx \log_2(x)$
- Use: Lighting calculations (gamma correction), entropy encoding, power calculation

### `op-exp2-approx` (Base-2 Exponential)

```
(op-exp2-approx x) => float
```
- Input: `x` as some floating point type
- Output: $\approx 2^x$
- Use: The inverse of log2. Combined with log2, it calculates generic powers: $x^y = 2^{y \cdot \log_2(x)}$.

### `op-sin-approx` 
```
(op-sin-approx x) => float
```
- Input: x (radians, floating point) 
- Output: $\approx \sin(x)$ 
- Use: Rotations, waves, procedural generation.

### `op-cos-approx`
```
(op-cos-approx x) => 
```
- Input: `x` (radians, flaoting point) 
- Output: $\approx \cos(x)$

### `op-sincos-approx`
```
(op-sincos-approx x) => float float
```
- Input: `x` (radians, floating point)
- Output: Returns two values: $\approx \sin(x)$ and $\approx \cos(x)$.
- Use: Calculating both sine and cosine for the same angle (e.g., rotation matrices). This often compiles to a single hardware instruction.

