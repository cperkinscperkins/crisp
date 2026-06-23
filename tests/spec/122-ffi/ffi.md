In this endeavor we are going to implement FFI support for Crisp.

The design document chapter for this feature is below.  I think we should break this up into a few passes.  In each pass we'll first write the TDD tests (and negative tests) we think are necessary, then implement.

Pass 1 - basic FFI, simple C scalar types.  no pointers or handles.

This is still a big pass, because it needs new Crisp forms supported, .bc args to the cmopiler, and possibly changes to run-specs.lisp for the test harness.

- [ ] make an external library (.c and .h) that has a basic float adding function.  Compile that to .bc and use that artifact in the tests.
- [ ] implement `def-foreign-function` such that supports basic types. 
- [ ] add support for .bc file argument to the compiler.
- [ ] make a .crsip file that uses `def-foreign-function` to define that float adding function, and invoke it from the kernel. 
- [ ] compile that .crisp with the .bc
- [ ] have a test use hoisting and  HOST-EXPECT: BUFFER directive to actually test our FFI "on metal".
 - - do we need a different .bc for Intel and Nvidia? ( spv and ptx ) ??  Might need two .bc and two tests?

Pass 2 - advanced scalar types: float4, uint2 etc.

- [ ] open question: how to best handle alignment? 
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
