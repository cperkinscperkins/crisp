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


---

## ROOT CAUSE (2026-08-17, bisected on H100) — `:local` SCRATCH IS BROKEN UNDER A CLUSTER

Not multicast.  Not the barrier.  Not `mapa`.  Not the cluster entry fence.  The minimal
reproduction has none of those:

| variant | cluster-size | scratch | TMA / barriers | result |
| --- | --- | --- | --- | --- |
| H | no  | yes | none | **PASSES**, correct output |
| G | YES | yes | none | **illegal instruction** |
| B | no  | yes | ring + :block | **PASSES**, correct output |
| C | YES | yes | ring, all :block, no multicast | HANGS |
| A | YES | yes | ring, :mode :cluster, no multicast | HANGS |
| rung 11 | YES | yes | ring + multicast | illegal instruction |

G vs H differ ONLY in `(cluster-size :set-to (2 1))`.  So:

> **A kernel that declares a cluster and allocates ANY `:local` scratch tensor is broken,
> independent of every other cluster feature.**

MECHANISM, and it matches the sanitizer verbatim.  The hoist passes a `:local` scratch base as a
literal shared-memory OFFSET (`..._ptr = 0ULL; // shared mem offset`), which the kernel uses as
an absolute shared address.  Without a cluster every CTA's shared window starts at 0, so that is
correct.  Under `.reqnctapercluster` the window is the DISTRIBUTED one and a low absolute address
names **rank 0's** shared memory -- so every non-rank-0 workgroup reads a peer.  The sanitizer
said exactly this:

    Invalid __shared__ read of size 4 bytes
      by thread (0,0,0) in block (1,0,0)
      Address 0x0 is not located in executing CTA

WHY RUNG 04 PASSED AND HID THIS: it copies through global memory and allocates no scratch.  Its
conclusion ("a .reqnctapercluster kernel launches correctly under a plain cuLaunchKernel")
remains true and was independently re-confirmed against NVIDIA's own __cluster_dims__ kernel.
It simply never exercised shared memory.

THINGS THIS EXONERATES, each disproved by measurement rather than argument:
  * multicast -- variant A has none and still fails
  * the `:mode :cluster` barrier and remote arrive -- variant C uses only :block
  * the cluster entry fence -- rebuilt with `%module-has-cluster-p` forced NIL (0 fences
    emitted); A and C still hang.  The fence structure was ALSO reproduced in raw CUDA (two
    inline-asm `barrier.cluster.arrive; barrier.cluster.wait;` with tid-0-guarded inits between)
    and returns cudaSuccess.
  * `mapa` -- now matches NVIDIA's codegen, and G contains no mapa at all

### THE FIX BELONGS IN SCRATCH ADDRESSING, NOT IN THE CLUSTER API

The scratch base must resolve to the EXECUTING workgroup's own shared window rather than an
absolute offset.  Candidates, cheapest first, none yet tried:
  1. Derive the base from a `.shared` symbol (cvta.shared) instead of a literal integer, so the
     address is CTA-relative by construction.
  2. Check whether NVCC-generated `extern __shared__` under `__cluster_dims__` resolves
     differently -- i.e. get ground truth the same way the mapa question was settled.

UNTIL THEN: every 152 metal rung that stages through `:local` scratch is blocked, which is rungs
11 and (when written) the MMA realization.  The compile-and-inspect rungs are unaffected and
remain green.

NOTE: the pod carries a TEMPORARY hack appended to its overlay (`%module-has-cluster-p` -> NIL)
from the fence bisect.  It is POD-ONLY; the repo copy is untouched.

### What the PTX says (static, no GPU needed)

G and H were compiled locally and diffed.  **The PTX is byte-identical apart from two lines:**

    < .explicitcluster
    < .reqnctapercluster 2, 1, 1

Same registers, same address arithmetic, same `st.shared.b32` / `ld.shared.b32`.  So this is not
a codegen divergence -- it is the SAME code behaving differently once the entry is marked as
clustered.

Three things that static reading DID settle, each of which was a candidate:

* **Shared memory is allocated.**  The launch passes 32 bytes of dynamic shared (`cuLaunchKernel(
  ..., 32, 1, 1, 32, 0, ...)`), exactly the tile size.  A "cluster kernel with zero shared" theory
  is dead.
* **The cluster axis mapping is CORRECT.**  Crisp's row axis maps to CUDA's x on the hoist path
  (`gridX = (c_ext0+1)/2`, extent 0 = rows), `.reqnctapercluster 2,1,1` puts the 2 on x, and the
  grid fixup pads gridX by 2.  Declaration, directive and launch all agree.
* **How the scratch base reaches the kernel**, and this is the suspect.  A `:local` scratch tensor
  is passed as a u64 **kernel parameter holding the literal integer 0** and used DIRECTLY as a
  shared-space address -- there is no `.shared` symbol anywhere in the module and no `cvta`:

      // host
      uint64_t tile_from_g_sync_1_ptr = 0ULL;  // shared mem offset
      // device
      add.s64      %rd128, %rd45, %rd142;   // %rd45 traces back to that parameter
      st.shared.b32 [%rd128], %r15;

  With no cluster, "shared offset 0" is unambiguous.  Under `.reqnctapercluster` the shared window
  is the distributed one, and whether a bare 0 still names the EXECUTING CTA is exactly the
  question -- the sanitizer's "Address 0x0 is not located in executing CTA" says it does not.

### The experiment that settles it: `put_temp_files_here/lds/lds_base.cu`

Static reading has gone as far as it can; the remaining question is a runtime address-encoding
question.  Four kernels, one file, ~70 lines, needs an H100:

| | addressing | cluster | asks |
| --- | --- | --- | --- |
| Q1a | `extern __shared__` symbol | no  | is a CTA's own shared base 0 without a cluster? |
| Q1b | `extern __shared__` symbol | 2,1,1 | **does it stay 0 WITH one?** |
| Q2a | raw address 0 (what Crisp does) | no  | control -- must pass |
| Q2b | raw address 0 (what Crisp does) | 2,1,1 | **must reproduce the illegal instruction** |

Q1b is the whole endeavour in one number.  If the symbol base is NON-ZERO under a cluster while
Q2b faults, the diagnosis is proven and the fix is scoped: a `:local` scratch base must be derived
from the executing CTA's shared window rather than passed in as a literal offset.  If Q1b is 0 and
Q2b passes, the cause is somewhere else entirely and this note is wrong -- which is why the
control rows are there.
### ANSWERED ON AN H100 (2026-08-17).  Hypothesis confirmed, with the exact encoding.

    Q1a symbol base, NO cluster     blocks 0,1,2,3 -> smem_base = 0x400        no error
    Q1b symbol base, CLUSTER 2      blocks 0,2     -> smem_base = 0x400
                                    blocks 1,3     -> smem_base = 0x1000400    no error
    Q2a raw base 0, NO cluster                                                 no error
    Q2b raw base 0, CLUSTER 2                          ILLEGAL INSTRUCTION

**A CTA's shared window base is rank-dependent under a cluster.**  The CTA rank sits at bit 24
(`1 << 24 == 0x1000000`), so rank 1's shared memory begins at `0x1000400`, not `0x400`.  A raw
address of 0 therefore names *rank 0's* window; for every non-rank-0 CTA it is a peer's memory,
and the hardware refuses it.  That is the sanitizer message word for word.

**And a second, larger finding fell out of Q1a: the base is 0x400 even WITHOUT a cluster.**
Dynamic shared memory begins 1024 bytes into the window.  Crisp addresses `:local` scratch from
an absolute 0, i.e. *below the dynamic region it actually requested* -- for every PTX kernel it
has ever compiled, cluster or not.  Q2a shows the hardware tolerates this when there is no
cluster, so it has never been visible.  It is nonetheless wrong, and clusters are simply the
first configuration in which the hardware says so.

### The fix, validated in Crisp's own idiom (Q3)

`put_temp_files_here/lds/lds_fix.cu` re-runs the failing case with one change -- the base comes
from the shared SYMBOL rather than a literal -- while keeping Crisp's exact addressing style
(`st.shared.b32` / `ld.shared.b32` on a u64 register, plus a per-tensor offset operand):

    Q3 raw asm, base from shared SYMBOL, CLUSTER 2
      block=0 base=0x400   block=1 base=0x1000400   block=2 base=0x400   block=3 base=0x1000400
      -> no error
      out = 3 3 3 3   (expect 3 3 3 3)

So the shape of the fix is settled and it is small: **keep the host-side per-tensor offset scheme
exactly as it is, and add the executing CTA's shared base to it inside the kernel.**  In NVVM that
is an external `addrspace(3)` global, which NVPTX lowers to `.extern .shared .align N .b8 sym[]`;
`ptrtoint` of it yields the per-CTA base the hardware resolves correctly.  This is precisely what
NVCC emits for `extern __shared__`, which is why Q1b/Q3 work.

The host cannot compute this -- the base is not knowable before the CTA is placed -- so the
correction must be kernel-side.

### Consequences to settle BEFORE patching

1. **Scope.**  This is scratch addressing, not the cluster API.  It touches every `:local` tensor
   on PTX, so it is not a 152-local change and wants its own verification pass.
2. **Does the requested dynamic size cover all scratch?**  Today the kernel writes below the
   dynamic region, so an under-request would never have faulted.  Once the base is correct, an
   under-request becomes a real overflow.  The G hoist requested exactly 32 bytes for a 32-byte
   tile, which is the right answer for one tensor; the multi-tensor and ring cases must be
   confirmed before flipping the base.
3. **Intel / SPIR-V is out of scope and must stay that way** unless measurement says otherwise --
   Intel has no cluster hardware and its local memory is reached differently.

### Consequence 2 answered: the dynamic-size request is SOUND, but the offset allocator has a hole

Measured by compiling representative kernels and comparing the allocator's `shared offset` lines
against the `cuLaunchKernel` sharedMemBytes argument:

| kernel | offsets assigned | launch requests | agree? |
| --- | --- | --- | --- |
| two scratch tensors | 0, 32 | 64 | YES |
| `make-scratch-matrix-ring :ring-count 4` | 0 (one rank-3 param, 128 B) | 128 | YES -- the ring folds into ONE param |
| scratch tensor + scratch CELL | **0 and 0** | 36 (=32+4) | **NO -- they alias** |

So `compute-total-shared-bytes` (src/hoist-cuda/main.lisp:541) counts cells correctly, but
`%cuda-emit-cell-arg` emits `<name>_local_ptr = 0` without ever consulting
`*cuda-shared-scratch-offset*` -- the running allocator that `%cuda-emit-local-scratch-tensor-arg`
uses.  Cells therefore always sit at offset 0, on top of the first scratch tensor.

**This is not theoretical -- it silently corrupts data on an H100 today, with no cluster
involved.**  A kernel whose cell write lands between the tile load and the tile store:

      (load-tile A tile (0 grid-x))
      (set! (~ acc) 99.0)
      (store-tile tile C (grid-y grid-x))

      BUFFER a: 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
      BUFFER c: 99 1 2 3 4 5 6 7 99 1 2 3 4 5 6 7      <-- element 0 of every tile clobbered

Ordering decides whether it shows: the same kernel with the `set!` moved ABOVE `tile-stride`
produces perfectly correct output, because the tile load simply overwrites the cell.  That is why
it has survived -- it is invisible unless a cell write is interleaved with tile use.

It is the same class as BUG 034, which was fixed for tensor-vs-tensor and never extended to
cell-vs-tensor.  Proposed as **BUG 046**.

**Intel / SPIR-V is structurally immune to both problems.**  The L0 hoister does not build a
shared blob with offsets at all -- each local tensor gets its own runtime-allocated SLM argument
(`zeKernelSetArgumentValue(kernel, idx, bytesize, nullptr)`), so there is nothing to collide in
and no base to get wrong.  Both findings are NVIDIA/CUDA-hoist only, which is what the earlier
"keep Intel out of scope" note hoped for and this confirms.

### Where that leaves the fix

The cluster base fix is SAFE from the under-request angle: for tensors and rings the requested
size already covers every byte addressed.  The cell hole is an OVERLAP, not an overflow, so it
does not block the base change -- but both touch the same allocator and are cheapest to reason
about together.

Two independent changes, both small, both CUDA-only:

* **A (BUG 046, cell offsets):** make `%cuda-emit-cell-arg` draw from `*cuda-shared-scratch-offset*`
  exactly as the tensor path does.  Fixes a live silent corruption; independent of clusters.
* **B (152, CTA-relative base):** add the executing CTA's shared base to the host-supplied offset
  inside the kernel, via an external `addrspace(3)` global.  Mechanism already validated (Q3).
