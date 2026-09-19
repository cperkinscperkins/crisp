# Looping Constructs ✅


Here is a list of the looping constructs supported by Crisp. Some are discussed elsewhere.

- loop-vector-stride / loop-soa-stride
- tensor-stride
- grid-stride
- tile-stride
- hardware-stride
- stride helper functions:
- - tensor-coords
- - tile-coords
- - tile-indices
- - load-tile
- - store-tile
- workgroup-stride
- dotimes / dotimes+
- do-times-by-doubling / do-times-by-doubling+
- do-times-by-multiply / do-times-by-multiply+
- dec-times / dec-times+
- dec-times-by-half / dec-times-by-half+
- dec-times-by-factor / dec-times-by-factor+
- do-power-step / do-power-step+
- dec-power-step / dec-power-step+

#### Immutable Index
All of the above bind a loop index. Unlike in a C++ `for` loop, that index value is immutable in the 
body of the loop.

#### + variants ✅
Most of the Looping Constructs have a variant whose name ends in `+`. 
The compiler will check that EVERY operand — `N`, and also `init`, `stride` and `factor` where
the form takes them — is uniform across the workgroup. If any of them is not workgroup-level
uniform, it will emit an error naming the operand at fault.

If the compiler cannot decide (the operand's uniformity is *unknown*, typically because it came
from a memory read), that is also an error, and the message will suggest `(declare (uniform ...))`.

These variants are fully differentiable under `--differentiate`; see "Requirements for Differentiable Kernels."

#### variants compared
Let's start with a simple example:
```
(dotimes (x (+ a b)) 
   ...)
```
Each thread will calculate `(+ a b)` independently, and then loop that many times.  If that value `(+ a b)` differs
between threads, the loop will not be uniformly executed and this may result in a LOT of stalling.

`+`
```
(dotimes+ (x (+ a b))
 ...)
```
If `(+ a b)` is calculable at compile time, then this is fine. The compiler will insert that value and the loop will be uniform. The compiler might even elect to unroll the loop for faster performance.


Otherwise the compiler will check that both `a` and `b` are workgroup-level uniform. If they are, then their sum is as well and 
this will both compile just fine, but it'll execute quickly without stalling. But if the compiler
detects that this is not workgroup-level uniform it will emit an error.

#### Operand rules ✅
These apply to every construct in this section. `dotimes` / `dotimes+` are the one exception to
the typing rule: they keep their original, more permissive typing, accepting signed as well as
unsigned integers. The termination rule below binds them too.

**Unsigned only.** `N`, `init`, `stride` and `factor` must be unsigned integer types. A
non-negative integer literal is accepted and treated as a `ulong`, so `(dec-times (i 10) ...)`
is fine. A negative literal, a signed variable or a float is a compile error. The loop index
takes `N`'s type.

**The loop always terminates.** Crisp forbids unbounded loops, and some operand values would
otherwise loop forever — an `init` of 0 can be doubled indefinitely, and a `factor` of 1 never
grows or shrinks `i`.  So:

- As a literal, `init` or `stride` of 0, or a `factor` less than 2, is a compile error.
- Computed at runtime, those same values run the loop ZERO times.
- This includes `dotimes`: `(dotimes (i n 0) ...)` is rejected, and so is a negative literal
  stride on a signed `dotimes` — in both cases the loop variable would never reach the limit.
- The multiplying forms step in a way that cannot overflow: the loop ends rather than letting
  `i * factor` wrap past the top of the type. `(do-times-by-doubling (i 1 N) ...)` with `N` at
  `ULONG_MAX` runs 64 times and stops.



#### dotimes / dotimes+  ⚠️
```
 (dotimes (i N:ulong &optional (stride:ulong 1)) 
    ...)
```
Binds `i` to 0, counts up to N, incrementing by `stride` each time through the loop. `stride` is optional, defaults to 1.

#### dec-times / dec-times+  ✅
```
  (dec-times (i N:ulong &optional (stride:ulong 1))
    ...)
```
Counts down to `0`, subtracting `stride` each time through the loop. `stride` is optional, defaults to 1.

`dec-times` visits exactly the values `dotimes` visits, in reverse — that is its definition. With a
stride of 1 it starts at `N-1`, but in general it starts at the largest multiple of `stride` below
`N`, which is `((N-1) / stride) * stride` in integer arithmetic. Only that choice makes the two
forms mirror images when `stride` does not divide `N`:

Example: `N` is 6, `stride` is 2:  dotimes => 0, 2, 4    dec-times => 4, 2, 0
Example: `N` is 5, `stride` is 2:  dotimes => 0, 2, 4    dec-times => 4, 2, 0

If `N` is 0, the body never runs.


#### do-times-by-doubling / do-times-by-doubling+ ✅
```
  (do-times-by-doubling (i:ulong init:ulong N:ulong) 
   ...)
```
Binds `i` to `init`. Each time through the loop, `i` is doubled until
it reaches (or exceeds) `N`.  The last call will always have `i` bound to a value less than or equal to `N`.

Example: If `init` is 1 and `N` is 64: i => 1, 2, 4, 8, 16, 32, 64
Example: If `init` is 1 and `N` is 100: i => 1, 2, 4, 8, 16, 32, 64

If `init` is greater than `N`, the body never runs. A literal `init` of 0 is a compile error;
computed at runtime, an `init` of 0 runs the loop zero times.

#### do-times-by-multiply / do-times-by-multiply+  ✅
```
  (do-times-by-multiply (i:ulong init:ulong N:ulong factor:ulong)
   ...)
```
Binds `i` to `init`. Each time through the loop, `i` is multiplied by `factor` until i reaches (or exceeds) `N`.  The last call will always have 
`i` bound to a value less than or equal to `N`.

The `factor` value must be greater than 1.

Example:  `init` is 1  `N` is 64 and the `factor` is 4:  i => 1, 4, 16, 64
Example:  `init` is 2  `N` is 100 and the `factor` is 3:  i => 2, 6, 18, 54


#### dec-times-by-half / dec-times-by-half+  ✅
```
  (dec-times-by-half (i:ulong N:ulong)
    ...)
```
Binds `i` to `N`. Each time through the loop, `i` is divided by two until it reaches 1.  The last call will always have `i` bound to `1`, it is never bound to `0` .
Example: If `N` is 64:  i => 64, 32, 16, 8, 4, 2, 1  
Example: If `N` is 100: i => 100, 50, 25, 12, 6, 3, 1

This is very useful for reductions where we have all 64 threads in a warp perform a calculation, then 32, down to the last thread which has 
the full value.  See the example for `sum_vector` with barriers below. 

If your algorithm always needs powers of two, make sure `N` is a power of 2 itself, or consider using `dec-power-step` instead ( below ).

#### dec-times-by-factor / dec-times-by-factor+ ✅
```
  (dec-times-by-factor (i:ulong N:ulong factor:ulong)
     ...)
```
`dec-times-by-factor` is a generalized version of `dec-times-by-half`.  This routine requires a third argument, the `factor`, which is an unsigned integer that must be greater than 1. 
(A `factor` of 2 will result in the same sequence as `dec-times-by-half`). 

`dec-times-by-factor+` requires that BOTH `N` and `factor` are `uniform` values. 

If `N` is 0, the body never runs.

Binds `i` to `N`. Each time through the loop, i is divided by `factor` using integer division. 
The loop continues as long as `i` is greater than or equal to 1. `i` is never bound to 0.

Example #1:  `N` is 64 and the `factor` is 4:  i => 64, 16, 4, 1
Example #2:  `N` is 24 and the `factor` is 5:  i => 24, 4


#### do-power-step / do-power-step+ ✅

```
  (do-power-step (step-var:ulong limit:ulong) 
     ...)
```
`do-power-step` binds `step-var` to the powers of 2 up to `limit` (or the next power of 2 if it is not itself a power of 2).
The highest value `step-var` will have is half the "padded" limit.
For example, in `(do-power-step (i 100) ..)`, the limit of 100 gets rounded up to the next power of 2 which is 128.
This would then have seven steps, binding `i` in turn to 1, 2, 4, 8, 16, 32, and 64
The number of steps taken is `(log2 padded_limit)` ( aka `(log padded_limit 2)`)

Said the other way round, and this is how it is implemented: `step-var` takes the powers of two
that are strictly less than `limit`. No rounding is actually computed.

Example: `limit` is 100 (padded 128): i => 1, 2, 4, 8, 16, 32, 64
Example: `limit` is 64 — already a power of two, so padded stays 64: i => 1, 2, 4, 8, 16, 32.
Note that 64 itself is NOT visited; the highest value is half the padded limit.
Example: `limit` is 2: i => 1
Example: `limit` is 1 or 0: the body never runs.


#### dec-power-step / dec-power-step+ ✅

```
  (dec-power-step (step-var:ulong limit:ulong) 
     ...)
```
The reverse of `do-power-step`, `dec-power-step` starts with `step-var` bound to half the padded limit and decremented until it is 1.
E.G. In `(dec-power-step (i 230) ...)` the limit of 230 would be raised to the next power of two, which is 256.
So `i` would be bound to 128, 64, 32, 16, 8, 4, 2, and 1. 

Equivalently, and this is how it is implemented: `step-var` starts at the largest power of two
strictly below `limit`, then halves down to 1. The starting value is found with a
count-leading-zeros instruction, so it costs one instruction rather than a loop.

Example: `limit` is 230 (padded 256): i => 128, 64, 32, 16, 8, 4, 2, 1
Example: `limit` is 256 — already a power of two, so it starts at 128, not 256
Example: `limit` is 257 (padded 512): i => 256, 128, ... 2, 1
Example: `limit` is 1 or 0: the body never runs.

This is the form to reach for in a tree reduction where the strides must be powers of two,
even when the element count is not — `dec-times-by-half` would give you 100, 50, 25 ... instead.


