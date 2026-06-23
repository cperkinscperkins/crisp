In this endeavor we are going to implement FFI support for Crisp.

The design document chapter for this feature is below.  I think we should break this up into a few passes.  In each pass we'll first write the TDD tests (and negative tests) we think are necessary, then implement.

Pass 1 - basic FFI, simple C scalar types.  no pointers or handles.   ✅ DONE (2026-06-23)

This is still a big pass, because it needs new Crisp forms supported, .bc args to the cmopiler, and possibly changes to run-specs.lisp for the test harness.

- [ ] make an external library (.c and .h) that has a basic float adding function.  Compile that to .bc and use that artifact in the tests.
- [ ] implement `def-foreign-function` such that supports basic types. 
- [ ] add support for .bc file argument to the compiler.
- [ ] make a .crsip file that uses `def-foreign-function` to define that float adding function, and invoke it from the kernel. 
- [ ] compile that .crisp with the .bc
- [ ] have a test use hoisting and  HOST-EXPECT: BUFFER directive to actually test our FFI "on metal".
 - - do we need a different .bc for Intel and Nvidia? ( spv and ptx ) ??  Might need two .bc and two tests?

Pass 2 - advanced scalar types: float4, uint2 etc.   ✅ DONE (2026-06-23) — zero compiler changes; rode entirely on Pass 1.

- [x] open question: how to best handle alignment?  ANSWERED: vector types pass by value as `<N x T>` and clang's per-target ABI handles alignment automatically (PTX shows `.param .align 16 .b8 ...[16]` for float4), matching Crisp's device-vector representation. No struct/byval/splitting. 
- [ ] new library functions for advanced scalar types.
- [ ] new .crisp tests to test them.

Pass 3 - pointers
- [ ] at the moment, only def-kernel-exact supports voidp and marshall-XXXX functions.  That restriction will have to be lifted. Might effects some existing tests. Not sure.
- [ ] what should the hoisting code do with voidp kernel args? USM alloc a small :device (or :shared ?) buffer and pass?  Maybe I shouldn't worry about this. 
- [ ] need to add `(base-ptr~ storage)` accessor to the storage. And, like `byte-size~` it should be a pass-through: `(base-ptr~ someCell)` should work just as good as `(base-ptr~ (parent~ someCell))`
- [ ] add new C function to our library that takes a pointer arg.
- [ ] add a .crisp test that calls that new function via the FFI. Passing it the base-ptr~ of some cell or vector , maybe?
- [ ] test on metal?

Pass 4 - handles
- [ ] add `voidp-handle` type 
- [ ] and `(voidp-handle)` type constructor.
- [ ] and `(voidp <some-voidp-handle>)` deref
- [ ] add new C function to our library that takes handle
- [ ] and .crisp file that binds and exercises.

Pass 5 - check "real" libraries
- [ ] bind something from libclc ? test
- [ ] bind something from libdevice ? test



=====================================================================
AMENDMENT (2026-06-23): Pointer & Handle API — supersedes the
"pointers and handles: voidp and voidp-handle" section of the Design Doc below.
=====================================================================

The original design assumed `voidp` (an opaque pointer) plus marshalling would
carry the address space. That doesn't hold: the *pointer value itself* carries
its address space at the LLVM/SPIR-V/PTX level, and this is one of the places
CUDA and SPIR-V diverge. A pointer crossing into a C function must already be in
an address space the C function's signature expects.

### The address-space reality

`voidp` currently hardcodes LLVM addrspace 0. The per-target meaning of 0 differs:

| Crisp `:address-space` | PTX addrspace | SPIR-V addrspace | notes |
|------------------------|---------------|------------------|-------|
| `:generic`             | 0             | 4                | the real "void*"; points anywhere |
| `:global`              | 1             | 1                | global buffer (portable!) |
| `:local`               | 3             | 3                | workgroup |
| `:constant`            | 4             | 2                |       |
| `:private`             | 5             | 0                | thread-private |

So `voidp` = addrspace 0 means **generic on PTX (works)** but **private on SPIR-V
(invalid for global data — llvm-spirv rejects it)**. Crisp ALREADY has a
backend-aware encoder (`encode-address-space`, src/types/validation.lisp) that
maps the table above correctly; `voidp` simply doesn't use it.

NOTE / pre-existing bug: this also affects `def-kernel-exact` — a bare `voidp`
kernel pointer param compiles on PTX but FAILS on SPV today (latent; no SPV test
exercises it). Additionally, on SPIR-V a *kernel* pointer param must be `:global`
(kernel args cannot be `:generic` or `:private`). So no single `voidp` address
space is correct for both the kernel boundary and a generic FFI call.

### Decision: explicit typed pointers are first-class

The real FFI/kernel pointer type is:

```
(c-pointer :address-space <:global | :generic | :local | :constant | :private>)
```

resolved per-target via `encode-address-space`. For global buffers (the common
case) use `:global` — it is addrspace 1 on BOTH targets, needs no cast, and is
fully portable. For generic-pointer libraries (CUDA libdevice) use `:generic`.

`voidp` is retained as a convenience **alias for `(c-pointer :address-space
:generic)`** — the honest "void*". (Fixing its two hardcoded `0`s to use the
`:generic` encoder is a small, separate step; it makes `voidp` work for FFI
generic-pointer calls on both targets. Kernel-boundary and global-buffer pointers
should use explicit `:global`.)

### `base-ptr~` accessor (Pass 3)

`(base-ptr~ <storage-handle>)` returns the handle's underlying pointer in its
NATIVE address space (e.g. a global cell → a `(c-pointer :address-space :global)`).
Like `byte-size~` it is a pass-through: `(base-ptr~ someCell)` works as well as
`(base-ptr~ (parent~ someCell))`. Passing it to a foreign param of the same
address space needs no cast; differing spaces are reconciled by an
`addrspacecast` in the existing value-coercion path.

### Per-target `.bc` compilation

Because the pointer address space is encoded in the `.bc`, the C source must be
compiled so its pointer params land in the matching address space:
- PTX/CUDA: plain/CUDA C (`int*` → generic addrspace 0; or annotate global).
- SPIR-V/OpenCL: OpenCL C (`-x cl`) with `__global int*` → addrspace 1 to match a
  `:global` Crisp pointer (zero cast), or generic for `:generic`.

The spec harness builds the `.bc` per target; an FFI spec may therefore carry a
target-specific C/CL source (e.g. a `.cl` for spv, a `.c`/`.cu` for ptx).

### Revised pointer example (Pass 3)

```
;; C (OpenCL, for spv): void write_seven(__global int *p) { p[0] = 7; }
;; C (CUDA/plain, for ptx): equivalent with a generic/global pointer

(def-foreign-function write_seven #'((c-pointer :address-space :global) => nil))

(def-type cell-int (cell int :address-space :global))

(def-kernel use_write (&out out-cell)
  (declare #'(&out cell-int))
  (write_seven (base-ptr~ out-cell)))   ;; out-cell then holds 7
```

### Handles (Pass 4) — revised

A handle is a `void**`: it has TWO address spaces — the slot's (outer, where the
`void*` lives) and the held pointer's (inner, where the data lives) — and they
are generally DIFFERENT. In `pool_alloc`, the handle is a kernel-local slot
(`:local`/`:private`) and the pointer it receives is `:global` (the allocation).
So the handle type must carry the held pointer's type:

```
;; type:        (c-handle <held-pointer-type>)   e.g. (c-handle (c-pointer :address-space :global))
;;              (the handle's own slot address space defaults to :local; optional override)
;; constructor: (make-c-handle (c-pointer :address-space :global))   ;; allocates the slot
;; deref:       (get-pointer <c-handle-obj>)  =>  the typed (c-pointer ...)
```

This replaces the original `voidp-handle` type, `(voidp-handle)` constructor, and
`(voidp <h>)` deref. The exact form (defaults, slot AS) will be finalized in
Pass 4 against the real `pool_alloc` signature so the `void**` address spaces match.

### Revised pass checklists

Pass 3 - pointers (decided: explicit typed pointers; on-metal via :global)
- [ ] make `(c-pointer :address-space X)` usable as a foreign-function param type
- [ ] add `(base-ptr~ <storage>)` accessor (pass-through; native address space)
- [ ] harness: per-target `.bc` build (OpenCL `__global` for spv; CUDA/plain for ptx)
- [ ] .crisp test passing `(base-ptr~ cell)` to a foreign function; compile ptx+spv
- [ ] on-metal test on the BMG (TEST-HOIST[L0], HOIST-EXPECT buffer)
- [ ] (separate, optional) fix `voidp` to use the `:generic` encoder (also fixes
      the latent def-kernel-exact-on-SPV case for generic pointers)

Pass 4 - handles (revised)   ✅ DONE (2026-06-23), verified on the BMG
- [x] `(c-handle <held-pointer-type>)` type — LLVM `ptr addrspace(0)` (the slot);
      held type tracked only in the Crisp type so get-pointer knows what to load.
- [x] `(make-c-handle <pointer-type>)` constructor — emits `alloca <held>`.
- [x] `(get-pointer <c-handle>)` deref — emits `load` of the held pointer.
- [x] C function taking a handle (`void**`): the outer/slot is addrspace 0 on both
      targets (opaque pointers erase the inner AS), so the foreign param is just
      `voidp`; the data pointer uses `__attribute__((address_space(1)))`.
- [x] .crisp test (06-ffi-handle-metal): make-c-handle -> give_ptr writes into it
      -> get-pointer reads it back -> write 7 through it. BUFFER out-cell: 7 on BMG.
NOTE: the slot addrspace turned out simpler than feared — the void** outer is
addrspace 0 (a device-function private param, VALID on SPIR-V, unlike kernel
params), matching make-c-handle's alloca. Only the inner data pointer carries the
global addrspace, and it's erased in the void** ABI by opaque pointers.

=====================================================================
END AMENDMENT.  The original design text below is kept for reference; where it
conflicts with the amendment above (the voidp/voidp-handle section), the
amendment wins.
=====================================================================


Design Doc Follows



## Foreign Function Interface (FFI) 📝

Crisp kernels can call functions from third party libraries (such as the OpenCL `libclc` library or NVidia's `libdevice` library, and others). The process is much like in C, simply name each function and its signature that you wish to use and pass its `.bc` when compiling.

### `def-foreign-function`
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

### pointers and handles: `voidp` and `voidp-handle`

> ⚠️ SUPERSEDED by the AMENDMENT (2026-06-23) above. This subsection's
> `voidp`/`voidp-handle` design is kept for reference only; use the typed
> `(c-pointer :address-space X)` / `(c-handle ...)` API from the amendment.

Just as in `def-kernel-exact`, pointer arguments to foreign functions can be declared with the `voidp` type. But note that to actually use a pointer or dereference it, you'll need to use a marshalling form (like `marshall-cell` or `marshall-vector`), which will require a complete type that has `:address-space`, `:align` and possibly other properties to be specified.

A `void**` "handle" type can be declared as `voidp-handle`. 

Additionally the form `(voidp-handle)` returns a `voidp-handle` type variable.
And `(voidp <voidp-handle>)` can be used to dereference the handle to a `voidp` type pointer (which could then be used with a marshalling routine)

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

(def-foreign-function pool_alloc #'(voidp ulong voidp-handle => int))

(def-kernel-exact use_pool_alloc (pool pool-size)
  (declare #'(voidp ulong => nil))
  (let ((vph (voidp-handle))
        (bytes (* 16 (byte-size float)))
        (err (pool_alloc pool bytes vph)))
    (when  (= err 0)
      (let ((v (marshall-vector (voidp vph) 16 float-vec-t)))
        ...))))
```

# basic invocation
```
crisp-compile.exe <some.bc> <another.bc> <some.crisp> --ir-target=ptx|spv


$ crisp-compile.exe myLib.bc someKernel.crisp --ir-target=ptx
```
Just add your library .bc file as an argument to the compiler.  As a general rule, the compiler will need to know the `--ir-target` (ptx or spv, and NOT `llvmir`) to correctly lower and bind.

# deferred invocation
NOTE: deferred FFI binding is not supported yet.

The library binding can be left unresolved and then someone needs to use nvlink (or whatever) to link cuBlas.a against someKernel.ptx 

```
crisp-compile.exe someKernel.crisp --ir-target=spv
```
