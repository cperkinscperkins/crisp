# Floating Point and Integer Operations ✅


These operations are available for both floating point and integer values.

- `abs`  
- `min`   => `(min a b)`
- `max`
- `clamp` => `(clamp x min-val max-val)`
- `+`
- `-`
- `*`
- `*!`  widening multiplication. see [Quantized Integers](#quantized-integers)
- `/`    see [Integer Division](#integer-division) below.

### binop vs accum-op

Most of the operations above binary operations, aka `binop-type`, aka their
type signature is generally `#'(T T => T)`.

Crisp also has accumulator operations, aka `accum-op`, where the type signature
is `#'(T T => (accum T))`. These are "widening" operations. For the basic types (`float`, `int` etc)  the `(accum T)` is just `T`.  So no special handling is required.

One example of an `accum-op` is `*!` which is multiplication but it "widens" the base type to 
an accumulator type.  We'll see more of this below when discuss the hardware accelerated types 
like Quantized Integers and MicroFloat Blocks.

- `*!`  => `#'(T T => (accum T))`  widening multiplication.

