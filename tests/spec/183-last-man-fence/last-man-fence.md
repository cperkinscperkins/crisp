Endeavour 183 -- last-man's fence: thread 0 releases, the elected workgroup acquires
====================================================================================

PROPOSAL, 2026-10-08 -- for Chris's review before any code.  Comes out of 181 (follow-up 3) and BUG 082.


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


Decision wanted
---------------

- Is the release/acquire split above the design you want, or do you want the fence kept on every
  thread (status quo) as the conservative choice?
- OK to fix BUG 082 as its entry describes (move the check to sync-wait)?
