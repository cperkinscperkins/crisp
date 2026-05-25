Endeavor 114 — Async tile codegen on metal (SPV `OpGroupAsyncCopy` + PTX `cp.async`)
======================================================================================

> **Status: planning stub.**  Endeavor 113 delivered the front-end +
> AD pre-rewrite + fallback-to-sync lowering on both backends.  This
> endeavor replaces the fallback with the real backend-specific async
> machinery so memory-bound tile-heavy kernels can hide their load
> latency.  Splitting it from 113 was a deliberate choice: 114 is
> LLVM-intrinsic spelunking + per-backend IR validation +
> Colab/RunPod hardware verification, a different character of work
> than 113's front-end story.


Why this matters
----------------

The `request-load-tile` / `await-request` API in 113 ships as theatre
on its own — every request runs a synchronous cooperative copy, and
the await is a no-op.  The user-visible API is correct and forward-
compatible, but **no overlap of memory transfer with compute is
happening**.  The canonical patterns this API exists to enable —
double-buffered GEMM, multi-stage pipelined tile kernels, anything
where compute throughput exceeds memory bandwidth — get no speedup
until 114 lands.

This endeavor is the perf delivery.


Goal
----

Replace 113's fallback lowering with real async on both backends:

- **SPV**: `OpGroupAsyncCopy` (lowered from `async_work_group_copy`) +
  `OpGroupWaitEvents` (lowered from `wait_group_events`).  Token =
  SPV `event_t` opaque type stashed in a hidden kernel-scope slot.
- **PTX-Ampere**: per-thread `cp.async.ca.shared.global` inside the
  existing cooperative loop, plus `cp.async.commit_group` after the
  loop and `cp.async.wait_group 0` at the await.  Token = FIFO commit
  depth (implicit, no runtime carrier needed).

Plus the two enforcement specs that the fallback couldn't usefully
police:

- **Missing-target gate**: error out cleanly when `*target-backend*` is
  `:generic` (no `--ir-target` flag) — the lowerings are
  fundamentally different per backend, no meaningful generic IR.
- **Single-outstanding enforcement**: error out at compile time if a
  second `request-*` is issued before the prior token is awaited.
  Matches cp.async's FIFO semantics and avoids the multi-outstanding
  hazards we're deferring to a later "real-runtime tokens" endeavor.


Research findings (Phase 0, recorded 2026-05-24)
------------------------------------------------

Toolchain pinned to LLVM 21.1.5 (llc) + LLVM 22.0.0-git (llvm-spirv,
Khronos translator) as bundled with Crisp `tools/`.

### SPV (`__spirv_GroupAsyncCopy` direct form, NOT mangled OpenCL)

The mangled OpenCL form (`_Z21async_work_group_copyPU3AS3...`) is
NOT recognised by llvm-spirv 22 — it survives translation as an
`Import` LinkageAttribute, which would fail at L0 module-create
(`ZE_RESULT_ERROR_INVALID_MODULE_UNLINKED`).  The `__spirv_*` direct
form IS recognised and emits the native `OpGroupAsyncCopy` /
`OpGroupWaitEvents` opcodes.

Confirmed empirically with a hand-crafted IR roundtrip
(`c:/tmp/async_copy_smoke2.ll`).

```llvm
declare spir_func ptr @__spirv_GroupAsyncCopy(
  i32, ptr addrspace(3), ptr addrspace(1), i64, i64, ptr)

declare spir_func void @__spirv_GroupWaitEvents(
  i32, i32, ptr addrspace(4))

;; usage:
%evt = call spir_func ptr @__spirv_GroupAsyncCopy(
          i32 2,                       ;; scope = Workgroup
          ptr addrspace(3) %tile,      ;; dst (local)
          ptr addrspace(1) %src,       ;; src (global)
          i64 %count,                  ;; element count
          i64 1,                       ;; element stride (1 = contiguous)
          ptr null)                    ;; prev event (null = start)
store ptr %evt, ptr %evt_slot
%generic_slot = addrspacecast ptr %evt_slot to ptr addrspace(4)
call spir_func void @__spirv_GroupWaitEvents(
       i32 2, i32 1, ptr addrspace(4) %generic_slot)
```

Translates cleanly to:

```spirv
... GroupAsyncCopy ...
... GroupWaitEvents ...
```

Event type: opaque `ptr` (the translator infers `OpTypeEvent` from
context).  No need to declare `%opencl.event_t` or `%spirv.Event`
explicitly.

### PTX (NVVM intrinsics in LLVM 21)

Confirmed empirically with `c:/tmp/cp_async_smoke.ll` →
`llc -march=nvptx64 -mcpu=sm_80`:

```llvm
declare void @llvm.nvvm.cp.async.ca.shared.global.4(
  ptr addrspace(3), ptr addrspace(1))
declare void @llvm.nvvm.cp.async.ca.shared.global.8(
  ptr addrspace(3), ptr addrspace(1))
declare void @llvm.nvvm.cp.async.ca.shared.global.16(
  ptr addrspace(3), ptr addrspace(1))
declare void @llvm.nvvm.cp.async.commit.group()
declare void @llvm.nvvm.cp.async.wait.group(i32 immarg)
```

Lowers to:

```
cp.async.ca.shared.global [dst], [src], 8;
cp.async.commit_group;
cp.async.wait_group 0;
```

Payload size: per-thread 4 / 8 / 16 bytes only.  For element types
that don't match a power-of-two-byte boundary (e.g. `half` = 2),
either coalesce two halves per cp.async or fall back to sync.

Compute capability: cp.async requires sm_80+ (Ampere).  Crisp's
current PTX default is `sm_50` (Maxwell).  Two options for 114:

1. Bump the default to sm_80 globally — simple, but rejects older
   GPUs even for kernels that don't use async ops.
2. Auto-bump per-kernel when async ops are present — cleaner but
   requires per-kernel compute-capability tracking that doesn't
   exist yet.

Going with **option 1** for 114 (just bump the default).  Maxwell is
ancient and the dev/CI box runs Battlemage / Hopper anyway.

### Address-space mapping

Both backends use addrspace(3) for shared/local, addrspace(1) for
global, and addrspace(4) for generic.  Same numbers — convenient
accident of history.  Confirmed.


Research discipline — what to look up before writing a line
-----------------------------------------------------------

This is the explicit "no programming by fumbling" guard.  Three
specs to nail down by reading the source-of-truth:

1. **LLVM-SPIRV translator intrinsic shape for `OpGroupAsyncCopy` /
   `OpGroupWaitEvents`.**  The Khronos llvm-spirv binary recognises
   specific function names/manglings.  Verify against the version we
   build with:

   - Direct intrinsic form: `@__spirv_GroupAsyncCopy(i32 %scope, ptr
     addrspace(3) %dst, ptr addrspace(1) %src, i64 %count, i64 %stride,
     <event-type> %prev)` — exact name + arg order + event type.
   - OR OpenCL-style mangled form: `@_Z21async_work_group_copyPU3AS3...`
     — works on more translator versions, more brittle to type-spell.
   - Event type: `target("spirv.Event")` in recent LLVM /
     `%opencl.event_t*` in older.  Check `lib/SPIRV/SPIRVBuiltins.td`
     in the Khronos translator repo for the active version.
   - Scope enum value for "Workgroup" (typically 2).

2. **NVPTX intrinsics for the cp.async family.**  Look up in
   `llvm/include/llvm/IR/IntrinsicsNVVM.td`:

   - `@llvm.nvvm.cp.async.ca.shared.global.4` / `.8` / `.16` — per-thread
     async copy for 4/8/16 byte payloads (and the `cg` cache variant
     `@llvm.nvvm.cp.async.cg.shared.global.16`).  Verify arg order and
     address-space conventions.
   - `@llvm.nvvm.cp.async.commit.group` — argument list (probably none).
   - `@llvm.nvvm.cp.async.wait.group(i32 N)` — wait for all but the N
     most recent groups.  For single-outstanding, N=0.
   - Lowest-supported PTX/SM target — Ampere is `sm_80`.  Need to set
     the right NVPTX target features or the intrinsics get rejected.

3. **Address-space mapping.**  Both backends use addrspace(3) for
   local/shared and addrspace(1) for global — accident of history but
   convenient.  Verify against the Crisp existing convention (it's
   already this way in 111).


Phasing
-------

### Phase A — SPV codegen for request-load-tile-coords

- [ ] Research items 1 above; write findings as comments in the
      codegen helper.
- [ ] New codegen helpers:
      - `%gen-spirv-async-work-group-copy` — emits the
        `__spirv_GroupAsyncCopy` (or mangled OpenCL) call, returns
        the event value.
      - `%gen-spirv-wait-group-events` — emits the
        `__spirv_GroupWaitEvents` call.
- [ ] New semantic node + `generate-node-ir` method for an
      `async-tile-copy` form (or extend the existing tile-coords
      node with an `:async-p` flag).
- [ ] Replace the fallback path in
      `%expand-request-load-tile-coords-form` (currently delegates to
      sync) with a new expansion that emits the async-tile-copy node
      on `*target-backend* = :spirv`.
- [ ] Hidden pending-event slot per kernel — an `alloca event_t` at
      kernel entry, stored to by request-*, loaded from by await-*.
- [ ] Validation: compile 113/01 with `--ir-target=spv`, inspect IR
      for the async_work_group_copy / OpGroupAsyncCopy call.
      llvm-spirv round-trip to confirm the translator accepts it.

### Phase B — PTX codegen for request-load-tile-coords

- [ ] Research items 2 above.
- [ ] New codegen helpers:
      - `%gen-ptx-cp-async-elem` — per-thread cp.async for one element
        (sized by elem type).
      - `%gen-ptx-cp-async-commit-group`
      - `%gen-ptx-cp-async-wait-group`
- [ ] Replace the fallback path on `*target-backend* = :ptx` with the
      cooperative loop pattern of sync load-tile-coords, but with the
      per-thread inner-body emitting cp.async instead of a regular
      store.
- [ ] Validation: compile 113/01 with `--ir-target=ptx`, inspect IR
      for `@llvm.nvvm.cp.async.ca.shared.global.*` +
      `@llvm.nvvm.cp.async.commit.group` +
      `@llvm.nvvm.cp.async.wait.group`.
- [ ] Colab / RunPod: actually run the kernel on an Ampere+ GPU and
      verify correctness against a sync reference.

### Phase C — Missing-target gate

- [ ] Add `%request-tile-check-target` to the analyzers (was removed
      in 113 because fallback was target-agnostic).  Now that the
      lowering branches on `*target-backend*` and there's no
      meaningful generic IR, `:generic` is a hard error.
- [ ] Reintroduce `errors/01-request-needs-ir-target.crisp` (was
      deleted in 113 Phase 1a for the same reason).
- [ ] Make sure the spec runner's "Default" pass (which uses
      `:generic`) still works for the rest of 113's specs — likely
      means those specs need `;; SKIP-WITH[default]: "needs --ir-target"`
      or similar, OR we make the default pass set a backend.

### Phase D — Single-outstanding scope table

- [ ] Compile-time scope table that tracks pending tokens through
      analyze-let / analyze-progn.  Issuing a second request-* while
      a token is pending = error.  Awaiting a token = clears the entry.
- [ ] Special-var binding at kernel-analyze entry so state doesn't
      leak across kernels.
- [ ] Reintroduce `errors/02-double-request-no-await.crisp` (was
      deleted in 113 Phase 1a).

### Phase E — Async store on backends where it exists

- [ ] SPV: `async_work_group_copy` with reversed addrspaces (global←
      local) — supported on most ICDs but check.  Fallback to sync if
      not supported.
- [ ] PTX-Hopper: `cp.async.bulk` with TMA — requires host-side
      TensorMap descriptors, which needs hoist-side work that doesn't
      exist yet.  Defer to its own endeavor.
- [ ] PTX-Ampere: no async store hardware support — stays as sync
      fallback.


Out of scope (further follow-ups)
---------------------------------

- **Real-runtime tokens** — promote the phantom token to an
  `event_t`-backed Crisp type so users can pass tokens to functions
  / store in structs.  Needs new type-system machinery.
- **Multi-outstanding / out-of-order await** — once real-runtime
  tokens exist, lift the single-outstanding restriction.
- **`check-async-hazards`** — static analysis pass that flags reads
  from a destination buffer between request and await.  Needs the
  real-token type to track lifetimes.
- **Hopper TMA path** (`cp.async.bulk`) — needs host-side TensorMap
  hoisting plumbing.


Risks / unknowns
----------------

- **LLVM-SPIRV intrinsic naming drift.**  The Khronos translator has
  rewritten its intrinsic-recognition pass at least once in recent
  releases.  We need to pin to a specific version (whatever
  `llvm-spirv` binary the build uses) and document the expected
  spellings.  Fallback if the intrinsic doesn't translate: keep the
  cooperative-loop fallback path as a runtime-toggleable backstop.
- **PTX intrinsic version gates.**  `cp.async` is `sm_80+`.  The
  build needs to set the NVPTX target feature set correctly or the
  intrinsics will error at lowering time.  Need to confirm what
  Crisp currently passes to the PTX backend.
- **Event-type opacity.**  In LLVM 14+, the SPV translator uses
  `target("spirv.Event")` — a target-extension type that can't be
  alloca'd or stored directly in some IR contexts.  The hidden-slot
  design might need to be a global variable instead of an alloca.
- **Single-outstanding rule across control flow.**  The compile-time
  scope-table check is straightforward for straight-line code but
  needs care around `if` / `when` branches — issuing a request in one
  branch and awaiting in another is arguably a bug, but the analyzer
  needs to detect it.  Conservative answer: forbid request/await in
  conditionals entirely, same as the existing tile-coords divergence
  check.
- **Hardware verification cost.**  CI can't run PTX.  Each PTX change
  needs Colab/RunPod manual verification.  Build a small harness
  script that compiles + uploads + runs + diffs against a sync
  reference, so the verification loop is fast.


Definition of done
------------------

- [ ] 113/01 IR under `--ir-target=spv` contains `OpGroupAsyncCopy` /
      `__spirv_GroupAsyncCopy` (whichever spelling we settle on),
      verified by llvm-spirv round-trip.
- [ ] 113/01 IR under `--ir-target=ptx` contains
      `@llvm.nvvm.cp.async.ca.shared.global.*` +
      `@llvm.nvvm.cp.async.commit.group` +
      `@llvm.nvvm.cp.async.wait.group`, verified by llc round-trip
      to PTX assembly.
- [ ] At least one Colab/RunPod run on Ampere+ hardware that runs
      the request-load-tile path against a sync reference and matches
      to bitwise.
- [ ] Missing-target gate and single-outstanding spec both pass.
- [ ] Full suite green on default and `--differentiate`.
- [ ] On Intel BMG (the dev box), a tile-heavy kernel shows
      measurable overlap of memory transfer with compute when
      compiled with the async path vs the sync fallback.  Even a
      crude wall-clock comparison is fine for the "perf actually
      shows up" checkbox.


Estimate
--------

~2 – 3 focused days end-to-end:

- Phase A (SPV): ~1 day (research + codegen + IR validation).  Risk:
  intrinsic naming surprises.
- Phase B (PTX): ~1 day (research + codegen + IR validation +
  RunPod run).  Risk: target-feature setup.
- Phase C/D (gates): ~½ day combined.  Mostly mechanical once
  A and B are in place.
- Phase E (async store): ~½ day for SPV; Hopper TMA explicitly
  deferred.

Research-first means front-loading the spec-reading; expect days 1–2
of any of these phases to be mostly reading + sketching, not coding.
