Endeavour 180 -- loop unrolling
===============================

Recorded 2026-10-03; not started.  Comes out of the reduction benchmarks
(`plan/benchmark-reductions.md`, phase 3, and `benchmarks/REPORT-reduction.md`).


Why
---

Measured on BMG (Arc B580), Docker, fp32 sum at 1 GiB, against a measured 454.5 GB/s read peak:

| kernel | GB/s | % of peak |
|---|---|---|
| `reduce-vec` / `grid-reduce!` after a `loop-vector-stride` fold | 260 | 57% |
| the same, unrolled x4 by hand, ONE accumulator, additions in the original order | 452 | 99.5% |
| the same, unrolled x4 into four accumulators | 452 | 99.5% |
| `loop-vector-stride` with the index walked by addition instead of `gid + k*gsize` | 277 | 61% |
| the original with 4x or 8x more work-groups | 257-260 | 57% |

- The SPIR-V Crisp ships (read back with `llvm-spirv -r`) has ONE global load per
  `loop-vector-stride` trip.  `default<O3>` does not unroll the loop for the SPIR-V target.
- More work-groups do not help: 160 x 256 already fills BMG's hardware threads.  What is missing
  is loads in flight PER THREAD.
- One accumulator in the original order is as fast as four, so **unrolling alone is enough, needs
  no reassociation, and leaves every result bit-identical**.

So `reduce-vec` -- the easy button -- delivers 57% of the memory bus, and every
`loop-vector-stride` over a large vector is likely in the same position.


Principles (agreed 2026-10-03)
------------------------------

1. **Fast by default.**  The easy button must be fast without the user knowing a knob exists.
2. **An explicit knob** for everyone else, the way `#pragma unroll` is in CUDA/HIP/SYCL: unrolling
   that helps a 4-byte streaming body can hurt a heavy one (code size, live values).
3. **Unrolling is codegen only.  It must not complicate autodiff.**  Mathematically it changes
   nothing.  The AD pass must see the same loop with or without it, and nothing in ANF / AD may
   have to understand it.
4. **Defaults are measured, not guessed.**  The probes below decide them, per element type and
   per platform, before anything is fixed.  Whether the defaults then belong in the hardware
   profile is decided AFTER the probes.  (The profile-probe applications under
   `benchmarks/profiles/` query the device; it is not clear an unroll value is something they can
   detect, rather than something only a sweep can find.)


Proposed API
------------

### 1. `(declare (unroll ...))` in a loop body

```lisp
(dotimes (k n)
  (declare (unroll 4))        ; unroll by 4, with a remainder loop when n is not a multiple
  ...)

(loop-vector-stride v (i)
  (declare (unroll 8))
  (set! acc (+ acc (~ v i))))

(dotimes (k 8)
  (declare (unroll t))        ; fully unroll -- the trip count must be a compile-time constant
  ...)

(loop-vector-stride v (i)
  (declare (unroll nil))      ; never unroll this loop, whatever the default
  ...)
```

- Placement: the first form(s) of the body, as `(declare (grid-level))` is in a `let`.
- Applies to: the `dotimes` family (`dotimes`, `dotimes+`, `dec-times`, the `do-times-by-*`
  variants) and `loop-vector-stride`.  Other stride forms (`tensor-stride`, `grid-stride`,
  `tile-stride`, `hardware-stride`) later, once these are measured.
- Values: a positive integer literal, `t` (full; constant trip count only) or `nil` (disable).
  Anything else is a compile error.
- Lowering: `!llvm.loop` metadata on the loop's latch branch -- `llvm.loop.unroll.count N`,
  `llvm.loop.unroll.full`, `llvm.loop.unroll.disable`.  LLVM does the unrolling and the remainder
  loop; Crisp emits a hint, not code.

### 2. A default for `loop-vector-stride`

With no `declare`, `loop-vector-stride` gets the default unroll -- the value is whatever the
probes say (it may depend on element size: the BMG result is 4 x 4 bytes = 16 bytes in flight
per thread, and fp64 may want x2 for the same bytes).  `dotimes` gets NO default: a counted loop
is not necessarily a stream.

### 3. `:unroll` on `reduce-vec`

```lisp
(reduce-vec #'+ v 0.0 out :strategy :atomic :unroll 2)
```

Passed through to its `loop-vector-stride`, as its other keys are passed to `grid-reduce!`.
`grid-reduce!` itself takes no `:unroll` -- it has no loop.


Autodiff
--------

- ANF and the AD passes must accept an `(unroll ...)` declaration in a loop body and otherwise
  ignore it.  The forward loop keeps its metadata.
- Loops the AD pass GENERATES (the backward of a sum reduction is itself a stride loop, broadcasting
  the adjoint) are plain loops; whether they inherit the source loop's unroll is a performance
  question, decided by measurement -- not something the AD pass has to reason about.
- `reduce-vec`'s `:unroll` must be threaded through the AD stride pre-pass that expands
  `REDUCE-VEC` itself (endeavour 178), or the key is silently dropped under `--differentiate`.


The 64-bit multiply (strength reduction)
----------------------------------------

`loop-vector-stride` computes `i = gid + k*gsize` each trip; walking `i += gsize` was worth ~6% on
its own.  **Do not change the expansion to get it.**  The closed form keeps the index a pure
function of the trip counter -- no loop-carried variable -- which is what keeps the AD pass simple
(compare the loop-carried `set!` work in BUG 103/105).  LLVM's induction-variable passes should
strength-reduce it; find out why they do not for this loop on the SPIR-V target, and fix it at the
IR level.


Tests (to write when the endeavour starts)
------------------------------------------

- **unit**: the declaration parses; the unoptimised IR carries `!llvm.loop` with the right
  `unroll.*` node for each form; `loop-vector-stride`'s default appears with no declaration and is
  replaced by an explicit one; `reduce-vec :unroll` reaches its loop.
- **module**: the SHIPPED SPIR-V (via `llvm-spirv -r`) has N loads per trip of a streaming
  `loop-vector-stride`, not 1.  (A spec validator gets a module path -- see the
  spec-validator-gets-a-module-path note.)
- **negative** (`errors/`): `(unroll 0)`, `(unroll -1)`, `(unroll x)` with x not a literal,
  `(unroll t)` on a runtime trip count, `unroll` outside a loop body, two `unroll`s on one loop.
- **--differentiate**: every new spec differentiates; VERIFY-AUTODIFF on a `reduce-vec :unroll`
  kernel and a `loop-vector-stride` + `(declare (unroll 4))` kernel gives the same gradient as
  without.
- **on metal**: the reduction ladder -- steps 4 and 5 should reach step 3b (~99% of peak on BMG);
  results bit-identical to the un-unrolled kernel on integer-valued data.


Plan
----

- [x] verification probes (below) -- decide the defaults
- [x] decide: defaults as constants, per element size, or in the hardware profile -- D1 below
- [ ] API review with Chris (the API was implemented as proposed; see "For review")
- [x] ideal_001.md (`declare` -> "Other declare directives" gains `unroll`; `loop-vector-stride`,
      `dotimes`, `reduce-vec`) and `reductions-excerpt.md`
- [x] TDD tests (above); bump `ci-stop.txt`
- [x] implement (overlays): declaration parsing, `!llvm.loop` emission, the default, `reduce-vec`
      passthrough, AD accept-and-ignore + the 178 pre-pass
- [ ] strength reduction at the IR level -- NOT DONE, deliberately (probe 3: worth <= 1.5%)
- [x] on-metal: BMG ladder (below) -- [ ] NVIDIA (this evening)
- [x] update reduction benchmarks with new numbers (BMG canonical; report not regenerated yet)
- [ ] fold into src/, regenerate reference / call graph / chapters, suites incl. --differentiate


Implementation (2026-10-07, overlays)
-------------------------------------

Done in one day while Chris was at the office; every decision he did not make himself is in
"Decisions" below, and the ones worth a second look are under "For review".

**How it works.**  `analyze-dotimes-expression` and `analyze-loop-variant-expression` strip the leading
`(declare ...)` forms off the body (`%split-loop-body-declarations`), run the pre-180 analyzer on the
rest, and record the request on the node's new `unroll` slot.  The codegen attaches `!llvm.loop` to
the latch (`%attach-loop-unroll-metadata`): the dotimes back-edge `br label %dt_check`, or the
loop-variant bottom test.  The loop ID is LLVM's distinct self-referential node, built from LLVM-C with
a temporary placeholder (two new bindings: `LLVMTemporaryMDNode`, `LLVMMetadataReplaceAllUsesWith`).

`loop-vector-stride` moves its body's leading declarations onto the dotimes it expands to.  With no
`unroll`, it writes `(declare (%unroll-default VEC))` instead; the dotimes analyzer sizes that from
VEC's element type to `(:stream BYTES)`, and the codegen turns it into a factor for the current
target.  `reduce-vec :unroll V` becomes `(declare (unroll V))` at the head of its loop-vector-stride
body and never reaches `grid-reduce!`.

**AD needed nothing.**  ANF passes a `declare` through untouched and the backward walk already skips
`DECLARE` forms, so the forward kernel keeps its metadata and the gradient kernel's loops are plain.
Because the default is a declaration written by the expansion, it survives the AD stride pre-pass
(endeavour 178) like any user declaration.

**Files touched.**  Overlays: `crisp-compiler-overlay.lisp` (everything), `crisp-llvm-bindings-overlay.lisp`
(2 bindings), `spec-runner-overlay.lisp` (5 validator delegators).  ONE `src/` patch, because a struct
cannot be overlaid: `src/semantic.lisp`, slot `(unroll nil)` on `semantic-dotimes` (inherited by
`semantic-loop-variant`).

**Tests.**  14 specs + 11 `errors/` + `loop-unroll.unit.lisp` (13 tests, 45 assertions).  On BMG metal:
01-07 and 09 run on the GPU; 10 and 11 pass VERIFY-AUTODIFF (analytical = numerical: 2.0 and 1.0) at
1100 elements over 128 threads, so the x4 body really runs.  The load-count validators read the
SHIPPED SPIR-V: float stream x4 = 5 loads (4 + remainder), double x2 = 3, explicit x8 = 9,
`(unroll nil)` = 1.  Spec 14 is BUG 107's regression (110 annotated loops).  Default `reduce-vec` (178/01) went from 8 float loads to 12: its stream loop is
now x4 + remainder.  NVIDIA, without a GPU: spec 13's hoisted `.cu` compiles and links with nvcc in
`nvidia/cuda:12.4.1-devel`, and every PTX variant assembles with `ptxas -arch=sm_90` (D2 below).

**Suites (with the BUG 107 fix, BMG box).**  Unit 341/341; E2E 1400/1400 (incl. the 180 unit file);
negative 322/322.  `--differentiate`, targeted at the stride and reduction directories (093, 105, 107,
175-178) and 180 itself: all green, the reduction VERIFY-AUTODIFF specs included.  The full
`--debug` / `--single-pass` / `--differentiate` phases are left to CI.  NOT done: the "bit-identical on
integer-valued data" check (the benchmark fixture verifies the sum, not bit-identity).

**On metal, BMG (2026-10-07)** -- the reduction ladder with NO source change, 180's default only.
Docker, `fast`, 80 groups (the driver's default), every point verified; % of the 454.5 GB/s measured
peak.  Before 180 steps 3, 4 and 5 sat at ~57%.  JSON in `benchmarks/results/scratch/` (scratch on
purpose: the canonical report is Chris's call); log `put_temp_files_here/e180/bench.log`.

| step | 64 MiB | 1 GiB | 3 GiB |
|---|---|---|---|
| 3 grid-stride (`loop-vector-stride`) | 96.1 | 99.1 | 99.1 |
| 3b hand-unrolled x4 (the target) | 96.6 | 99.2 | 98.9 |
| 4 `grid-reduce!` last-man | 91.6 | 98.7 | 98.9 |
| 4 `grid-reduce!` :atomic | 96.4 | 99.2 | 99.1 |
| 5 `reduce-vec` | 91.6 | 98.8 | 98.9 |

The easy button is now as fast as the hand-unrolled kernel: the goal of the endeavour, on BMG.

CANONICAL rerun, same day (`bench-intel.sh canonical 50 fast`, the whole Crisp reduction suite, all
six sizes, every point verified; JSON in `benchmarks/results/`, superseding the 10-03/10-05 runs).  At
1 GiB every kernel with a `loop-vector-stride` fold is now 98.2-99.2%: steps 3/4/5, the workloads
(argmax 98.5, sum+sumsq 98.7, Welford 98.7) and the rollup's atomic / last-man forms.  The CAS
forms stay slow (warp_cas 32%, wg_cas 69%) -- the separate CAS-lowering issue, not 180.

**BUG 107, found on the way** (plan/bugs.md).  `inject-spir-kernel-metadata` numbered the OpenCL
kernel-arg metadata from a hard-coded `!100`.  Any module already past `!99` got a duplicate id and
`llvm-as` refused it -- that is the probe-2 side finding (`--debug --ir-target=spv` fails: debug info
numbers past 100), and 180 made it reachable WITHOUT `--debug`: one loop ID per annotated loop.
Reproduced with a 110-loop kernel before the fix.  Fixed: the base is now one above the module's
highest id.


Decisions (2026-10-07)
----------------------

- **D1 -- the default is a per-target CONSTANT, not a hardware-profile field.**
  `*stream-unroll-bytes-in-flight*` = `((:spirv . 16) (:ptx . nil))`.  The profile-probe
  applications query the device; the 16-byte knee came out of a sweep, which no query reports.  Today
  "SPIR-V" means Intel, so per-backend is per-vendor.  Revisit when a second SPIR-V part shows a
  different knee -- that is when it moves into the profile.
- **D2 -- no default on PTX.**  Probe 4: LLVM's NVPTX target already runtime-unrolls the stream x4 and
  ptxas unrolls again (16 loads/trip in SASS).  Worse, a hint would HURT: after LLVM unrolls a loop
  it marks it `llvm.loop.unroll.disable`, which NVPTX prints as `.pragma "nounroll"`, which stops
  ptxas.  An explicit request is still honoured on PTX -- exactly like CUDA's `#pragma unroll N`,
  which nvcc lowers the same way (spec 12 checks `(unroll nil)` reaches the PTX as the pragma).
  CHECKED OFFLINE (ptxas -arch=sm_90 + cuobjdump in the CUDA image, no GPU;
  `put_temp_files_here/e180/ptx/`): `reduce-vec :strategy :atomic` with NO hint has **33 LDG** in
  SASS -- ptxas unrolls far past LLVM's x4 -- while `:unroll 4` has **5** (4 + remainder): the hint
  leaves the main loop `.pragma "nounroll"` (2 pragmas in the PTX vs 1) and ptxas stops.  So on PTX
  an explicit factor is FINAL.  Whether 33 beats 5 on an H100 is tonight's measurement (probe 4's hand
  kernels: x4 86.5%, x8 85.5% -- maybe a wash).
- **D3 -- the default factor is capped at x8.**  16 bytes / 1-byte elements would be x16, which no
  probe measured.  A factor of 1 (an element of 16+ bytes) emits nothing.
- **D4 -- the factor is chosen at CODEGEN** from `*target-backend*`; analysis records only the
  element size.  `--ir-target=llvmir` therefore gets no default (it has no target).  A vector of
  structs gets no default (no scalar size); that is logged at debug, never an error.
- **D5 -- a loop body accepts ONE declaration: `unroll`.**  Any other declaration at the head of a
  loop body is an error naming it (`errors/09`).  Before 180 a `declare` in a dotimes body was
  "Unsupported form 'DECLARE'", and in a loop-vector-stride body it fell into the inner `let`, which
  ignored it.  `(unroll 1)` is accepted (it means "do not unroll", like CUDA's `unroll 1`).
- **D6 -- misplaced `unroll` gets a named error everywhere.**  In a `let` (`%check-context-declarations`)
  and as a bare form (a new `DECLARE` expression analyzer, registered by wrapping
  `register-control-analyzers`; any non-unroll `declare` still gets the old unsupported-form error,
  same message, same location).  NOTE: a `let` still silently drops OTHER unknown declarations --
  out of scope, but see "For review".
- **D7 -- loops the AD pass generates are plain.**  Verified: the `_grad` kernel's loops carry no
  `!llvm.loop`.  Whether the backward broadcast loop should be unrolled is a measurement question for
  later, as the principles said.
- **D8 -- strength reduction not done.**  Probe 3: x4 already reaches 98.4%; the multiply costs at
  most ~1.5%.  Left as an open item.
- **D9 -- the SPIR-V load-count validators count only outside `*_grad` functions.**  Under the runner's
  `--differentiate` pass a validator is handed the `_grad` module, which holds the forward kernel too.


For review (this evening)
-------------------------

1. **The `src/semantic.lisp` slot.**  The only edit outside the overlays; it has to be in src/ (a
   struct).  Please eyeball it before anything else.
2. **D1 (constant, not profile) and D2 (no PTX default)** are the two judgment calls.  D2 is the one
   to confirm on the H100 tonight: `reduce-vec` on PTX should be unchanged by 180, and `:unroll 4`
   should NOT be slower than no hint (if it is, that's the `.pragma "nounroll"` effect, as predicted).
3. **`let` silently drops unknown declarations** (e.g. a typo'd `(declare (gird-level))`).  180 only
   closed this for `unroll`.  A general fix would refuse every unknown spec -- worth a bug entry?
4. **`%unroll-default` is an internal declaration** that `loop-vector-stride` writes.  A user could
   write it too (it would just ask for the default).  Fine, or rename it to something unspellable?


Verification probes (before the endeavour starts)
-------------------------------------------------

1. **Unroll factor x element type x size, BMG**: hand variants at x1 / x2 / x4 / x8, fp32 and fp64,
   one accumulator, 64 MiB - 3 GiB.  Tests the "bytes in flight" idea.
2. **Does the hint work?**  Take Crisp's IR for the stride loop, add `llvm.loop.unroll.count 4`,
   run our exact `default<O3>` pipeline, read the loads per trip -- and run it on metal.  A runtime
   trip count needs runtime unrolling; check the hint enables it here rather than assuming.
3. **Strength reduction**: why the multiply survives `default<O3>` (read the optimised IR).
4. **NVIDIA (PTX)**: the same sweep on an NVIDIA part.  Needs the CUDA twin of the reduction
   fixture (benchmark phase 5); latency is hidden differently there, so the default may differ.

Results go below as they come in.

### Probe results

All BMG (Arc B580), Docker, `fast`, 160 work-groups x 256, every point verified.  Kernels in
`benchmarks/reduction/_probe_unroll/` (probe 1) and `put_temp_files_here/phase3/` (probes 2-3).

**Probe 1 -- the unit is BYTES IN FLIGHT per thread, not the unroll factor** (2026-10-03).
One accumulator, original order; % of the 454.5 GB/s measured peak at 1 GiB (3 GiB in brackets):

| bytes in flight / thread | fp32 | fp64 |
|---|---|---|
| 4 B | x1: 60.6% (60.8) | -- |
| 8 B | x2: 93.5% (93.3) | x1: 95.2% (95.0) |
| 16 B | x4: 98.5% (98.9) | x2: 98.8% (99.6) |
| 32 B | x8: 98.8% (98.9) | x4: 99.2% (99.9) |
| 64 B | -- | x8: 99.5% (99.7) |

fp32 x2 and fp64 x1 (8 bytes each) land together; so do fp32 x4 and fp64 x2 (16 bytes).  On BMG
the knee is at **16 bytes per thread**; more never hurts and gains < 1%.  A BMG default would be
`unroll = max(1, 16 / element-bytes)`: x4 fp32, x2 fp64, x8 for 16-bit types.

**Probe 2 -- the hint works, through Crisp's own pipeline, on the real `reduce-vec` kernel.**
`step5_reduce_vec/sum.crisp` compiled in-process (bmg, fast/ftz), its pre-opt IR kept, one
`!llvm.loop` node with `llvm.loop.unroll.count N` added to the `dt_check` back-edge, then
Crisp's `%run-passes-in-process "default<O3>"`, `llvm-as`, `llvm-spirv`, and the fixture:

| hint | global loads in the kernel after O3 | 1 GiB | 3 GiB |
|---|---|---|---|
| none | 2 (stride loop + last-man partials) | 260.6 GB/s, 57.4% | 57.3% |
| x2 | 4 | 414.6, 91.2% | 90.9% |
| **x4** | 6 (4 + remainder + partials) | **447.3, 98.4%** | **99.0%** |
| x8 | 10 | 448.0, 98.6% | 98.8% |

So `default<O3>` DOES runtime-unroll a loop carrying `llvm.loop.unroll.count`, with a remainder
loop, and the `none` control reproduces the ladder's 57.4% (the hand pipeline matches Crisp's).
**The whole fix for `reduce-vec` is one metadata node.**

**Probe 3 -- strength reduction is not needed.**  The optimised stride loop keeps
`mul i64 %k, %gsize` every trip; adding `function(loop(loop-reduce))` after `default<O3>` does not
remove it (LSR's cost model without a target machine leaves it; on PTX, `llc` runs LSR itself).
With x4 at 98.4% the multiply costs at most ~1.5%: demote to "nice to have".

**Side finding (not this endeavour):** `crisp-compile --debug --ir-target=spv` FAILS on this kernel
-- `llvm-as` rejects the debug-info IR in `.temp.ll` (and the in-process opt fails on it too).
Worth a bug entry.

**Probe 4 -- NVIDIA H100 (2026-10-04).**  The PTX path already unrolls `loop-vector-stride` (LLVM's
NVPTX target runtime-unrolls x4 and `llc` strength-reduces the index; ptxas unrolls again, to 16
loads per trip in SASS).  So the 57% problem is SPIR-V-only.  On H100 grid size dominates: at 1
block/SM every variant plateaus near 65%.  Hand probes at 256 work-groups (last-man's cap), % of
the 3103 GB/s measured peak at 4 GiB:

| | x1 | x2 | x4 | x8 |
|---|---|---|---|---|
| fp32 | 43.2 | 80.3 | 86.5 | 85.5 |
| fp64 | 56.3 | 90.2 | 90.3 | 90.5 |

Unlike BMG, bytes in flight does not line up exactly (fp32 x2 and fp64 x1 move 8 bytes each: 80% vs
56%), so the NVIDIA default may be "at least x2-x4 independent loads" rather than a byte budget.
Open: why last-man `reduce-vec` (already unrolled by LLVM) reaches only 50.8% at the same 256
groups where the hand x4 probe reaches 86.5% -- compare their SASS.

**Implication for the defaults**: per-vendor.  BMG wants an unroll (16 bytes in flight); NVIDIA
wants occupancy first (dispatch policy, and last-man's groups <= local-size cap) and is already
unrolled by the backend.
