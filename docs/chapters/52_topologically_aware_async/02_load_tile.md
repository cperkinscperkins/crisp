# `load-tile` ✅


`(load-tile src dest (... grid-y grid-x) &key transpose identity barrier multicast) => nil`

Initiates a bulk memory transfer from the `src` tensor to the `dest` tensor (typically moving from Global Memory to SLM or registers).

* **Tile IDs (`grid-y`, `grid-x`):** The target location is specified using logical Tile Identifiers, which map to the strided chunks defined by the tensor's block distribution.  On a single GPU (no topology) this means simply: **the tile-ID is scaled by the `dest` tile's extent** to give the element origin in `src` — coord `(1 1)` with a `64×64` `dest` reads `src[64:128, 64:128]`.  These are exactly the `grid-y`/`grid-x` bindings that `tile-stride` and `matrix-multiply-tile-stride` hand you, so `(load-tile A A-tile (grid-y grid-k))` "just works".  When you need an exact element offset instead (unaligned / ragged), use `load-tile-at`.
* **`:transpose`:** A boolean indicating if the hardware should transpose the data during the load (leveraging tensor core layout features).
* **`:identity`:** A fallback value used for out-of-bounds padding if the tile intersects the edge of the source tensor.
* **`:barrier`:** Links this memory transfer to a previously created `async-barrier`. The hardware DMA engine will automatically signal this barrier when the bytes physically arrive in the destination memory space.
* **`:multicast`:** A boolean asserting that this tile is identical across one axis of the workgroup cluster and should be fetched once for all of them. Omitting it gives an ordinary per-workgroup load. See below.

#### `:multicast` ✅

`(load-tile src dest (... grid-y grid-x) &key transpose identity barrier multicast)`

In a kernel that declares a [`cluster-size`](#cluster-size), a tile that **every workgroup along
one cluster axis needs identically** can be fetched from global memory *once* and delivered into
all of their local memories simultaneously.  `:multicast` asks for that.

```lisp
;; cluster is (2 1) — two workgroups stacked along rows (axis 0)
(load-tile A (ring-get A-ring slot) (grid-y grid-k) :barrier (ring-get full slot))
(load-tile B (ring-get B-ring slot) (grid-x grid-k) :barrier (ring-get full slot) :multicast true)
```

`A`'s coordinates depend on `grid-y`, so the two workgroups need *different* rows of `A` — it is
not multicast, and asking for it would be wrong rather than merely wasteful.  `B`'s coordinates
ignore `grid-y`, so both workgroups want the same columns of `B` and one fetch serves the pair.

##### It is an assertion, not a directive

`:multicast` is a plain boolean.  You are **not** specifying an axis, a destination mask, or an
issuing workgroup — the compiler derives all three from the tile coordinates and the declared
cluster shape.  What you are saying is **"I expect this load to multicast,"** and the compiler
either does it or refuses to compile, naming the coordinate that conflicts.

> **A note on `true`.**  Crisp does not have a boolean literal yet; `true` and `false` are still
> pending (see the language-changes list).  Existing boolean keys such as `:transpose` are written
> with Common Lisp's `t` today, which is a stopgap rather than a decision — `t` and `T` are the
> *same symbol* to the reader, so it collides with the `T` that templates bind constantly.
> `:multicast` is documented with `true` because it is not implemented yet and there is no reason
> to add a second occurrence that will need migrating.

That division matters in both directions:

- **The mask and the leader are not writable by hand in any sane way.**  Exactly one workgroup per
  multicast group issues the fetch.  For a 2-workgroup cluster that is trivially the first; for a
  2x2 cluster the leader differs *per operand*, because `A`'s multicast groups and `B`'s partition
  the cluster differently.  Deriving that is the compiler's job.
- **Whether a load *should* multicast is not the compiler's call to make silently.**  A `load-tile`
  that quietly declines to multicast still computes the correct answer — at exactly the bandwidth
  you were trying to avoid paying, with nothing in the output to reveal it.  Making the intent
  explicit turns that silent 2x into a compile error.

This follows the same rule as [`:arrivals`](#make-async-barrier-ring): you state a fact you know,
the compiler checks shape rather than guessing intent.

##### Why this is a key on `load-tile` and not a barrier `:mode`

Everywhere else, a `load-tile`'s lowering is chosen by its `:barrier` — no barrier means a
synchronous copy, and a barrier's [`:mode`](#mode) picks which asynchronous mechanism.  Multicast
is the exception, and the example above shows why: **both loads name the same barrier, and only one
of them multicasts.**

The barrier cannot express the difference because it is not per-operand.  It is per-*stage* — that
is the entire meaning of `:arrivals 2`, "this slot tracks two transfers."  Multicast is a finer
choice *within* the TMA mechanism that varies from operand to operand, so it has no barrier to
hang on and belongs at the call site.

##### The barrier stays workgroup-local

A multicast writes into peer workgroups' local memory, but each destination workgroup's transaction
completes on **its own** mbarrier.  Every workgroup still waits on a barrier it owns, which is why
the data-arrival ring stays [`:mode :block`](#mode) in a clustered kernel rather than becoming
`:cluster`.  See [Which barriers need which rung](#which-barriers-need-which-rung).

##### Errors

`:multicast` is refused, with the conflicting coordinate named, when:

- the kernel declares no `cluster-size`, or the cluster extent is 1
- the tile's coordinates depend on **every** cluster axis, so no two workgroups want the same tile
- the target is not NVIDIA `sm_90+`

