Endeavour 181 -- lift last-man's "groups <= local size" cap
===========================================================

Recorded 2026-10-06; not started.  Comes out of the reduction benchmarks
(`plan/benchmark-reductions.md`, phase 5; `benchmarks/REPORT-reduction.md`).


Why
---

`grid-reduce-last-man!` -- the DEFAULT strategy of `grid-reduce!` and `reduce-vec`, and the ONLY
strategy for dependent multi-variable reductions (argmax, Welford, ...) -- requires
`num_groups <= local size`.  On a device whose resident capacity is larger than that, last-man
cannot fill the device.

Measured on an H100 NVL (2026-10-06), local size 256, so last-man is capped at 256 groups while the
device holds 1056 (8 per SM x 132), % of the 3702 GB/s measured read peak at 4 GiB:

| kernel | groups | % of peak |
|---|---|---|
| `reduce-vec` / `grid-reduce!` (last-man) | 256 (cap) | 42% |
| the same sum with `:strategy :atomic` | 1056 | 91% |
| sum + sum-of-squares, last-man | 256 | 33% |
| argmax (dependent, last-man only) | 256 | 52% |
| Welford (dependent, last-man only) | 256 | 40% |
| CUB `DeviceReduce` (for reference) | -- | 98-101% |

On an H100 80GB HBM3 (2026-10-04) the probes showed the same thing: at 256 groups even a hand
x4-unrolled stride loop stops at ~86%.  On BMG the cap does not bind (80 groups resident at local
256), but last-man there got WORSE with more groups (46% at 256 vs 58% at 80, where `:atomic` at 320
did not degrade) -- unexplained, and in scope here.

Every Crisp row in the NVIDIA contenders table is last-man.  This cap, not codegen, is the gap to
CUB.


Where the cap lives (as of 2026-10-06)
--------------------------------------

Two limits, and they are coupled:

1. **The final sweep is one partial per thread.**  The elected work-group loads `gv[lid]` for
   `lid < num_groups` and runs ONE `reduce-workgroup`.  Guarded by
   `(r-t-assert-0 (<= (get-num-groups 0) (get-local-linear-size)) ...)` at three lowering sites in
   `src/analysis/ops.lisp`:
   - `%grid-reduce-last-man-expand` (single variable; ~line 2211)
   - `%fused-grid-reduce-form` (independent multi-variable; ~line 1428)
   - `%fused-grid-reduce-dependent-form` (dependent multi-variable; ~line 1690)
2. **The implicit partials buffer has local-size slots.**  The implicit `:global-scratch-vec` is
   sized `:match-workgroup-size` (see any last-man metacrisp's `:implicit-params`).  Workgroup `g`
   writes `gv[g]`, so groups beyond the local size would write PAST THE END.  Removing limit 1
   without limit 2 is a memory-safety bug, not a speed-up.

The right size for the partials is `:match-num-workgroups` -- and **both hoists refuse it today**:
`%l0-scratch-symbolic-expr` (`src/hoist-l0/main.lisp`) and its CUDA twin
(`src/hoist-cuda/main.lisp` ~line 630) error with "`:match-num-workgroups` is not implemented yet",
because under `:strategy :strided` the group count is computed by the generated launcher at RUN TIME
(the occupancy query), after the point where scratch sizes are emitted.


Proposed change
---------------

### A. Strided final sweep (compiler, three sites)

In the elected work-group, each thread folds every `local_size`-th partial before the one
`reduce-workgroup`:

```lisp
(let ((acc identity))
  (loop over p = lid, lid + lsize, lid + 2*lsize, ... while p < num_groups
    (set! acc (fn acc (~ gv p))))
  (reduce-workgroup fn acc identity :local-scratch-vec sv))
```

- Order is fixed by `(num_groups, local_size)`, so last-man stays BIT-REPRODUCIBLE run to run --
  the property that makes it ~15x more accurate than `:atomic` (rel err 2e-8 vs 3e-7, BMG).
- Dependent forms fold with the combiner over all clause partials at once, as the fused sweep does now.
- The sweep reads `num_groups` partials once: negligible next to the stride fold.
- The `r-t-assert-0` on `local size` goes; a guard that the PARTIALS BUFFER is long enough replaces it
  (`(<= (get-num-groups 0) (length~ gv))`), which also covers a user-supplied `:global-scratch-vec`.
- Use a counted loop with a closed-form index (`p = lid + k*lsize`), not a loop-carried `p`: keeps
  the AD pass out of it (compare BUG 103/105).  The last-man VJP ignores the sweep (it broadcasts the
  output adjoint), so AD should be untouched -- verify, don't assume.
- 179's counter self-reset and `:launch-init` are unaffected (the reset already follows the sweep).

### B. `:match-num-workgroups` for implicit scratch (hoists + metacrisp)

- The implicit `:global-scratch-vec` of a last-man reduction gets `:size-expr :match-num-workgroups`.
- `crisp-hoist-l0` and `crisp-hoist-cuda`: allocate that buffer AFTER the dispatch emitter has
  computed the group count, from the same variable (`_gx` / `gridX`).  Today scratch is emitted
  before dispatch; this is the plumbing the existing error message names.
- `*implicit-scratch-size-expr-map*` / metacrisp: carry the new size-expr (already a keyword, so the
  metacrisp format needs no change).

### C. The harnesses that size scratch themselves

- **VERIFY-AUTODIFF runner** (`tests/verify-autodiff-runner.lisp`, `%vad-bind-implicit-param`):
  size a `:match-num-workgroups` buffer from the launch's group count.
- **Benchmark plan** (`scripts/crisp_bench/metacrisp.py`): the group count is computed INSIDE the
  fixture (occupancy mode), so the plan needs a symbolic count -- e.g. `buffer ... count=@groups` and
  slot values `u64 @groups*4` (byte size) / `u64 @groups` (extent, length) that the fixtures resolve
  after computing the grid.  The L0 fixture already computes the grid before allocating buffers;
  the CUDA fixture computes it after binding arguments (the occupancy query needs the dynamic
  shared size) and must be reordered.  Last-man's `cap=` in `groups_policy` then goes away.


Tests (to write when the endeavour starts)
------------------------------------------

- **unit**: the expansion's elected branch has the strided fold and no local-size assert, at all
  three sites; a last-man metacrisp's partials carry `:size-expr :match-num-workgroups`.
- **on metal, groups > local size** (this is what makes the cap bite on BMG too): a small local
  size, e.g. `(local-size :set-to (32))`, with `(global-size :set-to 8192)` = 256 groups > 32;
  `TEST-HOIST[L0]` + `HOIST-EXPECT` for single-variable `grid-reduce!`, an independent pair, a
  dependent argmax, and `reduce-vec`; CUDA twins (`TEST-HOIST[CUDA]`, next pod).
- **reproducibility**: two launches give bit-identical results (the stale-state machinery of 179
  already re-launches; the relaunch must ALSO agree bitwise on the same input).
- **--differentiate**: the existing last-man VERIFY-AUTODIFF specs (175/26, 176/08, 176/14, 178/10)
  unchanged; one new VAD spec with groups > local size.
- **negative**: a user-supplied `:global-scratch-vec` shorter than the group count -> the runtime
  guard fires (a spec that expects the message, not silent corruption).
- **benchmarks**: H100 last-man rows from ~42% toward the `:atomic` 91%; dependent workloads
  (argmax, Welford) likewise.  BMG: explain or remove the 46%-at-256-groups degradation.


Docs
----

- `ideal_001.md` and `tests/spec/175-reductions/reductions-excerpt.md`: the `grid-reduce-last-man!`
  "Cons" note ("requires that the total number of workgroups is less than or equal to the
  `local_work_size`") goes; the trade-off table's "Size of `num_workgroups`" becomes true of the
  implicit buffer; a user-supplied `:global-scratch-vec` must hold one element per work-group.
- `grid-reduce!` / `reduce-vec`: the "last-man carries its usual limit" sentence goes.


Decisions (made 2026-10-08 while Chris was away -- review these)
----------------------------------------------------------------

- **D1 -- strided sweep, not hierarchical last-man.**  The final sweep reads `num_groups` partials,
  a few thousand at most (H100 occupancy at local 256 is 1056; BMG at local 32 is ~640), so each
  thread of the elected group does `ceil(ng/ls)` loads (5 on H100).  A second election level would
  add a second counter, a second fence/ticket round and a second scratch buffer to save four loads.
  The sweep keeps ONE election and a fixed, launch-independent fold order.
- **D2 -- the accumulator starts at the IDENTITY and the loop folds `lid + k*ls` from k = 0.**  Counted
  `dotimes+` over `ceil(ng/ls)` with a closed-form index, as proposed.  REVISED during implementation:
  the first cut seeded from slot `lid` exactly as before (`(if (< lid ng) (~ gv lid) identity)`) and
  looped from k = 1, so that `ng <= ls` stayed bit-identical to pre-181.  BMG then dropped the seed in
  some kernels and not others -- correct IR at -O3, wrong answer on the device, moving with unrelated
  code shape.  Filed as **BUG 109** (same signature as BUG 030).  Folding the first partial in the loop
  like every other removes the divergent-if value IGC loses.  Cost of the change: `identity (+) x`
  for the first partial, which is exact for every identity (a -0.0 partial would sum to +0.0).
- **D3 -- the guard is `(<= num_groups (length~ gv))`, still an `r-t-assert-0`.**  NOTE what this
  means: `*runtime-checks-enabled*` defaults to NIL, so the old local-size assert NEVER fired in a
  normal build -- on an H100 at occupancy, pre-181 last-man silently summed the first 256 partials
  and wrote past the implicit buffer.  (That is why the benchmark plan caps last-man's grid.)  An
  always-on check was considered and rejected: on failure it can only `die`, which is just as silent
  as a wrong answer, and every other Crisp guard is opt-in.  The size-expr change (B) is what makes
  the default path safe; the guard protects a user-supplied buffer under `--runtime-checks`.
- **D4 -- no negative metal spec for the guard.**  It needs `--runtime-checks` at hoist time and the
  runner has no HOIST-FLAGS directive.  A unit test pins the guard's FORM at all three sites instead.
- **D5 -- `:match-num-workgroups` = the TOTAL group count** (X*Y*Z) in both hoists: last-man indexes by
  `workgroup-id 0` and is 1-D in practice, and the total is never smaller than the X count.
- **D6 -- hoist plumbing.**  CUDA: `kernelParams[]` holds ADDRESSES and `cuLaunchKernel` reads them at
  launch, so the buffer's variables are declared with the other args and allocated/filled just before
  the launch lambda (the same anchor the cluster fix-up uses).  L0: `zeKernelSetArgumentValue` copies
  the value, so the buffer's whole block (alloc, zero, six set-args) is DEFERRED and emitted after the
  group count.  Zeroed once (the 179 contract for global scratch): CUDA `cuMemsetD8`; L0
  `zeCommandListAppendMemoryFill` + barrier on the main command list, ahead of the launch.
- **D7 -- no HOIST-RELAUNCH directive (179's D3 was never built).**  Bit-reproducibility is by
  construction (fixed fold order given `(ng, ls)`); the relaunch is exercised by the VERIFY-AUTODIFF
  specs (every FD probe re-launches) and by the benchmark fixture's verify-twice.


Plan
----

- [x] API/doc review -- decided above (D1-D7) in Chris's absence
- [ ] TDD tests (above); bump `ci-stop.txt`
- [ ] A: strided sweep at the three sites (overlays)
- [ ] B: `:match-num-workgroups` in both hoists + metacrisp
- [ ] C: VAD runner + benchmark plan/fixtures
- [ ] on metal: BMG (small local size to make the cap bite) and NVIDIA (next pod)
- [ ] benchmarks: re-run H100 last-man rows and workloads; BMG degradation question
- [ ] fold into src/, regenerate reference / call graph / chapters, suites incl. --differentiate

Related: endeavour 179 (launch state; last-man counter self-reset), endeavour 180 (loop unroll --
the BMG half of the same competitive gap).
