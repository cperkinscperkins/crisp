Curious Things To Know About Crisp
==================================

- recursion (and mutual recursion) are DISALLOWED.
- unbound loops (such as "while") are DISALLOWED.
- Crisp has "let", which behaves like Common Lisp "let*".  AND Crisp "let" supports multiple value binding.
  There is no "let*" in Crisp itself.  (let ((quot rem (div 10 3))) ...)
- but a subset of Common Lisp is used in defmacro. It is expected to expand into Crisp forms.
- Crisp has template support  (with-template-type (T) ...)  
- passing functions as first order arguments means the function is implicitly promoted to a template (if not already templated), specialized on <F>, and then we monomorphically instantiate the actual function arg.
- functions with &optional and &key parameters have their combinations monomorphically templated. lazy instantiated though to fulfill actual calls.
- def-struct maps to a linear block of memory, whereas def-record maps to individual register addresses.  def-struct and def-record have the same affordances (property accessors, etc) but very different approaches
- all def-record based items lead to Architectural Scalar Replacement of Aggregates (SROA).  When anything based off def-record as passed as a function argument, in the LLVM-IR it gets exploded to the individual properties, each one passed as an argument, and implicitly reassembled by the callee.  
- def-kernel-exact uses marshall-XXXXX functions to take individual parameters passed by the host to the kernel and "marshall-XXXX" them into Storage Handles (which are based on def-record)
- def-kernel usually has Storage Handles are parameters, it gets macroexpanded into def-kernel-exact.
- Crisp does not have the Common Lisp `let` or `let*`. It has its own `let` which is like `let*` except it supports multiple value bind directly.
- Crisp leverages Common Lisp's macro support. Thus users can use defmacro and some Common Lisp forms to expand to Crisp forms. The supported Common Lisp forms are documented in defmacro-utils.md
- Crisp also uses Common Lisp macros to expand some of its own forms (def-function and others) into semantic nodes.
- the Spir-V metatadata is injected manually, rather than using LLVM Dev bindings.
- By default, the LLVM-IR is output to *standard-output*, and Log4CL messages are sent to *error-output*.    
- Crisp does NOT use Common Lisp style type declarations.  It uses
  a 'declare' form that either has individual `type` and `return-type` declarations, or it uses a single arrow syntax.  
  Example:
  ```
    (declare (type x y int) (return-type float))
    (declare #'(int int => float))
    ;;multiple value return is supported as well:
    (declare (type x int) (type y int) (return-type int int))
    (declare #'(int int => int int))
  ```
- Crisp defaults to "multipass" compilation. But it does support a --single-pass mode as well. When performing --single-pass the .crisp file MUST provide all functions and structs etc in reverse dependency order. Failure to do so is a compilation error.  There is a --single-pass mode for the tests as well.

- Crisp has a user-adjustable type hierarchy for both numeric types and structs and records. 
  The hierarchy isn't a traditional tree, it's a DAG, where a single type
  can have both multiple descendants and multiple ancestors.  The "derived type" system is very powerul, allowing users
  to use the type system to make a type for "meters" and for "yards" (for example) that cannot be in mixed math operations.  
- with `set-derived` the type system can also be used to do  C++ style subclassing between structs.
- the type DAG is via `:subst :ancestor` or `:subst :descendant` when deriving types via `def-derived-type` or `set-derived`

- Crisp has "branded" types. This is available only inside def-struct and def-record declaraations. Essentially, the user can declare a branded type using `(brand newTypeName originalType ...)` and then use `newTypeName` as the type of some member of the struct
or record.  The actual type is specialized to the object INSTANCE.  The other args to `brand` are the substitution keys that are used by `def-derived-type`.

- Crisp supports auto-differentiation with the `--differentiate` flag. Only kernels with `&out` output params can be differentiated
- The Crisp auto-differentiation leans towards mathematical correctness. For example kernels
  with Storage Handles of ints or scalar ints ARE differentiated, their gradients in the backward
  kernel are promoted to floats. 


# def-struct vs def-record

## Summary

`def-struct` and `def-record` are correctly defined and behave differently at function boundaries, but share similar codegen paths within function bodies. This document clarifies what works, what's suboptimal, and what might need future attention.

---

## Design Intent

From the design documents:

**`def-struct`:**
- Maps to **contiguous memory**
- Passed as a single aggregate parameter
- Members accessed via GEP operations
- Used for actual memory-backed structures

**`def-record`:**
- Maps to **individual registers** (no contiguous memory)
- Undergoes **Scalar Replacement of Aggregates (SROA)**
- Parameters are **exploded** at function boundaries
- Zero-cost abstraction for views (cell, vector, matrix, tensor)
- Enables efficient mutation through register shadowing/rebinding


Note that BOTH def-record and def-struct can appear on the kernel boundary.  In the case of def-record, the host code has to pass each property as an individual arg.  And that record
is mutable. It can't be used to transmit data back to the host or even to another thread,
but if kernel receives a point record as a direct argument and modifes its x~ value and then sends the point to a sub-function, that sub-function gets the modified x.

But for def-struct that are passed directly at the kernel boundary we carve out some contstnat memory and it is NOT mutable.  The compiler needs to track that the struct orignates at the kernel boundary and error if there is an attempt to modify it (if it were DIRECTLY passed, rather than in a cell or something).

---

## Storage Handles: cell, tensor, vector and matrix

`cell` is defined as a `def-record`. It has two members: `storage` and `offset`.  `storage`, is, in turn
another `def-record` that tracks a pointer and a byte size.
`tensor` is also a `def-record` with a `storage`. It's arity must be known at compile time. It
also tracks strides, offsets, and extents in compile-time fixed size virtual arrays (collection of registers). Tensors also have a `:align` compile time property (which can be `:compact`, `:compact-offset` or `:strided`)  and `:contiguous-term` (which can be `:first` or `:last`).
`vector` is simplay a tensor where N=1, and `matrix` is tensor with N=2.   When `:align` is `:compact`
the tensor aref access functions `(~ someTensor ... someY someX)` do not use the stride or offset in 
their calculation

When a record is passed as an argument to the kernel or function, it is exploded into its component registers.  And when a nested record is passed, it is "flattened" and exploded. So a `cell` should
appear as THREE arguments (storage-ptr, storage-bytesize, cell-offset).  This has been a source of bugs in the past.  A `matrix` would be EIGHT arguments (two for `storage`, plus two each for `strides`, `offset` and `extents`). 

## Scratch Cells/Tensors
Kernels cannot allocate memory, but Crisp let's users make a "scratch" Storage Handles. scratch Storage Handles are then implicitly added to the parameter list of the kernel, as well as ALL the functions in the call tree between the 'make-scratch-cell' call and the kernel.  Below that
they would be passed explicitly by the user, as normal.  

Scratch Cells are our first "Side Channel" Storage Handle.

Look at this calling tree

Kernel_A()
 => B()
   => C()
     c = make-scratch-cell
     => D(c)
      => E(c)

The scratch cell is instantiated in C(). But kernels cannot allocate memory. So the scratch
cell needs to implicitly added as a "Side Channel" to call chain from the kernel to C().
Below that, the cell can be passed explicitly and does not need "Side Channel" modification.
Crisp also has `make-scratch-vector`, `make-scratch-matrix` and `make-scratch-tensor` which all
work similarly.


## Global vs. Local address space

"scratch" cells are default to :local address space. ( of course, the user can specify :global if they want to.).

Local address space is handled slightly differntly CUDA vs L0/OpenCL. This might affect both the
codegen and the hoisting.  We 100% need to test some of these kernels on both before advancing.


## Related Files

- Type definitions: `src/compiler.lisp` (lines 116, 128)
- Test case: `tests/spec/010-def-record/17-record-compare-struct.crisp`
- Smoke test: `tests/spec/023-spirv/01-smoke.crisp`
- Design docs: `docs/chapters/08_crisp_types/12_def_record.md`

# (array T N)

The fixed array declaration is normally for compile-time known contiguous data.

BUT if the (array) declaration is inside a def-record it is a VIRTUAL array, and is SROA exploded just
like any record var when being passed to functions or kernels.


# Vectors, Tensors, and Matrices

So ALL Storage Hnadles (not just cell) are realized via def-record, so they are "virtual" structs, just
collections of registers.  Moreover, vectors, tensors, and matrices have several (array ulong N) internal
entries: `extents`, `offsets` and `strides`.  These are each VIRTUAL arrays and are mutable collections of
registers.

## align: :compact :compact-offset :strided
The vectors, matrices, and tensors all have an :align compile time attribute. 
When :align is :compact then the `~`  accessors `(~ someVec someIndex)` IGNORES the strides and offsets
making it faster.  For `:compact-offset` only the :stride is ignored.  and for `:strided` everything is considered.

But note that for a :compact storage handle, the normally mutable extents~, strides~ and offsets~ properties
throw a compile error if someone tries to modify them. A reinterpreted view will be needed.


## Implementation: package name qualifiers.

You'll sometimes see the following symbols package qualified with `cl:`

Sometimes:
`let`, `when`, `unless`, `cond`, `return` — Crisp redefines these as real host macros → bare name works (after src/macros loads).  But BEFORE src/macros.lisp loads, they may need to be qualified.

Alwyas:
`truncate`, `floor`, `ceil`, `round` — initialize-compiler installs cl:* counterparts at startup, but bootstrapping code in initialize-compiler itself still needs `cl:` on the right-hand side of those assignments
`char`, `short`, `float`, `double`, `int`, `long`, `sin`, `cos` etc. — Crisp type symbols with no CL function binding → always need cl: when used as CL functions (e.g. `(cl:char str idx), (cl:float x)`)


### cl:return
Final rule for `cl:return` in `:crisp.compiler` files:

Crisp's return macro expands to (explicit-return ...) — which is only valid inside the Crisp kernel compiler context. Anywhere in host Lisp implementation code that uses return to exit a loop or block, you need cl:return. The tricky cases are:

Pattern	Needs cl:?
(loop ... (return value))	Yes — bare function-call style
(loop ... (when ... (return)))	Yes — same
(loop ... finally (return x))	Yes
(loop for x when pred return x)	No — return as a LOOP keyword (word position, not a call)
'(def-function ... (return val))	No — inside a quoted Crisp kernel form



# Incomplete Types:  monomorphization
Any `def-record` or `def-struct` can have `:c-t` compile time properties. These properties
become part of the type definition.  In Crisp all type declarations at the kernel boundary
must be complete. But for functions, there is a simple polymorphism where the `:c-t` props
can be skipped.  This results in, yet again, lazy monomorphic template specialization 
of these functions, specialized on the `:c-t` props used. Remember Storage Handles are 
`def-record` and have quite a few properties.
See ./tests/spec/099-incomplete-types-revisited/incomplete-type-revisit.md if there are questions.

