# Phase 0 — paper verification

Two facts carry the design.  **Do these before writing any lowering** — each one changes what
gets built.

Status after the 2026-08-16 pass: **ALL SETTLED.**  Q1, Q1b, Q2, extent limits and grid
divisibility are all resolved — the last four empirically, on an H100 PCIe (sm_90, CUDA 12.4)
and against CUTLASS `main` source.  A bonus finding settles the deferred `empty`-barrier
lowering question too.  **No design change is required; one secondary source was wrong and is
corrected below.**

---

## Q1. Does a TMA multicast complete on each destination CTA's own mbarrier, or only the issuer's?

**Why it is load-bearing.**  The whole `:mode` ladder rests on this.  We concluded that the
data-arrival ring (`full`) stays `:mode :block` — a *workgroup-local* mbarrier — even in a
clustered kernel, because each destination CTA waits on a barrier it owns and the TMA hardware
credits that barrier as its copy lands.

### FINDING — CONFIRMED (2026-08-16). Each destination CTA's OWN mbarrier.

TMA multicast places the loaded data into the SMEM of every CTA named in the bitmask **and
arrives at the mbarrier of those CTAs** — plural, per-CTA, at the same shared-memory address.
Each participating CTA then **waits on its own local barrier**, which completes when its own
transaction-byte counter reaches zero.  `ctaMask` is a bitmask whose i-th bit selects the CTA
with cluster index i.

Corroborating evidence from our own codegen, which already emits the CTA-scoped forms for the
non-multicast case: [src/codegen.lisp:3475](../../../src/codegen.lisp)
`mbarrier.arrive.expect_tx.shared::cta` and :3484 `mbarrier.try_wait.parity.shared::cta`.

**Consequence: the design stands.**  `full` stays `:mode :block`, `:arrivals 2` is unchanged,
and the `:linear < :block < :cluster` ladder keeps its meaning — `:block` really does describe a
workgroup-local mbarrier even when a multicast is what fills it.

**Confidence caveat.**  Both sources are high-quality *secondary* sources (Colfax's CUTLASS
tutorials), not the ISA text itself.  The single-page PTX ISA HTML truncates before the
instruction section under fetch, so the primary text was not read directly.  The claim is
consistent across two independent tutorials, the libcudacxx syntax reference, and our own
shipped codegen — but if anything downstream behaves oddly, re-read the ISA before assuming the
bug is ours.

Sources:
- [CUTLASS Tutorial: GEMM with Thread Block Clusters (Colfax)](https://research.colfax-intl.com/cutlass-tutorial-gemm-with-thread-block-clusters-on-nvidia-blackwell-gpus/)
- [CUTLASS Tutorial: Mastering the TMA (Colfax)](https://research.colfax-intl.com/tutorial-hopper-tma/)
- [cp.async.bulk.tensor — libcudacxx](https://nvidia.github.io/cccl/libcudacxx/ptx/instructions/cp_async_bulk_tensor.html)

---

## Q1b (NEW). Who issues `expect_tx` — the leader only, or every destination CTA?

**This sub-question emerged from the Q1 research and it is API-relevant.**

Colfax's Blackwell cluster tutorial attributes `set_barrier_transaction_bytes()` — i.e.
`mbarrier.arrive.expect_tx` — to the **elected leader CTA only**, alongside issuing the copy.
Our `:arrivals` design assumed the opposite: that every destination CTA announces its own
expected byte count on its own barrier, and that the compiler therefore scales the user's
per-workgroup `:arrivals` by the cluster extent.

If the leader alone sets the transaction bytes — for all destination barriers, remotely — then
the compiler's scaling rule is wrong, and `:arrivals` may need no cluster adjustment at all.

**This must be settled before step 6 (`make-async-barrier-ring :mode :cluster`).**  It does not
block steps 1-2.  Settle it by reading CUTLASS's `PipelineTmaAsync` producer path directly
rather than a tutorial's prose.

### FINDING — RESOLVED (2026-08-16). EVERY CTA does its own local `expect_tx`. The tutorial was wrong.

CUTLASS `include/cutlass/pipeline/sm90_pipeline.hpp`, `PipelineTmaAsync::producer_acquire`:

```cpp
empty_barrier_ptr_[stage].wait(phase);
if (params_.is_leader) {
  full_barrier_ptr_[stage].arrive_and_expect_tx(params_.transaction_bytes);
}
```

`is_leader` looks like it might mean "the leader CTA of the multicast group", which is how the
Colfax tutorial reads it.  It does not.  The debug assertion immediately below it settles the
question:

```cpp
// Most likely you have elected more than one leader
if (params_.is_leader && (threadIdx.x % 32 != 0)) { asm volatile ("brkpt;\n" ::); }
```

That is a **lane-0 check within a CTA** — a *thread* election.  Every CTA elects one, and every
CTA therefore calls `arrive_and_expect_tx` on **its own local** `full_barrier_ptr_[stage]`.

**Consequence: the original design stands, unchanged.**  `:arrivals` on the data-arrival ring is
a per-workgroup count and needs no cluster adjustment, because each workgroup announces its own
expected bytes on its own barrier.

### DATE / SOURCE: 2026-08-16 — CUTLASS `main`, `include/cutlass/pipeline/sm90_pipeline.hpp:512-527`

---

## Q1c (BONUS). How is the `empty` barrier arrived on across the cluster?

This was the deferred lowering question — leader-only, or all-to-all?  The same file answers it.

```cpp
empty_barrier_ptr_[stage].arrive(dst_blockid_, is_signaling_thread_ & (!skip));
```

`arrive` takes a **remote** block id, confirming the reverse barrier is arrived on across CTAs —
which is exactly what `:mode :cluster` is for.  And the destination is *spread across threads*:

```cpp
auto [is_signaling_thread, dst_blockid] = detail::spread_arrivals_to_warpgroup(...);
is_signaling_thread_ &= dst_blockid_ < cluster_size;
is_signaling_thread_ &= is_same_row_or_col(dst_blockid_, block_id, cluster_shape);
```

**So it is ALL-TO-ALL within the multicast group, not leader-only**, with each signalling thread
responsible for one peer.  `is_same_row_or_col` confirms the group is the row or the column —
matching A-multicast-along-rows / B-multicast-along-columns.

**Consequence for `:arrivals` scaling:** the compiler's multiplier applies to the **`empty`**
ring only (the `:mode :cluster` one), and the factor is the **multicast group extent** — the row
or column length — *not* the total cluster size.  For a `(2 1)` cluster those coincide; for
`(2 2)` they do not.  Get this wrong on a 2x2 and the kernel hangs.

---

## Q2. Does `barrier.cluster.arrive` subsume intra-CTA thread convergence?

**Why it is load-bearing.**  `topology.md` states as fact that with cluster count 1,
`sync-cluster` is *"functionally exactly the same as `sync-workgroup`"*.  That holds only if the
cluster barrier also rendezvouses the threads **within** a CTA.

**If the answer is no:** the fused `(sync-cluster)` must emit an implicit `sync-workgroup`
alongside the cluster barrier, the degrade story changes, and that sentence is wrong as written.

### FINDING — CONFIRMED (2026-08-16). It DOES subsume. The topology.md sentence is correct.

Evidence, in increasing order of force:

1. **NVIDIA's own `cluster_group::sync()` contains no `__syncthreads()`.**  In CUDA 12.4's
   `cooperative_groups/details/helpers.h`, the cluster implementation is exactly:
   ```cpp
   _CG_STATIC_QUALIFIER void sync() { barrier_arrive(); barrier_wait(); }
   ```
   which bottoms out in the `__cluster_barrier_arrive()` / `__cluster_barrier_wait()` intrinsics
   (`crt/sm_90_rt.h:104-106`) and nothing else.

2. **The emitted PTX confirms it.**  Compiling `cg::this_cluster().sync()` with
   `nvcc -arch=sm_90a -ptx` yields precisely:
   ```
   barrier.cluster.arrive;
   barrier.cluster.wait;
   ```
   No `bar.sync`, no `barrier.sync`, no fence.

3. **The logic closes it.**  Cooperative Groups documents `sync()` as *"All threads in the group
   reach the synchronization point before any thread is allowed to proceed beyond it."*  A
   `cluster_group`'s threads are all the threads of all CTAs in the cluster.  If the cluster
   barrier did not rendezvous threads within a CTA, NVIDIA's own documented contract for its own
   API would be broken.

**Consequence: no implicit `sync-workgroup` is needed**, and `topology.md`'s "functionally
exactly the same as `sync-workgroup`" at cluster count 1 stands as written.

**Incidental but useful:** the default `cluster.sync()` emits the **non-`.relaxed`** form.  Our
decision to make `(sync-cluster)` memory-ordered by default, with no user-facing `:relaxed`, is
the same default NVIDIA ships.

### Superseded — what was NOT established in the first (web-only) pass:
- All threads of the group must participate.  The Cooperative Groups contract is that *"all
  threads in the group reach the synchronization point before any thread is allowed to proceed
  beyond it"*, and that memory accesses before the point are visible to the group after it.
- The `.aligned` qualifier is documented as being for the case where *all threads in the CTA
  will execute the same instruction*.
- `cluster.sync.aligned` is described as a cluster-wide barrier that all CTAs must reach.

Whether reaching that barrier also constitutes an intra-CTA rendezvous.  The CUDA Programming
Guide's Cooperative Groups page has no dedicated `cluster_group` semantics section, and the PTX
ISA single-page HTML truncates before `barrier.cluster` — so the web-only pass could not close
it.  Reading the shipped CUDA headers on the pod did, in about two minutes.

---

## Also settled while here

### Cluster extent limits — CONFIRMED (2026-08-16)

- **Portable maximum is 8.**
- **H100 allows a non-portable 16**, requiring the
  `cudaFuncAttributeNonPortableClusterSizeAllowed` function attribute to be set (1 = allowed).
- Larger clusters may reduce the maximum number of active blocks across the GPU — which
  corroborates the scheduler-quantization argument for preferring a 2-workgroup cluster.

`topology.md`'s text is therefore **correct as written** and the hedge on it can be removed.

Source: [NVIDIA Hopper Tuning Guide](https://docs.nvidia.com/cuda/hopper-tuning-guide/index.html)

Empirically re-confirmed on the H100 (`/root/probe/q3.cu`): cluster 8 launches, cluster 16 fails
with `cudaErrorInvalidClusterSize`, and cluster 16 succeeds after
`cudaFuncSetAttribute(k, cudaFuncAttributeNonPortableClusterSizeAllowed, 1)`.

### Grid divisibility — CONFIRMED REQUIRED (2026-08-16). It is a hard launch error.

Measured on H100 PCIe via `cudaLaunchKernelEx`:

| grid | cluster | launch result |
|---|---|---|
| `(4,1,1)` | `(2,1,1)` | `cudaSuccess` |
| `(3,1,1)` | `(2,1,1)` | **`cudaErrorInvalidClusterSize`** |
| `(4,3,1)` | `(2,2,1)` | **`cudaErrorInvalidClusterSize`** (the y axis) |

So `gridDim % clusterDim == 0` is enforced **per axis**, at launch, as a hard error — not a
warning and not a silent clamp.

**This CLOSES the open decision in `topology.md`, and closes it in favour of the proposed
policy** — but note the reasoning is stronger than "we chose to pad."  Something *must* happen,
because a non-divisible grid does not launch at all:

- **`:strided`** — pad the grid up to a multiple of the cluster dims.  The surplus workgroups
  find no tiles left to claim and exit; the `tile-stride` loop still covers every tile.  Safe.
- **`:exact`** — padding would create workgroups with no tile, and truncating would skip one.
  Neither is acceptable, so it must be a hoist-time **error** naming the tile shape and cluster
  shape that conflict.

The "Open decision" blockquote in `topology.md` can now be removed and replaced with this
measurement.

Probe source is on the pod at `/root/probe/q3.cu`; worth copying into the repo as a permanent
artifact if we want the table reproducible.


---

## Rung 04's launch assumption — SETTLED ON METAL (2026-08-16)

The hoist deliberately does not use `cuLaunchKernelEx`; it relies on the shape being baked
into the PTX as `.reqnctapercluster` and launches with a plain `cuLaunchKernel`.  That was
written down as an assumption, with the note that being wrong would fail loudly.

**It is correct.**  On an H100 PCIe (CUDA 12.4), `04-cluster-size-on-metal` produced:

    Device: NVIDIA H100 PCIe
    PTX module loaded successfully
    Kernel executed successfully
    BUFFER a: 0 1 2 3
    BUFFER c: 0 2 4 6
    Success!

A clustered kernel loads, launches and computes correctly without any launch-time cluster
attribute.  `CU_LAUNCH_ATTRIBUTE_CLUSTER_DIMENSION` is for setting the shape DYNAMICALLY,
which Crisp does not support by design.

The spec still failed, and only because of its own expectation: it predicted `BUFFER c:
2 2 2 2` on the guess that the harness fills tensors with a constant.  It fills them
0,1,2,3, and allocates a fixed 4 elements per param regardless of the declared global-size.
Expectation corrected to `0 2 4 6`.

**Also cleared by the same run:** the CUDA hoist path had NEVER executed before this.  Every
`TEST-HOIST[CUDA]` spec reports `SKIP (nvcc not available)` on the dev box, so
`generate-cuda-launcher` and the grid reconciliation were unexercised code behind four green
suites.  Pod result: `--differentiate` 1012/1012, negative 217/217, and the only default-phase
failures were this expectation plus the two multicast rungs whose lowering is not written yet.

---

## FINDING (2026-08-16, on metal) — grid PADDING and MULTICAST are in conflict

Rung 11 failed on an H100 with `unspecified launch failure`.  `compute-sanitizer memcheck`
reported no invalid access, so it is not a bounds bug.  The launcher's own note gives it away:

    note: grid padded (1,1,1) -> (2,1,1) for cluster (2,1,1)

The tensor is small enough to be ONE tile.  The cluster needs two workgroups, so the
divisibility policy pads the grid to 2 — and the surplus workgroup, by design, "finds no tiles
left to claim and exits".  That is exactly right for an ordinary strided kernel and **fatal for
a multicast**: the issuing workgroup multicasts into a peer that has already exited, never
initialised its mbarrier, and never ran `expect_tx`.

A control run of the identical kernel with `:multicast` removed completes correctly, which is
what isolates this to multicast rather than to the spec's geometry in general.

### Why this matters beyond one spec

The padding policy was settled from a MEASUREMENT — the driver rejects a non-divisible grid per
axis — and the reasoning was "`:strided` has a stride loop, so surplus workgroups are harmless."
That reasoning holds for loads, and does NOT hold for multicast, because a multicast has a
*destination* that must still be alive and participating.

So `pad for :strided` is not sufficient on its own once `:multicast` is in play.  The options,
none of them free:

1. **Require the problem to cover the cluster.**  A multicast kernel whose grid needed padding
   is refused, the way `:exact` already is.  Honest, and it makes the constraint visible, but it
   rejects ragged problem sizes that would otherwise be fine.
2. **Make padded workgroups participate.**  They would have to run the barrier protocol —
   mbarrier init, the cluster fence, `expect_tx`, the awaits — while claiming no tile.  That is
   the CUTLASS-shaped answer but it means the "surplus workgroups just exit" story is no longer
   true for clustered kernels.
3. **Pad the PROBLEM rather than the grid**, so every workgroup has a real (possibly
   identity-filled) tile.  `scramble.md` already lists an "oversubscribe and fill with an
   identity value" idea for `:strategy :tiled`; this is the same idea arriving from a different
   direction.

NOT YET DECIDED.  Recorded here because it is a genuine constraint discovered by measurement,
and because the note in `topology.md` that padding is "a small amount of wasted dispatch, not
correctness" is **false for multicast kernels** and must be qualified when this is settled.

### Immediate consequence for rung 11

The rung's own geometry is degenerate: one tile, so the second cluster member exists only
because of padding.  A real matmul has many tiles and both members have work.  The spec needs a
tile shape that yields at least two tiles along the clustered axis, so it exercises multicast
between two workgroups that are BOTH doing work — which is the case that matters.

### Rung 11 status as of 2026-08-16 — NOT WORKING.  Three distinct faults peeled back so far.

The multicast is EMITTED correctly (rung 10 asserts that and passes: `.multicast::cluster`,
ctaMask 3, `%cluster_ctarank` leader, `expect_tx` outside the guard, cluster entry fence).  It
does not yet RUN.  Each fix exposed the next fault, and all three were real:

| # | geometry | fault | cause |
|---|---|---|---|
| 1 | tile (8 8), 1 tile | `unspecified launch failure` | padded peer exits; multicast targets a dead workgroup (see above) |
| 2 | tile (2 2), 2x2 tiles | `invalid argument` at `cuTensorMapEncodeTiled` | TMA needs the innermost box dim to be a multiple of 16 bytes; 2 floats = 8 |
| 3 | tile (2 4), 2 row-tiles, no padding | **`an illegal instruction was encountered`** | UNKNOWN — current blocker |

Fault 3 is the live one.  What is known:
  * the grid no longer pads, so both cluster members have real work
  * a control run with `:multicast` removed at the SAME geometry is the next thing to get
    (the run that would have produced it timed out under compute-sanitizer)
  * `compute-sanitizer memcheck` on fault 1 reported NO invalid access, so these are not
    out-of-bounds

Candidates not yet eliminated, roughly in order of suspicion:
  1. The cluster entry fence is emitted INSIDE the `tile-stride` loop, because
     `make-async-barrier` is bound inside the loop in this spec.  A cluster barrier executed a
     different number of times by different workgroups is a hang or a fault.  Check whether both
     workgroups run the same trip count, and consider whether the fence belongs at kernel entry
     rather than at barrier-construction.
  2. The multicast destination SMEM address must be identical in every destination workgroup.
     Believed automatic (same kernel, same allocation) but NOT verified.
  3. Whether the mbarrier used by a multicast must itself be `shared::cluster` rather than
     `shared::cta`.  Phase 0 Q1 says the transaction completes on each destination's OWN
     barrier, which implies `.cta` is right — but that was settled from secondary sources, and
     the caveat recorded there says to re-read the ISA if something downstream behaves oddly.
     This is downstream behaving oddly.

NOTE ON METHOD: rung 10 and rung 11 are doing exactly the job they were designed for.  Rung 10
proves the instruction is emitted; rung 11 proves — or in this case refuses to prove — that it
works.  A suite that only had rung 10 would currently be reporting success.

---

## ANSWER to the fence-placement question (2026-08-17)

**The fence is in the right place.  The SPEC was wrong, and behind it sits a real structural
limit on one-shot multicast.**

### What was actually wrong

Rungs 10/11 bound `make-async-barrier` INSIDE `tile-stride`.  The emitted PTX put
`mbarrier.init`, the cluster entry fence and the multicast all inside a depth-2 loop.  Two
independent hazards, either fatal:

* a cluster-wide rendezvous executed a DIFFERENT number of times by workgroups that claim
  different numbers of tiles — mismatched trip counts hang
* `mbarrier.init` re-initialising the same module-global barrier every iteration while a peer
  may still be waiting on it

The shipped chapter-3 kernel binds its barriers OUTSIDE `tile-stride`, which is why it has never
hit this.  Rungs 10/11 now match it: init and fence are emitted once, before the loop; only the
multicast is per-tile.  Verified in the emitted PTX.

### The deeper limit, which fence placement cannot fix

`await` RE-INITIALISES the mbarrier inside the loop (src/codegen.lisp, `tma_reinit`), guarded by
`tid==0` and a workgroup `bar.sync`.  For a cluster that is the same race one iteration later:
the leader can re-init and issue the NEXT multicast before a peer has re-inited its own barrier.

Adding a cluster fence there would put a cluster-wide rendezvous back inside a
variable-trip-count loop — strictly worse.  So:

> **A single re-used barrier is not sound for multicast in a cluster across loop iterations.
> The correct construct is a barrier RING whose reverse (`empty`) barrier is cluster-scoped —
> i.e. Phase 2 steps 5 and 6, which are not built yet.  That is also exactly what the real
> chapter-3 kernel uses, and why it will be the first sound multicast pipeline.**

Rungs 10/11 remain valid ONLY because their trip count is uniformly 1 (2 tiles over 2
workgroups, one each), so the re-init is never followed by another multicast.  That is a narrow
soundness condition and it is recorded here rather than left implicit.

### Consequence for the plan

Step 2 ("one-shot multicast, no ring") was designed as the de-risking spike precisely because it
needs no ring.  That was right for proving the INSTRUCTION — rung 10 passes and did its job.  It
was over-optimistic for proving the DATA PATH, which turns out to need the ring after all.
Rung 11 should be expected to go green only once steps 5/6 land, unless its one-iteration
geometry holds.

STILL UNVERIFIED ON METAL: the pod was released before the restructured kernels could be run.
Everything above about the PTX structure is verified; nothing about rung 11 executing is.


---

## FINDING (2026-08-17, on metal) — `mapa` needs a GENERIC address. The obvious form does not map.

Crisp emitted, for a cluster-scoped `signal`:

    mapa.shared::cluster.u32 %rD, %rSharedOffset, %rRank;
    mbarrier.arrive.shared::cluster.b64 _, [%rD];

which reads correctly and is WRONG.  On an H100 it produced

    Invalid __shared__ read of size 4 bytes
      by thread (0,0,0) in block (1,0,0)
      Address 0x0 is not located in executing CTA

where 0x0 and 0x10 are precisely the shared-window offsets of the two mbarrier globals -- i.e.
the address reaching the arrive was the UNMAPPED local offset.

GROUND TRUTH, obtained the same way Q2 was settled: compile NVIDIA's own
`cooperative_groups::cluster_group::map_shared_rank()` with `nvcc -arch=sm_90a -ptx` and read it.

    cvt.u64.u32        %tmp,  %rSharedOffset
    cvta.shared.u64    %gen,  %tmp            <- shared window -> GENERIC
    mapa.u64           %peer, %gen, %rRank    <- mapa operates on GENERIC addresses
    cvta.to.shared.u64 %tmp,  %peer           <- back to the shared window
    cvt.u32.u64        %r,    %tmp
    mbarrier.arrive.shared::cluster.b64 _, [%r];

FIXED.  `%gen-nvvm-mapa-shared-cluster` now emits that round-trip as one inline-asm block.

WHY IT MATTERS BEYOND THE BUG: an unmapped arrive lands on the CALLER'S OWN barrier.  That is
exactly the silent-local-arrive failure rung 21 was written to catch -- and at cluster extent 1
the two addresses coincide, so it would pass every small test.  Here it surfaced as a hardware
fault only because the sanitizer noticed the address was not CTA-local.  `validate-ptx-cluster-
remote-arrive` now asserts the CONVERSION, and explicitly fails the old form.

## FINDING — rung 04's launch conclusion was right, but under-evidenced

Rung 04 proved a `.reqnctapercluster` kernel LAUNCHES under a plain `cuLaunchKernel`.  It used no
cluster INSTRUCTIONS, so it did not prove a usable cluster was formed.  Closed properly: NVIDIA's
own `__cluster_dims__(2,1,1)` kernel doing `mapa` + `mbarrier.arrive.shared::cluster` +
`cluster.sync()` under `k<<<2,32>>>` returns `cudaSuccess`.  The assumption holds, now for the
right reason.  `cuLaunchKernelEx` remains unnecessary.

## RUNG 11 — still failing, but the fault has MOVED OUT of the cluster machinery

After the slot fix and the mapa fix, rung 11 still faults.  `compute-sanitizer` + `nvdisasm` put
it at:

        /*1250*/  @!P0 VIADD  R19, R16, UR12 ;
        /*1270*/  @!P0 IADD3.X R7, R18, UR13, RZ, P6, !PT ;   <- reported PC
        /*1280*/  @!P0 LDS    R19, [R19] ;                    <- the access

A PLAIN shared load with a computed index, reading outside the executing CTA's shared window in
block (1,0,0).  That is tile addressing or shared allocation -- NOT multicast, NOT the barrier,
NOT mapa.  Both remaining cluster instructions now match NVIDIA's own codegen.

NEXT SESSION STARTS HERE, and needs no pod until there is a candidate fix.  Suspects, cheapest
first: the scratch-matrix-ring's slot addressing under a cluster; whether the tile ring's dynamic
SMEM size accounts for ring-count; and whether `store-tile` reads a slot the multicast wrote at a
different offset.


---

## RUNG 11 — narrowed further, LOCALLY (2026-08-17). The faulting read is `store-tile`.

Static analysis, no pod needed, and it rules several things out.

THE FAULT IS THE KERNEL'S ONLY `ld.shared`.  There is exactly one in the module
(`ld.shared.b32 %r33, [%rd57]`), and it belongs to `store-tile` reading the staged tile back out
to global.  The sanitizer's two reported addresses map onto it exactly:

    tile ring = 2 slots x 2 rows x 4 cols x 4B = 64B   (launcher requests 64B dynamic SMEM)
    row stride = 4 floats = 16 bytes
    reported: thread 0 -> 0x0 (row 0), thread 1 -> 0x10 (row 1)

So store-tile computes CORRECT tile-relative offsets.  What is wrong is that those ABSOLUTE
shared addresses are reported as not CTA-local in block (1,0,0).

RULED OUT:
  * the ring SLOT.  `slot = (mod grid-x 2)`, and with `:tile-shape (2 4)` over a 4x4 C the
    column axis has ONE tile, so grid-x is always 0 and slot is always 0.  Not a slot bug.
  * `mapa` / the remote arrive / the multicast instruction.  All now match NVIDIA's own codegen,
    and none of them is an `ld.shared`.
  * "scratch at shared offset 0 is inherently wrong".  The shipped chap3 kernel does exactly the
    same thing -- `b-ring_from_matmul_2 ... shared offset 0`, `ptr = 0ULL`, 81920 bytes of
    dynamic SMEM -- and is known-good on H100.  The DIFFERENCE is that chap3 has no cluster.

THE LIVE HYPOTHESIS, unconfirmed: a `:local` scratch tensor addressed from a base of literal 0
behaves differently under `.reqnctapercluster`, because with a cluster the shared window is the
DISTRIBUTED one and a low absolute address belongs to rank 0 rather than to the executing CTA.
That would make every non-rank-0 workgroup read a peer's memory -- which is precisely what
"Address 0x0 is not located in executing CTA" says.

It cannot be the WHOLE story (a clustered kernel must be able to use its own shared memory), so
the question is what makes the base resolve absolutely here.

### NEXT POD SESSION — run these two FIRST, in this order.  Both are bisects, not fixes.

1. **Same ring kernel, `:multicast` removed, cluster-size KEPT.**  Isolates multicast from
   cluster+ring+scratch.  If it still faults, multicast is innocent and the bug is in scratch
   addressing under a cluster.  (An equivalent control was run for the earlier ONE-SHOT kernel
   at tile (8 8) and passed, but never at the current geometry with a ring -- so this is
   genuinely undone, not merely unrepeated.)

2. **Same kernel, `cluster-size` removed, multicast removed.**  If THAT passes and (1) fails,
   the cluster is what changes scratch addressing, and the fix is in how a `:local` scratch base
   is computed for a clustered kernel.

Only after both should anything be changed.  This endeavour has twice paid for guessing at a
fix before bisecting.
