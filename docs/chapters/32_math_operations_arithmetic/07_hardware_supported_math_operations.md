# Hardware Supported Math Operations ✅


These ops expose single hardware instructions directly. They are implicitly templated over their
operand types. Unlike ordinary arithmetic, they mean the same thing in **every precision context**:
`op-fma` is always fused and the `*-approx` ops may always approximate, even under
`--math-precision=ieee`.

Several ops take an **accumulator** `c`. The accumulator decides the result type, and it may be
*wider* than the other operands ("widening"). The type rules are strict, and a violation is a
compile error:

- `a` and `b` must have exactly the same type. Promote one explicitly if they differ.
- `c` must be the same family as `a` and `b` (no mixing floats and integers) and have the same lane
  count (a `float4` multiplier needs a vector accumulator).
- `c` must be at least as wide as `a` and `b`. Two 16-bit float formats (`half`, `bfloat16`) are not
  interchangeable.
- For the integer multiply-adds, `c` must have the same signedness as `a` and `b`.

Widening is done *before* the operation, so nothing is rounded or wrapped at the narrow width.

#### `op-fma` Fused Multiply Add ✅
`(op-fma a b c) => ((a * b) + c)`

Fused Multiply Add is a hardware accelerated multiply and add that performs only ONE rounding. It is
available for all floating point types (`half`, `bfloat16`, `float`, `double`) and their hardware
vector variants (`float2`, `float4` etc).

To widen, use a larger type for the accumulator: `(op-fma 40.1h 30.2h 0.0f) => float` (both
multipliers are converted to `float` first, then one `float` fma).

`op-fma` always lowers to the guaranteed-fused instruction (`llvm.fma`; `OpenCL.std fma` on SPIR-V,
`fma.rn.*` on PTX), never to the merely-permitted contraction (`llvm.fmuladd`). Under `fast`
precision the compiler may fuse an ordinary `(+ (* a b) c)` on its own ... except when it doesn't.
Use `op-fma` when you want this hardware operation regardless of the precision setting.

#### `op-saturate`  Clamp Between 0.0 and 1.0 ✅
`(op-saturate f) => f`

Clamps a floating point value to be between 0.0 and 1.0. Works with all floating point types,
including the hardware vector variants. A NaN input saturates to 0.0.

#### `op-imad` Integer Multiply-Add ✅
`(op-imad a b c) => ((a * b) + c)`

Similar to `op-fma` but for integer types (signed and unsigned). Like ordinary integer arithmetic, the
result wraps in the accumulator's type.

The accumulator can be wider than `a` and `b`. To have `op-imad` perform widening, use a larger type for
the accumulator: `(op-imad 40s 30s 1i) => int` (the shorts are sign-extended to `int` before the
multiply, so the product cannot overflow 16 bits).

#### `op-imad-sat`  Integer Multiply-Add with Saturation ✅

`(op-imad-sat a b c) =>  SATURATE(   ((a * b) + c)   )`

Like `op-imad`, but the result is clamped to the accumulator's range instead of wrapping. The clamp is
applied ONCE, to the mathematically exact `a*b + c`, and the product is never saturated on its own
first. So `(op-imad-sat 65536 49152 INT_MIN)` is `1073741824`, not `-1`. Supports the same widening
as `op-imad`. Multipliers of 64 bits (`long`, `ulong`) are refused: the exact intermediate product
would need 128 bits.

#### `op-abs-diff` Absolute Value of Difference ✅

`(op-abs-diff a b ) =>  | a - b |`

Available for integer types (signed and unsigned). Takes the absolute value of a subtraction without a
branch. The result is the **unsigned** counterpart of the operand type (`char` -> `uchar`,
`int4` -> `uint4`), because `|a - b|` of two signed values can exceed the signed range:
`(op-abs-diff -128c 127c) => 255uc`.

#### `op-min3` / `op-max3`  Min / Max of 3 Arguments ✅
```
(op-min3 a b c) => T
(op-max3 a b c) => T
```
These find the minimum or maximum of 3 values of the same type, floating point or integer (scalars or
hardware vectors). For floats a NaN operand is ignored in favor of a number (IEEE 754-2008
`minNum`/`maxNum`). There is no three-argument `min` / `max` in Crisp; use these.

#### `op-rsqrt-approx` (Reciprocal Square Root) ✅
```
(op-rsqrt-approx x) => T
```
Most users shouldn't need or use this. Just choose `(precision fast)` and go about your business.

`op-rsqrt-approx` calculates an approximation of the reciprocal square root ($1/\sqrt{x}$).
- Input: `x`, a floating point scalar.
- Output: $y \approx 1/\sqrt{x}$, the same type as `x`.
- Use: Normalizing vectors. `normalize(v) = v * rsqrt(dot(v, v))`

The `*-approx` ops grant the compiler permission to approximate. They do not oblige it to. Where the
hardware has an approximate instruction, it is used. Otherwise the result may be exact. On NVIDIA PTX,
`op-rsqrt-approx`, `op-rcp-approx`, `op-exp2-approx`, `op-sin-approx` and `op-cos-approx` lower to
native `*.approx` instructions for 32-bit (and 16-bit) floats. On SPIR-V they use the OpenCL `native_*`
builtins where one exists. Test results against a tolerance, never bit patterns. The approximation is
good (for 32-bit floats, typically around 22 bits of precision): enough for lighting, normalizing
vectors, or Monte Carlo simulations, but not for scientific simulation or accumulated physics.

The `*-approx` ops are scalar-only for now.

#### `op-rcp-approx` (Reciprocal) ✅
```
(op-rcp-approx x) => T
```
 - Input: `x` (floating point)
 - Output: $\approx 1/x$
 - Use: Fast division. a / b can be computed as a * op-rcp-approx(b)

#### `op-log2-approx` (Base-2 Logarithm) ✅

```
(op-log2-approx x) => T
```
- Input: `x` as some floating point type
- Output: $\approx \log_2(x)$
- Use: Lighting calculations (gamma correction), entropy encoding, power calculation
- On PTX this needs libdevice linked (there is no native approximate log2 instruction).

#### `op-exp2-approx` (Base-2 Exponential) ✅

```
(op-exp2-approx x) => T
```
- Input: `x` as some floating point type
- Output: $\approx 2^x$
- Use: The inverse of log2. Combined with log2, it calculates generic powers: $x^y = 2^{y \cdot \log_2(x)}$.

#### `op-sin-approx` ✅
```
(op-sin-approx x) => T
```
- Input: `x` (radians, floating point)
- Output: $\approx \sin(x)$
- Use: Rotations, waves, procedural generation.

#### `op-cos-approx` ✅
```
(op-cos-approx x) => T
```
- Input: `x` (radians, floating point)
- Output: $\approx \cos(x)$

#### `op-sincos-approx` ✅
```
(op-sincos-approx x) => T T
```
- Input: `x` (radians, floating point)
- Output: two values, $\approx \sin(x)$ and $\approx \cos(x)$. Bind them with the multi-value `let`:
  `(let ((s c (op-sincos-approx x))) ...)`
- Use: Calculating both sine and cosine for the same angle (e.g., rotation matrices).

#### `op-abs-diff-add` Absolute Difference and Add ✅

```
(op-abs-diff-add a b c) => ( | a - b | ) + c
```

Computes the absolute value of the difference between `a` and `b` and adds it to the accumulator `c`.
Available for integer types (signed and unsigned), without branches. The accumulator decides the result
type. `|a - b|` is unsigned (as for `op-abs-diff`), so the accumulator must be an unsigned type at least
as wide as `a`, or a signed type strictly wider. For example, the difference of two 8-bit integers added
to a 32-bit integer is widened safely and returns a 32-bit integer.

#### `op-sad` Sum of Absolute Differences ✅
```
(op-sad a b c) => (Σ | a_i - b_i |) + c
```

A hardware-accelerated operation heavily optimized for computer vision, image processing, and video
encoding. `a` and `b` are integer hardware vectors (e.g. `uchar4`). It computes the absolute difference
for each lane, sums those differences, and adds the total to the scalar integer accumulator `c`.
Because summing several 8-bit differences easily overflows an 8-bit bucket, the accumulator must be
wider than the vector's element type. The accumulator decides the output type, usually a 32-bit integer.
Not yet differentiable (⚠️ needs vector adjoints).

#### Autodiff of the Hardware Math Operations ✅

All of these ops differentiate, except `op-sad` and every op on a hardware vector (⚠️ vector adjoints
are not supported yet). Integer operands get promoted adjoints, as for any integer.
- `op-fma`, `op-imad`: `da = b·g`, `db = a·g`, `dc = g`.
- `op-imad-sat`: as `op-imad` where the result is strictly inside the accumulator's range; zero where it clamped.
- `op-saturate`: `g` where the clamp is the identity (0 ≤ x ≤ 1), zero where it clamps.
- `op-abs-diff`, `op-abs-diff-add`: `da = sign(a-b)·g`, `db = -sign(a-b)·g` (sign(0) = 0), plus `dc = g`.
- `op-min3`, `op-max3`: the gradient goes to the selected operand; on a tie, to the first one.
- `*-approx`: the derivative of the exact function, *evaluated with the approximate ops* — `d sin(x) = cos(x)`
  is computed as `op-cos-approx`, `d rsqrt(x) = -0.5·rsqrt(x)/x`, and so on. The rule is the ordinary
  calculus; only its evaluation is approximate, matching the forward you asked for. (This also keeps the
  backward free of library calls: on PTX the exact `cos` and `pow` are libdevice symbols, so an
  exactly-evaluated gradient would force you to link `libdevice.10.bc`.) For `op-sincos-approx`,
  `dx = cos(x)·ds - sin(x)·dc`.

