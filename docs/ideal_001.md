CRISP - Lisp for developing GPU Kernels
=======================================

> In C you use C to solve a problem. In Lisp you make the language fit the problem, then you solve it.
>
> — *Popular Lisp Adage*


Overview
--------

Crisp is a Lisp dialect for developing GPU Kernels.
The Crisp compiler takes .crisp files and can output SPIR-V, PTX, or a binary for a specific GPU. 
The compiler can ALSO output C++ or Python code snippets that can "hoist" that same kernel. 
The snippets can be targeted to: OpenCL, LevelZero, or CUDA, as well as whether to use
Unified Memory/USM/SVM.


Focus
-----

The focus is on performance, compiliation speed, safety and correctness.
GPU idioms like tensors, shuffles, memory addressing, grid strides, structs-of-arrays, and more are directly exposed by the Crisp language.


Major Features of the Crisp language and tools
----------------------------------------------

- Hoisting and Tooling Ecosystem. Crisp has a Kernel First approach. While Crisp is used to write GPU kernels (only), the compiler can output boilerplate
  C++ or Python code that loads, prepares and runs each kernel, as well as copy back its data. 
  The hoisting code can also demonstrate how to take that same kernel as a string and JIT Compile
  and run it.
- Guaranteed Safety and Termination. Crisp is not Turing complete. By virtue of that, it is not subject
  to the halting problem.   Kernels written in Crisp are guaranteed to finish.
  <!--  This is different than guaranteeing that the Event is completed. For example, an out-of-bounds access could cause a kernel to terminate
        but its event might not ever be completed.  
        Also, deadlocks are not preventable (though Crisp has several metaphors that help)
        -->
- Extremely Fast Compilation. With the lib and lib caches and in-memory compilation, Crisp can be configured
  to be an integral fast compilation system featuring maximum re-use of preperatory precompilation.
- In-Memory Compilation API: Crisp is designed as a compiler library, not just a command-line tool. 
  It features a C and Python API that operates on in-memory source code strings via a virtual file system, completely avoiding disk I/O for the fastest possible Just-in-Time (JIT) compilation.
- Pragmatic Error Handling. Crisp has  optional debug logging that is turned on with a compiler flag.
  It also has a simple `maybe` type to streamline code past errors and with a minimum of thread divergence.
- Common GPU practices like strides, structs-of-array (AoS and SoA), shuffles, reductions across workgroups and warps are all
  expressed as top level language features. 
- "Side Channels" give the programmer the illusion of on-demand memory allocation. Crisp already 
  has side channel support for scratch memory or return results. 
- Strongly typed with all types resolved at compile-time. Crisp does not feature dynamic typing.
- Powerful Metaprogramming: By leveraging a Lisp-based syntax, Crisp supports powerful and clean metaprogramming.
  The `with-template-type` system automatically   generates type constructors and specialization functions, allowing for a level of abstraction and code generation that is difficult to achieve in other kernel languages.
- Functions support multiple return values. 
- Variadic functions are not supported, however variadic macros ARE. Anyone familiar with Lisp knows the power of `defmacro`  
- The type system supports templates and incomplete types for flexibility. 
- All variables and parameters will attempt to be stored in registers for performance. Some can be 
declared more or less critical in the event of register "spill" when there are not enough. 
- Kernels and functions can declare how/what they depend on or expect the enqueing code to configure
 global and local work sizes.  These expectations are output into the hoisting example code that is output.
- Opt-in static analysis is available. Different checks are requested individually per-function or per-kernel. When
  activated the Crisp compiler can check for memory coalescence, bank conflicts, thread divergence, barrier deadlocks and more.

Differences From Lisp
---------------------

While Crisp is an s-expression based language and shares with Common Lisp the very powerful `defmacro` 
construct as well as many other fundamentals ( `if`, `when` `cond`, `let` etc), there are 
marked differences between them.  

### no list data type.  

Crisp does not support the list data type. Nor cons cells. Nor linked lists. Internally, the compiler might be using
them to represent code, but there are no lists available to the Crisp developer.

### no ratios or bignums

Most Lisp and Scheme variants represent numbers in a numeric tower that include
ratios fully storing both numerator and denominator and more. Crisp has no such affordance.
In only exposes the numeric machine types that are availble on GPU hardware. 

### no dynamic memory or garbage collection

Scheme and Lisp implementations have implicit memory allocation and collection. Crisp does not.
It does have "Side Channels" which can be used for intermediate scratch memory and return
results memory. To be discussed later.

### static typing, not dynamic

As already mentioned, Crisp is statically typed.  There is no runtime typing of any sort.

### 0 is false

Crisp follows Python and C++ and treats 0 as false.  In Common Lisp, which supports
dynamic typing, there are strong reasons for having 0 be true, but given that Crisp
doesn't support dynamic typing and its intended audience is likely more familiar
with CUDA, C++, Python and OpenCL C, Crisp follows their practice and 0 is false.

### no recursion

Crisp does not support recursive functions, nor mutual recursion. 

### no condition/restart system

Common Lisp has an EXCEPTIONALLY powerful system for handling errors with restarts and more. 
Crisp's has a modest (yet performant) `maybe` type to help catch and log errors with a
minimum of branch divergence.

### no eval

To many a 'REPL' (Read Eval Print Loop) is the most basic requirement to be considered
a Lisp. As Crisp targets GPU kernel (only) this is not possible. 

### no CLOS

The Common Lisp Object System is likely the most powerful object system ever designed.
Crisp has nothing comparable, but instead offers modest structs, derived types, and function overloading. 
These are simple and should be flexible enough to get things done.

Thread Level / Grid Level / Dispatch
=========================================

In most Lisp languages, `progn` is a term used to desribe a set of code that is grouped together and bound 
by parentheses. In C++ we might say "the body of a function" or the "body of a closure". In C++ a `progn` is
typically surrounded by curly braces `{ ... }`  .

In Crisp, the `progn` that appear in function bodies implicitly have one of three "contexts" that
inform the compiler on the type of and scope of actions that might be taking place in that `progn`.
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
Grid level contexts most often come from macros like `loop-grid-stride`. Inside a grid level
`progn` making  thread level operations is perfectly fine. But calling OTHER grid level operations
is forbidden. 

A dispatch context is a context where we can call either thread level or grid level 
operations freely. But note, that if a grid level `progn` is opened that inside its body the
restriction on calling other grid level operations still applies. Dispatch contexts are 
associated with `def-kernel` and `def-grid-function`. 

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


Why This is Different from C++/CUDA
-----------------------------------

In C++/CUDA, there is no formal distinction between a "dress pattern" and an "assembly line blueprint" A programmer can accidentally write code that has a single thread try to launch a new, grid-wide operation. The C++ compiler won't prevent this. This code compiles but results in a silent, catastrophic bug: either the logic is fundamentally incorrect, or the performance is thousands of times slower than expected. The developer is left to debug a complex runtime issue with no help from the compiler.

Crisp's context system provides guardrails. By separating `def-function` and `def-grid-function`, the compiler understands the intent of your code. If you try to call a grid-level function from a thread-level context, you get an immediate, clear compile-time error, not a mysterious runtime bug.

In short, this system provides:

 - Safety: It makes a whole class of parallel programming errors impossible to write.
 - Clarity: It makes the code self-documenting. A `def-grid-function` is unambiguously a parallel operation.
 - Readability: It separates the high-level orchestration of a kernel from the low-level, per-thread implementation details, making complex algorithms easier to reason about.
 


Top Level Execution Constructs
==============================

In Crisp, nearly everything that can be put at the "top level" of a code file begins with "`def-`".  
There are a handful of exceptions (*), but that is the general rule. And every other Crisp expression
is then inside one of these definitions and cannot appear, unchaperoned, at the top level.
Of these "`def-`" expressions, there are three primary ones that serve as execution constructs:
 `def-kernel`, `def-function` and `def-grid-function`.

 (* Exceptions: `declaim`, `with-template-type` )

`def-kernel`
------------

```
(def-kernel do_something (i val VEC)
   ;; <type-declaration-here>
   (set! (~ VEC i) val) ;; store val into index i of VEC
 )
```
We'll discuss type declarations and type signatures later. For now, just understand that
`def-kernel` is how you define a kernel function that can be enqueued and invoked by some
host application.  The host application can only invoke kernels that you define, no other
functions.
Kernel functions
- take arguments like a regular function
- do not return values
- are not callable by other Crisp functions (see "continuation kernels" for exceptions)
- the body `progn` of the kernel function is a dispatch context
- can call both "thread level" functions and "grid level" functions.
- kernel function names (like "do_something" above) are restricted to C-style naming rules (ie "do_something" with an underscore is valid, but "do-something" with a dash is not.)
- kernel function names are case sensitive - unlike nearly everything else in Crisp which is case insensitive.

`def-function`
-------------
```
(def-function do-add (x y)
   ;; <type-declaration-here>
   (+ x y)) ; return the sum of x and y
```
`def-function` defines a function, just like you would do in nearly every other programming
language. Functions take arguments and return values, they have mandatory type declarations (see below).
The functions that are defined are "thread level" functions, meaning they are expected to operate in the context
of a single thread and not orchestrating the operation of all threads generally.

Thread level functions
- accept arguments
- CAN return values
- the body of these functions are a "thread level context" (more about this later)
- can call other thread level functions
- but CANNOT call "grid level" functions or use grid level macros
- can use Lisp-style naming rules. (dashes ok in function names, case insensitive)

`def-grid-function`
------------------

```
(def-grid-function vector-add (A B &out C)
  ;; <type-declaration-here>
  (loop-vector-stride A (i)
     (set! (~ C i) (do-add (~ A i) (~ B i))))) ;
```

`def-grid-function` also defines a function, much like `def-function` above. 
Grid functions have a "dispatch context" at their top level. They
are called "grid functions" because the CAN invoke grid level operations 
(as opposed to thread level functions which cannot).

Grid functions
- accept arguments
- CANNOT return values
- have a "dispatch context" in the top level
- can call thread level functinos
- can call grid level functions
- can use Lisp-style naming rules (dashes ok).


Return Vector Pattern `&out`
============================

Because kernel and grid functions cannot return values, the accepted
pattern is to pass memory to them where you want results to be recorded.
This is very common in GPU-land.

But there are caveats that if not well managed can lead to bugs.
It may be tempting to use a grid operation to calculate something, and 
then, afterward, "peek" at the solution.  

Like so
```
;; --- INCORRECT ---
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
Any variables after `&out` must be a `:global` vector ( or an acceptable `vector` proxy, or `soa-vector` and its proxies ).

It is encouraged that the access is set to `:write_only` but this is not a strict requirement.  
Importantly, regardless of the `:access` setting, within the functions scope the compiler enforces a write-only contract. 
Any attempt to read from an `&out` parameter will result in a compile-time error. 
Thus protecting you from accidentally making the race condition mistake.

```
;; --- CORRECT ---
(def-kernel calc (A &out B)
 ;; <type-declaration-here>
 
 ;; use grid level operation to square every element of A,
 ;; storing it in B
  (loop-vector-stride A (i)
    (set! (~ i B) (square (~ i A)))))
```

If you are implementing the "return-data-via-vector-parameter" pattern,
then use `&out` and enlist the compilers help in enforcing usage boundaries.



Argument Passing and Side Channels
==================================

As a general rule, GPU Kernels cannot allocate dynamic memory. This means that the host has to allocate 
and prepare ALL the memory a GPU kernel might need. The host needs to prepare the memory that will receive the result
of the operation. The host will also need to prepare memory for any scratch/intermediate operations the kernel might need.

The normal practice is that the kernel function has its parameter list for incoming arguments and everything the kernel
needs is present in its calling interface, and it passes those arguments down to subfunctions, as appropriate. 

There are two specialized Crisp constructs that can help with this: `make-result-vector` and `make-scratch-vector`.  These
operations, discussed in detail below, allow you to "pretend" to allocate memory
in your  kernel.   Each invocation of `make-result-vector` results in an extra allocation of memory appearing in the example
hoisting code, with a matching pointer passed implicitly as a kernel argument. Uses of `make-scratch-vector` are collected
by the compiler and are combined into a single scratch memory pool, which is similarly added as an implicit kernel argument.  These are conveniences.  The compiler calculates the size requirements for these and outputs them to the hoisting example code, but it's ultimately up to your final hoisting code to ensure the memory is sufficient.

Another side channel that adds implicit kernel arguments is the debugging communication channel, which can be enabled during compilation.

Lastly, kernel developers who want their own "side channel" can do so with `make-implicit-vector` , or if the data is constant and 
known at compile time then `def-constant-vector` and `use` would be better choices.

Side channels introduce side effects into functions that would otherwise be referentially transparent. For this reason, it's often better to avoid them. Many users choose to declare result memory in the kernel parameter list and pass it to sub-functions rather than introducing this impurity. Crisp supports both formulations. 


Crisp Types
===========

Because compile time types are a significant departure from most familiar Lisps, the next several sections
are focused on type declaration and support in the Crisp language.  


Base Numeric Types
------------------

| Type | Size |
|------|------|
| char | 8 bit |
| uchar | 8 bit |
| short | 16 bit |
| ushort | 16 bit |
| int | 32 bit |
| uint | 32 bit |
| long | 64 bit |
| ulong | 64 bit |
| half | 16 bit |
| bfloat16 | 16 bit |
| float | 32 bit |
| double | 64 bit |



Vector Numeric Types
--------------------

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
(let ((my-svec:short3 ##(5 6 7))
      (my-dvec ##(3.0 4.0 5.1 6.0)))
  (declare (my my-dvec double4)) 
  ...)
```

### Dereferencing and Swizzles
The subelements can be dereferences with the `x~`, `y~`, `z~` and `w~` functions.
Furthermore, Crisp supports "swizzles" (like `xyyy~`)

```
(let* ((my-svec:short4 ##(5 6 7 9))
       (all-six          (yyyy~ my-svec))
       (tail-part      #(0 0)))
  (declare (type tail-part short2))
  (set! (xy~ tail-part) (zw~ my-svec))
  ; OR
  (set! tail-part (zw~ my-svec))
   ...  )
```

Numeric Type Promotion, Casting, Conversion
-------------------------------------------

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

This applies element-wise to hardware vector types as well:
`ucharN` -> `ushortN` -> `uintN` -> `ulongN`    (etc for signed integer and floating point).

All other conversions require an explicit cast.

```
;; COMPILE ERROR: No automatic promotion between int and float.
(let ((a (some-int-returning-op)))
  (some-float-op a))

;; CORRECT: Use an explicit conversion function.
(let ((a (some-int-returning-op)))
  (some-float-op (to-float a)))
```

### Convert: `to-` , Cast `as-`

If you need to move between numeric types, Crisp gives you two affordances: `to-XXXX` and `as-XXXX` where `XXXX` is 
the target type name (eg. `to-float`  `as-int`)

#### Value Conversion 
`to-` converts the type "correctly" (or as correct as can be done) and will move bits to do so.  It is the equivalent
to a "static cast" in C++.  Converting across categories, or to smaller sizes, may lead to loss of information and/or 
accuracy.

IMPORTANT:  for floating point to integer conversions, `to-int` and friends are NOT DEFINED. 
Instead, you must explicitly choose which conversion you want:  `truncate`, `floor`, `ceil`
or `round`.  See the section on integer division for a comparison.

<!-- NOTE: maybe move that section on truncate/floor/ etc to yet another place? -->

```
(let ((f (some-float-returning-op)))
  (some-int-op (ceil f)))
```

#### Bit Reinterpretation
`as-` just tells the compiler to pass the value through with no action taken. No bits moved. It is inherently unsafe.
It is the equivalent of "reinterpret cast" in C++.


```
;; without `to-int` below, this would not compile
(let ((f (some-float-returning-op)))
  (some-int-op (to-int f)))
```





Other Basic Types
-----------------

> NOTE: this section needs work

### bool    
- `bool` is a type
- its values are `true` and `false`
- any zero number value puns as `false`
- any non-zero number value puns as `true`
- `nil` is a compile-time expression (not runtime). It also puns as `false`.
- an instance of any other Crisp type (struct, vector, etc) puns as `true`.

Currently under debate whether `bool` is an instantiable value.

keyword (e.g. :some-key) -- is a type of symbol. compiler converts this to unique byte value. 
                            

function (#'someFunction)



Declaring Types - Functions
---------------------------

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

;; D -- use colon (:) to attach type directly to variable. return type must still be declared.
(def-function addInts (a:int b:int)
    (declare (return-type int))
  (+ a b))

;; E -- multiple values return
(def-function divInts (a b)
; divInts returns both the quotient AND the remainder.
    (declare #'(int int => int int))
    ...)

(def-function divIntsAgain (a:int b:int)
    (declare (return-type int int))
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
  (declare #`(&key birds:int fish:int zombies:int => NIL))
  ...)

(def-function addSome (x:int &optional y)
  (declare (return-type NIL) (type y int))
  ;OR
  (declare #'(int &optional int => NIL))
  ...)

; default values do not appear in type signature
(def-function addSome (x &optional (y 30))
  (declare #'(int &optional int => NIL))
  ...)

;; I -- skip return type in kernels and grid functions
(def-grid-function bury (meters:float)
   ;types declared in paramter list, no need to declare anything else
   ...)

(def-grid-function sharpen (edge)
  (declare #'(float => nil))   ; nil is return type
  ; OR
  (declare #'(float))          ; no need for return type

;; J - &out -- write-only-vectors
(def-grid-function vector-add (A B &out C)
   (declare #( v-type v-type &out (v-type :write_only)))
    ...)
```




Function Overloading
--------------------

Crisp support function overloading for functions defined with `def-function`, `def-grid-function`, as well as property access functions on 
some of the other types. Note that property access via a `soa-vector` requires an additional overload. The compiler
will warn if it detects `soa-vector` property access with an asymmetric overload.

Overloaded functions can have the same name, but different type signatures. The compiler will use the 
types of the given parameters to determine which overload should be called. 

`def-kernel` function CANNOT be overloaded. Each kernel function must have a unique name.

As mentioned, the property access functions that some types support can be overloaded as well (discussed later), 
but the `make-XXXX` functions CANNOT be overloaded. 


Recursion Disallowed
--------------------

Crisp does not support recursive functions, nor mutually recursive functions.  The compiler will emit an error if it detects this.




Declaring Types - Kernels
-------------------------

### def-kernel

`def-kernel` defines a kernel function. It is much the same as `def-function` with only a few differences:

- `def-kernel` functions always returns NIL. It does not need to explicitly declare a return type.
- `vector` types must be fully typed with address space, access, alignment and element type. (See Vector Types below)
- `def-kernel` functions do NOT support `&key` or `&optional` arguments.
- but it DOES support `&out` 
- the function name for kernels MUST obey the C standard identifying rules.  Thus "do_something" is a valid name, but "do-something" is not.
- unlike regular functions, kernel functions do NOT support overloading. Each kernel function must have a unique name.

Like `def-function` ALL the parameters to the kernel function must have their types declared somehow. 

```
; note the name "add_two" is a valid C identifier
; note also that since the arguments are typed in the parameter list, we didn't need a declare directive at all. 
;  the return type is assumed NIL.

(def-type int-result-vector (vector-type int :global :writeable :std140 1))
(def-kernel add_two (a:int b:int &out result:int-result-vector)
   (set! (~ result 0) (+ a b)))
```

`def-kernel` can be templated ( see `with-template-type` below), but in this case you MUST explicitly provide a `gen-KERNELNAME` at the top-level
for each specialized kernel you want the compiler to generate. Otherwise the compiler will not output the kernel at all.  

### Implicit Arguments

The example hoisting code that Crisp outputs will often have more arguments than the ones in the parameter list of `def-kernel`.  

There are five different cases where this happens:
 - vectors
 - debug communication channel
 - scratch memory
 - result memory
 - user defined "implicit" vectors

 Crisp lets you put vectors directly into the kernel parameter list, but in practice the hoisting code will often need to set TWO arguments: a C-style pointer
 to the data and a size argument.  The kernel will handle marshalling those separate arguments. 

If the debug communication channel was elected when compiling the kernel, then the kernel will accept two additional arguments
for the debug data channel data pointer and size.   <!-- NOTE:  we might use interprocess comm for this. update as appropriate -->

If the kernel or any of the functions it calls invoke `make-scratch-vector`, then then kernel
will accept two additional arguments for the scratch memory pool and its size. 

Similarly, every invocation of `make-result-vector` or `make-implicit-vector` add two implicit args (pointer and size) to the kernel.

<!-- NOTES
clSetKernelArg : https://registry.khronos.org/OpenCL/sdk/3.0/docs/man/html/clSetKernelArg.html
clEnqueueNDRangeKernel: https://registry.khronos.org/OpenCL/sdk/3.0/docs/man/html/clEnqueueNDRangeKernel.html
Note that nearly all the args for clEnqueueNDRangeKernel revolve around the NDRange (and event list). 

-->

### def-kernel-exact

`def-kernel-exact` is like `def-kernel` . It can be templated and has the same restrictions.  
But kernels defined with `def-kernel-exact` do NOT support any implicit arguments.  
Additionally the `&out` argument specifier is not supported in the param list for `def-kernel-exact`
Instead `def-kernel-exact` supports different marshalling functions to help create Crisp vectors, 
including the ones required for the Crisp debug, scratch and result vectors.

`def-kernel-exact` is provided for users who have less control over how their kernel is hoisted and may have to instead adapt to some existing interface.

#### voidp type and marshall-vector
`def-kernel-exact` can use the `voidp` type for its arguments, but this type cannot be used in other contexts.  It can also call the `marshall-vector` function
which is a function Crisp provides for making Crisp vectors from `void` pointers and byte counts. This function cannot be used in other contexts.

```
(def-type float-vec-t (vector-type float :global :compact))
(def-kernel-exact vector_add_k (APtr:voidp ASz:ulong BPtr:voidp BSz:ulong CPtr:voidp CSz:ulong)
  (let ((A (marshall-vector APtr ASz (float-vec-t :read_only)))
        (B (marshall-vector BPtr BSz (float-vec-t :read_only)))
        (C (marshall-vector CPtr CSz (float-vec-t :write_only))))
    (vector-add A B C)))
```

The recommended practice is to use marshalling functionss immediately within a `def-kernel-exact` body 
to create standard Crisp views, and then call some some inner function. That inner function will let you leverage
the `&out` specifier and possibly other safety checks. 

#### implicit vector arguments

If the kernel or any of its subfunctions use the Crisp side channel convenience functions
like `make-scratch-vector` , `make-result-vector`, `make-implicit-vector` OR if the kernel was/will be compiled with the debug logging option, then these vectors will have
to be  explicitly passed by the host and marshalled.  

- `marshall-scratch-vector`
- `marshall-result-vector`
- `marshall-implicit-vector`
- `marshall-debug-logging-vector`

Note that both the metadata and the example hoisting code that the compiler outputs will have size expressions gathered 
by the compiler for all of these. Be sure to incorporate them into your own enqueueing/hoisting code.





Struct Types
------------

`def-struct` defines a structure and makes a new type. 

It also generates functions to create instances of struct (`make-XXXX`), and to access its members.
Additionally, the type constraint function `is-XXXX?` is also generated.



<!-- NOTES:  The compiler will treat these custom "functions"  as direct data offsets.  
If a user wants to pass #'make-point or #'x~ as first order arguments, 
then the compiler will generate a function for that.

Common Lisp would generate "point-x", but Crisp generates "x~".
I believe Clojure allows structs and vects to be in the function position:  (somePoint 'x)  (someVec i)
and I have to admit, that's fairly compelling. Might have to consider it. 
-->


```
; note the two different ways of specifing member type
(def-struct point
    (x float)
    (y:float))


;; make-XXXX
(make-point :x 3 :y 4)
;; type signature of make-point is #'(&key x:float y:float => point)
```

### member data rules

A struct can contain any type that has a fixed, known size at compile time.
This would include:
- Scalar types (`int`, `float`, etc)
- Small vector types (`float4` etc)
- Other structs
- Views to large data (`vector-view`, `tensor-view`, `matrix`)

But it excludes:
- `vector`
- `functions` and `kernels`

Note also that views can't be exchanged with the host directly. A struct that contains a view
cannot use the C interop for data exchange with host. Marshalling would be required.

### layout and alignment 

Crisp structs follow the `std140` layout rules used by the OpenGL and Vulkan graphic APIS.

https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html#interfaces-resources-layout


### type constraints: is-XXXX?

Using `def-struct` automatically generates `is-XXXX?` for that struct name, which can be used as a type constraint function
in `with-template-type`.  See the discussion of type constraints in `with-template-type` for more information.

### type names vs. type constructors
When a struct is defined with `def-struct`, its name becomes a new type name (e.g., `point`).

If a struct is defined within a `with-template-type` block, the system also generates a type constructor (e.g., `point-type`). This constructor must be used with its type arguments to create a concrete type, like `(point-type int)`.


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
(def-function align-y (p1 p2)
  (declare #'(point point => nil))
  (let ((horiz (y~ p1)))    ; get 'y from point p1
    (set! (y~ p2) horiz)))  ; set 'y of point p2 to that value


```

#### Non Overrideable Member Access: `~XXXX~`
Addiitonally, a non-overridable function to access members is also automatically generated. That function name is `~` followed by the member name, followed by `~` again.   This function can be used to get a value directly
from a struct bypassing any custom overload of the access, and can be passed to `set!` as well. 

These are mostly used by the overloaded member access functions, but are occasionally useful when dealing with
atomics or other places where diverting through a custom access function is not desired.

```
(let ((horiz-x (~x~ somePoint)))    ; get x from somePoint
   (set! (~x~ otherPoint) (+ horiz-x 10))  ; set x of otherPoint 
 ...)
```

#### overloading member access function
The access functions that are just one tilde followed by the member name can all be overloaded and thus
custom accessor functions can be provided. 
Simply define a function of the same name and the correct type.


In this example, this function flips a point over the vertical axis
by returning the negatiion of the x value.

```
(def-function x~ (p:point)
  (declare (return-type float))
  (- (~x~ p)))  ;; internally use the non-overrideable access function.

(let* ((p (make-point 5 0))
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
;; (x~ sv) returns the vector of ALL x values, we are adjusting the one at idx
(def-function x~ (sv:(soa-vector-type point) idx:ulong)
    (declare (return-type float))
    (- (~ (x~ sv) idx)))
```

The compiler will emit a warning if it encounters access on a soa-vector for a struct that has asymmetric property accessor overloads.

In the future, Crisp may handle this automatically. 

#### `with-struct-accessors`  - ADVANCED 

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



def-setter
----------

`def-setter` can be used to define an overloaded function to set any property.
It uses the same name of the property but takes an additional argument.  
The return type for all setting functions is always nil.  

If the setter parameters are typed, there is no need for an additonal declare.

```
;; this custom setter function negates x
(def-setter x~ (p:point newVal:float)
   (set! (~x~ p) (- newVal))) 

(set! (x~ somePoint) 14) ;; <-- the x of somePoint is actually stored as -14 
```

If overloading the setting of a struct property and you wish to use that struct
consistently and correctly in a `soa-vector`, then an additional overload
for that is recommended as well. The compiler will warn if it detects the absence.
In the future, Crisp may handle this automatically. 
```
;; additional overload if we are using soa-vectors.
(def-setter x~ (sv:(soa-vector-type point) idx:ulong newVal:float)
    (set! (~ (x~ sv) idx) newVal))
```



Template Types
--------------

`with-template-type` can wrap several `def-` declarations to template them. 


Doing so automatically generates two additional functions: `XXXX-type` and `gen-XXXX` 
where `XXXX` is the name of the function, struct, vector, etc that was defined.


```
(with-template-type (T)
  (def-function addTwo (a:T b:T)
      (declare (return-type T))
    (+ a b)))


(with-template-type (T U A)
    (declare (type-is U #'is-floating-point?) (value-is A #'is-address-space?))
  (def-function move-discrete (a:T b:U)
     (declare (return-type (vector-type U A)))
     ...))

; we can template structs as well
(with-template-type (T)
  (def-struct point (x:T) (y:T)))

```

It is possible to put a binding form (like `let`) between, so long as its bindings are evaluable
at compile time.  
Example:
```
(with-template-type (T &optional (M ""))
  (let ((make-reduce-l-s-v (gen-make-reduction-local-scratch-vec T M)))
    (def-function reduce-something (someFunction someThing &optional (localScratchVec (make-reduce-s-v)))
      ...)))
```


Note that automatic numeric type promotion does not occur during template argument deduction. All arguments passed to a templated function must match the expected type exactly, or an explicit conversion function (like `to-float`) must be used.




### XXXX-type

`with-template-type` AUTOMATICALLY defines a new type expression: XXXXX-type  for whatever it is wrapping.
That type expression can be used to specialize the template and return that specific type.
Example:
```
(with-template-type (T)
  (def-struct point (x:T) (y:T)))

(point-type int)  <== evaluates to the type, which is a point specialized to int.


;; I don't like this example as it's not really realizable.
(with-template-type (T U A)
    (declare (type-is U #'is-floating-point?) (value-is A #'is-address-space?))
  (def-function move-discrete (a:T b:U)
     (declare (return-type (vector-type U A)))
     ...))

(move-discrete-type int float :global) ; that specfic type. 
```

#### Incomplete Types

Passing `nil` as a type argument when specializing with `XXXX-type` produces an incomplete type. 
This can help make interoperation between different functions and structures more flexible.

```
(with-template-type (T U)
  (def-struct pair (first:T) (second:U)))

(def-type incomplete-p-t (pair-type nil (vector-view-type)))  ;; <-- a pair with a vector-view in the second type. Who cares what's in the first?

(def-function sum-length (a b)
  (declare (type a b incomplete-p-t) (return-type ulong)) 
  (+ (length~ (second~ a)  (length~ (second~ b)))))

```


### gen-XXXX

`with-template-type` ALSO AUTOMATICALLY defines an expression to get or construct a specialized form
of whatever it is wrapping.  This is `gen-XXXX` 

```
(with-template-type (T)
  (def-function addTwo (a:T b:T)
      (declare (return-type T))
    (+ a b)))

(fold someVector (gen-addTwo int)) ; <-- specialize "addTwo" for int and pass that to fold


; template over a struct
(with-template-type (T)
  (def-struct point (x:T y:T)))

(gen-point int)                         ; a. generate the template. 
(setf g-horizon (make-point :x a :y b)) ; b. now use it (assuming 'a' and 'b' are ints)

(map-stride #'make-point (vec-of-X vec-of-Y) vec-of-points)
```

In the case of templates, `gen-XXXX` is a special form or macro, not a function. 
It cannot be passed as an argument or referenced (ie  #'gen-addTwo is illegal)

As type inference is expanded, it may not be necessary to use `gen-XXXX` except in
limited cases. 

Note that `gen-XXXX` CANNOT instantiate an incomplete type. Passing `nil` as type arg is not allowed.

<!-- QUESTION: How DO incomplete types get made into complete types? Such that they could then be instantiated. -->

#### kernels

Crisp can template kernels as well. But any kernel that is templated MUST have 
specializations generated with `gen-XXXX` .  Furthermore, kernel functions must have 
unique names, so when applied to kernels `gen-XXXX` takes one additional last argument
which is a string name that the compiler should give the kernel. 

```
(with-template-type (T)
   (def-kernel happy_stance (data:(vector-type T :global :read-write)
     ...)))

(gen-happy_stance float "happy_stance_f")
(gen-happy_stance int  "happy_stance_i")
```


### &optional &key

The `with-template-type` argument list supports `&optional` and `&key` 

```
(with-template-type (T &optional C)
  (def-struct Point (x:T) (y:T)
    (when C '(color:C)) ; The color field is optional
  ))
```

### type constraints

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

#### `type-is` vs. `value-is`

The with-template-type form can be used to create generics that are parameterized by types (e.g., T which could be `int` or `float`) or by compile-time values (e.g., A which could be `:std140` or `:compact`). Crisp provides two corresponding constraint checks:

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


def-constraint
--------------

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

### type-has-prop?

`(type-has-prop? someType propName)`

evaluates to T/nil if something of someType has a member with that name, accessible
with `(<propName>~ obj)`
e.g.  `(type-has-prop? T 'length)` 


### has-overload?

`(has-overload? someF someSignature)`

evaluates to T/nil if a particular function has an overload of the provided signature.

e.g. `(has-overload? #'+ #(float float => float))`

### is-substitutable-for?

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




    



Vectors and Vector-View
------------------------

A `vector` is a contiguous array of uniformly typed data. 
Vectors cannot have their capacity resized. 
All vectors have their data allocated either by the host or the compiler, 
they cannot be dynamically allocated by the runtime. 

A `vector-view` is a vector that is a view into a parent `vector`. `vector-view` is a sub-type of `vector` and it can be
 used as an argument nearly every place a `vector` is usable.

### Alignment

Crisp supports two different alignment schemes for vectors: `:std140` and `:compact`.

`:std140` always aligns on the 16 byte boundary. The full description of this standard 
can be found here: https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html#interfaces-resources-layout

`:compact` alignment is contiguous with no gaps between data members. Compatible with `std::vector<T> .data()`

Note that while `:compact` is generally easier to interoperate, `:std140` is more performant on GPUs.

Also note that Crisp structs are ALWAYS `:std140`, putting them in a vector does not change that. 

### Properties

A `vector` has the following immutable properties:
| Property | Type    | Description |
| ---------|---------|-------------|
| length   | ulong   | the number of elements in the vector. This is immutable.|
| address-space | address-space | one of :global, :local, :constant |
| access   | access  | one of :read_only :write_only :read_write :readable :writeable |
| align    |         | one of :std140 or :compact |

A `vector-view` has these properties:
| Property | Type    | Description |
| ---------|---------|-------------|
| length   |  ulong  | the number of elements in the `vector-view`. It cannot be greater than `(length~ (parent~ vector-view))` |
| parent   | vector  | address of a "parent" vector |
| offset   | ulong   | offset into parent. |

Each of those properties can be accessed by the .<prop> function.
e.g. `(length~ someVector)` , `(parent~ someVectorView)`

These property functions can be overloaded.  They can also be retrieved with `~XXXX~` (which is not overloadable).

#### Settable Properties

None of the `vector` properties can be set, however, excepting `length`, the vector properties are compile time properties. 
The `length` property on a `vector` is sometimes a compile time property, but usually it's a runtime property. Regardless, it cannot be changed, .
But ALL the properties on a `vector-view` can be set, including `length`.

```
(set! (length~ someVectorView) 10)
(set! (parent~ someVectorView) someVector)   
(set! (offset~ someVectorView) 100)
```

Use `def-setter` to overload the property setting function.  `~XXXX~` can also be used to get / set the respective properties


Note that it is an error to set the `length` or `offset` of the `vector-view` such that it's `length + offset` is greater
than the `length` of the parent. But the checking and enforcement for these errors is NOT on by default.

### Element Access

- `~`
- `~ref~`

`~` is the main function for accessing elements in a vector. It can be `set!` and overloaded.
It would be supremely unwise to overload `~` generally. Instead use `def-derived-type` to 
define your own vector type and overload `~` for that type. 

```
(~ <vector> <index>) ;; to get 
(set! (~ <vector> <index>) <value>) ;; to set!
```

```
; example
(let* ((vec #(2 4 6 8))
       (elem (~ vec 1))) ;; 4
  (set! (~ vec 0) (* 2 elem))) ;; stores "8" into the first position of the vec.
```

 `~ref~` can also be used to get and set elements in a vector and these element
access functions cannot be overloaded.   `~ref~` is intended to be used from overloads of `~`

```
(~ref~ <vector> <index>)  
(set! (~ref~ <vector> <index>) <value>)
```


### Helpers 

`(element-type someVector)`  a type expression that returns the type of the elements in the `vector` or `vector-view`.

`(bytes someVector)`  a helper function that calculates the current number of bytes in the `vector` or `vector-view`.



### Member Data Rules

A `vector` can contain any type that has a fixed, known size at compile time.
This would include:
- Scalar types (`int`, `float`, etc)
- Small vector types (`float4` etc)
- Structs
- Views to large data (`vector-view`, `tensor-view`, `matrix`)

But it excludes:
- `vector`
- `functions` and `kernels`

Note also that views can't be exchanged with the host directly. A vector that contains a view
cannot use the C interop for data exchange with host. Marshalling would be required.


### Vector Types

Vectors are fully typed by 
- type of their element
- `address-space` (which is one of `:global` `:local` `:private` `:constant`)
- `access` (which is one of `:read-only` `:write-only` `:read-write` `:writable` `:readable`)
- `align` (one of `:std140` or `:compact`)

Further, constant vecs (see below) also need their `length` to be fully typed.


But none of those are necessary to specify a vector type in a parameter list.
Therefore, there are several vector type functions available in CRISP,
 and they fall on a gradient, from loose to specific.   Many of the type functions here
 return incomplete types, which make them flexible. But any operation that accesses the
 actual data of the vector will, at minimum, require the element type to be specified.

#### Simplest
`(vector-type)`
It's a `vector` or a `vector-view`.  

`(vector-type <element-type>)`
Example: `(vector-type float)`
This example simply specifies that the value or parameter is a `vector` or `vector-view` 
with a float element type. It does not specify any particular address space, access, or size.

`(vector-view-type)`
`(vector-base-type)`
These two allow the user to specify that a value is only a `vector-view` or NOT a `vector-view`.

#### Using Optional
`(vector-type <element-type> &optional address-space access align length)`
`(vector-view-type <element-type> &optional address-space access align length)`
`(vector-base-type <element-type> &optional address-space access align length)`

Example: `(vector-type float :global)` 
This example specifies a vector (or vector-view) of floats in the global address space. 
It does not specify access or size.

The first set of type functions is actually the same as these three. 
The `address-space`, `access` and `length` may appear in order.

#### Using Keys
`(vector-type &key element-type address-space access align length)`
`(vector-view-type &key element-type address-space access align length)`
`(vector-base-type &key element-type address-space access align length)`

Example: `(vector-type :access :writeable)`  This specifies that some vector is writeable. 
It could be of any type, address space or size.

Example: `(vector-view-type :element-type float :length 100)` This specifies that the 
vector is a `vector-view` of 100 floats. It could be any address space, access, or alignment.

Example: `(vector-type)`  This specifies merely that something is a `vector` or `vector-view`, but nothing else is known about it.



#### Element Type
The element type of a vector must be an element of a fixed size known at compile time.
It cannot be the type of a function. 
Nor can be a vector (but this functionality is available through the `vector-view`)

#### Access
The enumeration for access has five different choices in Crisp:
- `:read-only`
- `:write-only`
- `:read-write`
- `:readable` 
- `:writable`

But note that the last two are not available in the hoisting example code for loading and enqueueing the kernel

#### Usage

```
(def-function count (v)
    (declare (return-type ulong) (type v (vector-type long :global :read-only)))
 ...)

 ;; vectors (and vector views) can be compile-time fixed size
(vector-type float :local :read-write :std140 100)
```

### Vector Arguments for Kernels
`def-kernel` is the definition for the kernel function. Its parameter list does not support `vector-view`.
And any `vector` in its parameter list MUST have its element-type, address-space and access specified in
its type definition. Only the size can be unspecified.


```
(def-type data-from-host-t (vector-type float :constant :read-only :std140))
(def-type result-from-kernel-t (vector-type float :global :write-only :std140))
(def-kernel my_kernel (in:data-from-host-t out:result-from-kernel-t)
  ...)
```

### Creating Vectors

While the kernels cannot dynamically allocate vector memory, the kernel CAN
declare a vector on the stack at compile time.  This vector must have a known-at-compile-time length.
And it can also create a `vector-view` with a size determined at runtime. 


- `(make-vector vectorType)` will instantiate a vector of a set type. The type argument MUST include the length.
- `(make-vector vectorType length)` length can be provided explicitly if the type doesn't specify it.
- `(make-vector &key element-type address-space access align length)`
- `(make-vector-view parent length &optional offset)` 

And `#( val1, val2, ... valN)` instantiates a `vector` directly.  But note that vectors
created this way do not have information about address space or access and
possibly element type might be ambiguous as well. So these will typically 
need an accompanying `declare` or similar to determine.

<!-- NOTE  probably any vector directly instantiated with #(1 2 3) is
     constant and immutable and allocated in constant/private memory address space
     So we should say so.  
     Or do we want to support mutability if the user want to declare
     :global or :local ?
     -->

```
(def-type vec-floats-t (vector-type float :local :read-write :std140))
(def-type vec-ints-t (vector-type int :local :read-write :std140))

(def-kernel do_things ()
  (let* ((some-ints #(1 2 3 4 5)) ;; <-- compiler will attempt to infer type, but best to declare it.
         (hundred-floats (make-vector vec-floats-t 100))
         (ten-floats (make-vector-view hundred-floats 10)))
    (declare (type some-ints vec-ints-t))
    ...))

```

Note that `make-vector-view` CAN take another `vector-view` as the parent argument. But
there is no nesting. Instead the resulting view will have the original `vector` as a parent, 
not the `vector-view` argument.  Similarly, expect that is `offset` property will be the 
net offset.

#### reinterpret-view
```
(reinterpret-view source-vec new-type-symbol &key length offset))
```

`reinterpret-view` is a macro that takes a `vector` or `vector-view` argument and type (`float`, `int` etc)
and returns a `vector-view`. If the optional `:length` key isn't used, then the length of the new `vector-view` will be calculated automatically.  The returned `vector-view` inherits the address-space, access permissions, and layout (`:compact` or `:std140`) from the source-vec. Only the element-type and length are changed.
This is a casting operation and it is the callers responsibility to make sure the whole
`vector-view` is funded with data. Give care when using the `:length` and `:offset` keys and if casting from a smaller 
type to a larger one make sure there is enough source data even without using those keys.

There are some restrictions though. They are enforced at compile time:

- the source element type cannot be a struct type
- the new type also cannot be a struct type
- if the underlying source `vector` has `:std140` layout, then reinterpretation between
  types requires that both have the same base alignment requirement under `std140`. 

`:compact` layout is generally more amenable to reinterpretation.

#### address space concerns for kernel instantiated vectors

Inside `def-kernel` or `def-function` the only address spaces that can be used when 
instantiating a `vector` are `:local` and `:global`. But `:global` is SLOW and should
NOT be used unless you have good reason.

`:constant` address space is the most performant, but to set up a vector with that
you'll need to use `def-const-vec` which is covered below, or a direct instance ( `#(1 2 3)`).


soa-vector and soa-view
-----------------------

`soa-vector` is a special type of vector, with a special memory layout. They are used for vectors of structs (only).

`soa-vector` are templated over `S` where `S` is some struct type. But rather than a contiguous block of 
memmory consisting of repeating structs, `soa-vector`s are "Structs of Arrays". 

For example, using our `point` type from before, `(vector-type :element-type point :length 4)` would layout in memory
like this:
`|x0|y0|x1|y1|x2|y2|x3|y3|`.
Or in C++ we can think of it like this:
```
struct Point { float x, y; };
Point points[4];
```


But a `(soa-vector :element-type point :lenth 4)` lays out like this:
`|x0|x1|x2|x3|y0|y1|y2|y3|`.
In C++ with can think of it like this:
```
struct Points {
    float x[4];
    float y[4];
};
```

A `soa-view` is a `soa-vector` that is a view into a parent `soa-vector`.  It subtypes `soa-vector` like
`vector-view` does `vector`.

### Alignment

Crisp supports two alignments schemes for `soa-vector`: `:std140` and `:compact`.  Note that these
alignments are applied to the inner vectors.  The outer `struct` is always `:std140`.

### Base Properties

A `soa-vector` has the following immutable properties:

| Property     | Type         | Description      |
|--------------|--------------|------------------|
| length       | ulong        | the number of elements in the `soa-vector`. This is immutable. |
| address-space|address-space | one of `:global`, `:local`, `:constant`   |
| access       | access       | `:read_only`, `:write_only`, `:read_write`, `:readable` , `:writeable` |
| align        | align        | one of `:std140` or `:compact` |

A `soa-view` has these properties:

| Property     | Type         | Description      |
|--------------|--------------|------------------|
| length       | ulong        | the number of elements in the `soa-view`. It cannot be greater than `(length~ (parent~ soa-view))` |
| parent       | soa-view     | address of "parent" soa-view |
| offset       | ulong        | offset into parent. |

### Struct Properties

Additionally,  `soa-vector` and `soa-view` also inherit the properties of their struct element type. 


Example
```
(def-struct point (x:long) (y:long))

(let* ((sv      (make-soa-vector point :local :read_write :std140 20))
       (y       (y~ sv 9))
       (x-vec   (x~ sv)))
    ...)
```

#### `XXXX~` with index.

In the example above, `y` is gotten via `(y~ sv 9)` which means it is the value of the y vector at index 9.

Owning to memory coalesence, when the index is a thread id from parallel threads,  this will be very high-performance access. 

#### `XXXX~` without index

Whereas constrastingly, in the example above `(x~ sv)` returns the ENTIRE VECTOR of X from the `soa-vector`.
 `x-vec` would be `(vector-type :element-type long :length 20)`.  <!-- or should it be a vector-view-type ? -->

Its primary purpose is to pass a single, contiguous stream of data to another high-performance primitive, like `reduce-vec`

### Element Access

The struct properties (see above) with index arguments are the primary way of accessing `soa-vector` data.
If you want a particular struct as singular construct, it can be gotten with `get-struct`.  Note that this requires
creation of a new structure to hold the value.
`(let ((some-point (get-struct sv 3))))`   

`soa-vector` and `soa-view` do NOT support the `~` or `~ref~` element access functions like regular `vector` and `vector-view`.

### Helper Functions

Like `vector`, `soa-vector` and `soa-view` support `element-type` and `bytes` helpers.
`(bytes my-soa-vec)` returns the total memory footprint, which is the sum of the sizes of all its component arrays, including any padding.

### Member Data Rules

`soa-vector` are ONLY defined over structs (see `def-struct` above). And any candidate struct type can only consist of either
 - Scalar types (`int`, `float`, etc)
 - Small vector types ( `float4` etc)

 Unlike regular structs, they cannot include other structs or views.
 This rule is in place to prevent overly complex nested SoA layouts and to ensure a simple, predictable memory model that maps efficiently to the hardware.

 ### Defining 
 
 ```
 (soa-vector-type <element-type> &optional address-space access align length)
 (soa-view-type <element-type> &optional address-space access align length)

 (soa-vector-type &key element-type address-space access align length)
 (soa-view-type &key element-type address-space access align length)
 ```

 ### Creating

 `soa-vector` have parallel creation routines to `vector` and abide by the same requirements (ie length must be known at compile time).

 - `(make-soa-vector soaVectorType)`
 - `(make-soa-vector soaVectorType length)`
 - `(make-soa-vector &key element-type address-space access align length)`
 - `(make-soa-view parent length &optional offset)`


 ### Reinterpreting

`soa-vector` and `soa-view` do not support any sort of reinterpret cast. But their underlying vectors
do.  
```
  (let ((vector-view-of-ints (reinterpret-view (x~ point-soa-vec) 'int))) ...)
```

### Converting between SoA and AoS vectors.

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
    (def-function convert-soa-to-aos (input-soa-vector output-vector)
        (declare #((soa-vector-type T) (vector T) => nil))
        (loop-soa-stride input-soa-vector (i)
            (let ((temp-struct:T (get-struct input-soa-vector i)))
                (set! (~ output-vector i) temp-struct)))))

(defmacro convert-aos-to-soa (input-vector output-soa-vector)
    (c-t-assert (type-equal (element-type input-vector) (element-type output-soa-vector)))
    (let* ((T (element-type input-vector))
           (set-forms (with-struct-accessors T (aos-accF soa-accF)
                       ;; body generates one form for each member
                       ;; "i" and "temp-struct" TBD below.
                       `(set! (,soa-accF ,output-soa-vector i (,aos-accF temp-struct))))))
        `(def-function convert-aos-to-soa (input-vector output-soa-vector)
            (declare #((vector-type ,T) (soa-vector-type ,T)))
            (loop-vector-stride ,input-vector (i)
                (let ((temp-struct (~ ,input-vector i)))
                    ;; expand the forms we gathered
                    ,@set-forms)))))
```



 ### C++ / Python interop

 The hoisting code that the compiler generates includes helper functions that give the same property-to-vector and property-index-to-element 
 access that Crisp enjoys, making it easy to initialize or inspect data and interoperate with Crisp kernels.




def-const
---------

`def-const` is used to define an immutable expression in global file scope that the compiler will inject in place whereever it encounters it. The Lisp practice is that `def-const` expressions have a `+` sign on either side.

In CRISP `def-const` can only be used for scalar values. It cannot be used for constant vectors (see `def-const-vec` in the next section). 
Due to inference, `def-const` expressions do not typically need type information declared, it is optional.

```
(def-const +PI+ 3.141592654)       ; type will be inferred
;OR
(def-const +PI+:float 3.141592654) ; type is explicit
;OR
(def-const +PI+ 3.141592654)
(declare (type +PI+ float))        ; type is explicit

(def-function circle-area (r)
   (declare #'(float => float))
  (* r r +PI+))
```

def-parameter
-------------

`def-parameter` is used to define the type and possible default value for parameters that might 
come in from the compiler when it is invoked.   `def-parameter` is very similar to `def-const` in
that it also defines an immutable expression in global file scope.
`(def-parameter <parameter-name>:<type> &optional <default-value>)`

Like in C++, the `-D` flag is used to specify a parameter and is followed by the parameter name, equal sign and a value without spaces.
e.g. `-DMAX_INDEX=40` 

Paramter names should follow the C standard identifying rules. (ie use underscores, not dashes)

**NOTE:** Parameter names, like kernel names, are _case sensitive_, unlike other names in Crisp.


```
;; in the .crisp file
(def-parameter MAX_INDEX:ulong 100) ;; 100 is default value, used when not provided by the compiler invocation.

(def-parameter START_LOC 41.1)
(declare (type START_LOC float))
...
(dotimes (x MAX_INDEX) ...)


# the compiler invocation
crisp.exe -DMAX_INDEX=35  my_kernels.crisp
```

<!-- NOTE: def-const supports type inference, should def-parameter.  Why not?
    
    NOTE: what about + on both sides?  Plus sign can be interpreted differently by shells, so best to avoid it 
          appearing on any command line.  We could auto add it?  (def-parameter +X+ ..)  / crisp -DX=4
          Meh, seems brittle and weird. 
-->



def-const-vec
-------------

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

### Declare Use In Kernels
If anything wants to read from that vec during the execution of some kernel,
that kernel needs to add a `(use <const-vec-name>)` to its `declare` directive. 
Then it, or functions it calls, can simply refer to the const-vec, like one would a global variable.  

### Constant Vec Using Other Constant Vec

When preparing masks, sometimes the construction of one mask depends on another. So long
as all this is predeterminable at compile time, CRISP can support it.

The `(declare (use +xxx+))` declaration can be put inside a `def-const-vec` to allow it to 
refer to an earlier `def-const-vec` .  The requirement is that the named const vec in the `use`
clause MUST have been defined earlier in the translation unit. 

### Type Function
CRISP also has a type function for :constant :read-only vectors returned by `const-vec-type`
`(const-vec-type <element-type> &optional length)`


```
(def-type image-mask-t (const-vec-type uchar))
(def-const-vec +image-mask-32+ 
  (let ((image-mask-vec (make-vector image-mask-t 32)))
    (dotimes (x 32)
      (set! (~ image-mask-vec x) x))
    (return image-mask-vec)))

(def-const-vec +image-mask-8+
  (declare (use +image-mask-32+))
  (let* ((small-image-mask-vec (make-vector image-mask-t 8))
         (small-view  (make-vector-view small-image-mask-vec 2))
         (big-view    (make-vector-view +image-mask-32+ 2)))
    (dotimes (x 4)
      (copy-vec :from big-view :to small-view)
      (inc! (offset~ small-view) 2)
      (inc! (offset~ big-view) 8))
    (return small-image-mask-vec)))

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

Side Channel Vectors
--------------------

As was mentioned earlier, Crisp supports side channel vectors, which are special purpose vectors that
can be created in the operation of your kernel. This lets you "pretend" that the kernel is allocating 
memory, when it is actually just specifying a need for memory for some purpose and that need is expressed
to the host in the example hoisting code or metadata that the compiler outputs.

The different declarations each operate similarly. Each one results in an additional implicit argument being added to the kernel (or an additional matching "marshall" declaration appearing in a `def-kernel-exact`), plus an additionl set
of arguments (pointer and size) output into the hoisting code, complete with a recommended expression for calculating 
the correct allocation size.  

Each invocation must be countable by the compiler. This means they cannot appear in loops. 

The invocations take a `<VectorExpression>` as a first argument. That can be a type expression OR just some
vector value. The "new" vector will have the same type as the source, except that its `:access` may be changed to `:writeable` of the original vector was only `:readable` or `:read_only`.   If an existing vector value is
used, then the size will be set to be the same. This can be very handy, because if that value originates as 
a kernel argument, then the example hoisting code will specify that the size should match. 

The size of any invocation MUST be specified. It does not have to be a compile-time constant, merely specified. 
This is most relevant when using `vector-type` and friends, because that type expression often elides length.

The invocations also support `:name` and `:comment` keys. If using `def-kernel-exact` then `:name` is REQUIRED, 
as it will need to match a marshalling invocation.  The `:comment` key will output a comment into the hoisting code (Neat!).

Lastly, note that `<VectorExpression>` can include `soa-vector` vector type specifiers.


### make-result-vector

`(make-result-vector <VectorExpression> &optional length &key name comment)`

Each invocation of `make-result-vector` means an additional entry will be hoisted. Thus kernels can return 
multiple values. 

In the example below, this function, if called by a kernel, would cause two additional float array pointer to 
be hoisted, plus a pointer to a unsigned long array.  The first one would be the same length as the `A` vector argument to this function. 
The second one's length would be the multiple of the other arguments.  Both the first and the second result
would have their access set as `:writeable` despite the original `A` vectors `:read_only` access.
The third result would be hoisted as a `ulong` array ptr. 


```
(def-type float-vec (vector-type float :global :read_only :std140))
(def-type ulong-vec (vector-type ulong :global :writeable :std140))
(def-function calc-final-result (A x y)
  (declare #(float-vec ulong unlong => nil))
  (let ((result-1 (make-result-vector A :comment "Gamma Squad needs this result"))
        (result-2 (make-result-vector A (* x y)))
        (result-3 (make-result-vector ulong-vec (* x x) :name "haversine")))
      ...))
```

### make-scratch-vector
`(make-scratch-vector <VectorExpression> &optional length &key name comment)`

Unlike the others, each invocation of `make-scratch-vector` doesn't result in a new kernel arg that needs to be
enqueueed. Instead, the size expressions are gathered up and communicated back to the hoisting code and just
one scratch vector is allocated. 

Below is  a simple example
```
(def-kernel calc_something (A Res)
  (declare #(float-vec ulong-vec => nil))
  (let ((intermediate (make-scratch-vector A (/ (length~ A) 2) :comment "half of size of A parameter"))
        (otherIntermed (make-scratch-vector ulong-vec (* (get-global-linear-size) 1.5) :comment "we need half again as many launched threads")))
     ...))
```

And this is an excerpt of the hoisting code that might be generated.  
```
 unsigned long ScratchPtrLen =   ; //      (/ (length~ A) 2)    half of size of A parameter 
                                   // PLUS (* (get-global-linear-size) 1.5)    we need half again as many launched threads
 clSetKernelArg(calcSomethingKernel, 1, sizeof(void*), APtr);
 clSetKernelArg(calcSomethingKernel, 2, sizeof(unsigned long), &APtrLen);
 clSetKernelArg(calcSomethingKernel, 3, sizeof(void*), ResPtr);
 clSetKernelArg(calcSomethingKernel, 4, sizeof(unsigned long), &ResPtrLen);
 clSetKernelArg(calcSomethingKernel, 5, sizeof(void*), ScratchPtr);
 clSetKernelArg(calcSomethingKernel, 6, sizeof(unsigned long), &ScratchPtrLen);
 clEnqueeuNDRangeKernel( someCommandQueue, calcSomethingKernel,         
                          ...);
```

### make-implicit-vector

`(make-implicit-vector <VectorExpression> &optional length &key name comment)`
This works much the same as `make-result-vector` but has no specific purpose. 




Tensors
-------

In Crisp a `vector` is always a one dimensional contiguous blocks of memory. 
The `vector-view` is slice of a larger parent vector, but the `vector-view` remains 
contiguous and one dimensional.  
Tensors are represented by the `tensor-view` which is similar to a `vector-view` except 
that it has adjustable strides.

Tensors can have their exact size determined at runtime, but the number of their dimensions (eg. 2D matrix versus 4D hypercube )
must be known at compile time.

### tensor-view-type

Tensors are typed completely by dimensions and the complete vector-type of a parent. 
Tensors are incompletely typed if the parent vector-type is incomplete, or absent.

```
(tensor-view-type) 
(tensor-view-type NumDims)
(tensor-view-type NumDims parentVectorType)
; (tensor-view-type &key :dims :parent)  ; <-- NOTE: we don't have comparable parent key for vector-view ? Maybe define there? Or remove this?

(num-dims-of someTensorViewType)
```

`num-dims-of` is a compile-time expression that returns the dimensions used to define the `tensor-view-type` .
 It triggers a compile-time error if the `tensor-view-type` doesn't contain that (it does NOT return nil).

 In Crisp, a 1D `tensor-view` can be used nearly anywhere a `vector-view` can be used (which is nearly anywhere a `vector` can be used.)

### Creating Tensors

There are four routines for creating `tensor-view`s. Two for `tensor-view` of any dimension,
and two for creating matrices, which are 2D `tensor-views`. 
```
(make-tensor-view parent len ... lenN  &key (offset 0))
(make-tensor-view strideVec parentVec len ... lenN &key (offset 0))

(make-matrix parent len0 len1 &key (major :row) (offset 0))
(make-matrix parent strideVec len0 len1 &key (offset 0))
```
For the 2D `matrix`, one of the declarations supports a `:major` key which can be `:row` or `:col`.
Alternately, the `strideVec` can set the strides. Setting the strides directly is how to get "row major" vs "col major" (versus "plane major" etc) tensor-view in higher dimensions. 


In the example below, let's look at a 3x4 matrix `A`, with elements labeled 
`A[row][column]` (C++ notation) or `(~ A row column)` (Crisp notation)

<details>
<summary>C++ notation</summary>
<pre>
```
         Col 0    Col 1    Col 2    Col 3
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
        Col 0      Col 1      Col 2      Col 3
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
(make-tensor-view #(4 1) my-data-vec 3 4)

;; Create a column-major view of a 3x4 matrix
(make-tensor-view #(1 3) my-data-vec 3 4)
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


### Properties


A `tensor-view` has these runtime properties:
| Name     | Type        | Description |
|----------|-------------|-------------|
| length   | ulong       | the number of elements in the `tensor-view`. It cannot be greater than `(length~ (parent~ vector-view))` |
| parent   | vector      | address of a "parent" vector |
| offset   | ulong       | offset into parent. |
| num-dims | ulong       | number of dimensions of the tensor-view.  This is an immutable compile time property of the tensor-view |
| strides  | stride-type |  `vector` the length of the `num-dims` that tracks the count to the "next" element in that dimension |
| dims     | dims-type   | `vector` the lenght of `num-dims` that tracks the extant of that particular dimension

Each of those properties can be accessed by the .<prop> function.
e.g. `(length~ someTensorView)` , `(parent~ someTensorView)`


### Element Access.  Use `~` 
As in vectors `~` is the primary access function for getting and setting elements of a `tensor-view`.
It is also the safe and correct access function because it correctly navigates to the underlying data
using strides. 

Like C++ and Python (but unlike Fortran), Crisp uses "odometer" ordering of terms.
And the order of these terms are unaffected by the strides or whether "row major" or "col major" was elected
for the internal layout.

```
(~ some-3D-tensor z y x)
```

The `~ref~` function is NOT supported for tensors. Also, it is very likely that if more abstract 
tensors are supported in the future (symmetrical, sparse, etc)
that they may have completely different affordances for access. 


### Overloading Element Access

It is uwise to overload `~` for all tensors. Use `def-derived-type` when overloading.

```
;; source vector is floats ranged 0-1
(def-derived-type normalized-tv (tensor-view 1 (vector-view-type :element-type float)))

;; we return int values between 0-100
(def-function ~ (tensor index)
  (declare #(normalized-tv ulong => int))
  (round (* (~ tensor index) 100)))

;; and store those ints back to floats
(def-setter ~ (tensor index val)
  (declare #(normalized-tv ulong int => nil))
  (set! (~ tensor index) (/ val 100.0)))

```


### Mutable Strides ?

The strides are mutable. Normally this is done (safely and correctly) by functions like `transpose` but 
despite the horrible problems that might occur if done incorrect, we are making it available to you.

```
(set! (strides~ someTensorView) someOtherVec) ; will error if (length~ someOtherVec) is not equal to (num-dims someTensorView)
(set! (~ (strides~ someTensorView) 1) 8)
```

<!-- NOTE: I understand that the strides, will ultimately need to be mutable.  But OMG it seems like a bad idea 

  NOTE: does the user need to know HOW the strides will be created by Crisp? For example for a 10x10 tensor
       the stride could be #(0 10) or #(10 0).  
  That also maps to row major/col major. So it seems like that should be expressed somehow.
-->

### Helpers 

`(element-type someTensor)`  a type expression that returns the type of the elements in the `tensor-view`.

`(bytes someTensor)`  a helper function that calculates the current number of bytes in the `tensor-view`.

### identity-tensor

This is a specialization of the tensor-view, but is not a true tensor in that does NOT require
any vector data.  It is immutable. It is a Kronecker delta tensor. Every component is 0, except those
where all the indeces are equal, which are 1.

```
(identity-tensor-type &optional rank)
(make-identity-tensor rank)
(is-identity-tensor? someTensorView) ;; can be called on any tensor-view
```

Matrices
--------

`(def-type matrix (tensor-view 2))`

Matrices are simply 2D tensor views. The type alias `matrix` is defined to make coding easier, but any 2D `tensor-view` can automatically be considered a matrix. It is not a "derived" type.

In [Creating Tensors](#creating-tensors) above, two routines for creating matrices are discussed:
```
(make-matrix parent len0 len1 &key (major :row) (offset 0))
(make-matrix parent strideVec len0 len1 &key (offset 0))
```

Additionally, there are special functions specifically for matrices.

### col

`(col x:ulong A:matrix) => 1D tensor-view`

Given an index `x` and a 2D `tensor-view` matrix `A`   this returns a 1D `tensor-view` of that column of the matrix.

### row

`(row y:ulong A:matrix) => 1D tensor-view` 

Given an index `y` and a 2D `tensor-view` matrix `A`   this returns a 1D `tensor-view` of that row of the matrix.

### num-cols / num-rows

`(num-cols A:matrix) => ulong`
`(num-rows A:matrix) => ulong`

These utility functions return the number of columns or rows of the matrix.

### get-layout
```
`(get-layout M:matrix) => :row-major or :col-major or :other-layout
```

`get-layout` analyses the strides of some 2D matrix and returns a value from the
`matrix-layout` enumeration. This can be `:row-major`, `:col-major` or `:other-layout`

### transpose

```
(transpose M) ; returns a new tensor-view, leaving M alone.
(transpose! M) ; M is transposed, strides updated in place
```

The `transpose` operations swap the logical "shape" of the matrix. For example, starting with a 3x4 matrix
and ending with a 4x3 matrix. This is done simply by updating the strides. It is instant and zero cost.

Note that the while data is not moved it does mean that a "row major" matrix will now be "col major", and vice versa.

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
(def-function transpose! (M:matrix)
  (declare #((matrix) => nil))

  (let* ((dims-vec (dims~ M))
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

### load-tile / store-tile

```
(load-tile source-M dest-tile tile-y tile-x &key transpose)
(store-tile source-tile dest-M tile-y tile-x &key transpose)
```
When working with matrices, we often want coalesced memory access, but that is limited
to the `:row-major` / `:col-major` choice.  For this reason, a very common
usage pattern when working with matrices is to use local memory tiles.
These are typically `32x32` (ie `+warp-size+` squared ).

The `load-tile` and `store-tile` macros can help with that. They presume the kernel
has been enqueued with 2D arity and just use the local-id x and y for the target IN the tile.  

The tile will simply lift the data right out of the source-M, whether it is
`:col-major` or `:row-major`, and so have the same layout, just smaller.  

But the `:transpose` argument can be used to change that. If `true` then
the `x` and `y` coordinates will be swapped. 

Remember dest-tile should be `:local` memory.

Here are possible implementations
```
(defmacro load-tile (source-M dest-tile tile-y tile-x &key transpose)
  `(let ((tile-dim (num-cols ,dest-tile))
         (local-id-x (get-local-id 0))
         (local-id-y (get-local-id 1)))

     ;; Calculate Source Coords for a COALESCED READ 
     ;; This pattern is always the same: threads in a warp read adjacent columns.
     (let ((source-x (+ (* ,tile-x tile-dim) local-id-x))
           (source-y (+ (* ,tile-y tile-dim) local-id-y)))

       ;; Read from Global Memory
       (when (and (< source-y (num-rows ,source-M)) (< source-x (num-cols ,source-M)))
         (let ((val (~ ,source-M source-y source-x)))

           ;; Write to Local Memory (Transposed or Direct)
           (if ,transpose
               ;; If transposing, write to the swapped local coordinates.
               (set! (~ ,dest-tile local-id-x local-id-y) val)
               ;; Otherwise, do a direct copy.
               (set! (~ ,dest-tile local-id-y local-id-x) val)))))))
```



### convert-layout

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

(def-const TILE_DIM:ulong +warp-size+)

(def-function convert-layout (source-M dest-M choice &optional (scratch (make-tile-scratch (element-type source-M))))
  ;; scratch is 32x32 (+warp-size+ x +warp-size+)
  (declare #(matrix matrix matrix-layout &optional (vector-type (element-type source-M)) => nil))
  (c-t-assert (!= choice :other-layout) "dude")
  (r-t-assert-0 (!= choice :other-layout) "??")

  (unless (= (get-layout source-M) choice)
    (let ((temp-tile (make-matrix scratch TILE_DIM (+ TILE_DIM 1)))) ; Padded tile sometimes increases performance

      ;; This loop makes each workgroup process multiple tiles.
      (loop-tile-stride M TILE_DIM (tile-idx-y tile-idx-x) 

        ;; load tile  - coalesced read
        (load-tile M temp-tile tile-idx-y tile-idx-x :transpose (= (get-layout M) :col-major))
        
        (local-barrier)

        ;; store transposed tile coalesced write
        (store-tile temp-tile dest-M tile-idx-y tile-idx-x :transpose (= (get-layout dest-M) :row-major))))))
```



Type Aliases and Type Constructors
----------------------------------

The type names for vectors and functions,  etc. can be rather long and ungainly. 
 `def-type` is provided to help shorten these and make them more usable.  

In it's simplest application, it just provides type aliasing.

```
(def-type T int)  ;
(def-type addTwoT  (type-signature-of #'addTwo))
(def-type addThreeT #'(long long long => long))
(def-type floatVecT (vector-type float :global))
```

A **Type Constructor** is a function that takes a type as an argument and returns a new, specialized type. In Crisp, you create these using the `with-template-type` form, which provides a clean and powerful way to define generic types. When you use `with-template-type` to define a new type (like a struct or a vector alias), the compiler automatically generates a corresponding `XXXX-type` function, which is your type constructor. You can then use this function to create concrete types, such as `(anotherGlobalVecT-type int)` which represents a global vector of integers, which can be used in your function declarations. This approach separates the definition of the generic type from its specific instantiation, making your code more readable and reusable.

```
(with-template-type (T)
   (def-type anotherGlobalVecT (vector-type T :global)))

(def-function count-ints (v)
    (declare #'((anotherGlobalVecT-type int) => ulong))
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


Derived Types
-------------

`def-derived-type` ,  `make-XXXX`, `as-XXXX`, `is-XXXX?`

`def-derived-type` defines a NEW type derived from a stated type. The purpose for this
is to allow custom overload of functions and properties.

Additionally, with `set-derived` the compiler can be instructed to create a type hierarchy
between two types. 

### def-derived-type

```
(def-enumeration derived-subst :no :equal :pass-orig :pass-derived)

(def-derived-type <new-name> <type-expr> &key (subst :no))
```
The `type-expr` is any type that supports a `make-` function (`vector`, `vector-view`, `soa-vector`, `soa-view`, `tensor-view` and things created from `def-struct` )  
<!-- what about numeric types? bool, or nil ?  Definitely NOT functions or kernels, right?-->


The `subst` key should be from the `derived-subst` enumeration
| key           | Description            |
|---------------|------------------------|
| :no           |   A value of the derived type cannot be passeed as an argument to a function that expects the original type. Nor can a value of the original type be passed to a function that expects the derived type.|
| :equal        |   Values of either type can pass for each other.        |
| :pass-orig    |   A value of the derived type can be passed as an argument to a function that expects the original type. But the reverse it not true.  In languages like C++ or Java, this behavior is as if the derived type were a subclass of the original type. |
| :pass-derived | A value of the original type can be passed as an argument to a function that expects the derived type. But the reverse is not true - compilation error. If thinking like C++, this is like making the derived type act as the parent, as a super class (something C++ can't do). |


It's very important to remember that no matter what the substitution behavior is set to, that Crisp will choose the closest
overloaded function (and emit a compilation error if that cannot be clearly determined).
So even if using `:equal`, if function `foo` takes a single argument and is overloaded for types `A` and  `B` ,  `foo #'(A=>...)` will 
NEVER be called with a value of type `B`  unless `as-A ` were used.

`def-derived-type` is one of the `def-` constructs that CANNOT be wrapped by `with-template-type`. 


### Example

```
;; def-struct makes a new type 'point'
;; and we make a 'distance' function that takes points.
(def-struct point
    (x float)
    (y:float))

(def-function distance (a:point b:point)
    (declare (return-type float))
    #| pythagorean formula here |#  )


;; a coordinate derived type is declared with 
;; a custom distance formula for it.
(def-derived-type coordinate point :subst :no)

(def-function distance (a:coordinate b:coordinate)
  (declare (return-type float))
  #| haversine formula here |# )

(let ((p1 (make-point 1 2))
      (p2  (make-point 3 4 ))
      (c1 (make-coordinate 1 2))
      (c2 (make-coordinate 3 4)))

  (distance p1 p2)  ; <-- evaluates to pythagorean distance between p1 and p2
  (distance c1 c2)  ; <-- evaluates to haversine distance between c1 and c2
  (distance p1 c2)) ; <-- compilation error. because :subst is :no 
                    
```

In the example above if `:subst` were `:equal` it would also error, 
because the compiler wouldn't be able to successfully resolve which 
distance overload was desired.

In the example above, if `:subst` were instead set to `:pass-orig` then
`(distance p1 c2)` would accept `c2` as a `point` and would return the 
pythagorean distance.

Or, if `:subst` were instead set to `:pass-derived` then
`(distance p1 c2)` would accept `p1` as a `coordinate` and return 
the haversine distance. 

Crisp employs "multiple dispatch" for overloaded functions, determined at compile
time. It does not support runtime dynamic dispatch of any sort.

### make-XXXX

The `make-<derived-type-name>` is automatically generated  and accepts the same arguments
as the original type. 

### as-XXXX

When a derived type is declared, then two type casting functions are automatically created.
 `as-<original>` which can be used to cast an value of the derived type as if it is the original, and
 `as-<dervied>` which can be used to cast an original as the derived.

 ```
 ;; continuing the example above, with two distance overloads and points p1, p2 and coordinates c1, c2

 (distance (as-coordinate p1) (as-coordinate p2)) ; would return the haversine distance. Even if :subst was set to :no

 (distance (as-point c1) (as-point c2)) ; retuns pythagorean distance. 
 ```

### is-XXXX?
 
When a derived type is defined, a matching type constraint function is also automatically defined.
`is-<derived>?` evaluates to true if the type in question matches the new derived type.  
 
Note that this does NOT accept substitutions, regardless of `:subst`.  Use `is-substitutable-for?` for that.

```
(def-struct point ...) 
(def-derived-type coordinate point :subst :pass-derived)

(is-point? point) => True
(is-point? coordinate) => False
(is-coordinate? point) => False
(is-coordinate? coordinate) => True.
```



### set-derived

`(set-derived original-type derived-type &key subst)`

If you have two existing types you can simply state that one derives from the other 
with `set-derived`.  Using `set-derived` will generate the two `as-XXXX` type casting
functions, just like `def-derived` does.  But no new `make-XXXX` function is defined.

As `set-derived` is inherently unsafe, the compiler enforces certain sizing rules, 
depending on the value of `subst`.  

`d-sz` is the derived size
`o-sz` is the original size

| `subst`       | rule                |
|---------------|---------------------|
| :no           | (no rule)           |
| :equal        | `d-sz` == `o-sz`    |  
| :pass-orig    | `o-sz` <= `d-sz`    |
| :pass-derived | `d-sz` <= `o-sz`    |

#### extending views

If you want to extend a type like `vector-view` with your own type that has extra data members,
you can use `def-struct` in conjunction with `set-derived` for this.
Example:
```
(def-struct MY-VIEW 
    (base:tensor-view)
    (new-prop:int))

(set-derived tensor-view-type MY-VIEW-type :subst :pass-orig)
```

#### std140

All Crisp structs are aligned with the `std140` layout and alignment practice. 
Keep this in mind when using `set-derived` and type casting, as things
might not work like you'd expect in a language like C. 


No Lambda Functions 
-------------------
Because the GPU has only one callstack per warp (not one per thread), lambda functions are 
not supported. This is because they enable lexical closures (capturing variables from their surrounding scope),
 which would add significant complexity to the kernel's memory model and is 
 difficult to map efficiently to GPU hardware.  
The Common Lisp `labels` macro is similarly not supported for this same reason.


Continuation Kernels
--------------------

A common practice in GPU kernel coding is begin with with one kernel, that perhaps uses a certain
distribution of local and global work sizes, and then to complete that calculation with second kernel, 
that is typically enqueued with a set of local and global work sizes tailored to it. 

This occurs because there is no way to marshall which workgroups execute in which order, and there are
no "global barriers" with which to enforce it. Atomics can be used as ersatz barriers, but overuse often leads to unused GPU capacity and stalled threads. The "last man standing" strategy (see `when-is-last-workgroup`)
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

### `let-kernel`

`let-kernel` is a binding special form similar to `labels` in Common Lisp. It defines a new kernel
function.  You can invoke that kernel in the "last place" of some other kernel.  No operations should
be performed AFTER a continuation kernel is invoked. The compiler will warn you if you do.

`let-kernel` can be used anywhere a `let` binding could, but its primary and safest use is for 
defining a continuation kernel inside a `def-kernel`.  To ensure a clear execution model, the 
compiler requires that the declarative invocation of the continuation kernel must be the **final expression**
in its scope.  A warning will be issued if any code follows this invocation. 

The invocation of a continuation kernel is merely for show. In reality it is compiled away to NOP.  
But the hoisting code that the Crisp generates will demonstrate loading and enqueueing the first kernel,
waiting on it complete, and then enqueing the second one, typically sharing memory args between them.

If using `let-kernel` it is a good practice to `declare` the desired local and global work sizes so the
hoisting code will be optimal.


### Variable Capture
It is important to note that `let-kernel` does not create a lexical closure. Any variables from the 
surrounding scope that are used inside the `let-kernel` body must have their values known at compile time. 
This allows the compiler to "bake in" or inline these values (such as a constant identity value or a known `#'someFunction`) directly into the new kernel's definition.

If a value is only known at runtime (for example, a variable passed as an argument to the outer kernel), 
it cannot be captured. Instead, it must be passed as an explicit argument to the continuation kernel itself.


#### `kernel-name` 

`(declare (kernel-name "some_name"))` 

The `let-kernel` binding will determine the name of the kernel that is generated. But if you need to
name it relative to some other function argument, `declare` a `kernel-name`.  

If this declaration is missing, the kernel will take the name of the binding itself. 

Regardless of the method, remember that kernel names have to obey C identifier naming rules.


```
(def-kernel two_stage_operation (A B C)
    (declare #(my-v-t my-v-t my-v-t => nil)
             (local-size :derive-from B :msg "two_stage_operation local work size should be the same as the length of B")
             (global-size :set-to (+ (length~ A) (length~ B) (length~ C)) :msg "two_stage_operation global work size
             should be big enough for all three vector arguments"))
    (let-kernel ((continue-later (a c)
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
        (continue-later A C)))
```



First Order Functions
---------------------

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
(def-type my-vec-t (vector-type int :local))

(def-function count-if (v:my-vec-t predicate?)
    (declare (return-type ulong) (type predicate? #'(int => bool)))
    ...)

(def-function count-if (v pred?)
    (declare #'(my-vec-t #'(int => bool) => ulong))
    ...)
```



No First Order Types
--------------------

Types are evaluable only at compile-time. There is no runtime
passing or evaluation of types supported. 

But keywords and enumeration values ARE first order. 



Enumerations
------------

```
(def-enumeration address-space (:global 1) :local :private)

; Both of these are acceptable usage:
(vector-type int :global)
(vector-type float address-space:global)

```

In the example above, `def-enumeration` defines a new type called `address-space`, which is just a set of keywords.
Unless enumerations have conflicting keys, all unconflicted keys are automatically promoted to the 
global default namespace. ( And we don't support namespaces ).

### type constraints: is-XXXX?

Using `def-enumeration` automatically generates `is-XXXX?` for that enumeration name, which can be used as a type constraint function
in `with-template-type`.  See the discussion of type constraints in `with-template-type` for more information.



Maybe Type
----------

GPU Kernels do not support exceptions. Many operations that would be segfaults on a CPU 
(like reading past the bounds of allocated memory) are simply ignored by GPU kernels.  
These can make error handling challenging, negatively impacting both correctness and performance.
Crisp provides a "maybe" type which gives developers a simple way to define and handle error states. 
The maybe type automatically interoperates with the electable kernel logging mechanism, 
helping both correctness and debugability.

### maybe and result

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
  (def-function div-safe (dividend divisor)
    (declare #'(T T => (maybe T)))
    (if (= divisor 0)
      (result :Err "division by zero")
     (result :OK (/ dividend divisor)))))
  
```

### let-maybe

`let-maybe` is a binding environment that makes working with `maybe` types much easier.  
```
; Example 1
(def-function math-1 (a b)
  (declare #(long long => long))
 (let-maybe ((m1 (div-safe 10 a))
             (m2 (div-safe 20 b)))
          (+ m1 m2)
    :Err
       0))

; Example 2
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

#### compare to `let`

Below we use `let` instead of `let-maybe`.  Note that this will NOT compile. This is because, unlike `let-maybe`, 
the regular `let` doesn't guard and unwrap the maybe values.
The `#'+` operator only accepts numbers, it does not accept `maybe` types, and thus the expression `(+ m1 m2)` fails.

Note that if we want to use `let`, we can by leveraging the `or-else` construct (see below) which safely
guard and unwrap a single `maybe` type. 


```
; this won't compile
(def-function math-3 (a b)
  (declare #(long long => (maybe long)))
 (let ((m1 (div-safe 10 a))
       (m2 (div-safe 20 b)))
    (+ m1 m2)))
```



### a note about thread divergence

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



#### multiple return values

`maybe` and `result` support multiple return values. For example:  `(maybe int myVecType)`  `(result :OK someInt someVec)`


### Guard: or-else

`or-else` is a macro that takes a maybe and returns either 
its success value(s) or some other value(s) of the same type.

This is very useful for guaranteeing that even in the face of errors
that a function can consistently operate with SOMETHING and is not
forced to return 'maybe' simply because one of its sub-functions uses it.
 It does not prevent the `maybe` from being logged. 

```
(def-function some-math-ops (a b)
  (declare #'(float float => float))
  (let ((m (or-else (div-safe a b) 1))  ;<-- if there is an :Err, m will be '1'
        (n (+ a b)))
     (* m n)))
```




Control Flow
============

Programming performant GPU kernels is often very different than programming performant CPU-bound code.
And Crisp's departure from other languages is significant in its approach to execution control flow.

GPUs are very fast and powerful when performing parallel operations. When working large workloads, the goal is to keep 
the full might of the GPU fully occupied running meaningful operations in parallel without stalling.  
This is no small challenge, because many routine C and Lisp constructs like `if/then` or even a simple `for` loop
can lead to bifurcations in the thread progress, which leads to idle threads which leads to poor performance.

The control flow affordances in Crisp revolve around maximizing parallelism, keeping thread workgroups and warps marching
in sync, and avoiding bifurcations. Additionally Crisp keeps the developer involved and informed of the choices and trade-offs
being made, rather than hiding them behind abstractions. 


Single Task
-----------

A single task kernel is a kernel that runs on exactly one thread. While it is simple to understand be warned that it is not
necessarily performant. If you have only one single task kernel running, the majority of your GPU power idles untapped. 
When scheduling a single task kernel, look for opportunities to run it while other work is being done.

`single-task` 
Put the symbol `single-task` into the `(declare ...)` of the kernel. When it sees this, the compiler will surround
the main body of the kernel with a check to ensure it is run by only one thread.  And the hoisting code that
is generated will set the global work size (thread count) to be 1.  

```
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

when-thread-is / abs-when-thread-is
-----------------------------------

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
(def-kernel (#| some args |#)
  ;; first prepare
  (when-thread-is 0
    (let  ... ))

  ;; now do parallel grid stride
  (loop-grid-stride (i) 
    ...))
```

when-thread-in-group-is / when-group-is
---------------------------------------

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

### local-barrier compilation issue.

Using `(local-barrier)` inside the scope of `when-thread-in-group-is` results in a compilation error as it would otherwise deadlock an entire workgroup.

Crisp users are strongly encouraged to use `when-thread-in-group-is` as opposed to a generic construction like  `(when (= (get-local-id) 0) ...)`  for this reason. The compiler will _attempt_ to detect the deadlock possibility in a generic construction, but due to variables, assignments, etc that guarantee is not strong. Whereas in `when-thread-in-group-is` it is a surety.

when-global-linear-id-is / when-local-linear-id-is
--------------------------------------------------

Unlike the previous `when-XXXX-is` , these two calculate the relevant linear id, and so there are no
variants for higher dimensions.   
Note that the global linear id is always relative, an absolute version isn't supported.  (See discussion of `when-thread-is` / `abs-when-thread-is` above.)

```
(when-global-linear-id-is id <expr>)

(when-local-linear-id-is id <expr>)

```

when-is-last-workgroup
----------------------
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
(local-barrier)
(when-thread-in-group-is 0
   (set! old-count (atomic-dec! *internal-global-counter*))
   (local-barrier))

(when (= old-count 1)
    ;; body of when-is-last-workgroup
    )
```


Hoisting and Enqueing a Kernel
------------------------------

Crisp refers to the overall effort of getting a kernel read from disk, preparing the data, and actually enqueueing it as "hoisting". The Crisp compiler
can output hoisting example code for any kernel it compiles. That hoisting code is tailored to the kernel itself and the compilation targets,
which ensures that assumptions and dependencies are adhered to by both sides.

There are two important decisions that the host must make at the moment a kernel is enqueued. 
1. global work size - how many threads are spawned simultaneously for this kernels operation. 
2. local work size - how many threads are grouped together such that they can share fast local memory.


Typically, the most performant choices that maximize GPU throughput use a "local_work_size" that is both
a power of two and a multiple of the GPU warp size (32 or 64).  So typically 64, 128, or 256.  And the global_work_size,
the actual number of threads that will be spawned, should be a multiple of that. 

Crisp has a number of `declare` directives that allow the host and the kernel to agree on what, or how, these values will be set. They tell the story of who expects what. These all go in the kernel's top level `declare` block.


### global-size / local-size
```
(global-size &key set-to VALS derive-from EXPR dims:ulong msg:string)
(local-size &key set-to VALS derive-from EXPR dims:ulong msg:string)
```
These directives tells the hoisting code about how the kernel expects the global_work_size or local_work_size to be set.  
If both are used, then their arity must agree. And, the `work_dim` value the hoisting code sets will also match their arity.


The local_work_size is the number of threads grouped together in a single workgroup. This is number is usually best a power of two and multiple of the GPU warp size ( 32 or 64 ).
The global_work_size is the number of threads that the kernel will be enqueued upon. For maximum throughput, it is best to be a multiple of the local_work_size. 

A single directive CANNOT use both the `:set-to` and `:derive-from` keys.

#### :msg
The `:msg` key takes a string that will be output into the comment at the place where the hoisting code is setting the particular value. 


#### :dims
The `:dims` key just takes the number `1` , `2` or `3` to express the required arity.  If using `:set-to` or `:derive-from` then
`:dims` is not usually needed.  But there will be times when a kernel doesn't have particular size requirements but DOES
have arity expectations.  Communicate them with `:dims`

If the `:dims` declaration does not match the arity of `:set-to` or `:derived-from`, or the arity differs between `global-size` and `local-size` then the compiler will error.

```
(def-kernel operate_2D ()
   (declare (global-size :dims 2))
   ...)
```

#### :set-to
The `:set-to` key instructs the hoisting code to use a specific value, (or values if multi-dimensional).

```
; Crisp Code
(def-kernel fun ()
  (declare (local-size :set-to 256))
   ...)

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

#### :derive-from
The `:derive-from` key instructs the hoisting code that the kernel expects the size value to be in response to the named kernel parameter.  If the expression names a vector, then in response to its length. 

```
;; Crisp Code
(def-kernel lighten_image (image-data width height)
   (declare (type image-data (vector-type :uchar :global :read_write))
            (type width height ulong)
            (global-size :derive-from '(width height) :msg "ensure enough threads for every pixel of image, otherwise use the stepping convolution")) 
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




### check-thread-bounds
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
(def-kernel lighten_image (image-data width height)
   (declare (type image-data (vector-type :uchar :global :read_write))
            (type width height ulong)
            (global-size :derive-from ( width height))) ; <-- this sets the upper bound for check-thread-bounds 
  (let ((image-matrix (make-tensor-view image-data width height)))
    (in-each-thread (x y)
      (when (check-thread-bounds x y) 
        (inc! (~ matrix x y) 30)))))

```

### check-wg-bounds
Like `check-thread-bounds` but influenced by the `local_work_size` enqueue value and meant to be used on workgroup indeces.

### declaring local-size / global-size in sub functions.
The declarations of the local or global size preference is optional, though highly recommended. It can be done
in the scope of a `def-kernel` or in the scope of a `def-function`.  The compiler will look at the call chain for any kernel to see what values it should request in the hoisting code for global and local sizes.  
If there are competing declarations in the kernel and different sub functions then the compiler will emit a warning informing you. When there are conflicts the hoisting code will recommend that the GREATEST of the competing sizes
be used. 



Latency Hiding - warp sizes and workgroup sizes
-----------------------------------------------

As mentioned in passing, most GPUs have a warp size of 32 threads, and the best practice is to use a `local_work_size` (ie a work group size) that is a multiple of the warp size when enqueueing.  But why is that?
The answer is Latency Hiding. When a warp needs to access memory it may become stalled waiting for that memory.  
While it is stalled the GPU can run OTHER warps to "hide" the latency. But it can only run other warps that 
are within the same workgroup. So this is the reason the workgroup size is best set as a multiple of the warp size.

There are times when it is simplest, and indeed fastest, to simply set the `local_work_size` to 32, to the warp size. This ensures that workgroup thread communication can always just be done with a shuffle, and without needing `:local` memory or barriers. But this is only a good strategy if you are sure your kernel is relatively stall-free. If it stalls because of branch divergence or memory access, then there is no other warp to take up the slack, which makes the overall operation slower.  



One Thread Per Element
----------------------

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

### in-each-thread 

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
(def-type source-vec (vector-type float :global :readable))     
(def-type result-vec (vector-type float :global :write_only))    
(def-kernel vector_add (A B &out C)
  (declare (type A B source-vec) (type C result-vec) 
           (global-size :derive-from A :msg "no bounds checking. global_work_size MUST match vector lengths" ))
  (in-each-thread (i)                        ; 'i' will be bound to the thread index / global-id
    (set! (~ C i) ( + (~ A i) (~ B i)))))


;; 2D Lighten Image
(def-kernel lighten_image (image-data width height)
   (declare (type image-data (vector-type :uchar :global :read_write))
            (type width height ulong)
            (global-size :derive-from '(width height))) 
  (let ((image-matrix (make-tensor-view image-data width height)))
    (in-each-thread (x y)
      (when (check-thread-bounds x y) 
        (inc! (~ matrix x y) 30)))))
```


### in-each-thread-in-group

`in-each-thread-in-group` is a simple macro for binding thread index values over a body of statements. 
It is useful when you want every thread in a workgroup to follow a sequence of steps. 

There are three variants for 1D, 2D and 3D .
```
(in-each-thread-in-group (x) ...)       ; 1D   x is bound to the x thread index / local-id 0
(in-each-thread-in-group (x y) ...)     ; 2D   x and y bound to the local-id 0 and 1 
(in-each-thread-in-group (x y z) ...)   ; 3D  
```


### Size Matters

In the first example above, we used 1024 as the vector size and the matching thread count. That's convenient
for an example because that number is a multiple of 32 and 64, the most common warp sizes. 

When hoisting a kernel the most performant choices that maximize GPU throughput use a "local_work_size" that is both
a power of two and a multiple of the GPU warp size (32 or 64).  So typically 64, 128, or 256.  And the global work size,
the actual number of threads that will be spawned, should be a multiple of that.

But what to do if the size of your problem is NOT an even multiple of one of these nice choices?  In this case, the kernel 
should definitely use `check-thread-bounds` and the host code that hoists it should round up whatever thread count they are 
requesting to the next muliple of a nice local_work_size.



Looping - Grid Stride
---------------------

While a typical GPU can run many simultaneous threads, there are definitely problem spaces that exceeed its maximums.  
In these cases, we want to launch a bunch of threads and have each perform their work N times without overlapping. 
Where N = Size-of-Problem / Number-of-Threads-Launched.  

A grid-stride loop is a common pattern for processing large datasets that are bigger than the number of threads launched. It ensures that each thread processes multiple data elements while maintaining full occupancy and avoiding divergence.

The Crisp grid stride primitives are designed to encourage coalesced memory access patterns by default, helping the
programmer achieve maximum performance.

### IMPORTANT - NO NESTING

All the `-stride` operations are "grid level" operations. That is discussed below. Essentially,
`-stride` operations cannot nest inside one another. The compiler will error if you attempt to do so.

Also th body of the  `-stride` operations cannot call other "grid level" operations like the variants
on `reduce-`, `filter-` and others. You are welcome to use multiple grid level operations, they just
cannot be nested.

### `loop-grid-stride` 

`loop-grid-stride` let's a kernel elect the Grid Stride strategy and set up a grid stride loop,
such that the body of `loop-grid-stride` is run on a single thread, and then `i` is 
automatically incremented by the number of threads. 
Crisp has three variants of `loop-grid-stride` for 1D, 2D and 3D .

```
(loop-grid-stride (x) ...)       ; 1D   x is bound to the x thread index / global-id 0
(loop-grid-stride (x y) ...)     ; 2D   x and y bound to the global-id 0 and 1 
(loop-grid-stride (x y z) ...)   ; 3D  
```

Obviously, `loop-grid-stride` is quite similar to `in-each-thread` except it implicity surrounds the work in a loop, that will
loop the body `N` times, incrementing the thread id by N each time. Unlike the "one thread per element strategy", the check on the stride provided by the loop is enough. There is no need for an additional `check-thread-bounds` 

#### match work_dims arity
The hoisting code that enqueues the kernel should always use a work_dim that matches the arity of your grid stride.  Otherwise it may not work properly and will have many redundant threads.
To help avoid mistake, always `declare` a `global-size` whenever using `loop-grid-stride`. The compiler
will warn you if you do not. And if you do, but it's arity does not match the `global-size` arity, then the compiler will emit an error.

### grid-stride-target
```
(grid-stride-target EXPR)
(grid-stride-target X-Expr Y-Expr)
(grid-stride-target X-Expr Y-Expr Z-Expr)
```
The `loop-grid-stride` loop needs to know when to stop. That's what stride target is. This goes in a `declare` section
inside the `loop-grid-stride`. It can be a number, an expression that evaluates to a number, or a vector in which case it is assumed to be `(length someVector)`


### grid stride example with explanation.
```
;; 1D Vector Add
(def-type source-vec (vector-type float :global :readable))     ;; let's revisit that :read_only requirement for kernels?
(def-type result-vec (vector-type float :global :write_only))    ;;  ibid
(def-kernel vector_add (A B &out C)
  (declare (type A B source-vec) (type C result-vec) 
     (global-size :derive-from A))     
  (loop-grid-stride (i)                       ; 'i' will be bound to the thread index / global-id
    (declare (grid-stride-target A))          ; length of vector parameter 'A' is the where we stride to.
    (set! (~ C i) ( + (~ A i) (~ B i)))))
```

Let's imagine that our vectors A, B, and C each have 100,000 elements. And imagine that our hosting code has set the 
`global_work_size` to 1024. That is, 1024 threads are each running this kernel in parallel.

`loop-grid-stride (i)` establishes a loop, with `i` bound to an index, and the the body setting the vector C at that index
to the sum of A and B at that index (or in C: `C[i] = A[i] + B[i]`)

This runs in parallel so `i` is bound like so across all the threads:
```
    Loop Iteration #1:  0     1     2    3    4    ... 1023
```
And then, the next time through the loop, we don't increment by 1, instead we "stride", we increment _by the number of threads_, which 
we imagined is 1024.  We keep striding until we hit the target. In our code, a vector is the target `(grid-stride-target A)` so its length, 
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

### loop-grid-stride-linear
`(loop-grid-stride-linear (x) ...)       ; x is bound to the x flattened thread index / global-linear-id`

This is much like `loop-grid-stride` except that it always has just one thread id bind, regardless of the `work_dim` of the enqueue. The `x` term is bound to the global linear id.   Like `loop-grid-stride` it MUST be used with `grid-stride-target` or it will not be able to determine when to stop the loop. 


### loop-vector-stride
`(loop-vector-stride Vec (i) ...)`     

`loop-vector-stride` iterates over a vector  using the Grid Stride strategy. With it, there is no need to declare a grid stride target.
This makes it simpler, clearer and less error prone.   With it our vector_add example from the previous section becomes even simpler.
```
(def-kernel vector_add (A B &out C)
  (declare (type A B source-vec) (type C result-vec)
     (global-size :derive-from A))      
  (loop-vector-stride A (i)                   
    (set! (~ C i) ( + (~ A i) (~ B i)))))
```
#### work_dims 
In Crisp, vectors are always 1D, but a kernel can be enqueued with a work_dims of 2 or 3. 
In that case, `loop-vector-stride` will stride using `get_global_linear_id/size` just like `loop-grid-stride-linear`.

### loop-soa-stride
`(loop-soa-stride soaVec (i) ...)`

`loop-soa-stride` iterates over a `soa-vector` using the Grid Stride strategy.  There is no need to declare a grid stride target.

As with `loop-vector-stride`, if the kernel is enqueued with a work_dims of 2 or 3 this routine will stride with `get_global_linear_id`.


### loop-tensor-stride
```
(loop-tensor-stride Tensor (x) ...)           ; 1D   x is bound to the flattened thread index / global-linear-id

(loop-tensor-stride Tensor (x y ... N) ...)   ; ND  
```

`loop-tensor-stride` iterates over a tensor using the Grid Stride strategy.  Because the `Tensor` is provided as an argument there is no need to declare a grid stride target. 

`loop-tensor-stride` is available to any arity, so long as it matches the number of dimensions of the tensor itself. 
If the arity of the tensor matches the arity of the enqueue (`work_dim`) then the grid stride will use the `get_global_id` calls and stride by the relevant `get_global_size`.  Otherwise, it defaults to using `get_global_linear_id` and striding by the linear size, and it will handle setting the index arguments
correctly, rolling them over at the limits of the tensor in those dimensions.


### loop-group-stride

All the `loop-XXX-stride` forms we've seen so far have been thread oriented. For example a thread is given one 
index in a vector, which it uses, and then on the next entry to the loop it's assigned index is very far away.
The "jump" is determined by the global work size. 

But `loop-group-stride` is workgroup oriented. A target (like a `vector` or `tensor-view`) is provided, along with a work
size and then a group of threads each get the SAME index each time through the loop. 

You can think of a small cleaning crew (a workgroup) is assigned to a very long hallway (a vector). They clean one section of the hallway (a chunk), then skip ahead to the next section assigned to them, continuing until the whole hallway is clean.

```
(loop-group-stride Vector chunk-sz:ulong (chunk-start-idx) ...)  1D 

(loop-group-stride Matrix tile-dims:ulong2 (tile-idx-y tile-idx-x) ... ) 2D

(loop-group-stride 3D-Tensor-View block-dims:ulong3 (block-z block-y block-x) ...) 3D
```

Note that as the arity of `loop-grid-stride` goes up, so does arity of the dimensions argument (`ulong`, `ulong2` and `ulong3`).

#### loop-tile-stride 

The most common use of a 2D group stride is to process a matrix using square tiles. For this, the `loop-tile-stride` macro is provided as a simpler shorthand. It simply takes a `ulong` for `tile-dim` because it assumes a square tile.

```
(loop-tile-stride Matrix tile-dim:ulong (tile-idx-y tile-idx-x) ... )
```




Looping -- Uniform Loops
------------------------

A C++ `for` loop is a big liability when improperly used in a GPU kernel. If the loop isn't
performed uniformly across all the threads in a work group then massive stalls can occur
which kill throughput and performance. 

Crisp makes it easy to declare uniform loops.  The basic syntax looks like this:

```
(let ((someN:long someThing))
  (declare (uniform someN))
   (dotimes+ (x someN)
      ...))
```
or even easier
```
(dotimes* (x someN)
 ...)
```
This second example with `dotimes*` is automatically transformed to the first one (with `dotimes+`) by the compiler.

### (uniform <varName>)
`(declare (uniform someN))`
This is a convenience declaration to help programmers set up values that are uniform in a workgroup.

The `uniform` declaration causes the compiler to
- initialize the variable in exactly one workgroup thread
- share it with the other threads of the workgroup via local memory and a barrier.

Furthermore
- The variable named and the `declare` invocation both MUST originate in 
the same `let` clause. 
- `uniform` cannot be used in other `declare` contexts.

### dotimes+ 
 `dotimes+` is the `+` variant. It will throw a compiler error if it
is used without a constant or uniform `N` value. 

### dotimes*
`dotimes*` is the `*` variant. Any expression provided for its `N` will be
automatically captured by the compiler as a uniform for you, with no
error or warning emitted by the compiler. 


### caution
You must still exercise vigilance over the body of the loop. 
Inserting `if`, `when` or `cond` clauses can lead to branch divergence, 
where different threads in a workgroup take different execution paths. 
This will cause stalls and kill performance. 

But also, before using `+` or `*` variants, you must be confident that
uniformity is correct for your problem. 





Looping Constructs
------------------

Here is a list of the looping constructs supported by Crisp. Some are discussed elsewhere.

- loop-grid-stride / grid-stride-target   ( see Looping -- Grid Stride above ) 
- loop-grid-stride-linear
- loop-vector-stride / loop-soa-stride / loop-tensor-stride
- loop-group-stride / loop-tile-stride
- dotimes / dotimes+ / dotimes*
- do-times-by-doubling
- do-times-by-multiply
- dec-times / dec-times+ / dec-times*
- dec-times-by-half / dec-times-by-half+ / dec-times-by-half*
- dec-times-by-factor / dec-times-by-factor+ / dec-times-by-factor*
- do-power-step
- dec-power-step

### Immutable Index
All of the above bind a loop index. Unlike in a C++ `for` loop, that index value is immutable in the 
body of the loop.

### + variants
Most of the Looping Constructs have a variant whose name ends in `+`. These variants 
only accept constant or uniform values for their target `N` . The compiler will error if that
condition is not met. Whenver possible, try to use the `+` variants for more performant code. 

### * variants
If not provided a uniform or constant value, then the `*` variants will just make it a uniform for you.
They are a convenience.  They automatically capture the target `N` as a uniform value in one thread and use shuffle operations to retrieve it. 

See the discussion of Uniform Loops above. 

### variants compared
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
<!-- NOTE: this opens up a huge can of worms.  There are two possible response. -->
<!-- RESPONSE #1 -->
If `(+ a b)` is calculable at compile time, then this is fine. The compiler will insert that value and the loop 
will be uniform.
Otherwise for the expression `(+ a b)` to be uniform, it would have to first be captured in a variable that was declared such. So not calculable at compile time this would be considered non-unform and would cause a compiler error.
But this fix is simple, just capture and declare it.
```
(let ((N (+ a b))
   (declare (uniform N)
   (dotimes+ (x N)
    ... ))))
```
Or, even simpler, have the compiler do that for you with the `*` variant `dotimes*`.
<!-- RESPONSE #2 -->
If `(+ a b)` is calculable at compile time, then this is fine. The compiler will insert that value and the loop 
will be uniform.
If both `a` and `b` are `uniform` then the entire expression will be considered unform as well.
But if either `a` or `b` are not `uniform` then this would cause a compiler error. This can be gotten 
around by either capturing the sum in a variable that is made uniform, or using the `*` variant.


`*`
```
(dotimes* (x (+ a b))
 ...)
```
As a convenience, the compiler will have one thread of the workgroup capture `(+ a b)` as a value and then all threads
in the workgroup will access it via a shuffle operation. This will force the loop to be uniform. 



### dotimes / dotimes+ / dotimes*
```
 (dotimes (i N:ulong &optional (stride:ulong 1)) 
    ...)
```
Binds `i` to 0, counts up to N, incrementing by `stride` each time through the loop. `stride` is optional, defaults to 1.

### dec-times / dec-times+ / dec-times*
```
  (dec-times (i N:ulong &optional (stride:ulong 1))
    ...)
```
Binds `i` to `N-1` and counts down to `0`, subtracting `stride` each time through the loop. `stride` is optional, defaults to 1.
This is the opposite of `dotimes`


### do-times-by-doubling
```
  (do-times-by-doubling (i:ulong init:ulong N:ulong) 
   ...)
```
Binds `i` to `init`. Each time through the loop, `i` is doubled until
it reaches (or exceeds) `N`.  The last call will always have `i` bound to a value less than or equal to `N`.

Example: If `init` is 1 and `N` is 64: i => 1, 2, 4, 8, 16, 32, 64
Example: If `init` is 1 and `N` is 100: i => 1, 2, 4, 8, 16, 32, 64

### do-times-by-multiply
```
  (do-times-by-multiply (i:ulong init:ulong N:ulong factor:ulong)
   ...)
```
Binds `i` to `init`. Each time through the loop, `i` is multiplied by `factor` until i reaches (or exceeds) `N`.  The last call will always have 
`i` bound to a value less than or equal to `N`.

The `factor` value must be greater than 1.

Example:  `init` is 1  `N` is 64 and the `factor` is 4:  i => 1, 4, 16, 64


### dec-times-by-half / dec-times-by-half+ / dec-times-by-half*
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

### dec-times-by-factor / dec-times-by-factor+ / dec-times-by-factor*
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


### do-power-step

```
  (do-power-step (step-var:ulong limit:ulong) 
     ...)
```
`do-power-step` binds `step-var` to the powers of 2 up to `limit` (or the next power of 2 if it is not itself a power of 2).
The highest value `step-var` will have is half the "padded" limit.
For example, in `(do-power-step (i 100) ..)`, the limit of 100 gets rounded up to the next power of 2 which is 128.
This would then have seven steps, binding `i` in turn to 1, 2, 4, 8, 16, 32, and 64
The number of steps taken is `(log2 padded_limit)` ( aka `(log padded_limit 2)`)

#### possible implementation
```
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


### dec-power-step

```
  (dec-power-step (step-var:ulong limit:ulong) 
     ...)
```
The reverse of `do-power-step`, `dec-power-step` starts with `step-var` bound to half the padded limit and decremented until it is 1.
E.G. In `(dec-power-step (i 230) ...)` the limit of 230 would be raised to the next power of two, which is 256.
So `i` would be bound to 128, 64, 32, 16, 8, 4, 2, and 1. 

#### possible implementation
```
(defmacro dec-power-step ((step-var limit) &body body)
  "Loops log2(padded_limit) times, binding step-var to ..., 8, 4, 2, 1."
  (let ((d (gensym))
        (padded-limit (gensym)))
    `(let ((,padded-limit (next-power-of-2 ,limit)))
       (dec-times (,d (log2 ,padded-limit))
         (let ((,step-var (expt 2 ,d)))
           ,@body)))))
```


Grid Level Operations
---------------------

Grid-level operations are primitives that orchestrate work across the entire grid of threads. A fundamental rule in Crisp is that 
a `progn` with a grid-level context CANNOT contain other grid level operations. (ie no nesting). Attempting to do so is a semantic error that leads to incorrect calculations, massively redundant work, and incomplete coverage of the problem space.

The following Crisp functions and macros are grid level operations, the either open grid level contexts or take
higher order function arguments that must be thread level (only) operations. 

- all `-stride` functions
- all grid-wide reduction variants ( `reduce-to-1-*`, `reduce-vec-*`)
- `filter`
- `convert-layout` 
- `when-is-last-workgroup`



### `(declare (grid-level))`

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

### atomic ops

Atomic operations (see below) performed on `:global` memory are, by fiat, grid level operations. If your
`defmacro` uses any atomic operation on `:global` memory, be sure to `(declare (grid-level))`.  
Atomic operations on `:local` memory have no such requirement.


Barriers and Fences
-------------------

The golden rule of GPU programming is: if you have threads cooperating on a task and one thread writes a value that another thread needs to read, you must use a barrier. The logical pattern is always **Write -> Barrier -> Read**, regardless of whether it's one thread writing and many reading, or many threads writing and one reading.

### local-barrier
`(local-barrier)`
This routine inserts a local barrier. It ensures that all threads in the workgroup have reached the same location before continuing. This barrier includes a memory fence that guarantees all writes to local memory by threads in the workgroup are visible to all other threads in that same workgroup. Use it after you are done writing to shared local memory and before any other thread is expected to read from it. On CUDA it will map to `__syncthreads()` and on OpenCL to `barrier(CLK_LOCAL_MEM_FENCE)`.

### mem-fence
(mem-fence &key local global)
This routine inserts a memory fence to enforce the ordering of memory operations. Unlike a barrier, a fence does not synchronize thread execution.

A fence guarantees that all writes to a memory space (e.g., :global) before the fence are visible to other threads before any reads or writes after the fence are executed by this thread. This is an advanced feature for preventing subtle race conditions in complex algorithms, especially those involving atomic operations or producer-consumer patterns between different workgroups.

On CUDA, (mem-fence :global) maps to __threadfence(). On OpenCL, it maps to mem_fence(CLK_GLOBAL_MEM_FENCE).

<!-- WHAT are the comparables for LevelZero? -->




Sum a Vector using Local Memory
-------------------------------

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
or  M = global_work_size / local_work_size.

The routine will use a tree reduce pattern so that half the threads in the workgroup 
add their sum to the comparable in the other half. And then repeat, halving the 
number of threads each time. This reduction is on the local scratchpad.

Lastly one thread in each work group writes its sum to the global scratchpad.

After this, we could use a global barrier and then sum that scratchpad.
But since the global scratchpad needs to be prepared by the host anyway,
it's simpler to just end the operation and have the host sum them up.

In our `sum_vector` routine, the host will supply the vector it wants
to be summed, plus the result vector (which is also that global scratchpad).
We could also have it provide the local scratchpad as a vector too. That 
would make the routine more flexible. But in this case, we are just
going to agree on a convention that the local_work_size is 64.



```
;; this kernel assumes a local_work_size of 64
(def-const +wg-size+:ulong 64)  

;; the source vector can be any size. 
(def-type source-vec (vector-type long :global :readable))     

;; the result vector should be size M, where M = global_work_size / local_work_size
(def-type result-vec (vector-type long :global :writeable))  

(def-kernel sum_vector (A:source-vec &out Res:result-vec)
    (declare (local-size :set-to +wg-size+) (global-size :derive-from A))
                                     
   (let ((sum:long 0))
     ; 1- Stride the vector, summing it up. Each thread has its own value in 'sum'
     (loop-grid-stride (i)
       (declare (grid-stride-target A))
        (inc! sum (~ A i)))
    
      ;; 2- Prepare local memory and store sum in it. 
      (let ((slm (make-vector long :local :read_write +wg-size+)))
        (in-each-thread-in-group (local-idx)
          (set! (~ slm local-idx) sum)
          
          ;; 3- tree reduce
          (dec-times-by-half+ (s (/ +wg-size+ 2))  s is 32, then 16, 8, 4, 2, 1
            (local-barrier)
            (when (< local-idx s)
              (inc! (~ slm local-idx) (~ slm (+ local-idx s))))))

        ;; 4- move sums to global 
        (when-thread-in-group-is (0)
          (let ((wg-idx (get-workgroup-id 0)))
            (set! (~ Res wg-idx) (~ slm 0))))))) 
```

Warps & Shuffles
----------------
Witchcraft.

The shuffle primitives are special hardware instructions that allow threads
within a single warp directly exchange register values with each other without 
using shared memory. They are very powerful and fast operations.

For most NVidia hardware there are at most 32 lanes in a single warp.  Be sure the `local_work_size` used when enqueueing the kernel matches as a workgroup cannot perform shuffles outside the maximum warp range. A `(local-size :set-to 32)` declaration with a nice message can help communicate that to whoever is developing
the hoisting.

## in-warp
`(in-warp (<id-name>) ...)`
`in-warp` binds the thread's lane id to the `id-name` expression for the statements in its body.  

It is within the scope of an `in-warp` block that the various shuffle operations can occur. They cannot
be used otherwise. <!-- NOTE: I don't think this has to be true at all. Maybe? -->

<!-- IMPLEMENTATION NOTE
  CUDA:   unsigned int lane_id = threadIdx.x % 32;
  OpenCL: unsigned int lane_id = get_sub_group_local_id();
-->


### shuffle
`(shuffle <someVar> target-lane-id)`
The `(shuffle ...)` expression evaluates to the current value of `someVar` as it is in another thread. 
THe target lane-id is provided directly to `shuffle`.

### shuffle-up  / shuffle-down
`(shuffle-up <someVar> delta)`
`(shuffle-down <someVar> delta)`
These expressions evaluate to the current value of `someVar` in a thread that is plus or minus `delta` lanes over.
Note that `-up` / `-down` do not necessarily have an intuitive interpretation. The direction is where the data 
is going to, rather than the operation performed with the delta. So `shuffle-up` SUBTRACTS `delta` from the current 
lane id and returns the value of `someVar` from that lower lane (ie, the data is shuffling "up" to our higher lane).
Meanwhile, `shuffle-down` ADDS `delta` to the current lane id and return the value of `someVar` from that higher
lane (ie, the data is shuffling "down" to us.) Whatever. 

### shuffle-xor
`(shuffle-xor <someVar> lane-id-mask:ulong)`

Those other shuffle operations do cool tricks. But `shuffle-xor` is where real sorcery occurs.

The `(shuffle-xor ...)` expression evaluates to the current value of `someVar` as it is in one of the other threads.  
The target lane id is calculated by taking the current thread lane id and XOR-ing with the `lane-id-mask` argument.
`shuffle-xor` only needs to be given the name of the variable to fetch and the mask, it gets the current lane id automatically.

`shuffle-xor` is very useful for tree reducing.  See the `sum_vector_warp` example below. 
The magic occurs in the interaction between the descending-by-half mask gotten from `dec-times-by-half` and `shuffle-xor`
This gives us a butterfly communication pattern, which allows all threads to contribute to a reduction in a logarithmic
number of steps.
```
(dec-times-by-half (s (/ +warp-size+ 2)) ;;start the descent with half the warp size. ie 16 then 8, 4, 2, 1
        ... (shuffle-xor someVal s))
```

Sum a Vector using Warps and Shuffles
-------------------------------------

Would you like to calculate the sum of a vector without needing any local shared memory
and without needing any barriers? Just a drop of blood is all we need, use it to sign the
contract below. 

This version starts out the same as the last one. The grid stride legerdemain is used and 
each of the threads holds its own copy of a sum. Then, as before, we reduce. Half 
the warp uses a shuffle and an XOR mask to fetch the sum from another thread and add it.
Then half again, and so on. And then we  record the results into the same Result vector.




```
;; 32 warps maximum for most hardware
(def-constant +warp-size+:ulong 32)

;; the source vector can be any size. 
(def-type source-vec (vector-type long :global :readable))     

;; the result vector should be size M, where M = global_work_size / local_work_size
(def-type result-vec (vector-type long :global :writeable))  

(def-function calculate-this-thread-sum (A:source-vec)
  (declare #(source-vec -> long))
  (let ((sum:long 0))
    (loop-vector-stride A (i)
      (inc! sum (~ A i))))) ; <-- inc! implicity returns final sum


(def-kernel sum_vector_warp (A:source-vec Res:result-vec)
    (declare (local-size :set-to +warp-size+ :msg "this kernel uses a 32 warp size, which should also be the local_work_size when enqueueing") 
             (global-size :derive-from A))
  ; 1- Stride the vector, summing it up. Each thread has its own value in 'sum'
  (let ((sum (calculate-this-thread-sum A)))
     ; 2 - Reduce. 
    (in-warp (lane-id)
      ;; this reduction uses `s` from `dec-times-by-half` to bisect/reduce. The `lane-id` is unused.
      (dec-times-by-half+ (s (/ +warp-size+ 2))
         (inc! sum (shuffle-xor sum s))))
    
    ; 3 - move sum to global
    (when-thread-in-group-is (0)
      (let ((wg-idx (get-workgroup-id 0)))
          (set! (~ Res wg-idx) sum)))))   
      
```

Branching
=========

Crisp has the same three basic branching expressions as Common Lisp: `if` , `when` and `cond`

They each operate similarly: first evalute a predicate expression, and if true, then execute 
some consequent. With variations for multiple checks, multiple statements, etc.

### * variant
Each of these has a `*` variant: `if*`, `when*` and `cond*`.  The `*` variants do NOT run their
predicate in every thread in a workgroup. Instead only one thread per workgroup checks the predicate
and it stores the result. All threads in the workgroup fetch it via a shuffle and dispatch on that same 
result.  This means the `*` variants run uniformly. 

Further, if the predicate can be evaluated at compile time, then compiler will simply evaluate it and replace the
entire expression with the selected branch. 

When possible, try to use the `*` variants of these functions.

### + variant
The `+` variant exists as well (`if+`, `when+`, `cond+`). 
It does not make its predicate be uniform, it only checks at compile time that it is.
It is most useful if you expect the predicate to be compile-time evaluable.

### `it` - anaphoric
All the branching expressions are "anaphoric", which is a linguistic concept to describe a word that acts as a substitute for an earlier expression.
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

Cost of Divergent Branching
---------------------------

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

If the uniform variant `if*` were used then it would take 10 seconds, and there would be no stalling. This is because it would not diverge in a workgroup. Of course, that
might not be appropriate for some problem sets. But you can see where it is obviously superior to structure your problem so that it CAN 
take advantage of such an optimization.


Predicated Selection
--------------------

Because the cost of branch divergence is so high, it is often just preferable to evaluate BOTH the consequent and alternative and
select the correct one in response to a predicate. That what `select-if` is for. Use it with simple values for `<expr-A>` and `<expr-B>` 
and you'll be fine. 

`(let ((v (select-if <predicate-expr> <expr-A> <expr-B>))))  ; BOTH expr-A and expr-B will be evaluated/executed. `

This does NOT have shortcut evaluation like in C++.  Recommend that `<expr-A>` and `<expr-B>` be simple.

There is no uniform `+` or `*` variant for `select-if`, the uniform `if*` is better in that case because it DOES have shortcut evaluation.

<!-- NOTE: how is this actually realized on a GPU -->


Higher Order Function Operations
================================

map
---

### map-stride
`map-stride` uses Grid Stride to visit every element of some source vector or tensor and pass it
as an argument to a provided function, and then store it at the same position in some destination vector or tensor.

```
(map-stride #'someFunc (A) Z)   
```
Requirements:
- `someFunc` has the signature `#((element-type A) => (element-type Z))`
- `A` and `Z` are a  `vector`, `vector-view` or `tensor-view`
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
(def-function analyze (v)
  (declare #'(ulong => bool bool))
  (return (is-even? v) (appears-in-fibonacci? v)))
...
(map-stride #'analyze (A) EvenAnalysis FibAnalysis)
```

reduce variants
---------------

### optional scratch vector arguments.

Some of the reduce functions accept `&optional` arguments for local and global scratch vectors.  
These vectors are consistently sized relative the warp, workgroup and global thread count. 
If not provided Crisp will generate the scratch memory for you.



### reduce-to-warp

`(reduce-to-warp someFunction <someVar> identity &optional (active-threads +warp-size+) )`

`reduce-to-warp` is a macro that applies `someFunction` to `<someVar>` expression in the current thread and another thread in
the same warp. It does this iteratively until all the threads in the warp whose id is less than `active-threads`
 have been reduced.  Note that using a value for `active-threads` that is GREATER than the warp size for the GPU hardware
 is undefined behavior. This reduction cannot reduce more than `+warp-size+` threads.

`reduce-to-warp` achieves its reduction using shuffles and `dec-times-by-half+` without using barriers or local memory. 
It is extremely fast. But it is limited to just one warp. The kernel could `(declare (local-size :set-to 32))` where 32 is max thread count per warp for most GPUs, 
and this is a good fit for many problems. But a workgroup that consists of multiple warps is often better
 because if one warp needs to pause while it fetches memory, another warp can be run in its stead - but this only happens within a single workgroup.   

- `someFunction` is a `binop-type`, meaning it has type `#(T T => T)` where `T` is the type of `<someVar>`
- After completion `<someVar>` in all the threads of the warp will be bound to the final value of the reduction.
- `reduce-to-warp` returns nil. 



The example below will output "warp total: 640" repeatedly, once for each warp, assuming 32 threads per warp and each warp fully occupied. 
```
(let ((someVar:long  20))
  (reduce-to-warp #'+ someVar)
  (when-thread-in-warp-is 0
    (r-t-output "warp total: " someVar)))  ;; => "warp total: 640"     
```

Possible Implementation:

```
(defmacro reduce-to-warp (someFunction someVar identity  &optional (active-threads +warp-size+))
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  `(in-warp (lane-id)
    ;; Active threads use their value. Inactive threads use the identity.
    (let ((val (if (< lane-id ,active-threads)
                    ,someVar
                    ,identity)))

      ;; Perform the full, unconditional reduction on 'val'.
      ;; The loop bounds are always based on the full warp size.
      (dec-times-by-half+ (s (/ +warp-size+ 2))
        (set! val (funcall ,someFunction (shuffle-xor val s) val)))

      ;; Write the final result (from lane 0) back into someVar for all threads.
      (set! ,someVar (shuffle val 0)))))
```



### reduce-to-workgroup

`(reduce-to-workgroup someFunction <someVar> identity &key return-vec local-scratch-vec message )`

`reduce-to-workgroup` is much the same as `reduce-to-warp` but it reduces all the threads in the workgroup, not just in the warp. 
In addition to `someFunction` , `<someVar>` and `identity` it also accepts two `&key` arguments.

#### return-vec
The `:return-vec` is a vector that will store the return results (if desired).  This is a vector of the same
element type as `<someVar>`. Its address space MUST be `:global` and it's size is the number of workgroups 
which can be calculated as `M` where `M = global_work_size / local_work_size`.   
If the `:return-vec` is not provided, the result is not preserved in memory. But after `reduce-to-workgroup` 
finishes, `<someVar>` will be the result of the reduction in its same workgroup. So it is usable if your
next operations can be performed within the workgroup.

#### local-scratch-vec
The `:local-scratch-vec` key.  If not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` (or `vector-view`) that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / +warp-size+` ). `+warp-size+` is usualy 32. 

#### message
The `:message` will be applied to the creation of the `:local-scratch-vec` if Crisp is generating it on your
behalf.  This can help inform the hoisting code for what the extra scratch memory is needed.


- After completion `<someVar>` in all the threads of the workgroup will be bound to the final value of the reduction.
- `:return-vec` (if provided) will store the results of each individual workgroup's reduction.
- The state of `localScratchVec` is indeterminant 
- `reduce-to-workgroup` returns nil.

Possible Implementation
```
(defmacro reduce-to-workgroup (someFunction someVar identity &key message 
                                                             (local-scratch-vec (funcall (gen-make-reduction-local-scratch-vec (type-of someVar) message)))
                                                             return-vec)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (if return-vec (is-type-of (element-type return-vec) (type-of someVar)) T) "type mismatch of return-vec and someVar")

  `(progn
    ; After this local-scratch-vec contains partial sum from each warp in the wg
    (reduce-to-warp ,someFunction ,someVar ,identity)
    (when-thread-in-warp-is 0
      (set! (~ ,local-scratch-vec (get-warp-id)) ,someVar))
    (local-barrier)

    ; inter warp reduction
    (let ((num-warps (ceil (get-local-work-size) +warp-size+))
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
          (local-barrier)))

      ; The final result is in local-scratch-vec[0]. Load it to thread 0
      (when-thread-in-group-is 0
        (set! ,someVar (~ ,local-scratch-vec 0))
        (when ,return-vec (set! (~ ,return-vec (get-group-id)) ,someVar)))
      ; broadcast to entire workgroup
      (when-thread-in-group-is 0
        (set! (~ ,local-scratch-vec 0) ,someVar))
      (local-barrier)
      (set! ,someVar (~ ,local-scratch-vec 0))))


```

### reduce-to-1-small

`(reduce-to-1-small someFunction <someVar> identity &optional localScratchVec globalScratchVec)`

`reduce-to-1-small` is much the same as `reduce-to-workgroup` but reduces all threads in all workgroups down to one single value.

HOWEVER, it has a caveat, in that the number of workgroups MUST NOT BE greater than `local_work_size`.  If this is
violated, this routine will runtime assert. However, remember that runtime asserts are only observable when 
the debug logging option has been elected when compiling. 

#### optional scratch vectors
This routine accepts two optional arguments.  `localScratchVec` and `globalScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` (or `vector-view`) that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / +warp-size+` ). `+warp-size+` is usualy 32.

`reduce-to-1-small` also accepts an optional `globalScratchVec`. Crisp will generate it for you if you do not provide it.  
If you want to provide it yourself, it should be a `vector` whose `element-type` is the same as `<someVar>` , 
its address space MUST be `:global` and it's size is the number of workgroups 
which can be calculated as `M` where `M = global_work_size / local_work_size`. 


- After the operation completes, the state of both `localScratchVec` and `globalScratchVec` are indeterminant. 
- `reduce-to-1-small` returns nil.
- `<someVar>` in thread 0 of workgroup 0 will hold the final value of the reduction
              this is the same as global linear thread id of 0.
              Its value is indeterminant in OTHER threads.

```
(let* ((global-scratch (make-scratch-vector ulong :global :read_write (ceil (get-global-work-size) (get-local-work-size))))
       (local-scratch (make-scratch-vector ulong :local :read_write (ceil (get-local-works-size) +warp-size+)))
       (someVar 1))
   (reduce-to-1-small #'+ someVar 0 local-scratch global-scratch)
   (when-global-linear-id-is 0
      ;; someVar will hold the total in this thread.
      ... ))

```

Possible Implementation
```
(defmacro reduce-to-1-small (someFunction someVar identity &optional (localScratchVec (funcall (gen-make-reduction-local-scratch-vec (type-of someVar) message)))
                                                               (globalScratchVec (funcall (get-make-reduction-global-scratch-vec (type-of someVar) message)))
                                                             &key message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  `(progn
    (declare (grid-level))
    (when-thread-is 0
      (r-t-assert (<= (get-num-groups) (get-local-work-size)) "number of groups cannot be larger than local_work_size for reduce-to-1-small"))

    ; after this the globalScratchVec will one value per group.
    (reduce-to-workgroup ,someFunction ,someVar ,identity ,localScratchVec)
    (when-thread-in-group-is 0
      (set! (~ ,globalScratchVec (get-group-id) ,someVar)))

    ; inter thread reduction.  Easiest and fastest if it fits in one warp,
    ; or one workgroup.
    (when-is-last-workgroup ()
      (let ((N (length~ ,globalScratchVec))
            (l-w-s (get-local-work-size)))
        (declare (uniform N l-w-s))
        (cond+  ((< N +warp-size+)
                  (let* ((lane-id (get-lane-id))
                        (var (if (< lane-id N) (~ ,globalScratchVec lane-id) ,identity))))
                    (reduce-to-warp ,someFunction var ,identity N)
                    ; Broadcast to all threads in wg
                    (when-thread-in-group-is 0
                      (set! (~ ,local-scratch-vec 0) ,someVar))
                    (local-barrier)
                    (set! ,someVar (~ ,local-scratch-vec 0)))
                ((< N l-w-s)
                  (let* ((local-id (get-local-id))
                        (var (if (< local-id N) (~ ,globalScratchVec local-id) ,identity))))
                    (reduce-to-workgroup ,someFunction var ,identity ,localScratchVec)
                    ; broadcast
                    (when (= local-id 0)
                      (set! (~ ,localScratchVec 0) var))
                    (local-barrier)
                    (set! ,someVar (~ ,localScratchVec 0))))))))
```

### reduce-to-1-atomic

`(reduce-to-1-atomic someFunction <someVar> identity return-vec &optional localScratchVec)`

`reduce-to-1-atomic` is much the same as `reduce-to-workgroup` but reduces all threads in all workgroups down to one single value.
That value is stored in `return-vec` which is a required argument. It should be a vector of length 1.

Unlike `reduce-to-1-small`, `reduce-to-1-atomic` can work across all threads and is not constrained by workgroup sizes.  
Instead `reduce-to-1-atomic` has a different limitation: `someFunction` must be one of three commutative operations: `+`, `min` or `max`
that have `atomic-XXXX!` counterparts.

- `#'+`
- `#'min`
- `#'max`

It is a compilation error to use it with any other operation. 

#### optional scratch vector
This routine accepts an optional scratch vector argument  `localScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` (or `vector-view`) that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / +warp-size+` ). `+warp-size+` is usualy 32.


- After the operation completes, the state of `localScratchVec` is indeterminant. 
- `reduce-to-1-atomic` returns nil.
- After the operation the value of  `<someVar>` in any thread is indeterminant.
- `result-vec` will hold the value of the reduction.


Possible Implementation
```
(defmacro reduce-to-1-atomic (someFunction someVar identity return-vec
                              &optional (localScratchVec (funcall (gen-make-reduction-local-scratch-vec (type-of someVar) message)))
                              &key message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (is-type-of someVar (element-type return-vec)) "type mismatch between someVar and return-vec")
  (c-t-assert (or (= someFunction #'+) (= someFunction #'min) (= someFunction #'max)) "only #'+, #'min or #'max are accepted operations for reduce-to-1-atomic")

  `(let ((atomic-op (get-atomic-equivalent ,someFunction)))
     (declare (grid-level))
    ; after this the globalScratchVec will one value per group.
    (reduce-to-workgroup ,someFunction ,someVar ,identity ,localScratchVec)

    ; atomic combination
    (when-thread-in-group-is 0
      (funcall atomic-op (~ ,return-vec 0) ,someVar)))) 
```

### reduce-to-1-cas

`(reduce-to-1-cas someFunction <someVar> identity return-vec  &optional localScratchVec)`

`reduce-to-1-cas` is much the same as `reduce-to-workgroup` but reduces all threads in all workgroups down to one single value.
That value is stored in `return-vec` which is a required argument. It should be a vector of length 1.

Unlike `reduce-to-1-atomic` , which only works with a few operations, `reduce-to-1-cas` can work with ANY commutative binary operation.
It does this via atomic compare and swap (via `atomic-binop!`) which, while flexible, might not always be the most performant solution.


#### optional scratch vector
This routine accepts an optional scratch vector argument  `localScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` (or `vector-view`) that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / +warp-size+` ). `+warp-size+` is usualy 32.


- After the operation completes, the state of `localScratchVec` is indeterminant. 
- `reduce-to-1-cas` returns nil.
- After the operation the value of  `<someVar>` in any thread is indeterminant.
- `result-vec` will hold the value of the reduction.



Possible Implementation
```
(defmacro reduce-to-1-cas (someFunction someVar identity return-vec
                              &optional (localScratchVec (funcall (gen-make-reduction-local-scratch-vec (type-of someVar) message)))
                              &key message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (is-type-of someVar (element-type return-vec)) "type mismatch between someVar and return-vec")
  `(progn
    (declare (grid-level))
    ; after this the globalScratchVec will one value per group.
    (reduce-to-workgroup ,someFunction ,someVar ,identity ,localScratchVec)

    ; atomic combination
    (when-thread-in-group-is 0
      (atomic-binop! (~ ,return-vec 0) ,someFunction ,someVar))))
```

### reduce-to-1-cont
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


#### optional scratch vectors
This routine accepts two optional arguments.  `localScratchVec` and `globalScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` (or `vector-view`) that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / +warp-size+` ). `+warp-size+` is usualy 32.

`reduce-to-1-cont` also accepts an optional `globalScratchVec`. Crisp will generate it for you if you do not provide it.  
If you want to provide it yourself, it should be a `vector` whose `element-type` is the same as `<someVar>` , 
its address space MUST be `:global` and it's size is the number of workgroups 
which can be calculated as `M` where `M = global_work_size / local_work_size`. 




Possible Implementation
```


(defmacro reduce-to-1-cont (someFunction someVar identity continuation-kernel-name layout
                                   &optional (globalScratchVec (funcall (gen-make-reduction-global-scratch-vec (type-of someVar) layout message)))
                                             (localScratchVec  (funcall (gen-make-reduction-local-scratch-vec (type-of someVar) layout message))))  
   (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
   (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
   `(let-kernel ((continuation-k  (l-s-v g-s-v result-vec)
                  (declare (kernel-name ,continuation-kernel-name)
                           (type l-s-v (local-scratch-vec-type (type-of ,someVar) ,layout))
                           (type g-s-v (global-scratch-vec-type (type-of ,someVar) ,layout))
                           (type result-vec (vector-type (type-of ,someVar) :global :writeable ,layout))
                           (local-size :derive-from g-s-v :msg (string-concat ,continuation-kernel-name "requires a local_work_size at least as big as the global-scratch-vector")))
                      (let* ((num-items (length~ g-s-v))
                            (local-id (get-local-id))
                            ;; Each thread in the workgroup loads one partial result.
                            ;; If there are more threads than items, inactive threads get the identity.
                            (val (if (< local-id num-items)
                                      (~ g-s-v local-id)
                                      ,identity)))
                        
                        ;; Perform a standard workgroup reduction on the partial results.
                        (reduce-to-workgroup ,someFunction val ,identity l-s-v)
                        
                        ;; The final result is now in 'val' of thread 0.
                        ;; Only thread 0 writes the final result to the output vector.
                        (when (= local-id 0)
                          (set! (~ result-vec 0) val))) ))
             
      ; after this the globalScratchVec will one value per group.
      (reduce-to-workgroup ,someFunction ,someVar ,identity ,localScratchVec)
      (when-thread-in-group-is 0
        (set! (~ ,globalScratchVec (get-group-id) ,someVar)))
      
       ;; this isn't a real invocation. It just demonstrates to the hoisting code 
       ;; HOW this function expects the "continuation" kernel to be called.
      (continuation-k ,globalScratchVec ,localScratchVec (make-result-vector (type-of ,someVar) 1))))  
      
```


reduce vector
-------------

The previous reductions are general purpose tools that let you create algorithms that reduce over warps, workgroups, or all the threads.  
The `reduce-vec-XXXX` variants are different in that they are respondent to a `vector` (or `vector-view` or a 1D `tensor-view`). 

All the vector reductions are "grid level" operations, meaning they cannot be nested in other grid level ops.

### reduce-vec-small

`(reduce-vec-small  someFunction vec identity &optional localScratchVec globalScratchVec)`

This variant has the same limitation as `reduce-to-1-small`: the number of workgroups MUST NOT BE greater than `local_work_size`.  If this is
violated, this routine will runtime assert. However, remember that runtime asserts are only observable when 
the debug logging option has been elected when compiling. 

#### optional scratch vectors
This routine accepts two optional arguments.  `localScratchVec` and `globalScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` (or `vector-view`) that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / +warp-size+` ). `+warp-size+` is usualy 32.

`reduce-vec-small` also accepts an optional `globalScratchVec`. Crisp will generate it for you if you do not provide it.  
If you want to provide it yourself, it should be a `vector` whose `element-type` is the same as `<someVar>` , 
its address space MUST be `:global` and it's size is the number of workgroups 
which can be calculated as `M` where `M = global_work_size / local_work_size`. 


- when `reduce-vec-small` completes, the state of the scratch vectors are indeterminant
- `reduce-vec-small` returns the result of the reduction.


This is what an implementation of `reduce-vec-small` might look like

```
(defmacro reduce-vec-small (someFunction vec identity 
                                        &optional (localScratchVec (funcall (gen-make-reduction-local-scratch-vec (element-type vec) message)))
                                                  (globalScratchVec (funcall (gen-make-reduction-global-scratch-vec (element-type vec) message)))
                                        &key message)
  (c-t-assert (is-type-of someFunction (binop-type (element-type vec))) "type mismatch between someFunction and vec")
  (c-t-assert (is-type-of (element-type vec) (type-of identity)) "type mismatch between vec and identity")
  `(progn
    (declare (grid-level))
    (when-thread-is 0
     (r-t-assert (<= (get-num-groups) (get-local-work-size)) "number of groups cannot be larger than local_work_size for reduce-vec-small"))
    (let ((sum ,identity)
          (len (length~ ,vec)))
      (declare (uniform len))
      (loop-grid-stride (x)
        (declare (grid-stride-target ,vec))
        (when (< x len)
          (set! sum (funcall ,someFunction sum (~ ,vec x)))))
      (reduce-to-1-small ,someFunction sum ,identity ,localScratchVec ,globalScratchVec)
      ;; The result is now in 'sum' of thread 0.
      ;; Return it to the caller.
      (return (shuffle sum 0)))))

```

### reduce-vec-atomic

`(reduce-vec-atomic  someFunction vec identity return-vec-global &optional localScratchVec)`

The `reduce-vec-atomic` variant has the same limitations as `reduce-to-1-atomic`: 
`someFunction` must be one of three commutative operations: `+`, `min` or `max`
that have `atomic-XXXX!` counterparts.

- `#'+`
- `#'min`
- `#'max`

#### optional scratch vector
This routine accepts an optional scratch vector argument  `localScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` (or `vector-view`) that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / +warp-size+` ). `+warp-size+` is usualy 32.


- After the operation completes, the state of `localScratchVec` is indeterminant. 
- `reduce-vec-atomic` returns nil.
- `result-vec` will hold the value of the reduction. It must be `:global` memory.


Possible Implementation
```
(defmacro reduce-vec-atomic (someFunction vec identity return-vec
                              &optional (localScratchVec (funcall (gen-make-reduction-local-scratch-vec (element-type vec) message)))
                              &key message)
  (c-t-assert (is-type-of someFunction (binop-type (element-type vec))) "type mismatch between someFunction and vec")
  (c-t-assert (is-type-of (element-type vec) (type-of identity)) "type mismatch between vec and identity")
  (c-t-assert (is-type-of (element-type vec) (element-type return-vec)) "type mismatch between vec and return-vec")
  (c-t-assert (or (= someFunction #'+) (= someFunction #'min) (= someFunction #'max)) "only #'+, #'min or #'max are accepted operations for reduce-to-1-atomic")
  `(let ((sum ,identity)
          (len (length~ ,vec)))
      (declare (uniform len) (grid-level))
      (loop-grid-stride (x)
        (declare (grid-stride-target ,vec))
        (when (< x len)
          (set! sum (funcall ,someFunction sum (~ ,vec x)))))
      (reduce-to-1-atomic ,someFunction sum ,identity ,return-vec ,localScratchVec)))
  
```


### reduce-vec-cas

`(reduce-vec-cas  someFunction vec identity return-vec &optional localScratchVec)`

This variant uses `reduce-to-1-cas` for the final reduction stage, which means than an
atomic compare and swap is used to force the order of the reduction. While this is most flexible
of the vector reductions, it might not always be the most performant solution. 

- After the operation completes, the state of `localScratchVec` is indeterminant. 
- `reduce-vec-cas` returns nil.
- `result-vec` will hold the value of the reduction. It must be `:global` memory.

Possible Implementation
```
(defmacro reduce-vec-cas (someFunction vec identity return-vec
                              &optional (localScratchVec (funcall (gen-make-reduction-local-scratch-vec (element-type vec) message)))
                              &key message)
  (c-t-assert (is-type-of someFunction (binop-type (element-type vec))) "type mismatch between someFunction and vec")
  (c-t-assert (is-type-of (element-type vec) (type-of identity)) "type mismatch between vec and identity")
  (c-t-assert (is-type-of (element-type vec) (element-type return-vec)) "type mismatch between vec and return-vec")
  `(let ((sum ,identity)
          (len (length~ ,vec)))
      (declare (uniform len) (grid-level))
      (loop-grid-stride (x)
        (declare (grid-stride-target ,vec))
        (when (< x len)
          (set! sum (funcall ,someFunction sum (~ ,vec x)))))
      (reduce-to-1-cas ,someFunction sum ,identity ,return-vec ,localScratchVec)))
  
```

### reduce-vec-cont

`(reduce-vec-cont  someFunction vec identity continuation-kernel-name &optional localScratchVec globalScratchVec)`

This variant uses `reduce-to-1-cont` to perform the final reduction of the vector.  A second "continuation kernel"
will be generated to complete the reduction operation.

Possible Implementation
```
(defmacro reduce-vec-cont (someFunction vec identity continuation-kernel-name
                                        &optional (localScratchVec (funcall (gen-make-reduction-local-scratch-vec (element-type vec) message)))
                                                  (globalScratchVec (funcall (gen-make-reduction-global-scratch-vec (element-type vec) message)))
                                        &key message)
  (c-t-assert (is-type-of someFunction (binop-type (element-type vec))) "type mismatch between someFunction and vec")
  (c-t-assert (is-type-of (element-type vec) (type-of identity)) "type mismatch between vec and identity")
  `(let ((sum ,identity)
          (len (length~ ,vec)))
      (declare (uniform len) (grid-level))
      (loop-grid-stride (x)
        (declare (grid-stride-target ,vec))
        (when (< x len)
          (set! sum (funcall ,someFunction sum (~ ,vec x)))))
      (reduce-to-1-cont ,someFunction sum ,identity continuation-kernel-name  ,localScratchVec ,globalScratchVec)))
```

### generating scratch vectors

As mentioned earlier, some reductions accept optional scratch vector arguments, and if unspecified, Crisp
will generate them for you.  But the functions Crisp uses are available to you.
To help reduce errors and bookkeeping, Crisp provides two templated functions which can help generate them:
`make-reduction-local-scratch-vec` and `make-reduction-global-scratch-vec`

To use them, you'll need to generate the function you want for some particular element type using the `gen-` prefix.
The generators accept a type (`T`) argument and an optional comment message (`M`). The comment message is important
because it will appear the hoisting code informing where/why such-and-such amount of memory has to be allocated.


Example:
```
(let ((local-float-s-v (gen-make-reduction-local-scratch-vec float "scratch memory for the workgroup reduction on illumination scalars"))
      (scratch-vec (local-float-s-v)))
    ;; assume there is some variable named "illumination"
   (reduce-to-workgroup #'* illumination scratch-vec)
   ...)
```

Here is an example of how those functions might be implemented.

```
(with-template-type (T &optional (M ""))
  (def-function make-reduction-local-scratch-vec ()
    (let ((local-scratch-size (ceil (get-local-work-size) (get-warp-size)))) ;; or just (get-num-warps) right?
      (make-scratch-vector T :local :read_write local-scratch-size :name "make-reduction-local-scratch-vec" :comment M))))

(with-template-type (T &optional (M ""))
  (def-function make-reduction-global-scratch-vec ()
    (let ((global-scratch-size (ceil (get-global-work-size) (get-local-work-size)))
      (make-scratch-vector T :global :read_write global-scratch-size :name "make-reduction-global-scratch-vec" :comment M )))))
```


### binop-type

`binop-type` is a type constructor that takes a type `T` and returns the function type `#(T T => T)`.


#### Commutativity
Note that unlike `reduce` in some other languages that are meant for CPUs as opposed to GPUs, the `reduce-` variants in Crisp do not guarantee any sort of order for execution. 
This means that non-commutative operations like subtraction and division will not work.
But they still work fine with commutative operations like addition, multiply, minimum and maximum. 
Additionally any function defined with `def-function` can be used with the reduction, but it will only work
correctly if it is commutative, where  `(someF a b)` is equivalent to `(someF b a)`. 



Filtering / Prefix-Sum Scan
============================

A common activity on the GPU is to "find all matches".  Crisp has several macros and functions that
can help with that.  Most prominent is the support for "prefix-sum scans" such as "exclusive scan" and
"inclusive scan".  
In these operations, a vector that consists of matches (1) and misses (0) is converted
into a vector that counts "how many before".  And a vector in "prefix sum scan" format is easy to 
then parse to a compact short list of results.  The "word count" example below illustrates.

`exclusive-scan`
----------------
The purpose of `exclusive-scan` is to, for each element in a vector, calculate the sum of all the elements
that came before it.  The input vector is a vector of 0s and 1s (where 1 represents a "match"). The input
vector cannot be longer than the kernel work size.

`exclusive-scan` modifies the vector in place.  It returns the final sum of the scan.

### Example

Let's assume there a mere 6 threads in a workgroup. Our algorithm finds some match or miss and
records in a vector, each match or miss stored at the local id of whatever thread did the check.
Our vector has two states, the "input" state before `exclusive-scan` is run, and its modified output state
once `exclusive-scan` is complete. 

`(exclusive-scan match-vector)`

```
Input:  #(0 1 0 1 1 0)
Output: #(0 0 1 1 2 3)
```
If you look at the output, the value at each "match" position tells you exactly how many matches came before it:
  Thread 1: Its output is 0. There were 0 matches before it.
  Thread 3: Its output is 1. There was 1 match before it (at index 1).
  Thread 4: Its output is 2. There were 2 matches before it (at indices 1 and 3).
This output gives each "winner" its unique, zero-based local index (0, 1, 2)


`inclusive-scan`
----------------

The sister to `exclusive-scan`, its output at any index is the sum of the elements up to _and including_ `i`.

```
Output: #(0 1 1 2 3 3)
```

### Possible Implementation

This is a possible implementation of `exclusive-scan` realized via a Belloch Scan:

```
(defmacro exclusive-scan (local-vec)
  `(let ((local-id (get-local-id))
         (wg-size (get-local-linear-size)))
     
     ;; first pass - the up-sweep (reduction tree)
     ;; In each step, we add the value from 2^d elements away.
     (do-power-step (stride wg-size)
      (when (>= local-id stride)
        (set! (~ ,local-vec local-id)
              (+ (~ ,local-vec local-id)
                (~ ,local-vec (- local-id stride)))))
       (local-barrier))

     ;; The last element now holds the total sum. We save it and clear
     ;; that slot to start the exclusive scan.
     (let ((total-sum (~ ,local-vec (- wg-size 1))))
       (when (= local-id (- wg-size 1))
         (set! (~ ,local-vec local-id) 0))
       (local-barrier)

       ;; second pass - down sweep
       ;; Now we work back down the tree, distributing the sums.
       (dec-power-step (stride wg-size)
        (when (>= local-id stride)
          ;; Swap and add values between a thread and its partner
          (let ((partner-idx (- local-id stride)))
            (let ((temp (~ ,local-vec partner-idx)))
              (set! (~ ,local-vec partner-idx) (~ ,local-vec local-id))
              (set! (~ ,local-vec local-id) (+ temp (~ ,local-vec local-id))))))
         (local-barrier))

       ;; The macro can return the total sum from the workgroup
       total-sum)))
```

Word Count With Exclusive Scan
------------------------------

```

(def-type text-t (vector-type uchar :global :readable :std140))
(def-type index-t (vector-type ulong :global :writeable :std140))
(def-kernel word_count (corpus word result)
 (declare #(text-t text-t index-t => nil))
  (let ((local-wg-matches (make-scratch-vector uint :local :read_write :std140 (local-work-size)))
        (local-id (get-local-id))
        (global-counter 0)
        (wg-offset 0)
        (is-a-match nil))
     (declare (global-mem global-counter :return-value) (local wg-offset)) ;;
     (with-global-linear-id (i)
      ;; STEP 1: local match detection
      (set! is-a-match (look-for-word-at corpus i))
      (set! (~ local-wg-matches (get-local-linear-id)) word-match) ;might need convert between bool->int to be explicit?
      (local-barrier)
      ;; local-wg-matches = #(0 1 0 1 1 0 ...)

      ;; STEP 2: Reorder
      (let ((count (exclusive-scan local-wg-matches)))
            ;; local-wg-matches is now #(0 0 1 1 2 3)

        ;; STEP 3 - get global write offset
        (when-thread-in-group-is 0
          ;; add this workgroups count to global
          (set! wg-offset (atomic-add! global-counter count))))
      
      ;; STEP 4 - write results to global memory
      (local-barrier)

      (when is-a-match
        (let ((final-write-pos (+ (~ local-wg-matches local-id) wg-offset)))
           (set! (~ result final-write-pos) i))))))

```

`filter`
-------
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

### possible implementation of filter
```
(defmacro filter (input-vec predicateF result-vec)
  (c-t-assert (is-type-of predicateF (predicate-type (element-type input-vec))) "type mismatch between predicateF and input-vec")
  (c-t-assert (is-type-of (element-type input-vec) (element-type result-vec)) "type mismatch between input-vec and result-vec")
  `(let ((local-wg-matches (make-scratch-vector uint :local :read_write :std140 (get-linear-work-size)))
        (local-id (get-local-id))
        (global-counter 0)
        (wg-offset 0)
        (is-a-match nil))
     (declare (global-mem global-counter) (local wg-offset) (grid-level))
     (with-global-linear-id (i)
      ;; STEP 1: local match detection
      (set! is-a-match (when (< i (length~ ,input-vec)) (funcall predicateF (~ ,input-vec i)))
      (set! (~ local-wg-matches (get-local-linear-id)) (select-if is-a-match 1 0))
      (local-barrier)
      ;; local-wg-matches = #(0 1 0 1 1 0 ...)

      ;; STEP 2: Reorder
      (let ((count (exclusive-scan local-wg-matches)))
            ;; local-wg-matches is now #(0 0 1 1 2 3)

        ;; STEP 3 - get global write offset
        (when-thread-in-group-is 0
          ;; add this workgroups count to global
          (set! wg-offset (atomic-add! global-counter count))))
      
      ;; STEP 4 - write results to global memory
      (local-barrier)

      (when is-a-match
        (let ((final-write-pos (+ (~ local-wg-matches local-id) wg-offset)))
          (when (< final-write-pos (length~ ,result-vec))
           (set! (~ ,result-vec final-write-pos) (~ ,input-vec i)))))))
      (return global-counter)))
```

Sorting
=======

Bitonic Sort 
------------

Crisp provides a "toolkit" for bitonic sort.  If the sort can be performed by a single workgroup, then there are functions for that.
But if the sort is occurring across a vector larger than than, then a multi-stage approach is required.


In the first stage, you hoist/enqueue a kernel which will invoke one of the `bitonic-sort-workgroup` functions. Crisp provides premade kernel definitions for this if you require no other processing.

In the second stage, you hoist a `bitonic_merge_pass` kernel repeatedly until the sort is completed.

### psuedo demonstration

#### generate the kernels
```
;; generate kernel that sorts in place a vector of floats using :std140 alignment
(gen-bitonic_sort_workgroup_in_place float :std140 "stage_one_kernel")

;; generate the merge kernel
(gen-bintonic_merge_pass float :std140 "stage_two_kernel")
```

#### load and enqueue the first kernel

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
# (Assuming the runtime handles marshalling to std140 if needed)
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

#### loop the second kernel

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


### `bitonic-sort-workgroup`

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
  (def-function bitonic-compare-and-swap (local-vec idx1 idx2 direction &optional (keyF nil))
    (declare #((vector-type T) ulong ulong bool &optional #(T => U) => nil))
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
  (def-function bitonic-sort-workgroup (data-in data-out &key keyF)
    (declare (local-size :set-to 256 :msg "local-work-size should be a power of 2 for bitonic-sort-workgroup")
             #((vector-type T :global :readable) (vector-type T :global :writeable) 
                &key #'(T => #_is-orderable?) => nil))
    (let ((N   (get-local-linear-size)) ;; should be power of 2.
         (shared-array (make-scratch-vector T :local :read_write :std140 N))
         (global-id (get-global-id))
         (local-id (get-local-id)))
      (r-t-assert-0 (is-power-of-2 N) "local_work_size should be a power of 2")
      ;; load data from global to shared memory 
      ;; Each thread loads one element. For simplicity, assume N = global_size
      (when (< global-id N) ;; Boundary check for global data
        (set! (~ shared-array local-id) (~ data-in global-id)))
      (local-barrier)

      ;; perform Bitonic Sort
      ;; Outer loop: Builds increasingly large bitonic sequences
      ;; 'j' represents the size of the bitonic sequence being formed
      (do-power-step (j N)  ; Iterates j = 1, 2, 4, ... N/2
        ;; Inner loop: Merges bitonic sequences of size 'j'
        ;; 'k' represents the sub-sequence length to compare (j/2, j/4, ... 1)
        (dec-times-by-half (k (/ j 2))
          ;; Determine sorting direction for this phase
          ;; The first half of the sequences sort ascending, second half  descending
          (let* ((direction (> (bit-and local-id (+ j j)) 0))) ; Determines if this half sorts UP or DOWN
                (partner-id (bit-xor local-id k))) ; Partner is 'k' distance away

            (when (< partner-id N) ; Ensure partner ID is within bounds (for non-power-of-2 sizes)
              (bitonic-compare-and-swap shared-array local-id partner-id direction keyF))) 
          (local-barrier)))

      ; store sorted data from shared to global memory
      (when (< global-id N) ;; Boundary check for global data
        (set! (~ data-out global-id) (~ shared-array local-id)))
      (local-barrier)))

;; in place sorting
(with-template-type (T A)
  ;; Constraint relaxed: T only needs to be orderable IF keyF is NOT provided.
  ;; The compiler/constraint system needs to handle this conditional constraint.
  (declare (value-is A #'is-alignment?))
  (def-function bitonic-sort-workgroup! (data &key keyF)
    (declare #((vector-type T :global :read_write A) &key (function T => #_is-orderable?) => nil))
    (bitonic-sort-workgroup data data :key keyF)))


;; Kernels. These don't use the key. Define your own if you need to set one.
(with-template-type (T A)
  (declare (type-is T #'is-orderable?) (value-is A #'is-alignment?))
  (def-kernel bitonic_sort_workgroup (data-in data-out)
    (declare #((vector-type T :global :readable) (vector-type T :global :writeable) => nil))
    (bitonic-sort-workgroup data-in data-out)))
    
(with-template-type (T A)
  (declare (type-is T #'is-orderable?) (value-is A #'is-alignment?))
  (def-kernel bitonic_sort_workgroup_in_place (data)
    (declare #((vector-type T :global :read_write) => nil))
    (bitonic-sort-workgroup! data)))
```

### `bitonic_merge_pass`

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
   (gen-bintonic_merge_pass ulong :std140 "my_bintonic_merge_pass_kernel")
```



Possible Implementation

```
(with-template-type (T A)
  ;; Constraint relaxed: T only needs to be orderable IF keyF is NOT provided.
  ;; The compiler/constraint system needs to handle this conditional constraint.
  (declare (value-is A #'is-alignment?)) 
  (def-function bitonic-merge-pass (data j k &key keyF)
    (declare #((vector-type T :global :read_write A) ulong ulong &key #'(T => #_is-orderable?) => nil))

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
  (def-kernel bitonic_merge_pass (data j k)
    (declare #((vector-type T :global :read_write A) ulong ulong => nil))
    (bitonic-merge-pass data j k)))
```

### Don't Make Me Think `gen-bitonic-sort-vector`

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
  (def-kernel bitonic_sort_vector_in_place (vec)
    (declare #((vector-type T :global :read_write L)))
    (bitonic-sort-workgroup vec vec)))



(with-template-type (T L)
  (def-orchestration bitonic-sort-vector!
    (launch-sequential (gen-bitonic_sort_vector_in_place T L "bitonic_sort_vector_in_place_${T}_${L}"))

    ; +wg-size+ is available as a constant in def-orchestration

    (do-times-by-doubling (j (* 2 +wg-size+))
      (do-times-by-half (k (/ j 2))
        (launch-sequential ((gen-bitonic_merge_pass T L "bintonic_merge_pass_${T}_${L}")
                              bitonic_sort_vector_in_place_T_L::vec j k))))))


```


Radix Sort
----------

Like Bitonic Sort, Radix Sort is done with multiple kernels, but its structure is a loop 
of "histogram-scan-scatter" passes, not "sort-merge-merge-merge..." like bitonic.

The easiest way to understand Radix Sort is to think of it like sorting a huge pile of mail by zip code. You don't compare two envelopes directly. Instead:
- You first create piles for the last digit of the zip code (0-9).
- You go through all the mail, putting each envelope in the correct pile.
- You stack the piles back together in order (all the 0s, then all the 1s, etc.).
- You then repeat the entire process for the second-to-last digit, and so on, until the mail is fully sorted.

Radix Sort does this with the bits of your numbers.  It loops over three kernels: histogram, prefix-sum, and scatter.

### Radix Sort on the GPU

The entire process is a loop that has to be organized host side. For a 32-bit integer, you might loop 4 times, processing 8 bits in each pass. Inside this loop, the host orchestrates a sequence of kernel launches.

#### Step 1: The Histogram Kernel
The first kernel's job is to count the occurrences of each "digit" across the entire dataset.

How it works: Each workgroup computes a local histogram (e.g., a 256-element array for an 8-bit pass) in its fast shared memory. The leader of each workgroup then uses atomic-add! to add its local counts to a small global histogram buffer.

Result: A small array in global memory with the total count for each digit.

#### Step 2: The Prefix-Sum (Scan) Kernel
The second kernel's job is to turn the histogram counts into bucket offsets. It answers the question, "Where does the bucket for digit X begin in the final output array?"

How it works: Since the global histogram is very small (e.g., 256 elements), this is a tiny, fast kernel, often launched with just a single workgroup. It performs an exclusive scan on the histogram. (This step can sometimes even be done on the host CPU because the data size is negligible).

Result: A small array of "bucket pointers" in global memory.

#### Step 3: The Scatter (or Permute) Kernel
The third kernel's job is to actually move the data.

How it works: Each thread reads an element, looks at its current "digit," uses the bucket pointers from Step 2 to find the base address for that digit, and then uses a local counter to find its specific place within that bucket. It then writes the element to a new output buffer.

Result: A new global buffer where the data is sorted according to the current group of bits.

This new output buffer then becomes the input buffer for the next pass of the host-side loop. This is often called "ping-ponging" between two large buffers. After the final pass (on the most significant bits), the data is fully sorted.

### Radix Sort in Crisp


#### `histogram-pass`
```
 (histogram-pass input-vec global-histogram bit-offset &optional local-histogram)
```

 - this routine requires that the `local_work_size` is set to 256
 - similarly the `global-histogram` vector parameter must consist of 256 `uint`
 - the `local-histogram` scratch vector is optional, it should be 256 `uint` as well. If not provided,
  Crisp will use the scratch vector side channel to fulfill it.


Possible Implementation
```
(def-constraint is-signed-integer? (T)
   (and (is-signed? T) (is-integer? T)))

(with-template-type (T A)
  (declare (type-is T #'is-numeric?) (value-is A #'is-alignment?))
  (def-grid-function histogram-pass (input-vec global-histogram bit-offset &optional (local-histogram (make-scratch-vector uint :local A 256))
    (declare #((vector-type T :global :readable A) (vector-type uint :global :read_write A 256) uint => nil)
              (local-work-size :set-to 256 :msg "local_work_size must be 256 for histogram kernel"))
              
    ;; setup
    (let ((local-id (get-local-id))
          (local-size (get-local-size)))

      ;; initialize local histogram
      ;; The workgroup must zero-out its local histogram. This is done in parallel.
      ;; Each thread clears a portion of the 256-element array.
      (set! (~ local-histogram local-id) 0)
      (local-barrier)

      ;; build local histogram
      ;; Each thread processes its slice of the large input vector.
      ;; note we have to handle floats and unsigned digits special to make sure 
      ;; they are bit-wise evaluable. 
      (loop-vector-stride input-vec (i)
        ;; a. Get the value from the input vector.
        (let* ((initial-val (~ input-vec i))
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
      (local-barrier)

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





Atomics
=======
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


Atomic Operations
-----------------
Crisp provides a number of built-in atomic operations that perform their work on shared memory locations. Each function is guaranteed to be a single, indivisible transaction.  Each one updates some variable in place and returns the value at the location BEFORE the modification occured.

### atomic-add!
Adds a value to a memory location, updating it. This routine returns the value BEFORE this modification. This "fetch-and-add" behavior is the classic parallel reduction primitive.

Syntax: `(atomic-add! location delta)`

Example: `(let ((old (atomic-add! (~ result 0) 1))) ...)`
 This example adds 1 to the first element of the result vector. The variable `old` will
 have whatever was in `(~ result 0)` before the addition occured.

### atomic-sub!
Subtracts a value from a memory location, updating it. This routine returns the value BEFORE this modification..

Syntax: `(atomic-sub! location delta)`

Example: `(let ((old (atomic-sub! (~ total-vec 0) 1))) ...)`
This example decrements a shared counter. `old` will be set to whatever was there BEFORE the modification.

### atomic-inc!
Atomically increments a memory location by 1.  Returns the value there previously.

Syntax: `(atomic-inc! location)`

Example: `(let ((old (atomic-inc! (~ counter-vec 0)))) ...)`

### atomic-dec!
Atomically decrements a memory location by 1. Returns the value there previously.

Syntax: `(atomic-dec! location)`

Example: `(let ((old (atomic-dec! (~ tasks-vec 0)))) ...)`

### atomic-min!
Compares a value at a memory location with a new value and stores the minimum of the two. Returns the value there previously.

Syntax: `(atomic-min! location new-value)`

Example: `(let ((old (atomic-min! (~ min-across-threads-vec 0) local-min))) ...)`

### atomic-max!
Compares a value at a memory location with a new value and stores the maximum of the two. Returns the value there previously.

Syntax: `(atomic-max! location new-value)`

Example: `(let ((old (atomic-max! (~ max-across-threads-vec 0) local-max))) ...)`

### atomic-xchg!
Atomically exchanges the value at a memory location with a new value and returns the old value.  It does this UNCONDITIONALLY. 

Syntax: `(atomic-xchg! location new-value)`

Example: `(let ((old-value (atomic-xchg! (~ thread-lock-vec 0) 1))) ...)`

### atomic-binop!
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

### atomic-op!
Syntax: `(atomic-op! location op-f)`

Uses an atomic CAS (Compare and Swap) under the hood. 
`atomic-op!` calls a unary function `#(T => T)` with the value at `location`
and then store the result back to `location`. This is a CONDITIONAL exchange.
Returns the value there previously.

Example: `(let ((old-value (atomic-op! (~ global-counter 0) #'plus-ten))) ...)`

### atomics and grid level operations

Using any atomic operation on `:global` memory makes the containing function or macro into a 
grid level operation.  The compiler will emit an error if attempted in the thread level context
of a `def-function`. Use `def-grid-function` instead. 
 If writing a `defmacro`, be sure to include `(declare (grid-level))` in its `progn` 
expansion. 



<!--

THIS IS BEING REMOVED.  

### atomic-cas!
(Compare-and-Swap) Compares the value at a memory location with an expected value. If they are the same, it writes a new value. The old value is always returned. This is the most powerful atomic primitive and can be used to build any other atomic operation.

Syntax: `(atomic-cas! location expected-value new-value)`

Example: `(atomic-cas! (~ current-value-vec 0) 0 1)`
-->

### Example: Summing a Vector to One Value.

The last time we summed a vector, our result vector had M entries, one for each workgroup 
which the host was exected to sum up. 

This time, our result vector only needs to have space for one entry. Each thread-0 of each
workgroup will add its sum to the first element of the result vector.
( It mightn't be the worst idea to make sure that it's value is 0 before hoisting) 

```
;; 32 warps maximum for most hardware
(def-constant +warp-size+:ulong 32)

;; the source vector can be any size. 
(def-type source-vec (vector-type long :global :readable))     

;; the final result vector is just has 1 long value
(def-type result-vec (vector-type long :global :writeable :length 1)) 

(def-function calculate-this-thread-sum (A:source-vec)
  (declare #(source-vec -> long) (grid-level))
  (let ((sum:long 0))
    (loop-vector-stride A (i)
      (inc! sum (~ A i))))) ; <-- inc! implicity returns final sum

(def-kernel sum_vector_warp_to_one (A:source-vec Res:result-vec)
    (declare (local-size :set-to +warp-size+ ...)
             (global-size :derive-from A))

    (let ((sum (calculate-this-thread-sum A)))
        (in-warp (lane-id)
            (dec-times-by-half+ (s (/ +warp-size+ 2))
                (inc! sum (shuffle-xor sum s))))
    
    ;; Final reduction to a single value
    (when-thread-in-group-is (0)
        ;; Use atomic-add to contribute this workgroup's sum to the final result
        (atomic-add! (~ Res 0) sum))))
```


Vector and Tensor Operations
============================

dot product
-----------

The "dot product" is an operation that takes two vectors of the same length
and returns a single scalar number. It's the sum of the products of the corresponding
entries of the two sequences of number. 
Mathematically, for two vectors A and B, the dot product is:
<!-- latex -->
$$A \cdot B = \sum_{i=1}^{n} A_i B_i = A_1B_1 + A_2B_2 + \cdots + A_nB_n$$

I can be thought of as a measure of how much one vector "points in the direction" of another. 
If two vectors are perpendicular, their dot product is zero. If they point in the same direction, their dot product is maximized.

### dot-prod-grid / dot-prod-seq

```
(dot-prod-grid A B RESULT)
(dot-prod-seq A B)
```

Crisp provides two variants of the dot product function. `dot-prod-grid` is a grid level
function that uses a grid stride and a reduction to quickly calculate the dot product using
all available threads simultaneously. 

`dot-prod-seq` is a thread level sequential function that simply loops in the current thread.

Both accept two matrix arguments. They can
be a `vector`, `vector-view` or a 1D `tensor-view`.  Note that `dot-prod-grid` should be
coalesced automatically for `vector` and `vector-view` arguments. But not
necessarily for `tensor-view`.  A row of a row-major `matrix` would be fine, but
the col or a row-major `matrix` would not be able to have coalesced memory copy.

The `RESULT` argument for `dot-prod-grid` should be a `:global` writeable vector. The
result will be written to index 0.

There are possible implementations below, with the implementations of `matmul`

matrix multiplication (matmul)
-------------------------------

Matrix multiplication (`matmul`) is an operation that takes two matrices and produces a new matrix.
Each element in the resulting matrix is the dot product of a row from the first matrix and a column from the second matrix. 
It's the fundamental operation for transforming data in linear algebra, used for tasks like 
rotating and scaling vectors in 3D graphics or applying weights in a neural network.

### matmul

`(matmul A B)`

Crisp provides a `matmul` function. It takes two arguments, they are both matrices,
which are just 2D `tensor-view`. Note using `matmul` requires that the calling kernel
is enqueued with an arity of 2.

Note also that the inner dimensions must match.  For example multipling
a `2x3` matrix by a `3x4` is allowed, because the "inner" number is `3`.
But conversely, multiplying a `3x4` by a `2x3` matrix is NOT allowed because
the inner dimension (`4` and `2`) are not equal.


### OPTIMIZING DEMONSTRATION

Below are possible implementations of dot product and `matmul`

Note that the `matmul-naive` implementation is easy to write and understand
but is not maximally performant. It may not always use coalesced access
and it makes too many "small" writes to global memory.

But the `matmul` implementation below it solves both of those problems
simply by using tiles.  The `load-tile` macro is, once again, demonstrating
its value.

``` 
(with-template-type (T)
  (declare (type-is T #'is-scalar? T))                      
  (def-grid-function dot-prod-grid (A B RESULT)
    (declare #((vector-type T) (vector-type T) (vector-type T :global :writeable) => nil)) 
    (when-thread-is 0
      (r-t-assert (= (length~ A) (length~ B)) "lengths must match")) 
    (let ((C-scratch (make-scratch-vector A :name "dot product")))  
      (map-stride #'* (A B) C-scratch)
      (reduce-vec-atomic #'+ C-scratch 0 RESULT)

(with-template-type (T)
  (declare (type-is T #'is-scalar?))
  (def-function dot-prod-seq (A B)
    (declare #((vector-type T) (vector-type T) => T))

    (let ((sum:T 0))
      (dotimes (i (length~ A))
        (set! sum (+ sum (* (~ A i) (~ B i)))))
      (return sum))))

#|
  matmul-naive
  This is a very simple, easy to read version of matmul that uses
  loop-grid-stride and dot-prod-seq to easily multiply two matrices.
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
  (def-function matmul-naive (A B)
    (declare #(matrix matrix => matrix) (global-size :dims 2))
    (let ((inner-A (num-cols A))
          (inner-B (num-rows B))
          (outer-A (num-rows A))
          (outer-B (num-cols B)))
      (when-thread-is 0
        (r-t-assert (= inner-A inner-B) "inner dimensions must match!"))
      
      (let* ((vec (make-result-vector A (* outer-A outer-B)))
            (res (make-tensor-view vec outer-A outer-B )))
                (loop-grid-stride (x y)   
                  (declare (grid-stride-target outer-A outer-B))
                  (set! (~ res x y) (dot-prod-seq (row x A) (col y B)))) ;; <-- CANT CALL DOT PROD
                (return res)))))       

#|
  matmul - performant.
|#

;; same TILE_DIM as used by convert-layout 
(def-const TILE_DIM:ulong +warp-size+)

;; helpers (not fully defined yet)
;;   make-tile variants will call make-tile-scratch-vector themselves.
;; (make-tile-scratch-vector T)
;; (make-tile dim T) ;; <-- will do performance padding? Unsure.
;; (make-tile dim-y dim-x T) 

(with-template-type (T)
  (declare (type-is T #'is-scalar?))
  (def-function matmul (A B C)
    (declare #(matrix matrix matrix => nil) (global-size :dims 2))

    (let ((tile-A (make-tile TILE_DIM T))
          (tile-B (make-tile TILE_DIM T))
          (local-id-x (get-local-id 0)) (local-id-y (get-local-id 1))
          (group-id-x (get-group-id 0)) (group-id-y (get-group-id 1))
          (acc:T 0.0)) ; Per-thread accumulator register

      ;; main loop over the tiles in the inner dimension
      (dotimes (tile-num (ceil (num-cols A) TILE_DIM))

        ;; adaptive, coalesced loading
        ;; Use the 'load-tile' macro to handle the complexity.
        (load-tile A tile-A group-id-y tile-num
                   :transpose (= (get-layout A) :col-major))

        (load-tile B tile-B tile-num group-id-x
                   :transpose (= (get-layout B) :row-major))
        
        (local-barrier)

        ;; This part is now simple and fast, both local tiles are row-major.
        (dotimes (k TILE_DIM)
          (set! acc (+ acc (* (~ tile-A local-id-y k)
                              (~ tile-B local-id-x k)))))

        (local-barrier))

      ;; store final result. coalesced access
      (let ((c-row (+ (* group-id-y TILE_DIM) local-id-y))
            (c-col (+ (* group-id-x TILE_DIM) local-id-x)))
        (when (and (< c-row (num-rows C)) (< c-col (num-cols C)))
          (set! (~ C c-row c-col) acc))))))
                           
```

Arithmetic
==========

Integer Division
----------------

There are four  integer divison functions: `/`, `ceil` ,  `floor` and `round`.

All four of them return both the quotient and remainder and differ only 
in how the results are rounded.

`#(divisor divident => quotient remainder)`


### `/` truncating division

Operates the same as `/` in C++ or `truncate` in Common Lisp.  
This function rounds toward 0 and returns BOTH the quotient and the remainder.

```
(/ 10 3)   => 3 and 1

(/ -10 3)  => -3 and -1
```
Because this division operates the same as in C/C++, this division is familiar and
the "default".  But note that for many GPU numeric workloads, `floor` is more reliable
because its behavior is consistent on both the negative and positive side of the number line. 

### `floor`

This rounds the result down toward negative infinity. It returns the quotient and the remainder.
```
(floor 10 3)   => 3 and 1

(floor -10 3)  => -4 and 2
```

### `ceil`

This rounds the result up toward positive infinity. It returns the quotient and the remainder.
```
(ceil 10 3)   => 4 and -2

(ceil -10 3)  => -3 and -1
```

### `round`

In addition to the three above, there is also `round`. This performes division and rounds the quotient towards the nearest integer. If equidistant it "rounds half toward even" following the  IEEE 754 standard.  Like the others, it returns both the quotient and the remainder. 

```
(round 5 2 ) => 2 and 3.  2.5 is rounded DOWN towards the nearest even integer, which is 2
(/ 7 2)      => 3 and 4   Notice how the truncating / differs from round (below).
(round 7 2)  => 4 and 3   3.5 is rounded UP towards the nearest even integer, which is 4.  
(round 8 2)  => 4 and 0
(round 9 2)  => 4 and 5   4.5 is rounded DOWN towards the nearest even integer, which is 4. 
```

### Comparison

|Function	    | Behavior	  | (func 10 3) | (func -10 3)|
|-------------|--------------------|--------|--------|
| (/ a b)     |	Rounds toward zero |	3, 1  |	-3, -1 |
| (floor a b) |	Rounds toward -∞   |	3, 1  |	-4, 2  |
| (ceil a b)	| Rounds toward +∞   |	4, -2 |	-3, -1 |
| (round a b) | Rounds nearest neighbor | 3, 1 | -3, -1 | 


Builtin GPU Functions & Constants
=================================

- get-num-warps
- get-warp-id     index of warp WITHIN its workgroup
- get-lane-id     thread index within warp
- get-work-dim    number of dimensions the kernel was launched with 

- get-local-id   x y z     thread index inside workgroup
- get-local-work-size => (x y z)   size of workgroup

- get-workgroup-id x y z   index of group 
- get-num-groups => (x y z)     total number of workgroups

- get-global-id  x y z     thread index within all threads. always starts at 0
- get-global-id-abs x y z    absolute thread index. (equals get-global-id + get-global-offset)
- get-global-work-size => (x y z) 
- get-global-offset => (x y z)

- get-local-linear-id
- get-local-linear-size      
- get-global-linear-id
- get-global-linear-size
- get-total-threads   (same as get-global-linear-size)
- +warp-size+

- local-barrier
- mem-fence 
- sync-warp 

- get-timestamp   returns the high resolution clock counter. ( %clock64 register).

Forgotten
==========
- when-thread-in-warp-is 





Logging and Debugging
=====================

When a kernel is running on a GPU it is often on a different device, with a completely different memory and addressing system and no 
access to stdout or the file system. This makes debugging and logging challenging. Crisp attempts to assist with two different systems:
 - compile-time messaging, so that the compiler can be directed to output messages and information. 
 - side channel logging at runtime.  This has to be elected when compiling your kernel and the hoisting/enqueue code has to participate as well.

### `c-t-output`  

`(c-t-output <expr1> ... <exprN>)`
"c-t" stands for "compile time".  This variadic macro just takes a series of expressions and it will evaluate them at compile time and output them when compiling.   This can be particularly handy when used with `macroexpand` or `macroexpand-1`. A space character is inserted between each expression. If any of the expressions is
not evaluable at compile time that will merely be noted. 

### `c-t-assert`

`(c-t-assert <testExpression>  <expr1> ... <exprN>)`
This is akin to `static_assert` from C. The `<testExpression>` will be evaluated by the compiler. If it is true then
the compilation continues undisturbed.  But if it is false, then the compiler errors and ceases commpilation. The remaining arguments are output along with the error, separated by spaces. If one of the remaining expressions is
not evaluable at compile time that'll be noted in the output. 

If `<testExpression>` is not evaluable at compile time, it will lead to a compilation error.



### `r-t-workgroup-output-if`

`(r-t-workgroup-output-if <testExpression>  <expr1> ... <exprN>)`

`<testExpression>` is reduced across all the threads in a workgroup. If it is true in any of them,
then the the logging occurs in just one of them. Afterwards, kernel execution continues normally.


### `r-t-workgroup-assert`

`(r-t-workgroup-assert <testExpression>  <expr1> ... <exprN>)`

Akin to `assert` in C.  If the kernel is compiled with the `--debug-output` flag then this macro will result in an evaluation of `<testExpression>`. If true, fine.  If false, then the other expressions are output into the debug log
and then the kernel halts across all threads. The exact mechanism for halting is implementation dependent, typically a
`__trap()` or `assert()` but for some hardware there may be NO halting mechanism in which case the kernel just
continues to run until it finishes. ( Good luck with that ).

Note that `<testExpression>` reduced across all the threads in a workgroup. If it is true in any of them,
then the the logging occurs in just one of them and afterwards the halt.  So `r-t-workgroup-assert` is protected
from "firehose" problems.

### `r-t-output`

`(r-t-output <expr1> ... <exprN>)`
"r-t" stands for "run time".  If the kernel is compiled with the `--debug-output` flag then this macro will output
each of its expressions into the debug output memory. Note that this output will have to be retrieved by the hoisting 
code once the kernel is done executing. 
If the `--debug-output` flag is NOT present when the kernel is compiled, then this expression and all arguments
are simply skipped by the compiler. 

#### WARNING - FIREHOSE
If `r-t-output` appears loose in your kernel, it will almost certainly result in thousands of threads simultaneously
trying to dump string into a debug buffer. To avoid this either use `r-t-workgroup-output-if` instead, or 
surroud `r-t-output` in one of the thread guards.

```
(when-thread-is 0
   (r-t-output "reached midpoint" someVal))
```

### `r-t-assert`
```
(r-t-assert <testExpression>  <expr1> ... <exprN>)
(r-t-assert-0 <testExpression>  <expr1> ... <exprN>)
```

Akin to `assert` in C.  If the kernel is compiled with the `--debug-output` flag then this macro will result in an evaluation of `<testExpression>`. If true, fine.  If false, then the other expressions are output into the debug log
and then the kernel halts across all threads. 

The variant `r-t-assert-0` uses the `when-thread-is 0` guard and so the 
check and output is only performed in one thread.

#### WARNING - FIREHOSE
If `r-t-assert` appears loose in your kernel, it will almost certainly result in thousands of threads simultaneously
trying to dump string into a debug buffer. To avoid this either use `r-t-workgroup-assert` instead, or `r-t-assert-0`, or
surroud `r-t-assert` in one of the thread guards.

```
(when-thread-is 0
   (r-t-assert (< 0 lives) "no lives left"))
```

Logging Utilities
-----------------

- `(line)`  evaluates at compile-time to the line number of the file where it appears.
- `(file)`  evaluates at compile-time to the name of the .crisp file where it appears.


Conditional Compilation
=======================

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
And `C` would also NOT be defined, because  `0` does puns as false.

And, the following compilation line would reverse those completely:
```
crisp.exe -Dfull_ride=nil -Dsleigh_ride=T -Dover_ride=1  ... etc
```


### another example

```
(def-function calculate (x)
  (declare #(float => float))
  (let (#+(target-has :fp64)
        (precision   (get-high-precision-v))

        #-(target-has :fp64)
        (precision   (get-low-precision-v)))
      ...))

```
See below for `target-has`.

defmacro 
--------

Crisp supports defmacro, which makes it very easy to 
employ conditional compilation off ANY variable known at 
compile time.

target-has / device-has
-----------------------

### `(target-has <prop> &optional might:bool)`
`(target-has :fp64 T)`

`target-has` is a compile time ONLY macro that accepts a single keyword symbol for some
property. If the current compilation target definitively supports that property, it is T. 
If the compilation target definitively does NOT support it, it is nil.  But if the compilation
target is flexible (like SPIR-V) where it might or might not be supported,  then if the third
`might` argument is provided it evalutes to that.  In that case, were `might` not provided, it would be a compilation error.

### `(device-has :fp64)`

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

Static Analysys
===============

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

declaim
-------

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

check-coalesce
--------------

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


check-bank-conflicts
--------------------

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


check-divergence
----------------

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


max-registers / warn-max-registers
----------------------------------

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


check-barriers
--------------

```
;; in a kernel or function progn:
(declare (check-barriers))

;; top level of file
(declaim (check-barriers #'some-function #'other-function))
```

If a `(local-barrier)` is placed inside a conditional branch that not all threads in a workgroup will execute, the kernel will deadlock.
Crisp performs this check automatically for any use of `when-thread-in-group-is`, whether this check has been elected or not.
But with this check declared, Crisp will try to analyze other thread divergences and barriers looking for deadlock potential.

`check-barriers` will examine the Crisp branching control flow constructs (like `if` and `cond` etc) to 
see if perhaps a barrier is performed in one branch but not another, and warn about it.  



Hoisting and `def-orchestration`
================================

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

`def-orchestration`
------------------

Let's dive into some simple examples.

### "default" orchestration

```
;; assume vector_add is defined and is not templated
(def-orchestration just-vector_add
  (launch-sequential #'vector_add))
```
The above is equivalent to the default orchestration Crisp assumes for any kernel when 
generating hoisting code. Remember that `vector_add` usually takes three vector arguments, 
and notice that none of them need to be mentioned in a simple orchestration like this.

The compiler sees that `vector_add` is wanting to be launched, and it will go look at the arguments
that kernel needs and the code it generates will set up and initialize some dummy values, and handle
their enqueueing, etc.  

This introductory example shows the `def-orchestration` begins with a name for the orchestration
and is followed by a series of command for how to launch kernels. 


### argument passing

```
; assume vector_add and vector_sum are both defined and neither is templated
(def-orchestration my-add-and-sum
  (launch-sequential #'vector_add (vector_sum vector_add::C _)))
```

The example above launches two kernels, first `vector_add`, and once it is done, `vector_sum`.
The declaration for `vector_sum` might look like this: `(def-kernel vector_sum (A:some-vec-type &out Result:some-vec-type) ...` which would mean that `vector_sum` expects to be called with two vector arguments (`A` and `Result`) 

In this particular orchestration, we want the result of `vector_add` to be be passed as the first argument to `vector_sum`, so to tell Crisp that we just combine the name of the kernel with the name of its argument together with `::`
and use that.    For the second argument to `vector_sum` , we want the compiler to just use a dummy value like 
it would have in the previous example, so we use `_` to indicate that.

###  kernel template instantiation
```
;; assume both vector_add and vector_sum are templated for some element-type.
(def-orchestration add-and-sum-doubles
  (launch-sequential
     (gen-vector_add double "v_a_double") 
     ((gen-vector_sum double "v_s_double") v_a_double::C _)))

; this orchestration will cause the kernels `v_a_double` and `v_s_double` to be created in the output.
```

Recall that when a kernel is templated, `gen-KernelName` is used to specialize it and a kernel name string is required.
Here, that is leveraged. Note that this orchestration is effecting the compilation. It is generating
two kernels ( `v_a_double` and `v_s_double` ) that will appear in the output.

### template def-orchestration

```
(with-template-type (T)
  (def-orchestration add-and-sum-any
    (launch-sequential
      (gen-vector_add T "v_a_${T}")
      ((gen-vector_sum T "v_s_${T}") v_a_T::C _))))

(gen-add-and-sum-any float)  ; kernels `v_a_float` and `v_s_float` will be created in the binary.

```
`def-orchestration` can, itself, be templated. Like kernels, nothing will be generated by the compiler 
(not for regular output nor hoisting) UNLESS one or more `gen-Orchestration-Name` appear in the .crisp file.

This is a good way for Crisp libraries to provide orchestration code, since it is ignored otherwise. 
It is then incumbent on the user of the library to explicitly put the desired `gen-XXXX` form in
their own .crisp file.

### More notes on `def-orchestration`

Hopefully those examples give you a grounding on how it can be used. It is important to remember
that the forms inside the body of `def-orchestration` are used to just generate sample code and
ensure that certain specializations are instantiated. 

Because `def-orchestration` focuses on high-level data flow using Crisp's typed views, 
it is generally not used with kernels defined via `def-kernel-exact`, which operate at a lower level with raw argument types

The forms that can appear inside `def-orchestration` are quite limited. It is NOT a Crisp 
execution environment. 

Presently, the following forms are the ONLY ones allowed within the body of a `def-orchestration`:
- `launch-sequential`
- `launch-parallel`
- `launch-interleaved`
- the `dotimes` and related `dec-` / `do-` macros
- `_`  
- `kernel_name::var-name` identifier 

launch-sequential
-----------------

```
(launch-sequential  &rest launch-specification)
```
`launch-sequential` takes a series of "launch-specifications" and the hoisting code that is
generated will enqueue them all and prepare a device-side event based synchronization.
The CPU is free to do other things while the sequence of kernels run, and it does not need to do participate during the sequence.

### launch specification

A "launch specification" has two possible forms: specifying only the kernel, or specifying the kernel and its arguments.

For the kernel-only form, the kernel can just be named with `#'` preceding it. Or, for a templated kernel, 
the `(gen-KernelName ...)` form is sufficient.

For the kernel-with-arguments form, put the kernel name (or its generation) in the function position of the 
s-expression and then use either an underscore (`_`) for each variable, or refer to some variable used in a previous step
by combining another kernal name and its variable name: (e.g. `vector_add::C`). 
 This "other" kernel name must be from a different kernel that was used earlier in the orchestration.

Note that in the context of `def-orchestration` it is legal to use the `gen-XXXX` form
on an untemplated kernel for the purposes of giving it a unique name.  ( e.g. `(gen-SomeKernelName nil "new_kernel_name")`)

```
;; assume vector_add is NOT templated.
(launch-sequential 
     (gen-vector_add nil "initial_v_a")
     ((gen-vector_add nil "second_v_a") _ initial_v_a::C _)
     ((gen-vector_add nil "third_v_a") initial_v_a::B second_v_a::C _))
```

launch parallel
---------------

```
(launch-parallel &rest launch-specification)
```

`launch-parallel` is much like `launch-sequential` except that the kernels are all launched parallel to one
another. Crisp will add code to divide the available thread space up between them (excepting `single-task` kernels which just get one thread).

Note that kernels in this form CANNOT refer to each others variables. Dependencies between them are disallowed.

launch-interleaved
------------------
```
(launch-interleaved launch-specification offset-param-specifier length-param-specifier &key exclude)
```

When the compiler encounters `launch-interleaved`, the hoisting code that is generated will enqueue
the kernels and data such that the memory copy and the kernel execution overlap. This helps hide latency
and is often the secret to maximizing performance and throughput.  

The kernel launched must have, in addition to one or more vector data arguments, a parameter that can
accept an "offset" into the vector and a paramter that accepts a "length". 

If there vector arguments to the kernel that should NOT interleaved, specify them with the `:exclude` key.

Example:
```
;; assume input-vec-t and output-vec-t already defined.
(def-kernel vector_add_chunked (len offset A B &out C)
  (declare #(ulong ulong input-vec-t input-vec-t &out output-vec-t))
  (let ((A-view (make-vector-view A len offset))
        (B-view (make-vector-view B len offset))
        (C-view (make-vector-view C len offset)))
    (map-stride #'+ A-view B-view C-view)))

(def-orchestration add-interleaved
  (launch-interleaved #'vector_add_chunked vector_add_chunked::len vector_add_chunked::offset))
```
In the example above, Crisp will correctly conclude that ALL the vector arguments ( `A`, `B`, and `C`) 
should be interleaved and the hoisting code will demonstrate how to allocate some memory, pin it, 
and interatively copy it to the GPU device while executing the kernel concurrently.

Neat!




Compiler Invocation and Options
===============================

`$ crisp.exe file.crisp`
Without any output targeting options, the crisp compiler would simply output any compilation errors. Similar to using `-fsyntax-only` with C compilers.

Output Targeting Options
------------------------

### `--output-dir=<DIRECTORY_PATH>`

Where the output of the crisp compiler should go. If not provided it is assumed to be the current working directory.

### `--output-base=<NAME>`

This base name will be used for all outputs, with the file extension uniquely identifying them.
If not provided the base name is the name of the last .crisp file passed to the compiler (minus any extension).

### `--transpile-to=<ID>`

The compiler will transpile the .crisp file to some other Kernel language. At the moment `oclc` is the only supported
transpilation target.

| ID       | Extension |  Description       |
|----------|-----------|--------------------|
| `oclc`   | `c`       | OpenCL C           | 

### `--ir-target=<ID>`

This flag can be used repeatedly, each occurrence with a different ID. The compiler will compile the .crisp files 
to an IR (Intermediate Representation) file. One file per occurrence of the `--ir-target` flag.
`ID` can be one of

| ID       | Extension |  Description       |
|----------|-----------|--------------------|
| `ptx`    | `ptx`     | CUDA Parallel Thread Execution IR |
| `spv`    | `spv`     | Khronos SPIR-V IR  |

### `--binary-gpu-target=<ID>`

This flag can be used repeatedly, each occurrence with a different ID. The compiler will compile the .crisp files to a different binary file for each binary target. The binary file name will be `<output-base-name>_<ID>.<extension>`

`ID` can be one of
| ID      | Extension |  Description       |
|---------|-----------|--------------------|
| `sm_90` | `cubin`   | NVidia             |
| `pvc`   | `bin`     | Intel PonteVechio  |


### `--fat-binary`

This flag requires that the `--binary-gpu-target` flag also be used, or it is ignored.
Whe present the binaries that Crisp produces will be  fat binaries and will also contain the matching IR code (PTX or SPIR-V).

### `--hoist=<ID>` 

This flag can be used repeatedly, each occurrence with a different ID. The compiler will generate a hoisting example code files for each occurence.
The hoist options are paired against their matching IR and Binary targets automatically. You'll get a warning from the compiler if it detects
incompatible pairings.  Note that if outputting BOTH binary and IR targets then the hoisting code will demonstrate both.

The hoist file name will be `<output-base-name>_hoist_<ID>.<extension>`

`ID` can be one of
| ID              | Extension |  Description       |
|-----------------|-----------|--------------------|
| `OpenCL`        | `cpp`     | OpenCL 3.0 API     |
| `L0`            | `cpp`     | LevelZero 1.9 API  |
| `CUDA`          | `cpp`     | CUDA 12 API        |
| `PyOpenCL`      | `py`      | PyOpenCL           |
| `PyLevelZero`   | `py`      | Python LevelZero   |
| `PyCUDA`        | `py`      | PyCUDA             |

There are other flags that interoperate with the hoisting, such as `--hoist-unified-memory` and `--hoist-dynamic`

### `--metadata`

If this flag is present, the compiler will output a metadata file. This file has a lot of the necessary 
hoisting information about the kernels and their arguments and 
can be parsed programmatically if desired.

### Example
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

Other Flags
-----------

### `--debug-output`
This enables the debugging output side channel as well as enabling the runtime checks ( `r-t-check` ). When this 
option is used, the kernel may run significantly slower. Note that the code that actually hoists
the kernels built with this flag has to be updated as well so that the debug output side channel vector
is created and added as an argument. It is up to the calling application to decide what to
do with the debug output once it is retrieved. The hoisting code typically models writing it to a file.

### `--hoist-unified-memory`
If this flag is present then the memory that is prepared in the hoisting code will be
CUDA Unified Memory, LevelZero Unified Shared Memory, or OpenCL Shared Virtual Memory, as appropriate to the hoisting 
target.  Otherwise, the memory operations will use regular memory. 

### `--hoist-dynamic=<KERNELNAME>`
This flag can be used repeatedly, each occurrence with a different KERNELNAME.  For each kernel named, the hoisting 
code will demonstrate how to compile that same kernel by invoking the in-memory compilation API on the string that is that
kernel. 

### `--re-output-crisp=<DIRECTORY>`
This flag is passed a directory. The .crisp files that are being compiled will be copied into that directory. But they will 
be modified in three ways: 
 - any types that were inferred by the compiler will now be explicitly declared in the updated .crisp file.
 - the file will be output in dependency order, compatible with single pass compilation. 
 - any static analysis "opt-in"s will be removed. 


### `--no-inference`
Type inference is turned off. The compiler will output an error for missing types.

### `--no-static-analysis`
Any opt-in static analysis (see above) will be skipped. 

### `--single-pass`
By default, the Crisp compiler performs "multi-pass" compilation, which means that the compiler first reads the .crisp files, gets an understanding
of everything that will need to be compiled how how they depend upon each other, and then it takes a second pass and actually compiles everything. 
When the `--single-pass` flag is present the compiler compiles items as it encounters them. But this requires that your .crisp file is in reverse
 dependency order. Meaning that if  `calc-two-things` calls `calc-one-thing` that `calc-one-thing` MUST appear in the .crisp file BEFORE `calc-two-things`.
 In other words, when any function is being compiled, every subfunction and macro that it uses MUST have been previously declared. This often means that
 entry points and kernels appear last in a .crisp file. 
 If this is an inconvenient way of working for you, don't let it crimp your style. Don't bother with the `--single-pass` flag
  or use the `--re-output-crisp` flag to have your .crisp files converted to single pass order. 

### `--skip-c-t-checks`  

The compile-time checks are skipped. This is very dangerous but does make the act of compilation much faster. 
It is meant to be used when doing runtime compilation of Crisp kernels, probably from some sort of code template that you know is sound.
It is possible to output invalid kernels with this option. 
Note that this not only skips the `c-t-check` entries that you put into your own code, but ALSO many routine checks that the compiler
regularly performs, including error checks that the documentation elsewhere says might be performed.
When this flag is on, the compiler only performs the minimal checks required to
move forward. This is inherently unsafe. 

### `--tree-shaking`

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

Compiliation Flags
------------------

### `-D`

Used to define parameter values ( see `def-parameter`)
Example: `crisp.exe -DSTART_INDEX=20` 

### Math Flags (TBD)

There are tradeoffs between accuracy and speed in many math operations. These are elected at compile-time and there is
an assortment of flags to choose from. 


Fast Compilation
----------------
Compilation speed is one of the prime goals of the Crisp compiler. There are things you can 
do to maximize compilation performance.

### Single Pass

`--single-pass` compilation is faster than multi-pass. Use `--re-output-crisp` if necessary to prepare for this.

### No Static Analysis

Static analysis is slow. If you have opt-in static analysis in your .crisp file, use `--no-static-analysis` to skip them.

###  No Type Inference

Type inference slows the compiler down. Declare all types if possible.  Use the `--no-inference` or `--re-output-crisp` flags to help
kick the habit.

### Use Tree Shaking

The `--tree-shaking` flag makes for a slow compilation.  BUT the benefit for any future compilations to the same set of targets, especially
for the same set of libraries or kernels, is extreme. Be sure to use tree shaking from time to time to update the lib caches for your files.
Tree shaking can make the compilation of OTHER kernels faster too if they use some of the same libraries. It's clutch.

The `--tree-shaking` flag can be used with library .crisp files and no kernels at all. Given a set of targets it can still generate .crisp_lib files
for those libraries which will speed up future compilations of anything to any of those targets.  Note that many of the compilation flags
must be used consistently by both the tree shaking and future compilation passes:
- `-DXXXX`
- `--IR-target`
- `--binary-GPU-target`
- `--debug-output`
- math flags (speed, accuracy , etc)

### In Memory Compilation

There is ( soon? ) both a Python and a C++ API for performing in-memory compilation, including support for in-memory lib and lib caches. 
With this there is no disk IO and compilation can be performed nearly instantaneaously. 

### Danger
If you are confident that the code you are compiling is completely ready and error free, use the flag that skips the compile time
checks. 



Hoisting Code
=============

The hoisting code that Crisp outputs demonstrates the following:
- loading the kernel from disk
- using CUDA/LevelZero/OpenCL to create a program from that kernel
  be it IR or binary
- commented out code that demonstrates how to perform profiling
- then for each kernel in the output
- - allocating and preparing all the side channel memory. Using 
    Unified Memory if requested by the `--hoist-unified-memory` flag.
- - allocating and preparing the explicit memory in the kernel arguments.
- - setting the kernel arguments
- - enqueuing the kernel
- - waiting for it to complete
- - enqueing any "copy back" operations for result vectors.

Further, if the `--hoist-dynamic` flag is used, then the example code will actually 
include the string of that kernel and pass it to the in-memory compilation API (etc.).


In-Memory Compilation API
=========================

C API
-----

<!-- NOTE  Let's rename "tree shaking" throughout. set_cache_directory() ??  But also change the flag -->

### `new_context( target_identifier )`   
    
`target_identifier` is one ID from either IR or binary target flags.
returns a pointer to a context.

### `set_tree_shake_directory( context, path )`

`path` is null terminated C string.

if the `--tree-shaking` compilation was performed earlier, then its output directory can be 
used as the input tree_shake directory for the in-memory compiler. This can 
greatly speed up in-memory compilation.

The relevant flags used (and recorded) in that compilation will be used. 
See the section on `flags` below.

### `add_input_file( context, file.crisp )`

Reads in the file and adds the crisp source to the context.  Returns an error if the file could not be read.

### `add_input_string ( context, crisp_string, virtual_file_name )`

Adds the crisp source to the context. The `virtual_file_name` (e.g. "my_dynamic_kernel.crisp")
can help make compilation error messages more understandable.


### `set_flags( context, string )`

This is a just a string of flags and values like you would submit
to the crisp.exe compiler. If using `set_tree_shake_director()` then
this call is likely not needed .  See the section on `flags` below. 

Example:
```
  set_flags(ctx, "-DMAX_INDEX=40 --single-pass --no-inference");
```
### `get_flags( context, char** flagHandle, size_t* sz )`


If using `set_tree_shake_director()` then this populates the flagHandle with the flags
passed when the tree shaking was performed. Otherwise it returns nothing.

Call with nullptr for `flagHandle` to have the `sz` set to the size needed, then
call again with both set.

### `compile(context, size_t* sz)`

compiles everything. If this is the first call and `set_tree_shake_directory( path )` was 
called earlier then there may be file I/O as the files from the tree shaking get read in.

returns a status code. If successful `sz` will be set to the size of the binary.
See "Status Codes" below.

### `compile( context,  string, size_t* sz )`

adds string to the context and compiles everything. If the string has definitions
that have the same name as others that were loaded into the context earlier, 
it does not trigger an error. Instead, any definitions in string are presumed to override.

returns a status code. If successful `sz` will be set to the size of the binary.
See "Status Codes" below.


### `bool get_binary(context, const void** out_data, size_t* out_size)`

Gets the size and a pointer to the compiled binary from the last successful compilation.
return true on success, false if no binary is available.

The binary/ir result of the compilation. Something that can be passed 
to `clCreateProgramWithBinary` or its equivalent.

### `long get_compilation_error_code(context)`

Retrieve the actual compilation error code from the last compilation attempt. 0 if successful.

### `const char* get_messages(context)`

Gets any error or warning messages from the last compilation attempt (successful or not).

### `const char* get_metadata(context)`

Gets the metadata from the last successful compilation. Format TBD.

### `destroy_context( context )`

Destroys the context. 

Status Codes
------------

When using the In Memory Compilation API in conjunction with the "tree shaking cache" <!-- RENAME -->
it is important to preserve the API between the host and the kernels it may be enqueuing.

For example, if some kernel in the cache required only 1000 bytes of scratch memory, but 
after recompilation by In Memory Compilation API it now requires 10,000 bytes, that would
be a breaking change.  The kernel, if enqueued as before, would no longer function correctly.

Other changes could result in even more severe API breakage. Query the metadata to see
if the kernel you intend to call was affected and how before attempting to use it.


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


Flags
-----
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
- math accuracy flags
- flags governing errors and warnings (TBD)




INDECES
=======

def-
----

- def-function      [KO] [D] [T]
- def-kernel             [D] [T]
- def-kernel-exact       [D] [T]
- def-struct             [D] [T]
- def-setter             [D] [T]
- def-const              [D]  (next to, not "within")
- def-const-vec          [D]
- def-parameter          [D]
- def-enumeration
- def-type                   [T]
- def-derived-type
- def-constraint

control flow
------------
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
- in-each-thread                   [3D]
- in-each-thread-in-group          [3D]
- loop-grid-stride       [D]       [3D]
- grid-stride-target [DP]          [3D]
- loop-grid-stride-linear
- loop-vector-stride
- loop-soa-stride
- loop-tensor-stride                  [ND]
- loop-group-stride                [3D]
- loop-tile-stride                [2D]
- grid-level         [DP]
- uniform            [DP]
- dotimes / dotimes+ / dotimes*
- dec-times / dec-times+ / dec-times*
- dec-times-by-half / dec-times-by-half+ / dec-times-by-half*
- dec-times-by-factor / dec-times-by-factor+ / dec-times-by-factor*
- do-times-by-doubling
- do-times-by-multiply
- do-power-step
- dec-power-step
- in-warp
- shuffle
- shuffle-up
- shuffle-down
- shuffle-xor
- if / if+ / if*
- when / when+ / when*
- cond / cond+ / when*
- select-if

Higher Order Function Operations
--------------------------------
- map-stride
- reduce-to-warp
- reduce-to-workgroup
- reduce-to-1-small
- reduce-to-1-atomic
- reduce-to-1-cas
- reduce-to-1-cont
- reduce-vec
- binop-type     ; commutative vs non-commutative ?
- predicate-type
- exclusive-scan   ; <-- the scans are NOT HOF ops. but Filter is.
- inclusive-scan
- filter


Sorting
-------
- bitonic-sort-workgroup
- bitonic-sort-workgroup!
- bitonic-sort-soa-workgroup
- bitonic-sort-soa-workgroup!
### kernels
- gen-bitonic_sort_workgroup
- gen-bitonic_sort_workgroup_in_place
- gen-bitonic_sort_soa_workgroup
- gen-bitonic_sort_soa_workgroup_in_place
### merge_pass kernels
- gen-bintonic_merge_pass
- gen-bintonic_soa_merge_pass
### orchestrations
- gen-bitonic-sort-vector
- gen-bitonic-sort-soa-vector
- gen-bitonic-sort-vector!
- gen-bitonic-sort-soa-vector!




Atomics
-------
- atomic-add!
- atomic-sub!
- atomic-inc!
- atomic-dec!
- atomic-min!
- atomic-max!
- atomic-xchg!
- atomic-binop!
- atomic-op!

Type Constraints
----------------
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

other
-----
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
- vector-view
- `length~ / parent~ / offset~`   [O]
- element-type
- bytes  
- `~`                             [O]
- `~ref~`
- vector-type          [KO]
- vector-view-type     [KO]
- vector-base-type     [KO]
- make-vector          [KO]
- make-vector-view     [KO]
- soa-vector-type      [KO]
- soa-view-type        [KO]
- make-soa-vector      [KO]
- make-soa-view        [KO]
- convert-soa-to-aos
- convert-aos-to-soa
- make-scratch-vector
- make-result-vector
- make-implicit-vector
- marshall-vector
- marshall-scratch-vector
- marshall-result-vector
- marshall-implicit-vector
- marshall-debug-logging-vector
- voidp
- #(1 2 3)
- use                   [DP]
- tensor-view-type
- make-tensor-view     [KO]
- make-matrix          [KO]
- num-dims-of
- `dims~`
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
- dot-prod
- matmul
- const-vec-type
- maybe                 
- result               [KO]
- or-else
- as-derived
- as-original
- set-derived
- inline           <== for declare. needs definition  [DP]
- entry-point      <==  ibid
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


logging and debugging
---------------------
- c-t-output
- c-t-assert
- r-t-workgroup-output-if
- r-t-workgroup-assert
- r-t-output
- r-t-assert
- line
- file

static analysis
---------------
- declaim
- check-coalesce
- check-bank-conflicts
- check-divergence
- max-registers
- warn-max-registers
- check-barriers

hoisting and def-orchestration
------------------------------
- def-orchestration
- launch-sequential
- launch-parallel
- launch-interleaved
- +wg-size+  ; constant in def-orchestration (only)


lisp
----
- let                     [D]        ; not sure about let*
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


### Keys
```
[KO]   => arg list supports &key &optional
[D]    => progn supports inclusion of (declare ...)
[DP]   => can appear IN a (declare ...) list, in the function position
[T]    => can be wrapped by with-template-type
[O]    => can be overloaded
[3D]   => has 1D, 2D and 3D variant
```




To Do
-----
- implementation notes for each, esp vector and def-const-vec, def-function, def-kernel
- [x] is our "hoist" code going to include reading the compiled kernel from disk? Seems like it should.
- [x] multiple kernel invocation
- [x] multiple kernels in a single .crisp file.  what does that mean for binary reading and hoist code and compilation?
- [x] tension between vector-type declarations with and without length.  Possible solutions: (user-vector-t-wo-length 20)  or (add-length #'user-vector-t-wo-length 20) ? 
     The "twist" of using the type in the function position is very Clojure, but, honestly, too much of it makes things confusing. 
- [x] SBCL vs C++ ?
- [x] type "narrowing" suggested in with-template-type examples.
- [x] dependent types ( we've introduced them somewhat with tensor-view-type which takes both a number (dims) and a whole other type)
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
      tensor-views handle most slicing/shaping needs.  also "broadcasting" which is setting one of the strides to 0. So the "next row" calculation goes nowhere. It's a simple way of taking a [1 2 3 ] and making into [[1 2 3] [1 2 3] [1 2 3]...]
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
+ [ ] fold and friend BUT REDUCED via shuffle <-- we added `reduce-` do we need others? 
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
- + [ ]complex numbers
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

[X] C interop with structs/vectors : std140 

[ ] LAMBDA REVISIT - uniform lambdas OK?  

[ ] OVERLOAD REVISIT - how will overloaded functions, especially getters/setters, be useful if there is no var capture or globals?
                   (def-function make-xxxx ()   (def-function overload-of-something () ...))  ?  

[x] DEF-KERNEL-EXACT ?  - our def-kernel assumes someone will be using our hoisting code.  BUT for people that have hoisting code already and know
                      the exact interface, they should be able to define it.
                      QUESTION:  how do THEY get vectors over then? void* data and size_t bytecount / versus / double* data and size_t count.
                      A1:  special declare?
                      A2:  marshall-vector call and voidp type.

[ ] vector-view that changes element type. (like casting a vector of double to long) "reinterpret"

[ ] DATA-POOL   - could be a real value add here. Kernels can't really dynamically allocate memory, so a pool system would be handy.
              Also very handy if we can calculate how much scratch will be needed and communicate that back in the hoisting code.
              Could be in terms of kernel args.  DataPoolSize = sizeof(double) * vector-A.lenth * 1.7 

              This also suggests that "scratch" and "return"  data-pool entries are handled.  via type sig? declare? proclaim? 

[X] COPY-BACK   - are "result" vectors automatically copied back? (As opposed to "implicit"?)  Assuming no (safe assumption), 
              what is the mechanism for this? Often times it is a separate kernel. Need to understand this better.
              How will users doing their own result kernel args get things copied back?  Unified Memory vs Non vs Buffer vs ??

[X] MACROEXPAND - where to put this? A REPL tool? compiler flag?


[ ] SORTING  ( [ ]radix & [x]bitonic   - probably over warp, workgroup, global, vector)

[X] PROFILING ? yet another side channel?   advise?  -- is mostly a host side issue, correct?  
    DECISION: hoisting example code will have commented out code that enables profling. 
              (get-timestamp) function available.   
              That's enough to help a user.  Later we can add "advise" 

[x] IN MEMORY COMPILATION API -- needs to be specified. 

[ ] ENTRYPOINT

[ ] fused softmax ( whatever T F that is.)

[ ] Am not totally loving the reduction macros. with-template-type wrapped over function seems better?  Or maybe defmacro should be   
    statically typed.  Having it slip through the cracks seems weird, and dangerous.

[ ] REVISIT / CLEAN UP MEMORY / SUMMARYIZE and COMPARE .  a) make-vector with compile-time known size: fully supported.  
      b) various "scratch" local/global . c) :compact vs :std140 , d) def-constant-vec/use 
      e) communicate with hoisting, derive-from f) side-channels g) #( 1 2 3)  
      h) (declare (shared someVar) (uniform otherVar))   "shared" could be "local" or "slm" ?  This declare is for let clauses
         difference between "shared" and "uniform"

[x] Pretend we introduce 'while' or something. If a kernel does run infinitely, how can it be stopped?
    presumably some 'terminate()' call from within kernel. But what about from host? A: Not easily from host. Requires reset. 

[ ] OTHERS
   Mojo    ( https://www.modular.com/mojo )  One language, any hardware.  Bare metal performance. Pythonic Code.  
    Triton  ( https://openai.com/index/triton ) open source gpu programming for neural networks. 
    Cutlass  ( https://github.com/NVIDIA/cutlass ) CUDA Templates and Python DSLs for High-Performance Linear Algebra
    Hillisp ( https://github.com/michelp/hillisp )   tiny Lisp implementation written in CUDA.  Drives the GPU.  Queues up "fill" kernels, "+" kernels, etc. 
    CL GPU ( https://www.cliki.net/cl-gpu )  subset of Common Lisp on GPU
    cl-gpu ( https://github.com/angavrilov/cl-gpu ) A library for writing GPU (CUDA) kernels in a subset of Common Lisp.

[ ] Debugging Story - Give more attention.  A REAL pain point with developers.

[ ] Generate Crisp from Python. 

[ ] FFT 

[ ] warp scheduling and [x] memory coalescing

[ ] def-orchestration / calls kernels and some prebuilt affordances: cuBLAS, possibly oneMKL?.  "soft description". basic vector declarations, data passing, looping.
    probably need a (TBD ...) and (hoist-comment ...) macro.   Templates?  Gen?  


### To Do (SHORT)
- [ ] FFT
- [ ] Radix Sort
- [ ] Debugging Story
- [ ] Compile-time introspection first-class citizen: 
    [x] get-struct-members
    [ ] is-grid-level? 
    [ ] get-return-type
    [ ] get-member-types
- [ ] reduction macros -> templates
- [ ] Math: sqrt / rsqrt / pow / exp / log / log2 / sin / cos / tan / asin / acos / atan / abs / min / max / clamp
- [ ] ENTRYPOINT - for libraries
- [ ] fused softmax
- [ ] data pool
- [x] vector-view that changes element-type
- [ ] dot product and accumulate for matrices
- [ ] / group barriers
- [ ] complex numbers - need for FFT
- [ ] matrix ops / vector ops
    [ ] (m*v M v) - convenience function for matrix-vector multiplication. Very common special case of matmul
    [ ] / (determinant M)
    [ ] fill
    [ ] copy
    [ ] iota
    [ ] gather
    [ ] (is-contiguous? M)
- [ ] / (declare (critical name V)) ; if fighting "spill", how important is one value vs. another.
- [x] / def-orchestration
- [ ] / (hoist-comment )
- [ ] / (declare (const var-name))
- [ ] Kernel IPC
- [ ] Data interleaving. Mostly host side, but kernel needs to be able to work in chunks. 
      Kernel typically takes an "offset" into the data. (vector-view vibes).
      Works well with "embarassingly parallel" ops like: vector_add, convert-layout (matrix transpose), grid-strides,
      But won't work with: reductions, filter (and prefix-sum-scan), sorting (radix/bitonic). 
      [ ] Merge sort, however, chunks.  
      There is a REAL need here. Data interleaving has a lot of reqs.  So setting up a sample might 
      be fire.



<!-- PUT THIS LITTLE SUMMARY ON MEMORY SOMEPLACE -->
Memory
------

Memory cannot be allocated by the kernel itself. Only the host or the compiler can do so.

There are five different categories we need to consider:
- **Global:** Set up by the host. This is your main communication channel for large data sets. Slow.  This memory CAN be set up by the compiled code of the kernel, but that is an anti-pattern. A bad idea. 
- **Local (Shared):** Set up by the host via kernel arguments. This is for fast, on-chip sharing among threads in a workgroup.  This memory CAN be set up by the compiled code of the kernel as well. 
- **Constant:** Set up by the host. This is for read-only data that's broadcast to all threads.  This memory CAN be set up by the compiled code of the kernel as well -- but MUST be done BEFORE the kernel executes. 
- **Registers:** Managed automatically by the compiler. This is for variables that need to be accessed quickly and frequently.

- **Private:** Managed by the compiler. This is for per-thread variables, analogous to a CPU stack.


