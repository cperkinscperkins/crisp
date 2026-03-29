
Crisp has structs and records, it also has Storage Handles like vector, matrix, tensor.  It also has "device vectors" which are those float2, double4 things.    But it doesn't have a compile-time-known general array, and I'm thinking to add it to the language.

(array T N) => this would be the type declaration. Both T and N must be known at compile time, these are always std140 aligned arrays.  

Array has (~ someArr someIdx) type of access . Including (set! (~ someArr someIdx) someVal)



arrays can be passed directly on the kernel boundary, BUT, like passing structs on the kernel boundary, if that is done they use constant memory and are immutable.  We already have a code to see if some variable originates at the kernel boundary so we can enforce that.

arrays can appear inside a def-struct.  That makes sense.


AND (here's the cool part, maybe)  

(def-record something
   (arr (array int 5)))

arrays can also appear in def-record. BUT, if they do, they are virtual arrays. They are just a collection of arguments.  When "something" is passed to a function, we use SROA to explode and pass.  

Is that an ok design? I worry slightly about array being interpreted differently in an def-record, but I think it works well. 


Gemini Replies
--------------

That is a very cool design, and it perfectly completes the symmetry of your `def-struct` / `def-record` duality. 

Treating `(array T N)` as an SROA-exploded virtual array inside a `def-record` is a brilliant way to give users array-like syntax for mathematical conveniences (like a small covariance matrix or color channels) without paying the penalty of memory allocation. 

However, there is a massive LLVM-IR trap hidden inside the `def-record` array implementation that you need to account for: **Dynamic Indexing.**

Here is how the design holds up and the specific architectural hurdle you will hit.

### 1. Arrays at the Kernel Boundary & in `def-struct`
This part of your design is bulletproof. 
Passing `(array T N)` directly at the boundary mapping to immutable constant memory is exactly how it should work, mirroring standard GPU ABI behavior for by-value array passing. Inside a `def-struct`, it maps trivially to a contiguous block of `std140` memory that the compiler can natively access via LLVM's `getelementptr` (GEP) instruction.

### 2. The `def-record` Trap: Registers Don't Have Addresses
When you SROA-explode `(array int 5)` inside a `def-record`, the compiler generates 5 independent scalar SSA variables (e.g., `%arr_0`, `%arr_1` ... `%arr_4`). They live in hardware registers, not memory.

If the user writes `(~ someArr 2)`, the compiler can easily resolve this at compile time. It just drops in the SSA value for `%arr_2`.

But what happens if the user writes `(~ someArr i)`, where `i` is a variable evaluated at runtime?
Because `%arr_0` through `%arr_4` are independent registers, they do not have a base memory address. You **cannot** emit a `getelementptr` instruction to dynamically index into a collection of SSA values. 

### The Compiler Solutions for Crisp
To make arrays inside `def-record` work, you have to decide how Crisp will handle a dynamic index `(~ arr i)` on an SROA-exploded array. You essentially have three options:

**Option A: The Strict Path (Compile-Time Indices Only)**
* **How it works:** You enforce that any array inside a `def-record` can only be indexed using a compile-time constant. 
* **Pros:** Keeps the compiler simple and guarantees zero-cost register performance.
* **Cons:** Users might find it frustrating if they expect a `def-record` array to behave exactly like a `def-struct` array in loops.

**Option B: The LLVM Switch Hack (Best for Small N)**
* **How it works:** When the compiler detects dynamic indexing on a `def-record` array, it intercepts it and generates an LLVM `switch` instruction over `i`. 
  * `case 0: return %arr_0`
  * `case 1: return %arr_1`
* **Pros:** Preserves register-level speed and allows dynamic indexing.
* **Cons:** The LLVM-IR balloons quickly. It is perfectly fine for `(array float 4)`, but it becomes an absolute nightmare if a user tries `(array float 256)`. 

**Option C: The Local Stack Spill (The "Fake SROA")**
* **How it works:** When dynamic indexing is detected, the compiler injects an `alloca` instruction in the kernel entry block to create a private thread-local memory array. It writes all the SROA registers to that memory, uses standard `getelementptr` to do the dynamic read/write, and then updates the SSA registers if mutated.
* **Pros:** Fully supports arbitrary dynamic indexing.
* **Cons:** Completely destroys the performance benefits of `def-record` because you force the GPU to bounce data through Local/Private memory anyway.

### The Architectural Recommendation
If you add `(array T N)` to `def-record`, I highly recommend implementing **Option A** (compile-time indices only) first, or **Option B** (the switch hack) with a hard compiler cap on `N` (e.g., throwing an error if `N > 16` inside a record). 

This preserves the semantic contract of `def-record`—that it represents blistering-fast, register-backed scalar values—while still giving users the syntactic sugar of array notation for things like vector math or small unrolled loops.




THE DESIGN DOC
==============


Array Type
----------

`(array T N)`

In Crisp an `array` type is a 1 dimensional vector type of consecutive elements where
both the element type `T` and the length `N` of the array are known at compile time.

This is mostly a utility type used by some of the Crisp built-ins. Most users will be
better served by the `vector` Storage Handle. 

Like for `vector` the simple `~` accessor is available for dereferencing.

```
(let ((my-arr (array long 10)))
  (set! (~ my-arr 0) 0)
  (set! (~ my-arr 1) 1)
  (return (length~ my-arr)))
```

Arrays can be direct kernel parameters. But if they are appear directly on the kernel boundary,
they are read only, immutable.

Arrays always use `:std140` alignment. `:compact` is not available. 

Arrays can be elements of a struct, and can ALSO be in a record, but if used in a
`def-record` they are automatically virtualized like the other `def-record` members 
( which means the `:std140` alignment will not apply).

### `~`
Like vectors, arrays support `~` for refer-by-index semantics. This can be used for both
get and set.

### `length~`
The `length~` compile time property is supported.

### Note: soa-vector Disambiguation

Crisp also has the `soa-vector` data type, where "soa" stands for "Struct of Arrays." The fixed-size `(array T N)` type is architecturally distinct from `soa-vector`. An `array` is a stack-allocated or register-backed primitive, whereas `soa-vector` is a pointer-backed Storage Handle.

