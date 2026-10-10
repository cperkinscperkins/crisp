Endeavour 183 -- last-man's fence: thread 0 releases, the elected workgroup acquires
====================================================================================

APPROVED by Chris 2026-10-08 ("anything worth doing is worth doing right"); implemented the same day.  Comes out of 181 (follow-up 3) and BUG 082.


Why
---

Today every thread of every workgroup executes last-man's device-scope `mem-fence`, because BUG 082
refuses a fence inside `when-thread-in-group-is 0`.  Measured on BMG (181, `_probe_lastman`, 320
groups = 4x occupancy, local 256):

| arm | 64 MiB | 1 GiB |
|---|---|---|
| `:atomic` | 156.0 us | 2374.9 us |
| `:atomic` + one fence | 197.0 | 2431.6 |
| last-man (stock) | 194.7 | 2436.2 |
| last-man WITHOUT the fence (unsafe; measurement only) | 158.1 | 2376.0 |

The whole last-man penalty is the fence: 256 threads x 320 groups of device-scope fences, where one per
group would do (CUDA's threadFenceReduction sample: thread 0 alone calls `__threadfence()`).  At the
default grid (R=1) it is ~8 us on BMG; on the H100 SXM last-man's fixed cost at 1 MiB is 13 us against
6.8 us for `:atomic`, and the fence is the first suspect for the difference (not yet measured there).


The memory-ordering argument (the part to check)
-------------------------------------------------

Publish-then-signal across workgroups needs a RELEASE on the writer and an ACQUIRE on the reader.

- **Release -- thread 0 of each workgroup, in program order:** store its partial(s) to `gv[g]`;
  `mem-fence` (device scope); `atomic-add!` the ticket.  Only thread 0 stores the partial, so only its
  program order matters -- the other 255 threads' fences order nothing that anyone reads.
- **Acquire -- the elected workgroup, once:** after the barrier that publishes the ticket verdict, every
  thread of the ELECTED workgroup executes one `mem-fence` before reading the partials.  Today there is
  NO fence on the reading side at all -- the readers rely on the writers' fences plus the barrier,
  which is what the CUDA sample does and works in practice, but it is not what the memory model
  promises.  This proposal makes the acquire explicit, so it is MORE correct than today, not less.

Fence count per launch: today ng x ls (270k at H100 occupancy); proposed ng + ls (~1.3k).

The counter reset (179) and the strided sweep (181) are unchanged.


What changes
------------

1. **BUG 082, the real fix it describes:** `mem-fence` stops going through the divergence check; that
   check moves onto `sync-wait`, the construct that genuinely deadlocks under divergence.
   `118-async-misc/errors/02-arrival-sync-divergent` must STILL fail -- with `sync-wait` wording
   instead of the borrowed `MEM-FENCE` text it matches today (its CHECK-FAIL changes accordingly).
2. **The three last-man lowerings** (`%grid-reduce-last-man-expand`, `%fused-grid-reduce-form`,
   `%fused-grid-reduce-dependent-form`): the partial store, the fence and the ticket move into ONE
   `when-thread-in-group-is 0` block; the elected branch gains one fence before the sweep.


Tests (TDD)
-----------

- unit: in all three expansions the fence sits inside the thread-0 block between store and ticket,
  and the elected branch starts with a fence; no fence executed by all threads before the ticket.
- negative: a fence inside a divergent conditional is ACCEPTED (BUG 082's example); a divergent
  `sync-wait` is still REFUSED, with wording that names sync-wait.
- metal (BMG): every 175-181 last-man spec and VERIFY-AUTODIFF spec unchanged; 181's many-groups specs.
- benchmark: BMG `_probe_lastman` / rollup at R=1 and R=4 -- last-man should land on `:atomic`;
  H100 SXM: the small-size rows (1-64 MiB) -- needs a pod, after BMG is green.


What happened
-------------

- **BUG 082's diagnosis was wrong.**  Exempting the fence does not free a divergent sync-wait: its
  expansion ends in a sync-workgroup, which the same check refuses.  The August "274 -> 273" was 118/02's
  CHECK-FAIL text (it matched the borrowed MEM-FENCE wording), not a kernel that compiled.  So nothing
  moved onto sync-wait; the barriers got an accurate message instead, and 118/02 matches it.
- **IR, by hand** (BMG, `--debug` keeps the .opt.ll): one `__spirv_MemoryBarrier(1, 520)` inside thread 0's
  block immediately before the ticket's `atomicrmw`, one opening the elected branch, none executed by
  every thread.
- **BMG, scratch, last-man before -> after (`:atomic` for reference):** R=1 1 MiB 7.7 -> 5.8 us (3.3);
  R=1 3 GiB 7166 -> 7159 us (7186); R=4 64 MiB 194.7 -> 162.3 us (156.1); R=4 1 GiB 2436 -> 2379 us (2374);
  argmax R=4 64 MiB 205.6 -> 175.4 us.  The 40-80 us penalty at 4x occupancy is ~5 us now.


Plan
----

- [x] decisions (Chris): release/acquire split; fix BUG 082
- [x] TDD: last-man-fence.unit.lisp (fence placement, all three lowerings), 01 (metal), 02 (both
      backends), errors/01-02; 118/02 CHECK-FAIL updated; ci-stop -> 183
- [x] implement (overlay): %warp-spec-check-sync; the three last-man lowerings
- [x] BMG on metal + benchmark (above)
- [x] docs: ideal_001.md (mem-fence in divergent code, sync-workgroup must be reached, last-man phases),
      reductions-excerpt.md; BUG 082 closed with the corrected diagnosis
- [x] full gate: unit, E2E 1434/1434, negative 331/331, six last-man VERIFY-AUTODIFF specs (BMG)
- [x] H100 SXM (fb35b716, `scripts/183-pod-fence.sh`; 33/33 CUDA specs, stale demo caught 2/2): the fence
      was NOT NVIDIA's cost.  last-man 1 / 16 / 64 / 256 MiB = 12.7 / 15.6 / 39.2 / 103.2 us, against the
      pre-183 canonical 13.0 / 16.0 / 39.6 / 103.9 -- ~0.4 us; `:atomic` same session 6.7 / 8.5 / 28.4 /
      92.2.  On BMG 16 subgroups per group each issued a device-scope fence (the 40-80 us at R=4); on
      the H100 a fence issues once per warp, 8 per group, and was cheap.  The remaining ~6 us is
      STRUCTURAL to single-pass last-man: after the last group arrives, its store -> fence wait ->
      ticket round trip -> barrier -> sweep load -> second reduce-workgroup are all on the critical
      path, where `:atomic` ends at one atomic.  No cheap lever left there; the trade is last-man's
      determinism (bit-reproducible, ~15x more accurate) for that latency.
- [x] fold (2026-10-10): four verbatim replacements, overlay emptied; rebuild has no redefinitions; unit 389,
      E2E 1434/1434, negative 331/331, six last-man VERIFY-AUTODIFF specs; docs regenerated
