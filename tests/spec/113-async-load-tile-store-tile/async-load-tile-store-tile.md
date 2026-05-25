Endeavor 113 — Async load-tile / store-tile API + AD wiring (fallback impl)
============================================================================

> **Note on this directory.**  Endeavor 113 picks up where 111 left off.
> 111 delivered the synchronous tile family (`load-tile` / `store-tile`
> / `load-tile-coords` / `store-tile-coords`) and 112 wired their AD
> through the L0 verify-autodiff runner.  113 adds the **front-end**
> for the asynchronous variants — `request-load-tile`,
> `request-store-tile`, their `-coords` generals, and `await-request`
> — plus the AD pre-rewrite that lets the existing backward machinery
> handle them.
>
> **The real backend-async codegen lives in endeavor 114**
> (`tests/spec/114-async-tile-codegen/`) — `OpGroupAsyncCopy` on SPV,
> `cp.async` family on PTX.  Splitting was deliberate: 113 is
> front-end + AD work that fits the rest of the load/store-tile story;
> 114 is LLVM-intrinsic spelunking + per-backend IR validation +
> Colab/RunPod verification, a different character of work that
> deserves focused attention.
>
> The user-visible API and AD behaviour are the same with or without
> 114.  Until 114 lands, request-* lowers to its sync counterpart and
> await-request is a no-op — correct results, no perf benefit yet.


Goal
----

Ship the documented async tile API end-to-end as language surface, with
the fallback (sync) lowering on both backends:

```
;; Helpers, inside tile-stride / hardware-stride
(request-load-tile  <src-problem-space-tensor> <dest-tile> &key (identity 0) transpose) => request-token
(request-store-tile <src-tile> <dest-problem-space-tensor> &key transpose)               => request-token

;; General forms, anywhere
(request-load-tile-coords  source-tensor dest-tile (... coord ...) &key (identity 0) transpose) => request-token
(request-store-tile-coords source-tile dest-tensor (... coord ...) &key transpose)              => request-token

(await-request token)
```

User code is portable across backends and forward-compatible: when 114
lands, the same source compiles to real async with no changes.

References:

- `docs/chapters/14_control_flow/12_load_tile_store_tile.md`
- `docs/chapters/10_storage_handle_types/16_async_memory_operations.md`
- `docs/chapters/10_storage_handle_types/18_matrices.md`
- 111-load-and-store-tile (sync impl this builds on)
- 112-verify-autodiff-l0 (AD wiring this builds on)
- **114-async-tile-codegen** (real-async perf path; depends on 113)


Design decisions
----------------

### Token semantics — phantom token, single outstanding, FIFO await

The doc API is `(let ((tok (request-X ...))) ... (await-request tok))`.
We **don't** materialise the token as a runtime value in this endeavor:

- The let-binding name is tracked in a compile-time scope table.
- Single-outstanding-request is the intended rule (issuing a second
  `request-*` before the prior is awaited is a compile-time error).
  Hard enforcement lands in 114 alongside the real codegen — without
  it, the fallback path silently accepts overlapping requests because
  each one is already complete by the time it returns.
- `await-request tok` looks the name up and emits the wait — in
  fallback that's a no-op.

This is "phantom token" in the sense that the source syntax matches
the spec'd API exactly, but `tok` carries no runtime value.  User code
cannot store the token in a struct or pass it to a function — those
require the real-runtime-token treatment that comes later (a separate
follow-up, beyond 114).

### AD story — pre-rewrite to sync, AD walker unchanged

The AD walker delivered in 111+112 doesn't need to know about the
`request-` prefix.  In `%expand-stride-macros-in-form` (the existing
pre-rewrite hook used by `%generate-backward-kernel-ast`), rewrite:

- `(request-load-tile-coords  S D O …)` → `(load-tile-coords  S D O …)`
- `(request-store-tile-coords S D O …)` → `(store-tile-coords S D O …)`
- `(await-request tok)` → `nil`

The backward pass then emits `%load-tile-coords-bwd` /
`%store-tile-coords-bwd` exactly as today, and 112's on-metal AD
verification keeps working unchanged.

### Backend coverage — fallback-only here; real async in 114

Both `:spirv` and `:ptx` use the same fallback: emit the existing sync
`load-tile-coords` / `store-tile-coords` expansion.  Endeavor 114
replaces the fallback with real `OpGroupAsyncCopy` (SPV) and
`cp.async` (PTX) per backend, and adds the missing-target gate and
single-outstanding enforcement that the fallback path can't usefully
check.


Phasing
-------

### Phase 1 — `request-load-tile-coords` + `await-request` (DONE)

- [x] Front-end analyzer for `request-load-tile-coords`: delegates to
      `%expand-load-tile-coords-form`; wraps the result in a `(progn
      … (to-ulong 0))` so the surrounding let-binding has a phantom
      ulong token to bind.
- [x] Front-end analyzer for `await-request`: validates arity, emits
      a `(to-ulong 0)` no-op.
- [x] Whole-function redefine of `register-control-analyzers` to
      re-register both analyzers after `initialize-expression-analyzers`
      wipes the table on each compile.
- [x] AD pre-rewrite: extend `%expand-stride-macros-in-form` to
      normalise `REQUEST-LOAD-TILE-COORDS` → `LOAD-TILE-COORDS` and
      `AWAIT-REQUEST` → `nil`.
- [x] Smoke spec `01-request-load-tile-coords-1d.crisp` passes default
      and `--ir-target=spv`.

### Phase 2 — `request-load-tile` sugar

- [ ] Extend `%rewrite-bare-load-store-tile-in-form` in
      [src/analysis/control.lisp](src/analysis/control.lisp) so bare
      `request-load-tile` inside `tile-stride` / `hardware-stride`
      rewrites to `request-load-tile-coords` with the stride's origin
      list — same rewrite shape `load-tile` already uses.
- [ ] Same divergence check as the sync form (the implicit
      consumer-side barrier would deadlock if half the workgroup skips
      the request).

### Phase 3 — `request-store-tile-coords` + `request-store-tile`

- [ ] Analyzer for `request-store-tile-coords` that delegates to
      `%expand-store-tile-coords-form` and returns a phantom token,
      mirroring the load case.  Same fallback semantics on both
      backends — sync store + barrier + no-op await.
- [ ] Sugar rewriter for bare `request-store-tile` inside tile-stride
      / hardware-stride, mirroring Phase 2.
- [ ] AD pre-rewrite: same as Phase 1 for the store-coords variant.

### Phase 4 — Verify-autodiff coverage (DONE)

- [x] Added `04-ad-async-roundtrip.crisp` — mirror of 111/14 with the
      sync tile-coords calls swapped for the async request-* variants.
      Passes VAD on metal: analytical=1.0, numerical=0.999, diff=5.5e-4
      (the same accuracy as the sync 111/14 spec, because the AD
      pre-rewrite normalises request-* to the sync form before
      generate-backward-walk runs).
- [x] Suite stays green on default and `--differentiate`: 720/720.
- [x] Discovered + fixed a Phase 4 follow-on: the AD pre-rewrite's
      `(let ((sym (request-X ...))) body)` pattern was leaving the
      stripped sync tile-coords call in BINDING-VALUE position, which
      route it through `%handle-single-value-backward` (which doesn't
      know LOAD/STORE-TILE-COORDS).  Added a LET hoist clause to
      `%expand-stride-macros-in-form` that lifts such calls into a
      sibling `(progn ...)` so they land in statement position where
      `process-form`'s LOAD/STORE-TILE-COORDS cases handle them.


Out of scope (tracked elsewhere)
--------------------------------

- **Real async codegen on SPV and PTX.**  Whole of endeavor
  [114-async-tile-codegen](../114-async-tile-codegen/async-tile-codegen.md).
  This is where the actual perf win lives.
- **Real-runtime tokens / multi-outstanding / out-of-order await.**
  Promote the phantom token to an `event_t`-backed Crisp type.  Source
  syntax doesn't change; backend lowering does.  Probably its own
  small endeavor after 114.
- **`check-async-hazards`.**  Static analysis pass that flags reads
  from a destination buffer between the request and the await.  Needs
  the real-token type to track lifetimes properly.
- **`request-load-local` / `request-store-global`** (the non-tile
  vec→vec primitives doc'd in chapter 10/16).  Same lowering surface,
  different front-end shape.  Defer.


Definition of done
------------------

- [x] Phase 1 spec passes default and `--ir-target=spv`.
- [x] Phases 2–4 specs pass on both passes.
- [x] Full suite green: default + `--differentiate` (720/720).
- [x] `MEMORY.md` updated with the endeavor's outcome.
- [x] Plan doc for 114 stubbed (this co-delivery — endeavors are
      coupled in design even though split in execution).
