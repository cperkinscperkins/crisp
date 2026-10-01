# `make-async-barrier` ✅


`(make-async-barrier) => barrier`

Allocates a data-movement barrier that synchronizes the state of the hardware DMA engine (an
async global→local memory transfer) with the execution unit.  It is strictly for tracking that
transfer, not for arbitrary control flow.  A `:barrier` on `load-tile` / `store-tile` links the
transfer to this barrier; `await` blocks until the bytes have landed.

```
(make-async-barrier &key mode)

; examples
(make-async-barrier)                  ; arch-automatic (see below)
(make-async-barrier :mode :linear)    ; force the linear async copy
```

#### `:mode`

`:mode` answers one question: **what kind of object is this barrier, and how far does it reach?**
Omit it for the arch-automatic default; pass it explicitly to pin a specific kind (for degenerate
cases, or when reach is part of your algorithm rather than a property of the hardware).

The values form a ladder, each rung strictly more capable than the one below it:

| `:mode` | what the barrier IS | how far it reaches |
|---|---|---|
| `:linear` | the backend's group-async-copy handle | the workgroup |
| `:block` | a real mbarrier object | the workgroup |
| `:cluster` | a real mbarrier object | the whole workgroup cluster |

- `:linear` — `cp.async` on PTX, `OpGroupAsyncCopy` on SPIR-V.  A per-element / per-row
  cooperative copy global→SLM.  **Shipped** and metal-verified on both backends.  Valid on
  every supported arch.  Note the handle is not the same thing on both backends: on PTX
  `commit_group`/`wait_group` need no object at all, so the barrier is a *phantom* and the
  compiler emits a constant; on SPIR-V it owns a `target("spirv.Event")` slot that the async
  copies chain through.
- `:block` — `CuTensorMap` (TMA) on PTX.  A bulk descriptor-driven 2D copy global→SLM,
  completing on a **workgroup-local** mbarrier (`mbarrier.arrive.expect_tx.shared::cta` /
  `mbarrier.try_wait.parity.shared::cta`).  **NVIDIA sm_90+ only.**  On an older NVIDIA arch it
  is a compile error (needs sm_90+); **on Intel it is a compile error** — Intel's fast 2D path
  (LSC 2D block loads) loads global→*registers*, not SLM, and is **not** a barrier-governed
  transfer at all (see "Optimizing Intel MMA").
- `:cluster` ✅ — a real mbarrier that **peer workgroups in the same cluster may arrive on**
  (`mbarrier.arrive.shared::cluster` against a mapped peer address).  **NVIDIA sm_90+ only**,
  and only meaningful when the kernel declares a [cluster-size](#cluster-size).

##### Which barriers need which rung

A pipelined kernel usually has two barrier rings, and they do **not** want the same rung:

- The **data-arrival** ring (conventionally `full`) stays `:block` even in a clustered kernel.  A
  multicast load writes into several workgroups' SLM at once, but each transaction completes on
  the **destination workgroup's own** mbarrier, so the barrier is workgroup-local.
- The **buffer-free** ring (conventionally `empty`) is the one that becomes `:cluster`.  It carries
  no transfer at all — no `load-tile` ever names it — and exists so consumers can tell the producer
  a slot is safe to overwrite.  Once a producer fills slots in *peer* workgroups, those peers must
  be able to arrive on its barrier, and that is cluster reach.

So in a clustered matmul it is the barrier governing **no** data movement that gains `:cluster`,
while the barrier the multicast actually targets stays `:block`.

> **On Intel, only the bottom rung exists.**  `:block` and `:cluster` are both compile errors on
> SPIR-V, and `:mode :linear` **rings** are not implemented there either — see [Rings](#rings).
> Intel's fast matmul path reaches its throughput without barrier-governed staging at all, via
> direct register block-load prefetch.

#### The arch-automatic default

With no `:mode`, the barrier picks the best global→local async copy for the elected architecture
(`--ir-target-arch`, or the per-backend default):

- **NVIDIA sm_90+** → `:block` (TMA / CuTensorMap).
- **NVIDIA < sm_90** (incl. the default `sm_80`) → `:linear` (`cp.async`).
- **Intel** (any arch) → **always `:linear`** (`OpGroupAsyncCopy`).

> **Arch-automatic never selects `:cluster`, even on sm_90+ with a cluster declared.**  The default
> picks the best mechanism the hardware can realize — a capability question.  Reach is not: it is a
> claim about your algorithm, and guessing it wrong hangs the kernel rather than costing throughput.
> `:cluster` is always written explicitly.

> **Guidance for Intel.**  `:linear` on Intel is a genuine async copy and useful for large /
> contiguous tiles, but it is a per-*row* `OpGroupAsyncCopy` — for the small, strided fetches a
> matmul does, it costs more than it saves.  On Intel, prefer a plain synchronous `load-tile`
> (no `:barrier`) for those, or the direct register block-load prefetch path (Intel MMA optimization).


