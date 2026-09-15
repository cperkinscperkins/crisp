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




op-fma: Trace + Implementation Plan (PROPOSED, 2026-09-14)
===========================================================

Backend probes (hand-written .ll, put_temp_files_here/170-probe/)
-----------------------------------------------------------------
- SPV: `llvm.fma.f32` / `.f64` / `.v4f32` / `.f16` -> `ExtInst OpenCL.std fma` (vector stays one call).
  `.bf16` needs `--spirv-ext=+SPV_KHR_bfloat16` (compiler.lisp:750 already passes it; BMG driver does
  NOT implement that extension -- codegen.lisp:5079 -- so bf16 is compile-only on Intel).
- PTX: `llc -march=nvptx64` lowers `llvm.fma.*` to NATIVE instructions: `fma.rn.f32`, `fma.rn.f64`,
  `fma.rn.f16`, `fma.rn.bf16`; `<4 x float>` scalarizes to four `fma.rn.f32`. No libdevice needed
  (unlike the 128 transcendentals, where a bare `llvm.sin` crashes llc).
- So op-fma needs NO target routing: emit `llvm.fma.<suffix>` everywhere.

How endeavour 128 wired a math op (the template)
------------------------------------------------
| Layer | Where | op-fma needs |
|---|---|---|
| Export | package.lisp:200, 534, 586 | `op-fma` in all three -- PATCH (Chris) |
| Node | semantic.lisp:154 `(defstruct semantic-atan2 type left-arg right-arg source-location)` | `(defstruct semantic-fma type a b c source-location)` -- PATCH (struct) |
| Analyzer | analysis/ops.lisp `def-binary-math-analyzer`; registered in `register-ops-analyzers` (ops.lisp:497) | `analyze-fma-expression` (A3 rules, result = c's type); registration -- OVERLAY |
| Node dispatch | analysis/core.lisp:2225 `semantic-node-type`, :2305 source-location, :1918 `calculate-uniformity-state` | a `semantic-fma` clause in each -- OVERLAY (whole-fn) |
| Uniformity | analysis/core.lisp:1215 `%uni-analyze` contagion list | add "OP-FMA" -- OVERLAY |
| Codegen | codegen.lisp:1582 `def-binary-math-codegen` + `%math-call-name` | own `generate-node-ir` method: fpext a,b to c's type (`build-cast-if-needed`), call `llvm.fma.<sfx>`. No `%math-call-name`. -- OVERLAY |
| AD rule | autodiff.lisp:401 `%handle-math-and-trig-backward` | clause: `da += b*g`, `db += a*g`, `dc += g` -- OVERLAY (whole-fn) |
| AD dispatch | autodiff.lisp:699 in `%handle-single-value-backward` | add `op-fma` to the member list -- OVERLAY (whole-fn) |
| Activeness | autodiff.lisp:3538 `%active-scalar-vars` | "OP-FMA" joins the POW/ATAN2 union clause -- OVERLAY (whole-fn) |

Decisions to confirm
--------------------
1. No fast-math flags on the fma call (it is precision-independent; `%apply-precision-fmf` not applied).
2. Intrinsic suffix from c's type: half->f16, bfloat16->bf16, float->f32, double->f64, floatN->vNf32,
   doubleN->vNf64 (small helper).
3. A3 analyzer checks, each with its own error message for errors/01-03:
   a,b same type; family match (float scalar, or float device-vector with matching lane count);
   width(c) >= width(a).

Risks / open
------------
- BUG 060: spec 05's FORWARD never emits fmul (fma is one call), so it can pass. But its BACKWARD
  emits `(* b g)` on float4 -> integer `mul` -> invalid IR. So 05's --differentiate pass depends on
  060. Fix 060 inside this endeavour, or SKIP-WITH[--differentiate] citing 060?
- Widened backward: `da = b*g` where b is half and g is float. Need to see what adjoint type a half
  param gets (endeavour 163: 16-bit weights / 32-bit grads) and that no narrowing store (BUG 059 class)
  appears. Check the backward IR by hand.
- Registration: if `initialize-compiler` rebuilds `*expression-analyzers*` via
  `register-ops-analyzers`, a standalone `def-expression-analyzer` in the overlay is wiped; then the
  whole function must be redefined.  Verify.
- -O3: confirm opt does not unfuse `llvm.fma` (check the optimized IR / .spt / .ptx, not just .ll).


Decisions (made autonomously, 2026-09-14 night -- REVIEW THESE)
===============================================================
Chris went to bed with "make a choice and record it". Each entry: the choice, and why.

D1. Package exports + node struct live in the OVERLAY for now (not the src patches in
    put_temp_files_here/170-patches.md). A NEW defstruct is safe to overlay; only redefining an existing
    one is not. The patch file remains the intended final form when folding.
D2. ONE generic semantic node for every endeavour-170 op, instead of 16 structs:
    `(defstruct semantic-hw-op op type args source-location)`. One clause per node dispatcher, one
    codegen method that dispatches on OP. (Supersedes `semantic-fma` in 170-patches.md.)
D3. Dispatchers (semantic-node-type, semantic-node-source-location, calculate-uniformity-state,
    %uni-analyze, register-ops-analyzers, and the AD entry points) are extended by WRAPPING: the overlay
    captures the original function object and defines a new one that handles hw-ops and delegates the
    rest. When folding into src, each wrapper becomes one ordinary clause.
D4. A3 signedness (was OPEN): imad / imad-sat need the accumulator to have the SAME signedness as a/b.
    abs-diff-add / sad: |a-b| is unsigned, so c may be unsigned (width >= element) or signed (strictly
    wider). Violations are compile errors.
D5. Integer lowering uses LLVM intrinsics, because there is no LLVMBuildSelect binding and intrinsics
    translate cleanly (probed): abs-diff = umax/smax(a,b) - umin/smin(a,b) (wrapping sub is exact
    because the true value always fits the unsigned result); min3/max3 = nested smin/umin/minnum.

Backend probes for intrinsics (hand .ll, put_temp_files_here/170-probe/)
-------------------------------------------------------------------------
SPV (llvm-spirv): minnum/maxnum -> OpenCL.std fmin/fmax (vector stays one call); sadd.sat/uadd.sat ->
s_add_sat/u_add_sat; smin/umax lower without an ExtInst (inline); exp2 -> exp2; sqrt -> sqrt.

PTX (llc -mcpu=sm_89) -- the .approx instructions are REAL and need NO libdevice:
| IR | f32 | f16 | f64 |
|---|---|---|---|
| `call afn|fast @llvm.sin/cos` | sin.approx.f32 / cos.approx.f32 | via f32 (cvt) | LLVM ERROR Cannot select -> needs libdevice |
| `fdiv afn 1.0, (call afn @llvm.sqrt)` | rsqrt.approx.f32 | (not probed; rcp shows cvt path) | sqrt.rn + rcp.rn (exact) |
| `fdiv afn 1.0, x` | rcp.approx.f32 | rcp.approx via cvt | rcp.rn.f64 (exact) |
| `call @llvm.exp2` (even no flags) | ex2.approx.f32 | ex2.approx.f16 | no libcall -> needs libdevice |
| `call afn|fast @llvm.log2` | no libcall -> needs libdevice | | |
| no flags `@llvm.sin` | LLVM ERROR Cannot select | | |
Also: `afn` alone is enough; `fast` is not required. Plain `fdiv 1.0, x` is rcp.rn (exact).
Other PTX: minnum/maxnum -> min.f32/max.f32, smin -> min.s32, fma -> fma.rn.*.

D1 (REVISED). The package exports could NOT live in the overlay: when the build re-evaluates
    src/package.lisp's defpackage, SBCL raises a package-variance WARNING ("also exports") and the build
    fails. So src/package.lisp WAS PATCHED directly (the three lists from 170-patches.md, all 16 op
    symbols). The node struct is still in the overlay (a NEW defstruct is safe there).
D3 (NOTE). Wrappers capture the original in a DEFVAR via FDEFINITION. The first attempt,
    `(let ((original #'f)) (defun f ...))`, overflowed the stack: SBCL folds (funcall original) into a
    direct call to the global F, i.e. the wrapper itself.
D6. NaN: op-saturate(NaN) = 0.0 (minnum(maxnum(x,0),1); maxnum returns the number). op-min3/max3 use
    minnum/maxnum (the Q&A answer). Metal-verified on BMG (29).
D7. op-saturate backward: g where the clamp is the identity (0 <= x <= 1, endpoints INCLUDED -- computed
    as (= (op-saturate x) x)), 0 where it clamps.
D8. op-imad-sat backward: op-imad's rule times a mask that is 1 where the recomputed saturated result is
    STRICTLY inside c's range (so a result exactly at INT_MAX counts as clamped). The mask is an internal
    op, (%hw-sat-interior r), because Crisp has no typed min/max literals for an arbitrary int type.
D9. op-abs-diff(-add) backward: sign(a-b) with sign(0) = 0, built as to-float(a>b) - to-float(a<b).
    (There was no existing abs backward rule to copy.)
D10. op-min3/max3 backward: the gradient goes to the selected operand; ties go to the FIRST operand
    (a, then b). Built from (= x r) / (!= x r) comparisons against the recomputed result.
D11. op-imad-sat refuses 64-bit multipliers (long/ulong): the exact product needs i128, which neither
    SPIR-V nor PTX offers portably. Lowering: W = max(2*width(a), width(c)) <= 64; exact product in W;
    add.sat in W; clamp to c + trunc only when W > width(c). Negative spec errors/09.
D12. The *-approx ops are SCALAR-only for now (negative spec errors/12). Half/bfloat16 x on the
    library-routed ops (log2, sin, cos on SPV) is fpext'd to float, computed, and fptrunc'd back.
D13. op-sad accumulator must be strictly wider than the element type (both signednesses); the sum
    wraps in c like op-imad otherwise. |a-b| lanes are zero-extended and summed via extractelement
    (not llvm.vector.reduce.add, to keep to forms both translators accept).
D14. *-approx lowering: PTX f32 sin/cos = llvm intrinsic + afn (native sin/cos.approx); rsqrt =
    afn(1/afn sqrt) (native rsqrt.approx); rcp = afn fdiv (native rcp.approx); exp2 = llvm.exp2 + afn
    (native ex2.approx; PTX f64 calls libdevice __nv_exp2); log2 = the 128 fast-precision route
    (SPV native_log2, PTX __nv_fast_log2f -> needs libdevice). SPV: the translator itself turns afn
    sqrt/exp2 into native_sqrt/native_exp2. Everything gets afn (all flags under fast).
D15. The doc's claim "(min a b c) is mapped to op-min3 automatically" is FALSE -- Crisp has no min/max
    analyzer. The ideal_001 text now says to use op-min3/op-max3; adding a 3-arg min/max was out of scope.
D16. Integer-op AD cannot be metal-verified (VERIFY-AUTODIFF feeds float cells only, and float->int is
    AD-inert), so 32-34 validate the BACKWARD IR (promoted sitofp operand in the chain-rule fmul; mask /
    sign comparisons). To let a TEST-WITH validator see the backward, run-spec-precision-pass (spec-runner
    overlay) now honors --differentiate in its flags.
D17. The L0 host harness prints a uchar BUFFER as a raw byte, which the runner cannot decode (it crashed
    the output copy in 28). 28 reports the op-abs-diff result through (to-uint ...), a zext, which still
    proves the 8-bit result was unsigned 0xFF. Harness not changed.
D18. CUDA hoist lines were added to the metal specs 26-29 (they SKIP here: nvcc not available). 30 is
    L0-only because op-log2-approx on PTX needs libdevice (FFI-LINK). NOT verified on NVIDIA.


Status (2026-09-15 night run)
=============================
IMPLEMENTED (overlay + src/package.lisp): all 16 ops, analyzer + type rules, codegen for generic/SPV/PTX,
AD for all scalar ops except op-sad and op-sincos-approx. BUG 060 fixed. BUG 061 and 062 filed.

Specs (37 + 12 negative), all passing locally:
- 01-25 forward, IR checked by validators AND by hand (all 16 ops compiled to .ll -> llvm-as OK, SPV, PTX).
- 26-30 on metal (Intel BMG, Level Zero): fused fma (with an unfused CONTROL that prints 0 -- the spec
  discriminates), imad-sat exact clamp incl. the reading-(a)-vs-(b) case, abs-diff/sad extremes, NaN
  handling, all approx ops against tolerance.
- 31, 35, 36, 37 VERIFY-AUTODIFF on BMG: fma, min3/max3 routing, all six approx derivatives, saturate.
- 32-34 integer AD via backward-IR validators (D16).
- errors/01-12.
Planned-list mapping: plan 31-36 became 31-37 (37-saturate-ad added); errors 09-12 added.

GAPS (recorded, SKIP-WITH cites them)
- Device-vector AD: BUG 061 (05, 08, 17).
- op-sad backward rule (17) -- blocked on vector adjoints anyway.
- op-sincos-approx backward (25) -- multi-value AD.
- *-approx on vectors (D12).
- Widened-fma AD is hand-checked, not metal-verified (VERIFY-AUTODIFF: float cells only).
- NVIDIA on-metal not run (no nvcc here); the PTX .ptx output was inspected by hand instead.
- `(map-stride #'op-fma ...)` (ideal_001 ~5968) was not exercised.

D19. op-sincos-approx AD. Found: a multi-value binding (S C (op-sincos-approx X)) reaches
    generate-backward-walk's multi-value clause, which differentiates only REGISTERED functions, so the
    gradient was SILENTLY ZERO (s_adj/c_adj accumulated, x_adj never did). Fix (overlay part 3): wrap
    generate-backward-walk to split each such binding -- at any depth -- into (S (op-sin-approx X)) and
    (C (op-cos-approx X)) before the walk. Metal-verified by 38-sincos-ad (analytical -0.08127, FD
    -0.08118). The skip on 25 was removed. NOTE for the future: ANY non-registered multi-value producer
    in that clause gets a silent zero gradient -- worth an error in the clause's else branch.

Status update: op-sincos-approx is now differentiable; GAPS list item removed. Specs now 01-38 + errors/01-12.
