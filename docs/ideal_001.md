# CRISP - Lisp for developing GPU Kernels

> With C, you use C to solve your problem. With Lisp, you make the language fit your problem, then you solve it.
>
> — *Popular Lisp Adage*


### Overview

Crisp is a Lisp dialect for developing GPU Kernels.
The Crisp compiler takes .crisp files and can output SPIR-V, PTX, or a binary for a specific GPU. 
The compiler can ALSO output C++ or Python code snippets that can "hoist" that same kernel. 
The snippets can be targeted to: OpenCL, LevelZero, or CUDA, as well as whether to use
Unified Memory/USM/SVM.

Someday soon.


### Focus

The focus is on performance, compiliation speed, safety and correctness.
GPU idioms like tensors, shuffles, memory addressing, grid strides, structs-of-arrays, quantized integers, and more are directly exposed by the Crisp language.

### Major Features of the Crisp language and tools

- Distinct Execution Contexts:  A formal context system (thread, grid, dispatch) separates sequential per-thread code from parallel grid-level operations.  This makes a whole class of subtle but catastrophic parallel programming bugs (like nesting grid-level operations) impossible to write by turning them into clear, compile-time errors. (✅ implemented)

- Explicit Output Parameters:  The `&out` modifier explicitly marks output-only parameters in function signatures.  This creates a clear, compiler-enforced contract that prevents race conditions and bugs caused by reading from uninitialized or partially-written output buffers. (✅ implemented)

- Guaranteed Termination:  Crisp is intentionally not Turing-complete (no unbounded recursion or loops).  This provides a mathematical guarantee that kernels will always finish, preventing GPU hangs. It also unlocks a suite of powerful static analysis tools that are impossible in general-purpose languages, and is key to supporting auto differentiable kernels (✅ implemented)

- First-Class GPU Primitives:  Common but complex GPU patterns like grid-strides, warp shuffles, and parallel reductions are provided as high-level, built-in language constructs.  This allows developers to write powerful, performant code that is both readable and correct, without having to reinvent these difficult algorithms from scratch.

- Automated Scratch Memory:  High-level primitives (like reductions and sorts) can automatically manage their own temporary local and global memory via a "side-channel" mechanism.  This eliminates tedious and error-prone manual buffer allocation and management. (✅ implemented)

- Flexible Data Layouts:  Crisp provides distinct types and specialized accessors for both "Array of Structs" (`vector`) and "Struct of Arrays" (`soa-vector`).  This gives developers the tools to choose the most performant memory layout for their algorithm without sacrificing type safety or readability.

- Optimized Memory Access: Crisp provides explicit control over data layouts (`:aos`, `:soa`, `:compact`, `:strided`) and GPU-native iteration patterns (`loop-vector-stride`, `load-tile`). These features are designed to enable and encourage coalesced memory access, allowing kernels to achieve maximum memory bandwidth, a key factor for high performance on GPUs. The opt-in `check-coalesce` static analysis further helps developers verify these critical access patterns.

- Compile-Time Verification:  Special variants of control-flow forms (`if+`, `dotimes+`) and declarations (`uniform`, `constexpr`) allow programmers to assert their performance expectations.  The compiler verifies these assertions, catching unintended performance bugs (like warp divergence or non-constant loop bounds) at compile time.

- Strict Memory Layout Standard:  All Crisp structs adhere to a strict "scalar" memory layout standard.  This guarantees a predictable and performant memory layout, ensuring seamless and correct data interoperability between the host (C++/Python) and the device.

- Pragmatic Error Handling:  A simple maybe type is integrated into the language.  This provides a lightweight, compiler-assisted mechanism for handling potential failures in a way that minimizes control-flow divergence, a major performance killer on GPUs.

- Powerful Metaprogramming:  A Lisp-based syntax with defmacro and a rich templating system (`with-template-type`).  Developers can extend the language with new abstractions, control structures, and code generators, creating domain-specific solutions that are clean and expressive. (✅ implemented)

- Static Typing with Powerful Generics: Crisp is statically typed with a robust templating system and compile-time type constraints. This provides the compile-time safety and performance benefits typical of C++, preventing runtime type errors, while offering a level of generic programming and code generation via metaprogramming that surpasses traditional C++ templates and is absent in dynamic languages like Python or Common Lisp. (✅ implemented)

- Unified Quantized Math: Crisp provides first-class support for the entire spectrum of modern, high-performance numeric types. This includes both quantized integers (like `qint8`) and low-precision "microfloats" (like `fp8-e4m3`). The type system ensures mathematical safety by enforcing nominal "branded" types preventing you from mixing incompatible formats. It also enforces overflow-safe math, providing a direct, unified, and safe path to the massive performance gains of specialized AI hardware (like Tensor Cores) for both integer and floating-point acceleration. 

- Automated Hoisting Code:  The Crisp compiler can optionally generate a complete, runnable `main()` function in C++ or Python.  This automates the tedious and error-prone task of writing host-side launch code, providing an instant, working "blueprint" that demonstrates how to allocate memory, set arguments, and correctly launch a kernel. (⚠️ partially implemented)

- Opt-In Static Analysis:  The compiler includes a suite of advanced, opt-in checks.  This allows the compiler to act as an expert performance coach, automatically detecting subtle but critical issues like memory-coalescing failures, shared memory bank conflicts, and potential barrier deadlocks.

- In-Memory Compilation API:  Crisp is designed as a compiler library with a C/Python API.  This enables fast, in-memory JIT compilation, allowing applications to dynamically generate and run new kernels on the fly without disk I/O.

- Auto-Differentiation for GPU Kernels: The `--differentiate` compiler flag automatically generates high-performance reverse-mode gradient kernels from your forward code.  Write your math once. Crisp handles the calculus, generating the "backward pass" for you. Whether you're training neural networks, optimizing physical simulations, or performing sensitivity analysis, you can focus on the model and let the compiler worry about the derivatives. No manual backprop, no "calculus bugs," and no need to wrap your kernels in a heavy external framework. (✅ implemented)



### Differences From Lisp

While Crisp is an s-expression based language and shares with Common Lisp the very powerful `defmacro` 
construct as well as many other fundamentals ( `if`, `when` `cond`, `let` etc), there are 
marked differences between them.  

#### no list data type.  

Crisp does not support the list data type. Nor cons cells. Nor linked lists. Internally, the compiler might be using
them to represent code, but there are no lists available to the Crisp developer.

#### no ratios or bignums

Most Lisp and Scheme variants represent numbers in a numeric tower that include
ratios fully storing both numerator and denominator and more. Crisp has no such affordance.
In only exposes the numeric machine types that are availble on GPU hardware. 

#### no dynamic memory or garbage collection

Scheme and Lisp implementations have implicit memory allocation and collection. Crisp does not.
It does have "Side Channels" which can be used for intermediate scratch memory and debug logging. To be discussed later.

#### static typing, not dynamic

As already mentioned, Crisp is statically typed.  There is no runtime typing of any sort.

#### 0 is false

Crisp follows Python and C++ and treats 0 as false.  In Common Lisp, which supports
dynamic typing, there are strong reasons for having 0 be true, but given that Crisp
doesn't support dynamic typing and its intended audience is likely more familiar
with CUDA, C++, Python and OpenCL C, Crisp follows their practice and 0 is false.

#### no recursion

Crisp does not support recursive functions, nor mutual recursion. 

#### no condition/restart system

Common Lisp has an EXCEPTIONALLY powerful system for handling errors with restarts and more. 
Crisp's has a modest (yet performant) `maybe` type to help catch and log errors with a
minimum of branch divergence.

#### no eval

To many a 'REPL' (Read Eval Print Loop) is the most basic requirement to be considered
a Lisp. As Crisp targets GPU kernel (only) this is not possible. 

#### no CLOS

The Common Lisp Object System is likely the most powerful object system ever designed.
Crisp has nothing comparable, but instead offers modest structs, derived types, and function overloading. 
These are simple and should be flexible enough to get things done.

#### misc

`let` in Crisp is like `let*` in Common Lisp. Asterisk not needed.

`set!` in Crisp is like `setf` in Common Lisp. However, it does NOT return a value. 
You cannot shortcut set and return a value in the same expression.


### Commonalities with C++

#### Monomorphization
Monomorphization is just a big word for "templates". Look it up.

#### Static Typing

The Crisp basic types are the same as in C++. The type promotion rules differ though.

#### Zero Cost Abstractions

Did you know that C++ `std::sort` is faster than quicksort because it inlines the comparator?
Crisp does that sort of thing too, except there is no `std::sort`.

#### SFINAE

Just kidding. Crisp doesn't do SFINAE. It has Common Lisp `defmacro` which is better++.




## Thread Level / Grid Level / Dispatch ✅

> A GPU is not a CPU
>
> — ( this author )

In most Lisp languages, `progn` is a term used to desribe a set of code that is grouped together and bound 
by parentheses. In C++ we might say "the body of a function" or the "body of a closure". In C++ a `progn` is
typically surrounded by curly braces `{ ... }`  .

In Crisp, the `progn` that appear in function bodies implicitly have one of three "contexts" that
inform the compiler on the type and scope of actions that might be taking place in that `progn`.
These three contexts are

- thread level
- grid level
- dispatch

A thread level context is one where the action taking place within it is independent of what
is occurring in other threads. Typically this means there is no expection that it work with 
a particular piece of global memory or perform atomic operations on global memory. Thread level
contexts are the default in functions defined by `def-function`. Importantly, inside a thread
level `progn` it is illegal to make grid level or dispatch level operations/calls.   

In contrast in a grid level context there is an expectation that thread with such-and-such id is
accessing global memory at such-and-such index, or performing atomic operations on global memory.
Grid level contexts most often come from macros like `loop-vector-stride`. Inside a grid level
`progn` making thread level operations is perfectly fine. But calling OTHER grid level operations
is forbidden. In other words, grid level operations cannot nest inside one another.

A dispatch context is a context where we can call either thread level or grid level 
operations freely. But note, that if a grid level `progn` is opened that inside its body the
restriction on calling other grid level operations still applies. Dispatch contexts are 
associated with `def-kernel` and `def-grid-function`.  And note that while grid level operations
cannot be nested inside one another, a dispatch context CAN call them sequentially, one after another.

This author likes the analogy of a garment factory, where there are long tables with sewing machines
running along them. As a worker finishes their task (sewing buttons perhaps), they pass the garment on to the next
machine on the table (which sews seams).  In this analogy, a single GPU thread is like the long table.
The call stack of functions calling one another on that thread is the individual machines sewing then passing the work to the next.
A thread level `progn` can contain the actions that can be performed by a person sitting at one machine.
The long tables are grouped together into small workgroups. If there is some coordination that must 
occur within a workgroup, (via local memory and local barriers perhaps), that's fine. A worker can do that 
("Hey, look at what Jim is doing").
But if you need to coordinate multiple workgroups, or ALL the tables in the factory, well that's a
a grid level operation. That requires management. A single worker sitting at a sewing machine cannot
 "call" a grid level operation. 


### Why This is Different from C++/CUDA

In C++/CUDA, there is no formal distinction between a "dress pattern" and an "assembly line blueprint". A programmer can accidentally write code that has a single thread try to launch a new, grid-wide operation. The C++ compiler won't prevent this. This code compiles but results in a silent, catastrophic bug: either the logic is fundamentally incorrect, or the performance is thousands of times slower than expected. The developer is left to debug a complex runtime issue with no help from the compiler.

Crisp's context system provides guardrails. By separating `def-function` and `def-grid-function`, the compiler understands the intent of your code. If you try to call a grid-level function from a thread-level context, you get an immediate, clear compile-time error, not a mysterious runtime bug.

In short, this system provides:

 - Safety: It makes a whole class of parallel programming errors impossible to write.
 - Clarity: It makes the code self-documenting. A `def-grid-function` is unambiguously a parallel operation.
 - Readability: It separates the high-level orchestration of a kernel from the low-level, per-thread implementation details, making complex algorithms easier to reason about.


## Terminology: Storage Handles ✅

You'll see the term _"Storage Handle"_ a lot in this document.
A Storage Handle is any Crisp type that refers to resident memory (Global, Local, or Constant). 
This includes raw `storage`, structured views like `vector` and `tensor`, and `cell` references. 
Unlike register variables, Storage Handles refer to addressable memory locations.

We'll discuss the actual types later in the document.

 


## Top Level Execution Constructs ✅

In Crisp, nearly everything that can be put at the "top level" of a code file begins with "`def-`".  
There are a handful of exceptions (*), but that is the general rule. And every other Crisp expression
is then inside one of these definitions and cannot appear, unchaperoned, at the top level.
Of these "`def-`" expressions, there are three primary ones that serve as execution constructs:
 `def-kernel`, `def-function` and `def-grid-function`.

 (* Exceptions: `declaim`, `with-template-type`, `set-derived` )

### `def-kernel` ✅

```
;; -- do_something --
(def-kernel do_something (i val VEC)
   ;; <type-declaration-here>
   (set! (~ VEC i) val)) ;; store val into index i of VEC
```
We'll discuss type declarations and type signatures later. For now, just understand that
`def-kernel` is how you define a kernel function that can be enqueued and invoked by some
host application.  The host application can only invoke kernels that you define, no other
functions.
Kernel functions
- accept arguments like a regular function (with a constrained set of available types)
- do not return values
- are not callable by other Crisp functions (see "continuation kernels" for exceptions)
- the body `progn` of the kernel function is a dispatch context
- can call both "thread level" functions and "grid level" functions.
- kernel function names (like "do_something" above) are restricted to C-style naming rules (ie "do_something" with an underscore is valid, but "do-something" with a dash is not).
- kernel function names are case sensitive - unlike nearly everything else in Crisp which is case insensitive.

### `def-function` ✅
```
;; -- do-add --
(def-function do-add (x y)
   ;; <type-declaration-here>
   (+ x y)) ; return the sum of x and y
```
`def-function` defines a function, just like you would do in nearly every other programming
language. Functions take arguments and return values, they have mandatory type declarations (see below).
The functions that are defined are "thread level" functions, meaning they are expected to operate in the context
of a single thread and not orchestrating the operation of all threads generally.

Thread level functions
- accept arguments, including higher order function args
- CAN return values
- the body of these functions are a "thread level context"
- can call other thread level functions
- but CANNOT call "grid level" functions or use grid level macros
- can use Lisp-style naming rules. (dashes ok in function names, case insensitive)

### `def-grid-function` ✅

```
;; -- vector_add --
(def-grid-function vector-add (A B &out C)
  ;; <type-declaration-here>
  (loop-vector-stride A (i)
     (set! (~ C i) (do-add (~ A i) (~ B i))))) 
```

`def-grid-function` also defines a function, much like `def-function` above. 
Grid functions have a "dispatch context" at their top level. They
are called "grid functions" because the CAN invoke grid level operations 
(as opposed to thread level functions which cannot).

Grid functions
- accept arguments, including higher order function args
- CANNOT return values
- have a "dispatch context" in the top level
- can call thread level functinos
- can call grid level functions
- can use Lisp-style naming rules (dashes ok).


## Return Storage Handle Pattern `&out` ✅

Because kernel and grid functions cannot return values, the accepted
pattern is to pass memory to them where you want results to be recorded.
This is very common in GPU-land.

But there are caveats that if not well managed can lead to bugs.
It may be tempting to use a grid operation to calculate something, and 
then, afterward, "peek" at the solution.  

Like so
```
;; --- INCORRECT ---
;; -- calc --
(def-kernel calc (A B)
 ;; <type-declaration-here>
 
 ;; use grid level operation to square every element of A,
 ;; storing it in B
  (loop-vector-stride A (i)
    (set! (~ i B) (square (~ i A))))
  
 ;; check for lucky number in (~ B 7)  ie B[7]
 ;; this "peek" is a race condition. The thread executing here
 ;; has no guarantee that thread 7 has completed yet.
 (let ((lucky-num (~ B 7)))
   ;; do-something
  ...))
```

But this won't work. B[7] WILL hold the right value, someday. 
But at the time the thread the kernel is runnign on has finished its part 
of the `loop-vector-stride` there is no guarantee that the B[7] is done.
The odds are high that reading B[7] will result in garbage. This is a
classic race condition.

This is a very easy mistake to make, in all languages. For this reason, Crisp
has the `&out` parameter list specifier.  
Any variables after `&out` must be a `:global` Storage Handle ( ie an acceptable proxy, like `vector` `soa-vector`, `cell`, `tensor` ).

Importantly, within the functions scope the compiler enforces a write-only contract. 
Any attempt to read from an `&out` parameter will result in a compile-time error. 
Thus protecting you from accidentally making the race condition mistake.

```
;; --- CORRECT ---
;; -- calc --
(def-kernel calc (A &out B)
 ;; <type-declaration-here>
 
 ;; use grid level operation to square every element of A,
 ;; storing it in B
  (loop-vector-stride A (i)
    (set! (~ i B) (square (~ i A)))))
```

If you are implementing the "return-data-via-storage-handle-parameter" pattern,
then use `&out` and enlist the compilers help in enforcing usage boundaries.


The `&out` parameter list keyword marks the beginning of the output parameters. 
All subsequent parameters in the list are treated as output parameters and are subject 
to the write-only contract within the function's scope. Following  `&out` there can be `&optional` and then `&key` paramters, these are NOT considered to be `&out` parameters.
Note that these advanced signature constructs are order sensitive. The order is `&out => &optional => &key` and it is a compile error to order them otherwise.

`&out` parameters can only be Storage Handles (`cell`, `vector`, `matrix` or `tensor`). 
Any other type for an `&out` parameter is a compilation error.


### `&out` and differentiation ✅

Crisp's auto-differentiation feature (`--differentiate` flag), can only differentiate kernels
that use clear "input" and "output" parameters.  Use of `&out` is required, and the non-out paramters
must be read-only.

### `&out` and performance ✅
For any kernel, when `&out` is used then the "other" parameters not designated as output are
considiered as read-only input candidates. You can read and write to those parameters, if you wish, BUT if you forego write operations to them and honor a read-only contract, then the optimizer will be better able to work its magic and improve your kernel performance. In other words, for maximum performance use `&out` to designate your kernel output parameters and only write to those, never to any others.


## Argument Passing and Side Channels ✅

As a general rule, GPU Kernels cannot allocate dynamic memory. This means that the host has to allocate 
and prepare ALL the memory a GPU kernel might need. The host needs to prepare the memory that will receive the result
of the operation. The host will also need to prepare memory for any scratch/intermediate operations the kernel might need.

The normal practice is that the kernel function has its parameter list for incoming arguments and everything the kernel
needs is present in its calling interface, and it passes those arguments down to subfunctions, as appropriate. 


There are two specialized categories of Crisp constructs that can help with this: `make-scratch-XXXX` and `make-implicit-XXXX` (where `XXXX` names a type of Storage Handle )  These operations, discussed in detail below, allow you to "pretend" to allocate memory
in your  kernel.   Each invocation of `make-implicit-XXXX` results in an extra allocation of memory appearing in the example
hoisting code, with a matching pointer passed implicitly as a kernel argument. Uses of `make-scratch-XXXX` are collected
by the compiler and are combined into a single scratch memory pool, which is similarly added as an implicit kernel argument.  These are conveniences.  The compiler calculates the size requirements for these and outputs them to the hoisting example code, but it's ultimately up to your final hoisting code to ensure the memory is sufficient.

Another side channel that adds implicit kernel arguments is the debugging communication channel, which can be enabled during compilation.

Lastly, if the data is constant and known at compile time then `def-constant-vector` and `use` would be better choices. 
These are also discussed below.

Side channels introduce side effects into functions that would otherwise be referentially transparent. For this reason, it's often better to avoid them. Many users choose to explicitly declare all their required memory in the kernel parameter list and pass it to sub-functions rather than introducing this impurity. Crisp supports both formulations. 


## Crisp Types ✅

Because compile time types are a significant departure from most familiar Lisps, the next several sections
are focused on type declaration and support in the Crisp language.  


### Base Numeric Types ✅




``` markdown

| Type | Bits | Suffix | Example |
| :----------: | :----------: | :------------: | :-------------: |
| char         | 8            | c              | -1c             |
| uchar        | 8            | uc             | 255uc           |
| short        | 16           | s              | 100s            |
| ushort       | 16           | us             | 65535us         |
| uint         | 32           | u / U          | 10U             |
| long         | 64           | l / L          | 1000L           |
| ulong        | 64           | ul / UL        | 1000UL          |
| half         | 16           | h              | 1.5h            |
| bfloat16     | 16           | bf             | 1.5bf           |
| float        | 32           | f / F          | 1.5f            |
| double       | 64 bit       | d / D          | 2.0d            |   

```



### Vector Numeric Types ✅

| Base Type | 2 | 3 | 4 |
|-----------|---|---|---|
| char   | char2   | char3   | char4   |
| uchar  | uchar2  | uchar3  | uchar4  |
| short  | short2  | short3  | short4  |
| ushort | ushort2 | ushort3 | ushort4 |
| int    | int2    | int3    | int4    | 
| uint   | uint2   | uint3   | uint4   |
| long   | long2   | long3   | long4   | 
| ulong  | ulong2  | ulong3  | ulong4  |
| half   | half2   | half3   | half4   |
| float  | float2  | float3  | float4  |
| double | double2 | double3 | double4 |


These vector types can be directly instantiated using `##( ...)`.  If using this syntax, it is 
wisest to explicitly declare the type, rather than rely on type inference on the part of the compiler.

Example:
```
(let ((my-svec ##(5 6 7))
      (my-dvec ##(3.0 4.0 5.1 6.0)))
  (declare (type my-svec short3) (type my-dvec double4)) 
  ...)
```

A simple way to make the type clear is use a type literal suffix on the first element. 
```
(let ((my-ushort3-v ##(5us 6 7)) ;; <-- first term "5us" declares the type for all
      (my-half4-v ##(3.0h 4.0 5.1 6.0)))
   ;; declare not necessary.  
  ...)
```

#### Dereferencing 📝
The subelements can be dereferences with the `x~`, `y~`, `z~` and `w~` functions, 
and those can be used for `set!` as well.

```
(let ((my-svec ##(5us 6 7 8))
      (six    (y~ my-svec)))
    (set! (w~ my-svec) six)) ;; last element is now '6' instead of '8'
```

#### Swizzles 📝
Furthermore, Crisp supports "swizzles" (like `xyyy~`)

```
(let ((my-svec ##(5 6 7 9))
      (all-six          (yyyy~ my-svec))
      (tail-part      #(0 0)))
  (declare (type my-svec short4) (type tail-part short2))
  (set! (xy~ tail-part) (zw~ my-svec))
  ; OR
  (set! tail-part (zw~ my-svec))
   ...  )
```

### Numeric Type Promotion, Casting, Conversion ✅

It should surprise no one that Python, C++, and Common Lisp all have different
rules for type promotion. And, without naming names, no one will be surprised to 
learn that at least one of those systems is a constant source of bugs for its users.

Crisp takes a strict "hardware first" approach to automatic type promotion and 
requires that any auto promotion is both "safe" and "correct".

The rule is that implicit promotion is performed within the same category when
going from a smaller size to a larger size, leveraging fast hardware instructions (zero extension, sign extension, or floating-point conversion).
The three "categories" are signed integers, unsigned integers and floating point numbers.

Therefore these are the promotions Crisp performs automatically:

| | |
|-------------------|---------------------------------------------|
| Unsigned Integers | `uchar` -> `ushort` -> `uint` -> `ulong`    |
| Signed Integers   | `char` -> `short` -> `int` -> `long`        |
| Floating Point    | `half` or `bfloat16` -> `float` -> `double` |
| Integer to Float  | int → float, int → double, long → double, (etc for unsigned). |

This applies element-wise to hardware vector types as well:
`ucharN` -> `ushortN` -> `uintN` -> `ulongN`    (etc for signed integer and floating point).

All other conversions require an explicit cast.

```
;; COMPILE ERROR: No automatic promotion from float to int. (see Value Conversion section for CORRECT)
(let ((f (some-float-returning-op)))
  (some-int-op f))

;; COMPILE ERROR: No automatic promotion between signed and unsigned
(let ((u (some-unsigned-int-returning-op)))
  (some-signed-int-op u))

;; CORRECT
(let ((u (some-unsigned-int-returning-op)))
  (some-signed-int-op (to-int u)))
```

#### Convert: `to-` , Cast `as-`

If you need to move between numeric types, Crisp gives you two affordances: `to-XXXX` and `as-XXXX` where `XXXX` is 
the target type name (eg. `to-float`  `as-int`)

##### Value Conversion ✅
`to-` converts the type "correctly" (or as correct as can be done) and will move bits to do so.  It is the equivalent
to a "static cast" in C++.  Converting across categories, or to smaller sizes, may lead to loss of information and/or 
accuracy.

IMPORTANT:  for floating point to integer conversions, `to-int` and friends are NOT DEFINED. 
Instead, you must explicitly choose which conversion you want:  `truncate`, `floor`, `ceil`
or `round`.  See the section on integer division for a comparison.

<!-- NOTE: maybe move that section on truncate/floor/ etc to yet another place? -->

```
;; CORRECT - we must use ceil, floor, truncate or round to convert floating point to integer
(let ((f (some-float-returning-op)))
  (some-int-op (ceil f)))
```

##### Bit Reinterpretation ✅
`as-` just tells the compiler to pass the value through with no action taken. No bits moved. It is inherently unsafe.
It is the equivalent of "reinterpret cast" in C++.


```
;; this compiles, but is most likely wrong if some-int-op needs to perform actual numeric calculations
(let ((f (some-float-returning-op)))
  (some-int-op (as-int f))) ;; <-- DANGER
```

##### `(as T someVal)`

Rather than `as-XXXX`, you can also use the `as` type cast. It takes a value and a desired type arg.
Example: `(as uint someInt)` 

Note there is no equivalent shorthand for _conversion_ (ie no `to`). Use  `to-XXXX` .


### Quantized Integers and Complex Numbers 📝

Crisp has in-language support for quantized integers a popular optimization among
the GPU-dev-literati, as well as complex numbers. See [Quantized Integers](#quantized-integers)
and [Complex Numbers](#complex-numbers) below.



### Other Basic Types ⚠️

> NOTE: this section needs work

#### bool    
- `bool` is a type
- its values are `true` and `false`
- any zero number value puns as `false`
- any non-zero number value puns as `true`
- `nil` is a compile-time expression (not runtime). It also puns as `false`.
- an instance of any other Crisp type (struct, vector, etc) puns as `true`.

Currently under debate whether `bool` is an instantiable value.


#### symbols ✅

Common Lisp has a symbol type and it is repelete with them. Crisp does not support these
in the runtime. Note that the only known implementation of Crips uses Common Lisp 
for macro evaluation. And, so, in that context, symbols are allowed.

You'll also see that types are passed to macros, they are usually quoted like symbols (`'int`).

But as a general rule, symbols are not support in Crisp and the compiler will error if you
try to use them in runtime code. See `keyword symbols` below for the exception to this rule.

#### keyword symbols ✅

keyword symbols (`:some-key` ) ARE supported, but are only usable as values if
they appear in an enumartion. 
(Note, they don't need to be in an enumeration if they are simply function parameter keys)

                            
#### higher order functions ✅
`#'someFunction` are supported. But must be compile-time determinable.  See [Higher Order Functions](#higher-order-function-operations)



### Declaring Types - Functions ✅

Types MUST be declared for parameters to functions and the function return type.  

Grid functions and kernel functions ( `def-grid-function`, `def-kernel` ) also need their paramters to be typed.
They both have no return value and can either specify that, or elide it from the type signature.

There are various mechanisms for declaring parameter and return types.  Easiest to illustrate them with code.

```
;; A -- use a declare block. (return-type <type>) for the containing function, (type <varName> <type>) for each variable.
(def-function addInts (a b)
    (declare (return-type int) (type a int) (type b int))
  (+ a b))

;; B -- type can declare multiple names to the same type.
(def-function addInts (a b)
    (declare (return-type int) (type a b int))
  (+ a b))

;; C -- declare block with a single type signature for entire function.
;       if a type signature appears in declare, it's assumed to be for the function. 
(def-function addLongs (a b)
    (declare #'(long long => long))
  (+ a b))

;; E -- multiple values return
(def-function divInts (a b)
; divInts returns both the quotient AND the remainder.
    (declare #'(int int => int int))
    ...)

(def-function divIntsAgain (a b)
    (declare (type a b int) (return-type int int))
    ...)

;; F -- type-signature can refer to other functions
(def-function addPreciously (a b)
    (declare #'(long long => (return-type-of #'addInts)))
    ...)

(def-function addIntsSometimes (a b)
   (declare (type-signature-of #'addInts)) 
   ...)



;; G -- NIL return type (ie 'void' in C)   
(def-function doSomething ()
  (declare (return-type NIL))
  ;OR
  (declare #'(=> NIL))
  ...)

;; H -- keyword & optional arguments
(def-function survive (&key birds fish zombies)
  (declare (return-type NIL) (type birds fish zombies int))
  ;OR 
  (declare #'(&key :birds int :fish int :zombies int => NIL))

  (if (is-set? birds)    ;; <-- use is-set? to check if a variable is set or not.
  ...)

(def-function addSome (x &optional y)
  (declare (return-type NIL) (type x y int))
  ;OR
  (declare #'(int &optional int => NIL))

  (when (is-set? y)    ;; <-- is-set? to check 
  ...)

; default values do not appear in type signature
(def-function addSome (x &optional (y 30))
  (declare #'(int &optional int => NIL))
  ...)

;; I -- skip return type in kernels and grid functions
(def-grid-function bury (meters)
  (declare (type meters float))
   ...)

(def-grid-function sharpen (edge)
  (declare #'(float => nil))   ; nil is return type
  ; OR
  (declare #'(float))          ; no need for return type

;; J - &out -- write-only-vectors
(def-grid-function vector-add (A B &out C)
   (declare #( v-type v-type &out v-type))
    ...)
```

#### Lazy Monomorphic Generation ✅

Use of `&optional` and `&key` leads to function generation for
each option.  In other words, an optional declaration like so:
 `(def-function foo (&optional a) ...)` 
 results in TWO possible versions of `foo` being generated. One with zero
 arguments, and one with `a`.  To avoid combinatorial explosion, the compiler generates these lazily, as needed. 




### Function Overloading ✅

Crisp support function overloading for functions defined with `def-function`, `def-grid-function`, as well as property access functions on 
some of the other types. Note that property access via a `soa-vector` requires an additional overload. The compiler
will warn if it detects `soa-vector` property access with an asymmetric overload.

Overloaded functions can have the same name, but different type signatures. The compiler will use the 
types of the given parameters to determine which overload should be called. 

`def-kernel` function CANNOT be overloaded. Each kernel function must have a unique name.

As mentioned, the property access functions that some types support can be overloaded as well (discussed later), 
but the `make-XXXX` functions CANNOT be overloaded. 


### Recursion Disallowed ✅

Crisp does not support recursive functions, nor mutually recursive functions.  The compiler will emit an error if it detects this.




### Declaring Types - Kernels ✅

#### def-kernel ✅

`def-kernel` defines a kernel function. It is much the same as `def-function` with only a few differences:

- `def-kernel` functions always returns NIL. It does not need to explicitly declare a return type.
- Storage Handle types (ie `cell` `vector`, `matrix` and `tensor`)  must be fully typed with address space, alignment and element type. (See Storage Handle Types below)
- `def-kernel` functions do NOT support `&key` or `&optional` arguments.
- but it DOES support `&out` 
- the function name for kernels MUST obey the C standard identifying rules.  Thus "do_something" is a valid name, but "do-something" is not.
- unlike regular functions, kernel functions do NOT support overloading. Each kernel function must have a unique name.
- `def-kernel` function has a constrained choice of accepts types for parameters. It does NOT support first order function arguments (unlike regular `def-function` and `def-grid-function`) 
- structs and records (see `def-struct` and `def-record`) can be passed as arguments to `def-kernel` but they are private arguments, meaning that while they are editable, they are per thread. The alterations a thread might make to a kernel arg struct or record is not seen by other kernel threads, nor by the host.   For that you will need a Storage Handle (`cell`, `vector`, `matrix` or `tensor`)

Like `def-function` ALL the parameters to the kernel function must have their types declared somehow. 

```
; note the name "add_two" is a valid C identifier
; note also that since the arguments are typed in the parameter list, we didn't need a declare directive at all. 
;  the return type is assumed NIL.

(def-type int-result-cell (cell int :global))

;; -- add_two --
(def-kernel add_two (a b &out result)
   (declare #'(int int &out int-result-cell => nil))
   (set! (~ result) (+ a b)))
```

`def-kernel` can be templated ( see `with-template-type` below), but in this case you MUST explicitly provide a `gen-KERNELNAME` at the top-level
for each specialized kernel you want the compiler to generate. Otherwise the compiler will not output the kernel at all.  

#### Implicit Arguments ✅

The example hoisting code that Crisp outputs will often have more arguments than the ones in the parameter list of `def-kernel`.  

There are four different cases where this happens:
 - Storage Handle parameters (`cell`, `vector`, `tensor`)
 - records directly passed at kernel boundary. 
 - debug communication channel
 - scratch memory
 - user defined "implicit" Storage Handles

 Crisp lets you put Storage Handles directly into the kernel parameter list, 
 but in practice the hoisting code will often need to set MULTIPLE arguments: 
 at minimum a C-style pointer to the data and a size argument, but also strides and extents
 for higher arity Storage Handles. 
 The kernel will handle marshalling those separate arguments. 

If the debug communication channel was elected when compiling the kernel, then the kernel will accept additional arguments
for the debug data channel data pointer and size, etc.  

If the kernel or any of the functions it calls invoke `make-scratch-XXXX`, then then kernel
will accept additional arguments for the scratch memory Storage Handle. 

Similarly, every invocation of `make-implicit-XXXX` adds at least two implicit args to the kernel.



#### def-kernel-exact ✅

`def-kernel-exact` is like `def-kernel` . It can be templated and has the same restrictions.  
But kernels defined with `def-kernel-exact` do NOT support any implicit arguments.  
Additionally the `&out` argument specifier is not supported in the param list for `def-kernel-exact`
Instead `def-kernel-exact` supports different marshalling functions to help create Crisp Storage Handles, 
including the ones required for the Crisp debug logging and scratch memory.

`def-kernel-exact` is provided for users who have less control over how their kernel is hoisted and may have to instead adapt to some existing interface.

##### voidp type and marshall-vector
`def-kernel-exact` can use the `voidp` type for its arguments, but this type cannot be used in other contexts.  It can also call the `marshall-XXXX` function
which is a function Crisp provides for making Crisp vectors from `void` pointers and byte counts. This function cannot be used in other contexts.

```
(def-type float-vec-t (vector float :address-space :global :align :compact))

;; -- vector_add_k --
(def-kernel-exact vector_add_k (APtr ASz BPtr BSz CPtr CSz)
  (declare #'(voidp ulong voidp ulong voidp ulong => nil))
  (let ((A (marshall-vector APtr ASz float-vec-t))
        (B (marshall-vector BPtr BSz float-vec-t))
        (C (marshall-vector CPtr CSz float-vec-t)))
    (vector-add A B C)))
```

The recommended practice is to use marshalling functionss immediately within a `def-kernel-exact` body 
to create standard Crisp views, and then call some some inner function. That inner function will let you leverage
the `&out` specifier and possibly other safety checks. 

##### Marshall Functions ✅

`marshall-cell` — 1D opaque handle (no stride/extent)


`(marshall-cell type byte-size ptr offset)`
- `type` — fully-specified cell type alias, e.g. `(cell long :address-space :global)`
- `byte-size` — `ulong` total byte size of the backing buffer
- `ptr` — raw pointer (`voidp`)
- `offset` — `ulong` element offset into the buffer


`marshall-vector` — 1D strided view (tensor N=1)


`(marshall-vector type byte-size ptr offset_0 stride_0 extent_0 length)`
- `type` — fully-specified `vector` (or tensor N=1) type alias
- `byte-size` — `ulong`
- `ptr` — raw pointer (`voidp`)
- `offset_0` — `ulong` offset along dimension 0
- `stride_0` — `ulong` stride along dimension 0
- `extent_0` — `ulong` extent (size) along dimension 0
- `length` — `ulong` total number of elements (product of extents)


`marshall-matrix` — 2D strided view (tensor N=2)

`(marshall-matrix type byte-size ptr off_0 off_1 str_0 str_1 ext_0 ext_1 length)`
- `type` — fully-specified `matrix` (or tensor N=2) type alias
- `byte-size` — `ulong`
- `ptr` — raw pointer (`voidp`)
- `off_0`, `off_1` — `ulong` offsets along dimensions 0 and 1
- `str_0`, `str_1` — `ulong` strides along dimensions 0 and 1
- `ext_0`, `ext_1` — `ulong` extents along dimensions 0 and 1
- `length` — `ulong` total element count



`marshall-tensor` — N-dimensional strided view, keyword form

```
(marshall-tensor type byte-size ptr
  :offsets (o0 o1 ... oN-1)
  :strides (s0 s1 ... sN-1)
  :extents (e0 e1 ... eN-1)
  :length  len)
```

- type — fully-specified tensor type alias, e.g. `(tensor float 3 :address-space :global :align :compact)`. Also accepts an expanded vector or matrix alias (since both desugar to tensor).
- `byte-size` — `ulong` total byte size of the backing buffer
- `ptr` — raw pointer (`voidp`)
- `:offsets (o0 ... oN-1)` — list of exactly `N` `ulong` offsets, one per dimension
- `:strides (s0 ... sN-1)` — list of exactly `N` `ulong` strides, one per dimension
- `:extents (e0 ... eN-1)` — list of exactly `N` `ulong` extents (sizes), one per dimension
- `:length len` — `ulong` total element count (product of extents, pre-computed by the host)

All four keywords are required. Each list must be of length N. The macro validates at compile time that each sublist contains exactly N elements matching the tensor arity declared in type. Errors are signalled for missing keywords or wrong sublist lengths.


### Implementation Notes
"vector" and "storage" at the kernel boundary is just a collection of registers from the call interface.
`marshall-vector` is just a macro that associates them.

In reality even `(def-kernel k (someVector) ...)` just expands to 

```
(def-kernel-exact k (sv-len sv-mem)
  (let ((someVector (marshall-vector sv-len sv-mem))) ...)
```


#### implicit Storage Handle arguments

If the kernel or any of its subfunctions use the Crisp side channel convenience functions
like `make-scratch-XXXX` , `make-implicit-XXXX` OR if the kernel was/will be compiled with the debug logging option, then these Storage Handles will have
to be  explicitly passed by the host and marshalled.  

- `marshall-scratch-XXXX`
- `marshall-implicit-XXXX`
- `marshall-debug-logging-vector`

Note that both the metadata and the example hoisting code that the compiler outputs will have size expressions gathered 
by the compiler for all of these. Be sure to incorporate them into your own enqueueing/hoisting code.





Struct Types ✅
------------

`def-struct` defines a structure and makes a new type. 

It also generates functions to create instances of struct (`make-XXXX`), and to access its members.
Additionally, the type constraint function `is-XXXX?` is also generated.

Storage Handles can be specialized to struct types. If a struct needs to be passed directly to a 
kernel, that is the most common way of doing so for both input and output arguments. Note that structs CAN be passed directly to a kernel, without being wrapped by a Storage Handle. But in that
case the struct is configured with constant memory and is read only, immutable. 


```
(def-struct point
    (x float)
    (y float))


;; make-XXXX
(make-point :x 3 :y 4)
;; type signature of make-point is #'(&key :x float :y float => point)
```

### member data rules

A struct can contain any type that has a fixed, known size at compile time.
This would include:
- Scalar types (`int`, `float`, etc)
- Hardware vector types (`float4` etc)
- Other structs
- Compile time sized `array` 
- Views to large data (`cell`, `vector`, `tensor`, `matrix`)

But it excludes:
- `functions` and `kernels`
- Crisp specific internals, like `storage`

Note also that views can't be exchanged with the host directly. A struct that contains a view
cannot use the C interop for data exchange with host. Marshalling would be required.

### layout and alignment 

Crisp structs follow a strict "scalar" layout.
- Basci scalar types are aligned to a multiple of their own size ( a 1-byte `char` aligns to 1, a 4-byte `float` aligns to 4, an 8-byte `double` aligns to 8).
-  A struct's overall alignment is equal to the alignment of its most strictly aligned member.  If a struct contains a `char` and a `float`, the struct's alignment is 4.
- Padding: Members are placed at the lowest available offset that satisfies their alignment. The total size of the struct is padded at the end to be a multiple of its overall alignment.
- Storage Handles - (ie `(vector someStruct)` ) The stride of a storage handle is exactly the size of the struct. Zero extra padding between elements.



### type constraints: is-XXXX?

Using `def-struct` automatically generates `is-XXXX?` for that struct name, which can be used as a type constraint function
in `with-template-type`.  See the discussion of type constraints in `with-template-type` for more information.

### compile-time properties
```
(def-struct addressable
   (value int)
   (address-space address-space :c-t)
   (access access :c-t :read-write))
```


The `:c-t` key can be used to label any property as a compile-time property. It can be inspected
via a property accessor, just like any property (e.g. `(access~ someAddressable)`).  But cannot be changed at runtime. It becomes part of the type declaration for the struct.

A default value can follow the `:c-t` key.  This default will be used if a call to `make-XXXX` did not specifiy it. 

```
;; example #1
(let ((v (make-addressable :value 10 :address-space :global :access :read-only))
      ;; access has a default value, so can be elided:
      (v2 (make-addressable :value 20 :address-space :global)))
   ...)

;; example #2 
(def-function has-addressable-arg (a b)
   (declare (type a (addressable :address-space :global :access :read-only))
            (type b (addressable :address-space :global))
            (return-type nil))
   ...)
```
<!-- 

THIS IMPLEMENTATION DETAIL IS BEING REALIZED

> [!NOTE]
> **Implementation Status**: The implicit syntax shown above (where constructor arguments like `:address-space` are automatically promoted to type parameters) is a future goal. 
> Currently, to achieve this behavior, you must use **Explicit Templates**:
> ```lisp
> (with-template-type (T &optional (AS :global))
>    (def-struct addressable (val T) (space address-space :c-t AS)))
>
> ;; Specialize explicitly
> (def-type-alias GlobalAddr (addressable-type int :global))
> (make-GlobalAddr :val 10)
> ```

-->

### type names vs. type constructors
When a struct is defined with `def-struct`, its name becomes a new type name (e.g., `point`).

If the struct has compile time properties (`:c-t`) then those become part of its complete type constructor.

Example:
```
(def-struct addressable
   (value int)
   (address-space address-space :c-t)
   (access access :c-t :read-write))

(def-function foo (a)
  (declare (type a (addressable :address-space :local :access :read-only)) ...))
```

If a struct is defined within a `with-template-type` block, the system also generates a type constructor (e.g., `point`). This constructor must be used with its type arguments to create a concrete type, like `(point int)`.


### member access: `XXXX~`
Functions to access members are autmatically generated. The function name is the member name follow by `~`.

This function can be used to get a value, and in conjunction with `set!` it can be used to change it.

These functions can be overloaded, so you can make your own custom setters or getters for your structs. 
See "overloading member access function" below for more infomation. 

```
; function #'x~ and #'y~ are automatically generated
x~ #'(point => float)
y~ #'(point => float)

; example:

;; -- align-y --
(def-function align-y (p1 p2)
  (declare #'(point point => nil))
  (let ((horiz (y~ p1)))    ; get 'y from point p1
    (set! (y~ p2) horiz)))  ; set 'y of point p2 to that value


```

#### Non Overrideable Member Access: `~XXXX~` ✅
Addiitonally, a non-overridable function to access members is also automatically generated. That function name is `~` followed by the member name, followed by `~` again.   This function can be used to get a value directly
from a struct bypassing any custom overload of the access, and can be passed to `set!` as well. 

These are mostly used by the overloaded member access functions, but are occasionally useful when dealing with
atomics or other places where diverting through a custom access function is not desired.

```
(let ((horiz-x (~x~ somePoint)))    ; get x from somePoint
   (set! (~x~ otherPoint) (+ horiz-x 10))  ; set x of otherPoint 
 ...)
```

#### overloading member access function ✅
The access functions that are just one tilde followed by the member name can all be overloaded and thus
custom accessor functions can be provided. 
Simply define a function of the same name and the correct type.


In this example, this function flips a point over the vertical axis
by returning the negatiion of the x value.

```
;;;  x~
(def-function x~ (p:point)
  (declare (return-type float))
  (- (~x~ p)))  ;; internally use the non-overrideable access function.

(let ((p (make-point 5 0))
      (neg-x (x~ p)))   ; neg-x will be -5 because of the overloaded x~ function above.
    ...)  
       
```

#### AoS and SoA

Crisp supports vectors of structs. The standard Crisp `vector` can be used for an "Array of Structs" (AoS) layout, but there is also
`soa-vector` which can be used for "Struct of Arrays" (SoA) layout. See `soa-vector` below.

#### Overload member access and soa-vector

The overload member access functions (like `x~` in the previous section) will NOT WORK for structs in a `soa-vector`. 
If you want to overload access there too, an additional overload function must be defined:

```
;;;  (x~ sv) returns the vector of ALL x values, we are adjusting the one at idx
(def-function x~ (sv idx)
    (declare (type sv (soa-vector point)) (type idx ulong) (return-type float))
    (- (~ (x~ sv) idx)))
```

The compiler will emit a warning if it encounters access on a soa-vector for a struct that has asymmetric property accessor overloads.

In the future, Crisp may handle this automatically. 

#### `with-struct-accessors`  - ADVANCED  ✅

In Crisp, like in C++, the struct type itself is not runtime inspectable. But unlike C++, Crisp has compile time affordances
that help you write macros that generically walk all the properties. One of those affordance is `with-struct-accessors`.

```
(defmacro with-struct-accessors (struct-type (aos-var &optional soa-var) &key (access :public) &body body) ...)
```
This is an iterate-and-bind macro that loops over all the properties of `struct-type`. The return
values of the `body` are gathered up and can be expanded (via `,@`) where needed.  
Each time through the loop `aos-var` will be bound to some  accessor (e.g. `x~` then `y~` for the `point` type) that can take a struct argument.  If provided, `soa-var` will be the soa accessor variant that takes a `soa-vector` and an index `ulong`.  

The `:access` key determines which class of accessor is enumerated. If `:public` it 
enumerates the main public accessors (`x~` etc).  If `:raw` it enumerates the non overrideable
accessors (`~x~`).

See the "possible implementation" of  `convert-aos-to-soa` below for a usage example.




### def-setter ✅

`def-setter` can be used to define an overloaded function to set any property.
It uses the same name of the property but takes an additional argument.  
The return type for all setting functions is always nil.  

If the setter parameters are typed, there is no need for an additonal declare.

```
;; this custom setter function negates x

;;;  x~  (setter)
(def-setter x~ (p newVal)
   (declare #'(point float => nil))
   (set! (~x~ p) (- newVal))) 

(set! (x~ somePoint) 14) ;; <-- the x of somePoint is actually stored as -14 
```

If overloading the setting of a struct property and you wish to use that struct
consistently and correctly in a `soa-vector`, then an additional overload
for that is recommended as well. The compiler will warn if it detects the absence.
In the future, Crisp may handle this automatically. 

```
;; additional overload if we are using soa-vectors.

;;;  x~   (setter soa)
(def-setter x~ (sv idx newVal)
    (declare #'((soa-vector point) ulong float => nil))
    (set! (~ (x~ sv) idx) newVal))
```


### def-record ✅

`def-record` is very simlar to `def-struct`. Records "pun" as structs. The crucial difference is that while structs result in contiguous memory (though aligned and padded), records are not contiguous in memory.  Records are just a collection of register, of memory addresses. They act as virtualized structures.

`def-record` undergirds the Crisp "implicit" argument passing - how the many and sundry pieces of data required for a `tensor` get bound into one virtual variable passed from function to function. 

`def-record` has the exact same syntax and affordances as `def-struct`, including overloadable `XXXXy~` property accessors and non-overloadable `~XXXX~` accessors, and  support for `def-setter`, `def-derived-type`, templates , compile-time properties and more.

Though there is no equivalent of `soa-vector` for records.  

```
(def-record virtual-point
  (x float)
  (y float)
  (d bool :c-t)) ;; <-- some compile-time known property

(def-kernel-exact some_op (vpx vpy)
  (declare (type vpx vpy float))
  (let ((v-p (make-virtual-point :x vpx :y vpy :d (target-has :fp64 T))))
    ...))
```



#### Notes

- Importantly, types defined by `def-record` cannot be wrapped in Storage Handles.
- Both records and structs can be passed directly to kernels on the kernel boundary. 
- - But when doing so structs are immutable and cannot have their properties changed.
- - Records, on the other hand, are mutable in the current thread context. Any value
    change is not communicated back to the host or to other threads.
- kernels with structs directly on the parameter boundary (not in a Storage Handle) cannot
  be auto differentiated (with the `--differentiate` flag)
- In contrast, kernels with records directly on the parameter boundary CAN be auto differentiated,
  though that would be unusual.

<!-- IMPLEMENTATION NOTE
  So make-XXXX for records is capturing register identities, not values.
  This should work fine for 
    - kernel arguments
    - function arguments that originated as kernel arguments.
    - memory (:global, :local etc)

  But we have to be careful with temporaries, especially things that might 
  be modelled with alloca:

  (let ((someStruct (make-some-struct :x 10 :y 20))
        (someValue  10)
        (someRecord (make-some-record :vx someValue :vss someStruct)))
      (return someRecord))   

  If a record-of-a-struct "explodes-and-flattens" it to registers, that should be fine.
  But otherwise the code above could have an implicit "use-after-free" or incorrect
  reuse of    :vss someStruct   

  Therefore record-of-struct "explodes-and-flattens" the struct to registers.  
-->

> Implementation Note: consider changing `make-` to `marshall-` for `def-record`.


### Array Type ⚠️

`(array T N)`

In Crisp an `array` type is a 1 dimensional vector type of consecutive elements where
both the element type `T` and the length `N` of the array are known at compile time.

This is mostly a utility type used by some of the Crisp built-ins. Most users will be
better served by the `vector` Storage Handle. 

Like for `vector` the simple `~` accessor is available for dereferencing.

```
(def-kernel something (arr)
  (declare #'((array long 4) => nil))
  (+ (~ arr 0) (~ arr 3))) 
```

Arrays can be direct kernel parameters. But if they are appear directly on the kernel boundary,
they are read only, immutable.

Arrays always use :compact alignment.

Arrays can be elements of a struct, and can ALSO be in a record, but if used in a
`def-record` they are automatically virtualized like the other `def-record` members 


#### `~` ✅
Like vectors, arrays support `~` for refer-by-index semantics. This can be used for both
get and set.

#### `length~` ✅
The `length~` compile time property is supported.

#### No `make-array`
Arrays are expected to be part of structs or records, or passed from the host when enqueing. 
There is no `make-array` expression. 

#### No Nesting

arrays cannot be nested in one another. And expression like `(array (array long 4) 6)` 
will trigger a compilation error.

#### Note: soa-vector Disambiguation

Crisp also has the `soa-vector` data type, where "soa" stands for "Struct of Arrays." The fixed-size `(array T N)` type is architecturally distinct from `soa-vector`. An `array` is a stack-allocated or register-backed primitive, whereas `soa-vector` is a pointer-backed Storage Handle.




### Incomplete Types ✅

An "Incomplete Type" is a composite type (defined via `def-record` or `def-struct`) where one or more of its compile-time properties have not been specified in type declaration.

For example, given a record definition:
```lisp
(def-record pants
  (size int)
  (color someEnum :c-t))
```

The `make-pants` call is always required to have both `:size` and `:color` specified (e.g. `(make-pants :size 32 :color :blue)`), but the actual declaration of the type, as might appear in a function parameter list, can elide compile time properties and be "incomplete".
```
;; a 'complete' type: all compile time properties specified
(pants :color :blue)

;; an 'incomplete' type: one or more compile time properties unspecified:
(pants)
;; also valid and 'incomplete':
pants
```

Incomplete types allow for polymorphism in internal functions. You can write a function that accepts any kind of `pants`, regardless of (compile time) color.

#### Rules for Incomplete Types:
1. **Allowed in `def-function` and `def-grid-function`**: You may declare parameters with incomplete types in standard functions.
2. **Forbidden in `def-kernel` and `def-kernel-exact`**: Kernel parameters (the boundary between host and device) MUST have fully specified complete types. The host must know the exact layout and semantics of the data it is passing. Incomplete types cannot be used there.  Note that  `gen-XXXXX`, which can be used to generate a kernel from a grid function, when encountering an incomplete type will use its default value (if specified) or emit a compile error (if no default was specified)
3. **Compile Time Properties Only**: Runtime member fields are not required in the type declaration anyway, so the question of "complete" vs "incomplete" does not apply to them.

This question of "complete" vs "incomplete" matters because if a `:c-t` property
is declared in the type constructor, then the compiler will enforce that requirement. Whereas an incomplete type is more flexible. 

```
(def-record pants
    (size int)
    (color someEnum :c-t))

(def-function op-only-blue (blue-pants)
  (declare (type blue-pants (pants :color :blue)) (return-type nil))
  ...)

;; this function takes any pant, but calls an operation that only
;; accepts blue pants.  This is potentially a problem, but, by itself,
;; would not trigger a compile time error. 
(def-function remeasure (p)
  (declare #'(pants => int))
  (op-only-blue p)
  (- (size~ p) 2))

;; kernels are required to have complete types for all parameters and return
;; values.  Here, we see (pants :color :blue) is specified, therefore
;; this is safe and no compile error is generated.
;; BUT if the color were :red, then an error would appear.
(def-kernel omg (cbp &out csz)
   (declare #'((in-cell (pants :color :blue)) &out (out-cell int)))
   (let ((new-size (remeasure (~ cbp))))
     (set! (~ csz) new-size)))
```



### Template Types ✅

`with-template-type` can wrap several `def-` declarations to template them. 


Doing so automatically generates a type specifier (e.g. `(point long)`) and specializer function that 
can explicitly instantiate the template for a type:  `gen-XXXX` (e.g. `(gen-addTwo long)` or `(gen-point float)`).
where `XXXX` is the name of the function, struct, vector, etc that was defined.


```
(with-template-type (T)

  ;; -- addTwo --
  (def-function addTwo (a b)
      (declare (type a b T) (return-type T))
    (+ a b)))


(with-template-type (T U A)
    (declare (type-is U #'is-floating-point?) (value-is A #'is-address-space?))

  ;; -- move-discrete --
  (def-function move-discrete (a b)
     (declare (type a T) (type b U) (return-type (vector U :address-space A)))
     ...))

; we can template structs as well
(with-template-type (T)
  ;; -- point -- 
  (def-struct point (x T) (y T)))

```

It is possible to put a binding form (like `let`) between, so long as its bindings are evaluable
at compile time.  
Example:
```
(with-template-type (T &optional (M ""))
  (let ((make-reduce-l-s-v (gen-make-reduction-local-scratch-vec T M)))

    ;; -- reduce-something --
    (def-function reduce-something (someFunction someThing &optional (localScratchVec (make-reduce-s-v)))
      ...)))
```


Note that automatic numeric type promotion does not occur during template argument deduction. 
All arguments passed to a templated function must match the expected type exactly, 
or an explicit conversion function (like `to-float`) must be used.

#### Syntactic Sugar: `(<T> ...` ✅

`(with-template-type (T U)`  can get a little long to type and swallow. For that reason,
Crisp has a bit of syntactic suger that can make them slighly more palatable:

```
(<T U>  
 (def-...
```

Borrowing from C++, the type vars can appear between `<  >`  and that expression
can stand-in for the wordier `with-template-type (T)` .  


#### XXXX type function ✅

`with-template-type` AUTOMATICALLY defines a new type expression: XXXXX  for whatever it is wrapping.
That type expression can be used to specialize the template and return that specific type.
Example:
```
(with-template-type (T)
  ;; -- point --
  (def-struct point (x T) (y T)))

(point int)  <== evaluates to the type, which is a point specialized to int.


;; I don't like this example as it's not really realizable.
(with-template-type (T U A)
    (declare (type-is U #'is-floating-point?) (value-is A #'is-address-space?))

  ;; -- move-discrete --
  (def-function move-discrete (a b)
     (declare (type a T) (type b U) (return-type (vector U :address-space A)))
     ...))

(move-discrete int float :global) ; that specfic type. 
```

##### Incomplete Types

Passing `nil` as a type argument when specializing with `XXXX` produces an incomplete type. 
This can help make interoperation between different functions and structures more flexible.

Incomplete types are used in function signatures (only). Use them when you need to define 
a flexibe function, one that is typed to a struct or vector or similar, but maybe doesn't need
ALL the information normally needed when we define it. But once it is _used_ the compiler will make sure that
all the needed type information is present (or it'll error :-) )

```
(with-template-type (T U)
  ;; -- pair --
  (def-struct pair (first T) (second U)))

(def-type incomplete-p-t (pair nil (vector long)))  ;; <-- a pair with a vector in the second type. Who cares what's in the first?

;; -- sum-length --
(def-function sum-length (a b)
  (declare (type a b incomplete-p-t) (return-type ulong)) 
  (+ (length~ (second~ a)  (length~ (second~ b)))))

```


#### gen-XXXX ✅

`with-template-type` ALSO AUTOMATICALLY defines an expression to get or construct a specialized form
of whatever it is wrapping.  This is `gen-XXXX` 

```
(with-template-type (T)

  ;; -- addTwo --
  (def-function addTwo (a b)
      (declare #'(T T => T))
    (+ a b)))

(reduce-to-workgroup someVector (gen-addTwo int)) ; <-- specialize "addTwo" for int and pass that to reduce-to-workgroup


; template over a struct
(with-template-type (T)
  ;; -- point --
  (def-struct point (x T y T)))

(gen-point int)                         ; a. generate the template. 
(setf g-horizon (make-point :x a :y b)) ; b. now use it (assuming 'a' and 'b' are ints)

(map-stride #'make-point (vec-of-X vec-of-Y) vec-of-points)
```

In the case of templates, `gen-XXXX` is a special form or macro, not a function. 
It cannot be passed as an argument or referenced (ie  #'gen-addTwo is illegal)

As type inference is expanded, it may not be necessary to use `gen-XXXX` except in
limited cases. 

Note that `gen-XXXX` CANNOT instantiate an incomplete type. Passing `nil` as type arg is not allowed.

<!-- QUESTION: How DO incomplete types get made into complete types? Such that they could then be instantiated. 
      ANSWER: That's not how they work. They just make function signatures flexible. 
              They are never instantiated themselves. They just let a function sneak by for a 
              bit without having to have ALL the info.  A complete type will still need to be provided once
              someone USES the function. -->

##### kernels ⚠️

Crisp can template kernels as well. But any kernel that is templated MUST have 
specializations generated with `gen-XXXX` .  Furthermore, kernel functions must have 
unique names, so when applied to kernels `gen-XXXX` takes one additional last argument
which is a string name that the compiler should give the kernel. 

```
(with-template-type (T)

   ;; -- happy_stance --
   (def-kernel happy_stance (data:(vector T :address-space :global)
     ...)))

(gen-happy_stance float "happy_stance_f")
(gen-happy_stance int  "happy_stance_i")
```

##### kernels from `def-grid-function` ⚠️

Very often, especially when writing library code, you will want to
write some access pattern as a grid function for someone to use in their
kernel. Perhaps a grid function to "sweep up" results.

But it also the case that you may also want that function as a standalone kernel.
This is very common GPU-land where because marshalling individual workgroups is out of our
power, the most expedient course is to simply follow one kernel with another, rather than
trying to combine them. To assist with this very common "double usage" need, 
the `gen-` prefix can be used with any grid function (templated or not) and
a kernel will be produced if that third string argument is present.

```
(with-template-type (T)
  (def-grid-function templated-sweep-f ...))

(def-grid-function other-sweep-f ...)

(gen-templated-sweep-f ulong) ;; <-- this just generates the ulong specializtion
(gen-templated-sweep-f ulong "my_sweep_kernel")  ; <-- this generates a kernel

(gen-other-sweep-f "my_other_sweep_kernel") ; <-- generates a kernel from an untemplated grid function
```


#### &optional &key

The `with-template-type` argument list supports `&optional` and `&key` 

```
(with-template-type (T &optional C)
  ;; -- Point --
  (def-struct Point (x T) (y T)
    (when C '(color C)) ; The color field is optional
  ))
```

#### type constraints 📝

Sometimes we want to declare that a type adheres to some rule or condition. These are called "type constraints"
and Crisp supports them in conjuction with `with-template-type` and `declare`. We've already had some examples
in the fictional `move-discrete` shown earlier.  

Here is another example.
```
(with-template-type (T U)
  (declare (type-is T #'is-orderable?) (type-is U #'is-point?))
   ;; def-something  ...)
```

Crisp has several built-in type constraint functions:
- `is-numeric?` / `is-scalar?`
- `is-hardware-vector?`
- `is-integer?`
- `is-floating-point?`
- `is-orderable?`  => returns T if the type supports both `<` and `>` 

Additionally `def-enumeration` and `def-struct` automatically generate a `is-XXXX?` type constraint function
 for that enumeration or struct.   

Lastly, a custom type constraint function can be defined with `def-constraint` (see below).

##### `type-is` vs. `value-is`

The with-template-type form can be used to create generics that are parameterized by types (e.g., T which could be `int` or `float`) or by compile-time values (e.g., A which could be `:strided` or `:compact`). Crisp provides two corresponding constraint checks:

- `type-is` is used to constrain a template type parameter. It expects a type parameter and a predicate that operates on types.
`(type-is T #'is-numeric?)`
- `value-is` is used to constrain a template value parameter. It expects a value parameter and a predicate that operates on values. The most common use is for enumeration literals.

```
(def-enumeration phylum :arthropoda :chordata :nematoda )

;; Here, P is a template VALUE parameter, not a type parameter.
(with-template-type (P)
   (declare (value-is P #'is-phylum?))  
   (def-SOMETHING ...))

(gen-SOMETHING :chordata)  ; <-- awesome . Crisp generates a chordate. 
(gen-SOMETHING phylum)     ; <-- error .  The constraint expects a phylum value, not its type.
(gen-SOMETHING float)      ; <-- error.  'float' is a type, not a value from the 'phylum' enum
```


### def-constraint 📝

Constraint functions are not regular functions. They are limited to where they can
be invoked and must be fully evaluable at compile time. All constraint functions 
have the same signature and do not need to declare it. Every constraint function
takes a single type as an argument and returns a boolean. 

They cannot perform other actions, like generating specializations or defining new types etc.
If it is C++ SFINAE-like support you seek, check out `defmacro` and the
section on "Conditional Compilation". 

Example:

```
(def-constraint has-energy? (T)
  (type-has-prop? T 'energy))


(def-constraint is-comparable? (T)
  (and (has-overload? #'< #(T T => bool))
       (has-overload? #'> #(T T => bool))))
```

Constraint functions are primarily used in conjuction with `with-template-type`.  
See the sub-section on "type constraints" above.

Crisp has some functions that can help you define your own type constraints:

#### type-has-prop?

`(type-has-prop? someType propName)`

evaluates to T/nil if something of someType has a member with that name, accessible
with `(<propName>~ obj)`
e.g.  `(type-has-prop? T 'length)` 


#### has-overload?

`(has-overload? someF someSignature)`

evaluates to T/nil if a particular function has an overload of the provided signature.

e.g. `(has-overload? #'+ #(float float => float))`

#### is-substitutable-for?

`(is-substitutable-for? substT baseT)`

The `is-XXXX?` types constraint functions are exact. If using derived types, 
flexibility might be desired. `is-substitutable-for?` returns True if the type `substT` 
can be substituted for the type `baseT`. The substitution follows the `:subst` key 
when derived types are used.

```
(def-struct point ...)
(def-derived-type coordinate point :subst :pass-derived)

(is-substitutable-for? coordinate point) ;  => True ( because :pass-derived)
(is-substitutable-for? point coordinate) ;  => False.
```

| `:subst`        | `(is-substitutable-for? derived-T original-T)` | `(is-substitutable-for? original-T derived-T)` |
|-----------------|------------------------------------------------|------------------------------------------------|
| `:no`           |  `nil`                                         | `nil`                                          |
| `:equal`        |  `T`                                           | `T`                                            |
| `:pass-derived` |  `T`                                           | `nil`                                          |
| `:pass-orig`    |  `nil`                                         | `T`                                            |


### def-type-function 📝

Similar to `def-constraint`, `def-type-function` is not a regular function.
A type function takes one type and returns another. That's it. Having such is just useful enough
to make certain macro and meta-programming tasks possible and palatable. It does not require 
a `(declare ..)` block.

Type functions are evaluated at compile time (only). They cannot perform other actions like defining types 
or generating specializations. 

Possible example:
```
;; -- get-unsigned-type --
(def-type-function get-unsigned-type (InputType)
  (cond ((<= (sizeof InputType) (sizeof uint)) 'uint)
        (else 'ulong)))
```


    
## GPU Memory ⚠️

In the next section we introduce the Storage Handles (`cell`, `vector`, `tensor`). These are the only
data types Crisp supports for passing, or making available, blocks of memory
from the host TO the kernel. They are also the only vehicles for getting
any data back FROM a kernel, even if it's just a single digit (see the `cell` subsection).

For the kernel authors perspective there are three types of memory with
which we need to concern ourselves: Global, Local, and Constant.

#### Global Memory

Global memory is the largest memory space available to the GPU, typically measured in gigabytes (GB). It's accessible by all threads across all workgroups and is the only memory space directly accessible by the host CPU for transferring data to and from the GPU.

Any memory you prepare host-side and pass to the kernel will reside in global memory. Likewise, any results passed back from the kernel (`&out`) must also be in global memory.

But global memory access is slow.

#### Local Memory

Local memory (also called "shared memory") is fast. It is a low-latency high bandwidth on-chip memory space.
Its size is typically measured in kilobytes (KB) per compute unit (48KB to 128KB), and this
limited pool is shared among all workgroups running concurrently on that unit.

It must be prepared by the host, but the host 
can only prepare it to be available, it cannot write into it. It is not usable as a 
communication channel between host and kernel. 

Local memory is bound to a workgroup. It cannot be used to share 
data between workgroups. For that, global memory is needed.

Because it's a limited resource, requesting excessive local memory per workgroup can reduce the number of workgroups that run concurrently (lower occupancy), potentially impacting overall performance. 

#### Constant Memory

Constant memory is another fast on-chip memory that is optimized for broadcast scenarios. 
It is read only memory from the kernels perspective, but it CAN be initialized by the host. 
It is usually limited to 64KB per compute unit, and is ideal for small, read-only lookup tables, configuration
parameters, or coefficients that are shared by all threads.

With Crisp you have two ways of preparing constant memory: 
- Define and initialize it entirely at compile time using `def-constant-vector`. Kernels access it by its defined name.
- Declare a kernel parameter as Storage Handle type with `:constant` address space. The host is then responsible for allocating and initializing a read-only buffer and passing it to the kernel. The hoisting code generator will produce example code demonstrating the necessary host API calls.

#### Private Memory
`:private`  - need to be written


## Storage Handle Types ✅

Crisp has an internal represention called `storage`.  It is a contiguous array of bytes. 
`storage` entities cannot have their capacity resized. 
All `storage` entities have their data allocated either by the host or the compiler, 
they cannot be dynamically allocated by the runtime. 

We mention this internal represention not because you will interact directly with it, but because
it underpins the `cell`, `vector`, `soa-vector`, `matrix` and `tensor` constructs. All of them have a parent `storage`to which they provide access.

All these Storage Handle types are views into some parent `storage`. It is often useful to adjust the offset or size of a view to use it
as a cursor to a section of the `storage`. 


- `cell` : A view of one single element, type `T`
- `vector` : provides 1D linear access.  Technically, this is a 1D `tensor`
- `soa-vector` : Struct of Arrays. 1D linear access. See the `soa-vector` section below.
- `matrix` : a 2D `tensor`
- `tensor` : arity must be known at compile time. `tensor` can be any arity.  All tensors support "strides" which is how far to the next element in any of the `N` dimensions of the `tensor`


### Alignment ✅

Crisp supports three different alignment schemes for Storage Handles:  `:compact`, `:compact-offset`, and `:strided`

`:compact` alignment is contiguous with no gaps between data members. For a `vector` that would be compatible with `std::vector<T> .data()`.  `:compact` alignment also means that the underlying `storage` parent pointer is aligned to a 16 byte address boundary. Lastly, `:compact` storage handles are not offset. When alignment is `:compact` the access operations (`~`) ignore both the `stride` and `offset` elements of the storage handle and the element dereferences are calculated directly and performantly.

`:compact-offset` alignment is like `:compact` above except the `offset` elements of the storage handle
are used, they are not ignored.  This means there is an additional calculation that has to occur when
referencing.

 `:strided` alignment means that the Storage Handle uses its `stride` values when determining reference locations  during access operations. `:strided` Storage Hanles are often the result of transpose and slicing operations. This increases the reuse potential of Storage Handles and means less data copying
 is required.   

 If a storage handle type function arg is declared as `:compact` it will not accept a `:strided` or `:compact-offset` storage handle value.  Crisp developers can choose different strategies to help deal with alignment when declaring storage handle types. 
 - use templates.  `(with-template-type (T A) ...) ` where `A` is the alignment. Then you will have a "fast" `:compact` or `:compact-offset` version of your function and a more flexible `:strided`.
 - use incomplete types.  Just skip the `:align` keyword when declaring a storage handle type. The 
 compiler will then allow any type of storage handle to be used as an argument to that function. But, note, that it will default to the slightly slower `:strided` behavior.
 - be exact. Just specify the alignment you expect/desire. For users who aren't using transpose or slicing operations, this is simplest.

 Note that the tensor properties `offset` and `stride` are CANNOT be mutated when the alignment is `:compact`.  Attempting to do so is a compilation error.
 Similarly, `stride` is only mutable in a `:strided` aligned storage handle, and the compiler will emi
 an error if you attempt to mutate it otherwise.

 ### Contiguity  (aka row-major vs col-major) ✅ 

 Except `cell`, all Storage Handles have compile-time known "contiguity".  This tells the compiler
 in which dimension the data is contiguous. 
 The compiler time property to specify this is `:contiguous-term`. It defaults to `:last` for
 all types, and by virtue of there being a default it means this is optional. Many users will
 never need it, or need to know about it.

```
 (tensor float 6 :address-space :global :align :compact :contiguous-term :last)

;; usable with any tensor of any arity
 :contiguous-term  :last   ;; for a matrix, this is same as :row-major
 :contiguous-term  :first  ;; same as :col-major for a matrix

;; usable only with matrices
 :contiguous-term  :row-major
 :contiguous-term  :col-major

 (tensor-stride someMatrix (row-y col-x) ...)
```


### Storage Properties ✅

 `storage` has the following immutable properties:

| Property      | Type          |              |     Description |
| --------------|---------------|--------------|-----------------|
| byte-size~         | ulong         | runtime      | the number of bytes in the `storage`. This is immutable.|
| base-ptr~     | voidp          | runtime      | the voidp pointer of the storage. |
| address-space~ | address-space | compile-time | one of `:global`, `:local`, `:constant` |



The `byte-size~` property for a `storage` is sometimes known at compile time, but is most often a runtime property.  The `base-ptr~` is most definitely a runtime property. 
However the other properties are all known and evaluable at compile time. 

<!-- IMPLEMENTATION NOTE:

We should be able to model storage as a def-record.  But note that the memory address the storage is tracking is both a runtime property AND not directly 
accessible to the user. 

BUT - at the moment, let's NOT hide "address" from the user.  We'll simply
not document it, and play it by ear later. 

;; the address-space enumerations provide the "type" for the
;; storage properties of the same name. 

(def-record storage
    (address ulong)    
    (byte-size ulong)
    (address-space address-space :c-t))

-->

### Cell Properties ✅

A `cell` has these mutable properties:

| Property | Type    | Description |
| ---------|---------|-------------|
| parent~   | storage | address of a "parent" storage |
| offset~   | ulong   | offset into parent. |

`(offset~ someCell)` `(parent~ someCell)` can be used to access (or change) the `cell` view.
Note that out-of-bounds checks are not enabled by default. Certain compiler flags (like `--runtime-checks`) will enable them.

These property access functions are overloadable. It would be unwise to overload them for all `cell`s. Use `def-derived-type` 
to define your own cell type and overload those property accesses. The `~offset~` and `~parent~` functions
can also be used, and those cannot be overloaded. 


### Vector / Matrix /Tensor Properties ✅

 `vector` and `matrix` are just the 1D and 2D variants of `tensor`

Every `tensor` has these runtime properties:

| Name     | Type        | Description |
|----------|-------------|-------------|
| length~   | ulong       | the number of elements in the `tensor`. Product of the `extents`. This property cannot be directly `set!` for 2D and higher tensors. But CAN be set for `vector`. |
| parent~   | vector      | address of a "parent" storage |
| offsets~   | offset-type       | `def-rec-vec` the length of the `num-dims` that tracks the count to the starting element in the storage. |
| num-dims~ | ulong       | number of dimensions of the tensor.  This is an immutable compile time property of the tensor |
| strides~  | stride-type |  `def-rec-vec` the length of the `num-dims` that tracks the count to the "next" element in that dimension |
| extents~  | extents-type | `def-rec-vec` the lenght of `num-dims` that tracks the extent of that particular dimension |
| align~   | align-enum | `:strided` or `:compact` or `:compact-offset`. This is an immmutable compile-time property. |
| contiguous-term~ | contiguity-enum | `:last` or `:first`. This is an immutable compile-time property. |

Each of those properties can be accessed by the `XXXX~` function.
e.g. `(length~ someTensor)` , `(parent~ someTensor)`

The `align` and `contiguous-term` properties are known at compile-time and are immutable.  

But since these types are just views into some `storage`, their other properties are mutable. 

These property functions for the mutable properties can be overloaded.  They can also be retrieved with `~XXXX~` (which is not overloadable).

#### Settable Properties ✅ 

None of the `storage` properties can be set. Also, excepting `byte-size`, all the `storage` properties are compile time properties. 
The `byte-size` property on a `storage` entity is sometimes a compile time property, but usually it's a runtime property. Regardless, it cannot be changed, .
But ALL the mutable properties on the Storage Handle view can be set. And `vector` can also set the  `length`.

```
(set! (length~ someVector) 10)
(set! (parent~ someMatrix) otherStorage)   
;; offset for cell and vector is direct.
;; but for 2D matrix and higher, requires index
(set! (offset~ someCell) 100)
(set! (offset~ someVector) 4)
(set! (offset~ someMatrix 0) 40)
(set! (offset~ someMatrix 1) 50)
```

Use `def-setter` to overload the property setting function.  `~XXXX~` can also be used to get / set the respective properties


Note that it is an error to set the `length` or `offset` of any Storage Handle such that it's `(length + offset) * (sizeof elementType)` is greater
than the `bytes` of the parent `storage`. But the checking and enforcement for these errors is NOT on by default.

#### Pass Through ✅ 

The `storage` property accessor  `address-space~` can be used directly on any Storage Handle type. 
There is no reason to do `(address-space~ (parent~ some-vector))`.  Simply doing `(address-space~ some-vector)` is sufficient.

Similarly, the `base-ptr~` accessor can be used directly on any Storage Handle type. `(base-ptr~ some-vector)` is sufficient.

### Element Access ✅

- `~`
- `~ref~`

`~` is the main function for accessing elements in a Storage Handle. It can be `set!` and overloaded.
It would be supremely unwise to overload `~` generally. Instead use `def-derived-type` to 
define your own subtype and overload `~` for that type. 

```
;; cell
(~ <cell>) ;; get
(set! (~ <cell>) <value>) ;; to  set!

;; vector
(~ <vector> <index>) ;; to get 
(set! (~ <vector> <index>) <value>) ;; to set!

;; soa-vector of point
(x~ <soa-vec> <index>) ;; get the `x` of point at <index>
(set! (x~ <soa-vec> <index>)  <someValue>) ;; set the `x` of the point at <index>

;; matrix
(~ <matrix> <y-index> <x-index>) ;; to get
(set! (~ <matrix> <y-index> <x-index>)  <someValue>) ;; to set!

;; tensor
(~ <tensor> ... <z-index> <y-index> <x-index>) ;; get
(set~ (~ <tensor> ... <z-index> <y-index> <x-index>) <someValue>)
```

```
; example
(let ((vec #(2 4 6 8))
      (elem (~ vec 1))) ;; 4
  (set! (~ vec 0) (* 2 elem))) ;; stores "8" into the first position of the vec.
```

#### `~ref~` ✅ 
 `~ref~` can also be used to get and set elements in a Storage Handle and these element
access functions cannot be overloaded.   `~ref~` is intended to be used from overloads of `~`

```
;; example with vector
(~ref~ <vector> <index>)  
(set! (~ref~ <vector> <index>) <value>)
```


### Helper Functions ✅

`(element-type~ someStorageHandle)`  a type expression that returns the type of the elements in the Storage Handle.

`(bytes~ someStorageHandle)`  a helper function that calculates the current number of bytes in the Storage Handle.
Note that this is NOT a passthrough. If you want the total number of bytes in the parent `storage`
you'll need `(byte-size~ (parent~ someStorageHandle))`

`(num-dims-of someStorageHandle)`  returns the number of dimensions of a storage handle.
Very useful for the `tensor` type, less so for the others.

| type | dims | 
|------|------|
| cell   | 0 |
| vector | 1 | 
| matrix | 2 | 
| tensor | N | 

### Member Data Rules ✅

A  Storage Handle can contain any type that has a fixed, known size at compile time.
This would include:
- Scalar types (`int`, `float`, etc)
- Small vector types (`float4` etc)
- Structs
- Views to large data (`cell`, `vector`, `tensor`, `matrix`)

But it excludes:
- `storage`
- `functions` and `kernels`
- `def-record` and `def-rec-vec`




### Storage Handle Type Definitions ⚠️

Storage Handles are completely typed by 
- type of their element
- `address-space` (which is one of `:global` `:local` `:private` `:constant`)
- `align` (one of `:strided` or `:compact` or `:compact-offset`)  NOTE: `align` is not needed by the `cell` type.
- `contiguous-term` (one of `:first` or `:last`.  Defaults to `:last` if not provided)

The `tensor` type also requires the number of dimensions to be known at compile time.

Further, constant vecs (see below) also need their `length` to be fully typed.


But none of those are necessary to specify a storage handle type in a parameter list.
Therefore, there are several storage handle type functions available in CRISP,
 and they fall on a gradient, from loose to specific.   Many of the type functions here
 return incomplete types, which make them flexible. But any operation that accesses the
 actual data of the storage handle will, at minimum, require the element type to be specified.



#### Simplest - Element Type Only

For tensor, the arity is also required (at minimum).

```
(cell <element-type>)
(vector <element-type>)
(matrix <element-type>)
(tensor <element-type> NumDims)
```

Unlike the other Storage Handle types, the `tensor` type doesn't have an "only element type" type
specifier. Whenever the element-type is provided, the number of dimensions must also be provided.

Example: `(vector float)`
This example simply specifies that the value or parameter is a `vector` 
with a `float` element type. It does not specify any particular alignment, address space, or size.

Note that for the `cell` type, this is the minimum information needed to perform element access (`~`).


#### Using Keys
For the most flexibility, keys can be used.
```
;; for cell
(cell <element-type> &key address-space)

;; for vector and matrix
(XXXX <element-type> &key align address-space (contiguous-term :last))

;; for tensor
(tensor <element-type> NumDims &key align address-space (contiguous-term :last))
```



Example: `(vector long)`  This specifies that some vector of longs is writeable. 
It could be of any address space or alignment.

Example: `(tensor float 4)`  This specifies that we have a hypercube of floats, but nothing else is known about it. 



#### Element Type
The element type of a Storage Hnadle must be an element of a fixed size known at compile time.
It cannot be the type of a function. It cannot be a `def-record`.  Nor can it be a `storage` entity.


#### Usage

```
;; -- count --
(def-function count (v)
    (declare (return-type ulong) (type v (vector long :align :compact :address-space :global)))
 ...)

 ;; vectors can be compile-time fixed size
(vector float :align :compact :address-space :local :extent (100))
```

### Storage Handle Arguments for Kernels ✅ 
`def-kernel` is the definition for the kernel function. 
And any Storage Handle in its parameter list MUST have its element-type, number or dimensions, align, and address-space specified in
its type definition. Only the size can be unspecified. (And for `cell`, `align` is not needed.)
The number of dimensions is (obviously) implicit for the `cell`, `vector` and `matrix` types.


```
(def-type data-from-host-t (vector float :align :compact :address-space :global))
(def-type result-from-kernel-t (vector float :align :compact :address-space :global))

;; -- my_kernel --
(def-kernel my_kernel (in &out out)
  (declare #'(data-from-host-t &out result-from-kernel-t))
  ...)
```

### Creating Storage Handle Views ✅ 

Kernels cannot dynamically allocate memory. Crisp has four different ways
of working with and around this limitation:

- vector literals.  Small stack-based vectors that use registers ( `:private` addres space)
- reinterpret view. Re-use existing storage.
- `def-const-vec`. Read-only vector in the `:constant` address space. 
- Side Channels: "scratch" and "implicit" storage handle views.

These four approaches are quite different from one another, and each has advantages
and disadvantages. And some work well together (like declaring a vector literal or constant vec, and then reinterpreting it as a `cell` or `matrix`).

We'll discuss [vector literals](#vector-literals-val0-val1-val2--valn) and 
[reinterpret view](#reinterpret-storage---make-xxxx) in the next two sections, and
introduce [def-const-vec](#def-const-vec) and [Side Channels](#side-channel-storage-handles) later.




#### vector literals `#(val0 val1 val2 ... valN)` ✅ 

A `vector` can be literally declared using the Lisp `#(...)` syntax.

```
(let ((small-vec #(0 1 2 someVal otherVal)))      ;;<-- ideally, type should be inferred
  (declare (type small-vec (literal-vector short))) ;; so that this is not needed.
   ...)
```
A `vector` declared like this allocated using private register memory. It is highly recommended
that this is reserved for very small vectors (no more than 32 elements), else you could incur
a lot of register pressure.

The address space for these is `:private`. If you need it, the type function `(literal-vector T)` 
makes it easy to exactly declare the type for a vector literal.


#### reinterpret storage  . `make-XXXX` ✅ 

If you have a Storage Handle type, it can be reinterpreted to another type
using `make-` with the four Storage Handle types.

```
(make-cell <source> <new-element-type> &key offset)
(make-vector <source> <new-element-type> &key length offset)
(make-matrix <source> <new-element-type> width height &key offset strides)
(make-matrix <source> <new-element-type> width height &key (major :row) (offset 0))
(make-tensor <source> <new-element-type> <extents-list> &key offset strides)
```

A new `cell` obviously has `length=1`.  For a `vector`, if the `:length` key is not used, then the resulting 
new `vector` will have its size calculated automatically (byte size of the original storage / new element size, minus offset).
If the source byte size is not a multiple of the new element size, the result is truncated.
But the other types (`tensor` and `matrix`) need to have their extents provided.


For the 2D `matrix`, one of the declarations supports a `:major` key which can be `:row` or `:col`.
Alternately, the `:strides` key can set the strides. Setting the strides directly is how to get "row major" vs "col major" (versus "plane major" etc) tensor in higher dimensions. 

There are some restrictions. They are enforced at compile time:

- if the original and new element types don't match, then the source element type cannot be a struct type
- If the original and new element types don't match, the source Storage Handle must have a `:compact` or `:compact-offset` layout. Reinterpreting element types on `:strided` views is mathematically undefined and will trigger a compile-time error. 

The returned Storage Handle inherits the address-space from the source. It also inherits the alignmnet (`:compact`, `:compact-offset` or `:strided`), with one exception: if the `:strides` key is explicitly provided during the reinterpretation, the resulting handle is automatically typed as `:strided`.

The runtime will assert that the number of source bytes is sufficient for the new requirements, but this
assertion requires compiler flags (like `--runtime-checks`). 

`:compact` layout is generally more amenable to reinterpretation.

The `:contiguous-term` cannot be overridden by any interpretation operation. The compiler will set it appropriately


```
(def-type vec-floats-t (vector float :align :compact :address-space :local))
(def-type vec-ints-t (literal-vector int))

;; -- do_things --
(def-kernel do_things (hundred-floats)
  (declare (type hundred-floats (vecl-floats-t 100)))
  (let ((some-ints #(0 1 2 3 4 5)) ;; <-- compiler will attempt to infer typ
        (three-cell (make-cell some-ints int :offset 3))
        (ten-floats-view (make-vector hundred-floats float :length 10)))
    (declare (type some-ints vec-ints-t))
    ...))

```


### Reduce Boilerplate: `in-XXXX` and `out-XXXX` 📝

```
(in-cell T)
(out-cell T)
(in-vec T A)
(out-vec T A)
(in-mat T A)
(out-mat T A)
```

Storage Handler type declarations can be long, but for most kernel arguments there are 
 two common choices:  global readable Storage Handles for input paramters, and global writeable Storage Handles
for output parrameters.  Crisp has prepared pairs of `def-type` aliases to make this easier.
 Just specialize them with the element type and align and you are set.

Example:
```
(def-kernel my_kernel (A B &out C)
  (declare #'((in-vec float :compact) (in-vec float :compact) (out-vec float :compact)))
  ...)
```

Possible Implmenetionat
```
(<T A>   ;; <-- shorthand notation for with-template-type
  (def-type in-vec (vector T :align A :address-space :global))
  (def-type out-vec (vector T :align A :address-space :global)))
```


### soa-vector 📝

`soa-vector` is a special type of vector, with a special memory layout. They are used for vectors of structs (only).

`soa-vector` are templated over `S` where `S` is some struct type. But rather than a contiguous block of 
memmory consisting of repeating structs, `soa-vector`s are "Structs of Arrays". 

For example, using our `point` type from before, `(vector point :length 4)` would layout in memory
like this:
`|x0|y0|x1|y1|x2|y2|x3|y3|`.
Or in C++ we can think of it like this:
```
struct Point { float x, y; };
Point points[4];
```


But a `(soa-vector  point :lenth 4)` lays out like this:
`|x0|x1|x2|x3|y0|y1|y2|y3|`.
In C++ with can think of it like this:
```
struct Points {
    float x[4];
    float y[4];
};
```



#### Alignment & Layout 📝
Crisp supports three alignment schemes for `soa-vector`: `:compact`, `:compact-offset` and `:strided`.

`:compact` means the `soa-vector` is a primary allocation. The base pointer is 16-byte aligned. The internal arrays are perfectly contiguous and concatenated back-to-back. The compiler will only insert padding between the arrays if required to satisfy the natural alignment of the next element type.

`:compact-offset` would be a subview into a larger `:compact` view.

`:strided` means the `soa-vector` is a view or a slice. The internal arrays are no longer guaranteed to be perfectly contiguous, and accesses will rely on dynamic strides.

#### Base Properties 📝

A `soa-vector` has these properties:

| Property     | Type         | Description      |
|--------------|--------------|------------------|
| align        | align        | one of `:strided` or `:compact`. This dictates the layout of the inner vectors. |
| length       | ulong        | the number of elements in the `soa-vector`. Its bytes cannot be greater than its parent `storage` |
| parent       | storage      | address of"parent storage |
| offset       | ulong        | offset into parent. |

#### Struct Properties 📝

Additionally,  `soa-vector` also inherits the properties of their struct element type. 


Example
```
(def-struct point (x long) (y long))

(let ((sv      (make-soa-vector point :address-space :local :align :compact :length 20))
      (y       (y~ sv 9))
      (x-vec   (x~ sv)))
    ...)
```

##### `XXXX~` with index. 📝

In the example above, `y` is gotten via `(y~ sv 9)` which means it is the value of the y vector at index 9.

Owning to memory coalesence, when the index is a thread id from parallel threads,  this will be very high-performance access. 

##### `XXXX~` without index 📝

In contrast, `(x~ sv)` returns the ENTIRE VECTOR of X as a standard vector Storage Handle. The returned vector inherits the alignment of the `soa-vector`. If `sv` is `:compact`, `x-vec` will be `(vector long :compact :length 20)`, allowing for ultra-fast vectorized loads. If `sv` is `:strided`, the resulting vector will also be `:strided`. 

Its primary purpose is to pass a single, contiguous stream of data to another high-performance primitive, like `reduce-vec`

#### Element Access

The struct properties (see above) with index arguments are the primary way of accessing `soa-vector` data.
If you want a particular struct as singular construct, it can be gotten with `get-struct`.  Note that this requires
creation of a new structure to hold the value.
`(let ((some-point (get-struct sv 3))))`   

`soa-vector` does NOT support the `~` or `~ref~` element access functions like a regular `vector`.

#### Helper Functions

Like `vector`, `soa-vector`  supports `element-type` and `bytes` helpers.
`(bytes my-soa-vec)` returns the total memory footprint, which is the sum of the sizes of all its tightly-packed component arrays, plus any inter-array alignment padding required by the C ABI. Remember, the `soa-vector` is a view into some storage. Use `(byte-size~ (parent~ someSoaVec))` to get the full storage bytes.

#### Member Data Rules

`soa-vector` are ONLY defined over structs (see `def-struct` above). And any candidate struct type can only consist of either
 - Scalar types (`int`, `float`, etc)
 - Small vector types ( `float4` etc)

Unlike regular structs, they cannot include other structs or views.
This rule is in place to prevent overly complex nested SoA layouts and to ensure a simple, predictable memory model that maps efficiently to the hardware.

#### Defining 

```
(soa-vector element-type &key address-space align length)
```

#### Creating

`soa-vector` have parallel creation routines to `vector` and abide by the same requirements.

- `(make-soa-vector <source> <struct-type> length &optional offset)`



#### Converting between SoA and AoS vectors.

If you put yourself in a situation where you need to convert an AoS `vector` to an SoA `soa-vector`, 
or vice versa, then it might be time to reflect on the decisions in your life that have
brought you to this point. 
Fortunately, this is something that the GPU can do fairly well. Not optimized with perfect memory
coalescing, but well enough. Crisp provides routines that can help you out.

```
(convert-soa-to-aos input-soa-vector output-vector)
(convert-aos-to-soa input-vector output-soa-vector)
```

Possible Implementation
```
;; NOTE: convert-soa-to-aos should be implemented as a macro like convert-aos-to-soa below.
;; The will take the "temporary struct" creation out of runtime, making it marginally faster.
(with-template-type (T)

    ;; -- convert-soa-to-aos --
    (def-function convert-soa-to-aos (input-soa-vector output-vector)
        (declare #((soa-vector T) (vector T) => nil))
        (loop-soa-stride input-soa-vector (i)
            (let ((temp-struct (get-struct input-soa-vector i)))
                (set! (~ output-vector i) temp-struct)))))

;; -- convert-aos-to-soa --
(defmacro convert-aos-to-soa (input-vector output-soa-vector)
    (c-t-assert (type-equal (element-type~ input-vector) (element-type~ output-soa-vector)))
    (let ((T (element-type~ input-vector))
          (set-forms (with-struct-accessors T (aos-accF soa-accF)
                       ;; body generates one form for each member
                       ;; "i" and "temp-struct" TBD below.
                       `(set! (,soa-accF ,output-soa-vector i (,aos-accF temp-struct))))))
        `(def-function convert-aos-to-soa (input-vector output-soa-vector)
            (declare #((vector ,T) (soa-vector ,T)))
            (loop-vector-stride ,input-vector (i)
                (let ((temp-struct (~ ,input-vector i)))
                    ;; expand the forms we gathered
                    ,@set-forms)))))
```



#### C++ / Python interop

The hoisting code that the compiler generates includes helper functions that give the same property-to-vector and property-index-to-element 
access that Crisp enjoys, making it easy to initialize or inspect data and interoperate with Crisp kernels.




### def-const 📝

`def-const` is used to define an immutable expression in global file scope that the compiler will inject in place whereever it encounters it. The Lisp practice is that `def-const` expressions have a `+` sign on either side.

In CRISP `def-const` can only be used for scalar values. It cannot be used for constant vectors (see `def-const-vec` in the next section). 
Due to inference, `def-const` expressions do not typically need type information declared, it is optional.

```
(def-const +PI+ 3.141592654)       ; type will be inferred
;OR
(def-const +PI+ 3.141592654 float) ; type is explicit
;OR
(def-const +PI+ 3.141592654)
(declare (type +PI+ float))        ; type is explicit

;; -- circle-area --
(def-function circle-area (r)
   (declare #'(float => float))
  (* r r +PI+))
```

### def-parameter 📝

`def-parameter` is used to define the type and possible default value for parameters that might 
come in from the compiler when it is invoked.   `def-parameter` is very similar to `def-const` in
that it also defines an immutable expression in global file scope.
`(def-parameter <parameter-name> &optional <default-value> <type>)`

Like in C++, the `-D` flag is used to specify a parameter and is followed by the parameter name, equal sign and a value without spaces.
e.g. `-DMAX_INDEX=40` 

Paramter names should follow the C standard identifying rules. (ie use underscores, not dashes)

**NOTE:** Parameter names, like kernel names, are _case sensitive_, unlike other names in Crisp.


```
;; in the .crisp file
(def-parameter MAX_INDEX 100 ulong) ;; 100 is default value, used when not provided by the compiler invocation.

(def-parameter START_LOC 41.1)
(declaim (type START_LOC float))



# the compiler invocation
crisp.exe -DMAX_INDEX=35  my_kernels.crisp
```

<!-- NOTE: def-const supports type inference, should def-parameter.  Why not?
    
    NOTE: what about + on both sides?  Plus sign can be interpreted differently by shells, so best to avoid it 
          appearing on any command line.  We could auto add it?  (def-parameter +X+ ..)  / crisp -DX=4
          Meh, seems brittle and weird. 
-->



### def-const-vec 📝

Memory in the constant address space is read only and it must be 
initialized BEFORE the kernel that wishes to use it is called. 
The host can obviously set that up and pass it as an argument to 
the kernel. Or a .crisp file can declare and initialize them on its 
own and the compiler will take care of it. 

The `def-const-vec` takes two arguments: 
- a name for the vector 
- a progn which returns the initialized vector.  Think of it as just a function that does not accept arguments.

`def-const-vec` may return only one value. It cannot return multiple const-vecs.

`def-const-vec` will usually not require a `declare` with a type signature.  The compiler should be able to
infer it in nearly all cases. 

If you want the vector to be responsive to some other calculations, have the host initialize it and pass it to the kernel as a regular argument instead.

#### Declare Use In Kernels
If anything wants to read from that vec during the execution of some kernel,
that kernel needs to add a `(use <const-vec-name>)` to its `declare` directive. 
Then it, or functions it calls, can simply refer to the const-vec, like one would a global variable.  

#### Works with SoA
Returning a `soa-vector` from `def-const-vec` is fully supported. 

#### make-vector / make-soa-vector
```
(make-vector vectorType size)
(make-soa-vector soaVectorType size)
```
In the context of `def-const-vec` there are two additional overrides available. `make-vector`
and `make-soa-vector`.  Both take the appropriate vector type, which allows you to define
element type, layout, etc and a size. 


#### Constant Vec Using Other Constant Vec

When preparing masks, sometimes the construction of one mask depends on another. So long
as all this is predeterminable at compile time, CRISP can support it.

The `(declare (use +xxx+))` declaration can be put inside a `def-const-vec` to allow it to 
refer to an earlier `def-const-vec` .  The requirement is that the named const vec in the `use`
clause MUST have been defined earlier in the translation unit. 

#### Type Function
CRISP also has two type functions for `:constant` vectors returned by `const-vec`
`(const-vec <element-type> <align> &optional length)` 
and
`(const-soa-vec <element-type> <align> &optional length)`


```
(def-type image-mask-t (const-vec uchar :compact))
(def-const-vec +image-mask-32+ 
  (let ((image-mask-vec (make-vector image-mask-t 32)))
    (dotimes (x 32)
      (set! (~ image-mask-vec x) x))
    (return image-mask-vec)))

(def-const-vec +image-mask-8+
  (declare (use +image-mask-32+))
  (let ((small-image-mask-vec (make-vector image-mask-t 8))
        (small-view  (make-vector small-image-mask-vec 2))
        (big-view    (make-vector +image-mask-32+ 2)))
    (dotimes (x 4)
      (copy-vec :from big-view :to small-view)
      (inc! (offset~ small-view) 2)
      (inc! (offset~ big-view) 8))
    (return small-image-mask-vec)))

;; -- my_image_kernel --
(def-kernel my_image_kernel ()
  (declare (use +image-mask-8+))
  ;; this kernel and the functions it calls can 
  ;; refer directly to +image-mask-8+
  ;; Better, the kernel can pass it as an argument
  ;; to those other functions.  
  (do-something-magical +image-mask-8+))

  ;; note that my_image_kernel did NOT declare that it used +image-mask-32+. 
  ;; Normally, that would mean that vec would not be prepared when the kernel is loaded
  ;; but due to the 'use' from +image-mask-8+ it will be.  So the code from BOTH def-const-vec 
  ;; will execute before my_image_kernel is loaded.
  ;; But, loaded or not, my_image_kernel cannot access +image-mask-32+ because it did
  ;; not declare use for it. 

```

#### reinterpet for other Storage Handle types

`def-constant-vec` sets up vectors or soa vectors only. If you need some other Storage Handle type
(like `matrix`) then the appropriate `make-XXXX` function to reinterpreset it.


### Side Channel Storage Handles ✅

As was mentioned earlier, Crisp supports side channel Storage Handles, which are special purpose memory objects that
can be created in the operation of your kernel. This lets you "pretend" that the kernel is allocating 
memory, when it is actually just specifying a need for memory for some purpose and that need is expressed
to the host in the example hoisting code or metadata that the compiler outputs.

The different declarations each operate similarly. Each one results in an additional implicit argument being added to the kernel (or an additional matching "marshall" declaration appearing in a `def-kernel-exact`), plus an additionl set
of arguments (pointer, size, strides, etc) output into the hoisting code, complete with a recommended expression for calculating 
the correct allocation size.  

Each invocation must be countable by the compiler. This means they cannot appear in loops. 

The invocations take a type expression as their first argument.  If an existing Storage Handle VALUE is
used as the type expression, then the size will be set to be the same. This can be very handy, because if that value originates as 
a kernel argument, then the example hoisting code will specify that the size should match. 

The size of any invocation MUST be specified. It does not have to be a compile-time constant, merely specified. 
Note that there are several keyword symbols that can be used for the most common cases. 

The invocations also support a  `:name` and `:msg` keys. If using `def-kernel-exact` then `:name` is REQUIRED, 
as it will need to match a marshalling invocation.  The `:msg` key will output a comment into the hoisting code (Neat!),
which allows you to state its intended size and purpose.



#### make-scratch-XXXX ✅
```
;; cells
(make-scratch-cell element-type  &key address-space  name msg)
(make-scratch-cell cell-type  &key address-space  name msg)

;; vectors
(make-scratch-vector element-type sizeExpression &key address-space align name msg)
(make-scratch-vector vector-type sizeExpression &key address-space align name msg)

;; soa-vectors
(make-scratch-soa-vector struct-type sizeExpression &key address-space align name msg)
(make-scratch-soa-vector soa-vector-type sizeExpression &key address-space align name msg)

;; matrices
(make-scratch-matrix element-type sizeExpression &key strides address-space align name msg)
(make-scratch-matrix element-type sizeExpression &key (major :row) address-space align name msg)
(make-scratch-matrix matrix-type sizeExpression &key address-space align name msg)

;; tensors
(make-scratch-tensor element-type sizeExpression  &key strides address-space align name msg)
(make-scratch-tensor tensor-type sizeExpression &key address-space align name msg)
```

The `make-scratch-XXXX` routines create "scratch" side-channel memory Storage Handles. 

Scratch memory defaults to `:local` address space, `:compact` alignment, and `:last` contiguous term,
but the defaults can be overridden by either using the `&key` arguments to the `make-scratch-XXXX` function
or by using the second creation function of the pair that uses a Storage Handle type argument.


##### `sizeExpression` ✅

The `sizeExpression` is the magic that makes these things tick.  The most useful choices
for `sizeExpression` are the following keyword symbols that Crisp supports:

- `:match-workgroup-size`  (1 per thread in group) the scratch memory allocated will match the workgroup size (ie `wg-size * sizeof(T)` where `T` is the element type)
- `:match-num-workgroups`  (1 per group in the grid).
- `:match-total-threads`  (1 per thread total)
- `:match-warp-size`  (1 per lane in warp)
- `:match-warp-tile`  (1 per warp-size squared)
- `:match-num-warps-per-workgroup` 
- `:match-total-warps`  (global_size / warp-size)


The above `sizeExpression` choices will automatically set the `:msg` that is sent back to the hoisting code.

Alternately, the `sizeExpression` can be a compile-time known value, in which case the hoisting code will be configured with that,
or it can be any runtime value or some other Storage Handle variable.  In these cases, this will be noted in the hoisting comment,
but that may lack clarity. It is best ot use the `:msg` key as well.

##### `sizeExpression` for matrices and tensors

`:match-workgroup-size` and  `:match-grid-size` (and `:match-warp-tile`) all work well when the arity of the `local_work_size`/`global_work_size` matches
the arity of the Storage Handle view.  If it is expected that they won't match, use a scratch `vector` and reinterpret it for your needs.

Alternately, the `sizeExpression` can be a list in `(... z y x)` order. 


##### type expression argument

Usually this argument is a Storage Handle type, but an existing Storage Handle variable can be used as well, which 
can make things simpler.

##### scratch types
<!-- NOTE not sure about this -->
These type expressions are available:
```
(scratch-cell-type T &optional address-space)
(scratch-vec-type T &optional address-space)
(scratch-matrix-type T &optional address-space)
(scratch-tensor-type T &optional address-space)
```


##### Example 
Below is  a simple example
```
;; -- calc_something --
(def-kernel calc_something (A Res)
  (declare #(float-vec ulong-vec => nil))
  (let ((intermediate (make-scratch-vector A (/ (length~ A) 2) :msg "half of size of A parameter"))
        (otherIntermed (make-scratch-vector float :match-workgroup-size)))
     ...))
```

And this is an excerpt of the hoisting code that might be generated.  
```
 unsigned long intermediateScratchLen =   ; //      (/ (length~ A) 2)    half of size of A parameter 
 unsigned long otherIntermedScratchLen = local_work_size * sizeof(float);
 clSetKernelArg(calcSomethingKernel, 1, sizeof(void*), APtr);
 clSetKernelArg(calcSomethingKernel, 2, sizeof(unsigned long), &APtrLen);
 clSetKernelArg(calcSomethingKernel, 3, sizeof(void*), ResPtr);
 clSetKernelArg(calcSomethingKernel, 4, sizeof(unsigned long), &ResPtrLen);
 clSetKernelArg(calcSomethingKernel, 5, sizeof(void*), intermediateScratchPtr);
 clSetKernelArg(calcSomethingKernel, 6, sizeof(unsigned long), &intermediateScratchLen);
  clSetKernelArg(calcSomethingKernel, 7, sizeof(void*), otherIntermedScratchPtr);
 clSetKernelArg(calcSomethingKernel, 8, sizeof(unsigned long), &otherIntermedScratchLen);
 clEnqueeuNDRangeKernel( someCommandQueue, calcSomethingKernel,         
                          ...);
```
<!-- 
Implementation Notes

We'll need to modify the args up and down the call tree to get these "side channel" vars propogated.

Modifying the beginning of the arglist (of course).

-->

#### Scratch Helpers

Important: These helpers support a `:barrier` key for asynchronous execution.  See [Async Memory Operations](#async-memory-operations) for more information. 

```
(load-local global-tensor scratch-tensor &key identity barrier)
(store-global scratch-tensor global-tensor &key (transformF #'identityF) barrier)

(load-tile ...) 
(store-tile ...)

```

`load-local` and `store-global` simply copy data between a global tensor and a scratch one. There is no "positioning" of the tensors relative one another. These are most straightforward to use if the two arguments are the same size. But, in the event they are not the same size, the bytes moved are limited by the smaller of the two.  

`load-tile` and `store-tile`, on the other hand, have positioning arguments and that determine what section of the global tensor is copied to/from. See topology.md for details. 


In `:one-thread-per` strategies, a common practice is to divide some input vec
across workgroups and have each workgroup work on the vec using a local memory
copy of the workgroups segment. These two macros handle that and even include a 
`sync-workgroup`.

`load-local` has an optional `identity` arg. If the global work size is
greater than `global-vec`, then it may be necessary to fill in the matching portion
of the `scratch-vec` with something, and `identity` is that something.

There are also  `load-tile` and `store-tile` helpers to assist with
similar operations in 2D strided scenarios. They are described below with Matrices.
Lastly, `load-tile` and `store-tile` can be used with any tile size (so long as it is
not bigger than a single workgroup). From within  a `tile-stride` they don't require any
placement arguments, but they are perfectly usable without. See the section on [tile-stride](#general-purpose-tensor-stride-grid-stride--tile-stride-and-hardware-stride). 

Possible Implementation
```
(defmacro load-local (global-vec scratch-vec &optional (identity 0))
  (c-t-assert (type-equal (element-type~ global-vec) (element-type~ scratch-vec)) "type match!")
  (when identity (c-t-assert (type-equal (element-type~ global-vec) (type-of identity)) "identiy type"))
  `(let ((lid (get-local-linear-id))
         (gid (get-global-linear-id))
         (val (if (< gid (length~ ,global-vec)) (~ ,global-vec gid) ,identity)))
      (set! (~ ,scratch-vec lid) val)
      (sync-workgroup)))

(defmacro store-global (scratch-vec global-vec 
              &optional (transformF (get-identityF (element-type~ global-vec))))
  (c-t-assert (type-equal (element-type~ global-vec) (element-type~ scratch-vec)) "type match!")
  `(let ((lid (get-local-linear-id))
         (gid (get-global-linear-id)))
            ;; (wg-idx (get-workgroup-linear-id))) ;;<-- exists? 
      (when (< gid (length~ ,global-vec))
        (set! (~ ,global-vec gid) (funcall ,transformF (~ ,scratch-vec lid))))
      (sync-workgroup))

```



#### make-implicit-XXXX 📝

```
(make-implicit-cell <ID> cellType &key name msg)
(make-implicit-vector <ID> vectorType &key name msg)
(make-implicit-matrix <ID> matrixType &key name msg)
(make-implicit-tensor <ID> tensorType &key name msg)
```

Do you think the Crisp scratch memory or debug logging systems are cool, but you could do better?
Knock yourself out, deviant!  The `make-implicit-XXXX` allows you to Side Channel any Storage Handle for any 
purpose.  The `<vectorType>` et al must be complete, but it doesn't otherwise need to capture any particular
size requirement.

The `<ID>` are tracked. If the Crisp compiler sees two `make-implicit-XXXX` invocations with the same
`<ID>` for a given Storage Handle type, it will assume they are the same and only side channel enqueue one thing.

In the example below, this function, if called by a kernel, would cause two additional float array pointer to 
be hoisted, plus a pointer to a unsigned long array.  

```
(def-type float-vec (vector float :align :compact :address-space :global))
(def-type ulong-vec (vector ulong :align :compact :address-space :global))

;; -- calc-final-result --
(def-grid-function calc-final-result (x y &out A)
  (declare #( ulong unlong &out float-vec => nil))
  (let ((gamma-1 (make-implicit-vector :gamma-1 float-vec :msg "Gamma Squad should provide these"))
        (gamma-2 (make-implicit-vector :gamma-2 float-vec))
        (haversine-3 (make-implicit-vector :haversine ulong-vec  :name "haversine")))
      ...))
```

<!-- 
OUTDATED AND REMOVED
SEE topology.md for latest API.


### Async Memory Operations 📝

Crisp supports hardware-accelerated asynchronous memory copies (DMA). These operations allow the GPU
to fetch data in the background while the Execution Units (EUs) continue processing other instructions.

These operations are non-blocking. They return a `request-token`. You MUST eventually wait on this
token using `await-request` before accessing the destination memory.

#### `load-local` with `:barrier`
`(load-local global-vec local-vec &key identity barrier)`

Initiates an asynchronous copy from global memory to local memory.

IMPORTANT: accessing `global-vec` or `local-vec` before the request completes will result in BAD THINGS.  
In C++ lingo this is called "Undefined Behavior". In other languages it is referred to as "C++-like behavior".

The `check-async-hazards` static analysis can be elected to have the compiler check for you.


#### `await-request`
`(await-request token | list-of-tokens)`

Blocks execution until the specified memory request(s) are complete. This compiles to a hardware-specific
wait instruction (e.g., `wait_group_events` or `cp.async.wait_group`).

#### Safety
If you enable `(declare (check-async-hazards))`, the compiler will track the status of your local
memory buffers. It will emit an error if you attempt to read from `local-vec` between the `request-`
and the `await-`.


#### `request-store-global` 
```
(request-store-global local-scratch-vec global-vec) => request-token
```

Storage back to global memory does NOT yet have wide architecture support.  Crisp has these routines, but be aware that
the hardware choices that actually support this are limited. Your kernel may fail to compile or execute correctly on non-supporting hardware.

#### Tile Support : `request-load-tile-coords` / `request-store-tile-coords` ✅

```
(request-load-tile-coords source-tensor dest-tile (... tensor-row-y tensor-col-x) &key (identity 0) transpose) => request token

(request-store-tile-coords source-tile dest-tensor  (... tensor-row-y tensor-col-x) &key transpose) => request token
```
There are async variants for the tile scratch helpers as well.

-->


### Tensors & Matrices ✅

Tensors were introduced earlier in the [Storage Handle Types](#storage-handle-types) section.
That section covers how to declare a `tensor` or `matrix`, how to access elements, using scratch memory and more.

In this section we want to cover a few more details about tensors and matrices. 

In Crisp a `vector` is always a one dimensional contiguous blocks of memory.  
Tensors are represented by  `tensor` which is similar to a `vector` except 
that it has adjustable strides.

Tensors can have their exact size determined at runtime, but the number of their dimensions (eg. 2D matrix versus 4D hypercube )
must be known at compile time.

In Crisp, a 1D `tensor` can be used nearly anywhere a `vector` can be used.




In the example below, let's look at a 3x4 matrix `A`, with elements labeled 
`A[row][column]` (C++ notation) or `(~ A row column)` (Crisp notation)

<details>
<summary>C++ notation</summary>
<pre>
```
         Col 0     Col 1     Col 2     Col 3
       +---------+---------+---------+---------+
Row 0  | A[0][0] | A[0][1] | A[0][2] | A[0][3] |
       +---------+---------+---------+---------+
Row 1  | A[1][0] | A[1][1] | A[1][2] | A[1][3] |
       +---------+---------+---------+---------+
Row 2  | A[2][0] | A[2][1] | A[2][2] | A[2][3] |
       +---------+---------+---------+---------+
```
</pre>
</details>

<details open>
<summary>Crisp notation</summary>
<pre>
```
        Col 0       Col 1       Col 2       Col 3
       +-----------+-----------+-----------+-----------+
Row 0  | (~ A 0 0) | (~ A 0 1) | (~ A 0 2) | (~ A 0 3) |
       +-----------+-----------+-----------+-----------+
Row 1  | (~ A 1 0) | (~ A 1 1) | (~ A 1 2) | (~ A 1 3) |
       +-----------+-----------+-----------+-----------+
Row 2  | (~ A 2 0) | (~ A 2 1) | (~ A 2 2) | (~ A 2 3) |
       +-----------+-----------+-----------+-----------+
```
</pre>
</details>

Next, here is two different ways this matrix could be created.
In both methods, the coordinates above are exactly the same.
```
;; Create a row-major view of a 3x4 matrix
(make-matrix my-data-vec int 3 4 :strides #(4 1) )

;; Create a column-major view of a 3x4 matrix
(make-matrix my-data-vec int 3 4 :strides #(1 3) )
```

But, when laid out linearly, these two tensors are not the same. 
The first four entries of the data vector behind the row-major
matrix would contain the four elements of `Row 0`. 
But, for the col-major matrix, the first four elements of the data 
vector would contain the three elements of `Col 0`, plus the first 
element of `Col 1`.

Due to memory coalescing, multiplying a row-major matrix by a col-major matrix is
the MOST PERFORMANT choice. 

Lastly, the variants of these declarations that support `strideVec` should be used carefully. It's 
generally far simpler to use one of the other versions and let Crisp set up the stride vector for you.





#### Overloading Element Access ✅

It is uwise to overload `~` for all tensors. Use `def-derived-type` when overloading.

```
;; source vector is floats ranged 0-1
(def-derived-type normalized-tv (vector float))

;; we return int values between 0-100
;;; ~
(def-function ~ (tv index)
  (declare #(normalized-tv ulong => int))
  (round (* (~ tv index) 100)))

;; and store those ints back to floats
;;; ~  (setter)
(def-setter ~ ((tv index) val)
  (declare #(normalized-tv ulong int => nil))
  (set! (~ tv index) (/ val 100.0)))

```


#### Mutable Strides ✅

A `tensor` with `:align :strided` has mutable strides. If `:align` is `:compact` or `:compact-offset` then they are not mutable.  Stride mutation is normally done (safely and correctly) by functions like `transpose` but 
despite the horrible problems that might occur if done incorrect, we are making it available to you.

```
(set! (strides~ someTensorView) someOtherVec) ; will error if (length~ someOtherVec) is not equal to (num-dims someTensorView)
(set! (~ (strides~ someTensorView) 1) 8)
```

<!-- 

NOTE: removing 'identity-tensor' for now.

#### identity-tensor

This is a specialization of the tensor, but is not a true tensor in that does NOT require
any vector data.  It is immutable. It is a Kronecker delta tensor. Every component is 0, except those
where all the indeces are equal, which are 1.

```
(identity-tensor-type &optional rank)
(make-identity-tensor rank)
(is-identity-tensor? someTensorView) ;; can be called on any tensor
```

-->

### Matrices ✅

`(def-type matrix (tensor T 2))`

Matrices are simply 2D tensor views. The type alias `matrix` is defined to make coding easier, but any 2D `tensor` can automatically be considered a matrix. It is not a "derived" type.


Additionally, there are special functions specifically for matrices.

#### col ✅

`(col x:ulong A:matrix) => 1D tensor`

Given an index `x` and a 2D `tensor` matrix `A`   this returns a 1D `tensor` of that column of the matrix.

Note that the `tensor` (aka `vector`) that is returned will have `:align :strided`, regardless of the original `:align` of the matrix. 

#### row ✅

`(row y:ulong A:matrix) => 1D tensor` 

Given an index `y` and a 2D `tensor` matrix `A`   this returns a 1D `tensor` of that row of the matrix.

Note that the `tensor` (aka `vector`) that is returned will have `:align :strided`, regardless of the original `:align` of the matrix. 

#### num-cols / num-rows ✅

`(num-cols A:matrix) => ulong`
`(num-rows A:matrix) => ulong`

These utility functions return the number of columns or rows of the matrix.

#### get-layout ✅
```
(get-layout M:matrix) => :row-major or :col-major or :other-layout
```

`get-layout` analyses the strides of some 2D matrix and returns a value from the
`matrix-layout` enumeration. This can be `:row-major`, `:col-major` or `:other-layout`

#### transpose ✅

```
(transpose M) ; returns a new tensor, leaving M alone.
(transpose! M) ; M is transposed, strides updated in place
```

The `transpose` operations swap the logical "shape" of the matrix. For example, starting with a 3x4 matrix
and ending with a 4x3 matrix. This is done simply by updating the strides. It is instant and zero cost.

Note that the while data is not moved it does mean that a "row major" matrix will now be "col major", and vice versa.

The matrix returned by `transpose` will always be `:align :strided` , regardless of the original matrix argument `:align`.

##### transpose! notes ✅

`transpose!` mutates the matrix in place. This can only work for matrices that are `:align :strided`. 
Attempting to call `transpose!` on a matrix with any other `:align` is a compiliation error.

AlsoNote also, that due to the way Storage Handles wrap data, that `transpose!` will only effect the matrix in the scope of the function that is making the call (and any children it passes the matrix to after). 
It does NOT change the transposition of the matrix by the caller. 

> Implementation Note: consider dropping transpose!

##### understanding transposition
Here is a quick example with a 2x3 matrix:
```
        Col 0   Col 1   Col 2
       +-------+-------+-------+
Row 0  |   1   |   2   |   3   |
       +-------+-------+-------+
Row 1  |   4   |   5   |   6   |
       +-------+-------+-------+

Transposed:
        Col 0   Col 1
       +-------+-------+
Row 0  |   1   |   4   |
       +-------+-------+
Row 1  |   2   |   5   |
       +-------+-------+
Row 2  |   3   |   6   |
       +-------+-------+
```

Remember, NO DATA IS MOVED.

Possible Implemenation
```
;; -- transpose! --
(def-function transpose! (M)
  (declare #((matrix) => nil))

  (let ((dims-vec (dims~ M))
        (strides-vec (strides~ M)))
        (temp-dim0 (~ dims-vec 0))
        (temp-stride0 (~ strides-vec 0))
    ;; Swap the dimensions: (num_rows, num_cols) -> (num_cols, num_rows)
    (set! (~ dims-vec 0) (~ dims-vec 1))
    (set! (~ dims-vec 1) temp-dim0)

    ;; Swap the strides: (row_stride, col_stride) -> (col_stride, row_stride)
    (set! (~ strides-vec 0) (~ strides-vec 1))
    (set! (~ strides-vec 1) temp-stride0)))

```

#### load-tile-coords / store-tile-coords ✅

```
(load-tile-coords source-tensor dest-tile (... tensor-row-y tensor-col-x) &key (identity 0) transpose)
(request-load-tile-coords source-tensor dest-tile (... tensor-row-y tensor-col-x) &key (identity 0) transpose) => request token

(store-tile-coords source-tile dest-tensor  (... tensor-row-y tensor-col-x) &key transformF transpose)
(request-store-tile-coords source-tile dest-tensor  (... tensor-row-y tensor-col-x) &key transpose) => request token
```
When working with matrices, we often want coalesced memory access, but that is limited
to the `:row-major` / `:col-major` choice.  For this reason, a very common
usage pattern when working with matrices is to use local memory tiles.
These are typically `32x32` (ie `(get-warp-size)` squared ).

If using the `tile-stride` macro, then stride aware `load-tile` and `store-tile` helpers
are availalable in the body of the `tile-stride` (along with async variants). See [load-tile / store-tile](#load-tile--store-tile) for a full discussion.

Outside that macro, tile loading and storing is available, but coordinates are needed. 
`load-tile-coords` and `store-tile-coords` can be used.  

The `:identity` key can be used when the source tensor
is not evenly divisible by the tile size.  In that case, the tile will be correctly loaded with
data from the tensor where possible, but the REMAINING values of the tile will be loaded with the `:identity` value (which defaults to 0)

The tile will simply lift the data right out of the problem space tensor, 
whether it is `:col-major` or `:row-major`, and so have the same layout, just smaller.  
But the `:transpose` argument can be used to change that. For tensors of arity 1 (vectors), the `:transpose` is ignored. For arity 2 (matrices) then if `:transpose true` then
the `x` and `y` coordinates will be swapped. For tensors with an arity of three or greater, the `:transpose` keyword accepts a permutation list (such as `'(0 2 1)`) to explicitly dictate how the axes are reordered when mapping to local memory. Providing a simple boolean `true` serves as a convenient shorthand for this list, defaulting to swapping only the two innermost dimensions while preserving the outer batch structure.


Remember dest-tile should be `:local` memory.




#### convert-layout 📝

```
(convert-layout source-M dest-M choice) ; conversion is loaded into dest-M, leaving source-M alone

```
Crisp provides a layout conversion routine which can be used to convert a matrix into a specific layout choice.
If you are having to do this a lot, then some suboptimal decisions might have been made and should
be revisited. But, we live in the real world where we often have to deal with things as they are, and 
not necessarily like we want them to be.  

```
;; this routine assumes a 2D global_work_size

;; helpers (not fully defined yet)
;; (make-tile-scratch-vector T)
;; (make-tile dim T)

(def-const TILE_DIM:ulong (get-warp-size))

;; -- convert-layout --
;; THIS IS OUTDATED. REWRITE ONCE tile-stride, load-tile, workgroup-stride and store-tile are 
;; working.
(def-function convert-layout (source-M dest-M choice &optional (scratch (make-scratch-matrix (element-type~ source-M) :match-warp-tile)))
  ;; scratch is usuallly 32x32 (TILE_DIM x TILE_DIM)
  (declare #(matrix matrix matrix-layout &optional (vector (element-type~ source-M)) => nil)
            (global-size :strategy :strided))
  (c-t-assert (!= choice :other-layout) "dude")
  (r-t-assert-0 (!= choice :other-layout) "??")

  (unless (= (get-layout source-M) choice)
    (let ((temp-tile scratch))

      ;; This loop makes each workgroup process multiple tiles.
      (tile-stride M '(TILE_DIM TILE_DIM) (tile-idx-y tile-idx-x) 

        ;; load tile  - coalesced read
        (load-tile M temp-tile tile-idx-y tile-idx-x :transpose (= (get-layout M) :col-major))
        
        (sync-workgroup)

        ;; store transposed tile coalesced write
        (store-tile temp-tile dest-M tile-idx-y tile-idx-x :transpose (= (get-layout dest-M) :row-major))))))
```



### Type Aliases and Type Constructors ✅

The type names for vectors and functions,  etc. can be rather long and ungainly. 
 `def-type` is provided to help shorten these and make them more usable.  

In it's simplest application, it just provides type aliasing.

```
(def-type T int)  ;
(def-type addTwoT  (type-signature-of #'addTwo))
(def-type addThreeT #'(long long long => long))
(def-type floatVecT (vector float :address-space :global))
```

A **Type Constructor** is a function that takes a type as an argument and returns a new, specialized type. In Crisp, you create these using the `with-template-type` form, which provides a clean and powerful way to define generic types. When you use `with-template-type` to define a new type (like a struct or a vector alias), the compiler automatically generates a corresponding `XXXX` function, which is your type constructor. You can then use this function to create concrete types, such as `(anotherGlobalVecT-type int)` which represents a global vector of integers, which can be used in your function declarations. This approach separates the definition of the generic type from its specific instantiation, making your code more readable and reusable.

```
(with-template-type (T)
  (def-type anotherGlobalVecT (vector T :address-space :global)))

;; -- count-ints --
(def-function count-ints (v)
    (declare #'((anotherGlobalVecT int) => ulong))
 ...)

```
<!--
NOTE FOR FUTURE DEVELOPMENT: `(def-type-function (T U V) ...)`  
In theory we might be able to allow the user to define their own type functions.
They would just have to return a type. Because it potentially might call actual functions
(either user defined or built-in) it would mean CRISP code would need to be exectuable by
the compiler. Which will probably happen, if we are being totally honest. So long as it
didn't directly invoke any GPU-only capaibilities (like the shuffle functions) it could work.
-->



### Derived Types ✅

`def-derived-type`, `make-XXXX`, `as-XXXX`, `is-XXXX?`

`def-derived-type` defines a NEW type derived from a stated type. The purpose for this is to allow custom overload of functions and properties. Additionally, with `set-derived` the compiler can be instructed to create a type hierarchy between two types.

#### def-derived-type ✅

```lisp
(def-enumeration derived-subst :no :equal :descendant :ancestor)

(def-derived-type <new-name> <type-expr> &key subst)

```

The `type-expr` is any type that supports a `make-` function (`vector`, `soa-vector`, `tensor` and things created from `def-struct` and `def-record`). Additionally, `def-derived-type` can be used with scalars (like `int` and `float`). See below.

The `subst` key should be from the `derived-subst` enumeration:

- `:no`
A value of the derived type cannot be passed as an argument to a function that expects the original type. Nor can a value of the original type be passed to a function that expects the derived type.
- `:equal`
Values of either type can pass for each other.
- `:descendant`
A value of the derived type can be passed as an argument to a function that expects the original type. But the reverse it not true.
*Logic:* The derived type is a specific **Descendant** of the original. It inherits the structure of the original and can pass for it.
- `:ancestor`
A value of the original type can be passed as an argument to a function that expects the derived type. But the reverse is not true - compilation error.
*Logic:* The derived type is a broad **Ancestor** (or Supertype) of the original. The original type is implicitly promoted to this ancestor type.

It's very important to remember that no matter what the substitution behavior is set to, that Crisp will choose the closest overloaded function (and emit a compilation error if that cannot be clearly determined). So even if using `:equal`, if function `foo` takes a single argument and is overloaded for types `A` and `B`, `foo #'(A=>...)` will NEVER be called with a value of type `B` unless `as-A` were used.

`def-derived-type` is one of the `def-` constructs that CANNOT be wrapped by `with-template-type`.

#### Example

```
;; def-struct makes a new type 'point'
;; and we make a 'distance' function that takes points.
;; -- point --
(def-struct point
    (x float)
    (y float))

;; -- distance --
(def-function distance (a b)
    (declare #'(point point => float))
    #| pythagorean formula here |# )


;; a coordinate derived type is declared with 
;; a custom distance formula for it.
(def-derived-type coordinate point :subst :no)

;; -- distance --
(def-function distance (a b)
  (declare #'(coordinate coordinate => float))
  #| haversine formula here |# )

(let ((p1 (make-point :x 1 :y 2))
      (p2 (make-point :x 3 :y 4))
      (c1 (make-coordinate :x 1 :y 2))
      (c2 (make-coordinate :x 3 :y 4)))

  (distance p1 p2)  ; <-- evaluates to pythagorean distance between p1 and p2
  (distance c1 c2)  ; <-- evaluates to haversine distance between c1 and c2
  (distance p1 c2)) ; <-- compilation error, because :subst is :no

```

* In the example above if `:subst` were `:equal` it would also error, because the compiler wouldn't be able to successfully resolve which distance overload was desired.
* In the example above, if `:subst` were instead set to `:descendant` then `(distance p1 c2)` would accept `c2` as a `point` and would return the pythagorean distance.
* Or, if `:subst` were instead set to `:ancestor` then `(distance p1 c2)` would accept `p1` as a `coordinate` and return the haversine distance.

Crisp employs "multiple dispatch" for overloaded functions, determined at compile time. It does not support runtime dynamic dispatch of any sort.


#### Limitation: single pass semantics required

- The "original" type that the new type is deriving from MUST exist already. This is a requirement even when compiling multipass.  This prevents "type loops" or "type recursion", which are disallowed.
- enumerations can not be used as an "original" type.


#### make-XXXX ✅

The `make-` function is automatically generated for structural types (structs, vectors, records). It is NOT generated for scalar derived types (like those derived from `int` or `float`); use `as-<derived>` for those instead. `make-<derived-type-name>` accepts the same arguments as the original type (`make-<original-type>`).

#### as-XXXX ✅

When a derived type is declared, then two type casting functions are automatically created. `as-<original>` which can be used to cast a value of the derived type as if it is the original, and `as-<derived>` which can be used to cast an original as the derived.

```
;; continuing the example above, with two distance overloads and points p1, p2 and coordinates c1, c2

(distance (as-coordinate p1) (as-coordinate p2)) ; would return the haversine distance. Even if :subst was set to :no

(distance (as-point c1) (as-point c2)) ; returns pythagorean distance.

```

#### is-XXXX? ✅

When a derived type is defined, a matching type constraint function is also automatically defined. `is-<derived>?` evaluates to true if the type in question matches the new derived type.

Note that this does NOT accept substitutions, regardless of `:subst`. Use `is-substitutable-for?` for that.

```
(def-struct point ...) 
(def-derived-type coordinate point :subst :ancestor)

(is-point? point) => True
(is-point? coordinate) => False
(is-coordinate? point) => False
(is-coordinate? coordinate) => True

```


#### Derived Types and Arithmetic Operations ✅

`def-derived-type` can be used with numeric types. There are several use cases for this (like a custom float that is "meters" and is not interchangeable with other floats or perhaps not with "yards").

The substitution rules (`:no`, `:equal`, `:descendant`, `:ancestor`) determine the return type when mixing "original" and "derived" types in arithmetic operations. We describe this behavior using the biological concept of **Dominance** (as in genes which are "dominant" or "recessive").

- `:ancestor` is **Dominant**.
An arithmetic operation that mixes the original type and the derived `:ancestor` type returns the derived type. The derived type asserts itself over the original.
- `:descendant` is **Recessive**.
An arithmetic operation that mixes the original type and the derived `:descendant` type returns the original type. The derived type yields to the base "wild type."
- `:equal` is also **Recessive**, though because the types are interchangeable, this doesn't mean much.
- `:no` disallows mixing, so there is no valid return type.

```
(def-derived-type dominant-float float :subst :ancestor)
(def-derived-type recessive-float float :subst :descendant)

(def-function derived-type-demonstration (f d r)
  (declare #'(float dominant-float recessive-float => dominant-float float))
  ;; these two addition operations mix the original type (float)
  ;; with a derived type.
  ;; The first addition returns a 'dominant-float' because :ancestor is Dominant.
  ;; The second addition returns a simple 'float' because :descendant is Recessive.
  (return (+ f d)       
          (+ f r)))

```

But pay attention to how derived types behave when mixed with each other:

Different `:ancestor` (Dominant) types cannot be mixed with each other, even if they share a common base type.

```
(def-derived-type meters float :subst :ancestor)
(def-derived-type seconds float :subst :ancestor)

(+ meters seconds) ;; COMPILATION ERROR

```

Meanwhile, `:descendant` (Recessive) types will yield to the base type and CAN be mixed (because they both decay to the base type):

```
(def-derived-type weak-a float :subst :descendant)
(def-derived-type weak-b float :subst :descendant)

(+ weak-a weak-b) ;; evaluates to a float.

```

When mixing `:ancestor` (Dominant) and `:descendant` (Recessive) types that share a common base type, the **Dominant** type wins out.

```
(def-derived-type dominant-float float :subst :ancestor)
(def-derived-type recessive-float float :subst :descendant)

(+ dominant-float recessive-float) ;; evaluates to a dominant-float

```


#### set-derived ✅

`(set-derived ancestor-type descendant-type)`

`set-derived` instructs the compiler to create a formal type hierarchy between two previously defined struct types. Unlike `def-derived-type`, this does not create a new type; it links two existing types together.

The syntax requires the **Ancestor** type first, followed by the **Descendant** type.

- **Ancestor** : The "smaller" or contained type. A value of the Descendant type can pass for this type (it can be "sliced" or viewed as the Ancestor).
- **Descendant** : The "larger" or extension type.

This declaration automatically generates the `as-<ancestor>` and `as-<descendant>` casting functions, allowing explicit conversion between the two. Implicitly, the Descendant can usually be passed where the Ancestor is expected (equivalent to the `:descendant` substitution rule in `def-derived-type`).

##### Requirements & Validation

Since `set-derived` is inherently unsafe (mapping memory of one type to another), the compiler enforces strict rules:

- Order of Definition: Both `ancestor-type` and `descendant-type` must be fully defined and declared BEFORE `set-derived` is called.
- Structs Only: Both types must be structs. This mechanism does not support other types like records, scalars, or functions.  Note that types that are derived from structs (using `def-derived-type`) are also accepted.
- Size Safety: The size of the `ancestor-type` must be less than or equal to the size of the `descendant-type` ().
- No Loops: Type recursion (A derives from B, B derives from A) is detected and causes a compilation error.
- Shape Compatibility: The types must have compatible memory layouts (shapes) for the length of the Ancestor. For example, if the Ancestor is `[int, float]`, the Descendant must start with `[int, float, ...]`.  This requirement is of the "flattened" structs (see below). 
These member appearing in both Ancestor and Descendant don't have to have the same names, but
MUST have the strict same type. ( ie no swapping floats for ints or unsigned for signed)


As mentioned, the two structs must have compatible shape WHEN FLATTENED . This is most easily demonstrated with an example.  Below `set-derived` is used twice and both uses are perfectly valid.

```
(def-struct point (x int) (y int))
(def-struct vertex-flat (a int) (b int) (c int))
(def-struct vertex-nest (p point) (z int))

(set-derived point vertex-flat)
(set-derived point vertex-nest) ;; alternately, we could have done (set-derived vertex-flat vertex-nest)
```

Shape compatibility is evaluated on the flattened struct layouts: nested structs are recursively expanded to their scalar members. For each data member in the ancestor, the corresponding member in the descendant must have both the same type and the same byte offset . Struct-level trailing padding is not part of the comparison.


#### Branded Types ✅

Using `def-derived-type` and `:ancestor` it is possible to create two types (for example `meters` and `yards`) that are both essentially `float` and can interoperate with `float`s but cannot interoperate with one another. You can't accidentally add or multiply `meters` and `yards` 
because the type system disallows it. 

"Branded" types let us apply that same safety concept but to individual instances of structs or records. Let us imagine some sort of array struct type was defined. It could elect to have a branded index type, and then "index of A-arr" would be different than "index of B-arr" even though A-arr and B-arr were both the same type of array struct. 

Branded types support the `:subst` key just like `def-derived-type`.  This mean that how, exactly, these types can and cannot interoperate with each other and with other types is yours to decide.

##### brand ✅
```
(brand <new-name> <type-expr> &key subst (enforce :diff))
```

`brand` is nearly identical to `def-derived-type`. 

- `brand` is only usable inside the scope of a `def-struct` or `def-record`. It cannot be used elsewhere.
- `:subst` is a required key and cannot be omitted.
- like `def-derived-type` the `<new-name>` cannot collide with any existing type
  or derived type names (or type functions). BUT it CAN collide with other branded derived type names. This allows `index-t` to act as a generic type constructor. A function can accept `(index-t x)` and work on ANY struct that defines an `index-t` brand.
  The requirement here is that the same original type is used for each.
- `:enforce` is optional. It can be set to `:always` or `:diff`.  It defaults to `:diff` (see below)
- enumeration types cannot be branded
- `:c-t` (compile time) properties cannot use branded types
- unlike `def-derived-type`, no `make-XXXX` is defined for the new branded type when the original is a struct or record.

The new type that `brand` creates is a type function that accepts an argument of the type of the parent struct/record, and that returns the qualified "branded" type.

`:enforce :always` means the branded type is always generated and enforced.
`:enforce :diff` (the default) means the branded type is only generated when generating kernel derivatives (ie when using the `--differentiate` flag). Other times, it just falls back to the original type.  


```
(def-struct someStruct
  (brand index-t ulong :subst :equal :enforce :always)
  (length index-t)
  (cur-idx index-t)
  ...)

(def-function find-location (S match)
  (declare #'(someStruct something => (index-t S)))
  (let ((len (length~ S)))
  ...)
```

In the example above, we see that `index-t` is declared as a derived type inside `someStruct`. 
`someStruct` then proceeds to use that type for the declaration of two of its properties (`length` and `cur-idx`).  `find-location` declares its return type to be an "index-t of S" with the `(index- S)` form.  It binds `len` to `(length~ S)` which means `len` is also of type "index-t of S".


#### What's with all this derived and branded types? Who is this for?

If you come to Crisp from a CUDA, C++, or OpenCL background then much of this derived type stuff 
probably seems foreign and unusual to you. Crisp types are organized in a DAG, not a tree. The 
`meters` not adding with `yards` is cool, but maybe you've never needed it in the past.
And branded types aren't on the menu at any of your regular feeding establishments. 

It's a lot of rigaamarole and you probably don't ever intend to use it. Why did anyone even 
trouble to do this?

The short answer is AI workloads. AI workloads need differentiable kernels to fit and adjust training data. Crisp provides auto differentiation with the `--differentiate` flag, and to support
that Crisp needs branded types, which need derived types. And in the Lisp philosophy, 
if something is useful to the compiler, then it is likely useful to the language users. And thus
it has been exposed to all Crisp users. The author hope it serves at least one of you well.

<!--

I'm removing this section as Storage Handles are done with def-record, not def-struct
and can't be extended like this.

They CAN be extended by nesting them in a def-record. Will update.



#### Extending Views

If you want to extend a type like `vector` with your own type that has extra data members, you can use `def-struct` in conjunction with `set-derived` for this.

```
(def-struct MY-VEC 
    (base (vector int))
    (new-prop int))

;; MY-VEC is a descendant; it extends the vector and can pass as one.
(set-derived vector MY-VEC :subst :descendant)

```


-->



### Continuation Kernels 📝

A common practice in GPU kernel coding is begin with with one kernel, that perhaps uses a certain
distribution of local and global work sizes, and then to complete that calculation with second kernel, 
that is typically enqueued with a set of local and global work sizes tailored to it. 

This occurs because there is no way to marshall which workgroups execute in which order, and there are
no "global barriers" with which to enforce it. Atomics can be used as ersatz barriers, but overuse often leads to unused GPU cFapacity and stalled threads. The "last man standing" strategy (see `when-is-last-workgroup`)
is an example of working around these limitations. 

When an algorithm has clearly defined stages, and those stages might benefit from a separate enqueue, then 
Crisp has two choices: `def-orchestration` and "continuation kernels". 

`def-orchestration` is simple to use and lets you easily configure hoisting code for launching
kernels sequentially and moving data between them, or launching them isolated in parallel, or even
doing data interleaving with overlapping kernel-invocation/memory-copies. See the [Hoisting and def-orchestration](#hoisting-and-def-orchestration) section for more.

While `def-orchestration` provides a general framework for sequencing kernels, continuation kernels 
offer a unique advantage in specific scenarios: compile-time capture.  This superpower allows
 a macro using `let-kernel` to capture a function arg at compile time, which means
that BOTH kernel stages can use some same common worker function without having to "pass" that across the
host-device barrier. 

#### `let-kernel` 📝

`let-kernel` is a binding special form similar to `labels` in Common Lisp. It defines a new kernel
function.  You can invoke that kernel in the "last place" of some other kernel.  No operations should
be performed AFTER a continuation kernel is invoked. The compiler will warn you if you do.

`let-kernel` can be used anywhere a `let` binding could, but its primary and safest use is for 
defining a continuation kernel inside a `def-kernel`.  To ensure a clear execution model, the 
compiler requires that the declarative invocation of the continuation kernel must be the **final expression**
in its scope.  A warning will be issued if any code follows this invocation. 
This is typicallly done with `launch-kernel` (see below).

The launch-kernel directive used to specify the continuation is not executed by the initial kernel; it compiles to a NOP. Its purpose is purely declarative: it signals to the hoisting code generator which kernel to launch next.  
The hoisting code that the Crisp generates will demonstrate loading and enqueueing the first kernel,
waiting on it complete, and then enqueing the second one, typically sharing memory args between them.

If using `let-kernel` it is a good practice to `declare` the desired local and global work sizes so the
hoisting code will be optimal.


#### Variable Capture
It is important to note that `let-kernel` does not create a lexical closure. Any variables from the 
surrounding scope that are used inside the `let-kernel` body must have their values known at compile time. 
This allows the compiler to "bake in" or inline these values (such as a constant identity value or a known `#'someFunction`) directly into the new kernel's definition.

If a value is only known at runtime (for example, a variable passed as an argument to the outer kernel), 
it cannot be captured. Instead, it must be passed as an explicit argument to the continuation kernel itself.


##### `kernel-name` 📝

`(declare (kernel-name "some_name"))` 

The `let-kernel` binding will determine the name of the kernel that is generated. But if you need to
name it relative to some other function argument, `declare` a `kernel-name`.  

If this declaration is missing, the kernel will take the name of the binding itself. 

Regardless of the method, remember that kernel names have to obey C identifier naming rules.

##### `launch-kernel` 📝

`(launch-kenrnel (continue-later A C ) :copyback (A C))`

It is not possible to invoke any kernel function from any other. But `launch-kernel` CAN 
appear in your code with a kernel invocation.  It should appear as the **final expression**
of your kernel execution.

The compiler will simply NOP out the actual `launch-kernel` invocation from the calling kernel.
It does nothing and doesn't effect the compilation of the kernel in which it appears.

But the hoisting code that is generated WILL respect it, and will hoist that target invocation
after your own kernel.

It supports an optional `:copyback` key which can be used to list the arguments that should be 
copied back to the host when the continuation kernel is done. Only paramters to the continuation 
kernel itself OR the original kernel can be named in the copyback list. 

example
```
; define two kernels, one launches the other.
(def-kernel something-else (V) ...)

(def-kernel first-this (A B &out C))
   ... ;; do something
   (launch-kernel (something-else C)))
```

`launch-kernel` is also how "continuation kernel" invocations are specified
and realized. Additionally, it can appear in a `def-orchestration` context (see below).


#### Continuation Kernel Example

```
;; -- two_stage_operation --
(def-kernel two_stage_operation (A B C)
    (declare #(my-v-t my-v-t my-v-t => nil)
             (local-size :derive-from B :msg "two_stage_operation local work size should be the same as the length of B")
             (global-size :set-to (+ (length~ A) (length~ B) (length~ C)) :msg "two_stage_operation global work size
             should be big enough for all three vector arguments"))
    (let-kernel ((continue-later (a &out c)
                  (declare (kernel-name "last_stage_op")
                          #(my-v-t my-v-t => nil)
                          (local-size :derive-from A :msg "last_stage_op requires a local work size at least as long as A")
                          (global-size :derive-from C :msg  "be sure to set global workd size big enough to accomodate C"))
                    ;; perform operations in continuation kernel
                      ... ))
        ;; do operations for first stage
        ...
        ;; this isn't a real invocation.  It just demonstrates to the hoisting code
        ;; HOW this function expects the continuation kernel to be called
        (launch-kernel (continue-later A C) :copyback (B C))))
```



### First Order Functions ⚠️

- `def-function` defines a function
- `#'some-func-name` is how to refer to the function handle
- `#'(<arg-type> ... => <return-type> ...)` can be used to wrap the function type signature
- `(type-signature-of #'someFunction)` can get the type signature of a function
- `(return-type-of #'someFunction)` can get the return type of a function. 

<!--
QUESTION: `(return-type-of (type-signature-of #'someFunction))` supported?
ANSWER: I guess. 
-->
```
(def-type my-vec-t (vector int :address-space :local))

;; -- count-if --
(def-function count-if (v predicate?)
    (declare (return-type ulong) (type v my-vec-t) (type predicate? #'(int => bool)))
    ...)

;; -- count-if -- 
(def-function count-if (v pred?)
    (declare #'(my-vec-t #'(int => bool) => ulong))
    ...)
```



### No First Order Types 📝

Types are evaluable only at compile-time. There is no runtime
passing or evaluation of types supported. 

But keywords and enumeration values ARE first order. 



### Enumerations ✅

```
(def-enumeration address-space (:global 1) :local :private)

(vector int :address-space :global)
```

In the example above, `def-enumeration` defines a new type called `address-space`, which is just a set of keywords.
Unless enumerations have conflicting keys, all unconflicted keys are automatically promoted to the 
global default namespace. ( And we don't support namespaces ).

#### type constraints: is-XXXX? ✅

Using `def-enumeration` automatically generates `is-XXXX?` for that enumeration name, which can be used as a type constraint function
in `with-template-type`.  See the discussion of type constraints in `with-template-type` for more information.



### Maybe Type 📝

GPU Kernels do not support exceptions. Many operations that would be segfaults on a CPU 
(like reading past the bounds of allocated memory) are simply ignored by GPU kernels.  
These can make error handling challenging, negatively impacting both correctness and performance.
Crisp provides a "maybe" type which gives developers a simple way to define and handle error states. 
The maybe type automatically interoperates with the electable kernel logging mechanism, 
helping both correctness and debugability.

#### maybe and result 📝

`maybe` is a type expression that can wrap other types.  
`maybe` means that if it has no error, the function will return a value of that type.

The compiler handles the unwrapping of the `maybe` tuple for you, 
so the code that encounters the `maybe` remains clean. 
In reality, the function will return a tuple with :OK in the first position 
and the successful value(s) in the subsequent one(s). 
If there is an error, :Err will be in the first position no value.
But this is an implementation detail.

`result` is a special form that takes as its first argumment either
the keyword :OK or :Err.  When :OK, then the subsequent args match the type
of the maybe expression and are the return value(s).  
When :Err then you can pass a message string as second argument and that may appear
in the log if the side-channel logging has been elected. Otherwise it will
be compiled away. There is no performance penalty for any :Err message
or message handling if the side-channel logging is not active.


In the example below, we have a function divides numbers safely. 
It uses `maybe` in the type signature and `result` to return the 
result or error.

```
(with-template-type (T)

  ;; -- div-safe --
  (def-function div-safe (dividend divisor)
    (declare #'(T T => (maybe T)))
    (if (= divisor 0)
      (result :Err "division by zero")
     (result :OK (/ dividend divisor)))))
  
```

#### let-maybe 📝

`let-maybe` is a binding environment that makes working with `maybe` types much easier.  
```
; Example 1

;; -- math-1 --
(def-function math-1 (a b)
  (declare #(long long => long))
 (let-maybe ((m1 (div-safe 10 a))
             (m2 (div-safe 20 b)))
          (+ m1 m2)
    :Err
       0))

; Example 2

;; -- math-2 --
(def-function math-2 (a b)
  (declare #(long long => (maybe long)))
 (let-maybe ((m1 (div-safe 10 a))
             (m2 (div-safe 20 b)))
          (+ m1 m2)))
```
Examining the above, if neither `a` or `b` are 0, then the results of the two divisions are added together and the sum is the value returned by both functions.

In Example 1, if `a` is 0, then `div-safe` will return `(result :Err)`  and the `let-maybe` will then return the expression that follows `:Err` . 
But in Example 2, where there is no `:Err` clause,  the `let-maybe` would return the `result` it got from `div-safe`.
And, aligned with that, note the return type of `math-1` is `long` whereas in `math-2` it is `(maybe long)`.
In both Examples, we will NOT evaluate the second binding (assigning `m2` to `(div-safe 20 b)`). The `let-maybe` exits as soon as it encounters a `(result :Err)`

When using `let-maybe`, while you are on the "happy path" of the bindings and the main body of the progn your code can be assured that no error was encountered.


`let-maybe` has only one `:Err` escape for all of its bindings. If you need more, consider using `or-else` around an individual assignment. See below.

##### compare to `let`

Below we use `let` instead of `let-maybe`.  Note that this will NOT compile. This is because, unlike `let-maybe`, 
the regular `let` doesn't guard and unwrap the maybe values.
The `#'+` operator only accepts numbers, it does not accept `maybe` types, and thus the expression `(+ m1 m2)` fails.

Note that if we want to use `let`, we can by leveraging the `or-else` construct (see below) which safely
guard and unwrap a single `maybe` type. 


```
; this won't compile

;; -- math-3 --
(def-function math-3 (a b)
  (declare #(long long => (maybe long)))
 (let ((m1 (div-safe 10 a))
       (m2 (div-safe 20 b)))
    (+ m1 m2)))
```



#### a note about thread divergence

In the examples above (`div-safe, math1, math-2`) there are divergences being introduced into the flow of the kernel execution.

Remember that GPU kernel code is executed simultaneously by tens or even hundreds of threads sharing a single program counter. 
If any thread or group of threads needs to branch off onto a path that the others aren't taking, it results in a stall where some threads are 
simply waiting while the others finish that operation. 

Note first the explicit divergence in `div-safe`.   It  branches with `if` and then both branches return a `result`.  This
is a good example, because the branch is short and resolves again quickly.  Take care that when returning `maybe` values
that you don't introduce long branches, because if even one thread diverges, the entire warp stalls and waits.
Division by zero is not safe, so the use of `if` is mandatory. But consider using `select-if` in some cases. It
keeps threads synchronized (even though it fully calculates both consequent and alternate expressions). 


The second divergence is an implicit one. In both `math-1` and `math-2`, if a `(result :Err)` is encountered, then
that thread ceases executing the remainder of the function. It will wait until the other threads finish and then
they continue together. But note that while it is true that threads that encounter errors stall, they are NOT performing
extra work, nor are many different branches spider webbing away from the point of error. Instead the use of `maybe`
and `let-maybe` result in the minimal amount of stall and divergence. 



##### multiple return values

`maybe` and `result` support multiple return values. For example:  `(maybe int myVecType)`  `(result :OK someInt someVec)`


#### Guard: or-else 📝

`or-else` is a macro that takes a maybe and returns either 
its success value(s) or some other value(s) of the same type.

This is very useful for guaranteeing that even in the face of errors
that a function can consistently operate with SOMETHING and is not
forced to return 'maybe' simply because one of its sub-functions uses it.
 It does not prevent the `maybe` from being logged. 

```
;; -- some-math-ops --
(def-function some-math-ops (a b)
  (declare #'(float float => float))
  (let ((m (or-else (div-safe a b) 1))  ;<-- if there is an :Err, m will be '1'
        (n (+ a b)))
     (* m n)))
```


## `let` ✅
<!-- NOTE:  this section, and the one on set! and declare should probably appear MUCH earlier in the doc -->

`let` is the form for declaring variables in the scope of a function. 

`(let  (<VAR-DECLARATIONS>)  <PROGN>)    => (return-type-of <PROGN>)`

In Crisp `let` is like `let*` from Common Lisp. Variables are declared in order and build the
environment together.  

Unlike `let*` , Crisp `let` supports binding of multiple variables.  There is no
`multiple-variable-bind` form in Crisp, `let` is used instead.

The return value of the `let` expression is the return value(s) of the
last expression in its closure, in its implicit `progn`.

```
(let ((sum (+ a b))
      (diff  (- sum c))      ;; can refer to 'sum' since it was declared before.
      (fail  (+ someNum 9))  ;; this would fail, as someNum hasn't been declared yet.
      (someNum   0.2)        ;; is this a bfloat16, half, float or double? 
      (otherNum 0.1)    
      (quotient remainder (/ a b)))  ;; / returns multiple values, we can bind them all
  (declare (type someNum double) (type otherNum half))    ;; finally declare the type of someNum

  (dec! diff) ;; mutable
  (munch sum diff someNum otherNum remainder))  ;; <-- the return type of #'munch
                                                ;; is the return type of this `let`
```

## `set!` ✅

`set!` is the form for setting the value of a variable in the scope of a function. 
It does not return a value.

See [Appendix #1](#appendix-1---summary-set--get-vars-storage-handles-and-structs) for examples
of its use with various types of variables.

## `declare` ⚠️

`declare` can appear as the first line in the Crisp function forms 
( `def-function`, `def-grid-function`, `def-kernel`, `def-kernel-exact` )
as well as `let`. 

`declare` can also appear in the first position following a template declaration (`with-template-type` or `<T>` syntax)
When it appears in a template it is used for type declarations involving type constraints.


It is used to declare important information to the compiler, typically about the 
function itself or the new variable closure.  The following are the valid 
directives that can appear in `declare` when used in function or `let` bindings.
For template usage, see the subequent section.

| Name          | Example                     | Fun | Let | Description |
|---------------|-----------------------------|-----| ----|-------------|
| `type`        | `(type someVar int)`        | Yes | Yes | type of parameter or variable. See below for variadic example. |
| `return-type` | `(return-type long)`        | Yes | No  | return type of a function. see below for multiple return values |
| arrow form    | `#'(int int => float)`      | Yes | No  | declare the entire function signature in one expression |
| `type-signature-of` | `(type-signature-of #'addInts)` | Yes | No | reuse type signature of another function as own | 
| `use`         | `(use +image-mask+)`        | Yes | Yes | the context requires some constant storage vector / tensor |
| `inline`      | `(inline)`                  | Yes | No  | asks that the compiler inline this function. |
| `register`    | `(register <var0> <var1> ...)` | Yes | Yes | mark this var or parameter to be kept in register. Note that this cannot be guaranteed.|
| `global-size` | see [Hoisting](#hoisting-and-enqueing-a-kernel)| Yes | No | communicate kernel `global_size` requirements back to hoisting code |
| `local-size` | see [Hoisting](#hoisting-and-enqueing-a-kernel)| Yes | No | communicate kernel `workgroup_size` requirements back to hoisting code |
| `num-groups` | see [Hoisting](#hoisting-and-enqueing-a-kernel)| Yes | No | communicate kernel enqueue requirements back to hoisting code |
| `uniform`     | `(uniform someVar)`         | Yes | Yes | declares that some param or variable must be uniform across the workgroup.  Compiler will error if it is not. |
| `constexpr`   | `(constexpr someVar)`       | Yes | Yes | delares that some param or variable must be compile time calculable. Compiler will error if it is not |
| `to-uniform`  | `(to-uniform someVar)`      | No  | Yes | tells the compiler to MAKE the newly defined variable uniform across the entire workgroup. This is non-trivial. See [to-uniform](#to-uniform-) |
| `forward-only` | see [Auto-Differentiation](#auto-differentiation-ad)| Yes | No | tells the compiler that this function is forward-only and should not be differentiated. Will not be compiled when the `-differentiate` flag is used. |
| `max-registers` | `(max-registers 64)`        | Yes | No | An opt-in static analysis usually elected at the kernel level. Compiler will analyze the number of registers a kernel requires and emit a compiler error if it exceeds. |
|`warn-max-registers` | `(warn-max-registers 64)` | Yes | No | An opt-in static analysis usually elected at the kernel level. Compiler will analyze the number of registers a kernel requires and emit a compiler warning if it exceeds. It will also name which kernel args might be candidates for `no-sroa`  |
| `no-sroa` | `(no-sroa someVar)` |             | Yes | No | The variable named (typicall a Storage Handle) will not be automatically expanded into its SROA components at the kernel boundary, but is instead brought over as a single constant memory struct. This can lower register usage, but is only available for storage handles that do NOT use mutable strides or offsets. | 


<!--
The following are under consideration and have yet to be fully defined:

- inline
- not-inline
- (critical varName 100)  // how critical is this to NOT spill. 100== never 0== ok sure.
  the problem here is that unless we have FULL control these are promises that can't
  be kept.  just use 'register' in the interim. 

-->

<!--
This is a type function. It can be used in any position  a type could.  
So, yes, it can appear _IN_ a declare, but not as a top level directive.
 return-type-of | `(return-type-of #'addInts)` | Yes | No | T
 -->

#### `type` ✅
`(declare (type a b c double))`
`type` can be used to declare the type of parameters or variables. Note that it is
variadic and if multiple expressions are of the same type they can simply be listed with the
type itself being in the last position.

There are other ways of declaring variable types (arrows form, colon join). 

#### `return-type` ✅
`(declare (return-type int double))`

#### arrow form ✅

```
#'(int int => long)

#'(int => long double)

#'(int int &optional long &key :clamp float => long)

#'(in-vec &out out-vec)
```




### `declare` and templates 📝

#### `type-is` 📝
```
(<T>
  (declare (type-is T #'is-floating-point?))
  ...)
``` 
`type-is` can appear in the `declare` block at the beginning of a template. It lets you
leverage [type constraints](#type-constraints).

#### `value-is` 📝
```
(<T A>
  (declare (value-is A #'is-alignment?))
  ...)
```
Also for [type constraints](#type-constraints)


### Other `declare` directives

#### `use` 📝
`(declare (use +image-mask+))`
<!-- 
NOTE: should we constrain `use` to ONLY be in def-kernel or def-const-vec ?
  It'd make the compiler's job easier.
  Would it make the users code clearer?
  Having it be usable by any sub-function is actually pretty convenient. Being
  able to call an image convolution and not worry that it needs some luminosity mask
  at the kernel level is nice.  
-->
`use` can appear in funciton or `let` contexts, but it is mostly used with `def-kernel` or 
`def-const-vec`.  It simply declares that some context depends on a constant memory storage item.
See [def-const-vec](#def-const-vec)

#### kernel-name 📝
`(declare (kernel-name "some_name_${T}"))`
Used in `let-kernel` to name a continuation kernel.  See [Continuation Kernels](#continuation-kernels)

#### single-task 📝
`(declare (single-task))`

Communicates back to the hoisting code that this kernel should be run on only one thread. Used in `def-kernel`

#### entrypoint 📝
`(declare (entrypoint))`

For library writers. See the [entrypoint](#entrypoint-1) section

### For `defmacro` writers

#### grid-level / workgroup-level ✅
For use by `defmacro` when defining grid level operations.  See [Grid Level](#grid-level-operations)
Also, less common, [workgroup level operations](#workgroup-level-operations)

#### warp-convergent / workgroup-convergent. 📝
Tells the compiler this progn CANNOT be called in a divergent branch. See [the dedicated section](#declare-warp-convergent-and-declare-workgroup-convergent) on this topic.

### For Static Analysis 📝

There are a half dozen declare directives that can be declared to elect static analysis.
Rather than list them here, see the [section dedicated to this topic](#static-analysis)


## Control Flow ✅

Programming performant GPU kernels is often very different than programming performant CPU-bound code.
And Crisp's departure from other languages is significant in its approach to execution control flow.

GPUs are very fast and powerful when performing parallel operations. When working large workloads, the goal is to keep 
the full might of the GPU fully occupied running meaningful operations in parallel without stalling.  
This is no small challenge, because many routine C and Lisp constructs like `if/then` or even a simple `for` loop
can lead to bifurcations in the thread progress, which leads to idle threads which leads to poor performance.

The control flow affordances in Crisp revolve around maximizing parallelism, keeping thread workgroups and warps marching
in sync, and avoiding bifurcations. Additionally Crisp keeps the developer involved and informed of the choices and trade-offs
being made, rather than hiding them behind abstractions. 


### Single Task 📝

A single task kernel is a kernel that runs on exactly one thread. While it is simple to understand be warned that it is not
necessarily performant. If you have only one single task kernel running, the majority of your GPU power idles untapped. 
When scheduling a single task kernel, look for opportunities to run it while other work is being done.

`single-task` 
Put the symbol `single-task` into the `(declare ...)` of the kernel. When it sees this, the compiler will surround
the main body of the kernel with a check to ensure it is run by only one thread.  And the hoisting code that
is generated will set the global work size (thread count) to be 1.  

```
;; -- do_little --
(def-kernel do_little (#| some args |#)
  (declare single-task)
  #| some work |#
)
```

```
// example OpenCL hoisting code
 clEnqueeuNDRangeKernel( someCommandQueue, doLittleKernel, 
                          1 /* work_dim */,
                          0 /* global_work_offset */,
                          1 /* global_work_size -- just ONE thread */,
                          1 /* local_work_size */,
                          eventCount, waitList, &someEvent); 

```
<!-- NOTE: what might be a better "real" example for single-task? -->

### when-thread-is / abs-when-thread-is 📝

The `single-task` declaration above is a convenience, but it signals its limitation to the compiler
for the entire kernel. Oftentimes you will have kernels that are employing some parallel strategy 
(like Grid Stride, see below) but perhaps before embarking on that you might need a small bit of
initialization done by just one thread before or after the big show. Like preparing ballots for a shuffle,
or gathering up the last results of a big reduction. For this purpose `when-thread-is` can be used.
It simply surrounds its work with an implicit `(when (= someId (- (get-global-id 0) (get-global-offset ))) ...)` block.

`when-thread-is` uses a _relative_  thread id. Meaning, no matter what `global_offset` might have been used when enqueeuing
the kernel, the range of thread ids always starts at 0 and goes up to the `global_work_size` .  This means that if your kernel
is launched concurrently in two different thread groups that it can safely and consistently use `when-thread-is`  (especially `(when-thread-is 0 ...)` which is the most common usage).

This differs from OpenCL `get_global_id` which returns an absolute thread id (and is the source of many bugs and confusion).
`abs-when-thread-is` uses the absolute thread id and has the same interface as `when-thread-is`

```
(when-thread-is id <expr>)
;; when a multi-dimensional NDRange is used to enqueue the kernel, use these
(when-thread-is x-id y-id  <expr>)        
(when-thread-is x-id y-id z-id <expr>)   
```

Example:
```
(def-kernel k (#| some args |#)
  ;; first prepare
  (when-thread-is 0
    (let  ... ))

  ;; now do parallel grid stride
  (loop-vector-stride vec (i) 
    ...))
```

### when-thread-in-group-is / when-group-is 📝

`when-thread-in-group-is` is much like `when-thread-is` except that instead of using the global thread id,
the local id is used instead.  In other words, there is an implicit `(when (= someId (get-local-id 0)) ...)`

Similarly, `when-group-is` is akin to those except that the group id is used instead.  In other words, there is an implicit `(when (= someId (get-group-id 0)) ...)`

```
(when-thread-in-group-is id <expr>)
(when-thread-in-group-is x-id y-id  <expr>)        
(when-thread-in-group-is x-id y-id z-id <expr>)   

(when-group-is id <expr>)
(when-group-is x-id y-id  <expr>)        
(when-group-is x-id y-id z-id <expr>)   
```

#### sync-workgroup compilation issue.

Using `(sync-workgroup)` inside the scope of `when-thread-in-group-is` results in a compilation error as it would otherwise deadlock an entire workgroup.

Crisp users are strongly encouraged to use `when-thread-in-group-is` as opposed to a generic construction like  `(when (= (get-local-id) 0) ...)`  for this reason. The compiler will _attempt_ to detect the deadlock possibility in a generic construction, but due to variables, assignments, etc that guarantee is not strong. Whereas in `when-thread-in-group-is` it is a surety.

### when-global-linear-id-is / when-local-linear-id-is 📝

Unlike the previous `when-XXXX-is` , these two calculate the relevant linear id, and so there are no
variants for higher dimensions.   
Note that the global linear id is always relative, an absolute version isn't supported.  (See discussion of `when-thread-is` / `abs-when-thread-is` above.)

```
(when-global-linear-id-is id <expr>)

(when-local-linear-id-is id <expr>)

```

### when-is-last-workgroup 📝
`when-is-last-workgroup` captures the "last block standing" pattern. It provides a mechanism to elect a single workgroup to perform a final action after all other workgroups have completed their primary tasks up to that point. It does not cause other workgroups to wait. You can think of the other workgroups as party guests that continue on home, leaving the last one to whatever work is in the block.

It uses an internal atomic counter to determine which workgroup is the last to arrive at this point in the kernel. The body of the `when-is-last-workgroup` is then executed only by the threads within that single, elected workgroup. This is useful for performing a final, small reduction or cleanup step on data that has been prepared by all workgroups.
When it reaches the last workgroup, then the body of `when-is-last-workgroup` begins.   

```
(when-is-last-workgroup () ...)
(when-is-last-workgroup (id) ...)
(when-is-last-workgroup (x-id y-id) ...)
(when-is-last-workgroup (x-id y-id z-id) ...)
```

Example:
```
 ; lots of things being done by many threads and workgroups
 (when-is-last-workgroup (wg-id)
   ; now continue, knowing that "lots of things" are done everywhere.
   ...)
```

Implementation Notes
```
;; initialize *internal-global-counter* to (get-num-groups).  MUST BE :GLOBAL memory
;; initialize old-count to 0 .  MUST BE :local MEMORY
;; (declare (grid-level))

; start when-is-last-workgroup
;; Executed by thread 0 of each workgroup
(mem-fence :global)
(sync-workgroup)
(when-thread-in-group-is 0
   (set! old-count (atomic-dec! *internal-global-counter*))
   (sync-workgroup))

(when (= old-count 1)
    ;; body of when-is-last-workgroup
    )
```

### when-is-last-warp / when-is-last-thread 📝
```
(when-is-last-warp (lane-id) ...)
(when-is-last-thread (local-id) ...) ; <-- available in 0,1,2,3 arity
```
That "last man standing" pattern is also availabe for the last warp in a workgroup,
or the last thread in a workgroup. These use a local `atomic-dec!` so they have less
stall. See `when-is-last-workgroup` for an explanation. 

For the last thread or warp in the last workgroup, simply compose the two constructs:
```
(when-is-last-workgroup ()
  (when-is-last-thread ()
   ...))
```

### Hoisting and Enqueing a Kernel ⚠️

Crisp refers to the overall effort of getting a kernel read from disk, preparing the data, and actually enqueueing it as "hoisting". The Crisp compiler
can output hoisting example code for any kernel it compiles. That hoisting code is tailored to the kernel itself and the compilation targets,
which ensures that assumptions and dependencies are adhered to by both sides.

There are two important decisions that the host must make at the moment a kernel is enqueued. 
1. global work size - how many threads are spawned simultaneously for this kernels operation. 
2. local work size - how many threads are grouped together such that they can share fast local memory.
But note that in specifying these two values, you are also making a third very important decision:
3. number of workgroups.    The number of workgroups is simply the global work size divided by the local work size:
`num-groups = global-size / local-size`.  It is not uncommon to have kernels where the number of workgroups
cannot exceed the local work size. When this restriction is in place, certain algorithms become much simpler. 


Typically, the most performant choices that maximize GPU throughput use a "local_work_size" that is both
a power of two and a multiple of the GPU warp size (32 or 64).  So typically 64, 128, or 256.  And the global_work_size,
the actual number of threads that will be spawned, should be a multiple of that. 

Crisp has a number of `declare` directives that allow the host and the kernel to agree on what, or how, these values will be set. They tell the story of who expects what. These all go in the kernel's top level `declare` block.


#### global-size / local-size ✅
```
(global-size &key set-to VALS derive-from EXPR strategy:SYM tile-shape:(<extents>) dims:ulong msg:string)
(local-size &key set-to VALS derive-from EXPR strategy:SYM  tile-shape:(<extents>) dims:ulong msg:string)
```
These directives tells the hoisting code about how the kernel expects the global_work_size or local_work_size to be set.  
If both are used, then their arity must agree. And, the `work_dim` value the hoisting code sets will also match their arity.


The local_work_size is the number of threads grouped together in a single workgroup. This is number is usually best a power of two and multiple of the GPU warp size ( 32 or 64 ).
The global_work_size is the number of threads that the kernel will be enqueued upon. For maximum throughput, it is best to be a multiple of the local_work_size. 

A single directive CANNOT use both the `:set-to` and `:derive-from` keys.

These directives are optional but hightly encouraged as they serve to both document intent to future readers
of your kernel code, but also so the hoisting code is configuring things correctly for your kernel.

##### :msg 📝
The `:msg` key takes a string that will be output into the comment at the place where the hoisting code is setting the particular value. 


##### :dims 📝
The `:dims` key just takes the number `1` , `2` or `3` to express the required arity.  If using `:set-to` or `:derive-from` then
`:dims` is not usually needed.  But there will be times when a kernel doesn't have particular size requirements but DOES
have arity expectations.  Communicate them with `:dims`

If the `:dims` declaration does not match the arity of `:set-to` or `:derived-from`, or the arity differs between `global-size` and `local-size` then the compiler will error.

```
;; -- operate_2D --
(def-kernel operate_2D ()
   (declare (global-size :dims 2))
   ...)
```


##### :set-to ✅
The `:set-to` key instructs the hoisting code to use a specific value, (or values if multi-dimensional).

```
; Crisp Code
;; -- fun --
(def-kernel fun ()
  (declare (local-size :set-to 256))
   ...)

;; -- do_something --
(def-kernel do_something ()
  (declare (global-size :set-to '(512 256)  :msg "please don't change"))
  (declare (local-size :set-to '(32 32)))
  ... )

// possibly resulting C++ enqueue in hoisting example
// note that the work_dim is 2, which matches the arity of :set-to
 clEnqueeuNDRangeKernel( someCommandQueue, doSomethingKernel, 
                          2             /* work_dim */,
                          0             /* global_work_offset */,
                          { 512, 256 }  /* global_work_size  please don't change */,
                          { 32, 32 }    /* local_work_size */,
                          ...);
```

##### :derive-from ✅
The `:derive-from` key instructs the hoisting code that the kernel expects the size value to be in response to the named kernel parameter.  If the expression names a vector, then in response to its length. How "in response to" should be
intepreted is specified by the `:strategy` key (see below).  
It can take a single symbol (for a vector, implying its length) or a list of symbols (for scalar parameters representing dimensions).

```
;; Crisp Code

;; -- lighten_image --
(def-kernel lighten_image (image-data width height)
   (declare (type image-data (vector uchar :address-space :global))
            (type width height ulong)
            (global-size :derive-from '(width height) :strategy :one-thread-per :msg "ensure enough threads for every pixel of image, otherwise use the stepping convolution")) 
  ...)

// hoisting
 ...
 clSetKernelArg(lightenImageKernel, 1, sizeof(unsigned long), &imageWidth);
 clSetKernelArg(lightenImageKernel, 2, sizeof(unsigned long), &imageHeight);
 clEnqueeuNDRangeKernel( someCommandQueue, lightenImageKernel, 
                          2                            /* work_dim */,
                          0                            /* global_work_offset */,
                          { imageWidth, imageHeight }  /* global_work_size ensure enough threads for every pixel of image, otherwise use the stepping convolution */,
                          ...);
```

##### :strategy ✅

The `:strategy` key is most useful when used in conjunction with `:derive-from` (above). 

With `:derive-from` we are telling the hoisting code, "take such-and-such vectors size into consideration when setting the
global work size".  And the `:strategy` tells it _how_ that should be done.

It can be one of five possible values.

- `:one-thread-per`  This strategy means we expect there to be at least one global thread for each element of the vector. See [One Thread Per Element](#one-thread-per-element) discussion below.

- `:strided` This strategy tells the hoisting code that we are expecting to use a grid stride pattern to walk
the vector. (Read more at [Looping -- Grid Stride](#looping---grid-stride)). In this case the hoisting code
will try to size the global work size near the number of threads actually available on the hardware for MAXIMUM OCCUPANCY. 

But note that while maximum occupancy results in ideal performance for many workloads, it is not ideal for all workloads. In particular, if atomics are used, then a maximum occupancy stride might result in less work performed per atomic and more net atomic operations performed. Lower occupancy might be better for performance. See [:occupancy](#occupancy) below.


- `:exact` This strategy tells the hoisting code to set the global work size to be exactly the size, no more no less. This
strategy could also be used with the `:set-to` key. If combined with `:tile-shape`, `:exact` calculates exactly enough workgroups to cover the number of tiles.

`:tile-shape`
```
(declare (global-size :derive-from '(width height) :strategy :strided :tile-shape '(64 64)))
```

The `:tile-shape` key defines the geometric extents of the work being processed by a single workgroup. It is an orthogonal modifier to the `:strategy`.

When used with `:strategy :exact`, the hoisting code divides the input dimensions by the `:tile-shape` to determine the exact number of workgroups to launch `(CEIL(dimension / tile_extent))`.

When used with `:strategy :strided`, the host relies on hardware occupancy to determine the launch size, but uses the `:tile-shape` to configure any necessary tile-based dynamic memory allocations.

This declaration should always be used when utilizing the `tile-stride` or `matrix-multiply-tile-stride` macros so the host orchestrator understands the block partitioning.



If the `:strategy` is not provided, then the default assumption is `:one-thread-per`. 


##### `:occupancy` ✅

The `:occupancy` key is a manual derating factor for the `:strided` strategy.
Accepts a number from `0.0` to `1.0` (default `1.0`).

When the hoisting code calculates "near the number of threads actually
available on the hardware" (via `cuOccupancyMaxActiveBlocksPerMultiprocessor`
on CUDA or `zeDeviceGetComputeProperties` + `zeKernelGetProperties` on Level
Zero), it multiplies the result by the `:occupancy` ratio.

Maximum theoretical occupancy is necessary but not
sufficient for peak performance. Real workloads compete for shared resources
that don't scale with thread count:

- L2 cache pressure -  more concurrent workgroups thrash the L2.
- LSU queue depth -  finite per-SM load/store queues saturate.
- Atomic serialization - kernels ending in `atomic-add!` to global memory
  serialize at the atomic site. More workgroups = more atomic ops queued.
- Per-block fixed overhead amortization - shared-memory setup and
  barriers cost the same regardless of how much work each thread does.

For reduction-pattern kernels (those ending in a global atomic), the sweet
spot is often `:occupancy 0.2` or even lower. Bandwidth-bound kernels without
atomics generally benefit from the default `1.0`.

Remember, these declarations influence any hoisting code that Crisp outputs (`--hoist=L0` or `--hoist=CUDA`), the kernel itself is NOT effected in any way. 

```
;; -- sum_reduce_tree --
(def-kernel sum_reduce_tree (input &out result)
  (declare #'(in-vec &out out-cell => nil))
  (declare (global-size :derive-from input :strategy :strided :occupancy 0.5)
           (local-size  :set-to 256))
  ...)
```


##### :tile-shape ⚠️

`:tile-shape`  When  using the `:tiled` strategy you can provide the extents of the tile so the host can 
calculate accordingly.  

#### num-groups 📝
```
(declare (num-groups :max :local-size :msg "number of groups can't be bigger than a local work size"))
;OR
(declare (num-groups :max <someExpr> :msg "But here's my number, so call me maybe."))
```

As mentioned earlier, the number of workgroups for a kernel is simply the "global work size" divided by the "local work size". 
Thus the need to have any kernel specify it is redundant. Simply declaring `global-size` and `local-size` are sufficient.

But there are cases where kernels make assumptions about the number of workgroups. The most common one being that the 
number of workgroups cannot exceed the local work size. In that even simply `(declare (num-groups :max :local-size))`.
This will help document this restriction to anyone reading the kernel code, and the hoisting code that is 
generated will also abide by that restriction (and note it in the comments).

Alternately, some other expression can be provided. And, as with `local-size` and `global-size` and optional `:msg` 
can be used to inject a comment into the hoisting code.




#### check-thread-bounds 📝
By itself, the `global-size` expressions above doesn't result in any change to the 
the way the kernel compiles or runs. It is mostly for communicating intent to the host which 
will be hoisting the kernel. But it DOES interoperate with the `check-thread-bounds` predicate.

```
(check-thread-bounds i)
(check-thread-bounds x y)
(check-thread-bounds x y z)
```
`check-thread-bounds` returns T if the provided index value(s) is less than the value specified by the `global_work_size` when the kernel was enqueued. This makes it very useful for bounds checking, especially if the `global_work_size` 
has been "rounded up" to a multiple of the workgroup size by the host.

```
;; -- lighten_image --
(def-kernel lighten_image (image-data width height)
   (declare (type image-data (vector uchar :address-space :global))
            (type width height ulong)
            (global-size :derive-from ( width height) :strategy :one-thread-per)) ; <-- this sets the upper bound for check-thread-bounds 
  (let ((image-matrix (make-tensor image-data width height)))
    (in-each-thread (x y)
      (when (check-thread-bounds x y) 
        (inc! (~ matrix x y) 30)))))

```

#### check-wg-bounds 📝
Like `check-thread-bounds` but influenced by the `local_work_size` enqueue value and meant to be used on workgroup indeces.

#### declaring local-size / global-size in sub functions.
The declarations of the local or global size preference is optional, though highly recommended. It can be done
in the scope of a `def-kernel` or in the scope of a `def-function`.  The compiler will look at the call chain for any kernel to see what values it should request in the hoisting code for global and local sizes.  
If there are competing declarations in the kernel and different sub functions then the compiler will emit a warning informing you. When there are conflicts the hoisting code will recommend that the GREATEST of the competing sizes
be used. 


#### check-async-hazards 📝

If present, the scope is checked to see if there is illegal access of memory between an async `(request-)` and the matching `(await-request )`
A compile error is emitted if forbidden access is detected.



### Latency Hiding - warp sizes and workgroup sizes ✅

As mentioned in passing, most GPUs have a warp size of 32 threads, and the best practice is to use a `local_work_size` (ie a work group size) that is a multiple of the warp size when enqueueing.  But why is that?
The answer is Latency Hiding. When a warp needs to access memory it may become stalled waiting for that memory.  
While it is stalled the GPU can run OTHER warps to "hide" the latency. But it can only run other warps that 
are within the same workgroup. So this is the reason the workgroup size is best set as a multiple of the warp size.

There are times when it is simplest, and indeed fastest, to simply set the `local_work_size` to 32, to the warp size. This ensures that workgroup thread communication can always just be done with a shuffle, and without needing `:local` memory or barriers. But this is only a good strategy if you are sure your kernel is relatively stall-free. If it stalls because of branch divergence or memory access, then there is no other warp to take up the slack, which makes the overall operation slower.  



### One Thread Per Element ✅

When the host enqueue's a kernel it will set up the global work size, which means the host is deciding how
many threads will run your kernel.  One common strategy for simpler (and faster) kernels is to simply 
have the kernels work execute exactly once per thread. No other looping is required.  

For example, if we have a vector of 1024 items that need some work done on them, we schedule
that same number of threads: 1024. Each thread works on just one element of the vector.

This strategy is simple and flexible. While it can scale to any desired size, it 
performs suboptimally for very big kernels or very large thread work sizes. 
If a One Thread Per Element strategy works for your workload, then almost certainly
a Grid Stride will also work (see below) and that will be more performant for larger 
sized vectors. And most performant of all would be to leverage Data Interleaving (see below), 
though that requires considerably more effort to orchestrate host side.  

#### in-each-thread 📝

`in-each-thread` is a simple macro for binding thread index values over a body of statements. 
It is useful in lots of different kernels following different strategies. 
It is quite handy when using the  "one thread per element" work strategy. 

There are three variants for 1D, 2D and 3D .
```
(in-each-thread (x) ...)       ; 1D   x is bound to the x thread index / global-id 0
(in-each-thread (x y) ...)     ; 2D   x and y bound to the global-id 0 and 1 
(in-each-thread (x y z) ...)   ; 3D  
```



```
;; 1D Vector Add
(def-type source-vec (vector float :address-space :global))     
(def-type result-vec (vector float :address-space :global))    

;; -- vector_add --
(def-kernel vector_add (A B &out C)
  (declare (type A B source-vec) (type C result-vec) 
           (global-size :derive-from A :strategy :exact :msg "no bounds checking. global_work_size MUST match vector lengths exactly" ))
  (in-each-thread (i)                        ; 'i' will be bound to the thread index / global-id
    (set! (~ C i) ( + (~ A i) (~ B i)))))


;; 2D Lighten Image

;; -- lighten_image --
(def-kernel lighten_image (image-data width height)
   (declare (type image-data (vector uchar :address-space :global))
            (type width height ulong)
            (global-size :derive-from '(width height) :strategy :one-thread-per)) 
  (let ((image-matrix (make-tensor image-data width height)))
    (in-each-thread (x y)
      (when (check-thread-bounds x y) 
        (inc! (~ matrix x y) 30)))))
```


#### in-each-thread-in-group 📝

`in-each-thread-in-group` is a simple macro for binding thread index values over a body of statements. 
It is useful when you want every thread in a workgroup to follow a sequence of steps. 

There are three variants for 1D, 2D and 3D .
```
(in-each-thread-in-group (x) ...)       ; 1D   x is bound to the x thread index / local-id 0
(in-each-thread-in-group (x y) ...)     ; 2D   x and y bound to the local-id 0 and 1 
(in-each-thread-in-group (x y z) ...)   ; 3D  
```

#### in-each-group 📝

`in-each-group` is another binding, but it binds to the WORKGROUP index. 

```
(in-each-group (x) ...)       ; 1D   x is bound to the index of the GROUP (get-workgroup-id)
(in-each-group (x y) ...)     ; 2D   x and y bound to the wg-id 0 and 1 
(in-each-group (x y z) ...)   ; 3D  
```


#### Size Matters

In the first example above, we used 1024 as the vector size and the matching thread count. That's convenient
for an example because that number is a multiple of 32 and 64, the most common warp sizes. 

When hoisting a kernel the most performant choices that maximize GPU throughput use a "local_work_size" that is both
a power of two and a multiple of the GPU warp size (32 or 64).  So typically 64, 128, or 256.  And the global work size,
the actual number of threads that will be spawned, should be a multiple of that.

But what to do if the size of your problem is NOT an even multiple of one of these nice choices?  In this case, the kernel 
should definitely use `check-thread-bounds` and the host code that hoists it should round up whatever thread count they are 
requesting to the next muliple of a nice local_work_size.



### Looping - Grid Stride ✅

The One Thread Per Element strategy is simple and it can scale to any size. But if the number of threads
needed is greater than the maximum number on your GPU, then the driver will have to juggle and reload 
kernels and workgroups until the problem space is complete. This can be suboptimal for performance. 
In many of these cases, we can simply launch of bunch of threads and have them each loop internally a bit.
This could mean there would be no juggling or reloading required. 
Each thread would have to perform their work N times without overlapping. 
Where N = Size-of-Problem / Number-of-Threads-Launched.  

A grid-stride loop is a common pattern for processing large datasets that are bigger than the number of threads launched. It ensures that each thread processes multiple data elements while maintaining full occupancy and avoiding divergence.

The Crisp stride primitives are designed to encourage coalesced memory access patterns by default, helping the
programmer achieve maximum performance.

#### IMPORTANT - NO NESTING

Both `loop-vector-stride` and  `tensor-stride` operations are "grid level" operations. That is discussed below. Essentially,
grid level operations cannot nest inside one another. The compiler will error if you attempt to do so.

Also the body of those two `-stride` operations cannot call other "grid level" operations like the variants
on `reduce-`, `filter-` and others. You are welcome to use multiple grid level operations, they just
cannot be nested.  

But a grid-level stride CAN call `workgroup-stride`, which has a "workgroup level" context.  

#### `loop-vector-stride` ✅

 `loop-vector-stride` iterates over a vector  using the Grid Stride strategy. 
This macro is simple, clear and less error prone than trying to roll your own.
The bound value (`x`) is never out-of-bounds of the vector. 

```
(loop-vector-stride vec (x) ...)       ; 1D   x is some element index in the vector. 
```
In the example below, `vector_add` becomes trivial. But also note that no matter how big the vector,
so long as the hoisting code sets the `global_work_size` to be close to the actual number of hardware
threads available, that this `vector_add` will be much faster than the "One Thread Per" strategy when
the number of elements in the vector is larger than the number of available hardware threads.

The only way to make `vector_add` faster is to use interleaved memory and kernel execution (discussed below).
```
;; -- vector_add --
(def-kernel vector_add (A B &out C)
  (declare (type A B source-vec) (type C result-vec)
     (global-size :derive-from A :strategy :strided))       
  (loop-vector-stride A (i)                   
    (set! (~ C i) ( + (~ A i) (~ B i)))))
```

#### loop-soa-stride 📝
`(loop-soa-stride soaVec (i) ...)`

`loop-soa-stride` iterates over a `soa-vector` using the Grid Stride strategy. 


#### strided strategy ✅

As was discussed in [Hoisting and Enqueueing a Kernel](#hoisting-and-enqueing-a-kernel) it is good practice
to `declare` your kernels global work size expectations and the strategy it hopes to employ.

The `:strided` strategy is almost always the correct choice when doing grid strides of various flavors.


#### grid stride example with explanation.
```
;; -- vector_add --
(def-kernel vector_add (A B &out C)
  ;; assumes A, B and C are all the same length.
  (declare #'((in-vec float) (in-vec float) &out (out-vec float))
     (global-size :derive-from A :strategy :strided))     
  (loop-vector-stride A (i)        
    (set! (~ C i) ( + (~ A i) (~ B i)))))
```

Let's imagine that our vectors A, B, and C each have 100,000 elements. And imagine that our hosting code has set the 
`global_work_size` to 1024. That is, 1024 threads are each running this kernel in parallel.

`loop-vector-stride (i)` establishes a loop, with `i` bound to an index, and the the body setting the vector C at that index
to the sum of A and B at that index (or in C: `C[i] = A[i] + B[i]`)

This runs in parallel so `i` is bound like so across all the threads:
```
    Loop Iteration #1:  0     1     2    3    4    ... 1023
```
And then, the next time through the loop, we don't increment by 1, instead we "stride", we increment _by the number of threads_, which 
we imagined is 1024.  We keep striding until we hit the target which is the lenght of A, 
which we imagined at the outset was 100,000 elements, is where we'll stop striding.
```
    Loop Iteration #2:  1024 1025 1026 1027 1028   ... 2047
    Loop Iteration #3:  2048 2049 2050 2051 2052   ... 3071
    Loop Iteration #4:  3072 3073 3074 3075 3076   ... 4095
    ...
    Last Iter     #98: 99328 99329 99330  --  99999 in 671st position. Threads 672 to 1023 do nothing in last iteration.
```
Hey! That looks like a grid!  

As you can see, all the indeces from 0 to 99,999 are visited, and our calculation is performed at each index. 
In a very short time (just 98 iterations), these 1024 threads add vectors A and B and store them in C. Wow!


### General Purpose: `tensor-stride`, `grid-stride`,  `tile-stride` and `hardware-stride` ✅

While `loop-vector-stride` is very handy and one of the most commonly used Crisp affordances, 
it's one task is to just employ all the threads to walk a vector. Sometimes you'll need more.
That's when the other Crisp stride macros will come into play.  Unlike `loop-vector-stride`, these can be used with Storage Handles of other arities.

- `tensor-stride` - like `loop-vector-stride` but for matrices and tensors of any arity.
- `grid-stride`  - not associated with any data, just sets up a simple mathematical stride, to any arity.
- `tile-stride` - VERY HANDY stride variant of `tensor-stride` but that moves by "tiles".  Works in
any arity and has helper macros to move between the problem space vector , the indexing, and the tile coordinate systems.
- `hardware-stride` - stride by workgroup or warp. 



#### Simple Safe tensor-stride ✅
```
(tensor-stride <tensor> (<bindings>) ...) 

;;example: fill a matrix with "2"
(tensor-stride someMatrix (row-y col-x)
  (set! (~ someMatrix row-y col-x) 2))
```
This macro visits every unique location in the tensor. Within each warp, the contiguous term of the tensor 
is guaranteed to change. Meaning it's easy to get coalesced memory access.  Works equally well
with row major or col major matrices, for example. 

If the contiguous term of the tensor is compile time determinable, then this will be optimized striding,
otherwise an extra calculation at runtime might be required. Note that even though `:contiguous-term` is 
a compile-time requirement for all tensors, incomplete types at function boundaries might make that indeterminable.  
  

#### Strict tensor-stride ✅
```
(tensor-stride <tensor> <layout-tag> (<bindings>) ...)

;; example
(tensor-stride someMatrix :row-major (row-y col-x) 
   (set! (~ someMatrix row-y col-x) 3))
```

Forces the compiler to hardcode the specified layout. If the static type contradicts it, fail compilation.

Just as with the previous form, this `tensor-stride` macro visits every unique location in the tensor, with
the contiguos term of the tensor mapping neatly to each warp lane.  Once again, works equally well
with row major or col major matrices.

But this variant uses a `layout-tag` argument to express the authors expectation and that will be
EXACTLY how the tensor is strided, with the compiler optimizing every operation. 

`<layout-tag>` choices are

| Tag | Description |
| -- | -- |
| `:row-major` | bindings are `(row-y col-x)` and the LAST term is assumed to be contiguous.  IF the matrix is known at compile time to be :col-major then this is compilation error. OTHERWISE, it assumed the user knows what they are doing. |
| `:col-major` | bindings are still `(row-y col-x)`, but the FIRST term is assumed to be contiguous.|
| `:contiguous-last`  | bindings are `(... y x)` and the LAST term is assumed to be contiguous.|
| `:contiguous-first` | bindings are still `(... y x)` but the FIRST term is assumed to be contigous.|

If the compiler can determine the contiguos term of the tensor and sees that it disagrees with the `layout-tag` it
will emit an error.
But if the compiler CANNOT determine the contiguous term and the provided `layout-tag` is wrong, then this stride
will NOT have coalesced memory access and will likely be slow.  If compiled with `--runtime-checks` a runtime check 
is asserted into the code. 




#### Mathematical grid-stride ✅
```
(grid-stride (<size-list>) (<bindings>) ...)

;; example
(grid-stride (8000000 4000000) (y x) ...)
```
Unlike the others, `grid-stride` does not take a `<tensor>` argument. It simply divides up the `<size-list>` 
problem space by the number of enqueued threads and strides the problem. It treats it as a purely mathematical grid. Defaults to row-major mapping (right-most binding gets the warp).
It is how you tell Crisp to "Forget about physical memory for a second. Just generate a virtual 2D grid of 8 million rows and 4 million columns, and march the GPU across it."


#### tile-stride ✅
```
;; "safe" variants
(tile-stride <tensor> (<size-list>) (<bindings>) ...)
(tile-stride <tensor> <tile-tensor> (<bindings>) ...)

;; "strict" variants
(tile-stride <tensor> <layout-tag> (<size-list>) (<bindings>) ...)
(tile-stride <tensor> <layout-tag> <tile-tensor> (<bindings>) ...)

(tile-stride someMatrix (8 4) (grid-y grid-x) ;; grid-y/x denote nth tile
  (let ((y x (tensor-coords grid-y grid-x))) ;; which pixel/element in the matrix is it exactly
        
    ...))

```
`tile-stride` breaks up a `tensor` into tiles (of any arity, not just 2D). The body of 
`tile-stride` executes once for each tile, with the `<bindings>` being the coordinate
of the `<tensor>` that would act as the tiles origin.

For example, let's say tile-stride is used with a source vector length 30 and a tile length 10.
Then in
`(tile-stride source tile (grid-x) ...)`
The body will execute three times, with `grid-x` bound to 0, 1 and 2.


The arity of the `<size-list>` must match the arity of the `tensor` and the `<bindings>`. Compilation error otherwise.
Alternately, a smaller `<tile-tensor>` can be provided. Its extents will be used for the tile size and, of course,
its arity must match as well. 

Note that there are "safe" and "strict" variants of `tile-stride`. See the descriptions of `tensor-stride` above for that discussion

These variants of `tile-stride` DO set up helper macros. They are discussed below.

Note that `tile-stride` should nearly always be used with the `:strategy :tiled` declaration.  See [:strategy](#strategy) for a discussion. The strategy declaration
is how you communicate your tiling expections out to the metadata or hoisting code that runs host side. 


#### hardware-stride - stride by workgroup or warp. ✅

```
(hardware-stride <tensor>  <hw-tag> (<bindings>) ...)
(hardware-stride <tensor> <layout-tag> <hw-tag> (<bindings>) ...)

;; examples
(hardware-stride someMatrix :row-major :workgroup-idx (grid-y grid-x) ...)
   
(hardware-stride someVector  :warp-idx (grid-x) ...)

```

`hardware-stride` takes a `<hw-tag>` argument and chunks the problem space by the physical hardware enqueue dimensions. For "strict", provide a `<layout-tag>`.

Just like `tile-stride`, `hardware-stride` acts as an **outer loop**. Its body executes once per hardware chunk, and the `<bindings>` represent the index of that chunk within the tensor. The key difference is that you do not provide a `<size-list>`; the chunk size is implicitly derived from the hardware environment.

There are two choices for `<hw-tag>`: `:workgroup-idx` and `:warp-idx`.

##### `:workgroup-idx` ✅

With `:workgroup-idx`, the tensor is chunked by the workgroup dimensions. The arity of the tensor and the bindings MUST match the arity of the workgroup enqueue.

```lisp
;; 2D enqueue
(hardware-stride someMatrix :row-major :workgroup-idx (grid-y grid-x) ;; which workgroup chunk is this?
   (let ((y x (tensor-coords grid-y grid-x)))  ;; which pixel of someMatrix is at its upper-left 
       
       ;; body executes once per workgroup cooperatively
       (load-tile ...) 
       ...))

```

##### `:warp-idx` ✅

With `:warp-idx`, the tensor is chunked into 1D segments equal to the hardware warp width. Note that if using `:warp-idx`, it is extremely important that the kernel is hoisted with a `local_work_size` that is a multiple of `(get-warp-size)`. Otherwise, operations like warp-level reductions could end up deadlocking.

Note that `hardware-stride :warp-idx` can be used with any global size arity, but it iterates over the flattened, global execution space by the hardware warp width.

Also note that `load-tile` and `store-tile` (and their async counterparts) are not available
from within a `:warp-idx` hardware-stride.  

```
(hardware-stride someVector :warp-idx (grid-x) 
      ;; body executes once per warp cooperatively
      ...)

```

> Implementation Note: Unlike `tensor-stride`, the chunking variants (`tile-stride` and `hardware-stride`) do not evaluate their bodies per-element. They stride the problem space in block-sized steps. For `hardware-stride`, those steps are driven dynamically by `(get-local-size)` or `(get-warp-size)`. Any element-level computation must be done in an inner loop (like `workgroup-stride`) inside the body.

#### Helper Macros ✅

The helper macros map the tensor coordinates to the other spaces.  These helper macros are
available when using the `tile-stride` and `hardware-stride` stride macros.

<!-- 
REMOVED FOR NOW
##### `tile-coords`
`tile-coords` always has the same arity as the binding and returns that same number of argumetns.
These coordinates are within the tile `<size-list>`/`<tile-tensor>`

```
(let ((t-z t-y t-x (tile-coords cube-z cube-y cube-x))) ...)
```
-->
<!-- REMOVED FOR NOW 
##### `tile-indices` ✅
`tile-indices` also matches arity. It returns the index coordinates of the tile
-->

<!-- 
 REMOVED FOR NOW 
##### `tensor-coords` 
```
(tensor-coords (<grid-indices>) &optional (<tile-coords>))
```
`tensor-coords` macro takes two arguments. A list of the tile indices followed by a list of the tile coordinates.
It returns mapping coordinates into the problem space tensor.

```
(let ((row-y col-x (tensor-coords (idx-y idx-x) (t-y t-x)))))
```
-->
<!-- 
HELPERS REMOVED

##### `load-tile` / `store-tile` ✅
There are two other helper functions that are present when doing "tileed" striding.  
They have their own section of the docs below.
-->
<!--  

NOTE: I'm temporarily setting the stride-subview helper function aside
NOTE: explain risk of deadlock   
 
NOTE: compiler will use this to DETECT possible deadlocks 
       this makes it EASIER to detect deadlocks at "ragged edges"
       we insert (declare :ragged-edge) or something 
TODO: figure this out. (declare (convergent)) and friends.

##### `stride-subview`
In the scope of `thread-stride` there is helper function `stride-subview` which returns another `tensor`.
 This `tensor` has the size and dimensions of the `chunkExpr` but is mapped to the current location in the problem space.

Note that in the event the problem space is not evenly divisible by the chunk, then the `tensor` that is returned
might have dimensions smaller than the chunk if it is near the memory boundary. This way there is no accidental out of bounds memory access.  


Note, also, that this chunk is a subview into the problem space, which is likely `:global`.
If you are wanting fast chunk access use `load-chunk` / `store-chunk` below to transfer to `:local` memory for fast operations.
-->



<!--

### Load Tile / Store Tile ✅

`load-tile` and `store-tile` work with tensors of any arity, not only 2D matrices.

`load-tile` is used to copy data from the :global address space problem space tensor
to the :local address space tile tensor.

`store-tile` does the opposite. Storing the :local tile tensor into the original problem
space tensor.  

Note that these helper macros are coordinate aware. When used from within `tile-stride` or `hardware-stride`
stride macros, they know where the current tile "cursor" is and how to map between the problem space and the tile.

There are also asynchronous variants.


```
;; Helpers
(load-tile <src-problem-space-tensor> <dest-tile> &key (identity 0) transpose)
(request-load-tile <src-problem-space-tensor> <dest-tile> &key (identity 0) transpose) => request-token



;; Helpers
(store-tile <src-tile> <dest-problem-space-tensor> &key transformF transpose)
(request-store-tile <src-tile> <dest-problem-space-tensor> &key transpose) => request-token


(await-request request-token)
```

`<problem-space-tensor>` can be any tensor whose arity matches the surrounding tile-stride / hardware-stride and whose element type is compatible with <tile>. Extents, strides, offset, address space, alignment, and contiguous-term may all differ from the stride's tensor — the cooperative loop reads each tensor through its own metadata, and the in-bounds check uses the passed tensor's extents (so ragged or under-sized destinations just skip out-of-range writes / fill with :identity on the load side).

`<tile>` is a small `tensor` , the same dimensions of the `<tile-size>` for the `tile-stride`.
It is typically `:local` address space.

The `:identity` key can be used when the problem space
is not evenly divisible by the tile size.  In that case, the tile will be correctly loaded with
data from the problem space where possible, but the REMAINING values of the tile will be loaded with the `:identity` value (which defaults to 0)

`:transpose` key.  The tile will simply lift the data right out of the problem space tensor, 
whether it is `:col-major` or `:row-major`, and so have the same layout, just smaller.  
But the `:transpose` argument can be used to change that. For tensors of arity 1 (vectors), the `:transpose` is ignored. For arity 2 (matrices) then if `:transpose true` then
the `x` and `y` coordinates will be swapped.
For tensors with an arity of three or greater, the `:transpose` keyword accepts a permutation list (such as `'(0 2 1)`) to explicitly dictate how the axes are reordered when mapping to local memory. Providing a simple boolean `true` serves as a convenient shorthand for this list, defaulting to swapping only the two innermost dimensions while preserving the outer batch structure.



`load-tile` will map the `<tile>` to the appropriate place in the problem space and 
load the tile with the data there.  

Similarly, `store-tile` does the reverse - copies memory from some tile vector
into the appropriate location in the problem space data. This is usually used with 
some `&out` output memory whose size is identical to the problem space. 

The usual practice is that the problem space tensor is `:global` and the tile is `:local`.


`store-tile` can also accept a `:transformF` key. This is a function of `binop-type` that
can be used to transform the value as it is stored. Note that the asynchronous version does
not support the `:transformF` key.

> Implementation Note: first order functions are automatically templated and monomorphically specialized in Crisp

#### sync-workgroup ✅

Both `load-tile` and `store-tile` invoke `(sync-workgroup)` at the completion of their
operation. This prevents read-after-write and write-after-read race conditions. 
But be aware, that this also means these functions should NOT appear in conditional blocks 
( `when`, `if`, `cond`, `unless`) or you will incure a deadlock. The Crisp compiler should
detect this and emit an error.

#### Asynchronous Variants ⚠️
Crisp also provides asynchronous variants of these tile load and store helpers.
THe `request-XXXX` variants return a `request-token` which can be awaited on with `(await-request <token>)`

```
(let ((my-tile (make-scratch-vector float :match-workgroup-size)))
  (tile-stride big-vector my-tile (x)
    (let ((token (request-load-tile big-vector my-tile))
           ;; we can do OTHER operations before we await.
           ;; just don't touch the data behind big-vector or my-tile.
          (idx (tile-indices x)))
        (await-request token)
        ;; now we can touch my-tile
        (workgroup-stride my-tile (wx)
           (inc! (~ my-tile wx) 10))
        (store-tile my-tile big-vector)
        ...)))
```



#### Choosing the Right tile Size

When utilizing `load-tile` and `store-tile`, the shape and size of your `<tile-tile>` directly dictate how the GPU's memory controller fetches data. Choosing the wrong size will result in uncoalesced memory reads and severe performance degradation.

Follow these three guidelines when defining your tile sizes:

##### Capacity: Match the Workgroup Size
Because `load-tile` is a cooperative workgroup operation, the total number of elements in your tile should ideally be a perfect multiple of your `local_work_size`. 
- If your workgroup size is 64 threads, a tile of 64 elements means exactly 1 read per thread. 
- A tile of 128 elements means exactly 2 reads per thread. 
- If you pick an arbitrary total like 50 elements for a 64-thread workgroup, 14 threads sit completely idle while the memory controller waits for the active threads to finish. 

##### Warp : Stretch the Contiguous Dimension
GPU memory is physically 1-dimensional. Cache lines are pulled in 64-byte or 128-byte linear blocks. Therefore, your tile should not be shaped like a square if you can avoid it. It should be stretched as wide as possible along the tensor's `:contiguous-term`.

For a `:row-major` (or `:contiguous-last`) matrix, the contiguous term is the X-axis (the columns). 
- BAD (The Square Trap): A tile of `(Y=8, X=4)`. A warp of 32 threads will be divided across 8 different rows, requesting 4 elements from each. The hardware has to fetch 8 entirely separate cache lines simultaneously, wasting huge amounts of bandwidth.
- GOOD (The Stretched Tile): A tile of `(Y=2, X=16)`. 16 contiguous elements (64 bytes of floats) fit perfectly into a single cache line. 
- PERFECT:*A tile where the contiguous dimension is exactly the Warp Size (e.g., `X=32`). All 32 threads in the warp hit adjacent memory addresses simultaneously, resulting in a single, perfectly coalesced memory transaction.

##### Algorithmic Concerns: Why Square Tiles Exist
If stretched tiles are so fast to load, why do algorithms like Matrix Multiplication (MatMul) famously use square tiles (like `16x16` or `32x32`)?

Because in MatMul, the bottleneck isn't just loading the data; it is reusing the data. A `16x16` tile loaded into `:local` memory allows the workgroup to perform 256 math operations without returning to global memory. A stretched `2x128` tile might load faster, but it provides far less mathematical reuse for the algorithm.

-->



### workgroup-stride ✅
```
(workgroup-stride <tile-tensor> (<bindings>) ...)
```
`workgroup-stride` is the primary workhorse for computations within a single workgroup. It is designed to walk the coordinates of a `:local` or `:private` tensor (a "tile") using the full parallel resources of the workgroup. 

<!--
#### The "One Coordinate" Binding
The `<bindings>` always represent the local coordinates within the `<tile-tensor>`. If you are striding a $16 \times 16$ tile, the bindings will range from $(0,0)$ to $(15,15)$. The macro ensures that:
- Coalesced Access: The contiguous dimension of the tile is automatically mapped to the fastest hardware dimension (the warp lane) to prevent bank conflicts.
- Cooperative Execution: If the tile is larger than the physical workgroup size, the macro handles the serial-parallel tiling required to visit every element.

```
Example: Simple cooperative increment
(let ((my-tile (make-scratch-matrix float (16 16) :local)))
  (tile-stride big-matrix my-tile (y x)
    (load-tile big-matrix my-tile)
    
    (workgroup-stride my-tile (ly lx)
       ;; ly and lx are always 0-15, mapped to workgroup hardware
       (inc! (~ my-tile ly lx) 1.0))
       
    (store-tile my-tile big-matrix)))
```
-->

#### Hardware Context Helpers ✅

Instead of "modes" or "tags" that change how the stride works, Crisp provides helper macros that can be used inside the body of a `workgroup-stride` to access hardware-level information. This allows you to write warp-aware logic without losing your place in the tensor's coordinate system.

#### Helper Description 
- `(warp-id)` Returns the index of the current warp within the workgroup.
- `(warp-lane)` Returns the index of the current thread within its warp (e.g., 0–31).
- `(warp-count)` Returns the total number of warps in the current workgroup. 

#### Example: Warp-Aware Logic
This pattern is useful for algorithms where only one "representative" thread per warp should perform a specific task, such as updating a shared counter or coordinating a sub-group shuffle.

```
(workgroup-stride my-tile (ly lx)
  ;; Every thread does the common work
  (set! (~ my-tile ly lx) (expensive-calculation ly lx))
  
  ;; Only the first lane in every warp handles logging or sync
  (when (== (warp-lane) 0)
    (atomic-inc! (some-shared-counter) 1)))
```

#### Implementation Notes

- Implicit Synchronization: To maintain maximum performance, `workgroup-stride` does not inject a `(sync-workgroup)` at the end of its block. If your logic requires all threads to finish a pass before moving to the next, call `(sync-workgroup)` explicitly.
- Arity Consistency: The number of `<bindings>` must match the arity of the `<tile-tensor>`.
- Scope: The bindings `(ly lx)` represent the position within the tile, while any bindings from an outer tile-stride (e.g., y x) remain available for calculating positions relative to the global problem space.


                     

#### `ceil-pow2` 📝

For certain operations, like warp reductions, it is imperative that certain activities
fit completely in a warp and are not "split" across warp divide. 

If the argument to `ceil-pow2` is a power of 2, it'll be returns. But if not, then the
next hightest power of 2 will be returned. This can be very handy in loops
or for making sure tile strides don't split work across the warp boundary. 

```
(ceil-pow2 4) => 4
(ceil-pow2 5) => 8
```



### Looping -- Uniform Loops ✅

A C++ `for` loop is a big liability when improperly used in a GPU kernel. If the loop isn't
performed uniformly across all the threads in a work group then massive stalls can occur
which kill throughput and performance. 

Similarly, the compiler is capable of unrolling a loop if its target is compile-time calculable.

In Crisp, you can convey these expectations in your code, and if the compiler detects
that it is not achievable, it will emit an error. This makes writing performant code that 
does not diverge much easier. There is much less guessing will-it/won't-it.

Crisp has `+` variants of all the looping macros. These variants allow you to tell the compiler
that you expect the loop to run uniformly across the entire warp. If the compiler detects the 
possibility for warp-level divergences, it will emit a compliation error.

Note, that these variants are used to help you discover divergences. Even if you don't use them
the loop will still benefit if it is warp level uniform, and the compiler might still optimize
by unrolling. The use (or not) of the variant doesn't change the actual performance.


#### `provably-uniform?` and `provably-divergent?` ✅

```
(provably-uniform? <someExpre>)
(provably-divergent? <someExpr>)
```
`provably-uniform?` and `provably-divergent?` are compile-time forms that can be used to develop your own macros.

When evaluating uniformity, there are three possibilities: 
- the compiler can prove to itself that some variable is uniform across the workgroup
- the compiler can prove to itself that some variable diverges in the workgroup
- the compiler is unable to prove anything about the variable or expression uniformity.

Keep that in mind because because `(not (provably-uniform? var))` does NOT necessarily mean that `(provably-divergent? var)` would be true. 

The `+` variants (`if+`, `dotimes+`) etc all use `provably-uniform?` and emit an error if that is not determiinable. 




#### detecting uniform execution ✅
In this example, if the compiler detects that `someN` is not uniform across the warps it will
emit an error. 
```
(dotimes+ (x someN)
 ...)
```

Warp level loop uniformity is the most useful/important. And that's what `dotimes+` checks.



#### forcing uniform loop execution ✅

If you want to FORCE a loop to be uniform across the entire workgroup, Crisp makes it easy to do that 
using the `to-workgroup-uniform` or `to-warp-uniform` .

```
(let ((someN (to-workgroup-uniform (some-expression ...))))
   (dotimes* (x someN)
      ...))
```

`to-workgroup-uniform` will capture the variable in workgroup thread, use a `sync-workgroup` barrier and broadcast it to all the others.
`to-warp-uniform` is similar, but uses shuffles to broadcast through the warp. 

These two expression can ONLY be used in a let binding.  They cannot be used in any normal position like a regular lisp form. This is because of the barriers they might introduce, they need consistent predictable ordering. 

Note that these to forms are HEAVY HANDED and not peformant (though, when used correctly, performance can be gained).



#### providing uniformity hints to the compiler ✅
`(declare (uniform someVar))`

If you know that a variable will be uniform, even if the compiler cannot determine that by itself,
you can tell it using this declaration. 
The compiler will check that `someVar` isn't provably divergent. If it detects that it is, it will emit an error. Otherwise, the variable will be taken as uniform and that will influence the uniformity check peformed by `provably-uniform?`



#### (constexpr <varName>) 📝
`(declare (constexpr someVar))`

The compiler will check that `someVar` is compile-time calculable, and emit an error if it is not.



#### dotimes+  ✅
 `dotimes+` is the `+` variant.  It will throw a compiler error if it determines
that the `N` value is not uniform across the warp. 


#### caution
You must still exercise vigilance over the body of the loop. 
Inserting `if`, `when` or `cond` clauses can lead to branch divergence, 
where different threads in a workgroup take different execution paths. 
This will cause stalls and kill performance. 




### Looping Constructs ✅

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
- do-times-by-doubling
- do-times-by-multiply
- dec-times / dec-times+
- dec-times-by-half / dec-times-by-half+
- dec-times-by-factor / dec-times-by-factor+
- do-power-step
- dec-power-step

#### Immutable Index
All of the above bind a loop index. Unlike in a C++ `for` loop, that index value is immutable in the 
body of the loop.

#### + variants 📝
Most of the Looping Constructs have a variant whose name ends in `+`. 
The compiler will check that the target `N` is uniform across the workgroup. If the compiler
detects that it is not workgroup-level uniform, it will emit an error. 

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


Otherwise the compiler will check that both `a` and `b` are warp-level uniform. If they are, then their sum is as well and 
this will both compile just fine, but it'll execute quickly without stalling. But if the compiler
detects that this is not warp-level uniform it will emit an error.



#### dotimes / dotimes+  ⚠️
```
 (dotimes (i N:ulong &optional (stride:ulong 1)) 
    ...)
```
Binds `i` to 0, counts up to N, incrementing by `stride` each time through the loop. `stride` is optional, defaults to 1.

#### dec-times / dec-times+  📝
```
  (dec-times (i N:ulong &optional (stride:ulong 1))
    ...)
```
Binds `i` to `N-1` and counts down to `0`, subtracting `stride` each time through the loop. `stride` is optional, defaults to 1.
This is the opposite of `dotimes`


#### do-times-by-doubling / do-times-by-double+ 📝
```
  (do-times-by-doubling (i:ulong init:ulong N:ulong) 
   ...)
```
Binds `i` to `init`. Each time through the loop, `i` is doubled until
it reaches (or exceeds) `N`.  The last call will always have `i` bound to a value less than or equal to `N`.

Example: If `init` is 1 and `N` is 64: i => 1, 2, 4, 8, 16, 32, 64
Example: If `init` is 1 and `N` is 100: i => 1, 2, 4, 8, 16, 32, 64

#### do-times-by-multiply / do-times-by-multiply+  📝
```
  (do-times-by-multiply (i:ulong init:ulong N:ulong factor:ulong)
   ...)
```
Binds `i` to `init`. Each time through the loop, `i` is multiplied by `factor` until i reaches (or exceeds) `N`.  The last call will always have 
`i` bound to a value less than or equal to `N`.

The `factor` value must be greater than 1.

Example:  `init` is 1  `N` is 64 and the `factor` is 4:  i => 1, 4, 16, 64


#### dec-times-by-half / dec-times-by-half+  📝
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

#### dec-times-by-factor / dec-times-by-factor+ 📝
```
  (dec-times-by-factor (i:ulong N:ulong factor:ulong)
     ...)
```
`dec-times-by-factor` is a generalized version of `dec-times-by-half`.  This routine requires a third argument, the `factor`, which is a non-negative integer that must be greater than 1. 
(A `factor` of 2 will result in the same sequence as `dec-times-by-half`). 

`dec-times-by-factor+` requires that BOTH `N` and `factor` are `uniform` values. 

Binds `i` to `N`. Each time through the loop, i is divided by `factor` using integer division. 
The loop continues as long as `i` is greater than or equal to 1. `i` is never bound to 0.

Example #1:  `N` is 64 and the `factor` is 4:  i => 64, 16, 4, 1
Example #2:  `N` is 24 and the `factor` is 5:  i => 24, 4


#### do-power-step / do-power-step+ 📝

```
  (do-power-step (step-var:ulong limit:ulong) 
     ...)
```
`do-power-step` binds `step-var` to the powers of 2 up to `limit` (or the next power of 2 if it is not itself a power of 2).
The highest value `step-var` will have is half the "padded" limit.
For example, in `(do-power-step (i 100) ..)`, the limit of 100 gets rounded up to the next power of 2 which is 128.
This would then have seven steps, binding `i` in turn to 1, 2, 4, 8, 16, 32, and 64
The number of steps taken is `(log2 padded_limit)` ( aka `(log padded_limit 2)`)

##### possible implementation
```
;; -- do-power-step --
(defmacro do-power-step ((step-var limit) &body body)
  "Loops log2(padded_limit) times, where padded_limit is the next
   highest power of two from limit. Binds step-var to 1, 2, 4, 8..."
  (let ((d (gensym))
        (padded-limit (gensym)))
    `(let ((,padded-limit (next-power-of-2 ,limit)))
       (dotimes (,d (log2 ,padded-limit))
         (let ((,step-var (expt 2 ,d)))
           ,@body)))))
```


#### dec-power-step / dec-power-step+ 📝

```
  (dec-power-step (step-var:ulong limit:ulong) 
     ...)
```
The reverse of `do-power-step`, `dec-power-step` starts with `step-var` bound to half the padded limit and decremented until it is 1.
E.G. In `(dec-power-step (i 230) ...)` the limit of 230 would be raised to the next power of two, which is 256.
So `i` would be bound to 128, 64, 32, 16, 8, 4, 2, and 1. 

##### possible implementation
```
-- dec-power-step --
(defmacro dec-power-step ((step-var limit) &body body)
  "Loops log2(padded_limit) times, binding step-var to ..., 8, 4, 2, 1."
  (let ((d (gensym))
        (padded-limit (gensym)))
    `(let ((,padded-limit (next-power-of-2 ,limit)))
       (dec-times (,d (log2 ,padded-limit))
         (let ((,step-var (expt 2 ,d)))
           ,@body)))))
```


### Grid Level Operations ✅

Grid-level operations are primitives that orchestrate work across the entire grid of threads. A fundamental rule in Crisp is that 
a `progn` with a grid-level context CANNOT contain other grid level operations. (ie no nesting). Attempting to do so is a semantic error that leads to incorrect calculations, massively redundant work, and incomplete coverage of the problem space.

The following Crisp functions and macros are grid level operations, they either open grid level contexts or take
higher order function arguments that must be thread level (only) operations. 

- all `-stride` functions
- all grid-wide reduction variants ( `reduce-to-1-*`, `reduce-vec-*`)
- `filter`
- `convert-layout` 
- `when-is-last-workgroup`



#### `(declare (grid-level))` ✅

`grid-level` is a declaration that tells the compiler (and other users) that a particular `progn` is a grid level
context. If you are writing a `defmacro` that is doing grid level coordination, then be sure to include
this declaration in its expansion.

Look for these patterns in your macros:
- calls to `get_global_id()` or `get_global_linear_id()`
- using atomic operations on `:global` memory.
- calling OTHER grid level operations 

This declaration isn't just busywork. With it in place, the compiler will check your macros usage and ensure
that it isn't incorrectly nested or invoked by thread level functions. Otherwise it will almost certainly 
result in incorrect calculations and/or slow performance.

#### atomic ops

Atomic operations (see below) performed on `:global` memory are, by fiat, grid level operations. If your
`defmacro` uses any atomic operation on `:global` memory, be sure to `(declare (grid-level))`.  
Atomic operations on `:local` memory have no such requirement.

### Workgroup Level Operations ✅

Workgroup-level operations are a bit like grid-level, in that multiple threads are being coordinated in
the context of some `progn`, but the scope of coordination is limited to within a single workgroup.  
Workgroup level operations cannot be nested inside other workgroup-level operations, 
in this regard they are similar to grid level ops. But workgroup level
operations CAN be invoked in thread-level contexts (so long as that doesn't result in nested workgroup level contexts).

#### `(declare (workgroup-level))` ✅

`workgroup-level` is a declaration that tells the compiler (and other users) that a particular `progn` is a workgroup level
context. If you are writing a `defmacro` that is doing workgroup level coordination, then be sure to include
this declaration in its expansion.


### Barriers and Fences ✅

The golden rule of GPU programming is: if you have threads cooperating on a task and one thread writes a value that another thread needs to read, you must use a barrier. The logical pattern is always **Write -> Barrier -> Read**, regardless of whether it's one thread writing and many reading, or many threads writing and one reading.

#### sync-workgroup ✅
`(sync-workgroup)`
This routine inserts a local barrier. It ensures that all threads in the workgroup have reached the same location before continuing. This barrier includes a memory fence that guarantees all writes to local memory by threads in the workgroup are visible to all other threads in that same workgroup. Use it after you are done writing to shared local memory and before any other thread is expected to read from it. On CUDA it will map to `__syncthreads()` and on OpenCL to `barrier(CLK_LOCAL_MEM_FENCE)`.


#### sync-warp ✅

`(sync-warp)`
This routine inserts a warp-level barrier. It ensures that all threads within the same warp (or sub-group) have reached the exact same execution point before any of them proceed. This barrier includes a memory fence scoped specifically to the warp, guaranteeing that memory writes made by threads in the warp are visible to all other threads in that same warp. Use it when coordinating fine-grained data exchanges, register shuffles, or when preventing race conditions during warp-synchronous programming. On CUDA it will map to `__syncwarp()` and in SPIR-V to the sub-group equivalent, such as `sub_group_barrier`.

#### mem-fence ✅
(mem-fence &key local global)
This routine inserts a memory fence to enforce the ordering of memory operations. Unlike a barrier, a fence does not synchronize thread execution.

A fence guarantees that all writes to a memory space (e.g., :global) before the fence are visible to other threads before any reads or writes after the fence are executed by this thread. This is an advanced feature for preventing subtle race conditions in complex algorithms, especially those involving atomic operations or producer-consumer patterns between different workgroups.

On CUDA, (mem-fence :global) maps to __threadfence(). On OpenCL, it maps to mem_fence(CLK_GLOBAL_MEM_FENCE).

<!-- WHAT are the comparables for LevelZero? -->




### Sum a Vector using Local Memory ✅

Earlier we demonstrated a simple `vector_add` using grid strides. 
This example is slighly more complicated and uses several of the control flow 
constructs that have been covered so far.  

We can easily use multiple threads to stride through a vector summing it as they go. 
But if we have 1024 threads, we'll end up with a 1024 different sums that, in turn,
need to be summed.  

To then sum those up we COULD use a block of global memory that is 1024 element long.
Each thread could write its sum in it, and then one thread could sum them,
or it could be transferred back to the host and it could finish summing them. 
But this both takes a lot of memory and is the slowest type of memory. 
So we will not do that. 

Instead, we'll use two smaller scratch pads.  One is local memory that has the
same number of entries as the local_work_size of the kernel.  Local memory is fast, 
but limited to the threads in the same workgroup.  The second scratch pad
is global memory, and it is M entries wide, where M = NUM_THREADS / WORKGROUP_SIZE, 
or  M = global_work_size / local_work_size.  This the same as the number of workgroups.

The routine will use a tree reduce pattern so that half the threads in the workgroup 
add their sum to the comparable in the other half. And then repeat, halving the 
number of threads each time. This reduction is on the local scratchpad.

Lastly one thread in each work group writes its sum to the global scratchpad.

After this, we could use a global barrier and then sum that scratchpad.
But since the global scratchpad needs to be prepared by the host anyway,
it's simpler to just end the operation and enqueue a second operation to 
complete the sum.  Or sum it on the host, if that is your preference.

In our `sum_vector` routine, the host will supply the vector it wants
to be summed, plus the result vector (which is also that global scratchpad).
We could also have it provide the local scratchpad as a vector too. That 
would make the routine more flexible. But in this case, we are just
going to agree on a convention that the local_work_size is 64.



```
;; the result vector should be size M, where M = global_work_size / local_work_size
;; aka num-groups.
(def-type result-vec (vector long :align :compact :address-space :global :size (get-num-groups)) 

;; -- sum_vector_first_stage --
(def-kernel sum_vector_first_stage (A &out Res)
  ;; A can be any size, but Res should be num-groups
  (declare #'((in-vec long) => result-vec)) 
           (global-size :derive-from A :strategy :strided))
                                     
   (let ((sum 0))
     ;; Stride the vector, summing it up. Each thread has its own value in 'sum'
     (loop-vector-stride A (i)
        (inc! sum (~ A i)))
    
    ;; Prepare local memory and store sum in it. 
    (let ((slm (make-scratch-vector long :match-workgroup-size)))
      (in-each-thread-in-group (local-idx)
        (set! (~ slm local-idx) sum)
        
        ;; tree reduce
        (dec-times-by-half* (s (/ (get-local-size) 2))  s is 32, then 16, 8, 4, 2, 1
          (sync-workgroup)
          (when (< local-idx s)
            (inc! (~ slm local-idx) (~ slm (+ local-idx s))))))

      ;; move sums to global 
      (when-thread-in-group-is (0)
        (let ((wg-idx (get-workgroup-id 0)))
          (set! (~ Res wg-idx) (~ slm 0))))))) 
```

This example is provided so that you can see several "Crisp-ish" constructs used together, 
like the tree reduce `dec-time-by-half` and its `*` variant, the scratch vector creation 
all applied to the topic of a workgroup sized reduction using local memory and a local barrier. 

But, again, the vector is not fully summed. That'll require a second kernel pass. 
 The simplest solution there is to make another kernel that
employs `reduce-vec-second-stage` (see below) and then you'll have a two step solution. If you would
like to see the hoisting code in action, then use either a continuation kernel (see above) 
or  `def-orchestration` (see below).


### Warps & Shuffles 📝
Witchcraft.

The shuffle primitives are special hardware instructions that allow threads
within a single warp directly exchange register values with each other without 
using shared memory. They are very powerful and fast operations.

For most NVidia hardware there are at most 32 lanes in a single warp.  Very often workgroups
are BIGGER than a single warp, so plan your algorithm accordingly. shuffles work across warps, not 
workgroups. 

For some algorithms, setting the workgroup size to be the same as the maximum warp size makes
the algorithm easier to implement. But be careful if you do this, because multiple warps
in a workgroup take up slack whenever there is a stall accessing memory.  If your workgroup
has only one warp, that advantage is surrendered.  However, if you decide to use tha strategy then be sure the `local_work_size` used when enqueueing the kernel matches.  A `(local-size :set-to 32)` declaration with a nice message can help communicate that to whoever is developing
the hoisting.

### in-warp 📝
`(in-warp (<id-name>) ...)`
`in-warp` binds the thread's lane id to the `id-name` expression for the statements in its body.  

It is within the scope of an `in-warp` block that the various shuffle operations can occur. They cannot
be used otherwise. <!-- NOTE: I don't think this has to be true at all. Maybe? -->

<!-- IMPLEMENTATION NOTE
  CUDA:   unsigned int lane_id = threadIdx.x % 32;
  OpenCL: unsigned int lane_id = get_sub_group_local_id();
-->


#### shuffle 📝
`(shuffle <someVar> target-lane-id &optional (width (get-warp-size)))`
The `(shuffle ...)` expression evaluates to the current value of `someVar` as it is in another thread. 
THe target lane-id is provided directly to `shuffle`.

#### shuffle-up  / shuffle-down 📝
`(shuffle-up <someVar> delta &optional (width (get-warp-size)))`
`(shuffle-down <someVar> delta &optional (width (get-warp-size)))`
These expressions evaluate to the current value of `someVar` in a thread that is plus or minus `delta` lanes over.
Note that `-up` / `-down` do not necessarily have an intuitive interpretation. The direction is where the data 
is going to, rather than the operation performed with the delta. So `shuffle-up` SUBTRACTS `delta` from the current 
lane id and returns the value of `someVar` from that lower lane (ie, the data is shuffling "up" to our higher lane).
Meanwhile, `shuffle-down` ADDS `delta` to the current lane id and return the value of `someVar` from that higher
lane (ie, the data is shuffling "down" to us.) Whatever. 

#### shuffle-xor 📝
`(shuffle-xor <someVar> &optional lane-id-mask:ulong (width (get-warp-size)))`

Those other shuffle operations do cool tricks. But `shuffle-xor` is where real sorcery occurs.

The `(shuffle-xor ...)` expression evaluates to the current value of `someVar` as it is in one of the other threads.  
The target lane id is calculated by taking the current thread lane id and XOR-ing with the `lane-id-mask` argument.
`shuffle-xor` only needs to be given the name of the variable to fetch and the mask, it gets the current lane id automatically.  

`shuffle-xor` is very useful for tree reducing.  See the `sum_vector_warp` example below. 
The magic occurs in the interaction between the descending-by-half mask gotten from `dec-times-by-half` and `shuffle-xor`
This gives us a butterfly communication pattern, which allows all threads to contribute to a reduction in a logarithmic
number of steps.
```
(dec-times-by-half (s (/ (get-warp-size) 2)) ;;start the descent with half the warp size. ie 16 then 8, 4, 2, 1
        ... (shuffle-xor someVal s))
```


#### Ballot Operations 📝
The ballot primitives allow the warp to vote on a predicate.


##### warp-ballot 📝
`(warp-ballot predicate:bool) -> uint`
Returns a bitmask where the Nth bit is set if the Nth thread in the warp evaluated `predicate` to true.

Think of `warp-ballot` as a bitwise poll of the warp. Every thread passes in a boolean (the predicate). 
The hardware collects these booleans from all active threads simultaneously and packs 
them into a single 32-bit integer.
If Thread 0 says true, the 0th bit of the integer is 1.
If Thread 1 says false, the 1st bit of the integer is 0.

Each thread receives this same composite integer containing the votes of everyone in the warp.

This is a very useful operation often used in conjunction with the `popcount` bit operation. (See the Bit Twiddling section)

##### warp-any? / warp-all? 📝
`(warp-any? predicate:bool) -> bool`
`(warp-all? predicate:bool) -> bool`
Returns true if any (or all) active threads in the warp evaluate `predicate` to true. These are extremely fast hardware reductions.

#### Supported Types
The shuffle operations natively support 32-bit types (`int`, `uint`, `float`). 
Crisp will automatically decompose larger types (like `double`, vectors, or structs) into multiple 32-bit shuffle operations for you.

### Sum a Vector using Warps and Shuffles 📝

Would you like to calculate the sum of a vector without needing any local shared memory
and without needing any barriers? Just a drop of blood is all we need, use it to sign the
contract below. 

This version starts out the same as the last one. The grid stride legerdemain is used and 
each of the threads holds its own copy of a sum. Then, as before, we reduce. Half 
the warp uses a shuffle and an XOR mask to fetch the sum from another thread and add it.
Then half again, and so on. And then we  record the results into the same Result vector.

The result vector should be size M, where M = global_work_size / local_work_size.
This is the same size as the number of workgroups.

Note that this version ties the workgroup size to the size of a single warp. 
Doing so might limit the "latency hiding" opportunities, because there are no "extra" warps
 to fill in if this one stalls on a memory access.  But that potential performance
penalty is offset by the use of shuffles, instead of local memory and barriers.
Shuffles, if used correctly, are wicked fast, but they can't reach outside a single warp.

This version of vector summing is likely faster than the last one.

```
;; 32 warps maximum for most hardware
(def-constant +warp-size+ 32ul)

;; the source vector can be any size. 
(def-type source-vec (in-vec long :compact))    

;; the result vector should be size M, where M = global_work_size / local_work_size
;; aka num-groups
(def-type result-vec (vector long :align :compact :address-space :global :size (get-num-groups)))  

;; -- calculate-this-thread-sum --
(def-function calculate-this-thread-sum (A)
  (declare #(source-vec -> long))
  (let ((sum 0))
    (loop-vector-stride A (i)
      (inc! sum (~ A i))))) ; <-- inc! implicity returns final sum


;; -- sum_vector_warp_first_stage --
(def-kernel sum_vector_warp_first_stage (A Res)
    (declare #'(source-vec result-vec => nil)
             (local-size :set-to +warp-size+ :msg "this kernel requires the local work size to be the same as the warp size") 
             (global-size :derive-from A :strategy :strided))
  ;; Stride the vector, summing it up. Each thread has its own value in 'sum'
  (let ((sum (calculate-this-thread-sum A)))
     ;;  Reduce 
    (in-warp (lane-id)
      ;; this reduction uses `s` from `dec-times-by-half` to bisect/reduce. The `lane-id` is unused.
      (dec-times-by-half+ (s (/ +warp-size+ 2))
         (inc! sum (shuffle-xor sum s))))
    
    ;; move sum to global
    (when-thread-in-group-is (0)
      (let ((wg-idx (get-workgroup-id 0)))
          (set! (~ Res wg-idx) sum)))))   
      
```

Like the previous sum_vector demonstration, this example is provided so that you can see
 "Crisp-ish" constructs used together, this time with shuffles and warps. 
The vector is not fully summed. That requires a second kernel pass. 
Most expedient is to make another kernel that
employs `reduce-vec-second-stage` (see below) and then you'll have a two step solution. If you would
like to see the hoisting code in action, then use either a continuation kernel (see above) 
or  `def-orchestration` (see below).

## Bit Twiddling Operations 📝

### `op-popcount` 📝
`(op-popcount uint) => uint`

`op-popcount` counts the number of set bits in a binary integer.
```
(op-popcount 3) -> (op-popcount  #b00000011) -> 2
(op-popcount 255) -> (op-popcount #b11111111) -> 8
(op-popcount #xAA) -> (op-popcount #b10101010) -> 4
```
`op-popcount` is the engine of parallel prefix sums on bitmasks. When you combine `warp-ballot` (which gives you a bitmask of "who is active") with popcount (which tells you "how many people are active"), you can calculate offsets and indices in constant time without loops.

### `op-count-leading-zeros` / `op-count-trailing-zeros` 📝
`op-count-leading-zeros` returns the number of zero bits before the first 1 bit in a `uint`.
This can be very handy for finding the index of the first active thread in a ballot mask. 

`op-count-trailing-zeros` returnst the number of zero bits after the last 1 bit in a `uint`.

In hardware these get mapped to `CLZ` and `CTZ`

```
(op-count-leading-zeros #b00000011) -> 6
(op-count-trailing-zeros #b10101010) -> 1
```

### `op-find-msb` / `op-find-lsb` 📝
`op-find-msb` returns the *index* (0-31) of the most significant bit set.
Note: This is NOT the same as `op-count-leading-zeros`.
It is calculated as `31 - clz(value)`.

`op-find-lsb` is exactly the same as `op-count-trailing-zeros` above, and it will 
 sometimes get mapped to `CTZ` on hardware.

```
(op-find-msb #b00001100) -> 3
(op-find-lsb #b00001100) -> 2
```


### `op-bit-reverse` 📝
Reverses the bits in a 32-bit integer.
```
(op-bit-reverse #xFFFF0000) -> #x0000FFFF
```

### `op-bitfield-extract` / `op-bitfield-insert` 📝
These two operations are precision tools for slicing and splicing bits within an integer. They are incredibly useful for packing multiple small values (like 5-bit, 6-bit, or 10-bit numbers) into a single 32-bit integer without messy shifting and masking math.

`(op-bitfield-extract value offset bits) -> uint`

`op-bitfield-extract` grabs a specific sequence of bits from `value`, starting at 
`offset` and taking `bits` number of them, returns that sequence as a new integer (right-aligned).

Like `substring` but for bits.


`(op-bitfield-insert base insert offset bits) -> uint`
`op-bitfield-insert` takes a `base` integer and replaces a chunk of its bits with
the first `bits` from the `insert` value, starting at `offset`. 

#### Example: update RGB565

This example is a bit contrived, but it shows how `op-bitfield-insert` 
could be used.
```
(let ((packed-color #b1111100000011111)
      (green        #b0000000000111111))
  (declare (type packed-color green short))
  (op-bitfield-insert packed-color green 5 6)
  ;; NOW packed-color is #b1111111111111111 )
```





## Hardware Bit Packing / Unpacking 📝

Modern GPU hardware has built-in intrinsic functions which can quickly pack and unpack values out
of bitfields, sometimes with a loss of accuracy. If you expect to read or store these values
from a vector or tensor exactly once then the best practice would be use Crisp derived types and 
custom getter/setter functions. See the example for `op-pack-11` below.

### `op-pack-11` / `op-unpack-11` 📝
Take three floats and store them in 32 bits by converting two of them to 11 bit floats and the third
to a 10 bit float.  Unpacking them to normal 4-byte floats for operations

```
(op-pack-11 float-1 float-2 float-3) => uint
(op-unpack-11 uint) => float-1 float-2 float-3
```

#### Best Practice

Rather than passing a vector of `uint` around, use `def-derived-type` to
define your own type and do the packing in the setters and getters.

```
(def-derived-type my-HSL-vec (vector uint :align :compact) :subst :no)

(def-function ~ (vec index)
   (declare #'(my-HSL-vec uint => float float float))
   (op-unpack-11 (~ vec index)))


(def-setter ~ (vec index f1 f2 f3)
   (declare #'(my-HSL-vec uint float float float => nil))
   (set! (~ vec index) (op-pack-11 f1 f2 f3))))


(def-kernel distort (hsl-scene)
  (declare (type hsl-scene my-HSL-vec))
  (loop-vector-stride hsl-scene (i)
    (let ((hue sat light (~ hsl-scene i)))
      ;; note - can someone tell me what this does? I bet it's not good.
      ;; but, hey, it's coalesced access. So who cares? 
      (inc! hue .3)
      (dec! sat .2)
      (inc! light .1)
      (set! (~ hsl-scene i) hue sat light))))
```

### `op-pack-half-2x16` / `op-unpack-half-2x16` 📝

```
(op-pack-half-2x16 float float) => uint
(op-unpack-half-2x16 uint) => float float
```
- What it does: Packs two 32-bit floats into two 16-bit floats (half precision) inside a single `uint`.
- Use case: Storing UV coordinates, normals, or colors where 32-bit precision is overkill but 8-bit is too low. This is probably the most widely used packing op after 8-bit color.

Obviously, if you are using `half` you don't need this, you can just bit-shift and cast.

### `op-pack-unorm-4x8` / `op-unpack-unorm-4x8` 📝
```
(op-pack-unorm-4x8 float float float float) => uint
(op-unpack-unorm-4x8 uint) => float float float float
```
- What it does: Packs four 32-bit floats (clamped to 0.0-1.0 range) into four 8-bit unsigned integers inside a single `uint`.
- Use case: Standard RGBA8 color data. This handles the float-to-int conversion and packing in one fast hardware instruction.

### `op-pack-snorm-4x8` / `op-unpack-snorm-4x8` 📝
```
(op-pack-snorm-4x8 float float float float) => uint
(op-unpack-snorm-4x8 uint) => float float float float
```
- What it does: Same as above, but for SIGNED normalized values (-1.0 to 1.0).
- Use case: Storing normals (nx, ny, nz) or vectors in 8-bit precision.

### `op-pack-unorm-2x16` / `op-unpack-unorm-2x16` 📝
```
(op-pack-unorm-2x16 float float) => uint
(op-unpack-unorm-2x16 uint) => float float
```
- What it does: Takes two 32-bit floats (0.0-1.0), converts them to 16-bit unsigned integers, and packs them into one 32 bit `uint`
- Use case: High-precision texture coordinates or depth values.

### `op-pack-double-2x32` / `op-unpack-double-2x32` 📝
```
(op-pack-double-2x32 uint uint) => double
(op-unpack-double-2x32 double) => uint uint
```
- What it does: Packs two 32-bit unsigned integers into a single 64-bit double.
- Use case: Mostly for passing 64-bit data through pipelines that might be restricted to 32-bit registers, or bit-casting.

<!--

These are used fairly common in shaders, but there is usually no hardware level unpacker for them.

Plus, the "shared exponent" thing makes them more akin to the microfloat-blocks.  

If we wanted to provide unpacking, we'd have to do it ourselves, likely with no hardware acceleration.

For that reason, I'm keeping this out of the spec until later.

### `op-pack-rgb-9e5` (Shared Exponent)  Pack only.
- What it does: Packs three floats into a 32-bit integer using a shared 5-bit exponent for all three channels.
- Use case: HDR lighting/color. It has no sign bit (positive only) but handles large dynamic ranges better than standard fixed-point. It is often an alternative to the `11-11-10` format of `op-pack-11`


-->

## Branching ⚠️

Crisp has the same four basic branching expressions as Common Lisp: `if` , `when`, `unless`, and `cond`

They each operate similarly: first evalute a predicate expression, and if true, then execute 
some consequent. With variations for multiple checks, multiple statements, etc.  
( `unless` checks the predicate for being `false`, not `true`).

#### `cond` default ✅
The default case for `cond` is not `T` like it is in Common Lisp. That would be too confusing 
with the very common `T` used for templating.  Instead in Crisp, `cond` uses `else` as the default case.

#### + variant ✅
The `+` variant checks that the predicate expression is uniform across the entire warp. If the compiler
detects that it is not, it will emit an error. This variant is EXTREMELY USEFUL when developing 
high performance non-diverging code. 


<!-- 

ANAPHORIC VARIANTS MOST LIKELY TO BE DROPPED 

#### `it` - anaphoric
All the branching expressions (except `unless`) are "anaphoric", which is a linguistic concept to describe a word that acts as a substitute for an earlier expression.
For example "The cat chased the mouse, but it got away", the word "it" is an anaphoric reference to the mouse.
Whatever.

In Crisp, `it` is the name of a variable that is automatically created in the scope of the consequent of any `if`, `when` or `cond` clause, or their variants.
`it` holds the value of the predicate expression so you don't have to stash it earlier or call it again.
A simple example should explain everything:

```
(when (length someVector)  ; <-- 'it' is now bound to that length
   (set! somethingElse it))
```
Of course this works if the vector length was non-zero. If it was zero, the consequent would be skipped entirely.
Note that THIS may not work as expected:
```
(when (> (length someVector) 0)   ; `it` is now bound to `T` the result of the `>` comparison
  (set! somethingElse it))
```

-->

### Cost of Divergent Branching

Examine the following simple example:
```
   (if (should-we-do-it? a)
     (do-it a)
    (do-something-else a))
```
Let's pretend `do-it` is expensive and takes 10 seconds of wall clock time to complete.  Similary, `do-something-else` is expensive and takes 10 seconds.

So how long does the entire expression take?  The answer is surprising.  
On a CPU, we have to perform one or the other, but not both, so the answer is 10 seconds.
On a GPU the answer depends on whether the threads diverge or not.  If `should-we-do-it?` is true for all the threads in a workgroup
then the answer is the same as the CPU: 10 seconds.  But if `should-we-do-it?` is different for even just one of the threads in the workgroup, 
then the answer is 20 seconds. The first set of threads excute `do-it` while one thread waits stalled. Then all the other threads are STALLED while
one thread preforms `do-something-else`.  So our workgroup takes 20 seconds. The branches do not run independently.

If the result of `(should-we-do-it? a)` were captured in a variable and forced to be uniform with `to-uniform`, then we'd guarantee that it would take only 10 seconds, and there would be no stalling. This is because it would not diverge in a workgroup. Of course, that
might not be appropriate for some problem sets. But you can see where it is obviously superior to structure your problem so that it CAN 
take advantage of such an optimization. 


### Predicated Selection 📝

Because the cost of branch divergence is so high, it is often just preferable to evaluate BOTH the consequent and alternative and
select the correct one in response to a predicate. That what `select-if` is for. Use it with simple values for `<expr-A>` and `<expr-B>` 
and you'll be fine. 

`(let ((v (select-if <predicate-expr> <expr-A> <expr-B>))))  ; BOTH expr-A and expr-B will be evaluated/executed. `

This does NOT have shortcut evaluation like in C++.  Recommend that `<expr-A>` and `<expr-B>` be simple.

There is no uniform `+` or `*` variant for `select-if`.

<!-- NOTE: how is this actually realized on a GPU -->


## Higher Order Function Operations ✅

### Compile Time Resolution ✅

Crisp does not support "true" higher order functions. Doing so would introduce too much divergence,
which would destory performance.

Instead, all higher order function usages must be resolveable at compile time.

The flip side benefit of this is that expressions like this:
```
(map-stride #'op-fma (A-vec B-vec C-vec) RES-vec)
```
are possible to express AND and are performant. There is no actual "function call" to `op-fma`. 

#### Runtime Function Variables forbidden

While it is possible to assign a variable to a #'function, the restrictions on compile time resolveable 
are still in place. 

For example, this will result in a compile error if `someExpr` is not determinable by the compiler to be compile time constant.
```
(let ((f (if someExpr #'+ #'-)))  ...)
```
If that was the intention, then these would work
```
(let ((f (if+ someExpr #'+ #'-)))  ...)
; OR
(let ((someExpr ...)
      (f (if someExpr #'+ #'-)))
  (declare (constexpr someExr)) ...)
```

### Lambda No, Curry Yes 📝
Because the GPU has only one callstack per warp (not one per thread), lambda functions are 
not supported. This is because they enable lexical closures (capturing variables from their surrounding scope),
 which would add significant complexity to the kernel's memory model and is 
 difficult to map efficiently to GPU hardware.  
The Common Lisp `labels` macro is similarly not supported for this same reason.

#### `curry` 📝

```
(curry #'someFunction <uniform-arg0> ...)
```

But a limited form of "currying" IS available.  
The `curry` form takes a function of N arguments as its first arg, followed by M uniform args where 
M <= N. It returns a new function that accepts (N-M) arguments and can be passed to other HOF functions.

By "uniform" we mean that the argument binding values that are accepted by the `curry` form MUST
be uniform across the entire workgroup.  Thus, they either must originate in the kernel parameter list,
be declared `uniform`, forced to be uniform with `to-uniform`, etc. If crossing function calls, the compiler
will check up through the call chain to make sure that it can verify that these captures to `curry` are, in fact,
uniform. This particular compiler check will 
be deferred for library functions marked as `entrypoint` BUT the requirement remains and will be enforced
when the call-chain ends up underneath a kernel.  This requirement is so capturing them doesn't introduce divergence or the complexities of capturing thread-local state

The example in the next section shows `curry` in action.

<!--
Implementation Notes
for transpilation, create a new uniquely named inline C function that takes each capture as an arg, PLUS the expected arg
and use that instead of original 
-->

#### `compose` 📝

```
(compose #'secondFunction #'firstFunction) => #'combinedFunction
```

`compose` combines to functions. For `firstFunction` whose type is `#'(T => U)` 
and `secondFunction` whose type is `#'(U => Z)`  a new function is returned that 
performs both, first calling  `firstFunction`, then followed by `secondFunction` on its output. It's type is `#'(T => Z)`.
In C++ parlance the resulting function performs `secondFunction(firstFunction(x))` . 


In the example below, we wish to use the `filter` function which takes a predicate that maps `T` to `bool`.  (ie  `#'(T => bool)` )
But we want to use `lookup`, which takes TWO arguments, not one.   We can use the `curry` form
to create a new function `lookup-ref` .  But we want to filter if the reference is even,
so we use `compose` to combine the lookup with the check for even number.

```
(def-function lookup (someVec i)
   (~ someVec i))

(def-kernel cross_table (inputVec referenceVec &out outputVec matchCount)
  (declare #'((in-vec long) (in-vec long) &out (out-vec long) (cell ulong) => nil))
  (let ((lookup-ref (curry #'lookup referenceVec))
        (lookup-even? (compose #'is-even? lookup-ref))
        (count (filter inputVec lookup-even? outputVec)))
    (set-result! matchCount count)))


```

#### `ident` 📝

```
(ident x) => f where f(anything) => x
```

Given a value `x`, the `ident` function returns another function that, given any value
returns the original `x`. 

Note: This obeys the Compile Time Resolution rule. The compiler treats `(ident x)` 
not as a dynamic function pointer, but as a direct reference to the variable `x` 
inside the target scope. It is fully inlined and zero-overhead.

### map 📝

#### map-stride 📝
`map-stride` uses Grid Stride to visit every element of some source vector or tensor and pass it
as an argument to a provided function, and then store it at the same position in some destination vector or tensor.

```
(map-stride #'someFunc (A) Z)   
```
Requirements:
- `someFunc` has the signature `#((element-type A) => (element-type Z))`
- `A` and `Z` are a  `vector`  or `tensor`
- `A` and `Z` have the same dimensions.
- `A` is `readable` and `Z` is `writeable`

`map-stride` can accept multiple sources, and/or multiple destinations, so long as the signature
of `someFunc` accepts the matching number of parameters and/or returns the matching number of values.
The additional source or destinations have the same requirements as above (same dimensions, etc)
```
(map-stride #'someFunc (A0 .. An) Z0 ... Zm)
```

Example:
```
;; simplest vector_add
(map-stride #'+ (A B) C)

;; function returning multiple values used

;; -- analyze --
(def-function analyze (v)
  (declare #'(ulong => bool bool))
  (return (is-even? v) (appears-in-fibonacci? v)))
...
(map-stride #'analyze (A) EvenAnalysis FibAnalysis)
```



### Invoking Functions: `funcall` ✅

Crisp follows the Common Lisp tradition (Lisp-2) regarding function application. This means that variables and functions occupy separate namespaces.

If a variable `f` holds a function (or a compile-time resolvable entity like an `ident` or `curry` result), you cannot simply invoke it as `(f x y)`. You must use `funcall`.

```lisp
;; CORRECT
(let ((op #'+))
  (funcall op 10 20))

;; INCORRECT - Compilation Error
(let ((op #'+))
  (op 10 20))
```

#### Why `funcall`?

- Namespace Hygiene: In GPU kernels, it is extremely common to use variable names like `min`, `max`, `count`, `width`, or `index`. In a Lisp-1 (Scheme-style) language, defining a local variable named `min` would shadow the global `min` function, making it impossible to calculate a minimum value within that scope. 

- Compiler Signaling: `funcall` serves as an explicit signal to the compiler: *"The target of this call is held in a variable; please trace its origin and specialize this call site."* This makes it easier for the compiler to perform the necessary Template Instantiation and inlining required for zero-cost abstractions, distinguishing these cases from static calls to global functions.

#### Compile-Time Resolution Still Applies

The use of `funcall` does NOT imply dynamic runtime dispatch. The restriction that all functions must be resolvable at compile-time remains in effect. The compiler uses `funcall` as the insertion point for the specialized, inlined logic derived from the variable's definition.


## Shop Local, Act Global

A VERY common practice among GPU algorithm writers is "shop local, act global". In this
practice a small amount of local memory (usually one cell per workgroup thread) is operated
upon by the workgroup, and then one leader thread from the work group performs some 
operation that touches global memory (like an atomic operation).

We will see this practice over and over and over.  The reductions do it, the filter and scans,
the sorting, and more.  Crisp usually provides very useful reusable macros for the workgroup level,
and ready-to-go routines that employ them at the global level. 


## Reduce Variants 📝

Crisp provide several choices and building blocks for reductions. There are "shop local" variants that perform
quick efficient reductions at the warp or workgroup level. And there are also some Single Pass grid level
routines that first "shop local" using the warp or workgroup routines and then "act global"
to gather up the results of the reduction across the different workgroups.

This first set of reductions reduce a variable ( `<someVar>` ) with a commutative operation ( `someFunction`)
across threads (of a warp, of a workgroup, or all)

- reduce-to-warp
- reduce-to-workgroup
- reduce-to-1-second-stage
- reduce-to-1-atomic
- reduce-to-1-cas
- reduce-to-1-cont

The second set of reductions reduce a vector, with various techniques. They employ
grid strides however, which means you'll want to declare `:strategy :strided` if you use them in your own
functions/kernels.

- reduce-vec-first-stage
- reduce-vec-second-stage
- reduce-vec-warp
- reduce-vec-atomic
- reduce-vec-cas
- reduce-vec-cont

Note that the `XXXX-atomic` and `XXXX-cas` variants are Single Pass variants that require only one
kernel to complete their calculation, though they use atomics which may have performance earmarks.
The `XXXX-cont` variation is single construct that uses kernel continuations, so they are "two pass"
solutions.  The `XXXX-second-stage` is a small "sweep up and finish" construct that completes a "first stage" of 
some reduction.  For vectors that "first stage" is `reduce-vec-first-stage`.  For variables, the first
stage would be `reduce-to-workgroup`.  Note that `reduce-to-workgoup` is a VERY useful workhorse
and is used by many of the other reductions. Lastly `reduce-to-warp` is a thread level operation 
that is special case and very fast. It is used by `reduce-to-workgroup`. 


#### optional scratch vector arguments.

Some of the reduce functions accept `&optional` arguments for local and global scratch vectors.  
These vectors are consistently sized relative the warp, workgroup and global thread count. 
If not provided Crisp will generate the scratch memory for you.



#### reduce-to-warp 📝

`(reduce-to-warp someFunction <someVar> identity &optional (active-threads (get-warp-size)) )`

`reduce-to-warp` is a macro that applies `someFunction` to `<someVar>` expression in the current thread and another thread in
the same warp. It does this iteratively until all the threads in the warp whose id is less than `active-threads`
 have been reduced. At the culmination of this operation, each warp will have `someVar` set to the final reduction value in each thread of that warp.   Note that using a value for `active-threads` that is GREATER than the warp size for the GPU hardware
 is undefined behavior. This reduction cannot reduce more than `+warp-size+` threads.

`reduce-to-warp` achieves its reduction using shuffles and `dec-times-by-half+` without using barriers or local memory. 
It is extremely fast. But it is limited to just one warp. The kernel could `(declare (local-size :set-to 32))` where 32 is max thread count per warp for most GPUs, 
and this is a good fit for many problems. But a workgroup that consists of multiple warps is often better
 because if one warp needs to pause while it fetches memory, another warp can be run in its stead - but this only happens within a single workgroup. Note that while `reduce-to-warp` does coordinate other threads at the warp level, it is NOT
 a grid level operation can be used in a wide variety of situations and applications.

- `someFunction` is a `binop-type`, meaning it has type `#(T T => T)` where `T` is the type of `<someVar>`
- After completion `<someVar>` in all the threads of the warp will be bound to the final value of the reduction.
- `reduce-to-warp` returns nil. 



The example below will output "warp total: 640" repeatedly, once for each warp, assuming 32 threads per warp and each warp fully occupied. 
```
(let ((someVar  20))
  (reduce-to-warp #'+ someVar)
  (when-thread-in-warp-is 0
    (r-t-output "warp total: " someVar)))  ;; => "warp total: 640"     
```

Possible Implementation:

```
;; -- reduce-to-warp --
(defmacro reduce-to-warp (someFunction someVar identity  &optional (active-threads (get-warp-size)))
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  `(in-warp (lane-id)
    (declare (warp-convergent)) ;; <-- tells compiler cannot be called in divergent branch.
    ;; Active threads use their value. Inactive threads use the identity.
    (let ((val (if (< lane-id ,active-threads)
                    ,someVar
                    ,identity)))

      ;; Perform the full, unconditional reduction on 'val'.
      ;; The loop bounds are always based on the full warp size.
      (dec-times-by-half+ (s (/ (get-warp-size) 2))
        (set! val (funcall ,someFunction (shuffle-xor val s) val)))

      ;; Write the final result (from lane 0) back into someVar for all threads.
      (set! ,someVar (shuffle val 0)))))
```



#### reduce-to-workgroup 📝

`(reduce-to-workgroup someFunction <someVar> identity &key return-vec local-scratch-vec message )`

`reduce-to-workgroup` is very useful workhorse construct.  It applies the reduction across all threads and results
in each the 0 thread of each workgroup having the final reduction (and optionally storing it in `return-vec`).
Functionally, `reduce-to-workgroup` is much the same as `reduce-to-warp` but it reduces all the threads in the workgroup, not just in the warp.  The value `<someVar>` will be `uniform` at the completion of this operation.
In addition to `someFunction` , `<someVar>` and `identity` it also accepts two `&key` arguments.

Like `reduce-to-warp` this is NOT a grid level operation and it can be used in a wide variety of contexts and situations.

##### return-vec
The `:return-vec` is a vector that will store the return results (if desired).  This is a vector of the same
element type as `<someVar>`. Its address space MUST be `:global` and it's size is the number of workgroups 
which can be calculated as `M` where `M = global_work_size / local_work_size`.   
If the `:return-vec` is not provided, the result is not preserved in memory. But after `reduce-to-workgroup` 
finishes, `<someVar>` will be the result of the reduction in its same workgroup. So it is usable if your
next operations can be performed within the workgroup.

##### local-scratch-vec
The `:local-scratch-vec` key.  If not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / (get-warp-size)` ). `(get-warp-size)` is usualy 32. 

##### message
The `:message` will be applied to the creation of the `:local-scratch-vec` if Crisp is generating it on your
behalf.  This can help inform the hoisting code for what the extra scratch memory is needed.


- After completion `<someVar>` in all the threads of the workgroup will be bound to the final value of the reduction.
- `:return-vec` (if provided) will store the results of each individual workgroup's reduction.
- The state of `localScratchVec` is indeterminant 
- `reduce-to-workgroup` returns nil.

Possible Implementation
```
;; -- reduce-to-workgroup --
(defmacro reduce-to-workgroup (someFunction someVar identity &key message 
                                                             (local-scratch-vec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup :msg message))
                                                             return-vec)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (if return-vec (is-type-of (element-type return-vec) (type-of someVar)) T) "type mismatch of return-vec and someVar")

  `(progn
    ; After this local-scratch-vec contains partial sum from each warp in the wg
    (declare (workgroup-level))
    (reduce-to-warp ,someFunction ,someVar ,identity)
    (when-thread-in-warp-is 0
      (set! (~ ,local-scratch-vec (get-warp-id)) ,someVar))
    (sync-workgroup)

    ; inter warp reduction
    (let ((num-warps (ceil (get-local-work-size) (get-warp-size)))
          (local-id (get-local-id)))
        ; Only a subset of threads needed for this phase.
        (when (< local-id num-warps)
          ; The loop iterates s => num_warps/2, num_warps/4, ... , 1
          (dec-times-by-half (s (floor num-warps 2))
            ; The first 's' threads are active in this pass.
            (when (< local-id s)
              (let ((partner-idx (+ local-id s)))
                ; Each active thread combines its value with its partner's.
                (set! (~ ,local-scratch-vec local-id)
                      (funcall ,someFunction
                              (~ ,local-scratch-vec local-id)
                              (~ ,local-scratch-vec partner-idx))))))
          ; barrier needed between each pass 
          (sync-workgroup)))

      ; The final result is in local-scratch-vec[0]. Load it to thread 0
      (when-thread-in-group-is 0
        (set! ,someVar (~ ,local-scratch-vec 0))
        (when ,return-vec (set! (~ ,return-vec (get-group-id)) ,someVar)))
      ; broadcast to entire workgroup
      (when-thread-in-group-is 0
        (set! (~ ,local-scratch-vec 0) ,someVar))
      (sync-workgroup)
      (set! ,someVar (~ ,local-scratch-vec 0))))

      ;; add (declare (uniform ,someVar)) ??  

```

#### reduce-to-1-second-stage 📝

`(reduce-to-1-second-stage someFunction <someVar> identity &out final-result &optional localScratchVec globalScratchVec)`

`reduce-to-1-second-stage` is much the same as `reduce-to-workgroup` but reduces all threads in all workgroups down to one single value.
That value will be stored in `final-result` which is a `single-result`.  `someVar` will also be correctly set in the very last workgroup,
but not other workgroups which will hold intermediate values. 

Also this routing has a restriction in that the number of workgroups MUST NOT BE greater than `local_work_size`.  If this is
violated, this routine will runtime assert. However, remember that runtime asserts are only observable when 
the debug logging option has been elected when compiling. 

##### optional scratch vectors
This routine accepts two optional arguments.  `localScratchVec` and `globalScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector`  that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / (get-warp-size)` ). `(get-warp-size)` is usualy 32.

`reduce-to-1-second-stage` also accepts an optional `globalScratchVec`. Crisp will generate it for you if you do not provide it.  
If you want to provide it yourself, it should be a `vector` whose `element-type` is the same as `<someVar>` , 
its address space MUST be `:global` and it's size is the number of workgroups 
which can be calculated as `M` where `M = global_work_size / local_work_size`. 


- After the operation completes, the state of both `localScratchVec` and `globalScratchVec` are indeterminant. 
- `reduce-to-1-second-stage` returns nil.
- `<someVar>` in thread 0 of workgroup 0 will hold the final value of the reduction
              this is the same as global linear thread id of 0.
              Its value is indeterminant in OTHER threads.
- `final-result` will hold the final result of the reduction.

```
(let ((someVar (some-calculation ...)))
   (reduce-to-1-second-stage #'+ someVar 0 output-single)
```

Possible Implementation
```
;; -- reduce-to-1-second-stage -- 
(defmacro reduce-to-1-second-stage (someFunction someVar identity out-single 
                                    &optional (localScratchVec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup :msg message))
                                              (globalScratchVec (make-scratch-vector (type-of someVar) :match-num-workgroups :address-space :global :msg message))
                                    &key message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  `(progn
    (declare (grid-level) (num-groups :max :local-size))
    (r-t-assert-0 (<= (get-num-groups) (get-local-work-size)) "number of groups cannot be larger than local_work_size for reduce-to-1-second-stage")

    ; after this the globalScratchVec will one value per group.
    (reduce-to-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,localScratchVec :return-vec ,globalScratchVec)
    

    ; inter thread reduction.  Easiest and fastest if it fits in one warp,
    ; or one workgroup.
    (when-is-last-workgroup ()
      (let ((N (length~ ,globalScratchVec))
            (l-w-s (get-local-work-size)))
        (declare (uniform N l-w-s))
        (cond*  ((< N (get-warp-size))
                  (let ((lane-id (get-lane-id))
                        (var (if (< lane-id N) (~ ,globalScratchVec lane-id) ,identity)))
                    (reduce-to-warp ,someFunction var ,identity N)
                    ; Broadcast to all threads in wg
                    (when-thread-in-group-is 0
                      (set! (~ ,localScratchVec 0) var))
                    (sync-workgroup)
                    (set! ,someVar (~ ,localScratchVec 0))))
                ((< N l-w-s)
                  (let ((local-id (get-local-id))
                        (var (if (< local-id N) (~ ,globalScratchVec local-id) ,identity))))
                    (reduce-to-workgroup ,someFunction var ,identity :local-scratch-vec ,localScratchVec)
                    (set! ,someVar var)))
        (set-result! ,out-single ,someVar)))))
                    
```

#### reduce-to-1-atomic 📝

`(reduce-to-1-atomic someFunction <someVar> identity &out return-vec &optional localScratchVec)`

`reduce-to-1-atomic` is a reduction of a variable like the others, but it is a single pass operation.
No "second stage" kernel is needed.  It reduces all threads in all workgroups down to one single value.
That value is stored in `return-vec` which is a required argument. It should be a vector of length 1 (ie, a `single-result`)

Unlike `reduce-to-1-second-stage`, `reduce-to-1-atomic` can work across all threads and is not constrained by workgroup sizes.  
Instead `reduce-to-1-atomic` has a different limitation: `someFunction` must be one of three commutative operations: `+`, `min` or `max`
that have `atomic-XXXX!` counterparts.

- `#'+`
- `#'min`
- `#'max`

It is a compilation error to use it with any other operation. 

##### optional scratch vector
This routine accepts an optional scratch vector argument  `localScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / (get-warp-size)` ). `(get-warp-size)` is usualy 32.


- After the operation completes, the state of `localScratchVec` is indeterminant. 
- `reduce-to-1-atomic` returns nil.
- After the operation the value of  `<someVar>` in any thread is indeterminant.
- `result-vec` will hold the value of the reduction.


Possible Implementation
```
;; -- reduce-to-1-atomic --
(defmacro reduce-to-1-atomic (someFunction someVar identity return-vec
                              &optional (localScratchVec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup :msg message))
                              &key message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (is-type-of someVar (element-type return-vec)) "type mismatch between someVar and return-vec")
  (c-t-assert (or (= someFunction #'+) (= someFunction #'min) (= someFunction #'max)) "only #'+, #'min or #'max are accepted operations for reduce-to-1-atomic")

  `(let ((atomic-op (get-atomic-equivalent ,someFunction)))
     (declare (grid-level))
    ; after this the globalScratchVec will one value per group.
    (reduce-to-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,localScratchVec)

    ; atomic combination
    (when-thread-in-group-is 0
      (funcall atomic-op (~ ,return-vec 0) ,someVar)))) 
```

#### reduce-to-1-cas 📝

`(reduce-to-1-cas someFunction <someVar> identity &out return-vec  &optional localScratchVec)`

`reduce-to-1-cas` is a reduction of a variable like the others, but it is a single pass operation.
No "second stage" kernel is needed.  It reduces all threads in all workgroups down to one single value.
That value is stored in `return-vec` which is a required argument. It should be a vector of length 1 (ie, a `single-result`)

Unlike `reduce-to-1-atomic` , which only works with a few operations, `reduce-to-1-cas` can work with ANY commutative binary operation.
It does this via atomic compare and swap (via `atomic-binop!`) which, while flexible, might not always be the most performant solution.


##### optional scratch vector
This routine accepts an optional scratch vector argument  `localScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / (get-warp-size)` ). `(get-warp-size)` is usualy 32.


- After the operation completes, the state of `localScratchVec` is indeterminant. 
- `reduce-to-1-cas` returns nil.
- After the operation the value of  `<someVar>` in any thread is indeterminant.
- `result-vec` will hold the value of the reduction.



Possible Implementation
```
;; -- reduce-to-1-cas --
(defmacro reduce-to-1-cas (someFunction someVar identity return-vec
                              &optional (localScratchVec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup :msg message))
                              &key message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (is-type-of someVar (element-type return-vec)) "type mismatch between someVar and return-vec")
  `(progn
    (declare (grid-level))
    ; after this the globalScratchVec will one value per group.
    (reduce-to-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,localScratchVec)

    ; atomic combination
    (when-thread-in-group-is 0
      (atomic-binop! (~ ,return-vec 0) ,someFunction ,someVar))))
```

#### reduce-to-1-cont 📝
`(reduce-to-1-cont someFunction <someVar> identity continuation-kernel-name &optional globalScratchVec localScratchVec)`

`reduce-to-1-cont` is quite different than the other reduction macros.  It performs the first part of a reduction,
reducing within the workgroup, storing the result in a global scratch vector.

But it also defines a new kernel which will then handle the second part of the reduction. And THAT kernel
is invoked with the same two scratch vectors and a one element result vector.  
The result of the final reduction will be stored in ITS `result-vec` argument.

Note that the second "continuation kernel" will be hoisted with a quite different configuration from
the one that `reduce-to-1-cont` is in. That kernel's workgroup size will be the same size (or bigger) as
the global scratch vector.

Also note that the `reduce-to-1-cont` macro requires that both `someFunction` and `identity` be compile-time identifiable. 
The compiler will emit and error if it cannot identify them.


##### optional scratch vectors
This routine accepts two optional arguments.  `localScratchVec` and `globalScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector`  that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / (get-warp-size)` ). `(get-warp-size)` is usualy 32.

`reduce-to-1-cont` also accepts an optional `globalScratchVec`. Crisp will generate it for you if you do not provide it.  
If you want to provide it yourself, it should be a `vector` whose `element-type` is the same as `<someVar>` , 
its address space MUST be `:global` and it's size is the number of workgroups 
which can be calculated as `M` where `M = global_work_size / local_work_size`. 




Possible Implementation
```
;; -- reduce-to-1-cont --
(defmacro reduce-to-1-cont (someFunction someVar identity continuation-kernel-name
                             &optional (globalScratchVec (make-scratch-vector (type-of someVar) :match-num-workgroups :address-space :global))
                                       (localScratchVec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup))) 
   (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
   (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
   `(let-kernel ((continuation-k  (l-s-v g-s-v result-cell)
                  (declare (kernel-name ,continuation-kernel-name)
                           (type l-s-v (scratch-vec-type (type-of ,someVar)))
                           (type g-s-v (scratch-vec-type (type-of ,someVar) :global))
                           (type result-cell (cell (type-of ,someVar)))
                           (local-size :derive-from g-s-v :msg (string-concat ,continuation-kernel-name "requires a local_work_size at least as big as the global-scratch-vector")))
                      (let ((num-items (length~ g-s-v))
                            (local-id (get-local-id))
                            ;; Each thread in the workgroup loads one partial result.
                            ;; If there are more threads than items, inactive threads get the identity.
                            (val (if (< local-id num-items)
                                      (~ g-s-v local-id)
                                      ,identity)))
                        
                        ;; Perform a standard workgroup reduction on the partial results.
                        (reduce-to-workgroup ,someFunction val ,identity :local-scratch-vec l-s-v)
                        
                        ;; The final result is now in 'val' of all wg threads.
                        ;; To avoid contention, only thread 0 writes the final result to the output vector.
                        (when (= local-id 0)
                          (set! (~ result-cell) val))) ))

      (declare (grid-level))
      ; after reduce-to-workgroup the globalScratchVec will one value per group.
      (reduce-to-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,localScratchVec :result-vec ,globalScratchVec)
      
       ;; this isn't a real invocation. It just demonstrates to the hoisting code 
       ;; HOW this function expects the "continuation" kernel to be called.
      (launch-kernel (continuation-k ,globalScratchVec ,localScratchVec (allocate-cell (type-of ,someVar)))))  
      
```


### reduce vector 📝

The previous reductions are general purpose tools that let you create algorithms that reduce over warps, workgroups, or all the threads.  
The `reduce-vec-XXXX` variants are different in that they are respondent to a `vector` (or a 1D `tensor`). 

All the vector reductions are "grid level" operations, meaning they cannot be nested in other grid level ops.


#### reduce-vec-first-stage 📝
`(reduce-vec-first-stage someFunction vec identity &out intermediateVec &optional localScratchVec)`

This variant reduces `vec` down to a `intermediateVec` vec which will hold
one reduction value per workgroup.  You can then enqueue a kernel with `reduce-vec-second-stage` and pass it `intermediateVec` to complete the reduction.

The `localScratchVec` should be the same size as the size of a workgroup (ie local work size). 

Possible Implementation
```
(<T A>
  (declare (value-is A #'is-alignment?))

  ;; -- reduce-vec-first-stage --
  (def-grid-function reduce-vec-first-stage (someFunction vec identity &out intermediateVec) 

    (declare #'((binop-type T) (in-vec T A) T &out (out-vec T A))
      (global-size :derive-from vec :strategy :strided))
    (r-t-assert-0 (= (length~ intermediateVec) (get-num-groups) "intermediatVec length must equal number of workgroups))

    (let ((sum identity))
      (loop-vector-stride vec (i)
       (set! sum (funcall someFunction sum (~ vec i)))))

    (reduce-to-workgroup someFunction sum identity :return-vec intermediateVec))))

```



#### reduce-vec-second-stage 📝

`(reduce-vec-second-stage  someFunction intermediateVec identity &out final-result &optional localScratchVec globalScratchVec)`

This variant has a different requirement than  `reduce-to-1-second-stage`: it is launched 
with just ONE workgroup, which must have the same number of threads as `intermediateVec` length.

##### optional scratch vectors
This routine accepts two optional arguments.  `localScratchVec` and `globalScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / (get-warp-size)` ). `(get-warp-size)` is usualy 32.

`reduce-vec-second-stage` also accepts an optional `globalScratchVec`. Crisp will generate it for you if you do not provide it.  
If you want to provide it yourself, it should be a `vector` whose `element-type` is the same as `<someVar>` , 
its address space MUST be `:global` and it's size is the number of workgroups 
which can be calculated as `M` where `M = global_work_size / local_work_size`. 


- when `reduce-vec-second-stage` completes, the state of the scratch vectors are indeterminant
- `final-result` will hold the final result of the reduction.


This is what an implementation of `reduce-vec-second-stage` might look like

```
;; -- reduce-vec-second-stage --
;; This kernel's only job is to run the final reduction.
;; It's launched with a single workgroup that must be large
;; enough to hold the intermediate data.
(<T A>
  (declare (value-is A #'is-alignment?))

  ;; -- reduce-vec-second-stage --
  ;; This kernel IS the final reduction.
  (def-grid-function reduce-vec-second-stage (someFunction intermediateVec identity
                                               &out final-result
                                               &optional (localScratch (make-scratch-vector T :match-workgroup-size)))
    (declare #'((binop-type T) (in-vec T A) T &out (single-result T)
                                         &optional (scratch-vec-type T))
             (grid-level)
             ;; launch just one workgroup, big enough to accomodate intermediateVec
             (num-groups :max 1)
             (local-size :derive-from intermediateVec :strategy :one-thread-per))

    (let ((local-id (get-local-id))
          (N (length~ intermediateVec)))
      
      (when (< local-id N)
        (set! (~ localScratch local-id) (~ intermediateVec local-id)))
      (sync-workgroup)

      (let ((val (if (< local-id N) (~ localScratch local-id) identity)))
        (reduce-to-workgroup someFunction val identity)
        (set-result! final-result val)))))
```

#### reduce-vec-warp 📝

`(reduce-vec-warp someFunction vec identity) => result`

`reduce-vec-warp` is NOT a general purpose vec reduction routine. It uses warp-level functions
to reduce, but cannot reduce any vector whose length is greater than `(get-warp-size)` (32).

Note that unlike most reductions, this is NOT a grid-level function.

This function is very handy for operation on certain "small" data types, like a `microfloat-block` (see [below](#low-precision-floats-microfloats))

Possible Implementation
```
(<T A>
  (def-function reduce-vec-warp (someFunction vec identity)
    (declare #'((binop-type T) (in-vec T A) T => T))
    (in-warp (lane-id)
      (let ((len (length~ vec))
            (v (if (< lane-id len)  (~ vec lane-id) identity)))
        ;; reduce-to-warp broadcasts. If that changes,
        ;; then be sure to sync this as well (screen for lane-id==0, etc)
        (reduce-to-warp someFunction v identity)))))
```


#### reduce-vec-atomic 📝

`(reduce-vec-atomic  someFunction vec identity &out return-vec &optional localScratchVec)`

The `reduce-vec-atomic` variant has the same limitations as `reduce-to-1-atomic`: 
`someFunction` must be one of three commutative operations: `+`, `min` or `max`
that have `atomic-XXXX!` counterparts.

- `#'+`
- `#'min`
- `#'max`

##### optional scratch vector
This routine accepts an optional scratch vector argument  `localScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / (get-warp-size)` ). `(get-warp-size)` is usualy 32.


- After the operation completes, the state of `localScratchVec` is indeterminant. 
- `result-vec` will hold the value of the reduction. 


Possible Implementation
```
;; -- reduce-vec-atomic --
(<T A>
  (declare (value-is A #'is-alignment?))

  (def-grid-function reduce-vec-atomic (someFunction vec identity &out return-vec
                                &optional (localScratchVec (make-scratch-vector T :match-num-warps-per-workgroup)))
    (declare #'((binop-type T) (in-vec T A) T &out (single-result T) &optional (scratch-vec-type T))
      (global-size :derive-from vec :strategy :strided))

    (c-t-assert (or (= someFunction #'+) (= someFunction #'min) (= someFunction #'max)) "only #'+, #'min or #'max are accepted operations for reduce-vec-atomic")
    
    (let ((var identity)
          (len (length~ ,vec)))
        (declare (uniform len))
        (loop-vector-stride vec (i)
          (set! var (funcall someFunction var (~ vec i)))))
        (reduce-to-1-atomic someFunction var identity return-vec localScratchVec)))

  
```


#### reduce-vec-cas 📝

`(reduce-vec-cas  someFunction vec identity return-vec &optional localScratchVec)`

This variant uses `reduce-to-1-cas` for the final reduction stage, which means than an
atomic compare and swap is used to force the order of the reduction. While this is most flexible
of the vector reductions, it might not always be the most performant solution. 

- After the operation completes, the state of `localScratchVec` is indeterminant. 
- `result-vec` will hold the value of the reduction. 

Possible Implementation
```
;; -- reduce-vec-cas --
(<T A>
  (declare (value-is A #'is-alignment?))

  (def-grid-function reduce-vec-cas (someFunction vec identity &out return-vec
                                &optional (localScratchVec (make-scratch-vector T :match-num-warps-per-workgroup)))
    (declare #'((binop-type T) (in-vec T A) T &out (single-result T) &optional (scratch-vec-type T))
            (global-size :derive-from vec :strategy :strided))

    (let ((var identity)
          (len (length~ ,vec)))
        (declare (uniform len))
        (loop-vector-stride vec (i)
          (set! var (funcall someFunction var (~ vec i)))))
        (reduce-to-1-cas someFunction var identity return-vec localScratchVec)))

```

#### reduce-vec-cont 📝

`(reduce-vec-cont  someFunction vec identity continuation-kernel-name &optional localScratchVec globalScratchVec)`

This variant uses `reduce-to-1-cont` to perform the final reduction of the vector.  A second "continuation kernel"
will be generated to complete the reduction operation.

Possible Implementation
```
;; -- reduce-vec-cont --
(<T A>
  (declare (value-is A #'is-alignment?))

  (def-grid-function reduce-vec-cont (someFunction vec identity continuation-kernel-name
                              &optional (localScratchVec (make-scratch-vector T :match-num-warps-per-workgroup))
                                        (globalScratchVec (make-scratch-vector T :match-num-workgroups :address-space :global)))
    (declare #'((binop-type T) (in-vec T) T string &optional (scratch-vec-type T) (scratch-vec-type T :global))
                (global-size :derive-from vec :strategy :strided))

    (let ((var identity)
          (len (length~ vec)))
      (declare (uniform len))
      (loop-vector-stride vec (i)
        (set! var (funcall someFunction var (~ vec i))))
      (reduce-to-1-cont someFunction var identity continuation-kernel-name localScratchVec globalScratchVec))))
```


#### binop-type 📝

`binop-type` is a type constructor that takes a type `T` and returns the function type `#(T T => T)`.


##### Commutativity
Note that unlike `reduce` in some other languages that are meant for CPUs as opposed to GPUs, the `reduce-` variants in Crisp do not guarantee any sort of order for execution. 
This means that non-commutative operations like subtraction and division will not work.
But they still work fine with commutative operations like addition, multiply, minimum and maximum. 
Additionally any function defined with `def-function` can be used with the reduction, but it will only work
correctly if it is commutative, where  `(someF a b)` is equivalent to `(someF b a)`. 

## Boolean Reductions 📝

### `all?` / `none?` 📝
```
(all? someVec &out result &optional predicateF)
(none? someVec &out result &optional predicateF)
```
`all?` checks to see if all the values in a `vector` are true and, if so, sets its result to `true`, otherwise `false`

Conversely, `none?` checks to make sure that none of the values are true, and if so, set result to `true`.

Possible Implementation
```
;; -- all? --
(<T A>
  (declare (value-is A #'is-alignment?))

  (def-grid-function all? (someVec &out result-vec &optional (predicateF (gen-to-bool T)))
    (declare #'((in-vec T A) &out (single-result int) &optional (predicate-type T))
      (global-size :derive-from someVec :strategy :strided))
      
    ;; this thread checks its strides
    (let ((partial-result 1)) 
      (loop-vector-stride someVec (i)
        (unless (funcall predicateF (~ someVec i))
          (set! partial-result 0))))

    (reduce-to-1-cas #'logand partial-result 1 result-vec)))
```

### `any?` 📝
```
(any? someVec &out result &optional predicateF)
```
`any?` checks to see if any of the values in `someVec` are true and, if so, sets its result to `true`.

Possible Implementation
```
;; -- any? --
(<T A>
  (declare (value-is A #'is-alignment?))

  (def-grid-function any? (someVec &out result-vec &optional (predicateF (gen-to-bool T)))
    (declare #'((in-vec T A) &out (single-result int) &optional (predicate-type T))
      (global-size :derive-from someVec :strategy :strided))
      
    ;; this thread checks its strides
    (let ((partial-result 0)) 
      (loop-vector-stride someVec (i)
        (when (funcall predicateF (~ someVec i))
          (set! partial-result 1))))

    (reduce-to-1-cas #'logior partial-result 0 result-vec)))
```

## Segmented Reduction 📝

With the common use of prefix-sum scans, GPU programmers often find themselves using "segment maps".
These are very common for "ragged edged" data.  Essentially, you have a source vector of data
accompanied by a vector of flags, where "1" means start a segment, and "0" continue the segment.

`segmented-reduction` will perform a reduction on each segment, storing the result in a result vector.

In addition to the source data and the flags, this algorithm also needs an `incl-scan` variable which
is an inclusive scan of the flags.  The inclusive scan will be the indeces of the segment vec were it using
1 based counting. But since this isn't Visual Basic, we'll subtract one to make it match our 0 based counting.

Note that the output `segment-vec` is also expected to be the correct length, so yet another preperatory step
will be to reduce the `flags-vec` to count them. 

```
source-vec  #( 3  1  5  2  8  4  7  9)
flags-vec   #( 1  0  0  1  0  1  0  0) <- '1' marks the start of each segment
incl-scan   #( 1  1  1  2  2  3  3  3) <-- inclusive-scan of flags-vec produces this.
segment-vec #( 9        10    20)      <-- final output
```

| Data:     | `[3,`     | `1,` | `5,` | `2,`    | `8,` | `4,`      | `7,` | `9]` |
| :---      | :---      | :--- | :--- | :---    | :--- | :---      | :--- | :--- |
| Flags:    | `[1,`     | `0,` | `0,` | `1,`    | `0,` | `1,`      | `0,` | `0]` |
| incl-scan:| `1`       | `1`  | `1`  | `2`     | `2`  | `3`       | `3`  | `3`  |
| Segments: | `(3+1+5)` |      |      | `(2+8)` |      | `(4+7+9)` |      |      |
| Goal:     | `[9,`     |      |      | `10,`   |      | `20]`     |      |      |


```
;; -- segmented-reduction
(<T A>
  (def-grid-function segmented-reduction (source-vec flags-vec incl-scan someFunction identity &out segments-vec)
    (declare #'((in-vec T A) (in-vec uint A) (in-vec uint A) (binop-type T) T &out (out-vec T A))
      (global-size :derive-from source-vec :strategy :strided))
    (loop-vector-stride source-vec (i)
      (let ((val (~ source-vec i))
            (segment-id (1- (~ incl-scan i))))
        ;; each thread just atomically modifies its index in segments-vec
        (atomic-binop! (~ segments-vec segment-id) someFunction val))))) 
```





## Filtering / Prefix-Sum Scan 📝

A common activity on the GPU is to "find all matches".  Crisp has several macros and functions that
can help with that.  Most prominent is the support for "prefix-sum scans" such as "exclusive scan" and
"inclusive scan".  
In these operations, a vector that consists of matches (1) and misses (0) is converted
into a vector that counts "how many before".  And a vector in "prefix sum scan" format is easy to 
then parse to a compact short list of results.  The "word count" example below illustrates.

### `prepare-for-scan--value` 📝

```
(prepare-for-scan--value input-vec predicateF (<localScratchVar>) ...)
```

This is a macro that does most of the busy-work for you in preparation of using either `exclusive-scan-workgroup`
or `inclusive-scan-workgroup` .  It iterates over input data, applies a predicate and stores the result (1 or 0)
into a local memory buffer, which is then bound for you are ready for the scan operation.

This macro is meant to be called at the workgroup level ("shop local").

If the element type of `input-vec` is `T` then `predicateF` type is `#(T => bool)` 
The predicateF operation is called with THE VALUE at `(~ input-vec global-id)`

See an example of using it in `filter` and `find-indices` below.

### `prepare-for-scan--index`
```
(prepare-for-scan--index input-vec predicateF (<localScratchVar>) ...)
```
This is a macro much like `prepare-for-scan--value` above, except the `predicateF` is type is `#(ulong => bool)`
and it is called with THE INDEX into `input-vec`.

See an example of using it in `word_search` below.


POssible Implementation:
```
;; -- prepare-for-scan--value --
(defmacro prepare-for-scan--value (input-vec predicateF (local-flags-var) &body body)
  ;; Ensure predicate matches input vector type
  (c-t-assert (is-type-of predicateF (predicate-type (element-type input-vec))) "Predicate type mismatch")

  ;; Generate the code
  `(let (;; Allocate the local memory using the name provided by the user
          (,local-flags-var (make-scratch-vector uint :match-workgroup-size))
          (local-id (get-local-id))
          (global-id (get-global-id)))

      ;; Generate Flags in Parallel 
      (when (< global-id (length~ ,input-vec)) ; Only active threads participate
        ;; Apply predicate
        (let ((match? (funcall ,predicateF (~ ,input-vec global-id))))
          ;; Store 1 or 0 in the user-provided local memory buffer
          (set! (~ ,local-flags-var local-id) (if match? 1 0))))

      ;; Ensure all flags are written before the user's code runs
      (sync-workgroup)

      ;; Splice in the body provided by the user
      ,@body))
```

### `exclusive-scan-workgroup` 📝
The purpose of `exclusive-scan-workgroup` is to, for each element in a vector, calculate the sum of all the elements
that came before it. This is an extremely useful routine. If the activity if "finding matches" then the input vector
might be a vector of 0s and 1s (where 1 represents a "match"). 
But other times the vector is the "number of matches" for each of the workgroups or warps, in this case 
`exclusive-scan-workgroup` lets us transform that into a running total of all matches (ie `#(3 2 7 1) => #(3 5 12 13)`).

Since this only works on the scope of one workgroup, the input vector cannot be longer than the kernel work size.

`exclusive-scan-workgroup` modifies the vector in place.  It returns the final sum of the scan.

It works in two passes, first "sweeping up" the values with an increasing step size, and then "sweeping down" the results.
This "sweep up" "sweep down" will be more important once we want to start perform these scans on the really big vectors, vectors
that are bigger than just one workgroup.  

#### Finding Matches Example

Let's assume there a mere 6 threads in a workgroup. Our algorithm finds some match or miss and
records in a vector, each match or miss stored at the local id of whatever thread did the check.
Our vector has two states, the "input" state before `exclusive-scan-workgroup` is run, and its modified output state
once `exclusive-scan-workgroup` is complete. 

`(exclusive-scan-workgroup match-vector)`

```
Input:  #(0 1 0 1 1 0)
Output: #(0 0 1 1 2 3)
```
If you look at the output, the value at each "match" position tells you exactly how many matches came before it:
  Thread 1: Its output is 0. There were 0 matches before it.
  Thread 3: Its output is 1. There was 1 match before it (at index 1).
  Thread 4: Its output is 2. There were 2 matches before it (at indices 1 and 3).
This output gives each "winner" its unique, zero-based local index (0, 1, 2)


### `inclusive-scan-workgroup` 📝

The sister to `exclusive-scan-workgroup`, its output at any index is the sum of the elements up to _and including_ `i`.

```
Output: #(0 1 1 2 3 3)
```

#### Possible Implementation

This is a possible implementation of `exclusive-scan-workgroup` realized via a Belloch Scan:

```
;; -- exclusive-scan-workgroup --
(defmacro exclusive-scan-workgroup (local-vec)
  `(let ((local-id (get-local-id))
         (wg-size (get-local-linear-size)))
    (declare (workgroup-level))
     
     ;; first pass - the up-sweep (reduction tree)
     ;; In each step, we add the value from 2^d elements away.
     (do-power-step (stride wg-size)
      (when (>= local-id stride)
        (set! (~ ,local-vec local-id)
              (+ (~ ,local-vec local-id)
                (~ ,local-vec (- local-id stride)))))
       (sync-workgroup))

     ;; The last element now holds the total sum. We save it and clear
     ;; that slot to start the exclusive scan.
     (let ((total-sum (~ ,local-vec (- wg-size 1))))
       (when (= local-id (- wg-size 1))
         (set! (~ ,local-vec local-id) 0))
       (sync-workgroup)

       ;; second pass - down sweep
       ;; Now we work back down the tree, distributing the sums.
       (dec-power-step (stride wg-size)
        (when (>= local-id stride)
          ;; Swap and add values between a thread and its partner
          (let ((partner-idx (- local-id stride)))
            (let ((temp (~ ,local-vec partner-idx)))
              (set! (~ ,local-vec partner-idx) (~ ,local-vec local-id))
              (set! (~ ,local-vec local-id) (+ temp (~ ,local-vec local-id))))))
         (sync-workgroup))

       ;; The macro can return the total sum from the workgroup
       total-sum)))
```



### global-exclusive-scan 📝

Unfortunately, doing an exclusive scan on a really big vector is not a simple isolated operation. 
It starts with an upsweep operation, which is simple enough. That populates an output vec that is
divided into workgroup-sized sections with localized exclusive scan.  It also populates
a `block-sums` vector whose length is the number of workgroups. 

If that `block-sums` vector's length fits within the size of a single workgroup, then simply call
`exclusive-scan-workgroup` on it to order it. And then move onto the downsweep stage.
But if the `block-sums` is too long, then call `global-exclusive-scan-upsweep` on IT and get 
ANOTHER block sums that is shorter. Repeat as necessary until you finally get a blocksum that fits
in a workgroup.
The number of upsweep *P*asses can be calculated with this formula
$$P = \lceil \frac{\log(N)}{\log(W)} \rceil$$
Where:
- *P* is the number of "upsweep" passes (and, of course, downsweep passes as well)
- *N* is the length of the original input vector.
- *W* is the workgroup size (usually 256)

Then apply the `global-exclusive-scan-downsweep` algorithm with the blocksums and finally apply it 
to the output vector from the very first pass. 

Note that it is imperative that the workgroup-size and workgroup-count is the same for each matching "pair"
of upsweep / downsweep calls.

What could be simpler?

```
(<T A>
  (def-grid-function global-exclusive-scan-upsweep (input-vec &out output-vec block-sums
                                    &optional (scratch-vec (make-scratch-vector T :match-workgroup-size)))
    (declare #'((in-vec T A) &out (out-vec T A) (out-vec T A) &optional (scratch-vector T))
      (global-size :derive-from input-vec :strategy :strided))
    (r-t-assert-0 (= (length~ block-sums (get-num-workgroups))) "block-sums length should be the number of workgroups")
    (r-t-assert-0 (= (length~ input-vec) (length~ output-vec)) "in/out vec lengths don't match")
    (hardware-stride input-vec :workgroup-idx (wg-idx)
      (load-tile input-vec scratch-vec)
      (let ((total (exclusive-scan-workgroup scratch-vec))) ;; scratch-vec now reordered. sync-workgroup within exclusive-scan-wg
        (when (= 0 (get-local-id))
          (set! (~ block-sums wg-idx) total)))
      (sync-workgroup)
      (store-tile scratch-vec output-vec)))

  (def-grid-function global-exclusive-scan-downsweep (input-vec block-sums &out output-vec)
    (declare #'((in-vec T A) (in-vec T A) &out (out-vec T A))
      (global-size :derive-from  input-vec :strategy :strided))
    (r-t-assert-0 (= (length~ input-vec) (length~ output-vec)) "in/out vec lengths don't match")
    (loop-vector-stride input-vec (i)
      (let ((val (~ input-vec i))
            (prefix (~ block-sums (get-group-id 0))))
          (set! (~ output-vec i) (+ val prefix))))))


;; All orchestrations are for "demo" purposes only, but that is especially true for this one.
;; We do two recursive upsweeps and two matching downsweeps. But the actual number of 
;; upsweeps and downsweeps required will depend on the size of your vector and the
;; size and number of workgroups available (see the formula above)
(<T A M>
  (def-orchestration global-exclusive-scan
    (let ((upsweep-kernel (gen-global-exclusive-scan-upsweep T A "${M}_upsweep_${T}"))
          (downsweep-kernel (gen-global-exclusive-scan-downsweep T A "${M}_downsweep_${T}"))
          (ex-scan-wg-kernel (gen-ex_scan_wg_kernel T A "${M}_ex_scan_kernel_${T}"))
          (IN (allocate-tensor upsweep-kernel::input-vec))
          (OUT (allocate-tensor upsweep-kernel::output-vec))
          (BLOCK-SUMS-1 (allocate-tensor upsweep-kernel::block-sums))
          (SCRATCH (allocate-tensor upsweep-kernel::output-vec))
          (BLOCK-SUMS-2 (allocate-tensor ex-scan-wg-kernel::in-vec)))
      ;; we will sometimes pass a vector as BOTH input and output to modify it in place.
      (launch-sequential
        (upsweep-kernel IN OUT BLOCK-SUMS-1)
        (upsweep-kernel BLOCK-SUMS-1 SCRATCH BLOCK-SUMS-2) 
        (ex-scan-wg-kernel BLOCK-SUMS-2)
        (downsweep-kernel SCRATCH BLOCK-SUMS-2 BLCck-SUMS-1)
        (downsweep-kernel OUT BLOCK-SUMS-1 OUT)))))
    
```

### global-inclusive-scan 📝

Global inclusive scan, like its exclusive scan counterpart, is done with an upsweep and a downsweep operation, with
the same recursive behavior expected. 
```
(global-inclusive-scan-upsweep input-vec &out output-vec block-sums &optional scratch-vec)
(global-inclusive-scan-downsweep input-vec block-sums &out output-vec))
```


### Word Count With Exclusive Scan 

<!-- 
  This work count has problems.
  1 - needs a lambda or curried function. (look-for-word-at corpus word _i_ )
        if corpus or word were variable, it'd be a problem.
        maybe capturing _parameter_ is ok?

-->

```
(def-type text-t (vector uchar :address-space :global :align :compact))
(def-type index-t (vector ulong :address-space :global :align :compact))

;; -- word_count --
(def-kernel word_count (corpus word &out result counter)
  (declare #(text-t text-t index-t (index-t 1) => nil))

  ;; Local memory for workgroup offset (can use 'declare (local-mem)' when ready)
  (def-local-mem wg-offset-mem (vector ulong 1))

  ;; Use prepare-for-scan--index to handle flag generation
  ;; The predicate needs access to 'corpus' and 'word'. A local lambda
  ;; or assuming lexical closure within the macro body would work.
  ;; For now, let's assume 'look-for-word-at' implicitly uses them.
  (prepare-for-scan--index corpus          ; Vector argument for length check
                           #'look-for-word-at ; Predicate (takes index 'i')
                           (local-wg-matches) ; Variable to bind local flags to

    ;; --- Body starts here: local-wg-matches is populated ---
    (let ((local-id (get-local-id)))

      ;; --- STEP 2: Scan ---
      ;; Perform the scan on the flags generated by prepare-for-scan
      (let ((count (exclusive-scan-workgroup local-wg-matches)))

        ;; --- STEP 3: Get Global Offset ---
        (when (= local-id 0)
          ;; Atomically add this workgroup's count (returned by scan)
          ;; to the global counter vector. Store the returned offset
          ;; in local memory for the workgroup to share.
          (set! (~ wg-offset-mem 0) (atomic-add! (~ counter 0) count))))

      ;; --- STEP 4: Write Results ---
      ;; Barrier to ensure scan AND global offset write are done
      (sync-workgroup)

      ;; Check if this thread had a match by reading the flag back
      (when (= (~ local-wg-matches local-id) 1)
        ;; Calculate final position using scan result and shared offset
        (let ((final-write-pos (+ (~ local-wg-matches local-id) ; Local index from scan
                                    (~ wg-offset-mem 0))))      ; Shared global offset
          ;; Write the global ID (the index where the match occurred)
          (set! (~ result final-write-pos) (get-global-id)))))))

```

### `filter` 📝
```
  (filter input-vec predicateF result-vec)
  (filter-soa input-soa-vec propertyExpression predicateF result-soa-vec)
```

The `filter` macro takes an input vector of type T, and a predicate function `#(T => bool)`, as
well as a vector to hold the results. It returns the actual number of matches found.
It is up to the caller to anticipate the size of the result vector. But even if it is too small
the return count is correct.

```
(let ((numbers #(1 2 3 4 5 6 7 8 9))
      (result  #(0 0 0 0 0 0 0 0 0))
      (count (filter number #'even? result)))
  ; at this point.  count will be 4
  ; and result could be something like #(6 8 2 4 0 0 0 0 0 0)
```

The variant `filter-soa` has an additional `propertyExpression` symbol argument. That particular property
of the struct `element-type` will be passed to the predicate function. Note that the type `T` of
the predicate function `#(T => bool`) must match the type of the struct property and both be
determinable at compile time. (ie the exact property being referenced can't be a runtime variable).

#### possible implementation of filter
```
;; -- filter --
(defmacro filter (input-vec predicateF result-vec)
  (c-t-assert (is-type-of predicateF (predicate-type (element-type input-vec))) "type mismatch between predicateF and input-vec")
  (c-t-assert (is-type-of (element-type input-vec) (element-type result-vec)) "type mismatch between input-vec and result-vec")
  `(let ((local-wg-matches (make-scratch-vector uint :match-workgroup-size))
        (local-id (get-local-id))
        (global-counter 0)
        (wg-offset 0)
        (is-a-match nil))
     (declare (global-mem global-counter) (local wg-offset) (grid-level))
     (with-global-linear-id (i)
      ;; STEP 1: local match detection
      (set! is-a-match (when (< i (length~ ,input-vec)) (funcall predicateF (~ ,input-vec i)))
      (set! (~ local-wg-matches (get-local-linear-id)) (select-if is-a-match 1 0))
      (sync-workgroup)
      ;; local-wg-matches = #(0 1 0 1 1 0 ...)

      ;; STEP 2: Reorder
      (let ((count (exclusive-scan-workgroup local-wg-matches)))
            ;; local-wg-matches is now #(0 0 1 1 2 3)

        ;; STEP 3 - get global write offset
        (when-thread-in-group-is 0
          ;; add this workgroups count to global
          (set! wg-offset (atomic-add! global-counter count))))
      
      ;; STEP 4 - write results to global memory
      (sync-workgroup)

      (when is-a-match
        (let ((final-write-pos (+ (~ local-wg-matches local-id) wg-offset)))
          (when (< final-write-pos (length~ ,result-vec))
           (set! (~ ,result-vec final-write-pos) (~ ,input-vec i)))))))
      (return global-counter)))
```


## Gather / Scatter 📝

A very common practice in GPU programming is gathering and scattering.

The "gather" operation is like shopping in a big store with a list of locations and a basket.
At every location, the item is taken from the shelf and put into the basket.

The "scatter" operation is the reverse.  With basket in one hand and the list of locations in the other, you go through the store putting items onto the shelf at that location. 

Care must be taken when "scattering" that no location is in the list twice. Otherwise a race
will occur. This can possibly be addressed with an atomic operation (slow), but the better
solution is to just not make that mistake. 

Also note that both gather (reading `big-source-vec`) and scatter (writing `big-dest-vec`) involve uncoalesced memory access if the `index-vec` is irregular, which can impact performance.

```
(with-template-type (T)

  ;; -- gather-all --
  (def-grid-function gather-all (big-source-vec index-vec &out basket-vec)
    (declare #((vector T :align A) (vector ulong) &out (result-vec-type T)))
    (r-t-assert-0 (<= (length~ index-vec) (length~ basket-vec)) "basket-vec cannot be smaller than index-vec")
    (let ((limit (length~ big-source-vec)))
      (loop-vector-stride index-vec (i)
        (let ((loc (~ index-vec i)))
          (when (< loc limit)
            (let ((val (~ big-source-vec loc)))
              (set! (~ basket-vec i) val)))))))

  ;; -- scatter-all! --
  (def-grid-function scatter-all! (basket-vec index-vec &out big-dest-vec)
    (declare #((vector T) (vector ulong) &out (result-vec-type T)))
    (r-t-assert-0 (<= (length~ index-vec) (length~ basket-vec)) "basket-vec cannot be smaller than index-vec")
    (let ((limit (length~ big-dest-vec)))
      (loop-vector-stride index-vec (i)
        (let ((val (~ basket-vec i))
              (loc (~ index-vec i)))
          (when (< loc limit)
            (set! (~ big-dest-vec loc) val)))))))
```

#### `find-indices` 📝

```
(find-indices big-vector predicateF &out result-vec count-vec)
```

`gather-all` and `scatter-all!` are great, but where does one get an `index-vec` shopping list?

Say hello to `find-indices`.  Find indices take a vector and predicate function and it'll record
the results in a result-vec, and a count-vec that tells you exactly how many results were found.
If there are more results than fit in `result-vec` that is fine, they simply aren't recorded. 
But the count in `count-vec` is correct regardless.


```
;; SLOW - DO NOT USE
(with-template-type (T)

  ;; -- find-indices-naive --
  (def-grid-function find-indices-naive (big-vector predicateF &out result-vec count-vec)
    (declare #((vector T) predicate-type &out (vector T) (vector ulong :size 1)))
    (let ((limit (length~ result-vec)))
      (loop-vector-stride big-vector (i)
        (when (funcall predicateF (~ big-vector i))
          (let ((c (atomic-inc! (~ count-vec 0))  ; <-- kiss your performance goodbye
            (when (< c limit)
              (set! (~ result-vec c) i)))))))))

```

```
(with-template-type (T A) ; T = element type, A = alignment
  (declare (value-is A #'is-alignment?))

  ;; -- find-indices --
  (def-grid-function find-indices (input-vec predicateF
                                    &out result-index-vec ; Output: indices (ulong)
                                    &out result-count-vec) ; Output: final count (ulong, size 1)
    ;; Declare the function signature
    (declare #((vector T :address-space :global :align A) ; Input data vector
               (predicate-type T) ; Predicate function #(T => bool)
               &out (vector ulong :address-space :global  :align A) ; Output index vector
               &out (vector ulong :address-space :global  :align :compact :length 1) ; Output count vector
               => nil)
             ;; Declare optional local memory buffers for the scan algorithm
             &optional (local-flags (make-scratch-vector uint :match-workgroup-size))
                       (local-scan-results (make-scratch-vector uint :match-workgroup-size))
                       (local-info (make-scratch-vector uint 2))) ; For wg_total and wg_offset

    ;; first step - detect local matches
    (let ((is-a-match nil) ; Per-thread flag to store match result
          (global-id (get-global-id))
          (local-id (get-local-id)))

      ;; Check if within bounds and apply predicate
      (when (< global-id (length~ input-vec))
        (set! is-a-match (funcall predicateF (~ input-vec global-id))))

      ;; Write 1 for match, 0 for miss to local memory
      (set! (~ local-flags local-id) (select-if is-a-match 1 0))
      (sync-workgroup) ; Ensure all flags are written before scanning

    ;; next perform exclusive scan on the flags to get local indices
    (let ((workgroup-total (exclusive-scan-workgroup local-flags)))
      ;; 'local-flags' now holds local indices [0, 0, 1, 1, 2...]

      ;; Leader thread saves the workgroup's total count to local memory
      (when (= local-id 0)
        (set! (~ local-info 0) workgroup-total)))
    (sync-workgroup) ; Ensure total count is visible before atomic add

    ;; then get global write offset
    ;; Only the leader thread performs the atomic operation
    (when (= local-id 0)
      ;; Atomically add this workgroup's total to the global counter
      ;; (The global counter must be initialized to 0 by the host)
      (let ((offset (atomic-add! (~ result-count-vec 0) (~ local-info 0))))
        ;; Share the obtained global offset with the workgroup via local memory
        (set! (~ local-info 1) offset)))
    (sync-workgroup) ; Ensure the global offset is visible to all threads before writing

    ;; fainally, write results (indices) to global mem
    ;; Only threads that found a match perform a write
    (when is-a-match
      ;; Calculate the final global write position
      (let ((final-write-pos (+ (~ local-flags local-id) ; Local index from scan
                                  (~ local-info 1))))     ; Global offset for the group

        ;; Bounds check against the result index vector size
        (when (< final-write-pos (length~ result-index-vec))
          ;; Write the INDEX (global-id), not the data value
          (set! (~ result-index-vec final-write-pos) global-id)))))))            
```


## Sorting 📝

### Bitonic Sort 📝

Crisp provides a "toolkit" for bitonic sort.  If the sort can be performed by a single workgroup, then there are functions for that.
But if the sort is occurring across a vector larger than than, then a multi-stage approach is required.


In the first stage, you hoist/enqueue a kernel which will invoke one of the `bitonic-sort-workgroup` functions. Crisp provides premade kernel definitions for this if you require no other processing.

In the second stage, you hoist a `bitonic_merge_pass` kernel repeatedly until the sort is completed.

#### psuedo demonstration

##### generate the kernels
```
;; generate kernel that sorts in place a vector of floats using :compact alignment
(gen-bitonic_sort_workgroup_in_place float :compact "stage_one_kernel")

;; generate the merge kernel
(gen-bintonic_merge_pass float :compact "stage_two_kernel")
```

##### load and enqueue the first kernel

This is a simplified Python example of hoisting the first kernel.

```
import crisp_runtime
import numpy as np

# --- Setup ---
# 1. Load the kernels you generated. The runtime finds them by the names you provided.
stage_one_kernel = crisp_runtime.load_kernel("stage_one_kernel")
stage_two_kernel = crisp_runtime.load_kernel("stage_two_kernel") # Loaded for the next phase

# 2. Prepare data on the host (the application's responsibility)
# For this example, an array of 1024 elements
host_data = np.array(np.random.rand(1024), dtype=np.float32)
data_size = host_data.nbytes

# 3. Create GPU buffers
buffer = crisp_runtime.create_buffer(host_data)

# --- Launch Kernel 1 ---
# 4. Set kernel arguments by name
stage_one_kernel.set_arg("data", buffer)

# 5. Determine launch configuration and enqueue
workgroup_size = 256 # Must be a power of 2 for this algorithm
global_size = host_data.size
stage_one_kernel.launch(queue, global_size, workgroup_size)

# The host would then wait for the queue to finish before starting Stage 2.
```

##### loop the second kernel

```
# loop through the merge stages.
j = workgroup_size * 2
while j <= data_size:
    k = j / 2
    while k > 0:
        # Launch the simple merge kernel for each pass
        stage_two_kernel.launch(queue, data, j, k)
        k = k / 2
    j = j * 2
``` 


#### `bitonic-sort-workgroup` 📝

```
(bitonic-sort-workgroup data-in data-out &key keyF)
(bitonic-sort-workgroup! data &key keyF)
(bitonic-sort-soa-workgroup <property> soa-data-in soa-data-out)
(bitonic-sort-soa-workgroup! <property> soa-data)

(gen-bitonic_sort_workgroup  elementT alignment kernelName &key keyF)
(gen-bitonic_sort_workgroup_in_place elementT alignment kernelName &key keyF)
(gen-bitonic_sort_soa_workgroup structT property alignment kernelName)
(gen-bitonic_sort_soa_workgroup_in_place structT property alignment kernelName)
```

For both `vector` and `soa-vector` there are two variants of bitonic sorting for workgroups. One takes both input and output data, and the
other performs the sort in place and takes just one data argument.

For all variants, the `local_work_size` MUST be a power of 2. 

The `soa-vector` variants key the sorting off a property. The property named must be an `is-orderable?` type.
If the property access has an overload for `soa-vector` then that overload will be used.

The `vector` variants support an optional `keyF` function `#(T => U) (type-is U #:is-orderable?)`.  Typically
a `keyF` would be used if the `vector` was one of some struct (like `point`) and `keyF` would then 
be a property retrieval function (like `x~`). But technically, the `keyF` can be anything so long as it 
returns an orderable value (for example, it could add the `x` and `y` values of the point and return their sum).
The astute reader will observe that could be done with an overload property function as well. 

Lastly, note for `vector` of structs, that the Crisp developer can choose between overloading `>` and `<` 
for some struct, using a custom `keyF` function, using a property access function `~x`, or and overloaded property
access function, to influence or intercept the ordering. 

But for the `soa-vector` variant, beyond simply specifying the property to key off, the only 
intercept is via an overload that includes `soa-vector`.


The core operation in Bitonic Sort is a simple compare-and-swap. The entire algorithm is just a series of 
these compare-and-swap steps organized into a perfectly predictable, geometric pattern.

When bitonic sorting, we repeatedly merge "bitonic sequences" (sequences that first increase then decrease, or vice-versa) into larger sorted sequences.
We do this in a highly choreographed fashion. Every step we perform the same simple move (compare-and-swap with a partner), 
but the distance to the partner changes in a fixed sequence (1 step away, then 2 steps away, then 4, etc.). 
The pattern is the same regardless of what the input numbers are.
When swapping, there is a sorting direction. `direction == true` for an ascending sort, and `direction == false` for descending one. 


A possible implementation might be

```
;; helper function
(with-template-type (T U) ; T is element type, U is key type
  ;; U must be orderable, T doesn't have to be if keyF is provided.
  (declare (type-is U #'is-orderable?))

  ;; -- bitonic-compare-and-swap --
  (def-function bitonic-compare-and-swap (local-vec idx1 idx2 direction &optional (keyF nil))
    (declare #((vector T) ulong ulong bool &optional #(T => U) => nil))
    (let ((val1 (~ local-vec idx1))
          (val2 (~ local-vec idx2)))

      ;; extract keys if keyF is provided, otherwise use the values themselves
      (let ((key1 (if keyF (funcall keyF val1) val1))
            (key2 (if keyF (funcall keyF val2) val2)))

        ;; Compare the keys
        (when (if direction (> key1 key2) (< key1 key2))
          ;; Swap the original full values (structs)
          (set! (~ local-vec idx1) val2)
          (set! (~ local-vec idx2) val1)))))

;; out of place sort
(with-template-type (T A)
  ;; Constraint relaxed: T only needs to be orderable IF keyF is NOT provided.
  ;; The compiler/constraint system needs to handle this conditional constraint.
  (declare (value-is A #'is-alignment?))

  -- bitonic-sort-workgroup --
  (def-function bitonic-sort-workgroup (data-in data-out &key keyF)
    (declare (local-size :set-to 256 :msg "local-work-size should be a power of 2 for bitonic-sort-workgroup")
             #((vector T :address-space :global) (vector T :address-space :global) 
                &key #'(T => #_is-orderable?) => nil))
    (let ((N   (get-local-linear-size)) ;; should be power of 2.
         (shared-array (make-scratch-vector T :match-workgroup-size))
         (global-id (get-global-id))
         (local-id (get-local-id)))
      (r-t-assert-0 (is-power-of-2 N) "local_work_size should be a power of 2")
      ;; load data from global to shared memory 
      ;; Each thread loads one element. For simplicity, assume N = global_size
      (when (< global-id N) ;; Boundary check for global data
        (set! (~ shared-array local-id) (~ data-in global-id)))
      (sync-workgroup)

      ;; perform Bitonic Sort
      ;; Outer loop: Builds increasingly large bitonic sequences
      ;; 'j' represents the size of the bitonic sequence being formed
      (do-power-step (j N)  ; Iterates j = 1, 2, 4, ... N/2
        ;; Inner loop: Merges bitonic sequences of size 'j'
        ;; 'k' represents the sub-sequence length to compare (j/2, j/4, ... 1)
        (dec-times-by-half (k (/ j 2))
          ;; Determine sorting direction for this phase
          ;; The first half of the sequences sort ascending, second half  descending
          (let ((direction (> (bit-and local-id (+ j j)) 0))) ; Determines if this half sorts UP or DOWN
                (partner-id (bit-xor local-id k))) ; Partner is 'k' distance away

            (when (< partner-id N) ; Ensure partner ID is within bounds (for non-power-of-2 sizes)
              (bitonic-compare-and-swap shared-array local-id partner-id direction keyF))) 
          (sync-workgroup)))

      ; store sorted data from shared to global memory
      (when (< global-id N) ;; Boundary check for global data
        (set! (~ data-out global-id) (~ shared-array local-id)))
      (sync-workgroup)))

;; in place sorting
(with-template-type (T A)
  ;; Constraint relaxed: T only needs to be orderable IF keyF is NOT provided.
  ;; The compiler/constraint system needs to handle this conditional constraint.
  (declare (value-is A #'is-alignment?))

  ;; -- bitonic-sort-workgroup! --
  (def-function bitonic-sort-workgroup! (data &key keyF)
    (declare #((vector T :address-space :global A) &key (function T => #_is-orderable?) => nil))
    (bitonic-sort-workgroup data data :key keyF)))


;; Kernels. These don't use the key. Define your own if you need to set one.
(with-template-type (T A)
  (declare (type-is T #'is-orderable?) (value-is A #'is-alignment?))

  -- bitonic_sort_workgroup --
  (def-kernel bitonic_sort_workgroup (data-in data-out)
    (declare #((vector T :address-space :global) (vector T :address-space :global) => nil))
    (bitonic-sort-workgroup data-in data-out)))
    
(with-template-type (T A)
  (declare (type-is T #'is-orderable?) (value-is A #'is-alignment?))

  -- bitonic_sort_workgroup_in_place --
  (def-kernel bitonic_sort_workgroup_in_place (data)
    (declare #((vector T :address-space :global) => nil))
    (bitonic-sort-workgroup! data)))
```

#### `bitonic_merge_pass` 📝

```
(bitonic-merge-pass data j k &keyF)

(gen-bintonic_merge_pass elementT alignment kernelName &key keyF)
(gen-bintonic_soa_merge_pass structT property alignment kernelName)
```
The merge pass is provided as both a function you can use, and a kernel template that can be generated. 
The function takes 
It will generate a kernel that takes a data, j and k arguments. 
The generated hoisting code will demonstrate how to manipulate j and k
on each subsequent call.

```
   ;; generate the kernel we need
   (gen-bintonic_merge_pass ulong :compact "my_bintonic_merge_pass_kernel")
```



Possible Implementation

```
(with-template-type (T A)
  ;; Constraint relaxed: T only needs to be orderable IF keyF is NOT provided.
  ;; The compiler/constraint system needs to handle this conditional constraint.
  (declare (value-is A #'is-alignment?)) 

  ;; -- bitonic-merge-pass --
  (def-function bitonic-merge-pass (data j k &key keyF)
    (declare #((vector T :address-space :global :align A) ulong ulong &key #'(T => #_is-orderable?) => nil))

    (let ((i (get-global-id)))
      
      ;; 1. Determine the sorting direction for this thread.
      ;; This logic splits the array into regions that sort ascending
      ;; and regions that sort descending to form the next bitonic sequence.
      (let ((direction (> (bit-and i j) 0)))

        ;; 2. Find the partner thread to compare-and-swap with.
        (let ((partner-id (bit-xor i k)))
          
          ;; 3. Guard: Ensure each pair is processed only ONCE, by the thread
          ;;    with the lower index. This prevents a "double swap".
          (when (< i partner-id)
            (let ((val1 (~ data i))
                  (val2 (~ data partner-id))
                  (key1 (if keyF (funcall keyF val1) val1))
                  (key2 (if keyF (funcall keyF val2) val2)))
              
              ;; 4. Perform the compare-and-swap based on the direction.
              (when (if direction
                        (> key1 key2)   ; Ascending sort for this region
                        (< key1 key2))  ; Descending sort for this region
                (set! (~ data i) val2)
                (set! (~ data partner-id) val1)))))))))

;; kernel doesn't take a key. Define your own if you wish to use one.
(with-template-type (T A)
  (declare (type-is T #'is-orderable?) (value-is A #'is-alignment?)) 

  ;; -- bitonic_merge_pass --
  (def-kernel bitonic_merge_pass (data j k)
    (declare #((vector T :address-space :global :align A) ulong ulong => nil))
    (bitonic-merge-pass data j k)))
```

#### Don't Make Me Think `gen-bitonic-sort-vector` 📝

```
(gen-bitonic-sort-vector elementT alignment) ;;  &key keyF
(gen-bitonic-sort-soa-vector elementT alignment)

(gen-bitonic-sort-vector! elementT alignment) ;;  &key keyF
(gen-bitonic-sort-soa-vector! structT property alignment)
```

If you don't want a toolkit, Crisp provides some "orchestrations" that will sort the vector.  
If generated, then the two kernels will be compiled and the hoisting example code will correctly show
how to calculate `j` and `k` and enqueue the merge pass until done.  


`soa-vector` variants of these two orchestrations are provided as well. 


Possible implementation.
```
(with-template-type (T L)

  ;; bitonic_sort_vector_in_place
  (def-kernel bitonic_sort_vector_in_place (vec)
    (declare #((vector T :address-space :global :length L)))
    (bitonic-sort-workgroup vec vec)))



(with-template-type (T L)

  ;; bitonic-sort-vector!
  (def-orchestration bitonic-sort-vector!
    (launch-sequential (gen-bitonic_sort_vector_in_place T L "bitonic_sort_vector_in_place_${T}_${L}"))

    ; +wg-size+ is available as a constant in def-orchestration

    (do-times-by-doubling (j (* 2 +wg-size+))
      (do-times-by-half (k (/ j 2))
        (launch-sequential ((gen-bitonic_merge_pass T L "bintonic_merge_pass_${T}_${L}")
                              bitonic_sort_vector_in_place_T_L::vec j k))))))


```


### Radix Sort 📝

Like Bitonic Sort, Radix Sort is done with multiple kernels, but its structure is a loop 
of "histogram-scan-scatter" passes, not "sort-merge-merge-merge..." like bitonic.

The easiest way to understand Radix Sort is to think of it like sorting a huge pile of mail by zip code. You don't compare two envelopes directly. Instead:
- You first create piles for the last digit of the zip code (0-9).
- You go through all the mail, putting each envelope in the correct pile.
- You stack the piles back together in order (all the 0s, then all the 1s, etc.).
- You then repeat the entire process for the second-to-last digit, and so on, until the mail is fully sorted.

Radix Sort does this with the bits of your numbers.  It loops over three kernels: histogram, prefix-sum, and scatter.

#### Radix Sort on the GPU

The entire process is a loop that has to be organized host side. For a 32-bit integer, you might loop 4 times, processing 8 bits in each pass. Inside this loop, the host orchestrates a sequence of kernel launches.

##### Step 1: The Histogram Kernel
The first kernel's job is to count the occurrences of each "digit" across the entire dataset.

How it works: Each workgroup computes a local histogram (e.g., a 256-element array for an 8-bit pass) in its fast shared memory. The leader of each workgroup then uses atomic-add! to add its local counts to a small global histogram buffer.

Result: A small array in global memory with the total count for each digit.

##### Step 2: The Prefix-Sum (Scan) Kernel
The second kernel's job is to turn the histogram counts into bucket offsets. It answers the question, "Where does the bucket for digit X begin in the final output array?"

How it works: Since the global histogram is very small (e.g., 256 elements), this is a tiny, fast kernel, often launched with just a single workgroup. It performs an exclusive scan on the histogram. (This step can sometimes even be done on the host CPU because the data size is negligible).

Result: A small array of "bucket pointers" in global memory.

##### Step 3: The Scatter (or Permute) Kernel
The third kernel's job is to actually move the data.

How it works: Each thread reads an element, looks at its current "digit," uses the bucket pointers from Step 2 to find the base address for that digit, and then uses a local counter to find its specific place within that bucket. It then writes the element to a new output buffer.

Result: A new global buffer where the data is sorted according to the current group of bits.

This new output buffer then becomes the input buffer for the next pass of the host-side loop. This is often called "ping-ponging" between two large buffers. After the final pass (on the most significant bits), the data is fully sorted.

#### Radix Sort in Crisp


##### `histogram-pass` 📝
```
 (histogram-pass input-vec bit-offset &out global-histogram  &optional local-histogram)
```

 - this routine requires that the `local_work_size` is set to 256
 - similarly the `global-histogram` vector parameter must consist of 256 `uint`
 - the `local-histogram` scratch vector is optional, it should be 256 `uint` as well. If not provided,
  Crisp will use the scratch vector side channel to fulfill it.


Possible Implementation
```
(def-constraint is-signed-integer? (T)
   (and (is-signed? T) (is-integer? T)))

;;
;; histogram-pass
;; 
(with-template-type (T A)
  (declare (type-is T #'is-numeric?) (value-is A #'is-alignment?))

  ;; -- histogram-pass --
  (def-grid-function histogram-pass (input-vec bit-offset &out global-histogram  
                                                     &optional (local-histogram (make-scratch-vector uint 256))
    (declare #((in-vec T A) uint &out (out-vec uint A 256)  &optional (scratch-vector-type T)))
              (local-work-size :set-to 256 :msg "local_work_size must be 256 for histogram kernel"))
              
    ;; setup
    (let ((local-id (get-local-id))
          (local-size (get-local-size)))

      ;; initialize local histogram
      ;; The workgroup must zero-out its local histogram. This is done in parallel.
      ;; Each thread clears a portion of the 256-element array.
      (set! (~ local-histogram local-id) 0)
      (sync-workgroup)

      ;; build local histogram
      ;; Each thread processes its slice of the large input vector.
      ;; note we have to handle floats and unsigned digits special to make sure 
      ;; they are bit-wise evaluable. 
      (loop-vector-stride input-vec (i)
        ;; a. Get the value from the input vector.
        (let ((initial-val (~ input-vec i))
              (base-val  #+(is-floating-point? T) (as-bits initial-val uint)
                          #-(is-floating-point? T) initial-val)
              (val    #+(is-signed-integer? T) (logxor base-val #x80000000)
                       #-(is-signed-integer? T) base-val))

          #+(is-floating-point? T)
          (when (is-negative? initial-val)
              (set! val (lognot val)))

          ;; b. Isolate the 8-bit "digit" we're sorting by in this pass.
          (let ((digit (bit-and (ash val (- bit-offset)) #xFF)))
            ;; c. Atomically increment the counter for that digit IN LOCAL MEMORY.
            ;;    Atomics on local memory are very fast.
            (atomic-add! (~ local-histogram digit) 1))))
      (sync-workgroup)

      ;; combine into local histogram
      ;; Now that the local histogram is complete, the workgroup adds its results
      ;; to the final global histogram.
      ;; Each thread is responsible for one bin of the local histogram.
      (when (< local-id 256)
        (let ((count-for-this-bin (~ local-histogram local-id)))
          (when (> count-for-this-bin 0)
            ;; Atomically add this workgroup's count for this bin to the global total.
            (atomic-add! (~ global-histogram local-id) count-for-this-bin)))) )))
```

#### scan histogram pass 📝

```
(scan-histogram global-histogram &out bucket-offsets)
```

The `global-histogram` that was the output of `histogram-pass` is the input of this routine.
And its output is a prefix-sum vector.


```
;;
;; scan-historgram
;;
(with-template-type (A)
  (declare (value-is A #'is-alignment?))

  ;; -- scan-histogram --
  (def-function scan-histogram (global-histogram &out bucket-offsets)
    (declare #((in-vec uint  A 256)
              &out (out-vec uint  A 256) => nil)
            ;; Ensure this kernel runs with only ONE workgroup of size 256
            (local-size :set-to 256 :strategy :exact)
            (global-size :set-to 256 :strategy :exact))

    (let ((local-id (get-local-id))
           ;; A buffer in fast local memory to perform the scan
          (local-scan-buffer (make-local-scratch-vector uint 256)))

      ;; load data from global to local
      ;; each thread loads one count from the global histogram
      (set! (~ local-scan-buffer local-id) (~ global-histogram local-id))
      (sync-workgroup) ; ensure load is complete before scan begins

      ;; perform Parallel Exclusive Scan in local memory 
      ;; uses the built-in primitive - modifies
      ;; 'local-scan-buffer' in place and returns the total sum (which is ignored)
      (exclusive-scan-workgroup local-scan-buffer)
      ;; no barrier needed here, scan primitive includes own internal barriers.

      ;; store results from local to global
      ;; Each thread writes one offset back to the global output buffer.
      (set! (~ bucket-offsets local-id) (~ local-scan-buffer local-id)))))
```


#### scatter pass 📝

```
(scatter-pass input-vec bucket-offset bit-offset &out output-vec)
```

Ping-Pong: This kernel reads from `input-vec` and writes to `output-vec`. The host needs to swap these buffers between passes.

Transformations: The `radix-transform` helper encapsulates the bitwise logic for signed integers and floats.

Local Rank (The Tricky Part): The local-rank-within-digit function is the most complex part. A high-performance implementation requires another clever scan algorithm within the workgroup. 

```
;;
;; scatter pass
;;
(with-template-type (T A)
  (declare (type-is T #'is-numeric?) (value-is A #'is-alignment?))

  ;; -- scatter-pass --
  (def-grid-function scatter-pass (input-vec bucket-offsets bit-offset &out output-vec)
    (declare #((in-vec T A) ; Input data
               (in-vec uint  A 256) ; Bucket offsets
              uint ; Current bit offset
              &out (out-vec T A))) ; Output data

    ;; setup shared memory
    (let ((wg-size (get-local-size))
           ;; Need space to store the data tile for this workgroup
          (local-data-tile (make-scratch-vector T :match-workgroup-size ))
           ;; Need space to store the 'digit' for each element in the tile
          (local-digits (make-scratch-vector uint :match-workgroup-size ))
           ;; Need space for the local scan (prefix sum) result for each thread
          (local-scan-indices (make-scratch-vector uint :match-workgroup-size))

          (local-id (get-local-id))
          (global-id (get-global-id)))

      ;; load data tile
      ;; Each thread loads one element into local memory.
      (load-local input-vec local-data-tile)
      

      ;; calculate digits and local scan
      ;; each thread determines its element's digit for this pass.
      (let ((initial-val (~ local-data-tile local-id))
            ;; Apply signed/float transformations (same as histogram kernel)
            (sortable-int (radix-transform initial-val)) ; Use a helper/macro  
            (digit (bit-and (ash sortable-int (- bit-offset)) #xFF)))

        (set! (~ local-digits local-id) digit)
        (sync-workgroup)

        ;; Perform a local scan on the digits to find the rank within the workgroup
        ;; Need a scan that counts occurrences of each digit.
        (let ((local-rank (local-rank-within-digit local-digits local-id)))
          (set! (~ local-scan-indices local-id) local-rank)))
      (sync-workgroup)

      ;; calculate global write position
      ;; Read the starting offset for this element's digit from the global offsets.
      (let ((global-bucket-offset (~ bucket-offsets (~ local-digits local-id)))
            (local-rank (~ local-scan-indices local-id)))

        (let ((final-write-pos (+ global-bucket-offset local-rank)))

          ;; write to global output
          ;; Write the ORIGINAL element value to its final sorted position for this pass.
          (when (< global-id (length~ input-vec)) ; Bounds check
            (set! (~ output-vec final-write-pos) (~ local-data-tile local-id))))))))

;;
;; get-unsigned-type
;;

;; -- get-unsigned-type --
(def-type-function get-unsigned-type (T)
  ;; Helper to determine the corresponding unsigned integer type
  (cond ((<= (sizeof T) (sizeof uint)) 'uint)
        (else 'ulong)))

;;
;; radix-transform
;;
;; we could also realize this as a series of overloads.
(with-template-type (T)
  ;; Ensure T is a type we can work with
  (declare (type-is T #'is-numeric?))

  ;; Determine the corresponding unsigned integer type (UintT) for the result
  (let ((UintT (get-unsigned-type T)))

    ;; -- radix-transform --
    (def-function radix-transform (value)
      ;; The function returns an unsigned integer of the same size as T
      (declare #'(T => UintT))

      (cond
        
        ((is-unsigned-integer? T)
         ;; No transformation needed, just ensure it's the right uint type if T was smaller
         (as UintT value))

        
        ((is-signed-integer? T)
         ;; Calculate the mask for the most significant bit (sign bit)
         (let ((msb-mask (ash 1 (- (* (sizeof T) 8) 1))))
           (declare (type msb-mask uint))
           ;; Flip the sign bit using XOR to map negatives below positives
           (logxor (as UintT value) msb-mask)))

        
        ((is-floating-point? T)
         ;; Bit-cast the float to an unsigned integer of the same size
         (let ((as-uint (as-bits uint value)))
           ;; Check if the original float value was negative
           (if (< value 0.0)
               ;; If negative, flip ALL bits to reverse their order
               (lognot as-uint)
               ;; If positive, add the sign bit offset (same as signed int XOR)
               (let ((msb-mask (ash 1 (- (* (sizeof T) 8) 1))))
                 (logxor as-uint msb-mask)))))

        ;; Should not be reached if T is numeric
        (else (c-t-error "Unsupported type for radix_transform"))))))

;;
;; local-rank-within-digit
;;
(with-template-type (A) ;; A is the alignment
  (declare (value-is A #'is-alignment?))
  ;; This function calculates the 0-based rank of a thread among threads
  ;; in the same workgroup that have the same digit for the current radix pass.
  ;; It uses fast atomic operations on local memory.

  ;; -- local-rank-within-digit --
  (def-function local-rank-within-digit (local-digits ;; Input: array (size=wg_size) of digits (0-255) for each thread
                                          local-id     ;; Input: this thread's local ID
                                          ;; Optional scratch space for atomic counters
                                          &optional (digit-counts (make-scratch-vector uint 256 :align A)))
    (declare #((vector uint :address-space :local) uint &optional (vector uint :address-space :local :align A :length 256) => uint))

    ;; initialize the shared counter array
    ;; Need to zero out the 256 counters. This can be done in parallel.
    ;; Assuming local_work_size >= 256. If not, this needs a loop.
    (when (< local-id 256)
      (set! (~ digit-counts local-id) 0))
    ;; Ensure all counters are zero before any thread proceeds.
    (sync-workgroup)

    ;; atomically increment and get rank
    ;; each thread reads its digit for the current pass.
    (let ((my-digit (~ local-digits local-id)))

      ;; Atomically increment the counter for that specific digit in local memory.
      ;; The 'atomic-add!' returns the value *before* the increment.
      ;; This previous value is exactly the 0-based rank needed.
      ;; (e.g. the first thread with digit '5' gets rank 0, the second gets rank 1, etc.)
      (let ((rank (atomic-add! (~ digit-counts my-digit) 1)))

        ;; synchronize
        (sync-workgroup)

        ;; return the calculated rank
        rank))))
```

#### coordinating all three: histogram / san / scatter

Finally, after defining `histogram-pass`, `scan-histogram` and `scatter-pass` we
are ready to use Radix Sort. 

The most difficult part to grasp is that these three kernels are run repeatedly, 
8 bits at a time. The orchestration below demonstrates how to run them. 

Just use `(gen-radix-sort Type Alignment)` and the Crisp compiler will build the correct
kernels and the hoisting example code will walk through everything.

```
;;  the three passes and their param names, for reference.
;;  (histogram_pass input-vec bit-offset &out global-histogram  &optional local-histogram)
;;  (scan_historgram global-histogram &out bucket-offsets)
;;  (scatter_pass input-vec bucket-offsets bit-offset &out output-vec)


#
# radix-sort orchestration
#
(with-template-type (T A)
  (declare (type-is T #'is-numeric?) (value-is A #'is-alignment?))

  ;; -- radix-sort --
  (def-orchestration radix-sort
    ;; the goal is to start with the unsorted input-vec (that we'll pass to the first kernel, histogram-pass)
    ;; and finally end up with the sorted output-vec.

    (let ((histogram_pass_kernel (gen-histogram_pass T A "histogram_pass_kernel"))
          (buffer-A (allocate-tensor histogram_pass_kernel::input-vec))
          (buffer-B (allocate-tensor histogram_pass_kernel::input-vec)))

      (let ((num-passes (/ (* (sizeof T) 8) 8)) ;; why is this not just sizeof T?
            (N (* num-passes 8)))
        (dotimes (bit-offset N 8)
          (launch-sequential 
            (histogram_pass_kernel buffer-A bit-offset _)
            ((gen-scan_histogram A "scan_histogram") histogram_pass::global-histogram _)
            ((gen-scatter_pass T A)) scan_histogram::global-histogram scan_histogram::bucket-offsets bit-offset buffer-B)
          (swap-refs buffer-A buffer-B))) ;; <-- orchestration only routine. ping pong

      (let ((final-buffer (if (even? num-passes) buffer-A buffer-B)))
        ; present victory?
      ))))

```



## Atomics ⚠️
Barriers are used when we have a structured, cooperative algorithm when we know exactly when threads write
and when they read, especially when there is no contention for the location being written to.
Atomics serve a similar purpose, but they are used when the multiple threads may
need to write to a same location at unpredictable times. They are used when you need a thread-safe "read-modify-write" operation. An atomic operation ensures that the entire sequence—reading the value, performing a calculation, and writing the new value back—happens as a single, indivisible transaction. This prevents data corruption from race conditions.

Atomics operations are only useful when done to values that reside in memory shared between threads, so 
:local or :global memory, typically.  Possibly values declared as `uniform`. But a typical value declared in a `let` 
clause will be a register variable and is not subject to contention between threads and does not need
atomic operations performed. The compiler will warn you if it detects this situation. 

In some languages, atomics are a variable type, but in Crisp, it's simply an operation that can be coordinated
on any variable that has possible contention. 


### Atomic Operations ⚠️
Crisp provides a number of built-in atomic operations that perform their work on shared memory locations. Each function is guaranteed to be a single, indivisible transaction.  Each one updates some variable in place and returns the value at the location BEFORE the modification occured.

#### atomic-add! ✅
Adds a value to a memory location, updating it. This routine returns the value BEFORE this modification. This "fetch-and-add" behavior is the classic parallel reduction primitive.

Syntax: `(atomic-add! location delta)`

Example: `(let ((old (atomic-add! (~ result 0) 1))) ...)`
 This example adds 1 to the first element of the result vector. The variable `old` will
 have whatever was in `(~ result 0)` before the addition occured.

#### atomic-sub!
Subtracts a value from a memory location, updating it. This routine returns the value BEFORE this modification..

Syntax: `(atomic-sub! location delta)`

Example: `(let ((old (atomic-sub! (~ total-vec 0) 1))) ...)`
This example decrements a shared counter. `old` will be set to whatever was there BEFORE the modification.

#### atomic-inc! ✅
Atomically increments a memory location by 1.  Returns the value there previously.

Syntax: `(atomic-inc! location)`

Example: `(let ((old (atomic-inc! (~ counter-vec 0)))) ...)`

#### atomic-dec! ✅
Atomically decrements a memory location by 1. Returns the value there previously.

Syntax: `(atomic-dec! location)`

Example: `(let ((old (atomic-dec! (~ tasks-vec 0)))) ...)`

#### atomic-min! ✅
Compares a value at a memory location with a new value and stores the minimum of the two. Returns the value there previously.

Syntax: `(atomic-min! location new-value)`

Example: `(let ((old (atomic-min! (~ min-across-threads-vec 0) local-min))) ...)`

#### atomic-max! ✅
Compares a value at a memory location with a new value and stores the maximum of the two. Returns the value there previously.

Syntax: `(atomic-max! location new-value)`

Example: `(let ((old (atomic-max! (~ max-across-threads-vec 0) local-max))) ...)`

#### atomic-xchg!  |   atomic-set! ✅
Atomically exchanges the value at a memory location with a new value and returns the old value.  It does this UNCONDITIONALLY. 

Syntax: `(atomic-xchg! location new-value)`

Example: `(let ((old-value (atomic-xchg! (~ thread-lock-vec 0) 1))) ...)`

`atomic-set!` is just an alias for `atomic-xchg!` .  

#### atomic-binop! ✅
Syntax: `(atomic-binop! location binop-f arg)`

Uses an atomic CAS (Compare and Swap) under the hood. `atomic-binop!` 
will call a binary op function `#(T T => T)` with `arg` and the value at `location`
and then store the new value back in the `location`.  This is a CONDITIONAL exchange.
Returns the value there previously.

Example: 
```
;reduce someVar across all groups
(when-thread-in-group=is 0
  (let ((old-value (atomic-binop! (~ result-vec 0) #'+ someVar)))
    ...))
```

```
; IMPLEMENTATION NOTES
;; The macro generates a BOUNDED loop to guarantee termination.
(dotimes+ (retry-count 1000) ; Use a generous but finite limit
  (let ((old-val (~ global-result 0)))
    (let ((new-val (funcall #'+ old-val my-partial-sum)))
      (when (atomic-cas! (~ global-result 0) old-val new-val)
        ;; If the CAS succeeded, break the loop.
        (return-from-loop)))))
```

#### atomic-op! ✅
Syntax: `(atomic-op! location op-f)`

Uses an atomic CAS (Compare and Swap) under the hood. 
`atomic-op!` calls a unary function `#(T => T)` with the value at `location`
and then store the result back to `location`. This is a CONDITIONAL exchange.
Returns the value there previously.

Example: `(let ((old-value (atomic-op! (~ global-counter 0) #'plus-ten))) ...)`

#### atomics and grid level operations

Using any atomic operation on `:global` memory makes the containing function or macro into a 
grid level operation.  The compiler will emit an error if attempted in the thread level context
of a `def-function`. Use `def-grid-function` instead. 
 If writing a `defmacro`, be sure to include `(declare (grid-level))` in its `progn` 
expansion. 



<!--

THIS IS BEING REMOVED.  

#### atomic-cas!
(Compare-and-Swap) Compares the value at a memory location with an expected value. If they are the same, it writes a new value. The old value is always returned. This is the most powerful atomic primitive and can be used to build any other atomic operation.

Syntax: `(atomic-cas! location expected-value new-value)`

Example: `(atomic-cas! (~ current-value-vec 0) 0 1)`
-->

#### Example: Summing a Vector to One Value.

The last time we summed a vector, our result vector had M entries, one for each workgroup 
which the host was exected to sum up. 

This time, our result vector only needs to have space for one entry. Each thread-0 of each
workgroup will add its sum to the first element of the result vector.
( It mightn't be the worst idea to make sure that it's value is 0 before hoisting) 

```
;; 32 warps maximum for most hardware
(def-constant +warp-size+ 32 ulong)

;; the source vector can be any size. 
(def-type source-vec (vector long :address-space :global))     

;; the final result vector is just has 1 long value
(def-type result-vec (vector long :address-space :global :length 1)) 

;; -- calculate-this-thread-sum --
(def-grid-function calculate-this-thread-sum (A)
  (declare #(source-vec -> long))
  (let ((sum 0))
    (loop-vector-stride A (i)
      (inc! sum (~ A i))))) ; <-- inc! implicity returns final sum

;; -- sum_vector_warp_to_one --
(def-kernel sum_vector_warp_to_one (A Res)
    (declare #'(source-vec result-vec => nil)
             (local-size :set-to +warp-size+ ...)
             (global-size :derive-from A :strategy :strided))

    (let ((sum (calculate-this-thread-sum A)))
        (in-warp (lane-id)
            (dec-times-by-half+ (s (/ +warp-size+ 2))
                (inc! sum (shuffle-xor sum s))))
    
    ;; Final reduction to a single value
    (when-thread-in-group-is (0)
        ;; Use atomic-add to contribute this workgroup's sum to the final result
        (atomic-add! (~ Res 0) sum))))
```


## Vector and Tensor Operations 📝

### `fill` and `iota` 📝

```
(fill someVec someValue)
(iota someVec)
```

The `fill` and `iota` operations work directly only their vector parameters. `fill` sets every entry to `someValue`,
and `iota` fills the vector with its same indices.

Possible Implementation
```
 ;; -- fill --
(<T A> 
  (declare (value-is A #'is-alignment?))

  (def-grid-function fill (someVec someValue)
    (declare #'((vector T :align A :address-space :global) T))
    (loop-vector-stride someVec (i)
      (set! (~ someVec i) someValue))))

;; -- iota --
(<T A>
  (declare (value-is A #'is-alignment?)
          (type-is T #'is-scalar?))

  (def-grid-function iota (someVec)
    (declare #'((vector T :align A :address-space :global)))
    (loop-vector-stride someVec (i)
      (set! (~ someVec i) (to T i))))) ;; <-- not supposed to be (to T ...)
```

### `copy` 📝

`(copy input-vec output-vec)`

Copies from input to output. Use `vector` as a view if you need offsets or partials.

Possible Implementation
```
;; -- copy --
(<T A>
  (declare (value-is A #'is-alignment?))

  (def-grid-function copy (in &out out)
    (declare #'((in-vec T A) &out (out-vec T A)))
    (r-t-assert-0 (= (length~ in) (length~ out)) "lengths must be the same")
    (loop-vector-stride in (i)
      (set~ (~ out i) (~ in i)))))
```

### dot product 📝

The "dot product" is an operation that takes two vectors of the same length
and returns a single scalar number. It's the sum of the products of the corresponding
entries of the two sequences of number. 
Mathematically, for two vectors A and B, the dot product is:
<!-- latex -->
$$A \cdot B = \sum_{i=1}^{n} A_i B_i = A_1B_1 + A_2B_2 + \cdots + A_nB_n$$

I can be thought of as a measure of how much one vector "points in the direction" of another. 
If two vectors are perpendicular, their dot product is zero. If they point in the same direction, their dot product is maximized.

#### dot-prod-grid / dot-prod-seq 📝

```
(dot-prod-grid A B &out RESULT)
(dot-prod-seq A B) => RESULT
```

Crisp provides two variants of the dot product function. `dot-prod-grid` is a grid level
function that uses a grid stride and a reduction to quickly calculate the dot product using
all available threads simultaneously. 

`dot-prod-seq` is a thread level sequential function that simply loops in the current thread.

Both accept two matrix arguments. They can
be a `vector`,  or a 1D `tensor`.  Note that `dot-prod-grid` should be
coalesced automatically for `vector`  arguments. But not
necessarily for `tensor`.  A row of a row-major `matrix` would be fine, but
the col or a row-major `matrix` would not be able to have coalesced memory copy.

The `RESULT` argument for `dot-prod-grid` should be a `:global` writeable vector. The
result will be written to index 0.

There are possible implementations below, with the implementations of `matmul`

### matrix multiplication (matmul) 📝

Matrix multiplication (`matmul`) is an operation that takes two matrices and produces a new matrix.
Each element in the resulting matrix is the dot product of a row from the first matrix and a column from the second matrix. 
It's the fundamental operation for transforming data in linear algebra, used for tasks like 
rotating and scaling vectors in 3D graphics or applying weights in a neural network.

#### matmul 📝

`(matmul A B)`

Crisp provides a `matmul` function. It takes two arguments, they are both matrices,
which are just 2D `tensor`. Note using `matmul` requires that the calling kernel
is enqueued with an arity of 2.

Note also that the inner dimensions must match.  For example multipling
a `2x3` matrix by a `3x4` is allowed, because the "inner" number is `3`.
But conversely, multiplying a `3x4` by a `2x3` matrix is NOT allowed because
the inner dimension (`4` and `2`) are not equal.


#### OPTIMIZING DEMONSTRATION

Below are possible implementations of dot product and `matmul`

Note that the `matmul-naive` implementation is easy to write and understand
but is not maximally performant. It may not always use coalesced access
and it makes too many "small" writes to global memory.

But the `matmul` implementation below it solves both of those problems
simply by using tiles.  The `load-tile` macro is, once again, demonstrating
its value.

The version of `matmul` below is not our final one. We'll visit it again when we cover
the hardware accellerated types that have a widened accumulator, quantized integers and microfloats.

``` 
(with-template-type (T A)
  (declare (type-is T #'is-scalar?)
           (value-is A #'is-alignment?))

  ;; -- dot-prod-grid --                     
  (def-grid-function dot-prod-grid (A B &out RESULT)
    (declare #((in-vec T) (in-vec T) (single-result T))
              (global-size :derive-from A :strategy :strided)) 
    (when-thread-is 0
      (r-t-assert (= (length~ A) (length~ B)) "lengths must match")) 
    (let ((C-scratch (make-scratch-vector (length~ A) :name "dot product")))  
      (map-stride #'* (A B) C-scratch)
      (reduce-vec-atomic #'+ C-scratch 0 RESULT)))

  ;; -- dot-prod-seq --
  (def-function dot-prod-seq (A B)
    (declare #((in-vec T) (in-vec T) => T))

    (let ((sum 0))
      (dotimes (i (length~ A))
        (set! sum (+ sum (* (~ A i) (~ B i)))))
      (return sum))))

#|
  matmul-naive
  This is a very simple, easy to read version of matmul that uses
  thread-stride and dot-prod-seq to easily multiply two matrices.
  But it won't coalece unless A is row-major and B is col-major.
  And, even then, it will still be slow, because A and B
  are most likely using :global memory, so this routine has many
  individual accesses, which will be slow. 

  Using tiles (below) both guarantees coalesced access
  and also means access to global memory is done in larger passes
  which is more performant.
|#
(with-template-type (T)
  (declare (type-is T #'is-scalar? T))

  ;; -- matmul-naive --       
  (def-grid-function matmul-naive (A B)
    (declare #(matrix matrix => matrix) (global-size :dims 2))
    (let ((inner-A (num-cols A))
          (inner-B (num-rows B))
          (outer-A (num-rows A))
          (outer-B (num-cols B)))
      (when-thread-is 0
        (r-t-assert (= inner-A inner-B) "inner dimensions must match!"))
      
      (let ((vec (make-result-vector A (* outer-A outer-B)))
            (res (make-tensor vec outer-A outer-B )))
                (thread-stride '(outer-A outerB) :global-size (x y)   
                  (set! (~ res x y) (dot-prod-seq (row x A) (col y B)))) 
                (return res)))))       

#|
  matmul - performant.
|#

;; same TILE_DIM as used by convert-layout 
(def-const TILE_DIM 32 ulong)

;; helpers (not fully defined yet)
;;   make-tile variants will call make-tile-scratch-vector themselves.
;; (make-tile-scratch-vector T)
;; (make-tile dim T) ;; <-- will do performance padding? Unsure.
;; (make-tile dim-y dim-x T) 

(with-template-type (T)
  (declare (type-is T #'is-scalar?))

  ;; -- matmul --
  (def-grid-function matmul (A B C)
    (declare #(matrix matrix matrix => nil)
             (local-size :set-to `(,TILE_DIM ,TILE_DIM)) 
             (global-size :derive-from C             
                          :strategy :tiled           
                          :tile-shape TILE_DIM       ; Tile size is TILE_DIM x TILE_DIM
                          :dims 2
                          :msg "Launch one workgroup per output tile of C"))

    (let ((tile-A (make-tile TILE_DIM T))
          (tile-B (make-tile TILE_DIM T))
          (local-id-x (get-local-id 0)) (local-id-y (get-local-id 1))
          (group-id-x (get-group-id 0)) (group-id-y (get-group-id 1))
          (acc 0.0)) ; Per-thread accumulator register

      ;; main loop over the tiles in the inner dimension
      (dotimes (tile-num (ceil (num-cols A) TILE_DIM))

        ;; adaptive, coalesced loading
        ;; Use the 'load-tile' macro to handle the complexity.
        (load-tile A tile-A group-id-y tile-num
                   :transpose (= (get-layout A) :col-major))

        (load-tile B tile-B tile-num group-id-x
                   :transpose (= (get-layout B) :row-major))
        
        (sync-workgroup)

        ;; This part is now simple and fast, both local tiles are row-major.
        (dotimes (k TILE_DIM)
          (set! acc (+ acc (* (~ tile-A local-id-y k)
                              (~ tile-B local-id-x k)))))

        (sync-workgroup))

      ;; store final result. coalesced access
      (let ((c-row (+ (* group-id-y TILE_DIM) local-id-y))
            (c-col (+ (* group-id-x TILE_DIM) local-id-x)))
        (when (and (< c-row (num-rows C)) (< c-col (num-cols C)))
          (set! (~ C c-row c-col) acc))))))
                           
```

### Matrix Vector Multiply `(m*v M v)` 📝
```
(mat-vec-mult someMatrix someVec &out outVec &optional scratchVec)
```
The basic operation is `y = M * x`, where `M` is a 2D matrix, `x` is a 1D vector, and the output `y` is a 1D vector.

Possible Implementation
```
;; -- mat-vec-mult --
(<T A>
  (declare (value-is A #'is-alignment?))

  (def-grid-function mat-vec-mult (M x-vec &out out-vec 
                      &optional (m-row-scratch (make-scratch-vector T (num-cols M)))
                                (x-vec-scratch (make-scratch-vector T (length~ x-vec))))
    (declare #'((matrix (in-vec T A)) (in-vec T A) &out (out-vec T A) &optional (scratch-vec-type T) (scratch-vec-type T)))
    (r-t-assert-0 (= (num-rows M) (length~ out-vec)) "output vector must match matrix row count")
    (r-t-assert-0 (= (num-cols M) (length~ x-vec)) "input vector length must match matrix col count")
    ;; matrix is not bigger than local-size * num-groups
    (r-t-assert-0 (<= (num-cols M) (local-work-size) ) "matrix width must not be greater than local-size")
    (r-t-assert-0 (<= (num-rows M) (get-num-groups)) "matrix height must not be greater than num work groups")

    (in-each-group (i)
      (when (< i (num-rows M))
        (copy (row i M) m-row-scratch) ;; each workgroup takes a row.
        (copy x-vec  x-vec-scratch)

        (let ((res-view (make-vector out-vec 1 i)))
          (dot-prod-grid m-row-scratch x-vec-scratch res-view))))))
            
```

### Convolution 📝

```
;; -- convolve-2d --
(<T>
  (def-grid-function convolve-2d (input-m filter-m &out output-m)
    (declare #'((matrix T) (matrix T) &out (matrix T))
      (global-size :derive-from input-m :strategy :strided))
    (let ((width (num-cols input-m))
          (height (num-rows input-m))
          (f-width (num-cols filter-m))
          (f-height (num-rows filter-m))
          (f-center-x (floor f-width 2))
          (f-center-y (floor f-height 2)))
      (r-t-assert-0 (and (= width (num-cols output-m)) (= height (num-rows output-m)))
               "dimensions for input and output matrix must match")
      (thread-stride '(width height) :global-size (x y)
        (let ((acc (zero T)))
          (dotimes (ky f-height)
            (dotimes (kx f-width)
              ;; center filter on x,y
              (let* ((offset-x (- kx f-center-x)) ; e.g., 0-1 = -1
                     (offset-y (- ky f-center-y)) ; e.g., 1-1 = 0
                     (pixel-x (+ x offset-x))
                     (pixel-y (+ y offset-y)))
                (when (and (>= pixel-x 0) (< pixel-x width)
                           (>= pixel-y 0) (< pixel-y height))
                  (let ((pixel (~ input-m pixel-y pixel-x))
                        (filt-v (~ filter-m ky kx)))
                   (set! acc (+ acc (* pixel filt-v))))))))
            ;; after enumerating filter, store
            (set! (~ output-m y x) acc))))))
```



## Math Operations & Arithmetic ✅

### Floating Point Precision ✅

#### variable type

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

#### precision ✅

In addition to choice of variable type, Crisp has a precision control that supports two
different options: `fast` and  `ieee`.  Crisp defaults to `ieee` (and `preserve` for denormal handling)

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

#### selecting precision

Crisp provides three avenues for selecting precision. In order of specifity, 
from the least specific to the most specific, they are: 

| What                           |  Value           | Descripotion         |
|--------------------------------|------------------|----------------------|
| `--math-precision`             | `fast` or `ieee`  | compilation flag     |
| `(declaim (precision <KEY>))`  | `fast` or `ieee`  | per-file declamation |
| `(with-precision (<KEY>) ...)` | `fast` or `ieee`  | in-function macro    |

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

##### overriding precision: `--force-math-precision` ✅

The `--force-math-precision` compiler flag can be used to override ALL other precision choices.
It will override the developers stated intent, and for that reason it should be avoided. This flag is intended for validation and testing purposes and should not be used as part of your release
cycle.  The compiler emits a warning whenever this flag is used. 

##### `--denormal-handling [preserve | ftz]` ✅
The `--denormal-handling` compiler flag acts as a global control for subnormal numbers across the entire kernel, specifically effecting operations within ieee precision blocks.

- `preserve` (Default): Strict IEEE 754 compliance. Subnormal numbers are preserved, allowing for gradual underflow. Use this for maximum analytical accuracy, especially when relying on auto-differentiation where vanishing gradients are a risk.
- `ftz` (Flush-to-Zero): A performance optimization. Proper hardware handling of subnormals can demand significant extra cycles or microcode fallbacks. Setting this to `ftz` instructs the hardware to immediately flush any subnormal value to zero, reclaiming performance at the cost of strict precision at the bottom of the floating-point scale.


### Floating Point Only Operations ⚠️

Crisp provides the following operations for floating point numbers:

#### Unary Operations 📝

The Unary Operations take just a single argument.
Example:
```
(sqrt x)
```

- `sqrt`
- `rsqrt`
- `exp`   ; `(exp x)` calculates $e^x$
- `log`
- `log2`
- `sin`
- `cos`
- `tan`
- `asin`
- `acos`
- `atan`


#### Binary Operations  📝
- `pow`   => `(pow base exponent)`
- `atan2` => `(atan2 y x)`

### Floating Point and Integer Operations ✅

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

#### binop vs accum-op

Most of the operations above binary operations, aka `binop-type`, aka their
type signature is generally `#'(T T => T)`.

Crisp also has accumulator operations, aka `accum-op`, where the type signature
is `#'(T T => (accum T))`. These are "widening" operations. For the basic types (`float`, `int` etc)  the `(accum T)` is just `T`.  So no special handling is required.

One example of an `accum-op` is `*!` which is multiplication but it "widens" the base type to 
an accumulator type.  We'll see more of this below when discuss the hardware accelerated types 
like Quantized Integers and MicroFloat Blocks.

- `*!`  => `#'(T T => (accum T))`  widening multiplication.

### Integer Only Operations 📝

- `ash`   ;; arithmetic shift `(ash I count)`
- `logand`
- `logior`
- `logxor`
- `lognot`
- `popcount`

### Integer Division ✅

There are four  integer divison functions: `/`, `ceil` ,  `floor` and `round`.

All four of them return both the quotient and remainder and differ only 
in how the results are rounded.

`#(divisor divident => quotient remainder)`


#### `/` truncating division ✅

Operates the same as `/` in C++ or `truncate` in Common Lisp.  
This function rounds toward 0 and returns BOTH the quotient and the remainder.

```
(/ 10 3)   => 3 and 1

(/ -10 3)  => -3 and -1
```
Because this division operates the same as in C/C++, this division is familiar and
the "default".  But note that for many GPU numeric workloads, `floor` is more reliable
because its behavior is consistent on both the negative and positive side of the number line. 

#### `floor` ✅

This rounds the result down toward negative infinity. It returns the quotient and the remainder.
```
(floor 10 3)   => 3 and 1

(floor -10 3)  => -4 and 2
```

#### `ceil` ✅

This rounds the result up toward positive infinity. It returns the quotient and the remainder.
```
(ceil 10 3)   => 4 and -2

(ceil -10 3)  => -3 and -1
```

#### `round` ✅

In addition to the three above, there is also `round`. This performes division and rounds the quotient towards the nearest integer. If equidistant it "rounds half toward even" following the  IEEE 754 standard.  Like the others, it returns both the quotient and the remainder. 

```
(round 5 2 ) => 2 and 1.  2.5 is rounded DOWN towards the nearest even integer, which is 2
(/ 7 2)      => 3 and 1   Notice how the truncating / differs from round (below).
(round 7 2)  => 4 and -1  3.5 is rounded UP towards the nearest even integer, which is 4.  
(round 8 2)  => 4 and 0
(round 9 2)  => 4 and 1   4.5 is rounded DOWN towards the nearest even integer, which is 4. 
```

#### Comparison

|Function	    | Behavior	    | (func 10 3) | (func -10 3)|
|-------------|-------------------------|--------|--------|
| (/ a b)     |	Rounds toward zero      | 3, 1  |	-3, -1 |
| (floor a b) |	Rounds toward -∞        |	3, 1  |	-4, 2  |
| (ceil a b)	| Rounds toward +∞        |	4, -2 |	-3, -1 |
| (round a b) | Rounds nearest neighbor | 3, 1  | -3, -1 | 


### Hardware Supported Math Operations 📝

#### `op-fma` Fused Multiply Add 📝
`(op-fma a b c) => ((a * b) + c)`

Fused Multiply Add is a hardware accelerated multiply and add operation that performs
only one rounding operation.  It is available for all floating point types
 ( `half`, `bfloat16`, `float`, `double` ) as well as their hardware vector variants
 ( `float2`, `float4` etc).

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

#### `op-imad-sat`  Integer Multiply-Add with Saturation 📝

`(op-imad-sat a b c) =>  SATURATE(   ((a * b) + c)   )`

Similar to `op-imad`, this operation not only performs the add and multiply, but also clamps the result so there
is no integer overflow.

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

## Quantized Integers 📝

A quantized integer (`qint`) is just like a normal integer that's being used
to "fake" a floating-point number. Commonly a `qint8` is a single byte number
that represents any of 256 steps over some amount of number space, a gradient.

It does this in conjunction with a "Scale" and a "Zero Point" which are both 
floating point numbers. These two values define the "number space" that the 
gradient is applied over. 

So two floats (scale and zero-point) and N qints can compactly represent the 
same values as N floats that fall in the same number space. That's a 4x space
saving! 

While it's easy to focus on the precision lost when converting a single float, this viewpoint is flawed. The true power of qints is seen at the vector level. When a Scale and Zero-Point (two floats) are well-chosen to define the number space for an entire dataset, the relationships between the numbers are preserved with high fidelity.

This is the core trade-off: in exchange for a tiny, well-managed loss of precision, you get a 4x reduction in memory size and access to blazingly-fast, specialized integer math hardware. The results are fast, compact, and perfectly workable for domains like AI.

But `qint` base types have a problem when multiplied: that result can easily
be greater than 256, which means it's no longer representable by the base `qint` 
type. For this a second `qint` type is needed: the accumulator. 

For `qint8` the accumulator is usually `qint32`.  

By now, gentle reader, your assignment should be clear: receive data
as some small `qint` base type, operate on it, using temporary `qint` accumulators, 
and get it stored away again back as a the `qint` base type before
anyone notices. What could be easier?

### Quantized Integer Types 📝

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

#### def-qint 📝

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

#### to-XXXX 📝

For your `qint` type, a matching function `to-XXXX` is defined. It takes the floating point value in question along with scale and zerop (also floating point) and returns a scaled value in the base type `B`.

Example:
```
(to-q-celsius <float> <zero-point> <scale>) => <q-celsius>
;; e.g:
(to-q-celsius 23.204:float 0.0 50.0) => temp
```
where `temp` would be a 1-byte `qb8` but aliased as `q-celcius` 

#### to-float 📝

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

#### additon and subtraction 📝

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

#### `*!` widened multiplication 📝

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

#### max / min 📝

`max` and `min` are available for both base and accumulator types.
(Spoiler Alert: `max` and `min` are NOT available for `microfloat-block` in next section)

```
(max B B) => B
(min B B) => B

(max A A) => A
(min A A) => A
```

#### all other math ops

For all other math operations, you'll need to conver your `qint` back to a floating point value
and then perform the calculation on that (and then convert back). 

#### type promotion

Quantized ints have no automatic type promotion. 

#### scale and zero-point independence

An interesting aspect of using quantized integers, is that the scale and zero-point
factors are only needed to convert to and from regular floating point values.
If conducting only the basic (admitedly limited) arithmetic, then those values aren't even
required.
Of course, the flip side of that, is that if you DO need to convert, then those scale and
zero-point values will have to be passed as additional independent arguments. 


#### Illegal Combinations and Target-Specific Behavior

The entire purpose of Crisp's quantized integer types is to leverage the extreme performance 
of specialized AI hardware (like Tensor Cores or Intel's XMX engines). 
This hardware is not for general-purpose integer math; it is highly optimized for 
the "sum of products" (dot-product) pattern.

This means the compiler's behavior is strict and depends on your chosen output target.

##### 1. When Compiling (to LLVM IR, SPIR-V, or PTX)

This path is optimized for **maximum performance**. The compiler acts as a strict gatekeeper and maintains a "whitelist" of `qint` combinations that are known to map directly to hardware intrinsics.

- Supported Combinations: The most common (and often only) combination supported by hardware is `:base qb8` with `:accum qb32`. When the compiler sees this, it generates the correct high-performance intrinsic (e.g., `OpSDot` in SPIR-V or `mma.sync` in PTX).
- Unsupported Combinations: If you define a type that is not on this hardware "whitelist" (e.g., `:base qb16` with `:accum qb64`), the compiler will emit a compile-time error.
- No Emulation: The compiler will NOT silently generate a slow "emulation" path. This is a core design choice: it is better to give you a compile-time error than to let you ship a kernel that is 100x slower than you intended.

##### 2. When Transpiling (to OpenCL C)

This path is optimized for maximum portability and debugging, not performance. The transpiler has no way to guarantee that specific hardware intrinsics are available.

- Therefore, in this mode, the strict "whitelist" rules are relaxed.
- Crisp will generate a slow, emulated `for` loop to perform the quantized operations (like `B*B => A` and `A+A => A`).
- This ensures the transpiled C code is portable and works, but it will have severely suboptimal performance as it will NOT use the specialized AI hardware.


## Low Precision Floats ("microfloats") 📝

Similar to Quantized Integers, Crisp supports "microfloats".  These are
very small (half byte, one byte!) storage options for floats that need a
widened accumulator for multiplication. 

But there is a significant difference, microfloats are grouped into blocks, 
and each block has its own individual scaling factor. For example,
a not uncommon (*) organizations is one 8-bit scale factor followed by sixteen
individual 4-bit values :

`[fp8_scale_0] [16 x fp4_data] [fp8_scale_1] [16 x fp4_data] ...`

So microfloats don't have independent scaling factors in the way that quantized integers do.

(*) - This "not uncommon" organization is the one used by the NVIDIA Blackwell NVFP4 format.
It is 72 bits total and is usually padded out to 128 bits. 

### Format Wars 

There are competing formats for these microfloat blocks.

NVidia NVFP4 / Blackwell: https://developer.nvidia.com/blog/introducing-nvfp4-for-efficient-and-accurate-low-precision-inference/

OCP (Open Compute Project) MX Formats: https://www.opencompute.org/documents/ocp-microscaling-formats-mx-v1-0-spec-final-pdf


### Micro Float Types 📝

Crisp provides these base types for you:

| Type   | Size    | 
|--------|---------|
| fp4  | 4 bits (half byte)  | 
| fp8-e4m3 | one byte - 4 bit exponent, 3 bit mantissa |
| fp8-e5m2 | one byte - 5 bit exponent, 2 bit mantissa | 
| f8-e8m0 | one byte - 8 bit exponent, 0 bit mantissa. This has faster, but less precise dequantizing |
| fp16 | 2 bytes |
| fp32 | 4 bytes | 

The `f8-e8m0` type is used for the OCP MX formats ( MXFP8, MXFP6, and MXFP4 )

### def-microfloat-block 📝

The types above can then be used in `def-microfloat-block`.  Note that blocks can have 1D or 2D arity.

```
(def-microfloat-block mf-celcius :base fp4 :accum fp32 :scale fp8-e4m3 :shape (16))
(def-microfloat-block mf-weights :base fp4 :accum fp32 :scale fp8-e4m3 :shape (4 4))
```

And just like with the quantized types, different block types cannot be intermixed,
even if they are configured with identical parameters. However, if you absolutely must intermix them,
you can do so by using `set-derived`.   

`def-microfloat-block` with `mf-celcius` like above would result in
```
(def-type mf-celsius-base fp4)
(def-type mf-celcius-accum fp32)
(def-type mf-celsius-scale fp8-e4m3)

(def-struct mf-celcius 
  (scale mf-celsius-scale)
  #| the 16 fp4 elements |#) ;; these are not strided tensors or anything. 

;; accum and base are defined for ALL numeric types.
(def-type-function accum (T:mf-celcius) mf-celcius-accum)
(def-type-function base (T:mf-celcius) mf-celcius-base)
;; but scale is only defined for microfloat blocks
(def-type-function scale (T:mf-celcius) mf-celcius-scale)
```

<!--
REMOVE
For each invocation of `def-microfloat-block` Crisp will define the type identifiers
 `XXXX-base`, `XXXX-accum` and `XXXX-scale` as well as compile-time type functions
 `scale`, `count`, and `shape` . `num-rows` and `num-cols` are defined for the 2D variant.
-->


 Additionally,  `quantize-to-XXXX` and `dequantize-from-XXXX` functions
 are defined. These functions operate on vectors of floats and blocks. Read more below

#### Illegal Combinations and Target-Specific Behavior

The entire purpose of Crisp's microfloat types is to leverage the extreme performance of specialized hardware. 
This means the compiler's behavior is strict and depends heavily on your chosen output target.

1. When Compiling (to LLVM IR, SPIR-V, or PTX)

This path is optimized for maximum performance. The compiler acts as a strict gatekeeper 
and knows which combinations (e.g., :base fp8-e4m3, :accum fp32) are supported by hardware intrinsics.

- Supported Combinations: The compiler generates the correct high-performance intrinsic (e.g., `OpFMulAdd` in SPIR-V or `mma.sync` in PTX).
- Unsupported Combinations: If you define a type the hardware doesn't support (e.g., `:base fp16, :accum fp16`), the compiler will emit a compile-time error.
- No Emulation: The compiler will not silently generate a slow "emulation" path. This is a core design choice: it is better to give you a compile-time error than to let you ship a kernel that is 100x slower than you intended.

This strictness also applies to portability. A SPIR-V module compiled for 
one hardware target (e.g., OCP MX) is not portable to another (e.g., NVIDIA). 
The driver will reject the kernel, resulting in a fatal load-time error.

2. When Transpiling (to OpenCL C)

This path is optimized for maximum portability and debugging, not performance. The transpiler has no way to guarantee that specific hardware intrinsics are available.

- Therefore, in this mode, the "unsupported combination" rules are relaxed.
- Crisp will generate a slow, emulated for loop to perform the operation.
- This ensures the transpiled C code is portable and works, but it will have severely suboptimal performance as it will not use Tensor Cores or other hardware accelerators.



### blockwise operations 📝

The arithmetic operations on microfloats are "blockwise". This is highly optimized.

The abbreviation `A` is used for the accumulator type, and `MFB` stands for the entire
microfloat block.  

#### widening multiplication 📝

```
(*! MFB_1D MFB_1D) => A     ;  vector dot-product
(*! MFB_2D MFB_2D) => A     ;  matrix dot-product
```
Two microfloat blocks can be multiplied by each other, and the result is a single
float of the accumulator type.

#### addition / subtraction 📝
```
(+ A A ) => A   
(- A A ) => A
```
Floats of the accumulator type can be added together, or subtracted.  

Note that the BLOCKS themselves CANNOT be added or subtracted from one another.

#### optimization note

The common pattern of multipling blocks and adding to an accumulator  `A = A + (B * B)` 
is compiled to one hardware intrinsic.  The compiler should detect this and substitute automatically,
but if you want to ensure this use the `mfb-mult-add` macro:
```
(mfb-mult-add block1 block2 someA) => A
```
This will ensure that the correct `@llvm.fma._` LLVM intrinsic is output into the IR, which wil then
be correctly compiled for your target.

#### max / min 📝
`max` and `min` are NOT defined for the main MFB block type.  But they are defined
for both the base and accumulator types.
```
(max B B) => B
(max A A) => A

(min B B) => B
(min A A) => A
```

### Vector Conversion Operations 📝

The conversion operations operate on entire vectors of floats and microfloat blocks. A `quantize-to-...` and 
`dequantize-from-...` operation are defined for each invocation of `def-microfloat-block`.

#### quantize-to-XXXX 📝
```
(quantize-to-XXXX float-input-vec &out microfloat-block-vec)

(quantize-to-XXXX float-input-matrix &out microfloat-block-matrix)
```
`quantize-to-XXXX` takes either a vector (or matrix) of floats as an input arg, and a vector (or matrix) of microfloat blocks
as an output parameter.  

For 1D vectors note that length of the input vector is `count` times the length 
of the microfloat block output vector.

For 2D matrices, the length of each row of the input vector is `shape[1]` times the length of each
row of the microfloat block output matrix. 

These  are grid-level functions. 

Example:
```
(quantize-to-mf-celsius f32-input-vec mf-celcius-output-vec)
```

Possible Implementation
```
;; -- quantize-to-... --
(<F A MFB>
  (declare 
    (type-is F #'is-floating-point?)
    (value-is A #'is-alignment?)
    (type-is MFB #'is-microfloat-block?))

   ;; 1D
  (def-grid-function quantize-to-XXXX (input-vec &out output-mfb-vec 
                              &optional (scratch-vec (make-scratch-vector F (ceil-pow2 (count MFB)))))
    (declare #((in-vec F A) &out (out-vec MFB :compact)))
    (r-t-assert-0 (= (length~ input-vec) (* (count MFB) (length~ output-mfb-vec)))
                  "lengths don't match")
    (c-t-assert (<= (count MFB) +warp-size+) "microfloat-block must be smaller than warp-size elements")
    ;; 
    (thread-stride (length~ output-mfb-vec) (ceil-pow2 (count MFB)) (warp-num)
      ;; we may be loading a smaller tile than we declared to thread stride,
      ;; so we can't use the short version of load-tile. 
      (let ((identity-val (identity-of #'max F)))
        (load-tile input-vec scratch-vec identity-val '(warp-num) '((count MFB))) 
        (let ((max-val (reduce-vec-warp scratch-vec #'max identity-val)) ;;
              (scale-f (to (scale MFB) max-val))
              (target-block (~ output-mfb-vec warp-num)))
          (when-thread-in-warp-is 0 
            (set! (scale~ target-block) scale-f))
          (in-warp (lane-id)
            (when (< lane-id (count MFB))
              (set! (~ target-block lane-id) (to (base MFB) (/ (~ scratch-vec lane-id) max-val)))))))))

    ;; 2D
    (def-grid-function quantize-to-XXXX (input-tv &out output-mfb-tv 
                              &optional (scratch-vec (make-scratch-vector F (ceil-pow2 (num-cols MFB)))))
      (declare #((tensor 3 (in-vec F A)) &out (tensor 3 (out-vec MFB :compact))))
      (r-t-assert-0 (= (num-cols input-tv) (* (num-cols MFB) (num-rows MFB))) "confusing")
      (r-t-assert-0 (= (num-planes input-tv) (num-planes output-mfb-tv)) "number of planes not matching")
      (r-t-assert-0 (= (num-rows intput-tv) (num-rows output-mfb-tv)) "number of rows should match")
      

      ;; workgroup


            
                

```

#### dequantize-from-XXXX 📝
```
(dequantize-from-XXXX microfloat-block-vec &out float-input-vec )
```
`dequantize-from-XXXX` takes a a vector of microfloat blocks as an input arg
 and an output vector of floats as an output parameter.  Note that length of the output vector is `:count` times the length of the microfloat block input vector.

This is a grid-level function. 

Possible Implementation
```
;; -- dequantize-from-... --
(<MFB F A>
  (declare 
    (type-is F #'is-floating-point?)
    (value-is A #'is-alignment?)
    (type-is MFB #'is-microfloat-block?))

  (def-grid-function dequantize-from-XXXX (input-mfb-vec &out output-vec)
    (declare #((in-vec MFB :compact) &out (out-vec F A)))
    (r-t-assert-0 (= (length~ output-vec) (* (count MFB) (length~ input-mfb-vec)))
                  "lengths don't match")

    ;; be sure to "gen-" to-float for the desired F output type
    (loop-vector-stride output-vec (i)
      (let ((which-block index-in-block (floor i (count MFB)))
            (target-block (~ input-mfb-vec which-block))
            (value (to-float target-block index-in-block)))
        (set! (~ output-vec i) value)))))
```
            


### element-wise access 📝

Element-wise access to microfloat blocks is not slow (like atomic ops or reading global memory). 
But it is not optimal.  Try to avoid element-wise block access if possible. 

#### `~` 📝

`(~ MFB index) => base` 
The `~` array access expression can be used to access the raw unscaled base value of any microfloat block.

#### `to-float` 📝

`(to-float MFB index) => float`
An override of `to-float` exists that can take microfloat block argument and an index. It will retrieve 
the microfloat type at that index, scale it appropriately, and then return "regular" `float` type. 



## Complex Numbers 📝

Complex numbers are fairly straightforward in Crisp.

The implementation Crisp provides uses a template and `def-struct` like so:

```
(with-template-type (T)
  (declare (type-is T #'is-floating-point?))
  ;; -- complex --
  (def-struct complex (real T) (imag T)))

```
Thus to make them: `(make-complex :real someFloat :imag otherFloat)`
Or declare their type: `(complex-type double)`

The arithmetic functions fall out easily:
```

;; this macro lets us use "a b c d" notation in the body of our
;; binary arithmetic functions. Much easier to read. 
;; Just remmber to wrap in parantheses: (a)

;; -- with-complex-components --
(defmacro with-complex-components ((z1 z2) &body body)
  "Establishes local macros a, b, c, d for the components of z1 and z2."
  `(macrolet ((a () '(real~ ,z1))
               (b () '(imag~ ,z1))
               (c () '(real~ ,z2))
               (d () '(imag~ ,z2)))
     ;; Execute the body within the scope of the local macros
     ,@body))

(with-template-type (T)
  (declare (type-is T #'is-floating-point?))

  ;; ( + ) Addition
  (def-function + (Z1 Z2)
    (declare #((complex-type T) (complex-type T) => (complex-type T)))
    ;; $(a+c) + (b+d)i$
    (with-complex-components (Z1 Z2)
      (make-complex :real (+ (a) (c))
                    :imag (+ (b) (d)))))

  ;; ( - ) Subtraction
  (def-function - (Z1 Z2)
    (declare #((complex-type T) (complex-type T) => (complex-type T)))
    ;; $(a-c) + (b-d)i$
    (with-complex-components (Z1 Z2)
      (make-complex :real (- (a) (c))
                    :imag (- (b) (d)))))

  ;; ( * ) Multiplication
  (def-function * (Z1 Z2)
    (declare #((complex-type T) (complex-type T) => (complex-type T)))
    ;; $(ac-bd) + (ad+bc)i$
    (with-complex-components (Z1 Z2)
      (make-complex :real (- (* (a) (c)) (* (b) (d)))
                    :imag (+ (* (a) (d)) (* (b) (c))))))

  ;; ( / ) Division
  (def-function / (Z1 Z2)
    (declare #((complex-type T) (complex-type T) => (complex-type T)))
    ;; Formula: (ac+bd)/(c²+d²) + (bc-ad)/(c²+d²) i
    (with-complex-components (Z1 Z2)
      (let ((denom (+ (* (c) (c)) (* (d) (d)))))
        (make-complex
          :real (/ (+ (* (a) (c)) (* (b) (d))) denom)
          :imag (/ (- (* (b) (c)) (* (a) (d))) denom))))))
```

Additionally, Crisp provides the following operations for complex numbers:

| Operation       | Descrption                                              |
|-----------------|---------------------------------------------------------|
| `(conjugate z)` |  If $z = a + bi$, returns $a - bi$.                     |
| `(magnitude z)` | Returns $\sqrt{a^2 + b^2}$ (a real number).             |
| `(phase z)`     | Returns the angle $\text{atan2}(b, a)$ (a real number). |
| `(real~ Z)`     | Retrieve the `:real` part of the complex                |
| `(imag~ Z)`     | Retrive the `:imag` part of the complex                 |


And the transcendantals ( `exp`, `log`, `sqrt`, `sin`, `cos`, etc )

### soa-vector and complex 📝

Because complex numbers are defined as Crisp structs, they can take advantage
of `soa-vector`  support. 


## Fast Fourier Transform (FFT) 📝

The routines and orchestration below implement the Fast Fourier Transform using the Cooley-Tukey algorithm. 
It first optionally rearranges the input data using a bit-reversal permutation. 
Then, it precomputes the necessary complex constants called twiddle factors. 
The core of the algorithm is a loop that iterates through several stages. 
In each stage, it launches the fft-pass kernel, which performs parallel "butterfly" operations 
across the dataset, progressively transforming the data from the time domain to the frequency domain. 
This process uses temporary "ping-pong" buffers to store intermediate results between stages. 
Finally, a concluding step ensures the fully transformed data resides in the designated output vector.

Performance Note: The implementation below is a direct global-memory implementation. 
For maximum performance, real-world FFTs often use tiling with local memory (similar to matmul) 
to improve data reuse and reduce global memory traffic.
Additionally, some of the core operations in FFT are just dot products on both the real and imaginary part of a complex number. This can be accelerated by using the widening
accumulator hardware types like quantized integers and microfloat blocks. 

```
;;
;;  calculate-twiddle-factor
;;
;; templated with a floating point type
(with-template-type (T A)
  (declare (is-type T #'is-floating-point?) (is-value A #'is-alignment?))

  ;; -- calculate-twiddle-factor --
  (def-function calculate-twiddle-factor (k N)
    ;; $W_N^k = \cos(2\pi k/N) - i\sin(2\pi k/N)$
    (declare #(ulong ulong => (complex-type T)))
    (let ((angle:T (/ (* -2.0 PI (as T k)) (as T N))))
      (make-complex (cos angle) (sin angle))))


;;
;; precompute-twiddles
;;
  ;; -- precompute-twiddles --
  (def-grid-function precompute-twiddles (N &out twiddle-vec)
    (declare #(ulong &out (vector (complex-type T) :address-space :global :align A) => nil))

    ;; Each thread calculates twiddle factors using grid stride
    (loop-vector-stride twiddle-vec (k) ; Loop from k = 0 to N-1 (or length of twiddle-vec)
      (when (< k N) ; Ensure we only calculate N twiddles
        ;; Calculate the k-th twiddle factor
        (let ((twiddle (calculate-twiddle-factor k N)))
          ;; Store it in the output vector
          (set! (~ twiddle-vec k) twiddle))))))

;;
;; fft-butterfly
;;
;; Templated on complex type CT (which implies float type T)
(with-template-type (CT)
  (declare (type-is CT #'is-complex?))

  ;; -- fft-butterfly --
  (def-function fft-butterfly (a b w)
    ;; $A' = A + BW, B' = A - BW$ 
    (declare #(CT CT CT => CT CT)) ; Returns two complex values
    (let ((bw (* b w)))
      (return (+ a bw) (- a bw)))))


(with-template-type (T A)
  (declare (value-is A #'is-alignment?)) ;; T can be any type here

;;
;; reverse-bits
;;
  ;; Helper function to reverse bits (thread-level)

  ;; -- reverse-bits --
  (def-function reverse-bits (index num-bits)
    (declare #(ulong ulong => ulong))
    (let ((reversed-index 0))
      (dotimes (i num-bits)
        ;; Add the least significant bit of 'index' to the most significant
        ;; available position in 'reversed-index'
        (set! reversed-index (logior (ash reversed-index 1)
                                      (bit-and index 1)))
        ;; Shift 'index' right to process the next bit
        (set! index (ash index -1))))
      (return reversed-index)))
;;
;; bit-reverse-copy
;;
  ;; The main grid function

  ;; -- bit-reverse-copy --
  (def-grid-function bit-reverse-copy (input-vec N &out output-vec)
    (declare #((vector T :address-space :global :align A)
               ulong
               &out (vector T :address-space :global :align A) => nil))

    (let ((num-bits (log2 N))) ; Calculate number of bits needed for N indices
      ;; Use grid stride for parallelism - each thread handles multiple indices
      (loop-vector-stride input-vec (i)
        ;; 1. Calculate the destination index by reversing the bits of 'i'
        (let ((dest-index (reverse-bits i num-bits)))
          ;; 2. Read the value from the source index 'i' (coalesced read)
          (let ((val (~ input-vec i)))
            ;; 3. Write the value to the bit-reversed destination index (uncoalesced write)
            (set! (~ output-vec dest-index) val)))))))

;;
;; fft-pass
;;
(with-template-type (T A CT) ; T=float type, A=alignment, CT=complex type
  (declare (type-is T #'is-floating-point?)
           (value-is A #'is-alignment?)
           (type-is CT #'is-complex?)) ; Assuming is-complex? exists

  ;; The main grid function for one FFT pass

  ;; -- fft-pass --
  (def-grid-function fft-pass (input-vec twiddle-vec stage pass-stride N &out output-vec)
    (declare #((vector CT :address-space :global :align A) ; Input data
               (vector CT :address-space :global  :align A) ; Twiddle factors (size N/2)
               ulong ; Current stage (0 to log2N-1)
               ulong ; Stride for this pass (2^stage)
               ulong ; Total FFT size (power of 2)
               &out (vector CT :address-space :global  :align A) => nil)) ; Output data

    ;; Use grid stride - each thread calculates one butterfly output pair
    (loop-vector-stride output-vec (i)
      (when (< i (/ N 2)) ; Each thread handles one pair, so loop up to N/2

        ;; --- 1. Calculate Indices ---
        ;; This is the tricky part: determine which two elements (idx1, idx2)
        ;; and which twiddle factor (k) this thread 'i' is responsible for.
        ;; This specific indexing pattern is for the decimation-in-time algorithm.
        (let ((group-len pass-stride)          ; Length of the sub-DFT groups
              (half-group-len (/ group-len 2))
              (group-num (floor i half-group-len))
              (idx-in-group (mod i half-group-len))
               ;; Indices for the butterfly input elements
              (idx1 (+ (* group-num group-len) idx-in-group))
              (idx2 (+ idx1 half-group-len))
               ;; Index for the twiddle factor W_N^k
               ;; (Note: Needs adjustment based on N and pass_stride)
              (k (* idx-in-group (/ N group-len))))

          ;; --- 2. Perform Butterfly ---
          ;; Check bounds (important if N is not perfectly divisible)
          (when (and (< idx1 N) (< idx2 N))
            ;; Load inputs
            (let ((a (~ input-vec idx1))
                  (b (~ input-vec idx2))
                  ;; Load twiddle factor (using 'k' calculated above)
                  (w (~ twiddle-vec k)))

              ;; Perform the butterfly operation
              (multiple-value-bind (a-prime b-prime) (fft-butterfly a b w)

                ;; --- 3. Store Results ---
                ;; Write the two results to the output vector
                (set! (~ output-vec idx1) a-prime)
                (set! (~ output-vec idx2) b-prime)))))))))

```

Now using soa-vector for better performance

> CODE BELOW NOT ENTIRELY COMPLETE
> also def-orch definition needs more work

```
;; -- load-complex-soa-tile --
(defmacro load-complex-soa-tile (soa-vec tile-y tile-x local-reals local-imags)
  ;; Macro expands into the efficient load logic:
  `(let ((tile-dim (num-cols ,local-reals)) ; Assume square tile
         (local-id-x (get-local-id 0))
         (local-id-y (get-local-id 1)))

     ;; Calculate Global Source Coordinates (Coalesced for Components)
     (let ((source-x (+ (* ,tile-x tile-dim) local-id-x))
           (source-y (+ (* ,tile-y tile-dim) local-id-y)))

       ;; Read Components and Write to Separate Local Tiles
       (when (and (< source-y (length~ ,soa-vec)) (< source-x tile-dim)) ; Adjust bounds check
         ;; Coalesced read from real component array
         (set! (~ ,local-reals local-id- local-id-x) (real~ ,soa-vec source-y))
         ;; Coalesced read from imag component array
         (set! (~ ,local-imags local-id-y local-id-x) (imag~ ,soa-vec source-y))))))

;;
;; fft-pass-soa-tiled -- This requires a 2D enqueue
;;
(def-const TILE_DIM 32) ; 32 is warp size on most hardware

(with-template-type (T A CT) ; T=float type, A=alignment, CT=complex type
  (declare (type-is T #'is-floating-point?)
           (value-is A #'is-alignment?)
           (type-is CT #'is-complex?))

  ;; -- fft-pass-soa-tiled --
  (def-grid-function fft-pass-soa-tiled (input-soa-vec twiddle-vec stage pass-stride N &out output-vec)
      ;; same signature as fft-pass ?
      (declare #((soa-vector CT :global :readable A) ; Input data
                (vector CT :address-space :global  :align A) ; Twiddle factors (size N/2)
                ulong ; Current stage (0 to log2N-1)
                ulong ; Stride for this pass (2^stage)
                ulong ; Total FFT size (power of 2)
                &out (soa-vector CT :address-space :global  :align A) => nil) ; Output data
                (local-size :dims 2 :msg "fft-pass-soa-tiled requires a 2D enqueue"))
      
      ;; Define TWO local memory tiles
      (def-local-mem local-reals (matrix T TILE_DIM TILE_DIM))
      (def-local-mem local-imags (matrix T TILE_DIM TILE_DIM))

      ;; Load the tile for this workgroup
      (load-complex-soa-tile input-soa-vec tile-y tile-x local-reals local-imags)
      (sync-workgroup) ; Ensure loading is done

      (let ((local-id-x (get-local-id 0)) (local-id-y (get-local-id 1))
            (group-id-x (get-group-id 0)) (group-id-y (get-group-id 1)))

        ;; LOOP OVER WORK BLOCKS (If workgroup handles multiple butterflies)
        ;; This part depends on how work is assigned (e.g., each thread doing multiple butterflies)
        ;; Let's simplify and assume one butterfly per thread for now, matching non-tiled.

        ;; LOAD TILE INTO SoA FORMAT
        ;; Use a hypothetical SoA-aware load macro. This handles coalescing.
        (load-tile-soa input-vec local-reals local-imags group-idy group-idx)
        (sync-workgroup)

        ;; COMPUTE BUTTERFLIES IN LOCAL MEMORY 
        ;; This part needs careful indexing based on the FFT stage/stride
        ;; Let's assume 'idx1', 'idx2', 'k' are calculated as before
        (when (< (get-global-id) (/ N 2))
            (let (;; Calculate indices within the local tile
                  (local-idx1 ...) (local-idy1 ...)
                  (local-idx2 ...) (local-idy2 ...)
                  (k ...)) ; Twiddle index
                  
              ;; Load components from SoA local tile
              (let ((a-re (~ local-reals local-idy1 local-idx1))
                    (a-im (~ local-imags local-idy1 local-idx1))
                    (b-re (~ local-reals local-idy2 local-idx2))
                    (b-im (~ local-imags local-idy2 local-idx2))
                    (w (~ twiddle-vec k))) ; Assume twiddles are AoS complex

                ;; Perform SoA butterfly
                (multiple-value-bind (ap-re ap-im bp-re bp-im)
                    (fft-butterfly-soa a-re a-im b-re b-im (real~ w) (imag~ w))

                  ;; WRITE RESULTS BACK TO SoA LOCAL TILE
                  ;; Need barriers between stages if results overwrite inputs needed later
                  (set! (~ local-reals local-idy1 local-idx1) ap-re)
                  (set! (~ local-imags local-idy1 local-idx1) ap-im)
                  (set! (~ local-reals local-idy2 local-idx2) bp-re)
                  (set! (~ local-imags local-idy2 local-idx2) bp-im)))))
        (sync-workgroup)

        ;; STORE TILE FROM SoA FORMAT 
        ;; Use a hypothetical SoA-aware store macro. This handles coalescing.
        (store-complex-soa-tile local-reals local-imags output-vec group-idy group-idx))))

;;
;; fft-butterfly-soa
;;
;; Takes real/imag parts of a, b, w. Returns real/imag of a' and b'.
(with-template-type (T)
  (declare (type-is T #'is-floating-point?))

  ;; -- fft-butterfly-soa --
  (def-function fft-butterfly-soa (a-re a-im b-re b-im w-re w-im)
    (declare #(T T T T T T => T T T T)) ; RealA', ImagA', RealB', ImagB'
    ;; Calculate BW = (b_re*w_re - b_im*w_im) + (b_re*w_im + b_im*w_re)i
    (let ((bw-re (- (* b-re w-re) (* b-im w-im)))
          (bw-im (+ (* b-re w-im) (* b-im w-re))))
      ;; Return A' = A + BW and B' = A - BW
      (return (+ a-re bw-re) (+ a-im bw-im) ; RealA', ImagA'
              (- a-re bw-re) (- a-im bw-im))))) ; RealB', ImagB'

```


And a possible orchestration
```
(with-template-type (T A)

  ;; -- fft -- 
  (def-orchestration fft 

    ;; Define temp buffers (A for bit-reversed, B for ping-pong)
    (make-temp-vector buffer-A ...)
    (make-temp-vector buffer-B ...)
    (make-temp-vector twiddles ...) ; Need twiddle factor table

    (launch-sequential
      ;; Optional: Bit-reverse input into buffer-A
      ((gen-bit-reverse-copy T A) input-vec buffer-A (length~ input-vec))

      ;; Precompute twiddles (could be another kernel or host-side)
      ((gen-precompute-twiddles T A) twiddles (length~ input-vec)))

    ;; Host loop over FFT stages
    (loop-host ((stage 0 (+ stage 1)) :times (log2 (length~ input-vec)))
      (let ((pass-stride (expt 2 stage))
            ;; Determine input/output for ping-pong
            (current-input (if (even? stage) buffer-A buffer-B))
            (current-output (if (even? stage) buffer-B buffer-A)))
        (launch-sequential
          ((gen-fft-pass T A) current-input twiddles stage pass-stride current-output))))

    ;; Final copy to ensure output is in the right buffer
    (copy-final (if (even? (log2 (length~ input-vec))) buffer-A buffer-B) output-vec)))
```

## Fused Softmax 📝

```
(fused-softmax input-vec &out output-vec &optional scratch)
```

Softmax is a mathematical function that takes a vector of numbers (often called "logits") and converts them into a probability distribution. Each output value is between 0 and 1, and all the output values add up to 1. It's famous for being the final step in AI classification models, turning the model's "scores" into a set of confidence percentages.

The fused softmax operation is a workgroup level operation, meaning that once completed, each 
workgroup's values add up to 1. The typical use case is a vector that backs a 2D matrix is the 
input, with the workgroup size set to the row width, and the number of workgroups is equal to 
the number of rows (ie the column height) in the matrix.

`fuzed-softmax` takes an input and output vector, and optionally accepts a 
scratch vector whose length is equal to the local work size.

```
;; -- fuxed-softmaz
(<T A>
  (type-is T #'is-floating-point?)

  (def-grid-function fuzed-softmax (input-vec &out output-vec 
                          &optional (scratch-vec (make-scratch-vector T :match-workgroup-size)))
    (declare #'((in-vec T A) &out (out-vec T A) &optional (scratch-vec-type T))
      (global-size :derive-from input-vec :strategy :one-thread-per))

  (load-local input-vec scratch-vec)

  ;; find max
  (let ((lid (get-local-id))
        (xi  (~ scratch-vec lid))
        (max-val xi))
    (reduce-to-workgroup #'max max-val -INF)

    ;; subtract and exponentiate
    ;; $e^{x_i - \text{max}}$
    (let ((xi-minus-max (- xi max-val))
          (exm    (exp xi-minus-max)))
      ;; overwrite scratch
      (set! (~ scratch-vec lid) exm))

    (sync-workgroup)

    ;; sum across workgroup, 'sum' is uniform after
    (let ((sum (~ scratch-vec lid)))
      (reduce-to-workgroup #'+ sum 0.0)

      ;; divide by sum, store
      (let ((transformF (curry #'/ sum)))
        (store-global scratch-vec output-vec transformF))))))
    
```





## Builtin GPU Functions ✅

These GPU built-in functions help inspect the execution environment. Note that all of 
these are considered "grid level" operations and CANNOT appear in the body of a `def-function`.  They can only appear in `def-grid-function`, `def-kernel` or `def-kernel-exact` . 

Many of these functions are in pairs, like `get-local-id => ulong3` and `get-local-id n => ulong`.  For the variant that takes an `n` argument, `n` must be known at compile time. 
If you need to use a runtime `n`, get the vector `ulong3` and index it `(~ (get-local-id) n)`


| Function | Return Type | Description |
| :--- | :--- | :--- |
| `get-work-dim` | `uint` | Number of dimensions the kernel was launched with (1, 2, or 3). **SPV only** — implemented as a hidden kernel parameter via the `WorkDim` built-in (SPIR-V value 40). No PTX equivalent; emits NYI error on PTX. |
| `get-local-id` | `ulong3` | 3D thread index inside the workgroup. |
| `get-local-id n` | `ulong` | Scalar thread index inside workgroup for compile-time dimension `n`. |
| `get-local-work-size` | `ulong3` | Total size of the workgroup in 3 dimensions. |
| `get-local-work-size n` | `ulong` | Scalar workgroup size for compile-time dimension `n`. |
| `get-workgroup-id` | `ulong3` | 3D index of the workgroup within the grid. |
| `get-workgroup-id n` | `ulong` | Scalar workgroup index for compile-time dimension `n`. |
| `get-num-groups` | `ulong3` | Total number of workgroups in the grid across 3 dimensions. |
| `get-num-groups n` | `ulong` | Scalar group count for compile-time dimension `n`. |
| `get-total-groups` | `ulong` | Total number of workgroups as a scalar (product of the grid dimensions). Synthesized from `get-num-groups`. |
| `get-global-id` | `ulong3` | 3D thread index within the entire grid (always starts at 0). |
| `get-global-id n` | `ulong` | Scalar global thread index for compile-time dimension `n`. |
| `get-global-id-abs` | `ulong3` | Absolute thread index: `get-global-id` + `get-global-offset`. |
| `get-global-id-abs n` | `ulong` | Scalar absolute thread index for compile-time dimension `n`. |
| `get-global-work-size` | `ulong3` | Total number of threads in the grid across 3 dimensions. |
| `get-global-work-size n` | `ulong` | Scalar global work size for copmile-time dimension `n`. |
| `get-total-threads` | `ulong` | Total number of threads as a scalar (product of the grid). Synthesized from `get-global-work-size`. |
| `get-global-offset` | `ulong3` | The starting offset of the grid in 3 dimensions. |
| `get-global-offset n` | `ulong` | Scalar global offset for compile-time dimension `n`. |
| `get-local-linear-id` | `ulong` | Flattened 1D index of the thread within its workgroup. Synthesized: `z*lws.y*lws.x + y*lws.x + x`. |
| `get-local-linear-size` | `ulong` | Total number of threads in a single workgroup. Alias: `get-local-work-size 0 * 1 * 2`. |
| `get-global-linear-id` | `ulong` | Flattened 1D index of the thread within the entire grid. |
| `get-global-linear-size` | `ulong` | Total threads in the grid. Alias of `get-total-threads`. |
| `sync-workgroup` | `void` | Synchronizes all threads within a workgroup. |
| `mem-fence` | `void` | Ensures memory ordering across threads (global + local). |

- get-timestamp   returns the high resolution clock counter. ( %clock64 register).

## Forgotten 📝
- when-thread-in-warp-is 


## Strings - Compile Time and Run Time 📝

### Compile Time Strings 📝

Most strings in Crisp are compile time. They follow the Common Lisp parsing rules
(which is mostly just begin and end with double quote. "Like Me!!" )

The are mostly output into the hoisting example code.

#### `string-concat` 📝

`(string-concat <Expr1> <Expr2> ... <ExprN>) => string`

`string-concat` can be used to string some things up. Each expression can
be a different "printable" type, which is either a numeric type or a string.
The final string result is just all those things together, separated by spaces.

### Runtime Strings 📝

Runtime strings are a completely different animal. 

The only runtime strings Crisp supports are the ones output into the debug logging
buffer. That buffer is written into by `r-t-output`, `r-t-assert`, `die` and their variants. 

The buffer is a not a buffer of ASCII characters. It is a buffer of bytes, organized in groups of four ( `uint32_t` ), endianess determined by the host platform.  The buffer has a simple format. 
It is a series of packets, each like so.
`[IDENTIFIER][LENGTH][ x1 ][ x2] ..[xN]`   
Where `N` is the value in `LENGTH`.  

`IDENTIFIER` is a number, and in the accompanying metadata there is a table with 
each identifier and its matching format string and params, from which the final string
can be constructed.
```
{
  "id": 123,
  "format_string": "hello: % % % there",
  "params": [
    {"name": "i", "type": "int32"},
    {"name": "j", "type": "float32"},
    {"name": "k", "type": "uint64"}
  ]
}
``` 

Crisp comes with scripts that can recombine these, and a small standalone tool as well.

This formulation for string handling is analagous to the OSL "Journal Buffer" system. The
hope is that their performance penalty is minimal which will encourage use.

NOTE: Under consideration is just outputting full strings into a uchar buffer. That is simple
and no doubt attractive to Crisp users. This issue is that doing so can easily have 
a HUGE impact on performance. On the plus side, uchar 
output would be easily to stream out, which means it would be composable with other 
tools (like grep and tail). This might show up with a `--logging-output=string` type of 
formulation. 



## Logging and Debugging 📝

> Overengineer much?
>
> (asked of Author)

When a kernel is running on a GPU it is often on a different device, with a completely different memory and addressing system and no 
access to stdout or the file system. This makes debugging and logging challenging. Crisp attempts to assist with two different systems:
 - compile-time messaging, so that the compiler can be directed to output messages and information. 
 - side channel logging at runtime.  This has to be elected when compiling your kernel and the hoisting/enqueue code has to participate as well.


### Compile Time Output and Assert ✅

#### `c-t-output`  ✅

`(c-t-output <expr1> ... <exprN>)`
"c-t" stands for "compile time".  This variadic macro just takes a series of expressions and it will evaluate them at compile time and output them when compiling.   This can be particularly handy when used with `macroexpand` or `macroexpand-1`. A space character is inserted between each expression. If any of the expressions is
not evaluable at compile time that will merely be noted. 

#### `c-t-assert` ✅

`(c-t-assert <testExpression>  <expr1> ... <exprN>)`
This is akin to `static_assert` from C. The `<testExpression>` will be evaluated by the compiler. If it is true then
the compilation continues undisturbed.  But if it is false, then the compiler errors and ceases commpilation. The remaining arguments are output along with the error, separated by spaces. If one of the remaining expressions is
not evaluable at compile time that'll be noted in the output. 

If `<testExpression>` is not evaluable at compile time, it will lead to a compilation error.



### `(die "disaster")` ⚠️

```
(when (< index 0))
  (die "the index is negative? How did that happen?"))   ;; desperate times
```

`die` is a small but critical component. If `--logging-output` was NOT elected, then 
`die` simply halts the kernel.  
But if the kernel is debugging output then its message is recorded into the debug output buffer 
and then the kernel is halted. 
Note that the message argument to `die` must be known at compile time.

Importantly, space is ALWAYS reserved in the output buffer for the `die` message.

`die` records a tiny 16 byte record (per workgroup) into global memory
and then halts the kenrel. It is up to the host side caller to retreive that data and 
check it. The 16 bytes don't contain any text message like the one above, instead it
has a numeric identifier which can be looked up in either the metadata or the hoisting code
to see the original string.  The 16 bytes record 
- string_id
- file_id
- line_no
- local_id x, y, z



Possible Implementation
```
(defmacro (die msg-string)
  
  ;; compiler packs all the data at compile-time
  (let* ((my-string-id (get-compiler-id-for msg-string))
         (my-file-id (get-compiler-id-for (file)))
         (my-line-no (line))
         
         ;; pack the primary 64-bit "flag"
         (my-primary-data (pack-u64 my-string-id my-file-id my-line-no))
        
         ;; get my workgroup's slot in the global "die" buffer
         (my-wg-id (get-workgroup-id))
         (my-die-slot-address (~ die-buffer my-wg-id)) ;; 'die-buffer' captured non-hygenically
         (primary-field-address (& (~ my-die-slot-address 'primary))))  ;: & 
        
    
    ;; try to claim the slot.
    ;;    (cas address, expected_value, new_value)
    (let ((old-val (atomic-cas! primary-field-address 0 my-primary-data))
          (old-val (atmoic-binop! primary-field-address (ident my-primary-data) 0)))
      
      ;; check if I won the race
      (when (= old-val 0)
        ;; I WON! I am the first thread to die in this WG.
        ;; Now I safely write the *secondary* data.
        (let* ((my-local-x (get-local-id 0))
               (my-local-y (get-local-id 1))
               (my-local-z (get-local-id 2))
               (my-secondary-data (pack-u64 my-local-x my-local-y my-local-z 0))
               (secondary-field-address (& (~ my-die-slot-address 'secondary))))
          (set! (~ secondary-field-address) my-secondary-data))))
        
    ;; regardless of if I won or not, I must halt.
    (device-halt!)))
```

### Runtime Asserts ⚠️

There are various asserts available at runtime. They are available if the debug output is enabled or not, but their behavior changes slightly.

The runtime asserts always evaluation their test expression.  If it is `true`, then
the kernel continues on unperturbed. If it is false, then `die` is called.

If logging output is on (via `--logging-output`)
then these asserts evaluate all their remaining expression arguments and output them into the relevant logging
buffer subdivision before calling die to terminate the kernel execution.

If debug output is NOT on, the assert still calls `(die)` on failure. 

These all use `die` underneath, so some amount of thread id and line numbers, etc are recorded.



#### `r-t-workgroup-assert` 📝

`(r-t-workgroup-assert <testExpression>  <expr1> ... <exprN>)`

Akin to `assert` in C. This macro will result in an evaluation of `<testExpression>`. If true, fine. The
kernel execution continues normally. But if if false, then it behaves like the assert behavior described above
and then terminates calling `die`.


Note that `<testExpression>` reduced across ALL the threads in a workgroup. If it is false in ANY of them,
then the assert behavior is tripped.  So `r-t-workgroup-assert` is protected from "firehose" problems.


#### `r-t-assert` ✅
```
(r-t-assert <testExpression>  <expr1> ... <exprN>)
(r-t-assert-0 <testExpression>  <expr1> ... <exprN>)
```

Behaves like the asserts described above.  Ultimately, will call `die` if `<testExpression>` is false.

`r-t-assert` is engaged by EVERY thread.  It is not screened or limited to a single workgroup.

In contrast, the variant `r-t-assert-0` uses the `when-thread-is 0` guard and so the 
check and output is only performed in one thread.

##### WARNING - FIREHOSE
If `r-t-assert` appears loose in your kernel, it could result in many threads simultaneously
trying to dump strings into a debug buffer. Use the debugging subdivisions to control it (see [Debugging Implementation](#debugging-implementation)), or consider using `r-t-workgroup-assert` instead, or `r-t-assert-0`, or
surroud `r-t-assert` in one of the other thread guards.

```
(when-thread-in-group-is 0
   (r-t-assert (< 0 lives) "no lives left"))
```

### Runtime Logging 📝

#### `r-t-workgroup-output-if` 📝

`(r-t-workgroup-output-if <testExpression>  <expr1> ... <exprN>)`

If the kernel is compiled with the `--logging-output` flag then this macro will reduce 
`<testExpression>` across all the threads in a workgroup. If it is true in any of them,
then the the logging occurs in just one of them. Afterwards, kernel execution continues normally.

If the compiler flag is not elected, this entire form is compiled away. 

#### `r-t-output` 📝

```
(r-t-output <expr1> ... <exprN>)
(r-t-output-0 <expr1> ... <exprN>)
```
"r-t" stands for "run time".  If the kernel is compiled with the `--logging-output` flag then this macro will output
each of its expressions into the debug output memory. Note that this output will have to be retrieved by the hoisting 
code once the kernel is done executing. 
If the `--logging-output` flag is NOT present when the kernel is compiled, then this expression and all arguments
are simply skipped by the compiler. 

`r-t-output` is engaged by EVERY thread.  It is not screened or limited to a single workgroup.

In contrast, the variant `r-t-output-0` uses the `when-thread-is 0` guard and so the 
check and output is only performed in one thread.

##### WARNING - FIREHOSE
If `r-t-output` appears loose in your kernel, it could result in thousands of threads simultaneously
trying to dump strings into a debug buffer. Use the debugging subdivisions to control it (see [Debugging Implementation](#debugging-implementation)), or consider using `r-t-workgroup-output-if` instead, or 
surroud `r-t-output` in one of the thread guards.

```
(when-thread-is 0
   (r-t-output "reached midpoint" someVal))
```



### Logging Utilities 📝

- `(line)`  evaluates at compile-time to the line number of the file where it appears.
- `(file)`  evaluates at compile-time to the name of the .crisp file where it appears.

Note that the routines above always include line numbers and file identifiers automatically,
so the practical use of these logging utilities is rare - mostly reserved for dev macros.

## Debugging Implementation 📝

The perennial challenge of using debug logging on a GPU is that there is just TOO MUCH of it. 
Thousands of threads all logging identical messages isn't helping anyone, especially if the 
memory has to be anticipated and allocated in advance, and especially when there is inevitably contention
between threads to write to that memory. Performance degrades, output buffers fill up, and
tempers rise.


Crisp attempts to ameliorate that by providing SUBDIVIDED logging, as well as "first N" and "last N" 
message options to address debug buffer overflow. What this means is the debug buffer handed to the kernel
can be divided in differrent ways, ways to limit who logs, or ways to ensure that certain critical logging is performed and accessible.  Unfortunately, these options have to be
selected at compile time, rather than when enqueueing the kernel. Perhaps some intrepid user
can use the [In-Memory Compilation API](#in-memory-compilation-api) to make a handy tool.

### So You Want Debug Logging 

#### `--logging-output`  Master Switch. 📝

The `--logging-output` flag turns ON debug logging when it is present, or off when it is not.

When the `--logging-output` flag is set then the compiler alters the compilation in several ways:
- an additional `debug-vector-type` argument is added to the Kernel in the first argument position
- every `r-t-assert` and `r-t-output` variant is actually enabled and compiled, rather than being
  stripped out
- `maybe` `Err:` string expressions are compiled to output as well
- those function call paths to those outputting forms ALSO have their params modified such that
the debug vector is now in the first param position
- `(is-logging?)` expression evaluates to T at compile time.

The debug output vector base type is a `(vector ulong :align :compact :address-space :global)` and it must
be setup by the host. In this part of the document we refer to this vector as "the debug buffer" or 
just "the buffer". 

### Subdivide Subdivide Subdivide - the "other" debug flags 

Three debug flags govern subdivision by scope, target, and call site. Two more flags
let you select which workgroups or warps are participating in the logging, and the
logging mode.  That's a lot of terms, but the whole system is pretty straightforward.

#### --logging-scope 📝

`--logging-scope=spread|dedicated`

If the scope is "dedicated" then the entirety of the logging buffer will be available
to one "target" which is either a workgroup or a warp (selected by target and index flags).  
But if the scope is "spread", then the buffer is evenly split by the number of workgroups.

Default is `spread`.

#### --logging-target 📝

`--logging-target=workgroup|warp`

If the scope was `dedicated` then this simply specifies workgroup vs warp.
If the scope was `spread` and `warp` is chosen, that means only one warp per workgroup
will be enabled for logging, and each takes the full share set aside for its parent workgroup.
If scope was `spread` and the target is `workgroup` then each workgroup gets an equal share 
of the buffer.

Default is `workgroup`

#### --logging-by-call-site 📝

`--logging-by-call-site`

This option is ONLY available with dedicated debug logging scope ( `--logging-log-scope=dedicated` ).
With this option all the possible debug "call sites" (ie the lines that use `(maybe)` constructs
or call `r-t-assert` etc ) up and down the call chain of the kernel are identified and counted.
Then the debug output buffer is subdivided by call sites.  Thus each one get a little reserved
output area for itself.

#### --logging-mode 📝

`--logging-mode=first-n|last-n`

When set to `first-n` then the messages are output into the buffer subdivision until it is full, then
they stop. When set to `last-n`, then the buffer subdivision is treated as a circular buffer and the
later entries overwrite the earlier ones. 
IMPORTANT NOTE: `last-n` mode requires the debug log target be warp (`--logging-target=warp`).

Defaults to `first-n`

#### --logging-wg-index 📝

`--logging-wg-index=0-N`

This flag is only relevant if the scope is set to dedicated (`--logging-scope=dedicated`).

When using dedicated scope Crisp needs to know which workgroup. This flag can be given
a group number (from 0 up to the number of workgroups).

#### --logging-warp-index 📝

`--logging-warp-index=0-N`

This flag is relevant whenever the debug target has been set to `warp` (in BOTH `spread` and `dedicated` scopes).

Select which warp in a workgroup should perform debug logging to the buffer. It can be the warp number (from 0 to the max number of warps, ie 32) 

### Common Debug Flag Configurations 📝

#### Default (Low Overhead):
- --logging-scope=spread
- --logging-target=workgroup

Result: The buffer is split evenly, giving every workgroup a small "first-N" log slot.

#### Focus on ONE Workgroup:
- --logging-scope=dedicated
- --logging-target=workgroup
- --logging-wg-index=42

Result: The entire buffer is given to workgroup 42 for a large "first-N" log.

#### Focus on ONE Warp:
- --logging-scope=dedicated
- --logging-target=warp
- --logging-wg-index=42
- --logging-warp-index=0

Result: The entire buffer is given to warp 0 of workgroup 42 for a "first-N" log.

#### "Last-N" (The Champagne Case):
- --logging-scope=dedicated
- --logging-target=warp
- --logging-wg-index="last"
- --logging-warp-index=0
- --logging-mode=last-n

Result: The entire buffer is given to warp 0 of the "last standing" workgroup, operating in "Last-N" (rolling) mode. This is safe because target=warp.

#### Call Sites
- --logging-scope=dedicated
- --logging-target=workgroup (or warp)
- --logging-wg-index=42
- --logging-subdivide-by-site

Result: The buffer for the dedicated target (WG 42) is subdivided, giving each log site its own "reserved" tile (running in "first-N" mode).





## Conditional Compilation ✅

Crisp uses the `#+` and `#-` reader macros to do conditional compilation. Unlike Common Lisp, 
these are not keyed off of `*features*` (which is not supported) but intead the parameters,
which can be set via `def-parameter` or the `-D` compiler flag.

The #+ reader macro inspects the parameter that follows it. If that parameter's value is not nil, 
the subsequent S-expression is read and included in the compilation. 
If the parameter's value is nil, the reader skips the next S-expression entirely.
C/C++ programmers can consider it like `#if` that doesn't require an `#endif`

`#-` is the reverse of `#+`

Example.
```
(def-parameter full_ride T)
(def-parameter sleigh_ride nil)
(def-parameter over_ride 0)

#+full_ride
(def-type A ...)

#+sleigh_ride
(def-type B ...)

#+over_ride
(def-type C ...)
```
In the above example, `A` would be defined because `full_ride` was `T`.
But `B` would NOT be defined, because `sleigh_ride` was `nil`
And `C` would also NOT be defined, because  `0` puns as false.

And, the following compilation line would reverse those completely:
```
crisp.exe -Dfull_ride=nil -Dsleigh_ride=T -Dover_ride=1  ... etc
```


#### another example

```
;; -- calculate --
(def-function calculate (x)
  (declare #(float => float))
  (let (#+(target-has :fp64)
        (precision   (get-high-precision-v))

        #-(target-has :fp64)
        (precision   (get-low-precision-v)))
      ...))

```
See below for `target-has`.

### defmacro ✅

Crisp supports defmacro, which makes it very easy to 
employ conditional compilation off ANY variable known at 
compile time.

### target-has / device-has 📝

#### `(target-has <prop> &optional might:bool)`
`(target-has :fp64 T)`

`target-has` is a compile time ONLY macro that accepts a single keyword symbol for some
property. If the current compilation target definitively supports that property, it is T. 
If the compilation target definitively does NOT support it, it is nil.  But if the compilation
target is flexible (like SPIR-V) where it might or might not be supported,  then if the third
`might` argument is provided it evalutes to that.  In that case, were `might` not provided, it would be a compilation error.

#### `(device-has :fp64)`

`device-has` acts like `target-has` at compile time. If the target definitively supports
the capability (or not) then the expression evalutes similarly.  But in the event the
answer is not definitive at compile time, then the expression is replace by a runtime check.
At runtime it will detect the property and evaluate accordingly. 

In the event that some future exotic feature is neither compile time nor runtime determinable, the compiler
will error. 

```
Implementation Notes: for SPIR-V, device-has will require specialization constants, which means
coordination with the hoisting code.
```

## Assist defmacro Development 📝

Crisp has some constructs that are useful to developers leveraging `defmacro` and needing
to navigate the Crisp-specific terrain.

#### `is-thread-level?` 📝

`(is-thread-level? function-identifier) => T/nil`

`is-thread-level?` is a compile time introspection function that can help write certain types of macros.  It returns
`T` if the function in question was defined with `def-function` and `nil` for anything else.

Usage Example
```
(defmacro process-vector (vec func)
  ;; Check if 'func' is a simple, thread-level function
  (if (is-thread-level? func)
      ;; If YES: Wrap it in a grid-level primitive
      `(map-stride ,func ,vec ,vec)
      
      ;; If NO: It must be a def-grid-function, so just call it
      `(,func ,vec)))
```

#### `get-return-type` 📝

`(get-return-type function-identifier) => <Type>`

`get-return-type` is a compile time introspection function for macro writing. It returns the return type of the 
function in question. This is NOT the same as `return-type-of` which is a type expression meant to be used in 
a type declaration.  

Remember that Crisp types are NOT available at runtime. 

Example
```
(defmacro some-HOF-op (func A B &out C)
  ;; do some compile time checking
  (let ((ResultType (get-return-type func)))
    ;; 4. Check if the output vector 'C' matches.
    (c-t-assert (type-equal (element-type C) ResultType) "Output vector C has wrong type")
    ...
```

#### `get-signature` 📝

`(get-signature function-identifier)` => <Signature>`

```
(get-signature #'int_vector_sum) =>  `((vector int :align :compact  :address-space :global) &out (vector int :align :compact  :address-space :global))
```


#### `can-call?` 📝

`(can-call? function-identifier &rest argument-types) => T/nil`

`can-call?` is another compile time introspection construct for macro writers. With it you 
can determine if some function is "callable" with some set of argument types. 

Example:
```
(can-call? #'+ 'int 'float) =>  T 

(can-call? #'* 'int 'point) => nil
```

#### `get-struct-members` ⚠️

`(get-struct-members 'point) => '(x y)`

This is a low-level introspection macro useful for writing other macros (such as `with-struct-accessors`)
For some named struct type it returns a list of property name symbols. 

Example (Reminder: this is all compile-time evaluated code from a macro, not runtime code in any Crisp top level execution context)
```
(let ((member-count (length (get-struct-members 'my-struct))))
  ...)
;; OR
(when (member 'energy (get-struct-members 'particle-struct))
  ...)
```

#### `get-struct-types` ⚠️

`(get-struct-types 'point) => '(float float)`

Another low-level introspection macro. For the named struct it returns a list of type expressions.

#### `get-c-t-length` 📝

`(get-c-t-length <vector-or-tensor-type>) => length or nil`

`get-c-t-length` is passed a vector type and will return its length if it is known at compile time.
Otherwise it returns nil.  Can be used for various purposes, including making unrolling decisions.

#### `get-current-context` 📝

`(get-curret-context) => :dispatch / :grid / :thread`

Returns the context at the place where the macro is called. Useful if you need to write macros
that alter behavior based on context in order to provide a predictable experience for the caller.


#### `is-logging?` 📝

`(is-logging?) => T or nil`

Returns true if the file is being compiled with the `--logging-output` flag 

#### `is-runtime-checking?` 📝
`(is-runtime-checking?) => T or nil`

Returns true if the file is being compiled with the `--runtime-checks` flag

#### `is-set?` 📝
`(is-set? someVar) => T or nil`

Used to check `&optional` and `&key` values before use.

Note that if the value has a default set, then is-set? is unnecessary, it will
always be True.
```
(def-function someone (&optional a)
  (declare #'(&optional int => int))
  (when+ (is-set? a)
    ;; do something
    ...))

(def-function needless (&optional (a 100))
  (declare #'(&optional int => int))
  (if (is-set? a)   ; '(is-set? a) is T by virtue of the default value (100)
    (do-something)
   (never-called))) 
```


#### `(declare (grid-level))` ✅

This was mentioned earlier, under  [Grid Level Operations](#grid-level-operations)
A macro can add this declaration to a `progn` when doing grid level ops, and then the compiler
will ensure the proper call context restrictions are observed.

#### `(declare (warp-convergent))` and `(declare (workgroup-convergent))` 📝


The `(declare (XXXX-convergent))` tag is a safety contract between your new macro and the Crisp compiler's static analyzer.
When you add this declaration, you are "tagging" your macro and telling the compiler:
> "This code block MUST be called by all threads in its group (warp or workgroup) to avoid a deadlock. You (the compiler) are now responsible for ensuring this rule is followed."

This tag enables Crisp's `(check-divergence)` static analysis. The compiler will then throw a compile-time error if an end-user tries to call your macro from inside a divergent branch (like a `(when (< (get-local-id 0) 10) ...)`).

Many constructs in Crisp, like `sync-workgroup` or shuffle operations, automatically inject the appropriate "taint", 
so you don't need this declaration when those are present. But it is easy to write a macro that _assumes_ warp or workgroup wide operation. In that case, use the declaration so the compiler will help users of your macro. 

## `entrypoint` 📝
```
(def-grid-function foo (...)
  (declare (entrypoint))
   ...)
```

`entrypoint` is a declaration that can appear in any non-kernel function. It is similar to `DllExport`, in that it
tells the compiler that function is a top-level API function that should not be optimized away.
Further `entrypoint` functions are compiled "library-wise", meaning the function and all its dependencies get
bundled together (typically in a .bc file). This results in fast compilation for any kernel that uses it.

## `defmacro` and `T`

Remember that `defmacro` executes in a Common Lisp environment, not Crisp. And while it is
common in Crisp to use `T` as a template type placeholder (like in C++), in 
Common Lisp, `T` is reserved and means True.  If using `defmacro` over types, use `typ` or
something.




## Static Analysys 📝

> The minute you finally understand how a GPU works is the minute you are wrong.
>
> — John Owens, UC Davis

If you were ever wondering why Crisp is intentionally not Turing-complete, this section is the answer. 
Because every kernel is guaranteed to terminate, its control flow is finite and can be completely analyzed by the compiler. 
This allows Crisp to sidestep the Halting Problem, unlocking a suite of deep static analysis tools 
that would be impossible to implement reliably in a general-purpose language.

To help programmers reach full GPU performance and avoid errors, Crisp includes some static analysis ability. 
It makes little sense to apply these globally, as that would result in a lot of false positive warnings. 
Therefore the Crisp static analysis is "opt-in".

These opt-in analysis will slow down the compilation. Use the `--no-static-analysis` compiler flag to skip them.

Note, also, that the static analysis usually requires two pass compilation. If you elect `--single-pass` they are likely
skipped. The compiler will warn you if it is skipping any.  Don't rely on `--single-pass` to skip them. 
If you have static analysis opt-ins within your file, 
and you don't want that analysis performed, use `--no-static-analysis`. 

### declaim ⚠️

We've already seen `declare` introduced earlier. Whereas `declare` must appear in the context of some `progn`, 
`declaim` is done at the top-level of your .crisp file, usually at its beginning.
Like `declare`, `declaim` is enforced at compile-time and is erased from the runtime execution.

Example:
```
(declaim (check-coalesce #'my_kernel #'my_2D_memcpy))
```
In the example above, the "coalescence check" (see below) would be run on `#'my_kernel` and `#'my_2D_memcpy`, but not on any 
other functions or kernels.

If you want a check conducted on EVERY function and kernel in the .crisp file, simply `declaim` it directly.
Note that except for possibly `check-barriers`, running checks like this on EVERY function is probably a bad idea.
It's slow, and you'll likely trip a bunch of warnings that shouldn't really be applied to a particular function.
(Full Disclosure: `check-barriers` is slow too).

```
(declaim (check-barriers))
```
In the example above the "barrier check"  (see below) would be run on every function and kernel.

### check-coalesce 📝

```
;; in a kernel or function progn:
(declare (check-coalesce))  

;; top level of a file.
(declaim (check-coalesce #'some-function))
```

Coalesced memory access is faster than just random memory access. But it requires
- warp-level operation: access to be performed by threads in a single warp
- uniform: all threads execute the same load or the same store instruction at the same time
- contiguous and linear access - the threads' memory addresses should be adjacent and follow
  the same order as the thread id.

The compiler can check for this.  If you put a `check-coalesce` in a kernel or functions `declare` block,
or specify the kernel/function in a top level `declaim`, then this check will be performed
and a warning emitted if the function in question is not using coalesced access and a note if it is ok.


### check-bank-conflicts 📝

```
;; in a kernel or function progn:
(declare (check-bank-conflicts))

;; top level of file
(declaim (check-bank-conflicts #'some-function))
```

Local/shared memory is divided into a number of parallel memory banks (typically 32). 
Performance is highest when threads in a warp access different banks. If multiple threads
in a warp access the same bank simultaneously, it's a bank conflict, and the
accesses are serialized, killing performance.

When this check is enabled, the compiler analyzes all access to `:local` vectors. 
It looks at the index calculation for each thread within a warp. If it can prove that multiple
threads are accessing memory with a stride that is a multiple of the bank count 
(e.g., thread i accesses local_array[i * 32]), it issues a warning.  It will emit a note if it 
the analysis completes and no conflicts are found.


### check-divergence 📝

```
;; in a kernel or function progn:
(declare (check-divergence))

;; top level of file
(declaim (check-divergence #'some-function #'other-function))
```

While some divergence is unavoidable, sometimes you may write a function that you believe
should be completely uniform for all threads in a warp.

BUT, it is easy to overlook that some Crisp macros (for example, 'when-thread-id-is`) or
other behaviors may introduce divergence.

This check looks specifically for warp level divergence.
When this check is enabled,  the compiler analyzes all conditional branches (if, cond) inside the function. 
If it finds any branch whose condition is not a uniform value 
(i.e., the condition depends on something like get_lane_id or a non-uniform memory load), 
it will emit a warning.  It will emit a congratulatory note if it is ok.

<!-- NOTE
(declare (convergent)) can be used to declare a block as non-diverging, which will trip this error.
We use that declaration on potentially deadlocking calls.

reduce-to-warp  has it now.  Very important that reduce-to-warp is called by ALL the threads
in the warp, not just some.  

-->


### max-registers / warn-max-registers 📝

```
;; in a kernel or function progn:
(declare (max-registers 64))
(declare (warn-max-registers 64))
```

This analysis cannot be elected in `declaim`. It is function or kernel specific.

`max-registers` and `warn-max-registers` are advanced checks. These checks are slightly 
easier to use if you have performed compilations already
and are looking at the register usage enumerated in the metadata file. 

These check set a "performance budget" that sets an upper bound on how many registers a function or kernel requires.
The compiler can estimate how many registers a function will require. If its estimate exceeds
the declared budget, a warning is issued.

For example:

> WARNING: Register pressure for 'my_kernel' is estimated at 72, exceeding the declared budget of 64. 
> This may lead to reduced occupancy.


For `warn-max-registers`, there is only the warning emitted, no other change occurs.

`max-registers`, on the other hand, is NORMATIVE. In addition to the warning, 
the compiler will TRY TO FIT the kernel 
to `max-registers`, which may mean that other variables will experience "register spill"
and be moved to local memory. Only use `max-registers` if you know what you are about.


### check-barriers 📝

```
;; in a kernel or function progn:
(declare (check-barriers))

;; top level of file
(declaim (check-barriers #'some-function #'other-function))
```

If a `(sync-workgroup)` is placed inside a conditional branch that not all threads in a workgroup will execute, the kernel will deadlock.
Crisp performs this check automatically for any use of `when-thread-in-group-is`, whether this check has been elected or not.
But with this check declared, Crisp will try to analyze other thread divergences and barriers looking for deadlock potential.

`check-barriers` will examine the Crisp branching control flow constructs (like `if` and `cond` etc) to 
see if perhaps a barrier is performed in one branch but not another, and warn about it.  


### miscellaneous ⚠️

- if -stride or -loop has an atomic op inside, turn off the users machine.



## Auto Differentiation (AD) ✅


### `--differentiate` ✅

The `--differentiate` flag enables the Crisp Automatic Differentiation (AD) engine. When this flag is active, the compiler performs a reverse-mode transformation on compatible GPU kernels, generating a corresponding gradient kernel (the "adjoint") for every forward kernel defined in the source.



#### Requirements for Differentiable Kernels

To be compatible with `--differentiate`, a kernel must meet the following criteria:

- Explicit Output (`&out`): A differentiable kernel must have at least one `&out` parameter. This parameter represents the "primal" result of the calculation.
- No Recursion: As with all Crisp kernels, recursion is disallowed, which ensures a statically determinable execution graph for the backward pass.
- Opt-out via `forward-only`: If a kernel performs non-differentiable side effects (like logging or specific data-shuffling), it should be marked with `(declare forward-only)`. The compiler will skip gradient generation for these kernels.
- Input Types: Float, double, and integer scalars are all differentiable inputs.
  Integer inputs receive *promoted* adjoints (small ints → `float`, `long`/`ulong` →
  `double`) since gradients are inherently continuous. A kernel whose inputs are
  *exclusively* non-differentiable (e.g. all `ulong` indices with no float math)
  receives a trivial backward — the gradient kernel is still emitted but contains
  no chain-rule computation.
- Composite Inputs: Records, structs (including nested), tensors, and cells are
  all supported at the kernel boundary. See "Generated Gradient Signature" below
  for how each is paired with its adjoint.
- Control flow: `if` / `when` / `unless` / `cond`, `let`, and `dotimes` all
  differentiate, as do their uniform `+` variants — `if+`, `when+`, `unless+`, and
  `dotimes+`. The backward pass mirrors the forward control flow; a uniform `+`
  condition or loop bound is a *forward-time* concern, already discharged before the
  gradient runs, so the generated backward loop is a plain `dotimes` and the backward
  branch a plain `if`. Value-producing conditionals (e.g.
  `(set! (~ res) (if+ cond a b))`) propagate the result adjoint into whichever branch
  was taken; an untaken `when+`/`unless+` contributes zero gradient.


#### The Generated Gradient Signature

The backward kernel's signature mirrors the forward kernel's, with each
differentiable parameter paired to a corresponding adjoint. The shape of that
pairing depends on the parameter's type.

##### Scalar primals

For a forward kernel with scalar inputs and outputs:

```
;; Forward:
(def-kernel foo (A B &out C D) ...)
;; Generated Backward:
(def-kernel foo_grad (A B C D C_grad D_grad &out A_grad B_grad) ...)
```

- Primals (A, B, C, D): The original inputs and outputs are provided so the
  backward pass can use them to compute local derivatives.
- Incoming adjoints (C_grad, D_grad): The seed gradients flowing back from
  downstream. Carry the *promoted* type of their primal.
- Outgoing adjoints (A_grad, B_grad): The computed input gradients,
  populated via the chain rule.

##### Records at the kernel boundary

A record parameter is destructured into one `&out` grad-cell per leaf field.
Nested records recurse field-by-field. Given:

```
(def-record Point ((x float) (y float)))
(def-kernel foo (P &out C) ...)
```

the generated backward exposes one grad-cell per primitive leaf:

```
(def-kernel foo_grad (P C C_grad &out P.x_grad P.y_grad) ...)
```

##### Structs at the kernel boundary (Shadow Structs)

Unlike records, structs are *not* destructured — they cross the boundary as a
single value. To carry their gradient, the compiler auto-mints a paired
**shadow struct** for every `def-struct NAME`: a parallel struct named
`NAME_ADJ` with each field replaced by its promoted adjoint type. Nested
structs recursively reference the inner struct's shadow.

Given:

```
(def-struct Point ((x int) (y float)))     ;; auto-mints Point_ADJ with
                                            ;; (x float) (y float)
(def-kernel foo (P &out C) ...)
```

the backward kernel carries a single `&out` cell of the shadow type:

```
(def-kernel foo_grad (P C C_grad &out P_adj) ...)
```

where `P_adj` is `(cell Point_ADJ :address-space :global)`. The backward
walk writes per-field adjoints into the shadow's fields, then a final
`set!` lands the assembled shadow.

##### Tensors and cells at the kernel boundary

Tensor and cell primals are paired by a same-shape grad-handle whose element
type is the promoted adjoint type. Accumulation into indexed slots uses
atomic-add by default (or `set!` under `one-thread-per-element`).


#### Memory Safety and Accumulation

Because multiple threads may contribute to the gradient of a single input element (a common occurrence in "scatter" operations), the generated gradient kernel defaults to using Atomic Operations for all writes to `&out` gradient handles. This ensures mathematical correctness even in complex, non-injective mappings.

However, if the kernel strategy is declared as `one-thread-per-element`, then the generated gradient kernel will use `set!` instead of atomic operations.

#### Sub-Function Differentiation

`def-function`s called from a differentiable kernel are themselves
differentiated. Each receives a `_GRAD` companion whose signature uses a
**mixed convention**:

- Scalar contributions return through Crisp's multi-value return — the
  `_GRAD` function's primary return is the original return value, with
  per-scalar-input gradients trailing.
- Handle contributions (tensors, cells) are passed as additional `&out`
  grad-handles, since their gradient lands by atomic accumulation at indexed
  slots rather than by value.
- Record and struct sub-function arguments use the same conventions as at
  the kernel boundary (per-field grad cells for records, shadow-struct
  cells for structs).

This mixed convention lets the backward pass thread gradients through
helper functions without forcing tensor-shaped gradients onto the
multi-value return path.



#### Implementation Note for the User

The `--differentiate` flag significantly increases the complexity of the generated SPIR-V, as it effectively doubles the logic and may increase register pressure to store intermediate "primal" values. Use the `check-registers` and `check-divergence` flags in conjunction with `--differentiate` to ensure your adjoint kernels remain performant on your target hardware.

#### Output File Naming

When using the `--differentiate` flag, the compiler will append `_grad` to the output filename. For example, if compiling `my-kernel.crisp` with `--differentiate` and the `--ir-target=spv` flag, the output file will be named `my-kernel_grad.spv`.


## Foreign Function Interface (FFI) ✅

Crisp kernels can call functions from third party libraries (such as the OpenCL `libclc` library or NVidia's `libdevice` library, and others). The process is much like in C, simply name each function and its signature that you wish to use and pass its `.bc` when compiling.

### `def-foreign-function` ✅
```
(def-foreign-function <C_name> <arrow-signature>)
```

```
;; example someKernel.crisp
(def-foreign-function my_add #'(float float => float))

(def-kernel invoke_my_add (a b &out c)
  (declare #'(float float &out (cell float :address-space :global)))
  (let ((res (my_add a b)))
    (set! (~ c) res)))

;; invocation
$ crisp-compile.exe myLib.bc someKernel.crisp --ir-target=ptx
```

The `def-foreign-function` form has two arguments: the "C name" of the function and its signature in Crisp arrow form. 

### pointers and handles: `c-pointer` ✅

```
(c-pointer :address-space <:global | :generic | :local | :constant | :private>)
```

`c-pointer` can be used to declare a pointer variable type. It must be qualified with `:address-space`.

Just as in `def-kernel-exact`, pointer arguments to foreign functions can have their type declared using `voidp` or `c-pointer`. But note that to actually use a pointer or dereference it, you'll need to use a marshalling form (like `marshall-cell` or `marshall-vector`), which will require a complete type that has `:address-space`, `:align` and possibly other properties to be specified.

### `base-ptr~` accessor ✅

`(base-ptr~ <storage-handle>)` returns the handle's underlying pointer in its
NATIVE address space (e.g. a global cell → a `(c-pointer :address-space :global)`).
Like `byte-size~` it is a pass-through: `(base-ptr~ someCell)` works as well as
`(base-ptr~ (parent~ someCell))`. Passing it to a foreign param of the same
address space needs no cast; differing spaces are reconciled by an
`addrspacecast` in the existing value-coercion path.

### handles ✅

A handle is a `void**`: it has TWO address spaces — the slot's (outer, where the
`void*` lives) and the held pointer's (inner, where the data lives) — and they
are generally DIFFERENT. 

```
;; handle type declaration
(c-handle <held-pointer-type>)


(c-handle (c-pointer :address-space :global))

;; handle creation
(make-c-hanlde <pointer-type>)

;; dereference handle to pointer
(get-pointer <c-handle-obj>)

```


#### Example

In the example below, there is a C library function called `pool_alloc` takes a pointer, a size, and a handle.

```
// C 
// Atomically reserves 'size' bytes from the pool.
// Returns 0 on success, and writes the allocated pointer into 'out_ptr'.
__device__ int pool_alloc(memory_pool_t* pool, size_t size, void** out_ptr);
```

```
(def-type float-vec-t (vector float :address-space :global :align :compact))

(def-type ptr-t (c-pointer :address-space :global))

(def-foreign-function pool_alloc #'(ptr-t ulong (c-handle ptr-t) => int))

(def-kernel-exact use_pool_alloc (pool pool-size)
  (declare #'(voidp ulong => nil))
  (let ((vph (make-c-handle ptr-t))
        (bytes (* 16 (byte-size float)))
        (err (pool_alloc pool bytes vph)))
    (when  (= err 0)
      (let ((v (marshall-vector (get-pointer  vph) 16 float-vec-t)))
        ...))))
```

### basic invocation ✅
```
crisp-compile.exe <some.bc> <another.bc> <some.crisp> --ir-target=ptx|spv


$ crisp-compile.exe myLib.bc someKernel.crisp --ir-target=ptx
```
Just add your library .bc file as an argument to the compiler.  As a general rule, the compiler will need to know the `--ir-target` (ptx or spv, and NOT `llvmir`) to correctly lower and bind.

### deferred invocation 📝
NOTE: deferred FFI binding is not supported yet.

The library binding can be left unresolved and then someone needs to use nvlink (or whatever) to link cuBlas.a against someKernel.ptx 

```
crisp-compile.exe someKernel.crisp --ir-target=spv
```

## Automatic Differentiation over the FFI Boundary

To use a foreign function within a differentiated kernel, provide its backward pass as the third
argument to `def-foreign-function`. The compiler derives the required signature of that backward
function from the forward signature using the VJP rule below.


### The VJP Signature Rule (vetted)

When you call a foreign function inside a `--differentiate` kernel, the compiler cannot see inside the
C black box, so you must supply its backward pass — a Vector-Jacobian Product (VJP) — as the third
argument to `def-foreign-function`. The compiler mechanically derives the VJP's required signature
from the forward signature; your `def-function` must match it exactly.

Type categories:
- **Active scalars** — `int`, `float`, `long`, etc. Differentiated; gradients promoted
  (`int`/`float`→`float`, `long`/`ulong`→`double`).
- **Active memory** — `(c-pointer ...)` / `voidp`. Differentiated via shadow buffers.
- **Passive** — `(c-handle ...)`. Ignored in every gradient phase.

**VJP inputs** (appended strictly in this order):
1. **Primals** — the exact original forward arguments.
2. **Seeds for active returns** — if the forward returns an active scalar, append its gradient seed
   (promoted type). (Active-memory returns are out of scope for now.)
3. **Shadow pointers for active-memory inputs** — for each pointer argument, append a shadow pointer
   into which the VJP accumulates that buffer's gradient.

**VJP outputs**:
- One gradient per active **scalar** input, in forward order. (Promoted: `float`, or `double` for
  64-bit primals.) Pointer-input gradients are written through the shadow pointers, not returned.

> Crisp does not trivialize integers. An `int` primal still demands a returned `float` gradient; a
> `long` primal a `double`. The compiler's signature generator is blind to semantics — even a
> logically-zero gradient (e.g. a buffer `size`) must be returned as `0.0` to keep the ABI sound.


### Signature mapping examples


| Forward FFI signature                                | Derived VJP signature                                                      |
|------------------------------------------------------|-----------------------------------------------------------------------------|
| `#'(float float => float)`                           | `#'(float float  float  => float float)`                                    |
| `#'(float int => int float)`                         | `#'(float int  float float  => float float)`                                |
| `#'(float => long)`                                  | `#'(float  double  => float)`  ← long-return seed is **double**             |
| `#'(float int voidp (c-handle ptr-t) => int)`        | `#'(float int voidp (c-handle ptr-t)  float  voidp  => float float)`        |
| `#'(float int voidp (c-handle ptr-t) => nil)`        | `#'(float int voidp (c-handle ptr-t)  voidp  => float float)`               |
| `#'(float int (c-handle ptr-t) => voidp)`            | DEFERRED (active-memory return)                                             |

Reading the fourth row: primals `float int voidp handle`; one `float` seed for the `int` return;
one `voidp` shadow for the `voidp` input (the handle is passive, no shadow); returns `float float`
for the `float` and `int` inputs.


### Example 1 — A transcendental, no buffers

A foreign C function computing `sin`:

```c
/* libmath.c */  float c_sinf(float x) { return sinf(x); }
```

Forward: `y = sin(x)`. Backward (chain rule): `dx = dy * cos(x)`.

Forward FFI signature `#'(float => float)` derives VJP signature `#'(float float => float)`:
primal `x`, seed `dy`, returns `dx`.

```
;; Declare the foreign function and name its backward.
(def-foreign-function c_sinf #'(float => float) c-sinf-bwd)

;; The backward is an ordinary def-function whose signature matches the derived VJP.
(def-function c-sinf-bwd ((x float) (dy float))
  (declare #'(float float => float))
  (* dy (cos x)))                       ;; dx = dy * cos(x)

;; Now c_sinf is differentiable wherever it is called from a --differentiate kernel.
(def-type cell-f (cell float :address-space :global))

(def-kernel use_sinf (x &out y)
  (declare #'(float &out cell-f))
  (set! (~ y) (c_sinf x)))
```

A two-input forward (e.g. `#'(float float => float)`) is identical in shape: the VJP takes both
primals plus the seed and returns both partials in order — `#'(float float float => float float)`.

### Example 2 — A buffer op with shadow accumulation (the aggressive case)

A foreign C function applies `sin` elementwise over a global buffer:

```c
/* libvec.c (OpenCL for spv / CUDA for ptx) */
void c_vsin(int n, __global const float *in, __global float *out) {
  for (int i = 0; i < n; ++i) out[i] = sin(in[i]);
}
```

Forward FFI `#'(int (c-pointer :global) (c-pointer :global) => nil)` derives VJP
`#'(int (c-pointer :global) (c-pointer :global) (c-pointer :global) (c-pointer :global) => float)`:

- **Primals:** `n`, `in`, `out`
- **Seeds:** none (`=> nil`)
- **Shadows:** `shadow-in` (for `in`), `shadow-out` (for `out`) — one per pointer input, in order.
  The shadow of the *output* buffer carries the incoming downstream gradient; the shadow of the
  *input* buffer is where we accumulate.
- **Returns:** `float` — the gradient for the scalar `n` (semantically 0).

```
(def-type fvec (vector float :address-space :global :align :compact))

(def-foreign-function c_vsin
  #'(int (c-pointer :global) (c-pointer :global) => nil)
  c-vsin-bwd)

;; VJP: shadow-in[i] += shadow-out[i] * cos(in[i]) ; return 0.0 for n.
(def-function c-vsin-bwd ((n int)
                          (in        (c-pointer :global))
                          (out       (c-pointer :global))
                          (shadow-in  (c-pointer :global))
                          (shadow-out (c-pointer :global)))
  (declare #'(int (c-pointer :global) (c-pointer :global)
              (c-pointer :global) (c-pointer :global) => float))
  (let ((vin  (marshall-vector in         n fvec))
        (vsi  (marshall-vector shadow-in  n fvec))
        (vso  (marshall-vector shadow-out n fvec)))
    (dotimes (i n)
      (set! (~ vsi i)
            (+ (~ vsi i) (* (~ vso i) (cos (~ vin i)))))))
  0.0)                                    ;; gradient for the int primal n
```

**Automatic shadow routing.** The user's kernel never threads shadow pointers manually. It calls the
forward function normally, passing buffer base pointers:

```lisp
(def-kernel use_vsin (n in &out out)
  (declare #'(int fvec &out fvec))
  (c_vsin n (base-ptr~ in) (base-ptr~ out)))
```

When differentiating, the compiler sees that `(base-ptr~ in)` / `(base-ptr~ out)` come from
differentiable tensors and supplies `(base-ptr~ in_GRAD)` / `(base-ptr~ out_GRAD)` as the matching
shadow arguments — the base pointers of those tensors' gradient cells. The mechanical ABI lets the
graph route the gradients blindly while the actual accumulation happens inside the VJP.



## Hoisting and `def-orchestration` ⚠️

When compiling, you can elect to have the Crisp compiler output "hoisting" example code. 
This is example code in C++ or Python that demonstrates how to read in the binary file,
create a program object, get a kernel, allocate memory, enqueue memory, set kernel arguments,
enqueue and run the kernel, and retrieve any result data (`&out`) after. It is entirely
optional, but can be a useful feature for debugging or sanity checking.

By default every kernel defined in the .crisp files (or instance of `gen-KERNELNAME` if templated) will 
have this hoisting code output for it when generating hoisting code.

But oftentimes kernels aren't intended to be run in isolation. They are intended to be run in conjunction
with other kernels. `def-orchestration` is Crisp affordance for this, it lets you communicate in a 
simple fashion how one kernel is expected to run relative another. And with this information
Crisp can both generate better hoisting code for you AND perform evaluations of your kernels at compile-time
and warn or error if compatibility or use issues are detected.

### `def-orchestration` 📝

`def-orchestration` has the basic syntax of a function. It has an argument list (often empty), a let block where variables can be bound to kernels or memory, and then it invokes those kernels with a `launch-XXXX` form and a "launch directive" (which looks like a regular function call `(<kernel-var> <mem-var0> ...)` ).

The arg list for `def-orchestration` supports `&key` arguments ONLY. Every argument to a `def-orchestration` MUST be a keyed argument. Positional args are not supported, neither are `&optional` or `&out` or `&rest`.   These arguments are provided when invoking `gen-XXXX` on the orchestration and must be compile-time known. 


`def-orchestration` CAN be templated.

If a `def-orchestration` is not templated and has no arguments, then it will be considered a "immediately realizable" orchestration, and then outputting hoisting code, the Crisp compiler will output a hoisting file for it (ie a .cpp, .cu or .py file). One file per orchestration.  Similarly, if there are multiple kernels referenced by the orchestration then the IR output (.spv or .ptx) will contain all of them. One .spv/.ptx/.ll file per orchestration.

However, if a `def-orchestration` is templated, or has arguments it will NOT be considered a "immediately realizable" orchestration and nothing will be generated for it, itself. In this case you must use place a  `gen-XXXX` form on the orchestration at the top level of a .crisp file to specialize it. Each invocation of `gen-XXXX` will result in outputting a single IR file (.spv/.ptx/.ll) and a single hoisting example file (.cpp/.cu/.py).  For example:

```
(with-template-type (T)
  (def-orchestration fancy-kernel-dance (&key node-count)
      (let ((K (gen-dance_kernel T))
             (topo (workstation-topology node-count))
            ...))))

;; gen- the orchestration
(gen-fancy-kernel-dance float :node-count 16)
;; and another!
(gen-fancy-kernel-dance long :node-count 1)
```

Using topologies is "advanced" and entirely optional. It is covered in `topology.md`     


Let's dive into some simple examples.

#### "default" orchestration ✅

```
;; assume vector_add is defined and is not templated, uses &out
;; (vector_add A B &out C)

;; -- just-vector_add --
(def-orchestration just-vector_add ()
  (let ((K (gen-vector_add))
        (A (allocate-tensor K::A))
        (B (allocate-tensor K::B))
        (C (allocate-tensor K::C)))
  (launch-sequential (K A B C))
  (copy-back C)))
```
The above is equivalent to the default orchestration Crisp would produce when hoisting
`vector_add`, if none wer provided.  It "generates" the kernel, prepares memory for each vector, enqueues it, and copies
back to the host any `&out` data.

This introductory example shows the `def-orchestration` begins with a name for the orchestration
and is followed by a series of command for how to launch kernels. 

Let's take a quick look at its pieces:

##### gen-KERNEL_NAME 📝

In the context of an orchestration you'll typically want a variable to refer to 
the kernels you intend to launch. Use `gen-KERNEL_NAME` for this. For kernels that are 
templated, this is also used to generate its type. Don't forget that in this case a
kernel name string will be required and it must obey the C language naming rules.
 `(gen-templated_kernel float "name_of_kernel")`

##### allocate-tensor and kernel_var_name::param-name 📝

`(allocate-tensor <VectorType> &key :shared <bool> :topology <topo> :location <loc> :distribution <dist>)`

For every vector argument to pass to a kernel, use `allocate-tensor` and Crisp will generate
the code to set that up when outputting the hoisting code. The `<VectorType>` should be a complete
vector type, BUT there shortcut that let's you just grab the type directly from the kernel definition:

`kernel_var_name::param-name` Using the name of the kernel _variable_ that is in scope of the
`def-orchestration`, NOT the name of the kernel itself (ie `K` in the above, not `vector_add`) 

`:shared <bool>` : whether to allocate the tensor in shared memory. Defaults to false. For simple kernels with simple deployments and not aggressive memory requirements, using shared memory is vastly simpler. But it can be a performance liability if those things aren't true.

`:topology <topo>` : Only required for doing Out of Core operations or using multiple nodes.  See topology.md for mor information. 

`:location <loc>` : Not required unless doing Out of Core operations or using multiple nodes, see topology.md for more informaation.  Specifies where to allocate the tensor, either `:device` or `:host` or a topology specifier.

`:distribution <dist>` : Only required when using multiple nodes (PGAS), see topology.md for more information. 

##### allocate-cell 📝
```
(allocate-cell <VectorType>  &key :shared <bool> :topology <topo> :location <loc> :distribution <dist>)
(allocate-cell <Type>  &key :shared <bool> :topology <topo> :location <loc> :distribution <dist>)
```

`allocate-cell` will allocate a single cell. It can take a complete vector type, or a `vector-var-name::param-name` type shortcut , or just a type like `float` or `int`.

The `:shared`, `:location`, and `:distribution` keywords are the same as in `allocate-tensor` above.


##### copy-back 📝
```
(copy-back <hoist-vector-var>)
```

For any data you expect to be modified on the GPU, if you want it copied back 
to the host use `copy-back`. Crisp will generate code for that in the hoisting example.




#### kernel template instantiation

```
;; assume both vector_add and vector_sum are templated for some element-type.
;; (vector_add A B &out C)
;; (vector_sum DATA-IN &out RESULT)

;; -- add-and-sum-doubles --
(def-orchestration add-and-sum-doubles ()
  (let ((VADD (gen-vector_add double "v_add_double"))
        (VSUM (gen-vector_sum double "v_sum_double"))
        (A (allocate-tensor VADD::A))
        (B (allocate-tensor VADD::B))
        (C (allocate-tensor VADD::C))
        (RESULT (allocate-cell VSUM::RESULT)))
  (launch-sequential
     (VADD A B C)
     (VSUM C RESULT))
  (copy-back RESULT)))

; this orchestration will cause the kernels `v_a_double` and `v_s_double` to be created in the output.
```

Recall that when a kernel is templated, `gen-KernelName` is used to specialize it and a kernel name string is required.
Here, that is leveraged. Note that this orchestration is effecting the compilation. It is generating
two kernels ( `v_a_double` and `v_s_double` ) that will appear in the output.

#### template def-orchestration 📝

`def-orchestration` can itself be templated. Within its body `${XXXX}` can appear in strings and 
evaluate to the name of the type `XXXX`.

```
(with-template-type (T)

  ;; -- add-and-sum-any --
  (def-orchestration add-and-sum-any ()
    (let ((VADD (gen-vector_add double "v_add_${T}"))
          (VSUM (gen-vector_sum double "v_sum_${T}"))
       ...))))

(gen-add-and-sum-any float)  ; kernels `v_a_float` and `v_s_float` will be created in the binary.

```
`def-orchestration` can be templated. Like kernels, nothing will be generated by the compiler 
(not for regular output nor hoisting) UNLESS one or more `gen-Orchestration-Name` appear in the .crisp file.

This is a good way for Crisp libraries to provide orchestration code, since it is ignored otherwise. 
It is then incumbent on the user of the library to explicitly put the desired `gen-XXXX` form in
their own .crisp file.


#### `_` as a dummy var placeholder. 📝

The "calls" to a vector variable in an orchestration must have the correct number of arguments for that kernel.
But you don't have to be burdened to declare and bind each and every one. For any argument position
you can't be bothered to worry about, just use `_` and Crisp will look up what type that argument should be
and make a dummy var for you and pass it.  

`(launch-sequential (VADD _ _ _))`  <-- invoke the `vector_add` from the earlier examples with dummy
placeholders. Crisp will provide the right arg type, whatever that is (vectors in this case).

#### More notes on `def-orchestration`

Hopefully those examples give you a grounding on how it can be used. It is important to remember
that the forms inside the body of `def-orchestration` are used to just generate sample code and
ensure that certain specializations are instantiated. 

Because `def-orchestration` focuses on high-level data flow using Crisp's typed views, 
it is generally not used with kernels defined via `def-kernel-exact`, which operate at a lower level with raw argument types

The forms that can appear inside `def-orchestration` are quite limited. It is NOT a Crisp 
execution environment. 

Presently, the following forms are the ONLY ones allowed within the body of a `def-orchestration`:
- `launch-sequential`
- `launch-kernel`
- `launch-parallel`
- the `dotimes` and related `dec-` / `do-` macros
- `_`  
- `let`
- `kernel_var_name::param-name` identifier 
- `allocate-tensor`
- `allocate-cell`
- `allocate-massive-tensor` (see topology.md)
- `tile-from` (topology.md)

### launch-sequential 📝

```
(launch-sequential  &rest launch-specification)
```
`launch-sequential` takes a series of "launch-specifications" and the hoisting code that is
generated will enqueue them all and prepare a device-side event based synchronization.
The CPU is free to do other things while the sequence of kernels run, and it does not need to do participate during the sequence.

#### launch specification

A "launch specification" is simply a kernel _variable_ and the correct number of arguments. eg. `(VADD A B C)` or
`(VADD _ _ _)` or `(VADD _ B _)` etc

### launch-kernel 📝

```
(launch-kernel launch-specification &key :pipeline-stages <int>)
```
Launches exactly one kernel invocation. Multiple invocations mean serial enqueues.

Multiple `launch-kernel` invocations are NOT the same as `launch-sequential`, because `launch-kernel` invocations return to the host after each kernel operation completes, but  `launch-sequential` does not.

The `:pipeline-stages` keyword is advanced. See "Out of Core Orchestration" in `topology.md` 

```
(launch-kernel (VADD A B C))
(launch-kernel (VSUM C RES))
(copy-back RES)
```

### launch-parallel 📝

```
(launch-parallel &rest launch-specification)
```

`launch-parallel` is much like `launch-sequential` except that the kernels are all launched parallel to one
another. Crisp will add code to divide the available thread space up between them (excepting `single-task` kernels which just get one thread). Exactly how this is done is target implementation specific. It could use individual queues.

Note the parallel kernels can't safely write to the same vectors (whether marked with `&out` or not). Crisp will 
error if it detects parallel re-use of `&out` vectors, but even if you sneak around the compiler it still won't
work correctly.



## Compiler Invocation and Options ✅

`$ crisp.exe file.crisp`
Without any output targeting options, the crisp compiler would simply output any compilation errors. Similar to using `-fsyntax-only` with C compilers.

### Output Targeting Options 📝

#### `--output-dir=<DIRECTORY_PATH>`

Where the output of the crisp compiler should go. If not provided it is assumed to be the current working directory.

#### `--output-base=<NAME>` 📝

This base name will be used for all outputs, with the file extension uniquely identifying them.
If not provided the base name is the name of the last .crisp file passed to the compiler (minus any extension).

#### `--transpile-to=<ID>` 📝

The compiler will transpile the .crisp file to some other Kernel language. At the moment `oclc` is the only supported
transpilation target.

| ID       | Extension |  Description       |
|----------|-----------|--------------------|
| `oclc`   | `c`       | OpenCL C           | 

#### `--ir-target=<ID>` ✅

This flag can be used repeatedly, each occurrence with a different ID. The compiler will compile the .crisp files 
to an IR (Intermediate Representation) file. One file per occurrence of the `--ir-target` flag.
`ID` can be one of

| ID       | Extension |  Description       |
|----------|-----------|--------------------|
| `llvmir` | `ll`      | human readable LLVM-iR |
| `ptx`    | `ptx`     | CUDA Parallel Thread Execution IR |
| `spv`    | `spv`     | Khronos SPIR-V IR  |

Unless the `--merge` or `--join` flags are used, one target file (e.g. `spv`) is output per `def-orchestration`.  Loose kernels outside of any orchestration have a default one generated for them.

#### `--ir-target-arch=<ID>` 📝

This flag tells the Crisp compiler which architecture the IR should target. It is optional, but
matches the use of `--ir-target` flag. (ie, if `--ir-target=ptx` then `--ir-target-arch` should 
be an NVidia architecture.).



| ID       | Description                    |
|----------|--------------------------------|
| `sm_80`  | NVIDIA Ampere (A100)           |
| `sm_86`  | NVIDIA Ampere (RTX 3000 Series)  |
| `sm_89`  | NVIDIA Ada Lovelace (RTX 4000 Series / L40) |
| `sm_90`  | NVIDIA Hopper (H100 / H200)      |
| `sm_100` | NVIDIA Blackwell Datacenter (B100 / B200 / GB200) |
| `sm_120` | NVIDIA Blackwell Consumer (RTX 5000 Series / PRO 6000) |
| `gen12`  | Intel Gen12                    |
| `dg2`    | Intel DG2 / Alchemist          |
| `pvc`    | Intel Ponte Vecchio            |
| `xe2`    | Intel BattleMage / Lunar Lake  |


#### `--binary-gpu-target=<ID>` 📝

This flag can be used repeatedly, each occurrence with a different ID. The compiler will compile the .crisp files to a different binary file for each binary target. The binary file name will be `<output-base-name>_<ID>.<extension>`

`ID` can be one of the `--ir-target-arch` flags

Unless the `--merge` or `--join` flags are used, one target file (e.g. `cubin`) is output per `def-orchestration`.  Loose kernels outside of any orchestration have a default one generated for them.

#### `--fat-binary` 📝

This flag requires that the `--binary-gpu-target` flag also be used, or it is ignored.
Whe present the binaries that Crisp produces will be  fat binaries and will also contain the matching IR code (PTX or SPIR-V).

#### `--hoist=<ID>`  ⚠️

This flag can be used repeatedly, each occurrence with a different ID. The compiler will generate a hoisting example code files for each occurence.
The hoist options are paired against their matching IR and Binary targets automatically. You'll get a warning from the compiler if it detects
incompatible pairings.  Note that if outputting BOTH binary and IR targets then the hoisting code will demonstrate both.

The hoist file name will be `<output-base-name>_<orchestration>_<ID>.<extension>`

`ID` can be one of

| ID              | Extension |  Description       |
|-----------------|-----------|--------------------|
| `OpenCL`        | `cpp`     | OpenCL 3.0 API     |
| `L0`            | `cpp`     | LevelZero 1.9 API  |
| `CUDA`          | `cpp`     | CUDA 12 API        |
| `PyOpenCL`      | `py`      | PyOpenCL           |
| `PyLevelZero`   | `py`      | Python LevelZero   |
| `PyCUDA`        | `py`      | PyCUDA             |

There are other flags that interoperate with the hoisting, such as `--hoist-dynamic`

One hoisting file is output per orchestration.

#### `--metadata` ✅

If this flag is present, the compiler will output a metadata file. This file has a lot of the necessary 
hoisting information about the kernels and their arguments and 
can be parsed programmatically if desired.

The metadata files are output one per `def-orchestration`. If a kernel does not appear in a `def-orchestration`, a default one is generated for it. 

#### Example
```
$ crisp.exe --output-base=v_add --ir-target=spv --hoist=L0 ../vector-add.crisp
$ ls
v_add.spv
v_add_hoist_L0.cpp
```

```
$ crisp.exe  --binary-gpu-target=sm_90 --binary-gpu-target=pvc --hoist=CUDA --hoist=PyLevelZero --metadata ../reduce-vector.crisp
$ ls
reduce-vector_sm_90.cubin
reduce-vector_pvc.bin
reduce-vector_hoist_CUDA.cpp
reduce-vector_hoist_PyLevelZero.py
reduce-vector.metacrisp

```


#### `--differentiate` ✅

This flag is discussed in the [Auto Differentiation (AD)](#auto-differentiation-ad) section above.
When used the kernels are assumed to be "forward" kernels and the compiler will generate "backward" kernels for them with "backward" signatures.  The compiler will emit an error if the kernel is not differentiable.

Use `(declare forward-only)` to opt out of differentiation for a specific kernel.

Also note that at this time `--differentiate` and `--hoist` are mutually exclusive.  The compiler will emit an error if both flags are used.

### Other Flags ⚠️

#### `--runtime-checks` ✅
This flag enables various runtime checks that Crips is able to generate. Bounds checks, etc. 
The exact checks are documented in thei relevant sections. <!-- NOTE: gather them up --> 
In the initial implementation, this flag is useless without also enabling `--logging-output` and the
compiler will emit an error if that flag is not also elected. 

#### `--logging-output` 📝
This enables the debugging output side channel as well as enabling the runtime checks ( `r-t-check` ). When this 
option is used, the kernel may run significantly slower. Note that the code that actually hoists
the kernels built with this flag has to be updated as well so that the debug output side channel vector
is created and added as an argument. It is up to the calling application to decide what to
do with the debug output once it is retrieved. The hoisting code typically models writing it to a file.


#### `--debug` or `-g` ✅
When outputting LLVM-IR, include DWARF symbols


#### `--hoist-dynamic=<KERNELNAME>` 📝
This flag can be used repeatedly, each occurrence with a different KERNELNAME.  For each kernel named, the hoisting 
code will demonstrate how to compile that same kernel by invoking the in-memory compilation API on the string that is that
kernel. 

#### `--re-output-crisp=<DIRECTORY>` 📝
This flag is passed a directory. The .crisp files that are being compiled will be copied into that directory. But they will 
be modified in three ways: 
 - any types that were inferred by the compiler will now be explicitly declared in the updated .crisp file.
 - the file will be output in dependency order, compatible with single pass compilation. 
 - any static analysis "opt-in"s will be removed. 


#### `--no-inference` 📝
Type inference is turned off. The compiler will output an error for missing types.

#### `--no-static-analysis` 📝
Any opt-in static analysis (see above) will be skipped. 

#### `--single-pass` ✅
By default, the Crisp compiler performs "multi-pass" compilation, which means that the compiler first reads the .crisp files, gets an understanding
of everything that will need to be compiled how how they depend upon each other, and then it takes a second pass and actually compiles everything. 
When the `--single-pass` flag is present the compiler compiles items as it encounters them. But this requires that your .crisp file is in reverse
 dependency order. Meaning that if  `calc-two-things` calls `calc-one-thing` that `calc-one-thing` MUST appear in the .crisp file BEFORE `calc-two-things`.
 In other words, when any function is being compiled, every subfunction and macro that it uses MUST have been previously declared. This often means that
 entry points and kernels appear last in a .crisp file. 
 If this is an inconvenient way of working for you, don't let it crimp your style. Don't bother with the `--single-pass` flag
  or use the `--re-output-crisp` flag to have your .crisp files converted to single pass order. 

**Interprocedural uniformity and `--single-pass`.** Multi-pass compilation lets the compiler *infer* that a scalar kernel input threaded through a call is workgroup-uniform — so a sub-function using `if+`/`dotimes+` on that parameter compiles with no annotation, purely from the proof that every call site passes a uniform argument. This inference needs the whole call graph, which `--single-pass` does not build (a callee is compiled before its callers are seen). Under `--single-pass`, assert it explicitly on the callee with `(declare (uniform x))`; otherwise the `+` form reports its condition as `UNKNOWN` and errors.

#### `--skip-c-t-checks`  📝 

The compile-time checks are skipped. This is very dangerous but does make the act of compilation much faster. 
It is meant to be used when doing runtime compilation of Crisp kernels, probably from some sort of code template that you know is sound.
It is possible to output invalid kernels with this option. 
Note that this not only skips the `c-t-check` entries that you put into your own code, but ALSO many routine checks that the compiler
regularly performs, including error checks that the documentation elsewhere says might be performed.
When this flag is on, the compiler only performs the minimal checks required to
move forward. This is inherently unsafe. 

#### `--tree-shaking` 📝

The `--tree-shaking` flag causes the compiler to carefully evaluate which functions and subfunctions are ACTUALLY 
called by the kernels and only incorporate those into the final binaries.  This can make the compilation pass
a little slower, but makes the kernel smaller, faster, and faster to load.

But there is a second side effect that happens when tree shaking. Both the functions used and not from any 
library files are precompiled for the compilation targets into .crisp_lib and .crisp_libc files and these
files will make any future compilations that use these same libraries to these same targets MUCH
faster. 

<!--  Do we need flags to control where these lib files get written / read ?  Answer: YES -->

<!-- NOTE
1 - .crisp files with no kernels are automatically identified as "library" files.
2a. - the user invokes the full compilation command. There is a --tree-shaking flag. It runs slow. We compile for whatever targets they specified, be they IR or binary.
2b - when tree shaking, each "library" gets its entry point functions (*) compiled into their own little thing, one for each target. Bound up with a map into a big blob.
2c - and the entry point functions that are actually used by my_kernel also get put into a second little thing, one for each target. blobbed together.
     if a function is inlined when tree shaking, that is noted too. 
3 - the NEXT invocation of the compiler we lean on 2c to really speed things up and fall back to 2b if necessary. If something was inlined before, 
    we just do it again.
4 - assuming the output target profile is the same, other kernel .crisp files could benefit from 2b at very least. 
-->

<!--  (declare entry-point inline)  both need definitions -->

### Compiliation Flags ✅

#### `-D` 📝

Used to define parameter values ( see `def-parameter`)
Example: `crisp.exe -DSTART_INDEX=20` 

#### Math Flags `--math-precision` 📝

The `--math-precision` flag can be set to `fast`or `ieee`. But note that Crisp supports
in-file precision election. See the section on [Math Precision](#precision) above.

Also, there is a `--force-math-precision` flag that can override, but its use is discouraged.
It is intended for testing and validation and shouldn't be used generally.




### Fast Compilation ✅
Compilation speed is one of the prime goals of the Crisp compiler. There are things you can 
do to maximize compilation performance.

#### Single Pass

`--single-pass` compilation is faster than multi-pass. Use `--re-output-crisp` if necessary to prepare for this.

#### No Static Analysis

Static analysis is slow. If you have opt-in static analysis in your .crisp file, use `--no-static-analysis` to skip them.

#### No Type Inference

Type inference slows the compiler down. Declare all types if possible.  Use the `--no-inference` or `--re-output-crisp` flags to help
kick the habit.

#### Use Tree Shaking

The `--tree-shaking` flag makes for a slow compilation.  BUT the benefit for any future compilations to the same set of targets, especially
for the same set of libraries or kernels, is extreme. Be sure to use tree shaking from time to time to update the lib caches for your files.
Tree shaking can make the compilation of OTHER kernels faster too if they use some of the same libraries. It's clutch.

The `--tree-shaking` flag can be used with library .crisp files and no kernels at all. Given a set of targets it can still generate .crisp_lib files
for those libraries which will speed up future compilations of anything to any of those targets.  Note that many of the compilation flags
must be used consistently by both the tree shaking and future compilation passes:
- `-DXXXX`
- `--IR-target`
- `--binary-GPU-target`
- `--logging-output`
- `--runtime-checks`
- `--math-precision`

#### In Memory Compilation

There is ( soon? ) both a Python and a C++ API for performing in-memory compilation, including support for in-memory lib and lib caches. 
With this there is no disk IO and compilation can be performed nearly instantaneaously. 

#### Danger
If you are confident that the code you are compiling is completely ready and error free, use the flag that skips the compile time
checks. 

### Compiler Invocations and Files ✅
Each target (for example .spv) has one file output per orchestration. Loose kernels that
are not named in an orchestration are also output, one target file apiece. 

#### `--merge` and `--split`
The `--merge` flag can be used to ensure all the kernels are output into one file for any given target type (like all the kernels in one .spv or one .ptx).
Contrarily, the `--split` flag ensures each kernel gets its won individuaul target file and is 
not joined with any other, regardless of any `def-orchestration`.
It is an error to use both these flags together.

Also note that the metadata and hoisting output is always output per-orchestration. They are uneffected by either flag. 

#### multiple .crisp files

`$ crisp-compile.exe library.crisp app.crisp`

Multiple `.crisp` files can be sent to the compiler at one time. It reads them in order and then 
compiles. Note that while the compiler does default to multi-pass by default, macros (`defmacro`) 
are ALWAYS order sensitive, multi-pass or single-pass. 



## Hoisting Code ✅

The hoisting code that Crisp outputs demonstrates the following:
- loading the kernel from disk
- using CUDA/LevelZero/OpenCL to create a program from that kernel
  be it IR or binary
- commented out code that demonstrates how to perform profiling
- then for each kernel in the output
- - allocating and preparing all the side channel memory. 
- - allocating and preparing the explicit memory in the kernel arguments.
- - setting the kernel arguments
- - enqueuing the kernel
- - waiting for it to complete
- - enqueing any "copy back" operations for result vectors.

Further, if the `--hoist-dynamic` flag is used, then the example code will actually 
include the string of that kernel and pass it to the in-memory compilation API (etc.).


## In-Memory Compilation API 📝

### C API 📝

<!-- NOTE  Let's rename "tree shaking" throughout. set_cache_directory() ??  But also change the flag -->

#### `new_context( target_identifier )`   📝 
    
`target_identifier` is one ID from either IR or binary target flags.
returns a pointer to a context.

#### `set_tree_shake_directory( context, path )` 📝

`path` is null terminated C string.

if the `--tree-shaking` compilation was performed earlier, then its output directory can be 
used as the input tree_shake directory for the in-memory compiler. This can 
greatly speed up in-memory compilation.

The relevant flags used (and recorded) in that compilation will be used. 
See the section on `flags` below.

#### `add_input_file( context, file.crisp )` 📝

Reads in the file and adds the crisp source to the context.  Returns an error if the file could not be read.

#### `add_input_string ( context, crisp_string, virtual_file_name )` 📝

Adds the crisp source to the context. The `virtual_file_name` (e.g. "my_dynamic_kernel.crisp")
can help make compilation error messages more understandable.


#### `set_flags( context, string )` 📝

This is a just a string of flags and values like you would submit
to the crisp.exe compiler. If using `set_tree_shake_director()` then
this call is likely not needed .  See the section on `flags` below. 

Example:
```
  set_flags(ctx, "-DMAX_INDEX=40 --single-pass --no-inference");
```
#### `get_flags( context, char** flagHandle, size_t* sz )` 📝


If using `set_tree_shake_director()` then this populates the flagHandle with the flags
passed when the tree shaking was performed. Otherwise it returns nothing.

Call with nullptr for `flagHandle` to have the `sz` set to the size needed, then
call again with both set.

#### `compile(context, size_t* sz)` 📝

compiles everything. If this is the first call and `set_tree_shake_directory( path )` was 
called earlier then there may be file I/O as the files from the tree shaking get read in.

returns a status code. If successful `sz` will be set to the size of the binary.
See "Status Codes" below.

#### `compile( context,  string, size_t* sz )` 📝

adds string to the context and compiles everything. If the string has definitions
that have the same name as others that were loaded into the context earlier, 
it does not trigger an error. Instead, any definitions in string are presumed to override.

returns a status code. If successful `sz` will be set to the size of the binary.
See "Status Codes" below.


#### `bool get_binary(context, const void** out_data, size_t* out_size)` 📝

Gets the size and a pointer to the compiled binary from the last successful compilation.
return true on success, false if no binary is available.

The binary/ir result of the compilation. Something that can be passed 
to `clCreateProgramWithBinary` or its equivalent.

#### `long get_compilation_error_code(context)` 📝

Retrieve the actual compilation error code from the last compilation attempt. 0 if successful.

#### `const char* get_messages(context)` 📝

Gets any error or warning messages from the last compilation attempt (successful or not).

#### `const char* get_metadata(context)` 📝

Gets the metadata from the last successful compilation. Format TBD.

#### `destroy_context( context )` 📝

Destroys the context. 

### Status Codes ✅

When using the In Memory Compilation API in conjunction with the "tree shaking cache" <!-- RENAME -->
it is important to preserve the API between the host and the kernels it may be enqueuing.

For example, if some kernel in the cache required only 1000 bytes of scratch memory, but 
after recompilation by In Memory Compilation API it now requires 10,000 bytes, that would
be a breaking change.  The kernel, if enqueued as before, would no longer function correctly.

Other changes could result in even more severe API breakage. Query the metadata to see
if the kernel you intend to call was effected and how before attempting to use it.


```
typedef enum {
    /* The kernel compiled successfully and is compatible with the previous
        hoisting/launch requirements from the cache. */
    SUCCESS_COMPATIBLE = 0,

    /* The kernel compiled successfully, BUT its hoisting/launch requirements
        (e.g., arguments, scratch sizes) have changed. The host MUST
        re-query the kernel metadata before launching. */
    SUCCESS_BREAKING_CHANGE = 1,

    /* The kernel failed to compile.  Use get_compilation_error_code() to retrieve the actual ec.*/
    ERROR_COMPILE_FAILURE = -1,

}
```


### Flags
If using the `set_tree_shake_directory()` call, then the compilation environment will
load the flags from the record there.  This ensures maximum reuse of the .crisp_lib files
that are there and keeps compilation speed at its highest.

If you need to override or change, use the `set_flags()` call.  But note that
this call is singular and should be complete. The flags set with this call are
not "additive".  Any call to `set_flags()` should include ALL the relevant flags
you want on the next call to `compile()`.

However, nearly all flags are ignored by the In Memory Compilation API. 
The only flags it respects are

- `--single-pass`
- `--no-inference`
- `--skip-c-t-checks`
- `--no-static-analysis`
- `-D`
- `--math-precision` (and `--force-math-precision` but discouraged)
- flags governing errors and warnings (TBD)


## APPENDIX #1 - Summary: set / get vars, storage handles, and structs 

```
;; -- ACCESS 
someVar
(~ cell)
(~ vec i)
(~ mat y x)
(~ tensor ... z y x)
(x~ somePt)
(x~ soaVec<point> i)

;; -- SET!
(set! someVar val)
(set! (~ cell) Val)
(set! (~ vec i) val)
(set! (~ mat y x) val)
(set! (~ tens ... z y x) val)
(set! (x~ somePt) val)
(set! (x~ soaVec<point> i) val)

;; -- OVERRIDE GET ( ~ )
(def-function ~ (cellT) ...)
(def-function ~ (vecT i) ...)
(def-function ~ (matT y x) ...)
(def-function ~ (tensT ... z y x) ...)

;; -- OVERRIDE SET! ( ~ )
(def-setter ~ ((cellT) val) ...)
(def-setter ~ ((vecT i) val) ...)
(def-setter ~ ((matT y x) val) ...)
(def-setter ~ ((tensT ... z y x) val) ... )

;; -- OVERRIDE PROPERTY ACCESS
(def-function x~ (pointT) ...)
(def-function x~ (soaVec<point> i) ...)

;; -- OVERRIDE PROPERTY SET
(def-setter x~ (pointT val) ... )
(def-setter x~ ((soaVec<point> i) val) ...)

;; -- ATOMIC OPERATION
(atomic-inc! someVar)
(atomic-inc! (~ cell))
(atomic-inc! (~ vec i))
(atomic-inc! (~ mat y x))
(atomic-inc! (~ tens ... z y x))
(atomic-inc! (x~ somePt)
(atomic-inc! (~ soaVec<point> i))

;; -- ATOMIC-SET!  / ATOMIC-XCHG!
(atomic-set! someVar val)
(atomic-set! (~ cell) val)
(atomic-set! (~ vec i) val)
(atomic-set! (~ mat y x) val)
(atomic-set (~ tens ... z y x) val)
(atomic-set! (x~ somePt) val)
(atomic-set! (x~ soaVec<point> i) val)
```




## APPENDIX #2 - Math with Quantized Ints and Microfloat 

### dot product and matmul 📝

These dot product and matmul implementations work for ALL types. 

```
;; -- dot-prod-seq --
(with-template-type (T Al)
  (declare  (value-is Al #'is-alignment))

  (def-function dot-prod-seq (A B)
    (declare #'((in-vec T Al) (in-vec T Al) 
                 => (accum T)))
    (let ((sum (identity-of #'+ (accum T))))
      (declare (type sum (accum T)))
      (dotimes (i (length~ A))
        (set! sum (+ sum (*! (~ A i) (~ B i))))) ;; widening multiplication *!
      (return sum))))


;; -- dot-prod-grid --
(with-template-type (T Al)
  (declare (value-is Al #'is-alignment))

  (def-grid-function dot-prod-grid (A B &out RESULT)
    (declare #'((in-vec T Al) (in-vec T Al) &out (single-result (accum T)))
      (global-size :derive-from A :strategy :strided))
    (when-thread-is 0
      (r-t-assert (= (length~ A) (length~ B)) "lengths must match")) 
    (let ((C-scratch (make-scratch-vector (accum T) Al :name "dot product"))
          (zero (identity-of #'+ (accum T))))  
      (map-stride #'*! (A B) C-scratch) ;; widening multiplication *!
      (reduce-vec-atomic #'+ C-scratch zero RESULT)))) ;; <-- this broadcasts


;; same TILE_DIM as used by convert-layout 
(def-const TILE_DIM 32 ulong) ; warp-size on most hardware

;; -- matmul --
(with-template-type (T Al)
 (declare (value-is Al #'is-alignment))

  (def-grid-function matmul (A B &out C)
    (declare #((matrix T) (matrix T) &out (matrix (accum T)))
             (local-size :set-to `(,TILE_DIM ,TILE_DIM)) 
             (global-size :derive-from C             
                          :strategy :tiled           
                          :tile-shape TILE_DIM       ; Tile size is TILE_DIM x TILE_DIM
                          :dims 2
                          :msg "Launch one workgroup per output tile of C"))

    (let ((tile-A (make-tile TILE_DIM (base T)))
          (tile-B (make-tile TILE_DIM (base T)))
          (local-id-x (get-local-id 0)) (local-id-y (get-local-id 1))
          (group-id-x (get-group-id 0)) (group-id-y (get-group-id 1))
          (acc (identity-of #'+ (accum T)))
      (declare (type acc (accum T)))

      ;; main loop over the tiles in the inner dimension
      (dotimes (tile-num (ceil (num-cols A) TILE_DIM))

        ;; adaptive, coalesced loading
        ;; Use the 'load-tile' macro to handle the complexity.
        (load-tile A tile-A group-id-y tile-num
                   :transpose (= (get-layout A) :col-major))

        (load-tile B tile-B tile-num group-id-x
                   :transpose (= (get-layout B) :row-major))
        
        (sync-workgroup)

        ;; This part is now simple and fast, both local tiles are row-major.
        (dotimes (k TILE_DIM)
          (set! acc (+ acc (*! (~ tile-A local-id-y k)  ;; widening multiplication
                              (~ tile-B local-id-x k)))))

        (sync-workgroup))

      ;; store final result. coalesced access
      (let ((c-row (+ (* group-id-y TILE_DIM) local-id-y))
            (c-col (+ (* group-id-x TILE_DIM) local-id-x)))
        (when (and (< c-row (num-rows C)) (< c-col (num-cols C)))
          (set! (~ C c-row c-col) acc))))))
```

<!-- NOTE 
  convolve-2d and mat-vec-mult are just more of the same.
  - output is (accum T)
  - use (identiy-of #'+ (accum T)) for 0 in most places.
  - use *! (widening multiplication) instead of *

-->


#### max-pool 📝

The `max-pool` algorithm requires `max` which is not supported by `microfloat-block` so
this algorithm only works with regular floats and quantized ints.

`max-pool` is a downsampling operation, essential in convolutional neural networks (CNNs). Its main job is to shrink a feature map (like an image) while preserving the most prominent features (the ones with the highest values).

It works by sliding a "window" (usually 2x2) across the input matrix and picking the single highest value from that window to be the only value in the new, smaller output matrix.

```
;; -- max-pool--
(<T A>
  (declare (type-is (supports-max? T))  ;; maybe (supports? #'max T) but maybe not.
           (value-is A #'is-alignment?))

  (def-grid-function max-pool (input-M win-w win-h &out output-M)
    (declare #'((in-matrix T A) uint uint &out (out-matrix T A))
              (global-size :derive-from output-M :strategy :strided))
    (r-t-assert-0 (and (= (num-cols input-M) (* win-w (num-cols output-M)))
                       (= (num-rows input-M) ( win-h (num-rows output-M))))
                       "input matrix size must be output matrix size times win dim")
    (r-t-assert-0 (and (> win-w 0) (> win-h 0)) "window must have extent")
    (thread-stride output-M :global-size (xo yo)
      (let ((x-in-start (* xo win-w))
            (y-in-start (* yo win-y))
        
            (max-val -INF)) ;; (identity-of #'max T)
       (dotimes (ky win-h)
        (dotimes (kx win-w)
          (let* ((x-in (+ x-in-start kx))
                 (y-in (+ y-in-start ky))
                 ;; Note: No bounds check needed if we trust the assert
                 (pixel-val (~ input-M y-in x-in)))
                ;; This works for both f32 and qint (B=B)
                (set! max-val (max max-val pixel-val)))))
        ;; store
        (set! (~ output-M yo xo) max-val)))))

;; Remark the whole "sometimes x y z order, othertimes z y x" bothers me
;; points are usually (x, y), but C++ A[y][x]  or (~ A y x)  

```


#### Average Pool 📝

`average-pool` is a downsampling operation, just like `max-pool`. It's a core component of most convolutional neural networks (CNNs).

Its job is to shrink a feature map (like an image) by sliding a window over it. But, instead of picking the single highest value from the window (what `max-pool` does), `average-pool` calculates the mathematical average of all values within that window.

This results in a "smoother," "softer" downsampling that preserves a generalized sense of the neighborhood rather than just its single most prominent feature.  

This version of `average-pool` works with any numeric type or quantized integers. There is
not a performent version for microfloat blocks. 


```
;; -- average-pool--
(<T A>
  (declare (value-is A #'is-alignment?)
    (or (type-is T #'is-numeric?)
        (type-is T #'is-quantized-int?)))

  (def-grid-function average-pool (input-M win-w win-h &out output-M
                                  &key zero-point scale)
    (declare #'((in-matrix T A) uint uint &out (out-matrix T A))
              (global-size :derive-from output-M :strategy :strided))
    (r-t-assert-0 (and (= (num-cols input-M) (* win-w (num-cols output-M)))
                       (= (num-rows input-M) (* win-h (num-rows output-M))))
                       "input matrix size must be output matrix size times win dim")
    (r-t-assert-0 (and (> win-w 0) (> win-h 0)) "window must have extent")
    (c-t-assert (when (is-quantized-int? T) (nor  (nullp zero-point) (nullp scale)))
                "using quantized int requires :zero-point and :scale keys ")
    (thread-stride output-M :global-size (xo yo)
      (let ((x-in-start (* xo win-w))
            (y-in-start (* yo win-y))
            (win-count  (* win-w win-h))
            (acc (identity-of #'+ (accum T))))
       (dotimes (ky win-h)
        (dotimes (kx win-w)
          (let* ((x-in (+ x-in-start kx))
                 (y-in (+ y-in-start ky))
                 ;; Note: No bounds check needed if we trust the assert
                 (pixel-val (~ input-M y-in x-in)))
              ;; ADD
              (set! acc (+ acc (to (accum T) pixel-val))))))
        ;; store
        (let ((acc-f (if+ (is-quantized-int? T)
                        (to-float-accum acc zero-point scale) ;; don't square scale
                       acc))
              (avg-val (/ acc-f win-count)))
          (set! (~ output-M yo xo) avg-val))))))
```


#### ReLU 📝

ReLU stands for Rectified Linear Unit. It's the most popular activation function in modern neural networks. Its job is to introduce non-linearity into the network, which is what allows it to learn complex patterns (otherwise, the whole network would just be one giant, simple matmul).

The operation itself is a simple element-wise function: `output = max(0, input)`

It acts as a one-way gate:
- If the input is positive, it passes through unchanged ( `ReLU(5.0)` is `5.0`).
- If the input is negative, it is "rectified" (clamped) to zero ( `ReLU(-5.0)` is `0.0`).

This function is both simple to write and performant for the basic math types and quantized integers. But there is no comparable for the microfloat blocks. This asymmetry is not usually a problem however, because `matmul` outputs the `accum` type, which for microfloats is just a 32 bit float.  And a matrix of regular floats works
great with ReLU or any of the other common activation functions. 

```
;; -- ReLU--
(<T A>
  (declare (value-is A #'is-alignment?)
         (type-is (supports-max? T)))
    
  (def-grid-function relu (input-M  &out output-M &key (zero-point (identity-of #'+ T)))
    (declare #'((in-matrix T A)  &out (out-matrix T A))
              (global-size :derive-from output-M :strategy :strided))
    (c-t-assert (when (is-quantized-int? T) (not  (nullp zero-point)))
                "using quantized int requires :zero-point key. The default value would be incorrect for that type.")
    (r-t-assert-0 (and (= (num-cols input-M) (num-cols output-M))
                       (= (num-rows input-M) (num-rows output-M)))
                       "input matrix size must be output matrix size should be same")
    (thread-stride input-M :global-size (x y)
      (set! (~ output-M y x) (max zero-point (~ input-M y x))))))
```

## Acknowledgements ✅

Firstly, I'd like to thank Paul Graham whose essay [Beating the Averages](https://www.paulgraham.com/avg.html) introduced me to Common Lisp and forever altered the arc of my programming career and my life. I've never met him, but without his inspiration Crisp would not exist today.
 I would also like to thank Steffen Larsen and Artur Gainullin for listening to my many rants about "this could be better if only ..." . Thanks to Steffen for reminding me that criticizing is easy, but doing is what matters and also not easy.
I should thank Google Deepmind and Anthropic for AntiGravity and Claude Code. These tools have help speed the implementation at a fantastical pace.
Lastly, I'd like to thank Gemini for being a great sounding board, helping me understand any number of issues and shining light into what would otherwise be a dark impenetrable forest. While Crisp itself is a labor of love, I do work professionally in the field of GPU enablement and yet even with my experience and skill I could not have done this without Gemini. 


## INDECES 

### def-

- def-function      [KO] [D] [T]
- def-grid-function [KO] [D] [T]
- def-kernel             [D] [T]
- def-kernel-exact       [D] [T]
- def-struct             [D] [T]
- def-record             [D] [T]
- def-rec-vec            [D] [T]
- def-setter             [D] [T]
- def-const              [D]  (next to, not "within")
- def-const-vec          [D]
- def-parameter          [D]
- def-enumeration
- def-type                   [T]
- def-derived-type
- def-constraint
- def-type-function
- def-qint
- def-microfloat-block
- def-orchestration          [T]

### control flow
- single-task       [DP]
- when-thread-is                   [3D]
- abs-when-thread-is               [3D]
- when-thread-in-group-is          [3D]
- when-group-is                    [3D]
- when-global-linear-id-is
- when-local-linear-is-id
- when-is-last-workgroup           [3D]
- global-size       [DP] [KO]      [3D]
- local-size        [DP] [KO]      [3D]
- check-thread-bounds              [3D]
- check-wg-bounds                  [3D]
- with-global-linear-id            [3D] ; I keep using this. rename?
- in-each-thread                   [3D]
- in-each-thread-in-group          [3D]
- in-each-group                    [3D]

- loop-vector-stride
- tensor-stride
- grid-stride
- tile-stride
- hardware-stride
- - problem-space-coords
- - tile-coords
- - problem-space-view
- load-tile
- store-tile
- workgroup-stride
- - wg-problem-space-coords
- - wg-tile-coords

- grid-level         [DP]
- workgroup-level    [DP]
- uniform            [DP]
- constexpr          [DP]
- to-uniform         [DP]
- provably-uniform?
- provably-divergent?
- dotimes / dotimes+
- dec-times / dec-times+
- dec-times-by-half / dec-times-by-half+
- dec-times-by-factor / dec-times-by-factor+
- do-times-by-doubling
- do-times-by-multiply
- do-power-step
- dec-power-step
- in-warp
- shuffle
- shuffle-up
- shuffle-down
- shuffle-xor
- warp-ballot
- warp-any?
- warp-all?
- if / if+
- when / when+
- unless / unless+
- cond / cond+
- select-if

### Higher Order Function Operations
- map-stride
- reduce-to-warp
- reduce-to-workgroup
- reduce-to-1-second-stage
- reduce-to-1-atomic
- reduce-to-1-cas
- reduce-to-1-cont
- reduce-vec-first-stage
- reduce-vec-second-stage
- reduce-vec-warp
- reduce-vec-atomic
- reduce-vec-cas
- reduce-vec-cont
- binop-type     
- predicate-type
- get-identity-f  ; needs writeup
- all?
- none?
- any?
- segmented-reduction
- exclusive-scan-workgroup   ; <-- the scans are NOT HOF ops. but Filter is.
- inclusive-scan-workgroup
- global-exclusive-scan-upsweep
- global-exclusive-scan-downsweep
- global-inclusive-scan-upsweep
- global-inclusive-scan-downsweep
- filter
- filter-soa
- find-indices


### Sorting 
- bitonic-sort-workgroup
- bitonic-sort-workgroup!
- bitonic-sort-soa-workgroup
- bitonic-sort-soa-workgroup!
#### kernels
- gen-bitonic_sort_workgroup
- gen-bitonic_sort_workgroup_in_place
- gen-bitonic_sort_soa_workgroup
- gen-bitonic_sort_soa_workgroup_in_place
#### merge_pass kernels
- gen-bintonic_merge_pass
- gen-bintonic_soa_merge_pass
#### orchestrations
- gen-bitonic-sort-vector
- gen-bitonic-sort-soa-vector
- gen-bitonic-sort-vector!
- gen-bitonic-sort-soa-vector!

- histogram-pass
- scan-histogram
- scatter-pass
- gen-radix-sort

### Algorithms
- fft
- fuzed-softmax



### Atomics 
- atomic-add!
- atomic-sub!
- atomic-inc!
- atomic-dec!
- atomic-min!
- atomic-max!
- atomic-xchg!
- atomic-set!
- atomic-binop!
- atomic-op!

### Type Constraints
- type-is               [DP]  
- value-is              [DP]
- is-address-space?   
- is-floating-point?
- is-numeric? <--  replace with is-scalar?  ?
- is-hardware-vector?  (long4 float3 etc)
- is-integer?
- is-orderable?
- is-signed?
- type-has-prop?
- has-overload?
- is-substitutable-for?
- sizeof

### other
- Swizzles   `xyyy~` etc.
- ##(3 4 5 6) 
- return-type         [DP]
- type                [DP]
- #'(int int => int)
- return-type-of       
- type-signature-of   [DP]
- is-type-of
- type-of
- set!
- `XXXX~`
- `~XXXX~`
- make-XXXX
- is-XXXX?
- with-struct-accessors
- with-template-type   [KO] [D]
- XXXX-type
- gen-XXXX
- vector
- `length~ / parent~ / offset~`   [O]
- element-type
- bytes  
- `~`                             [O]
- `~ref~`
- cell
- make-cell
- type-equal
- vector          [KO]
- make-vector          [KO]
- soa-vector      [KO]
- make-soa-vector      [KO]
- convert-soa-to-aos
- convert-aos-to-soa
- make-scratch-cell
- make-scratch-vector
- make-scratch-matrix
- make-scratch-tensor
- scratch-cell-type
- scratch-vec-type
- scratch-matrix-type
- scratch-tensor-type
- load-local
- store-global

- make-implicit-cell
- make-implicit-vector
- make-implicit-matrix
- make-implicit-tensor
- marshall-vector
- marshall-scratch-vector
- marshall-implicit-vector
- marshall-debug-logging-vector
- voidp
- #(1 2 3)
- use                   [DP]
- matrix
- tensor
- make-tensor     [KO]
- make-matrix          [KO]
- num-dims-of
- `extents~`
- `strides~`
- `~` for tensors
- matrix
- col
- row
- num-cols
- num-rows
- get-layout
- transpose
- load-tile
- store-tile
- convert-layout
- fill
- iota
- copy
- dot-prod-grid
- dot-prod-seq
- mat-vec-mult
- matmul
- const-vec-type
- maybe                 
- result               [KO]
- or-else
- as-derived
- as-original
- set-derived
- inline           <== for declare. needs definition  [DP]
- entrypoint            [DP]
- warp-convergent       [DP] <== for declare. Tells compiler code cannot be in diverging branch. reduce-to-warp uses it. 
- workgroup-convergent  [DP]    we get a deadlock in divergent code. checkedd with "divergent-barrier" static analysys
- let-kernel
- kernel-name           [DP]
- /
- floor
- ceil
- round
- #+
- #-
- has-target
- local-mem                 [DP]
- global-mem :return-value  [DP] 
- string-concat
- forward-only              [DP]


### Hardware Operations
- op-popcount
- op-count-leading-zeros / op-count-trailing-zeros
- op-find-msb / op-find-lsb
- op-bit-reverse
- `op-bitfield-extract` / `op-bitfield-insert`
- op-pack-11 / op-unpack-11
- `op-pack-half-2x16` / `op-unpack-half-2x16`
- `op-pack-unorm-4x8` / `op-unpack-unorm-4x8`
- `op-pack-snorm-4x8` / `op-unpack-snorm-4x8`
- `op-pack-unorm-2x16` / `op-unpack-unorm-2x16`
- `op-pack-double-2x32` / `op-unpack-double-2x32`





### logging and debugging
- c-t-output
- c-t-assert
- die
- r-t-workgroup-output-if
- r-t-workgroup-assert
- r-t-output
- r-t-output-0
- r-t-assert
- r-t-assert-0
- line
- file

### static analysis
- declaim
- check-coalesce
- check-bank-conflicts
- check-divergence
- max-registers
- warn-max-registers
- check-barriers

### hoisting and def-orchestration
- def-orchestration
- launch-sequential
- launch-parallel
- launch-kernel
- +wg-size+  ; constant in def-orchestration (only)
- `allocate-cell`
- `allocate-tensor`


### lisp
- let                     [D]        
- '
- defmacro
- math + - / *
- log, log2
- expt
- bit-and
- bit-or
- bit-xor
- logxor
- lognot
- ash
- as-bits
- unless



#### Keys
```
[KO]   => arg list supports &key &optional
[D]    => progn supports inclusion of (declare ...)
[DP]   => can appear IN a (declare ...) list, in the function position
[T]    => can be wrapped by with-template-type
[O]    => can be overloaded
[3D]   => has 1D, 2D and 3D variant
```


<!--

### To Do
- implementation notes for each, esp vector and def-const-vec, def-function, def-kernel
- [x] is our "hoist" code going to include reading the compiled kernel from disk? Seems like it should.
- [x] multiple kernel invocation
- [x] multiple kernels in a single .crisp file.  what does that mean for binary reading and hoist code and compilation?
- [x] tension between vector-type declarations with and without length.  Possible solutions: (user-vector-t-wo-length 20)  or (add-length #'user-vector-t-wo-length 20) ? 
     The "twist" of using the type in the function position is very Clojure, but, honestly, too much of it makes things confusing. 
- [x] SBCL vs C++ ?
- [x] type "narrowing" suggested in with-template-type examples.
- [x] dependent types ( we've introduced them somewhat with tensor-type which takes both a number (dims) and a whole other type)
- [x] maybe type.  on-error-continue   <-- not sure we need on-error-continue.  (or-else <someexpr> <proxy-expr>) should work everywhere, right?
- [x] string formatting? ->  NO.  Just output things with spaces between. Default. 
+ [x] "side channel" implementation notes
- 'safe' types : numeric with overflow notifications/strategies. vector with boundary notifications. User elected? Automatic? I like compiler flag (or possibly `proclaim` )
- [x] lambda and types => DECISION: lambdas and labels are NOT supported
- index of Common Lisp/Scheme things we WILL be taking. defmacro, inc! 
- consider abbreviations: -type => -t    vector => vec  function => func , workgroup => wg
- [x] nd-vector-view and image-view for 2D and 3D ( and ND?) traversal.  convolution  .  image means multi-channel pixel. Defer image.
+ [ ] vector functions: copy, fill, iota. 
+ [ ] tensor functions: transpose , is-abelian? .gather() / .contiguous() 
                    "transpose" operation can often be done without moving any data. Just change the strides of the tensor.
      tensors handle most slicing/shaping needs.  also "broadcasting" which is setting one of the strides to 0. So the "next row" calculation goes nowhere. It's a simple way of taking a [1 2 3 ] and making into [[1 2 3] [1 2 3] [1 2 3]...]
- [ ] is-symmetric?  symmetric tensors only need to store upper triangle ( which may be more than half ).  How to map that to/from a linear vector? 
    would it have to be immutable?    Might need custom  `aref`/`.` than knows how to "mirror" indeces.  
- [ ] make-identity/is-identity   <-- square matrix with 0 everywhere but 1 on diagonal.  Once again, a fle
- [x]ROW MAJOR / COL MAJOR - should we borrow?
- [x] 1D tensor needs to pun for a vector.  Can our sub-type system handle or does it need special support?

- [ ] rename def-const-vec to def-compile-const-vec OR def-device-const-vec  to further separate it from other "def-" things.
- [ ] TILES? No.  SAMPLER? Yes, but not advised.
- [ ] declare "side-effect-free" or maybe "function" or "procedure" ?
- [ ] Matrix Operations: (matmul A B) (transpose A)    
    [ ] (m*v M v) - convenience function for matrix-vector multiplication. Very common special case of matmul
    [ ]  (make-identity-matrix N) -- square.    (make-zero-matrix rows cols)
    [ ]  (determinant A)   (inverse A)  -- slightly advanced. but common
- [ ] sparse tensors / sparse matrix  : OUT OF SCOPE FOR NOW
- [x] VARIADIC!! ( how could I forget ? )  &rest ArgList  <--  uses List. Is this a good match? I have reservations.
   for defmacro it seems like this might be useful, central maybe.  But it would make def-function etc difficult to realize.
   OTOH OpenCL C does not support variadics. So it could be a win if achieved. 
   Maybe TEMPLATES could be variadic, but at compile time the interface for a function is compiled exactly. (aref vec x &rest coords) => (aref vec x y z w) for a 4D vector-view ? 
- [x] Might need to reexamine variadics anyway. Is + going to be variadic like in Common Lisp? That means an implicit reduce, plus difficult to do without CONS cells,  
  which I do not want to introduce.  Maybe just overload + for 2, 3, and 4 args and call it a day?
    DECISION: defmacro is variadic, functions are not
- [ ] C++ has "explicit" for constructors to prevent them from participating in automatic type conversion.  Do we need anything like that?
- [ ] `identity-tensor` and `maybe` both have the risk of introducing too much "logic" code, which will not be performant
   Same goes for "safe" numeric types.
- [ ] metadata:  'bifurcation count' and 'cognitive load'.  Not sure. 
- [ ] give more thought to "events". Not sure what CUDA does. 
- [x] in-warp / in-XXXXX  =>  is this really better than just (let ((lane-id (get-lane-id))) ...)  &c.  Esp consider: (let (in-warp (let ...)))  which is a lot of nesting versus ONE  (let ...)
+ [ ] OTHER reductions: scan / boolean (all, any none?) / Segmented
- [x] reduce-vec ?
- [ ] pronounce "shuffle" as "shoo-FLAY"
- = specialization constants? More of a host thing.  Host runtime access to crisp compiler seems more powerful.
- = How will compiler work?  Multi-pass is simplest? macro-expansions. Tree shaking? Can libraries be built for faster compilation time? 
- = Compile Time Properties?  We have `num-dims-of`  already, possibly `address-space~` , `element-type-of` 
    Tension between `someProp~` and `someProp-of` .  
If so, what does THAT look like?   Imagine libraries with many functions, not all used.  We have a dependency of A -> B -> C, where A has the main changing kernel code.  Someone wants to recompile A _fast_ . Can we avoid recompiling C? or B?  Can the USER prepare something so that minimal compilation is required? If so, how?
- = is member-get/set! the best way?  Will we then need atomic variations on them as well?
    maybe we have (. someVec i)   and (.! someVec i)   where .! is not overrideable?
- = rename . (again)?  PROPOSAL: use ~ for vector access ~x  for struct access.  And maybe ~= for Non-overideable variants or maybe ~~ or maybe ~ref and ~x~   ( though, I think double tilde might be reserved in  markdown for strikethrough).   This helps make them ALL useful for (atomic-add (~x~ somePoint) delta)
+ `+` variants should use shuffles instead of local memory
- other things
- - [ ] fp rounding mode
- - [ ] general register file configurable?
- + [x]complex numbers
- + [ ] group barriers
- - [ ] prefetching
- - [ ] marshalling / directing of workgroups.  Seems like host should do this. But perhaps I lack imagination. reduce_over_group ? 
- - [ ] thread block clusters  ( CUDA only? )
+ - [x] atomics 
- + [x] conditional compilation of kernel functions for device aspects.  or maybe `(when+  (device-supports-fp16?) ... )` ?  (device-has? :fp16)
+ - [ ] dot product and accumulate for matrices, and maybe all tensors?

FUNCALL vs DIRECT USE. -- Let's try for direct use?  funcall was always confusing. 

[x] NO RECURSION. NO MUTUAL RECURSION 

[X] VARIADICS REVISIT -  Macros could be variadic.  But runtime functions no.  This might be a good compromise.

[x] DERIVED TYPE REVISIT - how to extend with new properties?  What would that mean vis-a-vis :subst options?
      ANSWER: no extending. a. Make two types:  struct-A { int }  struct-B {int, float}  
                            b. (set-derived struct-A-type struct-B-type :subst :pass-orig) 

[X] C interop with structs/vectors 

[x] LAMBDA REVISIT - uniform lambdas OK?  

[ ] OVERLOAD REVISIT - how will overloaded functions, especially getters/setters, be useful if there is no var capture or globals?
                   (def-function make-xxxx ()   (def-function overload-of-something () ...))  ?  

[x] DEF-KERNEL-EXACT ?  - our def-kernel assumes someone will be using our hoisting code.  BUT for people that have hoisting code already and know
                      the exact interface, they should be able to define it.
                      QUESTION:  how do THEY get vectors over then? void* data and size_t bytecount / versus / double* data and size_t count.
                      A1:  special declare?
                      A2:  marshall-vector call and voidp type.

[x] vector-view that changes element type. (like casting a vector of double to long) "reinterpret"

[ ] DATA-POOL   - could be a real value add here. Kernels can't really dynamically allocate memory, so a pool system would be handy.
              Also very handy if we can calculate how much scratch will be needed and communicate that back in the hoisting code.
              Could be in terms of kernel args.  DataPoolSize = sizeof(double) * vector-A.lenth * 1.7 

              This also suggests that "scratch" and "return"  data-pool entries are handled.  via type sig? declare? proclaim? 

[X] COPY-BACK   - are "result" vectors automatically copied back? (As opposed to "implicit"?)  Assuming no (safe assumption), 
              what is the mechanism for this? Often times it is a separate kernel. Need to understand this better.
              How will users doing their own result kernel args get things copied back?  Unified Memory vs Non vs Buffer vs ??

[X] MACROEXPAND - where to put this? A REPL tool? compiler flag?


[x] SORTING  ( [ ]radix & [x]bitonic   - probably over warp, workgroup, global, vector)

[X] PROFILING ? yet another side channel?   advise?  -- is mostly a host side issue, correct?  
    DECISION: hoisting example code will have commented out code that enables profling. 
              (get-timestamp) function available.   
              That's enough to help a user.  Later we can add "advise" 

[x] IN MEMORY COMPILATION API -- needs to be specified. 

[ ] ENTRYPOINT

[x] fused softmax ( whatever T F that is.)

[x] Am not totally loving the reduction macros. with-template-type wrapped over function seems better?  Or maybe defmacro should be   
    statically typed.  Having it slip through the cracks seems weird, and dangerous.

[x] REVISIT / CLEAN UP MEMORY / SUMMARYIZE and COMPARE .  a) make-vector with compile-time known size: fully supported.  
      b) various "scratch" local/global . d) def-constant-vec/use 
      e) communicate with hoisting, derive-from f) side-channels g) #( 1 2 3)  
      h) (declare (shared someVar) (uniform otherVar))   "shared" could be "local" or "slm" ?  This declare is for let clauses
         difference between "shared" and "uniform"

[x] Pretend we introduce 'while' or something. If a kernel does run infinitely, how can it be stopped?
    presumably some 'terminate()' call from within kernel. But what about from host? A: Not easily from host. Requires reset. 

[ ] OTHERS
   -Mojo    ( https://www.modular.com/mojo )  One language, any hardware.  Bare metal performance. Pythonic Code.  
    -Triton  ( https://openai.com/index/triton ) open source gpu programming for neural networks. 
    -Cutlass  ( https://github.com/NVIDIA/cutlass ) CUDA Templates and Python DSLs for High-Performance Linear Algebra
    -Hillisp ( https://github.com/michelp/hillisp )   tiny Lisp implementation written in CUDA.  Drives the GPU.  Queues up "fill" kernels, "+" kernels, etc. 
    -CL GPU ( https://www.cliki.net/cl-gpu )  subset of Common Lisp on GPU
    -cl-gpu ( https://github.com/angavrilov/cl-gpu ) A library for writing GPU (CUDA) kernels in a subset of Common Lisp.
    -ATen ( https://github.com/zdevito/ATen )

[x] Debugging Story - Give more attention.  A REAL pain point with developers.

[no] Generate Crisp from Python.

[x] FFT 

[ ] warp scheduling and [x] memory coalescing

[x] def-orchestration / calls kernels and some prebuilt affordances: cuBLAS, possibly oneMKL?.  "soft description". basic vector declarations, data passing, looping.
    probably need a (TBD ...) and (hoist-comment ...) macro.   Templates?  Gen?  


#### To Do (SHORT)
- [x] FFT
- [x] Radix Sort
- [x] Debugging Story
- [x] Compile-time introspection first-class citizen: 
    [x] get-struct-members   / with-struct-accessors
    [x] ~is-grid-level?~  / is-thread-level?
    [x] get-return-type
    [x] get-member-types
- [x] reduction macros -> templates
- [ ] OTHER reductions: 
- - [x] scan 
- - [x] boolean (all, any none?) 
- - [x] Segmented
- [x] Math: sqrt / rsqrt / pow / exp / log / log2 / sin / cos / tan / asin / acos / atan / abs / min / max / clamp
- [x] ENTRYPOINT - for libraries
- [x] fused softmax
- [ ] use maybe something "real" (texel ?)
- [ ] data pool
- [x] vector-view that changes element-type
- [ ] dot product and accumulate for matrices
- [ ] / group barriers
- [x] complex numbers - need for FFT
- [ ] matrix ops / vector ops
    [x] (m*v M v) - convenience function for matrix-vector multiplication. Very common special case of matmul
    [ ] / (determinant M)
    [x] fill
    [x] copy
    [x] iota
    [ ] gather
    [ ] (is-contiguous? M)
- [ ] / (declare (critical name V)) ; if fighting "spill", how important is one value vs. another.
- [x] / def-orchestration
- [ ] / (hoist-comment )
- [x] / (declare (const var-name))
- [x] Kernel IPC
- [x] Data interleaving. Mostly host side, but kernel needs to be able to work in chunks. 
      Kernel typically takes an "offset" into the data. (vector-view vibes).
      Works well with "embarassingly parallel" ops like: vector_add, convert-layout (matrix transpose), grid-strides,
      But won't work with: reductions, filter (and prefix-sum-scan), sorting (radix/bitonic). 
      [ ] Merge sort, however, chunks.  (Could be done using bitonic/radix for the smaller sets)
      There is a REAL need here. Data interleaving has a lot of reqs.  So setting up a sample might 
      be fire.

#### SHORTEST
[x] Entrypoint
[x] Strings (too much handwaving)
[x] mapping and composition
[x] update all old routines and remove them.
[x] workgroup-level  -- is-thread-level? might be impacted
[ ] ident / (identity-of #'max T) => -INF or wahtever.
[ ] (supports-max? T) or (supports? #'max T) ?
[x] Segmented (b.c. hard)
[x] Quantized Ints
- [x] dot-prod
- [x] matmul
- [x] mat-vect-mul
- [x] convolution
- [x] pooling (average / max)
- [x] activation functions ( ReLu etc)
[x] FP4 / FP8 -- microfloat blocks
[x] (declare (convergent)) (ragged-edge) ? and friends
[x] matrices and tensors as first class kernel args? Yes: Document. 
[x] rename "vector" as "storage". "vector-view" -> "vector", etc tensor matrix.
    and, yes, the NEW vector, matrix, tensor are first class kernel args.
    dumb storage is the storage but access is via views. the ex-views ALL
    have "offset" and "stride". 
    [x] update "Member Data Rules" for vector
    


Three things:
- maybe type in loops?  I'm just NOT using it. 
- where can these new bad boys be used? gather-all/scatter-all!
- maybe GLOBAL vector alignment?  <-- not for Crisp itself or libraries maybe?
  the constant capturing of A is noisy.
x FRANKLY, the constant templating of vectors is noisy. HMMMMM  (<T>  (def-fun..))
x gen-XXXXX on ANY grid-function to generate a kernel? (that doesn't take a function arg)
x these vectors of 1.  HMMMMM
- send code to Gemini?  AWESOME feature
x curry/lambda for word_count. f*ck
x lose make-vector and gen-make- and use make-scratch-vector instead. Defaults to :local, can be overriden.
- concepts / type classes / type collections.  microfloats and quantized integers
  seem like they should be leveraging a generalizable pattern.

  -->

<!-- PUT THIS LITTLE SUMMARY ON MEMORY SOMEPLACE 
### Memory

Memory cannot be allocated by the kernel itself. Only the host or the compiler can do so.

There are five different categories we need to consider:
- **Global:** Set up by the host. This is your main communication channel for large data sets. Slow.  This memory CAN be set up by the compiled code of the kernel, but that is an anti-pattern. A bad idea. 
- **Local (Shared):** Set up by the host via kernel arguments. This is for fast, on-chip sharing among threads in a workgroup.  This memory CAN be set up by the compiled code of the kernel as well. 
- **Constant:** Set up by the host. This is for read-only data that's broadcast to all threads.  This memory CAN be set up by the compiled code of the kernel as well -- but MUST be done BEFORE the kernel executes. 
- **Registers:** Managed automatically by the compiler. This is for variables that need to be accessed quickly and frequently.

- **Private:** Managed by the compiler. This is for per-thread variables, analogous to a CPU stack.


-->
