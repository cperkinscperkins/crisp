Endeavour 165 — 64-bit (double) MMA
===================================

In this endeavor we are going to make sure that 64-bit / DOUBLE is working with MMA, and we are
going to add it to the benchmarking.

I believe this will be NVidia Only, as the only Intel hardware we have access to is BMG. If you
know of a way to pursue this on BMG (maybe just the most basic matrix multiplication walk?, let
me know).

Unlike the other MMA, which is focused on "fast" math, this is ieee.
- `--math-precision=ieee`
- [ ] 64 bit (NVidia) and the `ftz` denormal request — see "Precision and denormals" below; the
      original plan said ERROR, and the decision has since been revised to *fix the lowering and
      warn*.  The reasoning is recorded so the change is auditable.


Findings before writing any code
================================

Everything in this section was established on the dev box, with no GPU and no rental, and each
item names how it was checked.  They are recorded because three of them constrain the plan.

### 1. LLVM has exactly ONE fp64 tensor-core intrinsic, and the failure mode is SILENT

Probed directly with our own `bin/llc.exe` (LLVM 21.1.5), `-march=nvptx64 -mcpu=sm_90`:

| declared intrinsic | result |
|---|---|
| `llvm.nvvm.mma.m8n8k4.row.col.f64` | emits `mma.sync.aligned.m8n8k4.row.col.f64.f64.f64.f64` |
| `llvm.nvvm.mma.m16n8k4.row.col.f64` (correct 7-arg signature) | becomes an `.extern .func` CALL |
| `m16n8k8.f64`, `m16n8k16.f64` | same — no instruction |

The sm_90 fp64 MMA shapes exist in the PTX ISA but are not NVVM intrinsics in our LLVM.  A
declaration assembles cleanly and `llc` emits an external call with no diagnostic, so a wrong
shape choice would surface as a link error or as garbage, far from its cause.  **The 64-bit
ladder is pinned to m8n8k4, and anything else must be a compile-time refusal in Crisp.**

### 1b. The exact fp64 fragment LANE LAYOUT, from a primary machine-readable source

`third_party/cutlass/include/cute/atom/mma_traits_sm80.hpp` defines
`MMA_Traits<SM80_8x8x4_F64F64F64F64_TN>` with explicit CuTe thread-value layouts.  Decoded
(CuTe linearises the natural index column-major, `index = m + n*M`; thread decomposes as
`t0 = lane % 4`, `t1 = lane / 4`):

```
ALayout = SM80_8x4     = Layout<Shape<Shape<_4,_8>,_1>, Stride<Stride<_8,_1>,_0>>
BLayout = SM80_8x4     (same)
CLayout = SM80_8x8_Row = Layout<Shape<Shape<_4,_8>,_2>, Stride<Stride<_16,_1>,_8>>
```

| fragment | shape | per lane | mapping |
|---|---|---|---|
| A | 8x4 (M,K) | 1 double | `m = lane/4`, `k = lane%4` |
| B | 4x8 (K,N) | 1 double | `k = lane%4`, `n = lane/4` |
| C/D | 8x8 (M,N) | 2 doubles | `m = lane/4`, `n = 2*(lane%4) + v`, v in {0,1} |

This is the SAME `groupID = lane/4` family as the tf32 path already documented at
src/mma.lisp:546, which is corroborating rather than surprising.  It matches the element counts
CUTLASS's arch layer declares independently (`FragmentA/B = Array<double,1>`,
`FragmentC = Array<double,2>`), so two parts of CUTLASS agree with each other.

**Why this mattered enough to go and find.**  A fragment lane layout is the textbook
wrong-but-self-consistent failure: guess it, and the kernel compiles, emits the right
instruction, passes every mechanical check, and computes garbage that only on-metal
verification catches.  Endeavour 159 lost a pod session to exactly that class of thing.  Taking
it from CuTe rather than from memory removes the guess before it can cost a rental.

### 2. CUTLASS independently agrees, and hands us the fragment layout

`third_party/cutlass` at the pinned `dc45f97` defines exactly one fp64 tensor-op MMA
(`include/cutlass/arch/mma_sm80.h`):

```
Mma<gemm::GemmShape<8,8,4>, 32, double, RowMajor, double, ColumnMajor, double, RowMajor, ...>
  FragmentA = Array<double,1>;   FragmentB = Array<double,1>;   FragmentC = Array<double,2>;
```

Two independent sources, same answer.  This also gives the per-lane layout the Crisp fragment
records will need — 1 A element per lane, 1 B, 2 accumulator — and confirms row-major A /
column-major B is what the instruction natively wants.

### 3. The h100 builtin profile currently resolves `double` to an UNEMITTABLE shape

`register-builtin-hardware-profiles` (src/mma.lisp:319) declares:

```lisp
:mma-shapes ((16 8 8) (16 8 4) (16 8 16))
```

`%mma-shape-for-elem` (src/mma.lisp:3147) has no typed entry to match, so it falls to the width
rule: "K x element-bits is a constant fragment footprint", calibrated here at 8 x 32 = 256.  For
`double` (64 bits) that gives K = 4, which selects **(16 8 4)** — exactly the shape finding 1
says LLVM cannot lower.  The rule is not wrong; it is simply not the constraint that binds for
fp64.  Wants a typed entry `(double (8 8 4))` plus the refusal from finding 1.

### 4. Chapter 7 has no 64-bit rung at all

wgmma covers fp16/bf16/tf32/fp8/int8.  There is no `wgmma.mma_async...f64` in any form, so the
64-bit ladder is chapters 0-6 and chapter 7 is **absent by hardware**.  That should be stated in
the report as such, not left as an empty cell — an empty cell reads as "not measured yet".

Chapters 1-6 sit on `mma.sync` plus cp.async/TMA, which are dtype-agnostic byte movers, so they
port.  TMA needs `CU_TENSOR_MAP_DATA_TYPE_FLOAT64` and box widths recomputed in bytes.

### 5. Expectation to record BEFORE measuring

Vendor figures for H100 put fp64 tensor core at ~2x fp64 vector (67 vs 34 TFLOPS), against the
~8-16x that 16-bit tensor cores enjoy.  Meanwhile fp64 doubles the bytes per flop, halving
arithmetic intensity.  Prediction, written down in advance the way endeavour 159 did it:

> **The 64-bit ladder compresses at the bottom and stretches at the top.**  Chapter 1
> (hand-rolled MMA over naive) is worth ~2x at best, while the data-movement chapters (3/4/5)
> matter MORE relatively than they do at 16-bit, because DGEMM goes bandwidth-bound sooner.

MEASURED 2026-09-07 — see "Section 2 measured" below.  The shape of the prediction held and the
magnitude did not: the fp64 tensor core is worth **1.20-1.53x**, not ~2x.  The vendor's 2x is a
peak-rate ratio and does not survive contact with a real GEMM.

Also: m8n8k4 is a quarter of the tf32 tile per instruction, so issue rate dominates and the 64x64
register geometry that won for tf32 is unlikely to transfer.  Budget for a geometry sweep, as
156/162 needed.

**This is an H100/A100-only measurement.**  Consumer Blackwell runs fp64 at 1/64 rate; a number
from the RTX would be actively misleading rather than merely uninteresting.


The oracle: why A = B = 1 is not good enough here
=================================================

Every other matmul benchmark in this tree fills A and B with 1.0 and checks `C == K`.  For this
endeavour that oracle is worthless: 1.0 is exact in fp64, fp32, tf32 AND fp16, so a kernel that
silently computed the whole GEMM in single precision passes with `max_abs_err` exactly 0.  The
premise of 165 is IEEE double; an oracle that cannot tell double from float is a green light
with no information in it.

`benchmarks/matmul/sec2_top_f64/f64_oracle.h` fills A and B with **v = 1 + 2^-25** instead:

* in fp32, 2^-25 is below half an ulp at 1.0, so v rounds to exactly 1.0 — a single-precision
  path therefore computes exactly K.  tf32 and fp16 round it away even more decisively.
* in fp64, v is exact and C = K*v^2 = K*(1 + 2^-24 + 2^-50), whose mantissa spans 51 bits and so
  is exactly representable.  No reference GEMM is needed, on host or device.

Verified on the dev box by compiling the header with g++ and running both paths for real:

```
K        path           max_rel_err    verdict   diagnosis
16384    fp64           6.661e-16      ACCEPT    fp64
16384    fp32-simulated 5.960e-08      REJECT    computed at SINGLE precision (fp32/tf32 signature)
```

Tolerance is 1e-10 — five orders above honest fp64 rounding, three below the fp32 signature.  The
header also DIAGNOSES rather than merely failing: it recognises the fp32 signature and says so,
because "incorrect" sends you looking for a harness bug while "computed at single precision"
names what actually happened.

The oracle is layout-insensitive by construction (every element of A and B is the same value), so
the contenders may disagree about row- vs column-major without the oracle measuring the layout
instead of the arithmetic.

**A second, mechanical gate belongs alongside it**, needing no GPU: assert the emitted PTX
contains `mma.sync.aligned.m8n8k4...f64` and no f32 MMA.  That catches the silent-fallback and
silent-extern-call cases at compile time.


Section 2 measured — H100 NVL, 2026-09-07
=========================================

Hardware: NVIDIA H100 NVL, driver 580.126.09, CUDA 12.4, CUTLASS `59e3a33` (note: NOT the dev-box
pin `dc45f97` — `setup-third-party.sh` fetches fresh, so peer numbers must be quoted against
`59e3a33`).  Sizes 1024/2048/4096/8192, warmup 20, 100 iterations, median.  **Every contender at
every size returned `correct=true` with `precision_diagnosis: fp64`** — nothing silently ran in
single precision, which is the one thing the new oracle exists to catch.

GFLOPS, best config per family:

| N | cuBLAS 64F | cuBLAS 64F_PEDANTIC | CUTLASS DMMA | CUTLASS SIMT | DMMA/SIMT |
|---|---:|---:|---:|---:|---:|
| 1024 | 41,812 | 38,971 | 25,003 | 20,796 | **1.20x** |
| 2048 | 54,180 | 40,601 | 27,570 | 22,738 | **1.21x** |
| 4096 | 52,746 | 40,689 | 28,198 | 22,356 | **1.26x** |
| 8192 | 38,890 | 35,374 | 28,258 | 18,496 | **1.53x** |

### A method correction, recorded because the first answer was wrong

The plan was to read the tensor-core ratio off cuBLAS: `CUBLAS_COMPUTE_64F` free to use DMMA,
`CUBLAS_COMPUTE_64F_PEDANTIC` not.  **That reasoning was imported from fp32, where PEDANTIC's job
IS to forbid tf32, and it does not transfer.**  DMMA is bit-identical IEEE double — it is not an
approximation of anything — so a mode defined as "prescribed precision and standardized
arithmetic" has no numerical reason to refuse it.  The data agreed with the doubt: PEDANTIC held
40.6 TFLOPS at N=2048, well above what a pure vector-fp64 path should reach.

The ratio is therefore measured in CUTLASS instead, where the lowering is CHOSEN rather than
inferred: `OpClassTensorOp` + `GemmShape<8,8,4>` against `OpClassSimt` + `GemmShape<1,1,1>`, one
template parameter apart in the same file, same oracle, same timing loop, same data.  The cuBLAS
pair is still reported, labelled as not a tensor-core ratio.

### What the numbers mean for the ladder

1. **The fp64 tensor core is worth ~1.2x at practical sizes**, not the ~2x the vendor peak-rate
   figures imply.  So chapter 1 — hand-rolled MMA over naive — has a small ceiling, and the
   endeavour should not be organised around it.
2. **The larger gap is not about tensor cores at all.**  cuBLAS 64F (54.2 TFLOPS at 2048) is
   ~1.9x the best CUTLASS DMMA config (28.3).  Both are DMMA; that gap is scheduling and data
   movement.  **The 64-bit headroom lives almost entirely in chapters 2-6.**
3. Revised thesis, and it is the opposite of the 16-bit story: **for fp64 the MMA instruction is
   a minor win and the pipeline is the whole game.**
4. At N=8192 the ratio widens to 1.53x because the SIMT arm DEGRADES (22.4 -> 18.5) while DMMA
   holds (28.2 -> 28.3), not because DMMA improves.  Worth understanding before leaning on it.

### Caveats on these numbers

- The peer is LIGHTLY SWEPT: four DMMA geometries (all K=16) and three SIMT.  cuBLAS being 1.9x
  ahead is therefore an UPPER BOUND on available scheduling headroom, not a precise figure —
  some of it may be peer under-tuning.  Endeavour 159's lesson applies: an under-reporting peer
  flatters everyone measured against it.
- The DMMA/SIMT ratio is more trustworthy than the absolute numbers, because both arms are tuned
  to a comparable (low) degree and differ in one template parameter.
- `32x32x16w32x32s4` does not build: CUTLASS static-asserts "This tile iterator requires at least
  two warps."  Recorded rather than hidden — it bounds the small end of the tiling space.


Phase 0 measured — what the compiler does with f64 MMA TODAY
============================================================

Run on the dev box, compile-only, no GPU.  Probes in `put_temp_files_here/165/probe/`.

**The prediction was wrong on both counts.**  It said an f64 MMA would fall into the tf32 branch
and silently emit f32.  It does not: `double` register tiles already work and emit genuine f64,
and the MMA path REFUSES rather than degrading.  What the probes did find is a different and
pre-existing defect that has nothing to do with fp64 — but which fp64 walks straight into.

| probe | result today |
|---|---|
| `double` register tile, fragment-aligned (16x8), fill + store | **works** — 49-line body, 4 `st.global`, 13 f64 refs |
| `double` tile + `mma-accumulate-via-tile (16 8 8)` | **refuses**: "Type mismatch! Expected FLOAT but inferred DOUBLE" |
| `double` tile (8x8) + MMA (8 8 4), profile supplying the shape | compiles "successfully", emits an **EMPTY KERNEL** (`ret;`) |
| **`float`** tile (8x8), fill + store, no MMA at all | **also an empty kernel** |

### The silent-empty-kernel defect is about SHAPE, not element type

The last two rows are the discriminating pair.  An f32 8x8 tile produces exactly the same `ret;`
as the f64 one, so this is not an fp64 gap.

`analyze-make-register-tile` (src/mma.lisp:1104) computes

```lisp
(nfrags (* (floor m 16) (floor n 8)))
```

so a tile with M < 16 or N < 8 yields **zero fragments**.  Nothing to fill, nothing to store,
nothing to multiply — and the kernel legitimately optimises down to `ret;`.
`%ensure-register-tile-type` (src/mma.lisp:1001) has a guard for precisely this case:

```lisp
(unless (and (zerop (mod m 16)) (zerop (mod n 8)))
  (error "make-register-tile: dims (~a ~a) must be multiples of the 16x8 accumulator fragment."))
```

but it does not fire, because a let-bound tile does not take that path — as the comment at
src/mma.lisp:1103 says, "a let binding is EXPLODED, and %explode-register-tiles does the
distribution".  The explode path never re-checks.  So the guard exists and is bypassed by the
route every real kernel uses.

**This deserves a BUG number in plan/bugs.md.**  It is pre-existing, type-independent, and
silently turns a kernel into a no-op — the same class as BUG 036 (the C-tile reset), which was
also "quietly computes nothing/wrong for a shape nobody had tried".

### Why it lands on this endeavour

fp64's ONLY tensor-core shape is m8n8k4, so its natural accumulator is **8x8** — below the
hardcoded 16x8 fragment in both dimensions.  Every fp64 MMA kernel we write will request an 8-row
tile, and today every one of them would compile clean and do nothing.

So the register tile is not merely missing an f64 branch; it is **structurally 16x8-f32**:
`%ensure-register-tile-type` takes `(m n)` and no element type at all, and hardcodes
`register-fragment-acc-f32-16x8` as the fragment type.  Teaching it fp64 means teaching it that
the fragment geometry is a property of the element type — which is the same lesson endeavour 155
learned for the Intel GRF width, and 159 for the 16-bit K.

### Revised compiler-work list, in dependency order

1. [x] **DONE — the silent zero-fragment case is now a refusal.**  Filed as **BUG 058**.  One
   shared predicate `%register-tile-dims-must-divide`, called from BOTH
   `%ensure-register-tile-type` (which already had the guard, dead) and
   `%register-tile-fit-check` (which the explode path already calls once per tile binding), so
   the two cannot drift apart again.  It went into the fit-check rather than
   `%explode-register-tiles` because that function is 124 lines and transcribing it into an
   overlay is its own class of risk, while the fit-check already receives exactly `(m n
   location)`.  NVIDIA-only, deliberately — see BUG 058 for why SPIR-V needs the element type
   threaded through first, and note that half is STILL OPEN.
   Specs: `errors/01-tile-too-few-rows.crisp`, `errors/02-tile-too-few-cols.crisp`.
2. [x] **DONE — accumulator fragment geometry is now a function of the element type.**  Done in
   three sub-steps, each verified before the next: **2a** threaded ELEM to the tile TYPE (the
   minted name now carries it, `*register-tile-dims*` stores `(M N ELEM)`); **2b-i** reached ELEM
   from the five `%emit-per-frag-*` emitters; **2b-ii** flipped `%acc-frag-mn` so `double`
   answers 8x8, added `register-fragment-acc-f64-8x8` (2 doubles) and `%frag-record-for-acc`,
   taught `analyze-make-register-fragment` the element's own geometry, and gave
   `analyze-store-fragment` the fp64 lane mapping.  A third geometry function,
   `%frag-mn-for-operand`, was routed too, including fp64's 8x4 / 4x8 OPERAND geometry — unused
   until step 3, but a function that would answer 16x8 if asked is a trap.
   Specs: `01-f64-register-tile.crisp` (one fragment), `02-f64-register-tile-multi.crisp` (16x16
   = four fragments, which exercises the walk).

   **Method that paid off, and one that did not.**  2a and 2b-i were required to be INERT and
   checked against a 14-file byte-identical IR baseline.  That check is a spot check and it is
   not sufficient: 2b-i passed it and still broke 5 Intel specs, because ELEM had been added as a
   seventh field on the tile ENTRY and a consumer in ANOTHER FILE (src/codegen.lisp:5477)
   destructures that entry with a fixed lambda list.  The survey had been scoped to src/mma.lisp.
   **Only the suite can support the word "inert"; the IR check is a fast filter, not a proof.**
   The redesign was also simply better: that same codegen site already asks
   `(%register-tile-elem-of (first entry))` — a side-table lookup keyed by the tile's symbol —
   so the entry never needed to grow, and v2 uses the mechanism that was already there.

3. Then the `load-fragment-a`/`-b` f64 branch and the `llvm.nvvm.mma.m8n8k4.row.col.f64` emitter
   branch.  Both now have their geometry supplied and their lane layouts already decoded (finding
   1b), so this is wiring rather than discovery.  **This is where the pod becomes worth renting**:
   a fragment lane layout is exactly what compile-time checks cannot validate.
4. The (8 8 4)-only shape refusal.

**NOT an open question — RETRACTED.**  This doc briefly claimed that needing `(as double 2.5)` for
a tile init was a papercut requiring a language decision.  It is not: **`2.5d` works**, and the
`d` suffix is documented in `docs/ideal_001.md`'s literal-suffix table (`double | 64 bit | d / D |
2.0d`) and implemented.  The claim came from reading BUG 005's "we will probably use suffixes on
literals" as future tense and not testing it.  Both specs use `2.5d` / `1.5d`, verified to emit
`0x4004000000000000`.

One real (and minor) trap does exist: **`2.5d0`, the Common Lisp spelling, reads as FLOAT** — the
suffix parser matches `<number><suffix>`, so the trailing `0` defeats it.  It fails loudly with
"Expected DOUBLE but inferred FLOAT" rather than silently, so it is a papercut for Lisp habits
rather than a hazard.  Recorded in spec 01's header.

The type refusal itself remains good evidence that the record is really fp64: before 2b-ii a tile
declared `double` was built from f32 fragments and a plain float init matched, so spec 01's first
form had been passing for the wrong reason.

Note that the "Type mismatch! Expected FLOAT but inferred DOUBLE" refusal in row 2 is the
f32-hardcoded fragment record showing through, and it is a GOOD sign: the type checker is already
catching what the MMA path cannot yet do.  It should be replaced by a real f64 lowering, not by
loosening the check.


Precision and denormals — decision and reasoning
================================================

The original plan said 64-bit should ERROR on the ieee+ftz combination.  The scope is slightly
different from that phrasing, and the conclusion has changed.  Recorded in full because it is the
kind of decision that looks arbitrary a year later.

**The scope.**  PTX `.ftz` is f32-only.  `ftz` is meaningless for f64 regardless of ieee vs fast;
`ieee` is not what makes it f32-only.

**The defect.**  `%stamp-denormal-attrs` (src/codegen.lisp:469-478) stamps BOTH `denormal-fp-math`
and `denormal-fp-math-f32` to the same value, so under `--denormal-handling=ftz` the module makes
a flush claim about f64 that the hardware will not honour and that LLVM may fold on.

**Why not an error.**  Precision has a five-deep resolution chain — force > with-precision >
declaim > flag > default — so a site-level warning like 126/20 (`20-warn-wgmma-not-fast.crisp`)
always leaves the user an escape hatch: `(with-precision (fast) ...)` says "yes, I know".
**Denormal handling is flag-only, and permanently so — there will never be a `(with-denormal ...)`
or a declaim form.**  A hard error therefore means one double anywhere makes
`--denormal-handling=ftz` unusable for the entire compilation with no way to say "yes, I know" —
and it would be refusing a well-formed request, since on a mixed f32/f64 kernel `ftz` still means
something real for the f32 half.

**Decision.**
1. Fix the lowering: `:ftz` stamps only `denormal-fp-math-f32`.  This is the actual defect, it is
   independent of this endeavour, and once fixed `ftz` + f64 stops being a lie and becomes a
   no-op.
2. Warn, once per compilation, in 126/20's shape: `ftz` does not apply to 64-bit arithmetic; the
   f64 operations keep IEEE denormals.

Corroboration from the harness itself: `nvcc_math_flags` passes `-ftz=`, and nvcc's own `-ftz` is
documented as single-precision only.  The toolchain already treats this axis as f32-only.


Intel / BMG
===========

No fp64 record exists in our BMG device facts.  Xe2's XMX/DPAS has no f64 datapath, so an f64
cooperative-matrix will be a REFUSAL rather than a slow path; the only open question is whether
BMG advertises the `Float64` capability at all for plain (non-MMA) fp64.

Cheapest resolution is a two-arm probe in the existing Docker flow: (a) a plain f64 kernel, no
MMA, to see whether the driver accepts Float64; (b) an f64 coop-matrix, to get the refusal on
record.  One Docker run.  Either we get a chapter-0-only Intel column or a documented "no", and
either way the answer belongs in the BMG device-facts note.


Compiler work this implies
==========================

All of it is overlay-appendable — `register-mma-types` is a `defun`, so the new fragment records
need no struct patch.

- Three fragment records for m8n8k4, per finding 2: A 8x4 -> 1 double/lane, B 4x8 -> 1
  double/lane, C/D 8x8 -> 2 doubles/lane.
- A third branch in `load-fragment-a` / `-b` for the f64 lane layout (currently tf32 4-elem vs
  16-bit 8-elem, src/mma.lisp:557-620).
- A third branch in the MMA emitter (src/mma.lisp:850-917) for
  `llvm.nvvm.mma.m8n8k4.row.col.f64`.
- Typed profile entry `(double (8 8 4))` plus a refusal for any other f64 shape (finding 3).
- PTX register accounting: a double is two 32-bit registers, so `%ptx-note-register-demand` needs
  the x2.  Endeavour 144 Phase 2 has the hook.
- `CRISP_MATMUL_ELEM` (scripts/crisp_bench/matmul.py:671 and :740) has no `double` key — a
  KeyError the moment a double kernel appears.
- `report.py`'s section-1 `LADDER` list is hardcoded (report.py:955); a third dtype is the moment
  to generalise it rather than paste a third copy.
- AD should come free via the 145/163 VJP registry, and fp64 is the EASIEST precision in which to
  do a numeric gradient check.  Worth one spec.

**Phase 0, before any chapter is written** (compile-only, no GPU): write one f64
`mma-accumulate-via-tile` kernel and see what the compiler does with it TODAY.  The expectation is
that it falls into the tf32 branch and silently emits f32 — which, if true, is the single most
important thing to have on record, and is the reason the mechanical PTX gate above exists.


Plan
====

Ordering note: the competitor benchmarks come FIRST, before the ladder.  cuBLAS can answer the
endeavour's central question outright — `CUBLAS_COMPUTE_64F` is free to use DMMA,
`CUBLAS_COMPUTE_64F_PEDANTIC` is not, and both compute the same IEEE double result, so the ratio
between the two arms is the ceiling of everything the ladder was going to build, measured by
NVIDIA's own tuned code.  ~2x and the ladder is worth building as planned; ~1.3x and chapter 1 is
a formality and the 64-bit story is data movement from top to bottom.  It also de-risks the
CUTLASS peer early, which endeavour 159 taught us to do.

- [x] **Section 2 competitors** (`benchmarks/matmul/sec2_top_f64/`):
  - `f64_oracle.h` — the shared discriminating oracle, so the arms cannot drift.
  - `cublas_ceiling_f64.cu` — both compute-type arms, `-DPEDANTIC` selecting the vector-fp64 one.
  - `cutlass_peer_f64.cu` — CUTLASS **2.x** `device::Gemm` on `arch::Sm80`.  NOT a typedef swap
    on the tf32 peer: that one is 3.x `CollectiveBuilder` on `arch::Sm90`, which is wgmma-based,
    and there is no fp64 wgmma, so the Sm90 builder has no dispatch policy for `double`.
  - `scripts/165-pod-sec2.sh` — the whole session as one batched command, `SMOKE=1` first.  Needs
    only nvcc and the CUTLASS headers; no SBCL, no compiler build, so it is a cheap rental.
- [x] **Run it** — H100 NVL, 2026-09-07.  See "Section 2 measured".  Raw `results.jsonl` was not
      pulled before the pod was released; the per-point summary tables in that section (GFLOPS,
      correct, precision diagnosis for every contender at every size) are the surviving record.
- [ ] The 64-bit MMA Techniques ladder, chapters 0-6 (7 is absent by hardware).  **The measured
      numbers reshape this: the tensor core is worth only ~1.2x, while ~1.9x sits in scheduling
      and data movement.  Weight the effort toward chapters 2-6 and treat chapter 1 as a rung to
      pass through, not a destination.**
- [ ] TDD tests in this directory for whatever compiler work the ladder requires — see "Compiler
      work this implies".
- [ ] The 64-bit ladder added to the report; chapter 7 marked absent-by-hardware, not blank.
- [ ] Section 2 for 64-bit: fastest 64-bit technique per size vs cuBLAS / CUTLASS / custom CUDA.
      Until the ladder names a winner there is no Crisp column, and that state should be an
      explicit "not yet measured" rather than a zero — `matmul.py` already carries scar tissue
      about section 2 reading wrong when the promotion step misbehaves.

`scripts/crisp_bench/matmul.py` and `report.py` are deliberately UNTOUCHED so far.  With no Crisp
column yet there is nothing to promote, and reshaping section 2's logic before we know what the
columns should be is the wrong order.  The standalone pod script gets the numbers; we wire into
the harness once the peers are proven.
