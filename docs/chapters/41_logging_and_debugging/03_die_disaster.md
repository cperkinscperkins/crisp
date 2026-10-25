# `(die "disaster")` 📝


> **Implementation status**: today `die` lowers to `llvm.trap`.  On CUDA that halts the
> kernel (and poisons the context).  On L0 it is a **silent no-op** (BUG 136): the trap
> becomes `OpUnreachable`, and the driver deletes the branch.

```
(when (< index 0)
  (die "the index is negative? How did that happen?"))   ;; desperate times
```

The message must be a compile-time string.  It is optional.

What `die` promises:
1. **The first death is recorded** in the *die record*: a 16-byte module-scope global,
   `__crisp_die_record`, that the host finds by name (`zeModuleGetGlobalPointer` /
   `cuModuleGetGlobal`).  It is not a kernel argument, so it costs a kernel nothing, and
   `def-kernel-exact` kernels can `die` too.  The first thread to die claims it, and later
   deaths leave it alone.  The host zeroes it before every launch.  It is per module: two
   kernels of one module running at once share it.
2. **The dying thread stops.** It performs no further stores.
3. **Everyone else stops eventually.** Other threads stop at their next safe point or run to
   completion.  The kernel always finishes; `die` never hangs it.

What `die` does NOT promise: that the kernel stops *immediately*, or that work in other
workgroups is abandoned.  Results in any `&out` parameter are undefined after a death.

The die record is 16 bytes:

| field | meaning |
|---|---|
| `site_id` | which `die` (or assert, or bounds check) fired.  The metadata maps it to file, line and message.  0 = nobody died. |
| `group_id` | linear workgroup id of the thread that died |
| `local_id` | linear local id of the thread that died |
| reserved | |

After the kernel completes, the hoisting code checks `site_id`.  If it is nonzero it reports
something like:
```
DIE stencil.crisp:42 group 3 local 17: the index is negative? How did that happen?
```

#### How `die` halts

There is no instruction on either backend that ends a whole kernel cleanly.  NVIDIA's `trap`
comes close, but it poisons the CUDA context: the host cannot even read results back
afterwards.  So `die` ends only the dying thread:

- **PTX**: claim the record (atomic compare-and-swap), then `exit`.
- **SPIR-V**: claim the record, then return, and every caller returns too.  SPIR-V compute
  has no thread-exit instruction.

A thread that has exited counts as having arrived at later workgroup barriers, so the
threads that are still alive are not left waiting at a `(sync-workgroup)` the dead thread
never reaches.  This was measured on Intel BMG and on NVIDIA H100, both for one thread
exiting and for a whole warp/subgroup.

**Warp specialization** is the exception.  A consumer waiting on an mbarrier for a producer
that died would wait forever.  In kernels that can die, the compiler adds a check of the die
record to the wait loops it generates (mbarrier waits, last-man and CAS loops).  A waiting
thread that finds a death bails out as well.

Kernels that cannot reach a `die` pay nothing: no extra argument, no extra checks.


