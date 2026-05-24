Endeavor 113 — Async load-tile / store-tile + await-request
=============================================================

> **Note on this directory.**  Endeavor 113 picks up where 111 left off.
> 111 delivered the synchronous tile family (`load-tile` / `store-tile` /
> `load-tile-coords` / `store-tile-coords`) and 112 wired their AD
> through the L0 verify-autodiff runner.  113 adds the asynchronous
> variants — `request-load-tile`, `request-store-tile`, their `-coords`
> generals, and `await-request`.


Goal
----

Ship the documented async tile API end-to-end:

```
;; Helpers, inside tile-stride / hardware-stride
(request-load-tile  <src-problem-space-tensor> <dest-tile> &key (identity 0) transpose) => request-token
(request-store-tile <src-tile> <dest-problem-space-tensor> &key transpose)               => request-token

;; General forms, anywhere
(request-load-tile-coords  source-tensor dest-tile (... coord ...) &key (identity 0) transpose) => request-token
(request-store-tile-coords source-tile dest-tensor (... coord ...) &key transpose)              => request-token

(await-request token)
```

Lower to true async DMA on backends that support it (SPV
`async_work_group_copy`; PTX-Ampere `cp.async` + commit/wait), gracefully
degrade to a synchronous cooperative loop everywhere else, keep the
language API uniform across backends, and let AD work unchanged via a
pre-pass that rewrites `request-*` to its sync counterpart before the
backward walker sees it.

References:

- `docs/chapters/14_control_flow/12_load_tile_store_tile.md`
- `docs/chapters/10_storage_handle_types/16_async_memory_operations.md`
- `docs/chapters/10_storage_handle_types/18_matrices.md` (request-X-tile-coords)
- 087-gpu-builtins (precedent for `(case *target-backend* (:spirv …) (:ptx …))`)
- 111-load-and-store-tile (sync impl + AD machinery this builds on)


Design decisions
----------------

### Token semantics — phantom token, single outstanding, FIFO await

The doc API is `(let ((tok (request-X ...))) ... (await-request tok))`.
We **don't** materialise the token as a runtime value in this endeavor:

- The let-binding name is tracked in a compile-time scope table.
- Internally the compiler holds a hidden pending-event slot per backend
  (the SPV `event_t` array, the PTX commit-group depth).
- `await-request tok` looks the name up and emits the wait against the
  hidden slot.
- Single-outstanding-request is enforced statically.  Issuing a second
  `request-*` before the prior one is awaited is a compile-time error.

This is "phantom token" in the sense that the source syntax matches the
spec'd API exactly, but `tok` carries no runtime value.  User code
cannot store the token in a struct or pass it to a function — those
require the real-runtime-token treatment that lands later (deferred,
see "Out of scope").

Phantom-token is forward-compatible: the source syntax is identical
under the real-runtime impl, so promoting later is a backend change,
not a source change.

### AD story — pre-rewrite to sync, AD walker unchanged

The AD walker delivered in 111+112 doesn't need to know about the
`request-` prefix.  In `%generate-backward-kernel-ast` (or a sibling
pass that runs before it), rewrite:

- `(request-load-tile-coords  S D O …)` → `(load-tile-coords  S D O …)`
- `(request-store-tile-coords S D O …)` → `(store-tile-coords S D O …)`
- `(await-request tok)` → `(local-barrier)`

The backward pass then emits `%load-tile-coords-bwd` /
`%store-tile-coords-bwd` exactly as it does today, and the existing
on-metal AD verification (suite green at 716/716) keeps working.

### Backend coverage — SPV and PTX both in Phase 1

Both targets get real lowering in the same phase.  We can't run PTX
in spec CI (no NVIDIA hardware on the dev box), but the IR is
inspectable, the codegen path lives next to its SPV sibling under
the same `(case *target-backend* (:spirv …) (:ptx …))` pattern as
local-barrier in 087, and Colab / RunPod runs are coming up.

| Form | Backend | Lowering |
| --- | --- | --- |
| `request-load-tile-coords` (1D unit-stride float) | SPV | `async_work_group_copy(dst, src, n, 0)`; event stashed in hidden slot |
| `request-load-tile-coords` (2D / strided) | SPV | `async_work_group_strided_copy(...)` per row OR fallback to sync if shape unsupported |
| `request-load-tile-coords` (any) | PTX | cooperative loop with `cp.async.ca.shared.global` per element; `cp.async.commit_group` after the loop |
| `request-store-tile-coords` (any) | SPV, PTX | Fallback: sync `store-tile-coords` + `local-barrier`.  Token is a no-op marker; `await-request` on a store-token emits nothing on SPV / `cp.async.wait_group 0` on PTX (cheap no-op when no pending ops). |
| `await-request` on load token | SPV | `wait_group_events(1, &slot)` |
| `await-request` on load token | PTX | `cp.async.wait_group 0` |
| any | generic (no `--ir-target`) | compile-time error, same message style as 087 (`"… requires --ir-target=spv or --ir-target=ptx"`) |

When a shape combination has no efficient async lowering on a given
backend, we silently fall back to sync `load-tile-coords` + barrier.
User code is unchanged; perf is just no-better-than-sync.


Phasing
-------

### Phase 0 — Plan + smoke

- [x] Write this plan.
- [ ] Trivial spec at `01-request-load-tile-coords-1d.crisp` that compiles a
      `request-load-tile-coords` + `await-request` pair on SPV; inspect
      the IR for `async_work_group_copy` and `wait_group_events`.
- [ ] Compile the same spec with `--ir-target=ptx`; inspect for `cp.async`
      + `cp.async.commit_group` + `cp.async.wait_group`.
- [ ] Confirm `--ir-target` is required for any request-* — compile
      without it produces the documented error.

### Phase 1 — `request-load-tile-coords` + `await-request`

- [ ] Compile-time scope table for phantom tokens.  Tracked in the same
      analyze-let / analyze-progn machinery that handles other bindings.
      Single-outstanding check: emit error if a second `request-*` issues
      while the table has a pending entry not yet awaited.
- [ ] Analyzer for `request-load-tile-coords` that:
      - takes the same arg shape as `load-tile-coords`
      - allocates a hidden pending-event slot in the surrounding kernel
      - emits the appropriate backend IR (SPV or PTX, per
        `*target-backend*`) for the cooperative async copy
      - records the binding name in the scope table
- [ ] Analyzer for `await-request`:
      - resolves the named binding from the scope table
      - SPV: emits `wait_group_events(1, &slot)`
      - PTX: emits `cp.async.wait_group 0`
      - clears the table entry
- [ ] Backend codegen helpers, parallel to `%gen-spirv-control-barrier`:
      - `%gen-spirv-async-work-group-copy`
      - `%gen-spirv-async-work-group-strided-copy`
      - `%gen-spirv-wait-group-events`
      - `%gen-ptx-cp-async-elem`
      - `%gen-ptx-cp-async-commit-group`
      - `%gen-ptx-cp-async-wait-group`
- [ ] Fallback path: when shape unsupported on the chosen backend,
      analyzer rewrites to `(progn (load-tile-coords …) <bind token to no-op>)`
      and the await becomes a no-op.
- [ ] AD pre-rewrite pass: `request-load-tile-coords` → `load-tile-coords`,
      `await-request` → `local-barrier`.  Runs before
      `generate-backward-walk`.

### Phase 2 — `request-load-tile` sugar

- [ ] Extend `%rewrite-bare-load-store-tile-in-form` in
      [src/analysis/control.lisp](src/analysis/control.lisp) so bare
      `request-load-tile` inside `tile-stride` / `hardware-stride`
      rewrites to `request-load-tile-coords` with the stride's origin
      list — exactly the same rewrite shape `load-tile` already uses.
- [ ] Confirm the bare-form's divergence check still triggers if the
      user puts `request-load-tile` inside a thread-divergent `if`
      (same constraint as the sync form — the implicit barrier in the
      await would deadlock).

### Phase 3 — `request-store-tile-coords` + `request-store-tile`

- [ ] Analyzer for `request-store-tile-coords`: ALWAYS lowers to sync
      `store-tile-coords` + `local-barrier` regardless of backend.
      Token still goes in the scope table for syntactic consistency;
      `await-request` on a store-token emits nothing on SPV /
      `cp.async.wait_group 0` on PTX (no-op-when-no-pending).
- [ ] Sugar rewriter for bare `request-store-tile` inside tile-stride /
      hardware-stride, mirroring Phase 2.
- [ ] AD pre-rewrite: same as Phase 1 for the store-coords variant.

### Phase 4 — Verify-autodiff coverage

- [ ] Add VAD directive to a copy of `111/14-ad-identity-via-tile-1d`
      that uses `request-load-tile` / `await-request` / `request-store-tile`.
      Should pass on the L0 runner with no runner-side changes (because
      of the AD pre-rewrite).  Lands here as `02-ad-async-roundtrip.crisp`.
- [ ] Suite stays green on default and `--differentiate`.


Out of scope (tracked for later)
--------------------------------

- **Real-runtime tokens / multi-outstanding / out-of-order await.**
  Promote the phantom token to an `event_t`-backed Crisp type.  Source
  syntax doesn't change; backend lowering does.  Probably its own
  small endeavor.
- **`check-async-hazards`.**  Static analysis pass that flags reads
  from a destination buffer between the request and the await.  Needs
  the real-token type to track lifetimes properly.
- **`request-load-local` / `request-store-global`** (the non-tile vec→vec
  primitives doc'd in chapter 10/16).  Same lowering surface, different
  front-end shape.  Defer.
- **Hopper / Blackwell TMA path** (`cp.async.bulk`).  Requires host-side
  TensorMap descriptors hoisted by the C generator — Crisp doesn't have
  that hoist plumbing yet.  Will land naturally when a Hopper hoister
  exists.


Risks / unknowns
----------------

- **SPIR-V `event_t` opaque type.**  Different drivers represent
  `event_t` differently (i64 vs `OpTypeEvent` vs pointer).  We avoid
  the question by stashing the slot at the kernel-IR level, not in a
  user-visible type — but the eventual hoist-side ABI may need work.
  Not in scope for 113.
- **PTX `cp.async` element-size constraints.**  Only 4-, 8-, or 16-byte
  payloads per instruction.  If a user makes a `(make-scratch-vector
  half 64)`, we'd need either to coalesce two halves per cp.async or
  fall back to sync.  Detect at analyze time and fall back for the MVP.
- **Bounds checks under async.**  Sync `load-tile-coords` does an
  in-bounds check per thread per element with an `:identity` fallback
  for out-of-range writes.  `async_work_group_copy` does not honour
  per-element bounds — it copies a contiguous run.  For shapes where
  the tile doesn't divide the problem space evenly, we have to either
  fall back to sync OR pre-zero the tile then async-copy the in-bounds
  range.  Simpler: detect non-divisible at analyze time and fall back.
- **The single-outstanding rule.**  Easy to enforce statically but it
  means users can't pipeline two loads.  This is a real perf limitation
  the multi-token follow-up endeavor will lift.


Definition of done
------------------

Per [plan/definition-of-done.md](plan/definition-of-done.md):

- [ ] All Phase 1–4 specs pass under default and `--differentiate`.
- [ ] SPV IR inspection: async ops visible, no stray sync barriers in
      kernels that should be fully async.
- [ ] PTX IR inspection: `cp.async` + `cp.async.commit_group` +
      `cp.async.wait_group` emitted; structure matches Ampere expectations.
      Spot-checked on Colab or RunPod; not gated in CI.
- [ ] Full suite green: default + `--differentiate`.
- [ ] `MEMORY.md` updated with the endeavor's outcome.
- [ ] No new entries in `plan/bugs.md` (or, if there are, they're
      tracked with the same care as bug 032).


Estimate
--------

~1½ – 2 focused days end-to-end, split roughly:

- Phase 0: a couple hours (smoke + first IR look)
- Phase 1: ~day (the meat — token table, both backends, fallback paths)
- Phase 2: half day (sugar rewriter, mirrors existing 111 pattern)
- Phase 3: half day (sync-fallback wiring, both store forms)
- Phase 4: half day (VAD spec + suite green)

Plenty of room for SPV / PTX surprises in Phase 1; if either hits a wall
we stop, fall back to sync-only on the affected backend, and come back
to the perf path in a follow-up.
