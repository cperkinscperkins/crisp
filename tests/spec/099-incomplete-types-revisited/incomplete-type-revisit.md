Chris Recounts
============== 
 
 In Crisp, structs and records (which are just virtualized structs) can have both runtime and compile time values. For example, the tensors (a Storage Handle) in Crisp are defined via def-record and in addition to the compile-time known arity and element data type, they also have :c-t properties :address-space (which can be :global , :local or others) :align (which can be :compact, :compact-offset, and :strided)  and :contiguous-term (:first or :last).



Using def-record or def-struct defines a new type expression. And that type expression can be used to pin down an actual type by using it with all the compile time properties. Thus a "complete type" is one of those expressions with all the properties present. Like so:

(tensor float 3 :address-space :global :align :compact :contiguous-term :last).

In the case of tensor, the :contiguous-term has default of :last, and so if left off in a situation where a complete type is required, we'd use the default.



With me so far?



Incomplete types are a way of getting type expression polymorphism. So a function can declare that it accepts (tensor int 1) , for example, and doesn't have to worry about those other properties. In theory, it should work with any vector of ints. 



For most user-defined def-record/def-struct this sort of polymorphism works pretty well.  But for the Storage Handles it introduces an issue.  There are two possible ways of interpeting what it means to be an "incomplete type".  

Method #1: if the code in a function that accepts an incomplete type needs any of that information, it can insert runtime checks and branches.  

Method #2: if the code in a function that is written with an incomplete type needs any of that information, we can refuse to compile and say "actually we DO need that". This limits the usefulness of incomplete types in some situations.  But it has much less divergent branching and is more performant.


Now without thinking about this deeply it seems like Method #2 would be the right choice. And it likely is. But for Storage Handles, we run into problems right away. For normal get and set access, like (set! (~ destVector someIdx) (~ srcVector someIdx)) what compile-time properties do we need?

- data type (obviously)

- arity (indubitably)

- :address-space ?

- :align (likely)

- :contiguous-term (probably for everything but vector ( tensor N==1)



So if we need ALL the compile time terms, then that means incomplete types aren't very useful. To get that sort of polymorphism the user will have to template FOUR or FIVE things minimum.


Gemini Replies
===============
You've hit on a fundamental tension in systems programming for GPUs: the clash between high-level polymorphic ergonomics and the rigid, low-level semantics required by hardware. 

You are entirely correct that for Storage Handles—especially something like a `tensor` where memory layout and address space are critical—Method #2 (failing at compile time) is the only path that preserves the zero-cost abstractions and avoids catastrophic divergent branching. 

However, as you pointed out, if basic access like `(~ destVector someIdx)` requires the compiler to know the data type, arity, address space, alignment, and contiguous term, then an "incomplete type" parameter like `(tensor int 1)` seems completely stripped of its utility, drowning the user in template boilerplate.

Here is a breakdown of why the hardware forces your hand here, followed by a few architectural strategies to rescue the ergonomics of polymorphism without sacrificing the performance of Method #2.

### The Hardware Reality of `(~ vector someIdx)`

To emit the IR (whether PTX or SPIR-V) for a simple get/set operation, the compiler strictly requires almost all of those properties:

1.  **Data Type & Arity:** Non-negotiable. The compiler needs the byte-width for the load/store instruction and the dimensionality for the index math.
2.  **`:address-space`:** In PTX, `ld.global` is a fundamentally different instruction from `ld.shared` or `ld.local`. While OpenCL/CUDA do offer "Generic" address spaces that resolve at runtime, relying on them incurs a slight performance penalty and requires the hardware to do the address mapping. For peak performance, the address space must be baked into the IR.
3.  **`:align` & `:contiguous-term`:** These dictate the math required to translate `someIdx` into a physical memory offset. 

If a function only knows `(tensor int 1)`, it literally does not have enough information to emit a targeted `STORE` instruction. 

### Strategies to Rescue Ergonomics

If you want the performance of Method #2 without forcing users to explicitly template 4 or 5 properties every time they write a helper function, you have to bridge the gap between what the *user writes* and what the *compiler sees*.

#### 1. Implicit Monomorphization (The Constraint Pattern)
Since Crisp already supports monomorphization, you can treat `(tensor int 1)` in a function signature not as a literal "incomplete type" that must be reasoned about abstractly, but as a **type constraint** or wildcard.

When a user writes a function accepting `(tensor int 1)`, they are telling the compiler: *"I don't care about the layout properties."* When they *call* that function with `(tensor int 1 :global :compact)`, the compiler silently stamps out a specialized version of the function for that exact complete type. The function operates on the complete type, `(~ vector someIdx)` has all the metadata it needs to emit exact PTX, and the user never had to write out a massive template signature. The polymorphism is purely syntactic; the emitted code is fully specialized.

#### 2. Fat Records (Runtime Math, Zero Branching)
If you want to avoid stamping out dozens of monomorphized functions (which bloats compile times and binary size), you can selectively shift *some* properties to runtime without incurring the dreaded divergent branching of Method #1.

* **Compile-time mandatory:** Data type, Arity, `:address-space` (to emit the correct load/store instruction).
* **Runtime acceptable:** `:align` and `:contiguous-term`.

Because a `def-record` is virtualized, you can implement an incomplete `(tensor int 1)` as a "Fat Record" that carries its stride or offset math as hidden fields (registers). The accessor `(~ vector someIdx)` then compiles down to `base_ptr + (someIdx * vector.stride)`. 
This requires a couple of extra ALU instructions (register reads and a multiply) rather than an immediate constant, but it **does not branch**. It preserves performance while allowing functions to be genuinely polymorphic over memory layouts.

#### 3. Default Fallbacks and "View" Types
If a function truly only needs to read a 1D slice of data, you can introduce a concept of a normalized "View" (similar to Crisp's `soa-view`). If a user passes a complex strided tensor into a function expecting a generic `(tensor int 1)`, the compiler implicitly coerces it into a standardized fat-pointer view before passing it. This isolates the complexity.

### The Verdict on Incomplete Types for Storage Handles

For structs that purely hold data, incomplete types work beautifully. For Storage Handles, true incomplete types are a mirage because the memory access mechanics are entirely dependent on the missing information. 

If you stick strictly to Method #2, your best bet to avoid boilerplate hell is to lean heavily into **Implicit Monomorphization**, allowing the compiler to fill in the missing `:c-t` properties at the call site rather than forcing the user to declare them all in the function signature.


Chris Opines
============

OK. So Crisp has all of this. It has monomorphization and already does "implicit templating" for first order functions. I guess that could be expanded.



It also requires that all kernel arguments are complete. So if we want to walk the call tree, we can do that and that should resolve the monomorphic requirements.



But Crisp DOES have the strides, offsets and extents stored in compile-time fixed-length virtual arrays, ie "collection of registers". So Crisp can just do the math always with strides and offsets. But I'd rather not, since these accesses appear on the critical path (hate that phrase) and every cycle counts.


Gemini Replies
==============
Your reluctance to burn even a single ALU instruction on address math in the inner loop is entirely justified. When you are trying to saturate memory bandwidth or maximize warp occupancy, injecting an extra integer multiply-add (IMAD) into every single memory load or store is a heavy tax. You want that address to be an immediate offset whenever physically possible.

If Crisp requires complete types at the kernel entry point, you have the perfect anchor. By leveraging that, you can get the syntactic polymorphism of incomplete types without sacrificing a single cycle of runtime performance. 

Here is how you can synthesize top-down type propagation with your existing virtual arrays to solve this.

### The "Top-Down Monomorphization" Strategy

Since the root of the call graph (the kernel argument) is a complete type, every function call originating from that kernel can have its polymorphic arguments fully resolved at compile time. 

Instead of treating `(tensor int 1)` as a type that has erased its layout properties, treat it as a **template parameter constraint**. 

1. **The Kernel Boundary:** The kernel receives `(tensor int 1 :global :compact :last)`.
2. **Call Graph Propagation:** When the kernel calls a polymorphic helper function expecting `(tensor int 1)`, the compiler instantiates a monomorphized version of that helper function, secretly passing down the full `:global :compact :last` metadata.
3. **Compile-Time Folding:** This is where your virtual arrays of strides and offsets shine. 

### Relying on Constant Folding

You mentioned you *could* do the math using the strides and offsets from your virtual arrays, but you don't want to because it's on the critical path. 

**You can write the code to do the math, but rely on the compiler to erase it.**

If the monomorphization pass successfully propagates the complete type down to the accessor function, then the strides and offsets inside your virtual arrays are no longer runtime variables—they are **compile-time constants**.

For example, if the complete type dictates a `:compact` layout, the stride is strictly `1` and the offset is `0`.

* **Your internal macro/accessor logic emits:** `base_ptr + (idx * stride) + offset`
* **The complete type evaluates this as:** `base_ptr + (idx * 1) + 0`
* **The compiler's optimization pass (or the SPIR-V/PTX backend) folds this to:** `base_ptr + idx`

This approach offers a massive architectural advantage for Crisp:

* **User Ergonomics:** The developer writes clean, polymorphic code `(tensor int 1)` and doesn't template the layout properties.
* **Compiler Simplicity:** Your internal macro logic for `(~ destVector someIdx)` only has to be written *once*. It always emits the math using the virtual arrays. You don't need distinct code paths for complete vs. incomplete types.
* **Hardware Performance:** Because the complete type is pushed down from the kernel boundary, the optimizer constant-folds the arithmetic away. The emitted PTX/SPIR-V contains the exact same zero-overhead `LOAD`/`STORE` instructions as if the user had manually templated the whole thing.

As long as your AST walker or intermediate representation guarantees that the `:c-t` properties resolve to constants before the final backend emission, you get the absolute best of both worlds.


Chris Remarks
=============

I'll have to consult with Claude. He's much closer to the codebase and should be the final arbiter.


OK, that sounds solid vis-a-vis the Storage Handles.



Since we are on the topic, let's talk about OTHER incomplete types, especially user defined ones.  I think for those, we should just default to Method #2. The point is to make Crisp high performance, and we don't want users unknowingly introducing runtime divergence into their Crisp kernels.



And what about default values? I think we need to make it an implementation policy (along with testing) that at the kernel boundary, the defaults are used if not provided by the user. But in all OTHER functions, if the compile time property isn't present, then we don't default to the default, we instead treat it as an incomplete type.    BUT, what if the property is needed to actually compile the code at hand? Do we compile-time error? Or use the default?



Gemini Replies
=============
Your intuition is dead on. Committing to Method #2 (compile-time errors over runtime divergence) for user-defined incomplete types is exactly the right move for a GPU-targeted language. It upholds Crisp's core promise: predictable, high-performance execution without hidden cliffs.

Regarding your question about how to handle missing properties in helper functions when the code *actually needs* them: **You must throw a compile-time error. Do not fall back to the default.**

Here is the architectural reasoning for why falling back to the default in a helper function is a trap, and how your proposed implementation policy fits perfectly together.

### The Danger of "Helper Defaults" (Silent Corruption)
Imagine you have a user-defined struct with a default compile-time property: `(my-struct :layout :flat)`. 

1. A user writes a kernel that explicitly overrides the default: `(my-struct :layout :nested)`.
2. The kernel calls a polymorphic helper function that accepts `(my-struct)` (incomplete).
3. Inside the helper function, the code performs an operation that *requires* knowing the `:layout`. 

If your compiler says, *"I don't know the layout from this signature, so I'll just use the default `:flat` so I can finish compiling,"* you have just introduced a catastrophic, silent bug. The helper function emits IR assuming a `:flat` layout, but the actual runtime data being passed to it from the kernel is `:nested`. The kernel will compile successfully, run, and immediately corrupt memory.

### The Crisp Type Resolution Policy
Based on your logic and the requirement for top-down monomorphization, here is the ironclad policy you should implement:

**1. The Kernel Boundary Rule (The Root of Completeness)**
At the kernel entry point, all arguments *must* resolve to complete types. If a user omits a property here, the compiler injects the default value defined in the `def-struct`/`def-record`. 
* *Result:* The kernel boundary acts as the absolute source of truth. Every type entering the kernel is 100% complete.

**2. The Helper Signature Rule (Incomplete = Constraint)**
In any non-kernel function signature, an omitted property means "I am polymorphic over this property" (an incomplete type). The compiler does *not* inject defaults here. 
* *Result:* The function is treated as a template waiting to be monomorphized by a caller.

**3. The Usage Rule (Strict Monomorphic Resolution)**
When a helper function's body is being compiled/instantiated, it inherits the complete type properties passed down from its caller. 
If an operation inside the helper function requires property `X` to emit IR, the compiler checks the inherited complete type. 
* If `X` is present (because the kernel passed it down): Emit the IR.
* If `X` is *still* missing (e.g., the developer is trying to independently compile a generic function outside of a valid call graph, or the type propagation failed): **Throw a hard compile-time error.** ### Why the Error is the Right Choice
By throwing an error (e.g., *"Compile Error: Operation Y in function 'foo' requires property ':align', but the type is incomplete and cannot be resolved in this context"*), you force the user to do one of two things:
1. Ensure the function is only ever compiled as part of a valid call graph originating from a kernel (where the complete type is known).
2. Explicitly narrow the function signature to require that specific property, turning it from a fully polymorphic function into a partially polymorphic one.

This policy guarantees that defaults are only used to save typing at the *creation* of a type (the kernel boundary or explicit allocations), and are never used to blindly guess the *state* of a type during execution.


Chris Thinks
============

So if we go forward on this tack, 
- we'll need to test all the Storage Handle behavior discussed
(monomorphic capture, compiler optimizations )
- including compile-time errors
- AND the behavior for both def-struct and def-record that use :c-t props and then
use them polymorphically. 
- including errors
- we should also revisit 011-incomplete-types and see if those tests are both valid and useful
  in light of this design decision
- update the design doc appropriately
