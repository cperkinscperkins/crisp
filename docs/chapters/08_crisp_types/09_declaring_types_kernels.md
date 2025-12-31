## Declaring Types - Kernels


### def-kernel

`def-kernel` defines a kernel function. It is much the same as `def-function` with only a few differences:

- `def-kernel` functions always returns NIL. It does not need to explicitly declare a return type.
- Storage Handle types (ie `cell` `vector`, `matrix` and `tensor`)  must be fully typed with address space, access, alignment and element type. (See Storage Handle Types below)
- `def-kernel` functions do NOT support `&key` or `&optional` arguments.
- but it DOES support `&out` 
- the function name for kernels MUST obey the C standard identifying rules.  Thus "do_something" is a valid name, but "do-something" is not.
- unlike regular functions, kernel functions do NOT support overloading. Each kernel function must have a unique name.
- `def-kernel` function has a constrained choice of accepts types for parameters. It does NOT support first order function arguments (unlike regular `def-function` and `def-grid-function`) nor can structs be passed as plain arguments (but they CAN be put in a Storage Handle )

Like `def-function` ALL the parameters to the kernel function must have their types declared somehow. 

```
; note the name "add_two" is a valid C identifier
; note also that since the arguments are typed in the parameter list, we didn't need a declare directive at all. 
;  the return type is assumed NIL.

(def-type int-result-cell (cell int :global :writeable))

;; -- add_two --
(def-kernel add_two (a b &out result)
   (declare #'(int int &out int-result-cell => nil))
   (set! (~ result) (+ a b)))
```

`def-kernel` can be templated ( see `with-template-type` below), but in this case you MUST explicitly provide a `gen-KERNELNAME` at the top-level
for each specialized kernel you want the compiler to generate. Otherwise the compiler will not output the kernel at all.  

### Implicit Arguments

The example hoisting code that Crisp outputs will often have more arguments than the ones in the parameter list of `def-kernel`.  

There are four different cases where this happens:
 - Storage Handle parameters (`cell`, `vector`, `tensor`)
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

<!-- NOTES
clSetKernelArg : https://registry.khronos.org/OpenCL/sdk/3.0/docs/man/html/clSetKernelArg.html
clEnqueueNDRangeKernel: https://registry.khronos.org/OpenCL/sdk/3.0/docs/man/html/clEnqueueNDRangeKernel.html
Note that nearly all the args for clEnqueueNDRangeKernel revolve around the NDRange (and event list). 

-->

### def-kernel-exact

`def-kernel-exact` is like `def-kernel` . It can be templated and has the same restrictions.  
But kernels defined with `def-kernel-exact` do NOT support any implicit arguments.  
Additionally the `&out` argument specifier is not supported in the param list for `def-kernel-exact`
Instead `def-kernel-exact` supports different marshalling functions to help create Crisp Storage Handles, 
including the ones required for the Crisp debug logging and scratch memory.

`def-kernel-exact` is provided for users who have less control over how their kernel is hoisted and may have to instead adapt to some existing interface.

#### voidp type and marshall-vector
`def-kernel-exact` can use the `voidp` type for its arguments, but this type cannot be used in other contexts.  It can also call the `marshall-XXXX` function
which is a function Crisp provides for making Crisp vectors from `void` pointers and byte counts. This function cannot be used in other contexts.

```
(def-type float-vec-t (vector float :address-space :global :align :compact))

;; -- vector_add_k --
(def-kernel-exact vector_add_k (APtr ASz BPtr BSz CPtr CSz)
  (declare #'(voidp ulong voidp ulong voidp ulong => nil))
  (let ((A (marshall-vector APtr ASz (float-vec-t :access :read-only)))
        (B (marshall-vector BPtr BSz (float-vec-t :access :read-only)))
        (C (marshall-vector CPtr CSz (float-vec-t :access :write-only))))
    (vector-add A B C)))
```

The recommended practice is to use marshalling functionss immediately within a `def-kernel-exact` body 
to create standard Crisp views, and then call some some inner function. That inner function will let you leverage
the `&out` specifier and possibly other safety checks. 


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





