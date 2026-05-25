Endeavor 114 — Async tile codegen on metal (SPV `OpGroupAsyncCopy` + PTX `cp.async`)
======================================================================================

> **Status (closed 2026-05-25): PTX path shipped, SPV path blocked,
> remaining sub-phases deferred with clear criteria.**
>
> - **Phase B.1 PTX cp.async — SHIPPED.** Native
>   `@llvm.nvvm.cp.async.ca.shared.global.{4|8}` + `commit.group` +
>   `wait.group(0)`, lowering to the right cp.async PTX assembly under
>   `llc -mcpu=sm_80`.  Verified at IR + PTX-assembly inspection level
>   for `tests/spec/113-async-load-tile-store-tile/01-request-load-tile-coords-1d.crisp`.
>   PTX default compute capability bumped sm_50 → sm_80 in
>   `src/compiler.lisp`.
> - **Phase A SPV — BLOCKED.** IGC's BiFModule doesn't resolve either
>   `__spirv_GroupAsyncCopy` direct or mangled `_Z21async_work_group_copy...`
>   forms.  Both produce SPV that fails `zeKernelCreate` with
>   `ZE_RESULT_ERROR_INVALID_MODULE_UNLINKED`.  Per Gemini's "pragmatic
>   out", SPV stays on the 113 sync fallback — on Intel SLM-integrated
>   hardware the perf delta is small.  See section below.
> - **Phase B.2 / C / D / E — deferred** with clear re-attempt criteria
>   (see end of this doc).
>
> Suite remains 720/720 on default and `--differentiate`.
> Runtime validation on Ampere+ (Colab / RunPod) is pending — the only
> verification done so far is at the IR / PTX-assembly inspection level.


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

### Phase A — SPV codegen for request-load-tile-coords  *(BLOCKED, pragmatic-fallback)*

**Status (2026-05-25): attempted, reverted to fallback.**  Both candidate
SPV emission paths translate cleanly to SPIR-V but fail at
`zeKernelCreate` with `ZE_RESULT_ERROR_INVALID_MODULE_UNLINKED`:

- **Direct `__spirv_GroupAsyncCopy`** form lowers to a real
  `OpGroupAsyncCopy` opcode in the SPV.  IGC's frontend ingests the
  SPV and synthesises a function call with mangled
  `_Z22__spirv_GroupAsyncCopyi...l...` (`l` = i64 / long when the
  pointee type propagates correctly via typed GEPs) — but IGC's
  BiFModule doesn't ship a matching builtin.  Searched
  `intel-graphics-compiler/IGC/BiFModule/Languages/OpenCL/IBiF_Impl.cl`
  directly: no mention of `async_work_group_copy` or `GroupAsyncCopy`.
- **Mangled OpenCL form** (`_Z21async_work_group_copyPU3AS3mPU3AS1Kmj9ocl_event`)
  translates to `LinkageAttributes Import`.  Per the L0 spec, that's
  exactly the case `zeModuleDynamicLink` is supposed to resolve —
  but we don't have a builtins module to link against, and the spec
  doesn't define one as auto-loaded for OpenCL builtins.

Gemini diagnosed the underlying issue: the LLVM-SPIRV translator
defaults opaque-pointer args to `i8`, so even when the SPV opcode
emits successfully it asks IGC for an 8-bit builtin (`<i8>` mangle)
that Intel hardware doesn't have.  We confirmed by adding typed-GEP
hints (`getelementptr i64, ptr addrspace(3) %tile, i64 0`) that
the translator picks up the i64 element type and emits
`__spirv_GroupAsyncCopy<long>` — but IGC's BiFModule doesn't have
the long variant either.  Sub-byte and non-standard widths look
similarly unsupported.

**Pragmatic fallback** (Gemini's recommendation, accepted): SPV stays
at the 113 sync cooperative-loop lowering.  On Intel hardware (BMG and
later) the SPV-side perf delta between hardware async copy and a
well-coalesced sync cooperative load is small — L1 and SLM are
tightly integrated, the load looks like a back-to-back coalesced
read.  Phase B (PTX) is where the headline perf win lives, since
NVPTX uses direct LLVM intrinsics (no BiF linkage needed).

**Re-attempt criteria** for the SPV path:

- Intel publishes (or we find) a documented L0 module / pBuildFlags
  invocation that auto-resolves OpenCL builtins, OR
- We implement a `zeModuleDynamicLink` call against a builtins module
  we can ship or extract, OR
- IGC adds direct support for the `__spirv_GroupAsyncCopy<long>` /
  `<int>` / `<float>` mangles in its BiFModule.

Filing context for the question: when bug 031 goes to Intel on Tuesday,
add a sidebar question about the recommended SPIR-V async DMA path for
L0 + IGC consumers who aren't going through Clang's OpenCL frontend.

#### Original plan (kept for when the blocker lifts)

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

### Phase B.1 — PTX cp.async, single-element-per-thread MVP *(LANDED)*

Status (2026-05-25): **shipped**.  When `*target-backend*` is `:ptx`,
the analyzer builds `semantic-nvvm-cp-async-tile-copy` /
`semantic-nvvm-cp-async-wait` nodes; codegen emits:

```
call void @llvm.nvvm.cp.async.ca.shared.global.{4|8}(
       ptr addrspace(3) %tile_elt_ptr, ptr addrspace(1) %src_elt_ptr)
call void @llvm.nvvm.cp.async.commit.group()
;; ... user work that doesn't touch the tile ...
call void @llvm.nvvm.cp.async.wait.group(i32 0)
```

`llc -march=nvptx64 -mcpu=sm_80` lowers to exactly:

```
cp.async.ca.shared.global [%rd_dst], [%rd_src], 8;
cp.async.commit_group;
cp.async.wait_group  0;
```

Confirmed on `tests/spec/113-async-load-tile-store-tile/01-request-load-tile-coords-1d.crisp`.
PTX default compute capability bumped sm_50 → sm_80 in
`src/compiler.lisp` (cp.async requires Ampere).  Kernels not using
request-* still compile cleanly under sm_80.

**B.1 scope assumption**: tile.length == workgroup_size (one cp.async
per thread, no inner loop).  Element types limited to 4- and 8-byte
(int, uint, float, long, ulong, double).  Other shapes fall through to
the 113 sync fallback.

**Tested only at IR / PTX-assembly inspection level** (CI has no NVIDIA
hardware).  Runtime validation requires Colab or RunPod.  Suite stays
green at 720/720 default + --differentiate (no regressions).

### Phase B.2 — PTX cp.async cooperative loop *(deferred)*

For tiles larger than workgroup_size, threads iterate workgroup-strided
issuing one cp.async per element.  Same structural pattern as the sync
load-tile-coords cooperative loop, swapping `set!` for cp.async.
Worth deferring until there's a kernel that actually needs it (most
real-world tile shapes equal workgroup_size).

### Phase B.0 — Original plan *(retained for reference)*

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

### Phase C — Missing-target gate *(deferred — not value-add yet)*

The 113 Phase 1a gate was removed because the sync fallback worked on
any target including `:generic`, and gating broke the spec runner's
default pass.  With 114 Phase B.1 shipped, the user-facing trade-off is
now: forgetting `--ir-target=ptx` silently keeps you on the sync
fallback (correct results, no cp.async).

Re-introducing the gate would mean updating every request-* spec with
`SKIP-WITH[default]` directives — meaningful friction for a check that
just catches a typo.  Defer until either:
- a real user gets bitten by silently-not-getting-perf, or
- the spec runner gains a per-spec default-pass target opt-in.

### Phase D — Single-outstanding scope table *(deferred — runtime already correct)*

`@llvm.nvvm.cp.async.wait.group(i32 0)` waits for **all** pending
groups, so the multi-outstanding pattern works correctly at runtime
today.  A compile-time scope table would constrain style, not fix
correctness.

Re-attempt criteria: when real-runtime tokens land (so users can
distinguish "wait for THIS request" from "wait for all"), the
static-check helps disambiguate.  Not before then.

### Phase E — Async store *(deferred — mostly N/A)*

- **SPV**: same IGC BiFModule blocker as Phase A.  Sync fallback stays.
- **PTX-Ampere**: no hardware async store.  Sync fallback stays.
- **PTX-Hopper TMA** (`cp.async.bulk`): requires host-side TensorMap
  descriptors — needs hoist-side plumbing that doesn't exist.  Its own
  endeavor when there's a real Hopper target.

Net: no Phase E work needed now.  `request-store-*` continues to
lower to the 113 sync fallback on every backend, which is the only
correct path on current hardware.


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
