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

- [ ] verification probes (below) -- decide the defaults
- [ ] decide: defaults as constants, per element size, or in the hardware profile
- [ ] API review with Chris; ideal_001.md (`declare` -> "Other declare directives",
      `loop-vector-stride`, `dotimes`, `reduce-vec`) and `reductions-excerpt.md`
- [ ] TDD tests (above); bump `ci-stop.txt`
- [ ] implement (overlays): declaration parsing, `!llvm.loop` emission, the default, `reduce-vec`
      passthrough, AD accept-and-ignore + the 178 pre-pass
- [ ] strength reduction at the IR level
- [ ] on-metal: BMG ladder; NVIDIA once the CUDA fixture exists (benchmark phase 5)
- [ ] fold into src/, regenerate reference / call graph / chapters, suites incl. --differentiate


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
