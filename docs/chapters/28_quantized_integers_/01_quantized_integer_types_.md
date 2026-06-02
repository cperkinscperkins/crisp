# Quantized Integer Types ✅


These are the Crisp `qint` base types pre-defined for you.   

| Type   | Size    | 
|--------|---------|
| qb8  | 1 byte  | 
| qb16 | 2 bytes | 
| qb32 | 4 bytes | 
| qb64 | 8 bytes | 

Note that there are no mathematical operations defined for any of them. 
But once you define your own qint type there will be
operations defined for your type. You'll typically need to define your OWN qint type like so:

### def-qint

```
(def-qint q-fahrenheit :base qb8 :accum qb32)
(def-qint q-celcius :base qb8 :accum qb32)
```
Note that even though `q-fahrenheit` and `q-celsius` above have the exact same base and accumulator
types that they CANNOT be intermixed.  This is because they might have different scale and zero-point
references. These types are nominally-typed. The compiler will error if you try to mix different 
classes, preventing you from accidentally combinging data with different scales.

The `def-qint` for `q-celcius` above expands to
```
;; simple type aliases
(def-type q-celcius qb8)
(def-type q-celcius-accum qb32)

;; a new overload of the accum type function
(def-type-function accum (T:q-celcius) 
   q-celcius-accum)
;; and of the base type function, just returns same type
(def-type-function base (T:q-celcius)
  q-celcius)
```

Plus the following conversion and math functions.
Using `B` for the `:base` type and `A` for the `:accum` , here are the operations

<!-- 
TO BE REMOVED
Once `def-qint` is used it defines TWO new types: `XXXX-base` and `XXXX-accum` for you to use.

-->

### to-XXXX

For your `qint` type, a matching function `to-XXXX` is defined. It takes the floating point value in question along with scale and zerop (also floating point) and returns a scaled value in the base type `B`.

Example:
```
(to-q-celsius <float> <zero-point> <scale>) => <q-celsius>
;; e.g:
(to-q-celsius 23.204:float 0.0 50.0) => temp
```
where `temp` would be a 1-byte `qb8` but aliased as `q-celcius` 

### to-float

To convert either the base type `B` or the accumulator type `A` back to a 
floating point number, the `zero-point` and `scale`  must both be provided. 
These should be floating point values (`float`, `double`, `bfloat16` etc)
The value that is returned is of the same floating point type. 

Note that when converting accumulators, you need to square the scale if the widening
is the result of multiplying the base type.  If it was widened simply to handle a lot of addition (as in a reduction) then the scale remains the same. If the accumulator represents multiple multiplications, then it should be `(pow scale num-of-multiplications)`

```
(to-float B zero-point scale) => F

(to-float-accum A zero-point scale-squared) => F  
```

### additon and subtraction

Addition and Subtraction are available for both the base type `B` and `A` but not across them.

```
(+ B B) => B
(- B B) => B

(+ A A) => A
(- A A) => A
```

Implementation note: addition and subtraction are NOT defined for any of the qint base types.
But there are compiler-only primitives that map to the hardware instrucions (`iadd`) and these 
are used when we overload `+` and `-` for any `def-qint` instance.

### `*!` widened multiplication

Multiplication of two base types returns an accumulator type. There is no other option for 
multiplication. 

```
(*! B B) => A
```

<!-- NOTE:
  In theory we could provide a (* B A) affordance, but doing so 
  means we'd also have to accompany every accumulator value with a "scale-power" that 
  trackes how much multiplication it has captured, and then to convert
  back (to-float-accum A zero-point original-scale scale-power)  which wouuld (pow original-scale scale-power) to get the right scaling factor.

  The problem here is that this means ALL multiplication now needs to return TWO values with
  the scale-factor being the second value. And the multiplciation of B * A would require 
  an additional scale-factor parameter: (* B A SPi) => A SP

  This is ugly as hell and no one is doing this or asking for it.  Someone can 
  always come along and overload/macro this up if they want.  

  Right now we just have (to-float-accum) require a scale-squared and we don't allow B * A multiplication. 
  Simple. Neat.
 -->

### max / min

`max` and `min` are available for both base and accumulator types.
(Spoiler Alert: `max` and `min` are NOT available for `microfloat-block` in next section)

```
(max B B) => B
(min B B) => B

(max A A) => A
(min A A) => A
```

### all other math ops

For all other math operations, you'll need to conver your `qint` back to a floating point value
and then perform the calculation on that (and then convert back). 

### type promotion

Quantized ints have no automatic type promotion. 

### scale and zero-point independence

An interesting aspect of using quantized integers, is that the scale and zero-point
factors are only needed to convert to and from regular floating point values.
If conducting only the basic (admitedly limited) arithmetic, then those values aren't even
required.
Of course, the flip side of that, is that if you DO need to convert, then those scale and
zero-point values will have to be passed as additional independent arguments. 


### Illegal Combinations and Target-Specific Behavior

The entire purpose of Crisp's quantized integer types is to leverage the extreme performance 
of specialized AI hardware (like Tensor Cores or Intel's XMX engines). 
This hardware is not for general-purpose integer math; it is highly optimized for 
the "sum of products" (dot-product) pattern.

This means the compiler's behavior is strict and depends on your chosen output target.

#### 1. When Compiling (to LLVM IR, SPIR-V, or PTX)

This path is optimized for **maximum performance**. The compiler acts as a strict gatekeeper and maintains a "whitelist" of `qint` combinations that are known to map directly to hardware intrinsics.

- Supported Combinations: The most common (and often only) combination supported by hardware is `:base qb8` with `:accum qb32`. When the compiler sees this, it generates the correct high-performance intrinsic (e.g., `OpSDot` in SPIR-V or `mma.sync` in PTX).
- Unsupported Combinations: If you define a type that is not on this hardware "whitelist" (e.g., `:base qb16` with `:accum qb64`), the compiler will emit a compile-time error.
- No Emulation: The compiler will NOT silently generate a slow "emulation" path. This is a core design choice: it is better to give you a compile-time error than to let you ship a kernel that is 100x slower than you intended.

#### 2. When Transpiling (to OpenCL C)

This path is optimized for maximum portability and debugging, not performance. The transpiler has no way to guarantee that specific hardware intrinsics are available.

- Therefore, in this mode, the strict "whitelist" rules are relaxed.
- Crisp will generate a slow, emulated `for` loop to perform the quantized operations (like `B*B => A` and `A+A => A`).
- This ensures the transpiled C code is portable and works, but it will have severely suboptimal performance as it will NOT use the specialized AI hardware.


