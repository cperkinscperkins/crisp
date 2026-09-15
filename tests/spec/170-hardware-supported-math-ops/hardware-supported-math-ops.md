In this endeavor we'll be adding support the hardware supported math operations.  The original docs for this are in ideal_001.md, near line 8880, but I've copied that section of the docs below.

The docs are admittedly a little thin. If you see things that need to be firmed up, let me know.

Most of the ops assume implicit templating

```
(with-template-type (T) 
    (declare (type-is U #'is-floating-point?))  ;; <-- we don't support type constraints yet. This just illustrates intent. 
    (def-function op-min3 (a b c)
        (declare #'(T T T => T))
         ...))
```

But note that some of them support type "widening", where the accumulator term (`c`) can be a larger type than `a` or `b`.  The return type of the function is the same as the accumulator.


Another key feature is that these ops can occur in any precision context.  So even when --math-precision=ieee, op-fma results in a multiply and add that would not be strictly IEEE conforming. 




Plan
====

I've already cut a hardware-supported-math-ops and bumped ci-stop.txt

- write TDD tests for each operation
- including "widened" and "not widened" when relevant
- implement
- all our TDD tests will be subject to the --differentiate pass, so, ultimately, we'll need to think
  about their autodiff story. 




DOCS
====

### Hardware Supported Math Operations 📝

#### `op-fma` Fused Multiply Add 📝
`(op-fma a b c) => ((a * b) + c)`

Fused Multiply Add is a hardware accelerated multiply and add operation that performs
only one rounding operation.  It is available for all floating point types
 ( `half`, `bfloat16`, `float`, `double` ) as well as their hardware vector variants
 ( `float2`, `float4` etc).

 Importantly, note that the `c` accumulator term can be a different (larger) type than `a` and `b`.  To have `op-fma` perform widening, use a larger type for the accumulator.  example `(op-fma 40.1h 30.2h 0.0f) => float`

Note that the Crisp compiler outputs LLVM-IR, and if using `:fast` precisions, then the
LLVM-IR should be automatically optimized 
if addition followed by multiplication is detected ... except when it isn't. 

Use `op-fma` when you want this hardware operation, regardless of the math precision setting.

#### `op-saturate`  Clamp Between 0.0 and 1.0 📝
`(op-saturate f) => f`

Clamps a floating point value to be between 0.0 and 1.0.  Works with all floating point types, 
including the hardware vector variants.

#### `op-imad` Integer Multiply-Add 📝
`(op-imad a b c) => ((a * b) + c)`

Similar to `op-fma` but for integer types (signed and unsigned).

 Importantly, note that the `c` accumulator term can be a different type than `a` and `b`.  To have `op-fma` perform widening, use a larger type for the accumulator.  example `(op-imad 40s 30s 1i) => int`

#### `op-imad-sat`  Integer Multiply-Add with Saturation 📝

`(op-imad-sat a b c) =>  SATURATE(   ((a * b) + c)   )`

Similar to `op-imad`, this operation not only performs the add and multiply, but also clamps the result so there is no integer overflow.  Supports the same "widening" with the type of `c` as `op-imad`

#### `op-abs-diff` Absolute Value of Difference 📝

`(op-abs-diff a b ) =>  | a - b |`

Available for integer types (signed and unsigned). Takes the absolute value of a subtraction
and avoids a branch/conditional check.

#### `op-min3` / `op-max3`  Min / Max of 3 Arguments 📝
```
(op-min3 a b c) => f
(op-max3 a b c) => F
```
This routines find the minimum or maximum between 3 values of the same type. These can be either floating point or integer types. Note that Crisp `(min a b c)` gets
mapped to this same instruction automatically (and this is true for `max` as well), so this is redundant.  


#### `op-rsqrt-approx` (Reciprocal Square Root) 📝
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


#### `op-rcp-approx` (Reciprocal) 📝
```
(op-rcp-approx x) => float
```
 - Input: `x` (floating point)
 - Output: $\approx 1/x$
 - Use: Fast division. a / b can be compiled as a * op-rcp-approx(b)

#### `op-log2-approx` (Base-2 Logarithm) 📝

```
(op-log2-approx x:float) => float
```
- Input: `x` as some floating point type
- Output: $\approx \log_2(x)$
- Use: Lighting calculations (gamma correction), entropy encoding, power calculation

#### `op-exp2-approx` (Base-2 Exponential) 📝

```
(op-exp2-approx x) => float
```
- Input: `x` as some floating point type
- Output: $\approx 2^x$
- Use: The inverse of log2. Combined with log2, it calculates generic powers: $x^y = 2^{y \cdot \log_2(x)}$.

#### `op-sin-approx` 📝
```
(op-sin-approx x) => float
```
- Input: x (radians, floating point) 
- Output: $\approx \sin(x)$ 
- Use: Rotations, waves, procedural generation.

#### `op-cos-approx` 📝
```
(op-cos-approx x) => 
```
- Input: `x` (radians, flaoting point) 
- Output: $\approx \cos(x)$

#### `op-sincos-approx` 📝
```
(op-sincos-approx x) => float float
```
- Input: `x` (radians, floating point)
- Output: Returns two values: $\approx \sin(x)$ and $\approx \cos(x)$.
- Use: Calculating both sine and cosine for the same angle (e.g., rotation matrices). This often compiles to a single hardware instruction.



#### `op-abs-diff-add` Absolute Difference and Add 📝

```
(op-abs-diff-add a b c) => ( | a - b | ) + c
```

Computes the absolute value of the difference between `a` and `b`, and adds it to the accumulator `c`. Available for integer types (signed and unsigned). Avoids multiple conditional checks and branches.
Like `op-fma` and `op-imad`, this operation supports accumulator-based overloading to prevent integer overflow. The precision of the result is dictated by the type of the accumulator `c`. For example, calculating the difference of two 8-bit integers (`a`, `b`) and adding it to a 32-bit integer (`c`) will safely widen the intermediate result and return a 32-bit integer.

#### `op-sad` Sum of Absolute Differences 📝
```
(op-sad a b c) => (Σ | a_i - b_i |) + c
```

A hardware-accelerated operation heavily optimized for computer vision, image processing, and video encoding. While similar to `op-abs-diff-add`, `op-sad` is typically used when `a` and `b` are packed data types (such as four 8-bit integers packed into a single 32-bit register). It computes the absolute difference for each corresponding byte pair, sums all those differences together, and adds the total to the accumulator `c`.
Because summing multiple 8-bit differences easily overflows an 8-bit bucket, this operation practically mandates widening. The accumulator `c` dictates the output type, which is usually a 32-bit integer to safely hold the summed differences.



QUESTION from Claude, and Answers
=================================
1. What do the *-approx ops actually emit?
This is my main concern. I don't know of a portable "Special Function Unit (SFU) lookup table" instruction in either of our targets:

SPIR-V (OpenCL.std) has rsqrt, sin, cos, log2 and so on, but they're the ordinary functions, not approximations.
NVVM/libdevice also has __nv_rsqrt and friends, but again they're exact(ish) library calls.
If there's no approximate instruction underneath, op-rsqrt-approx becomes a hard-to-test promise. My proposal is to treat "approx" as permission, not obligation: the op may return the exact result, and it's lowered like the endeavour 128 transcendentals, just without precision gating. Tests would then check a tolerance, not bit patterns. Otherwise we'd need to commit to a specific approximation, like a polynomial or a Newton step. Do you know of a target instruction I'm missing?

A1:  treat "approx" as permission, not an obligation.
In LLVM IR, you don't call a specific "approximate" intrinsic. Instead, you emit the standard llvm.sin.* or llvm.cos.* intrinsic and attach the afn (Approximate Functions) fast-math flag. This tells the backend (PTXAS or IGC) that it is permitted to substitute the SFU hardware instruction (like sin.approx.f32 in PTX). For SPIR-V, you emit the standard GLSL.std.450 instruction, potentially decorated with RelaxedPrecision or FastMath flags.
Testing against a tolerance rather than exact bit patterns is the only sane way to test this across different GPUs.



2. What exactly does op-imad-sat saturate?
"SATURATE((a*b)+c)" has at least three readings, and they give different answers when a large a*b meets a negative c:

(a) Compute exactly in a wide enough type, then clamp to c's type once.
(b) Saturating multiply, then saturating add (smul_fix_sat → sadd_sat).
(c) Wrapping multiply, then saturating add.
I'd lean toward (a) as the definition, with (b) allowed when widening makes the two agree.

A2: Agreed on (a) Compute exactly in a wide enough type, then clamp to c's type once.
This is what developers expect mathematically, and it's how hardware mad.sat instructions are implemented natively (calculating the internal product at double width before the final saturating clamp). Doing a saturating multiply followed by a saturating add (b) can lead to early clamping that returns an incorrect final sum.



3. What are the widening rules?
Narrower c: Can c be narrower than a/b? The fma text says "larger", but the imad text says "different". I'd make narrower c a compile error and add a negative test.
Mixed families: Must c be in the same family? For example, half a, half b, double c is presumably fine, but what about float a, int c?
Mismatched a and b: Must a and b be the same type, or do they get promoted?
Widened fma: For (op-fma 40.1h 30.2h 0.0f), I assume we fpext a and b to float first, then call llvm.fma in float. That's still one rounding.

A3: Let's lock down strict, unambiguous rules for the frontend:

- Narrower c: Compile error. The accumulator must be $\ge$ the width of the multipliers. Negative tests are a great idea here.

- Mixed families: Compile error. No mixing floats and ints in a single FMA/IMAD operation. The user must explicitly cast beforehand.

- Mismatched a and b: Compile error. a and b must be the exact same type. If they want to multiply i8 by i16, force them to promote the i8 first. This keeps the compiler logic clean.

- Widened fma emission: Correct. For (op-fma 40.1h 30.2h 0.0f), Crisp should emit two fpext instructions (from half to float), followed by a standard float llvm.fma. The backend will pattern-match this into a mixed-precision hardware instruction.




4. What does op-abs-diff return for signed types?
For signed a/b, |a-b| can exceed the signed range. OpenCL's s_abs_diff returns the unsigned counterpart. Should Crisp do that too (char → uchar), or return the same type and wrap?

A4: let's go with the unsigned counterpart.  Thank you!

5. What are op-sad's operand types?
The doc talks about "four 8-bit integers packed in a 32-bit register". Is a a uint of packed bytes, or a hardware vector like uchar4 (if that exists)?

A5: For op-sad, a and b should be hardware vectors (e.g., <4 x i8> in LLVM IR, analogous to uchar4).

5.5  Relatedly, does Crisp have multiple return values for op-sincos-approx, or does that need a record/float2 return?

A5.5: Crisp has multiple value return. It uses `return` instead of `values`:   `(return 7 9)`
  And they are bound in an extended special `let` form:
  `(let ((quot rem (divide 7 4))) ...) ; assuming divide returns two values`

6. Autodiff
op-fma: Easy (da = b·g, db = a·g, dc = g).
op-saturate: A step function.
Integer ops: No adjoints, so AD should just pass through them.
Approx ops: I'd use the exact function's derivative.

A6:  Crisp supports mathematically correct autodifferentiation. It DOES support differentiation of integers, it doesn't throw them out like a lot of lesser products.  Does that make sense?

Small things
-----------
`llvm.fma` vs `llvm.fmuladd`: Claude is right to distinguish these. `llvm.fmuladd` gives the backend permission to fuse if it thinks it's a good idea. `llvm.fma` forces the fused instruction. Since the user called `op-fma`, emit `llvm.fma`.


NaN handling for min/max: Use minnum (IEEE 754-2008). It returns the valid number if one operand is NaN.



Follow-ups (Claude)
===================

A6 correction: integers DO differentiate
----------------------------------------
Chapter 43: integer inputs receive *promoted* adjoints (small ints -> `float`, `long`/`ulong` -> `double`).
So every integer op needs a real backward rule, not a pass-through. First cut:

- `op-imad`: `da = b*g`, `db = a*g`, `dc = g` (promoted type)
- `op-imad-sat`: as `op-imad` where unclamped; zero where clamped
- `op-abs-diff` / `op-abs-diff-add`: `da = sign(a-b)*g`, `db = -sign(a-b)*g` (`dc = g` for `-add`)
- `op-sad`: same rule per lane, `dc = g`
- `op-min3` / `op-max3`: gradient routes to the selected operand
- `op-fma`: `da = b*g`, `db = a*g`, `dc = g`
- `op-saturate`: `g` inside (0,1), zero outside
- `*-approx`: derivative of the exact function

Conventions to settle: the kink at `a == b` (copy the existing `abs` rule) and ties in min3/max3
(no existing `min`/`max` AD handling was found, so this may be ours to define).

A1 notes: what to verify manually
---------------------------------
- Our SPIR-V is OpenCL-kernel flavoured: the translator maps `llvm.sin` -> OpenCL.std `sin`, not GLSL.std.450.
- Fast-math flags only reach SPIR-V as an `FPFastMathMode` decoration if the translator emits it,
  and `-O3` strips `!spirv.Decorations` (see memory). Check what actually lands in the `.spv`.
- `sin.approx.f32` on PTX is a hypothesis -- check the PTX output.
- There is no `llvm.rsqrt` or reciprocal intrinsic: `op-rsqrt-approx` = `1/sqrt`, `op-rcp-approx` = `fdiv 1.0`,
  each with `afn`/`reassoc`. `llvm.exp2` and `llvm.log2` exist.
- Flags are per-instruction, so `afn` calls can live inside an `ieee` kernel.

OPEN: A3 signedness
-------------------
e.g. `short a, short b, uint c`. Proposal:
- `imad` / `imad-sat`: accumulator must match the signedness of `a`/`b`.
- `abs-diff-add` / `sad`: `|a-b|` is already unsigned (A4), so `c` should be unsigned, or signed and strictly wider.

Small
-----
- Line 18 wording: `fusedMultiplyAdd` IS an IEEE 754 operation. Suggest "is not subject to the precision
  mode's contraction rules" rather than "not strictly IEEE conforming".
- Hardware vector types (`float4`, `uchar4`) have only ~3 references in `src/`; support may be thin.
  Decision: stay in scope, retreat if needed.


Test List (approved)
====================
Grouped by op, `NN-name.crisp`; negative specs under `errors/`.

Forward (compile + manual IR/SPV check)
---------------------------------------
- 01-fma-float                   -- emits `llvm.fma` (not `fmuladd`) under `ieee`
- 02-fma-double                  -- non-widened, double
- 03-fma-half-widen-float        -- doc example: two `fpext`, then `float` fma
- 04-fma-float-widen-double      -- second widening pair
- 05-fma-float4                  -- vector variant
- 06-saturate-float              -- clamp to 0..1
- 07-saturate-half               -- smaller type
- 08-saturate-float4             -- vector variant
- 09-imad-int                    -- non-widened, signed
- 10-imad-uint                   -- non-widened, unsigned
- 11-imad-short-widen-int        -- doc example `(op-imad 40s 30s 1i)`
- 12-imad-sat-int                -- non-widened; wider internal type, one clamp
- 13-imad-sat-short-widen-int    -- widened
- 14-abs-diff-int                -- returns `uint` (A4)
- 15-abs-diff-uchar              -- unsigned in, unsigned out
- 16-abs-diff-add-char-widen-int -- doc example (8-bit into 32-bit)
- 17-sad-uchar4-uint             -- vector operands, scalar accumulator
- 18-min3-max3-float             -- `minnum`/`maxnum`
- 19-min3-max3-int               -- integer variants
- 20-rsqrt-approx                -- `1/sqrt` + `afn`/`reassoc`; check the flag survives
- 21-rcp-approx                  -- `fdiv 1.0` + flags
- 22-log2-approx
- 23-exp2-approx
- 24-sin-cos-approx
- 25-sincos-approx               -- two values via `(return s c)` and multi-value `let`

On metal (L0, and PTX where they differ)
----------------------------------------
- 26-fma-metal         -- inputs where fused != unfused in the last bit (proves real fusion)
- 27-imad-sat-metal    -- overflow edges both directions; large `a*b` vs negative `c` (A2 (a) vs (b))
- 28-abs-diff-sad-metal -- signed extremes (e.g. `-128`, `127` -> `255`)
- 29-min3-nan-metal    -- NaN operand returns the valid number
- 30-approx-metal      -- all approx ops against tolerance

Autodiff (VERIFY-AUTODIFF)
--------------------------
- 31-fma-ad            -- includes a widened case
- 32-imad-ad           -- promoted integer adjoints
- 33-imad-sat-ad       -- zero gradient in the clamped region
- 34-abs-diff-ad       -- sign rule; kink convention from `abs`
- 35-min3-max3-ad      -- routes to the selected operand
- 36-approx-ad         -- exact-function derivatives

Negative (`errors/`)
--------------------
- 01-fma-narrow-accumulator
- 02-fma-mixed-family
- 03-fma-a-b-mismatch
- 04-imad-float-operand
- 05-imad-signedness-mismatch  -- pending OPEN A3 signedness
- 06-abs-diff-float
- 07-saturate-int
- 08-sad-scalar-operands


