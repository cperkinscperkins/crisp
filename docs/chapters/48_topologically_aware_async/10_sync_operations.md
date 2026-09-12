# Sync Operations ✅

```
(sync-cluster)
(sync-workgroup)
(sync-warp)


(make-arrival-sync <count>) => sync-handle 
(sync-arrive sync-handle) => nil
(sync-wait sync-handle) => nil
```

#### sync-cluster ✅

```lisp
(sync-cluster)          ; arrive + wait, ordered. The safe default. ✅

;;  - OR - (📝 NOT IMPLEMENTED YET)
(sync-cluster :arrive)  ; non-blocking: "I'm here"
(sync-cluster :wait)    ; block until all CTAs have arrived

```

`sync-cluster` acts as a global barrier for the entire workgroup cluster. It blocks until every thread in every workgroup within the cluster has arrived, ensuring all Distributed Shared Memory (DSMEM) operations are complete and visible.

* **Intra-workgroup included:** `sync-cluster` intrinsically synchronizes threads *within* the workgroup as well. You do not need to issue a separate `sync-workgroup`.
* **Divergence:** Placing `sync-cluster` inside a divergent control flow (`if`, `cond`, or warp specialization) guarantees a deadlock. Crisp detects this statically and will throw a compile error.
* **Target Degradation:** On Intel hardware, pre-Hopper NVIDIA hardware, or if the kernel does not declare a `cluster-size` (effective cluster size of 1), this operation gracefully degrades to a standard `sync-workgroup`.

#### Split-Phase Execution (Design Sketch) 📝

A split `(sync-cluster :arrive)` / `(sync-cluster :wait)` is **not shipped**, pending the static
analysis to enforce its safety rules.  Those rules are the ones documented for the shipped split
[`sync-workgroup`](#sync-workgroup) below, plus one more: a cluster peer's shared memory may not
be read or written inside the window.

#### sync-workgroup ✅

```lisp
(sync-workgroup)          ; arrive + wait, ordered.  The safe default.  ✅ All

;; --- the split form, SPIR-V only --------------------------------------------
(sync-workgroup :arrive)  ; non-blocking: "I'm here"                    ✅ Intel
(sync-workgroup :wait)    ; block until all threads have arrived        ✅ Intel
```

`(sync-workgroup)` is the same as `barrier(CLK_LOCAL_MEM_FENCE)`. It both announces that this thread
has reached the point and blocks until every other thread in the workgroup has too.

The **split form** separates those two, so useful work can sit between them — the thread announces,
keeps going, and only blocks at the `:wait` if it actually outran its peers:

```lisp
(dotimes (grid-k n-k)
  (sync-workgroup :arrive)
  (load-tile A A-tile (grid-y grid-k))
  (load-tile B B-tile (grid-k grid-x))
  (mma-accumulate-via-tile (8 16 16) C-tile A-tile B-tile)
  (sync-workgroup :wait))
```

**This is an execution rendezvous, not data movement.** It synchronises no memory of its own and
signals no barrier object — `await` and `signal` are for "these bytes are now visible." A split
barrier paces control flow, which is why it extends `sync-workgroup` rather than `await`, and why it
reads like the [sync-cluster](#sync-cluster) split above: cluster, workgroup and warp are one scope
ladder.

The same restrictions apply as for `sync-cluster`, and for the same reason — every violation
deadlocks rather than computing a wrong answer:

- the `:arrive` MUST be paired with a `:wait`, and these CANNOT nest (one window at a time).
- neither half may appear in a divergent context (`if` / `when` / `unless` / `cond`, or a warp
  specialization role block).
- `return` or otherwise exiting between `:arrive` and `:wait` is disallowed.
- reading or writing SLM inside the window is discouraged — the barrier's memory semantics are
  `AcquireRelease | WorkgroupMemory`, so that is exactly the ordering the split gives up.

The compiler **refuses** the first two statically. The third and fourth are **not yet checked**;
absence of an error is not proof of correctness for those two.

`SPV_INTEL_split_barrier` is requested only by modules that actually use the split form, so a kernel
that never splits does not oblige the driver to support the extension.

> **PTX refuses rather than approximating.** NVIDIA has it but requires a participant count Crisp cannot currently guarantee, so compiling either half for `--ir-target=ptx` is a compile error naming the backend.
> Use the fused `(sync-workgroup)` there.


#### sync-warp ✅

`(sync-warp) => nil`

Synchronizes the threads of a single warp / subgroup — a convergence point narrower than
`sync-workgroup`, for ordering within one warp without paying a workgroup-wide rendezvous.
It lowers to `bar.warp.sync` on PTX and to a Subgroup-scope `OpControlBarrier` on SPIR-V.

There is no split `:arrive` / `:wait` form: a warp executes in lockstep, so there is no window
between arriving and waiting in which to put work.

#### Sync on Arrival ✅

(make-arrival-sync count) : A thread-count barrier. Returns a handle used by the consumer to block until `count` threads have called (sync-arrive). Implementation uses a global atomic counter.

(sync-arrive sync-handle) : non-blocking. Puts one "unit" into the sync bucket.
(sync-wait sync-handle) : blocks until "count" units have been put into the sync bucket.


