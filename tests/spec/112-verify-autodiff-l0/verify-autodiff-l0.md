Endeavor 112 — verify-autodiff runner: OpenCL → Level Zero
==========================================================

> **Note on this directory.**  This is a *tooling* endeavor — porting the
> on-metal AD verification runner from OpenCL to Level Zero — not the
> usual kernel-feature spine.  The plan below is the primary artefact.
> The directory exists so the work has a numbered home and so any
> "canary"-style tests of the runner itself land alongside the plan.
>
> Canary specs (small, hand-authored kernels whose only job is to
> exercise the runner) are expected to land during phase 1c.2.c
> ("validation").  Names will be `01-canary-scalar-cell.crisp`,
> `02-canary-ulong-scalar.crisp`, `03-canary-vector.crisp`, with
> matching `RUNTIME[l0]` and (eventually) `RUNTIME[opencl]` crosscheck
> directives.


Goal
----
Restore green checkmarks on `--differentiate` runs of the spec suite, by
swinging `tests/verify-autodiff-runner.lisp` off the OpenCL ICD (regressed
on BMG, bug 031) and onto Level Zero (proven correct by the bug-031 L0
probe loader on the same SPVs).

Secondary goal: unblock real on-metal VERIFY-AUTODIFF coverage of the 111
load-tile / store-tile work where it intersects AD.

Tertiary goal: lay the runtime-seam straight enough that a third backend
(CUDA, when CUDA hoist lands after Phase 2) drops in without churn.

Why now
-------
- Bug 031 is filed with Intel but unbounded in fix-time; we can't gate AD
  work on their queue.
- L0 probe already validated the per-cell ABI translation end-to-end
  (forward + backward, FD-numerical + analytical both PASS).  No
  unknowns left in the GPU side of the port.
- The 111 AD compile-side is merged and untested on metal.  Carrying
  that uncertainty forward into Phase 2 (async tiles) compounds risk.

Counter-argument (momentum): pulling off the 111 critical path to do a
runtime port is a side-quest.  Mitigated by: (1) the port is genuinely
small (see "Scope" below), (2) the alternative is shipping 111 with
forward-only validators and hoping the AD path is right.


Scope
-----
The runner is one file, 905 lines.  The OpenCL surface is tightly
localised:

```
lines  29 – 108   :  ~85 LOC  - CFFI bindings + constants
lines 113 – 275   : ~160 LOC  - 14 helper functions wrapping the bindings
lines 514 – 905   : ~390 LOC  - verify-autodiff itself + descriptor logic
```

The helper layer (14 functions: `create-program-and-kernel`,
`create-float-cell-buffer`, `write-float-cell`, `read-float-cell`,
`bind-cell-arg`, `launch-kernel-1d`, `create-float-buffer`,
`write-float-vector`, `read-float-vector`, `read-float-vector-elem`,
`bind-vector-arg`, `bind-uint64-scalar-arg`, `bind-float-scalar-arg`,
`bind-int32-scalar-arg`, `bind-struct-by-value-arg`) is the seam.  The
390-line dispatcher only ever calls these helpers — it does not touch
CFFI or `cl-*` directly.  Almost.

What needs to change
--------------------
- Add ~15 L0 CFFI defcfun lines (zeInit, zeDriverGet, zeDeviceGet,
  zeContextCreate, zeModuleCreate, zeKernelCreate, zeMemAllocShared,
  zeMemFree, zeKernelSetGroupSize, zeKernelSetArgumentValue,
  zeCommandQueueCreate, zeCommandListCreateImmediate,
  zeCommandListAppendLaunchKernel, zeCommandQueueSynchronize,
  zeKernelDestroy, zeModuleDestroy, zeContextDestroy).
- Add L0-flavoured versions of the 14 helpers (`l0-bind-cell-arg`, …).
- Add a thin dispatch shim per helper that switches on a special
  `*ad-runtime*` (`:opencl` | `:l0`).
- Tweak `verify-autodiff` so that the small handful of places it
  bypasses the helpers (the platform/device/context/queue setup,
  raw `cl-create-buffer` for grad buffers, raw OpenCL types in
  bindings around line 569 – 604) become helper calls.

USM simplification
------------------
L0 USM-shared allocations come back as host-addressable pointers.
That eliminates `write-float-cell` / `read-float-cell` /
`write-float-vector` / `read-float-vector` as enqueue operations —
they become plain `(setf (cffi:mem-ref ...))` against the pointer
the buffer was allocated as.  Net code shrink in the L0 helper set.


Runtime-seam shape (forward-compat for CUDA)
--------------------------------------------
Two equally reasonable options:

  (a) `*ad-runtime*` defvar + `(case *ad-runtime* (:opencl …) (:l0 …))`
      in each of the 14 dispatch shims.  Adding `:cuda` = adding a
      third clause per shim.

  (b) Defgeneric per helper, eql-dispatched on a runtime tag symbol.
      Adding `:cuda` = adding 14 methods.

Both are 1-line-per-clause additions for CUDA.  (a) is fewer files and
easier to read in a 14-shim domain; (b) is more idiomatic CL and
easier to grep ("show me all the L0 impls").  I'd default to (a) but
am happy to take direction.


Phasing
-------

### Phase 1c.2.a — L0 reachability smoke test  (~½ day)

- [ ] Stand up CFFI bindings to `ze_loader.dll` in a new file
      `tests/l0-bindings.lisp` (so the runner file doesn't bloat past
      1000 lines).  Just the ~15 fns above plus the structs they
      need (ze_module_desc_t, ze_kernel_desc_t, ze_command_queue_desc_t,
      ze_command_list_desc_t, ze_device_mem_alloc_desc_t,
      ze_host_mem_alloc_desc_t, ze_group_count_t).
- [ ] Tiny standalone test script `scripts/l0-smoke.lisp` that loads
      `forward.spv` (the bug-031 probe SPV), launches once with
      `x=3, n=5`, reads `result`, asserts `result == 15`.  Mirrors
      what `loader_l0.cpp` already does, but in Lisp.  Confirms the
      bindings are correct end-to-end before we touch the runner.
- [ ] Document any L0 SDK gotchas in the bindings file (e.g. struct
      `stype` field discriminator, version field magic numbers).

Stop here if the smoke test fails — that's a binding bug to fix
before touching the runner.

### Phase 1c.2.b — Helper-layer parallel impl  (~½ day)

- [ ] In `tests/verify-autodiff-runner.lisp` (or a new sibling
      `tests/verify-autodiff-runner-l0.lisp`), add the 14 `l0-*`
      helpers.  Each is a 5- to 15-line CFFI wrapper.  Use the
      L0 probe loader as the reference implementation.
- [ ] Add a `*ad-runtime*` defvar (default `:l0`) and convert each
      existing 14 helpers to a dispatch shim that calls either the
      old `cl-*`-using body (now renamed `opencl-bind-cell-arg`,
      etc.) or the new `l0-bind-cell-arg`.
- [ ] Refactor the `verify-autodiff` body's setup section
      (lines ~569 – 614) to go through a couple of new helpers
      (`runtime-init` → returns context+queue, `runtime-shutdown`,
      `runtime-create-grad-buffer`) so the dispatcher is
      runtime-agnostic top-to-bottom.

### Phase 1c.2.c — Validation on the four broken specs  (~couple hours)

The four currently-failing AD-on-metal specs (from MEMORY.md / 
[bmg-driver-verify-autodiff-flakes]):

- [ ] `tests/spec/092-dotimes/07-diff-float-accum`     (the bug-031
      bellwether — must PASS or the port has its own bug)
- [ ] [other three specs to be enumerated from `plan/bugs.md` 031]

Run each through the in-process spec runner with `--differentiate` and
confirm PASS under `:l0` and (still) FAIL under `:opencl`.  The
OpenCL fail-state is now documentation, not a regression.

### Phase 1c.2.d — Spec-runner default flip  (~½ hour)

- [ ] Flip the default in `tests/spec-runner` / overlay so VERIFY-AUTODIFF
      directives use `:l0` by default.
- [ ] Add a `RUNTIME[opencl]` directive variant (or `:runtime :opencl`
      kw on `VERIFY-AUTODIFF`) so any spec that genuinely wants to
      crosscheck both runtimes can ask.  No spec should need this
      yet, but the hook is cheap and the day Intel ships a fix we'll
      want to retest the BMG OpenCL path.

### Phase 1c.2.e — Full-suite regression  (~½ hour, mostly wait)

- [ ] `sbcl --script tests/run-specs.lisp` (default pass) — confirm
      green; expect 715/715 or current count.
- [ ] `sbcl --script tests/run-specs.lisp --differentiate` — confirm
      this is back to all-green for the first time since the BMG
      driver update.  This is the actual headline result.
- [ ] If any spec regresses under L0 that was previously passing
      under OpenCL: that's a real L0-runner bug to fix, not a punt.

### Phase 1c.2.f — 111 AD-on-metal coverage  (blocked: runner needs local-scratch arg support)

Once L0 is the AD runtime, add VERIFY-AUTODIFF directives to a
handful of representative 111 specs (load-tile-at,
store-tile-at, the bare-sugar variants) to actually exercise
the Phase 1 compile-side AD on metal.  We've been running these
forward-only; the runner port is what unlocks them.  Pick maybe
3 – 5 spec files, not all 19, to keep the runner's wall-clock
manageable.

**Found while attempting this** (2026-05-23): adding VERIFY-AUTODIFF
to `111-load-and-store-tile/14-ad-identity-via-tile-1d.crisp` exposed
a separate runner gap.  The backward kernel signature is

```
ad_identity_via_tile_1d_grad(
  tile     : <local f32[4]>   ; 6 args: ptr addrspace(3) + 5 i64
  tile_ADJ : <local f32[4]>   ; 6 args: ptr addrspace(3) + 5 i64
  A        : <global f32[4]>  ; 6 args
  C        : <global f32[4]>  ; 6 args
  C_GRAD   : <global f32[4]>  ; 6 args  (input seed)
  A_GRAD   : <global f32[4]>) ; 6 args  (output)
```

— 36 args.  Two of those vector descriptors are :local addrspace
scratch tiles (the original `tile` plus the AD-minted `tile_ADJ`
shadow that load-tile-at-bwd accumulates into before
%load-tile-at-bwd scatters with atomic-add!).

The runner's `bind-vector-arg` only knows how to bind global
buffers.  For :local addrspace vectors the binding is different:
the pointer arg is set to NULL with just a byte-size (the runtime
allocates the local memory at launch); the other 5 i64 metadata
args are set normally.

Symptoms when this is missing: under L0 the kernel runs with
zero/NULL scratch pointers and silently produces zero gradients
(no -52-style "invalid kernel arg" error, unlike OpenCL).  So the
spec FAILs with `analytical=0.0, expected=1.0` rather than refusing
to launch.

Sub-tasks:

- [ ] Teach `%vad-make-descriptors` (or the kernel-scanning side of
      VAD) to detect :local-addrspace vector params and emit a new
      `:scratch-vector` descriptor kind.
- [ ] Add `bind-local-scratch-vector-arg` + opencl/l0 impls + a
      dispatch shim.  L0: pass NULL with byte-size for the ptr arg,
      normal i64 sets for the rest.
- [ ] Re-add VERIFY-AUTODIFF to `14-ad-identity-via-tile-1d` and
      pick 2 – 4 more 111 specs.

This is bounded but not a 10-minute fix; the descriptor-scanning
side of the runner needs to know which kernel arg slots are local
vs global, which means it has to read the SPV (or be told by the
spec directive).  Probably ~½ day on top of the L0 port.

Recommendation: ship Phase 1c.2.a–e as-is (suite is green; bug-031
is resolved), break 1c.2.f into its own follow-up endeavor or roll
it into Phase 2's 111 AD-coverage push, where having the runner
local-scratch story sorted naturally pays for itself.


OpenCL-in-parallel decision
---------------------------
Keep OpenCL alive behind `:opencl`, default to `:l0`.  Two reasons:

1. Crosscheck value.  If Intel ships an OpenCL fix and a *different*
   regression slips in later (theirs or ours), having the second
   runtime gives us the same diagnostic we just used for bug 031.
2. The cost is small.  The OpenCL helpers already exist; they just
   get renamed `opencl-*` and stop being default.  No active
   maintenance burden unless the OpenCL API itself shifts (it won't).

Delete OpenCL only if it actively rots — i.e., the next CFFI binding
update breaks it and nobody's run `:opencl` in a month.  Until then,
two runtimes is cheap insurance.


CUDA future-proofing
--------------------
Minor.  The 14-helper seam + `*ad-runtime*` dispatch shim makes adding
a third runtime mechanical: write 14 `cuda-*` helpers (each thin over
the CUDA driver API), add a `:cuda` clause to each shim, document any
gotchas in `tests/cuda-bindings.lisp`.

The only thing worth front-loading for CUDA is *naming discipline*:
helpers should be named after their semantic role (`bind-cell-arg`,
`launch-kernel-1d`), not after OpenCL concepts (`bind-arg-to-mem-object`).
The current names are already neutral.  Good.

We are explicitly NOT building a runtime-ops protocol object, a
plugin-discovery mechanism, or a defclass hierarchy.  Three runtimes
is not enough to extract a real interface from; we'd be making the
wrong abstraction.


Risks / unknowns
----------------
- **L0 module-build error reporting:** if `zeModuleCreate` fails on a
  SPV, the error message lives in a build-log retrieved via
  `zeModuleBuildLogGet*`.  We need to wire that through or
  validation failures will be cryptic.  Plan to crib the build-log
  scaffolding from `loader_l0.cpp` (it's already there).
- **USM allocation lifetime:** L0 USM allocations are tied to a
  context; cleanup ordering matters more than under OpenCL.  Wrap
  every alloc in unwind-protect; mirror `loader_l0.cpp`'s pattern.
- **Group-size hints in the SPV:** the kernels were authored with
  fixed `local-size :set-to N`.  L0 honours these via `zeKernelSetGroupSize`
  before launch; we must call it.  OpenCL was getting away with
  null `local_work_size`.
- **mingw vs MSVC linkage:** the loader is dispatched through
  `ze_loader.dll`; CFFI loads it fine on both, but if anyone runs
  on Linux the path-finding logic needs `ze_loader.so` fallback.


Definition of done
------------------
Per [definition-of-done.md]:

- [ ] All four bug-031 specs PASS under `--differentiate` with
      `*ad-runtime* = :l0`.
- [ ] Full suite green on both default and `--differentiate`.
- [ ] 3 – 5 of the 111 spec directory's load-tile/store-tile specs
      have working VERIFY-AUTODIFF directives passing on metal.
- [ ] `MEMORY.md` updated: bug 031 status, AD-runtime defaults to L0,
      OpenCL is opt-in.
- [ ] Bug 031 entry in `plan/bugs.md` marked `[x]` (or moved to a
      "waiting on Intel" section if the OpenCL fix never lands).


Estimate
--------
~1½ – 2 focused days end-to-end, split roughly:
  - 1c.2.a (smoke):       half day
  - 1c.2.b (helpers):     half day
  - 1c.2.c – e (validate, default, suite): half day
  - 1c.2.f (111 coverage): half day (next session)

Plenty of room for L0 SDK surprise on phase a; if smoke fails we
stop and triage there, the rest doesn't move forward.
