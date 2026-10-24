# Storage Handle Type Definitions ⚠️


Storage Handles are completely typed by 
- type of their element
- `address-space` (which is one of `:global` `:local` `:private` `:constant`)
- `align` (one of `:strided` or `:compact` or `:compact-offset`)  NOTE: `align` is not needed by the `cell` type.
- `contiguous-term` (one of `:first` or `:last`.  Defaults to `:last` if not provided)

A storage handle type may also carry a `:cache` hint (see *Cache hints* below).  The hint is NOT part
of the type: two declarations that differ only in `:cache` are the same type.

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
(cell <element-type> &key address-space cache)

;; for vector and matrix
(XXXX <element-type> &key align address-space (contiguous-term :last) cache)

;; for tensor
(tensor <element-type> NumDims &key align address-space (contiguous-term :last) cache)
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

#### Cache hints: `:cache` ✅

A `:global` storage handle type can say how its data should be cached.  The hint never changes a
result; it changes where the hardware keeps the data and how eagerly it evicts it.

```lisp
(def-type in-vec  (vector float :address-space :global :align :compact :cache :streaming))
(def-type in-vec2 (vector float :address-space :global :align :compact :cache (:streaming :prefetch 256)))
(def-type k-cell  (cell float :address-space :global :cache :reused))
```

The value is an intent, or a list of an intent and an L2 prefetch size:

| Intent | Meaning | PTX (loads / stores) | SPIR-V (L1, L3) |
|---|---|---|---|
| `:default` | no hint (same as no key) | — | — |
| `:streaming` | read or written once | `.cs` — evict-first in L1 and L2 | load Streaming, Streaming; store Streaming, Streaming |
| `:reused` | keep it cached | `.L2::cache_hint` under a `createpolicy ... L2::evict_last` policy (sm_80+; `L1::evict_last` on loads below sm_80) | load Cached, Cached; store WriteBack, WriteBack |
| `:no-l1` | skip L1, cache in L2 | `.cg` | load Uncached, Cached; store Uncached, WriteBack |
| `(INTENT :prefetch N)` | on an L2 miss, fetch N bytes (64, 128 or 256) | `.L2::NB` on loads | not mapped |

The hint applies to every access through the handle:

- **Views inherit it.**  `make-vector` and the other reinterpreting casts take no `:cache` argument; a
  view of a hinted handle is hinted the same way (a float4 view of a `:streaming` vector issues
  `ld.global.cs.nc.v4.f32`).
- **Tile operations honour it.**  `load-tile`, `load-tile-at`, `store-tile`, `store-tile-at`,
  `load-local`, `store-global`, and Intel's 2D block / cooperative-matrix loads, stores and
  `prefetch-tile` all take the hint from the handle's type.  A `:cache` key on the operation itself
  is refused: a per-operation override is not supported yet.
- **Read-only inference is separate.**  `.nc` (the read-only path) is never declared; Crisp adds it
  when it can prove a handle is not written (a tensor declared before `&out`), and it combines with
  every hint.  An argument the kernel writes is never marked read-only.
- **Adjoints do not inherit it.**  Under `--differentiate`, the gradient (shadow) buffers of a
  `_GRAD` kernel carry no hint, even when declared with the same type — an adjoint's access pattern
  is not the forward pass's.  The primal reads in the `_GRAD` kernel keep theirs.

Refused, with a message naming the legal values: an unknown intent; a prefetch size other than
64 / 128 / 256; a list that does not start with an intent (write `(:default :prefetch 256)` for
prefetch alone); `:cache` on `:local` memory (L1/L2 hints mean nothing for shared memory); `:cache`
on any address space but `:global`; `:cache` on a tile operation.

Not (yet) hinted, and left exactly as before: NVIDIA `cp.async` copies (4- and 8-byte copies have no
L1-bypass form, and L2 policies on `cp.async` need inline asm on shared addresses); TMA bulk copies;
PTX accesses of element types other than `float`, `double`, 32- and 64-bit integers (scalar, or 2- or
4-lane vectors); the L2 prefetch size on SPIR-V.

**What to expect.**  Measured on the GPU MODE `vectorsum` contest kernel (H100, 52M floats): about
3% with `(:streaming :prefetch 256)` and `(unroll 8)`, nothing on B200.  Earlier BMG matmul
measurements found Intel cache controls no faster than the driver default.  Treat `:cache` as a
tuning knob to measure, not a default.

<!-- IMPLEMENTATION NOTE (endeavour 192): -O3 drops metadata and narrows lane-accessed vector loads,
so nothing placed in codegen survives.  Codegen records, per entry point, physical-param-index ->
hint (and read-only-ness); a text pass over the POST-opt .ll (%apply-cache-hints-to-ll) walks each
addrspace(1) access back to its kernel argument (GEP / casts / inttoptr / phi / select).  PTX: hinted
accesses become `asm sideeffect` ld/st (ptxas schedules them as ordinary loads), the load/store
vectorizer runs first, and the module's PTX ISA is raised to >= 7.4; read-only arguments get
!invariant.load back (BUG 134).  SPIR-V: CacheControl{Load,Store}INTEL !spirv.Decorations on a typed
zero-offset GEP (plain accesses) or on the pointer's defining instruction (block / coop builtins).
tests/spec/192-cache-hints/cache-hints.md has the decisions and measurements. -->

