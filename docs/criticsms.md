Why Crisp Sux
=============

Criticisms of Crisp. Fair and unfair.

Kernel Interface
================

The whole "Side Channel" thing and even the way that vectors appear
singly in a kernel param list just paper over issues and introduce surprises.

Crisp author write  `kern(in &out out)`  but it uses both local and global
scratch mem and debugging has been elected, so the ACTUAL enqueuing
looks like this:

```
clSetArg(debug_buf_size)
clSetArg(debug_buf_global)
clSetArg(scratch_global_size)
clSetArg(scartch_global_mem)
clSetArg(scratch_local_size)
clSetArg(NULL, sz, local)
clSetArg(in_size)
clSetArg(in_global_mem)
clSetArg(out_size)
clSetArg(out_glboal_mem)
```
and the ACTUAL transpiled kernel is nearly unrecognizable.

principle of "Most Astonishment" seems to be in play.

Hoisting
========

Hoisting is just an attempt to fix a problem Crisp made in the first 
place (see Kernel Interface above). And while it seems nice in theory
who is asking for that? Is that really helping anyone?

Also, it's non-trivial to produce and support the whole hoisting endeavor.
So a LOT of work for something no one has asked for, all because of problems
introduced by an overly simplistic kernel interface.


Interoperability
================

As I understand "Kernel First" there is this idea that Crisp
can just write the kernels and they can "drop in" to some
existing setup. But between the side channels and the implicit args
I'm not sure that's realizable at all. Even 'def-kernel-exact' seems
like just weak attempt to assure the reader, not a concerted effort
to really interoperate.

What Do I Get Exactly?
======================

- MORE performance? : No
- EASIER kernel development? : Arguable. Also Lisp. So No?
- SAFER kernels? : No
- BETTER Debugging? : arguably better logging. But No. Especially
since the existing debug tools speak CUDA and C. None speak Crisp.




Table of Contents
=================

This TOC is taken from Crisp ideal docs. Using it as coverage guide.


- Overview 
- - Focus 
- - Major Features of the Crisp language and tools 

I'm sorry - did I read "not Turing complete" ? Is this like HTML or something?

- - Differences From Lisp 
- Thread Level / Grid Level / Dispatch Contexts 

Do we have any _real_ grounded/mathematical evidence that this thread-level
grid-level, dispatch thing is real? Even if it the examples provided are
correct, might there not be cases where actual valid working approaches
would be prevented by the restrictions introduced ?  

- - Why Different from C++/CUDA
- Top Level Execution Constructs 
- Return Vector Pattern `&out` 

It may seem hard to believe, but not all race conditions are bad. 
If race conditions were completely and utterly banned from all software, 
then most software wouldn't work at all. So, yes, accessing B[7] is a race
and may result in garbage. But "may" is perhaps doing too much lifting here.
If this workgroup include B[0]-B[128], then B[7] IS readable.

- Argument Passing and Side Channels

Side Channels end up modifying ALL the function signatures of the calls in the tree to  side channel data use. Again, rendering the final code unrecognizable.  
What's this stuff going to look like in the debugger?

- Crisp Types
- - Basic Numeric Types

The Crisp numeric type are "basic" but also not nearly complete:
qint8 qint32, fp4, fp8  

If performance is the goal, then those should be part of the equation.
This might be "unfair", as they belong in the realm of compiler optimization,
but it's not like there's going to be an LLVM crisp parser anytime soon, so 
what's the plan? Is this just a toy?

- - Vector Numeric Types
- - Numeric Type Promotion, Casting, Conversion

No to-int? But use ceil/floor/truncate/round?  Can't I just say "make to-int be floor" 
and be done with it? Seems problematic.

Also what then is `(to T <var>)`   ? if `T` is an integer type and `<var>` is floating point?


- - Other Basic Types
- - Declaring Types - Functions

zOMG - for the love of all that's holy, do we really need 10 different
ways of specifying paramater and return types?  

- - Function Overloading

This seems oversimplified and idealized. Will this work in practice?

- - Recursion Disallowed
- - Declaring Types - Kernels
- - Struct Types

:std140 "seems" like a good idea until my C++ structs don't copy over 
to Crisp kernels. What's a girl gotta do? So, now what, use Crisp struct
definitions? That's NOT "kernel only". That's infecting my entire source base.

- - `def-setter`



- - Template Types
- - `def-constraint`
- - `def-type-function`
- - Vectors and Vector-View

vector-view seems like a nice way to avoid unsafe pointer arithmetic.
But, there aren't true compile-time checks, so `(inc! (offset~ vv))` is
just as unsafe as `ptr++` .  Worse, this means vector views are SLOWER
because every access means base + offset arithmetic has to be performed.

Also, is `:constant` memory really required at compile time? Can't this 
be a decision made by the host? Why does the kernel even care? So long
as the kernel knows it's :read-only, then what more is there to talk
about?    
The in-vec type is limited to :global , but that might be incorrect.



- - Reduce Boilerplate: Vectors Of Lenght 1: `single-result` and `set-result!`
- - Reduce Boilerplate: `in-vec` and `out-vec`

The in-vec type is limited to :global , but that might be incorrect.  
It should be global OR constant.   incomplete type?

Or maybe :address-space is misconfigured in the language?

- - `soa-vector` and `soa-view`
- - `def-const`
- - `def-parameter`
- - `def-const-vec`
- - Side Channel Vectors

make-implicit-vector ?  Really?  Making it easier for people to hurt themselves?

- - Tensors
- - Matrices
- - Type Aliases and Type Constructors
- - Derived Types

This is weird. Feels weir.d

- - Continuation Kernels

OMG - so contrived. Also, whatever happened to "Kernel First" and "Kernel Only" ?
I'm not sure anyone will actually ever use this feature.

- - First Order Functions
- - First Order Types
- - Enumerations
- - Maybe Type

Goodbye performance!

- Control Flow
- - Single Task
- - when-thread-is / abs-when-thread-is
- - when-thread-in-group-is / when-group-is
- - when-is-last-workgroup
- - Hoisting and Enqueing a Kernel
- - Latency Hiding - warp sizes and workgroup sizes
- - One Thread Per Element
- - Looping - Grid Stride
- - Looping -- Uniform Loops
- - Looping Constructs
- - Grid Level Operations
- - Sum a Vector using Local Memory
- - Warps & Shuffles
- - Sum a Vector using Warps and Shuffles
- Branching
- - Cost of Divergent Branching
- - Predicated Selection
- Higher Order Function Operations
- - Lambda No, Curry Yes
- - map
- - reduce variants
- - reduce vector
- Boolean Reductions
- Filtering / Prefix-Sum Scan

THe "prepare-for-scan" is what?  

- - exclusive scan
- - inclusive scan
- - Word Count with Exclusive Scan
- - `filter`
- Gather / Scatter
- Sorting
- - Bitonic Sort
- - Radix Sort
- Atomics

atomic binop?  And NOT atomic-cas?  This is because of the "turing incomplete"
thing right? Seems broken. Whole categories of things I can't write now. Thanks.

- Vector And Tensor Operations
- - dot product
- - matrix multiplication (matmul)
- Math Operations & Arithmetic
- - Floating Point Precision
- - Floating Point Only Operations
- - Floating Point and Integer Operations
- - Integer Only Operations
- - Integer Division
- Complext Numbers
- - soa-vector and complex
- Fast Fourier Transform (FFT)
- Builtin GPU Functions & Constants
- Forgotten
- Logging and Debugging

  Heh, the "overengineered" observation was funny. 
  And not funny. No one will use even half of these things.

- - Logging Utilities
- Conditional Compilation
- defmacro
- Static Analysis
- - declaim
- - check-coalesce
- - check-bank-conflicts
- - check-divergence
- - max-registers / warn-max-registers
- - check-barriers
- Hoisting and `def-orchestration`

Who's going to use this again?  Seems like it's just 
a weak attempt to paper over problems that Crisp introuces in the first place

- - `def-orchestration`
- - launch-sequential
- - launch-parallel
- - launch-interleaved
- Compiler Invocation and Options
- - Compilation Flags
- Hoisting Code
- In-Memory Compilation API

zOMG - overengineered and SPECULATIVE.
 Also, while there is definitely a demand for
this generally, I am skeptical that there will be a demand for THIS exactly.

- - C API
- - Status Codes
- - Flags
- INDECES
- To Do etc.
