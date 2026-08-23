# Endeavour 155 — Typed MMA shapes (and the bf16 tier they unlock)

Opened 2026-08-22, after endeavour 154 (NVIDIA perf) and the first clean H100 run of the
reorganised benchmark ladder.  **The report chose this endeavour's priorities, not an argument.**

---

## Why this, and why now

`benchmarks/REPORT.md`, regenerated 2026-08-22 from a full `fast`-precision sweep on an
H100 NVL plus the standing BMG data, says one thing louder than anything else:

| Intel BMG @ N=8192 | TFLOPS |
|---|---:|
| Crisp **bf16** | **nothing** |
| Crisp tf32 (best chapter) | 13.3 |
| oneMKL bf16 (**Ceiling**) | 112.9 |
| SYCL-TLA bf16 (**Peer**) | **237.5** |

BMG's matrix engines deliver roughly **18x** what Crisp currently reaches in tf32, and Crisp
records nothing against them.  There is no NVIDIA bf16 section in the report whatsoever — not
attempted, not skipped.

`benchmarks/results/` holds **SEVEN** `sec2_top_bf16_Crisp_*.json` files and **every one has
`results: []`**.  The kernel is being attempted, repeatedly, and producing nothing, quietly
enough that six re-runs did not make it obvious.  Phase 0 below establishes why — and it is NOT
the reason any of us assumed.

That is the whole case.  Every other item below is real but smaller.

---

## The core problem: `:mma-shapes` is not typed

`def-hardware-profile` carries `:mma-shapes` as a bare list of `(M N K)` triples — see
`src/hardware-profile.lisp` (`*hardware-profile-schema*`) and the builtin profiles in
`src/mma.lisp`:

```lisp
:mma-shapes ((8 16 8) (8 16 16) (8 16 32))  ; bmg  — XMX tf32, bf16/fp16, int8
:mma-shapes ((16 8 8) (16 8 4) (16 8 16))   ; h100 — tf32 / and NOT tf32
```

A shape triple alone cannot say **what element type it is a shape FOR**.  Both profiles already
LIST shapes belonging to several types; the type is recorded only in the trailing comment, where
no code can reach it.

So the defect is not that bf16 shapes are missing — they are present and they pass.  It is that
`%check-mma-shape` can only ask "is this triple in the list", which makes it **vacuous in both
directions**: a tf32 kernel requesting the bf16 shape is accepted just as readily, and a profile
has no way to state which element types the device supports at all.  That is the gap this
endeavour closes.

---

## TDD spec map (to be drafted before implementation)

Specs live in this directory and WILL be written first.  Sketch, not commitment:

| rung | spec | what it pins |
|---|---|---|
| 1 | `01-typed-mma-shapes-parse.crisp` | `:mma-shapes` accepts a typed form; old untyped form still parses |
| 1 | `errors/01-shape-unknown-type.crisp` | a shape naming an unsupported element type is REFUSED, with the type named |
| 2 | `02-bf16-shape-selection.crisp` | an MMA on bf16 operands selects the bf16 shape, not the tf32 one |
| 2 | `errors/02-bf16-on-tf32-only-profile.crisp` | asking for bf16 on a profile that declares none is a compile error |
| 3 | `03-bf16-mma-ptx.crisp` | NVIDIA: emitted PTX carries the bf16 MMA opcode, not the tf32 one |
| 3 | `04-bf16-mma-spv.crisp` | Intel: emitted SPV carries the bf16 coop-matrix / DPAS form |
| 4 | `05-bf16-mma-metal.crisp` | MMA_CORRECT on BOTH vendors (this is the rung that matters) |
| 5 | `06-bf16-autodiff.crisp` | bf16 MMA differentiates, or a refusal that names why |

**A validator that only checks the kernel COMPILES is not enough here.**  The existing bf16
kernel presumably compiles today — it produces empty result sets at run time.  Rungs 3 and 5
are the load-bearing ones: read the emitted instruction, then run it.

---

## Phase 0 — DONE 2026-08-22.  The diagnosis changed the endeavour.

The working assumption (mine and Chris's) was "the bf16 kernels fail to compile because
`:mma-shapes` is untyped".  **That is not what happens.**  Measured, not assumed:

```
$ ./bin/crisp-compile.exe --ir-target=spv --hardware-profile=bmg --math-precision=fast       benchmarks/matmul/sec2_top_bf16/matmul_bmg_bf16.crisp
WARNING: kernel MATMUL needs 384 registers/thread (3072 register-tile elements x 4 B / 32 B per
GRF register), exceeding every selectable allocation (128 256) in the hardware profile — it will
SPILL in any mode.
; ...All compilation passes finished.
```

It **compiles**, and emits a 30 KB `.spv`.  Two separate things are actually wrong, and only one
of them is the shape schema.

### 1. The shapes list already carries bf16 — but the TYPE is in a comment

`src/mma.lisp` (bmg profile) has already been extended:

```lisp
:mma-shapes ((8 16 8) (8 16 16) (8 16 32))   ; XMX tf32, bf16/fp16, int8
```

So `(8 16 16)` passes `%check-mma-shape`'s membership test and the kernel is accepted.  The
element type each shape belongs to exists only in that trailing comment — it is not data, so
nothing can validate against it.  The consequence is not "bf16 is rejected"; it is that **the
check is vacuous in both directions**: a tf32 kernel asking for the bf16 shape would be accepted
just as readily, and a profile cannot say which types it supports at all.

h100 has the same defect and it is already visibly ambiguous there:
`((16 8 8) (16 8 4) (16 8 16))` mixes tf32 and non-tf32 shapes with no way to tell them apart.

### 2. THE ELEMENT TYPE IS DISCARDED.  This is the root cause.

`src/mma.lisp::analyze-make-register-tile`:

```lisp
(elem     (first args))
...
(declare (ignore elem))          ; tf32/fp32 fixed for now
```

`(make-register-tile-ring bfloat16 (32 16) ...)` parses, and `bfloat16` is **thrown away**.
Every fragment is then built with the element type hardcoded — `(list 'coop-matrix 'float ...)`,
at FIVE sites in src/mma.lisp.

**Confirmed in the emitted SPIR-V**, not inferred.  Disassembling
`benchmarks/matmul/sec2_top_bf16/matmul_bmg_bf16.spv`:

```
491:4 TypeInt   2  64 0
492:4 TypeInt   8   8 0
493:4 TypeInt  20  32 0
532:3 TypeFloat 259 32          <- the ONLY float type in the module
539:7 TypeCooperativeMatrixKHR 396 259 ...   <- component type 259 = float32
541:7 TypeCooperativeMatrixKHR 423 259 ...
543:7 TypeCooperativeMatrixKHR 437 259 ...
```

There is **no 16-bit type of any kind** in the module.  All three cooperative matrices are
float32.  `bfloat16` survives only in PARAMETER NAMES
(`parent__tensor_bfloat16_2_global_compact_last`), inherited from the `def-type` — nowhere in a
type.

So the tensors are bf16 in memory while the matrices consuming them are fp32, with no conversion
type available to bridge them.  **That is a correctness bug, not a performance one**, and it is a
far better explanation for seven empty result files than register pressure ever was.

### 3. The GRF byte width is a SYMPTOM, and "fixing" it alone would be actively wrong

`%spv-kernel-register-demand` computes `(ceiling (* elements 4) *spv-grf-register-bytes*)`.  The
`4` is an element width applied regardless of type, which produced:

```
WARNING: kernel MATMUL needs 384 registers/thread (3072 register-tile elements x 4 B / 32 B per
GRF register), exceeding every selectable allocation (128 256) — it will SPILL in any mode.
```

**That warning is ACCURATE for the code actually being generated.**  The compiler really does
emit float32 matrices, so 4 B/element is the truth about them.  An earlier version of this plan
proposed patching the model to count 2 B for bf16.  That would have been a mistake: a register
model precisely wrong about real code is worse than one obviously broken, because it stops
warning about a kernel that genuinely will spill.

The byte width is not a fix to make.  It is a consequence that falls out once (2) is done.

### What Phase 0 changes about this endeavour — REVISED

The dependency chain runs the OPPOSITE way to how this endeavour was scoped:

> **1. Thread the element type through** (`make-register-tile` -> fragments -> the `coop-matrix`
> type).  This is the actual unblocker; nothing else matters until bf16 tiles are bf16.
>
> **2. Byte width follows BY CONSTRUCTION** — 4 for float, 2 for bf16/half — rather than being
> patched.
>
> **3. Typed `:mma-shapes` becomes the GUARD RAIL, not the fix.**  Its job is to stop a bf16 tile
> pairing with a tf32 shape — precisely the mistake the current code cannot detect, and the one
> most likely to be made while doing (1).

Typed shapes are still worth building.  They are simply not what unblocks bf16, and building them
first would have left the element type still being discarded one layer down.

## Secondary items, in the order the report justifies them

### A. CUTLASS / SYCL-TLA provisioning — cheap, and it makes the report interpretable

The **entire Peer column is empty on NVIDIA**.  `cutlass_peer` is a stub that (until today)
printed `{"error": "CUTLASS headers not found"}` and exited **0**, so a missing contender looked
like a measured zero.  Combined with a `_is_peer` substring bug that matched `"CUB"` inside
`"CUBLAS"`, the published table asserted CUTLASS had been measured and matched cuBLAS *exactly*
at every size, on hardware where it never ran.  Both fixed 2026-08-22; the column now reads `—`.

**But it should not read `—` at all.**  Without a peer we cannot answer the question that
actually matters: *is 77% of cuBLAS good?*  cuBLAS is a closed, hand-tuned dispatcher; CUTLASS
is a composable template library — the same claim-space Crisp is in.  It is the right yardstick.

The provisioning is currently **undocumented and inconsistent**:

| peer | how it is located | status |
|---|---|---|
| SYCL-TLA | `<repo>/third_party/sycl-tla` (repo-relative) | `third_party/` is in `.gitignore:34`, absent locally, no setup script found |
| CUTLASS | `-I/workspace/cutlass/include` (**absolute**, RunPod-specific) | nothing clones it; hence the empty column |

Two different mechanisms, neither written down, one hardcoded to a path that only exists on a
particular pod.  Proposed: one `scripts/setup-third-party.sh` that clones both under
`third_party/` at pinned revisions, make the CUTLASS include path repo-relative to match
SYCL-TLA, and have `run-on-pod.sh` / `bench-on-pod.sh` / the Intel Dockerfile call it.  Then
document it in INSTALL.md.  A pinned revision matters: a peer that silently tracks upstream
makes historical comparisons meaningless.

### B. The >8192 falloff — new, unexplained

Crisp holds 295 TFLOPS at 8192 then falls to **184 @16384 and 146 @32768**, while cuBLAS goes
408 -> 283 -> 309.  As a fraction that is 72% -> 65% -> **47%**.

Endeavour 154 never measured past 8192, so this is genuinely new.  Note cuBLAS's own curve is
non-monotonic there (283 then 309), which suggests kernel-selection changes rather than a pure
bandwidth wall — worth understanding before assuming it is our problem alone.

### C. Port 154's tile/ring findings into the chapter kernels — known-good, mechanical

The shipped chapters still use one fixed configuration.  154 established, measured on an H100:
64x64 tile + ring 4 at 256-512, 64x128 + ring 4 at 1024, 64x256 + ring 2 at 2048-4096,
cooperative 128x256 at 8192.  The report currently shows 59% at 256 and 57% at 512 — 154 got
those sizes to ~99% by configuration alone, with no compiler change.

Reporting decision already settled (154, with Chris): report best-kernel-per-size and say plainly
that cuBLAS is doing the same thing one layer down.  Size-conditional dispatch is a HOST-side
enqueue concern, not a compiler feature.

### D. Harness debts carried over from `plan/benchmark-harness.md`

- **§1, per-chapter precision sets — NOT implemented.**  `--sweep-all` is hardcoded in
  `bench-on-pod.sh` and runs three precision passes, but `report.py` reads **only** `"fast"`
  (every lookup is `matmul_data[gpu][ch]["fast"]`).  Two-thirds of every matmul run is measured
  and discarded.  Fixing this makes every future run 3x faster for free.
- **`alt_keys` blends runs from different commits.**  `benchmarks/results/` holds 25 pre-reorg
  H100 files under old chapter names, and `report.py` maps them into the new chapters.  That is
  why the table reads cuBLAS 141.3 at N=1024 while today's raw file says 139.0.  Either clear
  old results before a canonical run, or retire the aliases now the reorg has landed.
- **§4, per-device size caps — still unwired** (`compute_max_matmul_n` exists, no callers).
  Mitigated for now by the adaptive give-up + size-scaled timeout added during 154.

---

## Suggested order

1. **Phase 0 diagnosis** of the empty bf16 results — cheap, and it may redirect everything below.
2. **Typed `:mma-shapes`** + the bf16 tier.  TDD rungs above.
3. **Third-party provisioning** (A) — small, and every future report depends on it.
4. **Port 154's configurations** (C) — mechanical, large effect on the published small-N numbers.
5. **The >8192 falloff** (B) — needs a pod and probably a profiler, which is still blocked
   (`ncu` needs `NVreg_RestrictProfilingToAdminUsers=0`; request with RunPod support as of
   2026-08-22).

Item D is opportunistic: do §1 the next time anyone touches `bench-on-pod.sh`, since it pays for
itself immediately.

---

## Standing numbers this endeavour is trying to move

From `benchmarks/REPORT.md`, 2026-08-22, `fast` precision, H100 NVL:

| N | Crisp | cuBLAS | % |
|---:|---:|---:|---:|
| 256 | 3.2 | 5.4 | 59% |
| 512 | 17.4 | 30.7 | 57% |
| 1024 | 92.4 | 141.3 | 65% |
| 2048 | 253.9 | 326.6 | 78% |
| 4096 | 295.8 | 386.3 | 77% |
| 8192 | 295.3 | 408.3 | 72% |
| 16384 | 184.0 | 282.7 | 65% |
| 32768 | 145.7 | 308.6 | 47% |

CAVEAT on these: they are a blend of today's run with 25 older files via `alt_keys` (item D), so
treat them as indicative rather than exact until that is resolved.  The Crisp figures at
2048/4096 do agree closely with endeavour 154's independent measurements (78.2% / 71.3%), which
is the main reason to trust the shape of the curve.

PHASE 1 — ELEMENT TYPE THREADED END TO END.  bf16 REACHES THE HARDWARE INSTRUCTION.
====================================================================================
2026-08-22.  All changes in `overlays/crisp-compiler-overlay.lisp`, each with a
NOTE FOR THE SRC PATCH.  **1028/1028 specs, 218/218 negative, 291/291 unit.**

THE RESULT, stated as the artefact rather than the intent.  Disassembling
`benchmarks/matmul/sec2_top_bf16/matmul_bmg_bf16.spv`:

| | before | after |
|---|---|---|
| float/int types | `TypeFloat 259 32` only | `TypeFloat 259 32` **and `TypeFloat 396 16`** |
| coop matrices | 3, all component `259` (f32) | **5: three f32, two bf16** |
| extensions | coop_matrix, 2d_block_io | + **`SPV_KHR_bfloat16`** |
| GRF verdict | "384 regs — will SPILL in any mode" | "256 regs — selecting the 256-register mode" |

The bf16 operands and the f32 accumulator now coexist in one module, which is what a
mixed-precision MMA IS.

WHAT HAD TO CHANGE, and it was five layers rather than one
-----------------------------------------------------------
Each was invisible until the one above it was fixed — the reason this could not be planned in
advance, and the reason the endeavour was scoped wrongly twice.

1. `analyze-make-register-tile` — deleted `(declare (ignore elem))`; threads the type into the
   fragments it generates.
2. `%explode-register-tiles` — binds `elem` from the constructor form in BOTH branches (tile and
   ring) and passes `:elem` down.
3. `analyze-make-register-fragment` — new `:elem` key (default `float`, so every existing caller
   is unchanged); it reaches the coop-matrix component type and the GRF byte tally.
4. `%coop-elem-of` (new) + `load-fragment-a` / `-b` — the component type is DERIVED from the
   operand's tensor, mirroring how `%coop-layout-of` already derives the memory layout.
5. `%coop-mma` — declares the MulAdd signature from `LLVMTypeOf` of the actual A/B/C values
   instead of rebuilding all three from one element type.

Plus `%module-uses-bfloat-p` + `compile-to-spirv`, to request `SPV_KHR_bfloat16` only when a
bfloat type is actually present.

ACCUMULATORS ARE DELIBERATELY STILL f32.  XMX/DPAS and the NVIDIA tensor cores take bf16
operands and accumulate in fp32, so an f32 accumulator beside bf16 operands is correct.  Only A
and B were routed through `%coop-elem-of`; `analyze-mma-accumulate`'s f32 accumulator type was
left alone on purpose.

THE GRF BYTE WIDTH — the "fix" this endeavour nearly made first, and why the order mattered
--------------------------------------------------------------------------------------------
`%spv-kernel-register-demand` now tallies BYTES (`%elem-bytes`) rather than elements-times-four.
Doing this FIRST — as the original plan proposed — would have produced a register model that was
precisely wrong about real code, because the compiler still emitted float32 and 4 B/element was
the truth about it.  The model only became safe to change once the emitted type changed.

THREE TRAPS HIT WHILE DOING THIS, all worth remembering
--------------------------------------------------------
- **Retyping a function from memory.** My first `analyze-make-register-fragment` dropped the
  `:rows/:cols/:use/:layout` fields, flattened the PTX register demand (really
  `(:acc 4) (:a 4) (:b 2)`), and collapsed three fragment struct types into one — it would have
  broken NVIDIA silently.  Caught by reading the original before installing.  Everything after
  that was EXTRACTED FROM SOURCE PROGRAMMATICALLY rather than retyped.
- **`src/compiler.lisp` is CRLF; `src/mma.lisp` is LF.**  A multi-line search string with `\n`
  silently fails to match the CRLF file.  Normalise on extraction.
- **`:crisp.compiler` shadows `char`, `float`, `let`, `when`, `unless`, `cond` and `return`**
  (src/package.lisp).  `(char ir i)` resolves to the Crisp TYPE and fails with
  "The function CRISP.COMPILER:CHAR is undefined".  The sibling predicates use `return-from`,
  never bare `return` — that is the house style for this reason.

STILL OPEN
-----------
- **Not run on hardware.**  The SPIR-V contains bf16 coop matrices; whether BMG executes them
  correctly is unmeasured.  That needs a BMG run and is the next step.
- **NVIDIA bf16 untouched.**  The PTX fragment records are tf32/f32 by construction
  (`register-fragment-a-tf32-16x8` etc.) and this phase deliberately did not touch them.
- **Typed `:mma-shapes` not yet done** — and Phase 1 makes the case for it sharper, not weaker.
  Nothing currently stops a bf16 tile pairing with a tf32 shape; the profile lists
  `((8 16 8) (8 16 16) (8 16 32))` with the types recorded only in a comment.  That is now the
  guard rail on work already done, which is the right time to build it.

PHASE 2 — ON METAL (BMG, Arc B580).  bf16 IS BLOCKED BY THE DRIVER, NOT BY CRISP.
================================================================================
2026-08-22, in the crisp-bench-intel container with /dev/dxg passthrough.  BMG confirmed live:
[level_zero:gpu] Intel(R) Graphics [0xe20b] 20.1.0 [1.6.33578+15].

FIRST OBSERVATION, AND IT WAS MISLEADING.  Loading the bf16 module failed with
zeModuleCreate -> 0x70000004 and nothing else, because the generated L0 harness passes nullptr
for the build log.  Capturing the log showed "IGC: Internal Compiler Error: Segmentation
violation", and the obvious reading was: IGC cannot compile our bf16 cooperative matrix; Intel's
own bf16 path uses SPV_INTEL_subgroup_matrix_multiply_accumulate, so we must switch extension.

THAT READING WAS WRONG, and one experiment separated it from the truth.

THE EXPERIMENT.  `half` and `bfloat16` differ by one token in the same kernel, go through the same
typed path added in Phase 1, and use the same (8 16 16) shape.  Compile both, load both:

    half      ->  RESULT: MODULE BUILT OK      kernel: probe_tile        exit 0
    bfloat16  ->  InvalidModule: Invalid SPIR-V module: input SPIR-V module uses
                  unknown extension 'SPV_KHR_bfloat16'                   process dies, exit 11

Note the wording: "INPUT SPIR-V module uses unknown extension".  That is a READER speaking.  The
message arrives on the LOADER PROCESS'S STDERR, not from any Crisp tool -- it had looked like a
compile error only because stdout was block-buffered and stderr was not, so it interleaved ahead
of the loader's own output.  Running the pipeline by hand confirms the other half: llvm-spirv
translates the bf16 module SUCCESSFULLY, and all three translators present on the image
(LLVM 21.1.1 /usr/bin, oneAPI 2025.3, and the repo's LLVM 22 tools/) accept it.

CONCLUSION.  The BMG driver's embedded SPIR-V reader (IGC 1.6.33578) DOES NOT IMPLEMENT
SPV_KHR_bfloat16.  It says so, and then crashes instead of returning an error.  Crisp's module is
well-formed; nothing in Crisp is at fault, and switching to the INTEL extension is a possible
WORKAROUND, not a correction of a Crisp bug.  The tooling to prove this now lives in
put_temp_files_here/bf16probe/spvload.cpp -- a standalone loader that prints the IGC build log.

  16-BIT COOPERATIVE MATRICES ARE FINE ON THIS HARDWARE.  fp16 proves it: same KHR coop-matrix
  construct, same shape, same Phase 1 plumbing, builds and runs.  The blocker is specific to the
  bfloat16 EXTENSION, not to 16-bit MMA.

So Phase 1 stands, and stands stronger than before: the element type reaches codegen, and on the
one 16-bit type this driver supports it reaches the GPU and executes.

WHAT TO DO ABOUT bf16 ON INTEL — A DESIGN DECISION, NOT A BUG FIX
------------------------------------------------------------------
Three routes, none of them "fix our SPIR-V":
  1. WAIT / UPGRADE THE DRIVER.  SPV_KHR_bfloat16 is recent; a newer compute runtime may simply
     support it.  Cheapest to test, and it should be tested before any code is written.
  2. LOWER Intel bf16 through SPV_INTEL_subgroup_matrix_multiply_accumulate instead
     (OpSubgroupMatrixMultiplyAccumulateINTEL).  This is what Intel's own SYCL-TLA peer compiles
     with, so it is known-good on this hardware -- but it is a SECOND MMA lowering for one
     backend, and it should not be adopted on the strength of a flag string alone.
  3. DECLINE bf16 on Intel for now and say so in the hardware profile, which is what typed
     :mma-shapes exists to express.  A compile-time refusal that names the driver limitation is
     far better than a module that crashes the loader.
Recommend (1) then (3), with (2) only if bf16 on Intel becomes a requirement -- and Chris should
make that call.


PHASE 3 — fp16 END TO END, AND WHAT IT EXPOSED
================================================================================
Since fp16 runs where bf16 cannot, a parallel fp16 chapter was added so a 16-bit MMA number can be
measured on BMG today: benchmarks/matmul/sec2_top_fp16/ (Crisp kernel + SYCL joint_matrix control
+ oneMKL ceiling, all converted from their bf16 counterparts).

KEPT DELIBERATELY SEPARATE FROM sec2_top_bf16.  The report picks a chapter's Crisp row by name and
would have rendered an fp16 measurement under a "Crisp BF16" heading -- precisely the class of
fabrication this report was just repaired for (the CUB/CUBLAS substring collision that published
CUTLASS numbers from a run where CUTLASS never executed).  Different element type, different
section.

RESULT: THE KERNEL BUILDS, RUNS, AND IS WRONG AND SLOW.  Measured on BMG, precision=fast:

    N=4096   N=8192
    16.33    13.50   TFLOPS   Crisp  tf32  (sec2_top -- the tuned kernel, for control)
    14.31    14.17   TFLOPS   oneMKL tf32
     0.27     2.20   TFLOPS   Crisp  fp16  (sec2_top_fp16)
    17.92    15.25   TFLOPS   SYCL joint_matrix fp16 control
   110.38   111.62   TFLOPS   oneMKL fp16

The tf32 control run in the same session rules out the environment and the harness: Crisp tf32 is
healthy and beats oneMKL tf32.  The fp16 kernel is ~50x off, at 0.5 s per 256^3 launch.

IT IS NOT SPILLING, which was the first guess and the wrong one.  The IGC build logs say the
opposite of the theory:

    tf32 (fast, healthy) : "compiled SIMD16 allocated 128 regs and spilled around 28"
    fp16 (broken)        : clean, no spill  (it selected the 256-register mode)

THE ACTUAL DEFECT, and it is in Phase 1's own work.  Disassembling the fp16 module shows the
element type reached codegen only PARTIALLY.  Every operand exists TWICE, once per component type:

    TypeCooperativeMatrixKHR 387 259 ... 130     259 = TypeFloat 32     A as f32
    TypeCooperativeMatrixKHR 390 389 ... 130     389 = TypeFloat 16     A as f16
    TypeCooperativeMatrixKHR 433 259 ...  26                            B as f32
    TypeCooperativeMatrixKHR 435 389 ...  26                            B as f16
    TypeCooperativeMatrixKHR 457 259 ... 347                            accumulator f32 (correct)

There are NO conversion ops (FConvert, CooperativeMatrixConvert: zero), and the f32 operand types
are referenced MORE than the f16 ones (42/22 vs 18/10).  So the majority of A/B fragments are
still being minted as float32 and fed 16-bit memory -- which is both a correctness bug and an
ample explanation for a 50x slowdown.

A HYPOTHESIS I FORMED AND THEN DISPROVED, recorded because the disproof is the useful part.  The
benchmark kernel uses make-register-tile-ring, which the Phase 1 probe spec never exercised, and
this codebase has a documented precedent for exactly that shape of bug (BUG 040: %mma-k-steps
silently truncating for a ring-get operand whose extent was not compile-time resolvable).  So:
"the ring path drops the element type."  Compiling the NON-ring probe kernel and dumping its types
refutes it -- probe_half.spv shows the identical f32/f16 duplication.  The defect is systemic in
the 155 lowering, not ring-specific, and a fix aimed at the ring would have missed.

  All five (list 'coop-matrix 'float ...) sites in src/mma.lisp are accounted for: 337/469/497 are
  overridden in the overlay to use the element type, and 568/2048 are the ACCUMULATOR, which is
  correctly f32.  So the f32 A/B types are minted somewhere not yet found.  That is the next
  investigation, and it wants a REPL session with a breakpoint, not more static reading.

MY PHASE 1 VALIDATOR IS TOO WEAK, and this is the lesson that generalises.  validate-spv-bf16-coop
asserts that a 16-bit float type exists, that at least one cooperative matrix uses it, and that an
f32 type also exists.  A module in which MOST operands are still f32 satisfies all three.  The
validator was written to catch "the element type was discarded" and does not catch "the element
type was discarded on SOME paths" -- which is the bug that was actually there.  It should assert
that NO A/B-use cooperative matrix carries a component type other than the declared element type.

STATUS OF THE fp16 NUMBERS: NOT PUBLISHED.  The three sec2_top_fp16 result files were moved out of
benchmarks/results/scratch/ into put_temp_files_here/bf16probe/unpublished-results/ so no report
run can pick up a Crisp row produced by a kernel known to compute the wrong answer.  No report was
regenerated.


A HARNESS GAP FOUND ALONG THE WAY, AND IT IS BIGGER THAN THIS ENDEAVOUR
================================================================================
matmul.py reports "NOT MMA_CORRECT -- skipping point" for EVERY size <= 2048 in sec2_top,
sec2_top_bf16 and sec2_top_fp16 -- including the tf32 kernel that is demonstrably healthy.  The
cause is not a wrong answer: the generated L0 harness for these chapters contains NO HOST
REFERENCE AT ALL.  %l0-emit-mma-reference (src/hoist-l0/main.lisp:385) emits the check only when
it can assign :a/:b/:c MMA roles, which requires rank = 2 to be recoverable from the parameter
type; for these chapters it is not, and the harness is emitted silently without a verification
block.  matmul.py then treats "no MMA_CORRECT token in the output" as "incorrect".

THE CONSEQUENCE IS AN INTEGRITY ONE.  Points at N <= 2048 are dropped, while points at N > 2048
are recorded -- because section 5 skips verification above 2048.  So for these chapters EVERY
PUBLISHED CRISP NUMBER COMES FROM EXACTLY THE SIZES WHERE NOTHING IS CHECKED, and the sizes that
would be checked are discarded for failing a check that was never emitted.  The tf32 top chapter
has been reporting under this regime.

Two separate defects, worth separate fixes:
  1. the hoist generator should emit the reference for these chapters (or say out loud that it
     cannot, rather than emitting a harness that silently verifies nothing);
  2. matmul.py must distinguish "verification ran and FAILED" from "no verification was emitted".
     Silently equating them is what let (1) hide.

TWO SMALLER HARNESS DEFECTS, ONE FIXED
----------------------------------------
- FIXED: a contender that fails to compile no longer aborts the sweep.  time_compile called
  check_returncode(), so when third_party/sycl-tla was absent the SYCL-TLA peer's compile failure
  raised CalledProcessError and killed the whole chapter -- discarding Crisp's and the control's
  already-measured results.  It now raises a typed ContenderBuildError carrying the compiler's own
  diagnostic; run_target and run_l0_crisp catch it, print a skip line with the reason (and a
  pointer to scripts/setup-third-party.sh when the reason is missing peer headers), and continue.
  Verified: the fp16 sweep ran to completion and saved all three contenders.
- OPEN: the generated L0 harness discards the IGC build log (zeModuleCreate(..., nullptr)), so
  every module-build failure on Intel reports only a numeric code.  This is what turned a one-line
  diagnosis into an afternoon.  put_temp_files_here/bf16probe/spvload.cpp is the stopgap; the
  generator should pass a log handle and print it on failure.


PHASE A — TDD RUNGS, AND THE THREE HARNESS BUGS THAT WERE HIDING BEHIND ONE ANOTHER
================================================================================
2026-08-22.  Goal: state the f32/f16 defect as a failing spec before fixing anything.

WHY THERE WAS NOTHING TO BUILD ON.  A survey of the whole tree found that 16-bit is essentially
untested in Crisp:
  - ALL 25 benchmark kernels are `float` (tf32) except the two 16-bit ones, both of which are the
    ones just found broken.  The activation chapters (sec4_fused_relu, sec4_fused_custom) are
    float too, so there is NO working 16-bit benchmark on BMG in ANY category.
  - EXACTLY ONE spec in the entire suite declares a 16-bit type — rung 01, written last session
    and parked beyond ci-stop.  Every other apparent hit was the word "half" in prose.
That is why a systemic element-type leak survived: nothing exercised it.

THE VALIDATOR, REBUILT AROUND THE RIGHT INVARIANT.  A cooperative matrix declares BOTH what it is
made of and what it is for:

    7 TypeCooperativeMatrixKHR <result> <component> <scope> <rows> <cols> <use>

with <use> an ID naming a constant: 0=A, 1=B, 2=Accumulator.  So the real invariant of a
mixed-precision MMA is checkable exactly — every A/B matrix has the declared element width, every
Accumulator is fp32 — instead of the old "at least one matrix is 16-bit somewhere", which a mostly
-f32 module satisfies.  New: %spv-lines, %spv-int-constants, %spv-float-widths, %spv-coop-matrices,
%validate-coop-operand-elem, and validate-spv-fp16-coop beside a strengthened
validate-spv-bf16-coop.

PROVEN BOTH WAYS BEFORE BEING TRUSTED, using a standalone harness (put_temp_files_here/
test-155-parse.lisp) so the logic could be checked without a compiler rebuild:
    probe_half.spv   -> FAIL, 2 of 4 A/B operands are 32-bit   (the real defect)
    sec2_top tf32    -> PASS, 2 of 2 A/B operands are 32-bit   (no false positive)

NEW RUNGS
  02-fp16-register-tile-spv       plain make-register-tile
  03-fp16-register-tile-ring-spv  make-register-tile-ring, the benchmark's construction path
Both fp16, because bf16 cannot be loaded on this driver at all while fp16 goes through the
identical typed path and runs.  Rung 01 stays bf16 and compile-only.

All three are RED, with the diagnostic naming the offending ids:
    FAIL: 2 of 4 A/B cooperative matrices are NOT half/fp16 (16-bit).
        id 364  component=32-bit  use=A
        id 376  component=32-bit  use=B
Rung 03 fails identically to 02, reconfirming from a second construction path that the defect is
not ring-specific.

THREE HARNESS BUGS, FOUND ONLY BECAUSE EACH MASKED THE NEXT
--------------------------------------------------------------
Rung 01 had recorded three "obstacles" last session.  Working through them showed that two of the
three descriptions were wrong about the cause, and the real causes were stacked:

1. --hardware-profile IN A TEST-WITH WAS PARSED BUT NEVER APPLIED.  The runner PRINTS the flag in
   the pass name, so it is plainly parsed; the compile then failed with "load-tile into a
   register-tile requires a hardware profile", exactly as if it had been omitted.  My earlier fix
   bound *compile-hardware-profile*, which is the spec runner's own variable for HOIST runs.  The
   compiler reads crisp.compiler::*requested-hardware-profile* — and binding THAT would not have
   worked either, because initialize-compiler SETFs it from its :hardware-profile argument
   (src/compiler.lisp:1033), clobbering any surrounding binding with NIL.  The value has to
   travel as an ARGUMENT.  Fixed by overriding compile-crisp-file-to-spirv to pass it.

   This is the FOURTH instance of one class: 137 (--ir-target-arch), 152 (--metadata), rung 01
   (--hardware-profile), and now its actual cause.  A directive flag that no code path consumes
   should be an ERROR, not a no-op.  Worth doing once rather than rediscovering a fifth time.

2. AN --ir-target=spv VALIDATOR COULD NEVER RECEIVE THE .spv, IN PROCESS.  run-spec-spirv-in-
   process passed the validator META-PATHS, which only exist under --metadata.  Without it,
   meta-paths is NIL and NIL flowed into (probe-file val-arg), producing
       The value NIL is not of type VECTOR when binding #:N-ARRAY
   — an opaque type error that says nothing about the real problem, and which rung 01 had
   mis-diagnosed as a package-resolution issue.  The package was a red herring; the ARGUMENT was
   the bug.  Fixed by falling back to OUT-PATH.  Safe by construction: any spec reaching that
   branch without metadata ALREADY crashed every time, so nothing could depend on it.

3. THE CRLF TRAP, AGAIN.  tests/run-specs.lisp is CRLF while the overlays are LF, so a multi-line
   anchor written with \\n silently matched ZERO times.  The first fix survived only because it
   matched by line index.  Extraction now normalises line endings, and the overlay was scrubbed of
   the 122 CR characters the first append had carried in.

REGRESSION AFTER ALL THREE: 1028/1028 E2E, 218/218 negative, 291/291 unit.  The two overridden
runner functions are shared, so this was not optional.

ci-stop remains at 154-nvidia-perf; the 155 rungs are deliberately beyond it and RED.  Advance it
to 155-typed-mma-shapes when Phase B turns them green.

NEXT: PHASE B — find where the f32 A/B cooperative-matrix types are minted.  All five
(list 'coop-matrix 'float ...) sites in src/mma.lisp are accounted for (337/469/497 overridden to
use the element type; 568/2048 are the accumulator and correctly f32), so the source is somewhere
not yet located.  With the rungs now failing for the right reason, the fix has a target to aim at
and a test that will confirm it.


PHASE B — THE ELEMENT TYPE REACHES CODEGEN.  RUNGS GREEN.  AND THE NEXT LAYER IS NAMED.
================================================================================
2026-08-22.

FOUND IT, AND NOT BY GUESSING.  Dumping the LLVM IR rather than reading more source located it in
one step.  The module declared FIVE distinct cooperative-matrix types where it should have had
three, and the mangled callee names said why:

    declare target("spirv.CooperativeMatrixKHR", float, 3, 8, 8, 0)  @__spirv_CompositeConstruct_0_8_8(float)
    declare target("spirv.CooperativeMatrixKHR", float, 3, 8, 8, 0)  @__spirv_CooperativeMatrixLoadKHR_0_8_8_as1(...)

`_0_8_8` encodes use/rows/cols and NO element type — one name necessarily serves every element
type, and %coop-call interns by name, so the FIRST declaration wins and every later one silently
aliases it.

THE DEFECT was two literals in src/codegen.lisp:4706 and :4714 —

    (:fill (values (%coop-fill builder module (gen ...) f32 rows cols use) nil))
    (:load          (%coop-load builder module ptr stride f32 rows cols use layout))

Phase 1 had threaded the element type through the ANALYZER, so the semantic node correctly carried
`(coop-matrix half 8 8 0)`.  Codegen never read it.  The emitted IR was therefore internally
inconsistent, and silently so, because opaque pointers mean LLVM never objects:

    %"a-tile$f0" = alloca target("spirv.CooperativeMatrixKHR", half,  3, 8, 8, 0)
    %27 = call   target("spirv.CooperativeMatrixKHR", float, 3, 8, 8, 0) @__spirv_CompositeConstruct_0_8_8(float 0.0)
    store        target("spirv.CooperativeMatrixKHR", float, 3, 8, 8, 0) %27, ptr %"a-tile$f0"

An f32 cooperative matrix stored into an f16 slot and read back as f16 — a REINTERPRET, not a
conversion.  That is exactly why the disassembly showed both widths per operand and ZERO FConvert
ops.

WHY IT STAYED QUIET.  Every piece was individually defensible: the ALLOCA came from the fragment's
semantic type (half, right), and __spirv_CooperativeMatrixMulAddKHR derives its signature from
LLVMTypeOf of the actual values (half, right — Phase 1's %coop-mma fix).  Only the PRODUCERS
disagreed, and nothing cross-checked producer against consumer.

THE FIX (overlay, three parts)
  - %coop-node-elem / %coop-op-elem-llvm: read the node's own (coop-matrix ELEM ...) type.
  - generate-node-ir for semantic-coop-op: :fill / :load / :store now pass that element type.
  - %coop-fill: COERCE the init scalar to it.  This surfaced immediately — a literal `0.0` is an
    f32 constant, so a correctly-typed `half` matrix was being constructed from a `float` argument
    and llvm-spirv rejected the module with exit code 13.  Before the element type reached codegen
    this coercion was vacuous (everything was f32); now the literal has to follow the tile.

  THE MAP PATH IS REFUSED, NOT FIXED.  :map / :map2 extract scalar elements through f32 temporaries
  (cm_elem / cm_prm / cm_adj).  Making those width-correct is a real change to a path no failing
  rung exercises and that autodiff depends on, so it now raises a compile-time error naming the
  limitation instead of miscompiling.  It cannot regress anything today: every kernel in the tree
  that uses map is float.

RESULT.  The module now declares exactly three coop types, which is the correct mixed-precision
shape:
    half  8x8   use A        half  8x16  use B        float 8x16  use Accumulator
All three rungs GREEN, including rung 01 (bf16), which had been red since it was written.
Regression: 1028/1028 E2E, 218/218 negative, 291/291 unit.


THE NEXT LAYER, NAMED BY THE HARDWARE ITSELF
================================================================================
With the types right, the fp16 benchmark kernel STILL does not run on BMG — but the failure has
changed from silent garbage to a precise diagnosis.  Where the type-inconsistent module loaded and
computed nonsense at 0.27 TFLOPS, the type-correct one is REJECTED at load, and says why:

    undefined reference to `__builtin_spriv_OpJointMatrixLoadINTEL_PackedA_RowMajor_SG16_8x8_i16_4_...'
    undefined reference to `__builtin_spriv_OpJointMatrixLoadINTEL_PackedB_RowMajor_SG16_8x16_i16_4_...'

IGC lowers KHR cooperative-matrix loads to internal JointMatrix builtins, and there is no
`8x8_i16` builtin because 8x8 IS NOT A VALID 16-BIT DPAS SHAPE.  Read the shapes: A is 8x8 and B
is 8x16 — those are the K=8 TF32 shapes, carrying 16-bit elements.

THE CAUSE IS %spv-mma-shape, AND IT IS THIS ENDEAVOUR'S ORIGINAL SUBJECT.  It returns
`(first shapes)` from the profile's :mma-shapes — for bmg that is (8 16 8), tf32 — ignoring BOTH
the element type AND the shape the kernel explicitly asked for.  The kernel says
`(mma-accumulate-via-tile (8 16 16) ...)`, i.e. K=16, which is correct for fp16; the fragments are
minted at K=8 anyway.  The profile's own comment has said so all along:

    :mma-shapes ((8 16 8) (8 16 16) (8 16 32))  ; XMX tf32, bf16/fp16, int8

K scales inversely with element width, because K x element-bits is a fixed fragment footprint.  So
the shape list is only meaningful WITH the type — which is precisely what "typed :mma-shapes"
means, and why it was the endeavour's name from the start.

RE-SCOPING, HONESTLY.  Typed :mma-shapes was scheduled as Phase E, a guard rail to be added once
16-bit worked.  It is not a guard rail: it is a HARD PREREQUISITE for 16-bit working at all.  The
type and the shape are one decision, not two, and Phase B fixed only half of it.

WHAT THIS SAYS ABOUT THE RUNGS, which is worth saying plainly.  02 and 03 are green and the kernel
still does not run.  They assert the emitted TYPES, and the types are now right; a shape that no
hardware implements is invisible to them because it is only rejected at load time.  That is not a
flaw in the rungs — it is the argument for rung 04, the on-metal rung the plan already listed.  A
compile-and-inspect rung can only ever check what the module SAYS; it takes hardware to check what
the module MEANS.

NEXT: make %spv-mma-shape select by element type — the entry whose K matches the operand width —
and reconcile it with the shape the kernel requests, so `(8 16 16)` on an fp16 tile mints A=8x16
and B=16x16.  Then rung 04 on metal, then the benchmark, then the report section.


PHASE C — TYPED SHAPES.  fp16 NOW BUILDS ON THE GPU.
================================================================================
2026-08-23.

Phase B made every cooperative matrix carry its element type; the module then failed to LOAD
because 16-bit matrices were still being minted in TF32 shapes.  Phase C makes the SHAPE follow
the type as well, which is what this endeavour was named for.

THE MECHANISM.  %spv-mma-shape now takes an optional ELEMENT TYPE and selects the profile entry
that matches it, by one of two rules:
  1. an explicitly TYPED entry wins -- :mma-shapes ((float 8 16 8) (half 8 16 16) ...) is now an
     accepted format, which is the honest long-term encoding;
  2. otherwise the WIDTH rule: K x element-bits is a fixed fragment footprint (256 bits on both
     shipped profiles), so the right entry is the one whose K equals footprint/width.  The
     footprint is read off the profile's own 32-bit entry rather than hardcoded.
Both shipped profiles resolve exactly as their comments always claimed:
    bmg  ((8 16 8) (8 16 16) (8 16 32))   tf32 K=8   fp16 K=16   int8 K=32
    h100 ((16 8 8) (16 8 4) (16 8 16))    tf32 K=8   fp16 K=16
When nothing matches -- e.g. the many specs carrying :mma-shapes ((8 16 8)) -- it returns
(first shapes), exactly the pre-155 behaviour, so nothing regresses.

FOUR CALL SITES had to pass the element type; the other ~14 keep their previous behaviour because
ELEM is optional.  Finding all four took three iterations, each surfaced by the same symptom
("Unknown variable NIL" -- a fragment index that no longer exists) and each in a different layer:

  1. analyze-make-register-fragment      the fill        :elem was already in its lambda list
  2. analyze-load-fragment-a / -b        the loads       element comes from the SOURCE TENSOR;
                                                         these needed their nesting INVERTED, as
                                                         the shape was computed before the tensor
                                                         was analysed -- nothing yet knew what the
                                                         shape was a shape OF
  3. %emit-per-frag-accumulate           the MMA walker  fixed by NOT re-deriving: the kernel wrote
                                                         `(mma-accumulate-via-tile (8 16 16) ...)`
                                                         and %check-mma-shape had already validated
                                                         it; the shape was in hand at the call site
                                                         and simply never passed down
  4. %emit-per-frag-block-load           the load-tile   the tile ENTRY records no element type

(4) wanted a structural change -- appending ELEM to the tile entry -- which several fixed-arity
destructuring-binds would have turned into a wide, brittle edit.  145 P3a had already solved the
identical problem with *mma-scratch-tile-dims*, a special bound by %explode-register-tiles, so
*REGISTER-TILE-ELEMS* is the same mechanism for the same reason and degrades the same way (NIL
outside an explosion; an unknown tile falls back to FLOAT).

RESULT.  The fp16 kernel emits the correct DPAS shapes --
    half  8x16  use A        half 16x16  use B        float 8x16  use Accumulator
-- and, on an Arc B580:

    RESULT: MODULE BUILT OK
       kernel: matmul

That is the milestone.  Before Phase C the driver refused the module outright:
    undefined reference to `..._PackedA_RowMajor_SG16_8x8_i16_4_...'
The TF32 top kernel is byte-for-byte unchanged (A=8x8, B=8x16), and the suites are green:
1028/1028 E2E, 218/218 negative, 291/291 unit.  All three 155 rungs pass.

WHAT IS NOT YET TRUE, STATED PLAINLY.  fp16 BUILDS and RUNS; it is not yet shown CORRECT, and it
is not yet fast.  The benchmark reports a kernel time of 500.07 ms at BOTH 4096 and 8192 -- an
identical wall time for 8x the work, which is not a measurement of anything.  The same constant
appeared before Phase C, so it is not a property of the new shapes.  Two candidates: the kernel
is not doing size-proportional work, or the kernel-timestamp path is returning a constant for
this kernel.  The TF32 kernel in the same harness reports sensible, varying times, so it is not
the timing path in general.


A CORRECTION, AND IT MATTERS MORE THAN THE THING IT CORRECTS
================================================================================
Phase 3 of this document claimed the sec2_top* chapters get no host reference because
%l0-emit-mma-reference cannot recover rank=2 from the parameter type.  THAT WAS WRONG.  The
metacrisp plainly carries `:rank 2` for all three parameters, the MMA roles ARE assigned, and the
role-driven extent override IS applied (a/b/c extents come out 256, not the default 4).

The actual rule is simpler and much worse:

    --mma-test=256,256,256                  ->  MMA_CORRECT emitted   (mma_ok x3, 13912 bytes)
    --mma-test=256,256,256 --mma-bench=5    ->  NOT emitted           (mma_ok x0, 17085 bytes)

**--mma-bench SUPPRESSES THE HOST REFERENCE.**  Reproducible, on the same metacrisp, changing only
that flag.  In the generated C++ the block simply is not there: buffer dump at line 394, then
"Success!" at 416, with nothing between.

WHY THIS IS THE MORE SERIOUS FINDING.  Every autobench chapter passes --mma-bench.  So it is not
that these chapters happen to be unverified -- it is that BENCHMARK MODE NEVER VERIFIES, for any
chapter, on this backend.  Chapters that show MMA_CORRECT=1 in their checked-in .cpp (chap0,
chap1, chap4, chap5) are the ones run through the NON-autobench path.  matmul.py then reads "no
MMA_CORRECT token" as "incorrect" and drops every point at N <= 2048, while keeping points above
2048 because verification is skipped there by design.  The net effect stands as previously
recorded, and is if anything wider than stated: for autobench chapters every published Crisp
number comes from sizes where nothing was checked.

The generator's own logic does not obviously explain this -- generate-cpp-main has a single
unconditional `(when *mma-test-dims* (%l0-emit-mma-reference stream allocations))`, allocations
are non-empty in both modes, and the roles are present in both.  So the cause is one layer below
where reading the source suggests, and it wants an instrumented run rather than more reading.
That is the next thing worth doing, because it gates knowing whether ANY benchmarked kernel is
correct.

A SECOND, SEPARATE OBSTACLE on the same path: running the non-bench (verifying) harness for this
chapter aborts inside the driver --
    Abort was called at 30 line in file:
    ./level_zero/core/source/memory/cpu_page_fault_memory_manager.cpp
The emitted reference reads a_ptr/b_ptr directly from the HOST while they are device USM
allocations.  So even the verifying path cannot currently confirm this chapter.  Both of these are
harness defects, not compiler defects, and both are now precisely characterised.

NEXT
  - instrument the hoist generator to find why --mma-bench drops the reference (gates correctness
    for every benchmarked kernel);
  - fix the host-side reference to read operands through a device->host copy rather than a direct host read;
  - only then trust an fp16 number, and only then add the report.py section.


PHASE D — VERIFICATION RESTORED, AND THE FIRST REAL VERDICT ON fp16
================================================================================
2026-08-23.

Phase C got the fp16 module onto the GPU.  Phase D was supposed to be "check correctness, then
find the slowness."  Neither question could be answered, because the two instruments needed to
answer them were both broken.  Both are now fixed, and both were broken in the same way this
whole endeavour has been about: the element type was not carried to the place that needed it.

(1) THE --mma-bench MYSTERY, SOLVED — AND IT WAS NOT IN src/ AT ALL
--------------------------------------------------------------------
Reading src/hoist-l0/main.lisp could never explain it, because the live definition is not there.
`overlays/hoist-l0/crisp-hoist-l0-overlay.lisp` (endeavour 150) redefines generate-cpp-main, and
its version says:

    (when (and *mma-test-dims* (not *mma-bench-iters*))
      (%l0-emit-mma-reference stream allocations))

against the original's plain `(when *mma-test-dims* ...)`.  That `(not *mma-bench-iters*)` is the
whole thing: the host-reference check is emitted ONLY when --mma-bench is absent, and every
benchmark sweep passes --mma-bench.

THE OVERLAY'S OWN HEADER SAYS: "Everything else in this function is byte-identical to the
original."  It is not.  150 needed the buffer-print cap raised from 100 to 512, documented that,
and silently disabled benchmark verification in the same edit.  Recorded here because the
misleading part was not the code — it was the comment asserting the code was unchanged, which is
what kept me reading src/ for the cause.

CONSEQUENCE, now measured rather than inferred: NO BENCHMARKED KERNEL HAS BEEN VERIFIED on this
backend, for any chapter, since 150.  matmul.py looks for an MMA_CORRECT token, never finds one,
reports "NOT MMA_CORRECT", drops every point at N <= 2048, and keeps the points above 2048 where
verification is skipped by design.  Restored to the src condition; verifying once and then
benchmarking costs a 64x64 corner (full K) once per run.

(2) A 16-BIT TENSOR WAS FILLED AND READ AS AN INTEGER
------------------------------------------------------
crisp-type-to-cpp-type maps BOTH half and bfloat16 to uint16_t, so the harness carried a 16-bit
float buffer as an unsigned integer and treated it as one at both ends:

    for (...) a_ptr[_i] = (uint16_t)(_i % 5);          // fill
    acc += (float)a_ptr[...] * (float)b_ptr[...];      // host reference

The bit pattern 0x0001 is not 1.0 in fp16 — it is a SUBNORMAL near 6e-8.  So the GPU was handed
denormal noise while the host reference computed with 1..4.  They could not agree even in
principle, the input data was meaningless, and any timing taken over it timed the wrong problem.
Fixed at both ends with converters emitted into the harness; half and bfloat16 get DIFFERENT
converters (same width, different exponent split), which is why the element TYPE is now recorded
in the allocation plist rather than being guessed from "uint16_t".

(3) THE REFERENCE COULD NOT READ DEVICE MEMORY ANYWAY
------------------------------------------------------
With the decode fixed, the check still aborted before comparing anything:

    Abort was called at 30 line in file:
    ./level_zero/core/source/memory/cpu_page_fault_memory_manager.cpp

The reference dereferenced a_ptr / b_ptr from the HOST; on this driver a host dereference of that
USM aborts outright.  But the harness FILLS those buffers itself, from the index — so their
contents are known by construction and need not be read back at all.  The reference now
reconstructs them.  C is still read properly, by device->host memcpy, which is the thing actually
under test.

  THE TRADE, STATED PLAINLY.  This now checks "C equals the product of the values the harness
  WROTE" rather than "...of the bytes currently IN the operand buffers".  That differs only if the
  fill itself is broken, which is a louder and separate failure.  The risk introduced is drift
  between fill and reference, so both take their modulus from %l0-mma-fill-modulus and the
  constant exists once.  0..4 and 0..2 are exact in fp16/bf16/tf32/f32, so the check is exact for
  every element type.

(I re-made a mistake I had already made in endeavour 152: `%%` in a CL FORMAT string emits TWO
percent signs, because `%` is already literal there.  It reached the C++ compiler as `%%` and
failed to parse.  Third time this bug has cost me a cycle; it is worth remembering that FORMAT is
not printf.)

THE VERDICT: fp16 IS WRONG, AND THE TWO SYMPTOMS ARE TWO DIFFERENT BUGS
================================================================================
With working instruments, the benchmark kernel finally reports:

    BENCH 256 256 256 ... median_us=500072
      C[0][0]=-2.07349e-33 ref 510
      C[0][1]=0            ref 510
    MMA_WRONG

(The reference is sane: C[0][0] = sum over kk<256 of (kk%5)*(kk%3), which is ~510.)

Running the SIMPLE fp16 kernel — rung 02's, no prefetch and no ring — separates the symptoms
cleanly:

    BENCH 64 64 64  148.271 GFLOPS  median_us=3.536
      C[0][0]=64 ref 125     C[0][1]=60 ref 125
      C[0][2]=62 ref 128     C[0][3]=64 ref 125
    MMA_WRONG

So:

  A. THE 500 ms IS NOT THE fp16 PATH.  The simple kernel runs in 3.5 MICROSECONDS and reports 148
     GFLOPS.  The constant 500 ms — identical at 256, 512, 4096 and 8192, which was never a
     measurement of anything — belongs to the BENCHMARK kernel specifically, i.e. to its
     prefetch / register-ring pipeline, not to 16-bit MMA.  That is a separate bug and probably a
     GPU fault being reset, given the fixed duration.

  B. THE SIMPLE KERNEL IS WRONG BY ABOUT HALF.  64 vs 125, 60 vs 125, 62 vs 128, 64 vs 125 —
     ratios 0.48 to 0.51.  Not garbage, not scrambled: roughly half the contraction.  That is the
     signature of BUG 040 ("%mma-k-steps silently truncated to ONE native K-step and the MMA
     computed HALF the dot product"), which is encouraging in that it is a known shape of bug, and
     suspicious in that Phase C changed exactly how K-steps are counted.

REGRESSION after all of Phase D: 1028/1028 E2E, 218/218 negative, 291/291 unit.  The hoist changes
touch every HOIST-EXPECT spec, so this was not optional.

NEXT
  - chase (B) first: it is in the core MMA path, it is the thing rung 02 asserts, and it is now
    measurable on hardware.  Prime suspect is the interaction between the K-step count and the
    per-fragment walk at K=16, i.e. Phase C part 3.
  - then (A), the benchmark kernel's 500 ms.
  - rung 04 (on-metal fp16) should be written once (B) is fixed, so the suite pins this on
    hardware rather than only in the emitted types.


PHASE E — fp16 IS CORRECT ON HARDWARE.  TWO MORE LAYERS HAD THE ELEMENT TYPE WRONG.
================================================================================
2026-08-23.

THE HALF-CONTRACTION, AND HOW THE ARITHMETIC PROVED IT
--------------------------------------------------------
Rather than reason about the %5 / %3 fill pattern, the operands were temporarily set to ALL ONES.
That makes the result equal the NUMBER OF CONTRACTED TERMS, so a partial contraction is readable
straight off the output:

    K=16    correct 16    got 16   (correct)
    K=32    correct 32    got 16
    K=64    correct 64    got 32
    K=128   correct 128   got 64

One K-step was exact; beyond that, half the terms vanished.  The cause was in the tile ADDRESS:

    %coop_elem_ptr = getelementptr float, ptr addrspace(1) %coop_base, i64 %coop_flat

%coop-tensor-ptr+stride computed a correct flat ELEMENT index and then indexed it with a hardcoded
`float`.  On a 2-byte tensor that scales every offset by 4 bytes instead of 2, so each tile after
the first starts at TWICE its intended element offset.  The STRIDE operand is passed separately and
was already right, which is exactly why the first tile of every kernel read perfectly and nothing
looked wrong until a K-loop took a second step.

The prediction is quantitative, which is what makes it a cause rather than a candidate.  For an
8xK operand, the tile at step k should start at element 16k but starts at 32k; a tile whose last
element (base + 7K + 15) exceeds the allocation reads past the buffer and contributes nothing:

    K=16    bases 0                  1 of 1 in bounds  -> 16     measured 16
    K=32    bases 0,32               1 of 2            -> 16     measured 16
    K=64    bases 0,32,64,96         2 of 4            -> 32     measured 32
    K=128   bases 0,32,...,224       4 of 8            -> 64     measured 64

Four predictions, four matches.

WHY NO EXISTING TEST COULD HAVE CAUGHT IT.  Every kernel in the tree was f32 until this endeavour,
and for f32 the hardcoded type is the CORRECT one — the bug is exactly zero-cost at 32 bits.  No
amount of f32 testing could find it, and no .spv-reading validator could either: the emitted TYPES
were already right by this point, and types are all such a validator can see.  It took running a
16-bit kernel on hardware.  That is the case for rung 04.

RESULT: the simple fp16 kernel is MMA_CORRECT on an Arc B580 at K = 16, 32, 64, 128 and 256, with
the real deterministic fill (not the all-ones diagnostic).  **fp16 MMA works on Intel.**

THE 500 ms, AND WHY A PREFETCH WAS NEVER HARMLESS
---------------------------------------------------
The benchmark kernel still took a constant 500 ms at every size and still returned garbage, while
the simple kernel — same MMA path — ran in 3.5 MICROSECONDS.  The difference between them is
prefetch and the register ring.

%block-prefetch emitted Subgroup2DBlockPrefetchINTEL with ElementSize hardcoded to 4 bytes and
MemoryPitch as leading-dim * 4.  On a 16-bit tensor both are double the truth, so the surface
handed to the driver is twice as wide as the data and runs off the end of the allocation.

Its own docstring calls it "a fire-and-forget L1 cache hint... never changes data".  That is true
of a VALID prefetch.  An invalid one is a memory access like any other — and a constant 500 ms
independent of problem size, with garbage output, is the signature of a GPU fault and reset rather
than of slow work.

COUNTING THE LAYERS.  The element type has now had to be threaded through, each invisible to the
one above it:
    1. the analyzer                              (Phase 1)
    2. the coop-matrix TYPE in codegen           (Phase B)
    3. the instruction SHAPE                     (Phase C)
    4. the tile ADDRESS (getelementptr)          (Phase E)
    5. the PREFETCH surface                      (Phase E)
    6. the host FILL and host REFERENCE          (Phase D)
Every one of them was a hardcoded f32 that had been correct for as long as Crisp only ever ran
f32 kernels.  The lesson is not that any single one was careless — it is that "the element type is
float" had been a safe assumption everywhere, so it was made everywhere, and the first non-f32
kernel had to find each site the hard way.

ONE MORE SITE: A PREFETCH NODE HAS NO MATRIX TO ASK
-----------------------------------------------------
Fixing %block-prefetch's ElementSize was not enough, and the emitted IR said why.  Counting GEPs
by element type after that fix:

    20 getelementptr float, ptr addrspace(1) %coop_base
    18 getelementptr half,  ptr addrspace(1) %coop_base

18 half is right for the A/B loads.  20 float is 8 C-tile stores (correct — C really is f32) plus
12 PREFETCHES of the very tensors that had just been loaded as half.  The totals had to add up,
and 20 was too many; that arithmetic is what located it.

Two causes, both about a prefetch not being a matrix:
  - %coop-node-elem answered from the node's own (coop-matrix ELEM ...) type, falling back to the
    VALUE node for a :store.  A :prefetch node has NEITHER — it names a tensor and a region and
    produces no matrix — so it fell through to FLOAT.  It now asks the TENSOR, which is the same
    source %coop-elem-of uses on the analysis side.
  - the :store and :prefetch branches call %coop-tensor-ptr+stride through a SHORTER argument form
    than :load does, so the earlier edit — which matched on the :load call's layout — reached only
    one of the three sites.  A reminder that "replace the call" is not one edit when the same
    function is called three ways.

Final: 8 float GEPs (the C stores) and 30 half (18 loads + 12 prefetches).


RESULTS ON AN ARC B580
================================================================================
The 500 ms constant is GONE — it was the faulting prefetch all along.  fp16, precision=fast:

    N                512     1024     2048     4096     8192
    Crisp fp16     15.84    39.79    41.85    34.39    26.91   TFLOPS
    SYCL control    7.48    15.35    17.71    17.80    15.23
    oneMKL fp16    40.97    75.09    88.48   110.75   111.38
    vs control      2.12x    2.59x    2.36x    1.93x    1.77x
    vs oneMKL         39%      53%      47%      31%      24%

So Crisp's first working fp16 kernel peaks at ~42 TFLOPS, beats the hand-written SYCL
joint_matrix control by roughly 2x across the range, and reaches a quarter to a half of oneMKL.
It has not been tuned for fp16 at all — it is the tf32 top kernel with the element type changed —
so the shape of the curve (peak at 2048, falling away after) is the obvious next thing to look at,
not a settled result.


RESTORING VERIFICATION IMMEDIATELY CAUGHT A REAL BUG — IN THE TF32 KERNEL
================================================================================
fp16 verifies CORRECT at N >= 512 and WRONG at N = 128 and 256.  Before attributing that to fp16,
the same test was run on the TF32 top kernel, which has been shipping numbers for months:

    tf32   N=128  MMA_WRONG      N=256  MMA_WRONG      N=512  MMA_CORRECT     N=1024  MMA_CORRECT
    fp16   N=128  MMA_WRONG      N=256  MMA_WRONG      N=512  MMA_CORRECT     N=1024  MMA_CORRECT

Identical.  So this is NOT an fp16 defect: the sec2_top prefetch-pipeline kernel family computes
the wrong answer at N <= 256, on both element types, and has done so for as long as it has
existed.  It was invisible because endeavour 150 disabled host verification whenever --mma-bench
was passed, and every benchmark sweep passes it.

THE PUBLISHED tf32 LADDER INCLUDES N=256.  That row has been reporting a kernel that computes the
wrong answer.  The sweep now drops it correctly (matmul.py sees NOT MMA_CORRECT and skips the
point), which is why the fp16 table above starts at 512.

This is the whole argument for verification being on by default: it took one run to surface a
defect that had survived every benchmark since 150.  Cause unknown so far — the prologue
prefetches two K-steps ahead and the tile cover is 32x32, so small N is where the pipeline has
fewest steps to hide an off-by-one; that is a hypothesis, not a diagnosis.

STATUS
  - fp16 MMA is CORRECT on Intel at every size the tf32 kernel is correct at, and roughly 2x the
    SYCL control.  [[the 6-layer element-type sweep is complete]]
  - OPEN: sec2_top family wrong at N <= 256, BOTH element types.  Pre-existing, now visible.
  - OPEN: rung 04 (on-metal fp16 spec) — the whole point being that the emitted TYPES were correct
    while the ADDRESS was not, and only hardware could tell the difference.
  - OPEN: report.py has no fp16 section; do not add one until N<=256 is understood, or the table
    will silently start at 512 with no explanation of why.


PHASE F — A RETRACTION: THE "N <= 256 KERNEL BUG" WAS IN THE VERIFIER
================================================================================
2026-08-23.

RETRACTED.  Phase E recorded that "the sec2_top prefetch-pipeline kernel family computes the wrong
answer at N <= 256, on both element types, and has done so for as long as it has existed", and
that "the published tf32 ladder includes N=256 — that row has been reporting a kernel that computes
the wrong answer."

BOTH KERNELS ARE CORRECT AT EVERY SIZE.  The defect was in the host reference that had just been
re-enabled.

    tf32 top   N=128 MMA_CORRECT  N=256 MMA_CORRECT  N=512 MMA_CORRECT  N=1024 MMA_CORRECT
    fp16 top   N=128 MMA_CORRECT  N=256 MMA_CORRECT  N=512 MMA_CORRECT  N=1024 MMA_CORRECT

WHAT WAS ACTUALLY WRONG.  The reference block calls itself "stride-agnostic", and it is — for A
and B, which it indexes with their real strides.  For C it was not:

    memcpy(host_c_buf, c_ptr, chk_m * chk_n * sizeof(float));   // a flat 64*64 prefix
    float got = host_c_buf[i*chk_n + j];                        // indexed as if C were 64 wide

C is N wide, so flat offset i*64+j is C[(i*64+j)/N][(i*64+j)%N].  At N=128, i=1, j=0 that is
C[0][64], compared against a reference computed for (1,0).  For EVERY row after the first, at
EVERY N > 64, the check read a different element than the one it had computed a reference for.
Fixed by copying chk_m WHOLE ROWS and indexing by C's own strides.

WHY IT IMITATED A KERNEL BUG SO WELL — the part worth remembering.  With the deterministic %5 / %3
fill, C is very nearly uniform: it varies only with (row mod 5, col mod 3).  So reading the wrong
element produced a SMALL error, about 6 absolute, roughly independent of N.  Against the 1%
relative tolerance that yields:

    N=128    248 vs 255    2.7%   FAIL
    N=256    510 vs 516    1.2%   FAIL
    N=512   ~1030          0.6%   PASSES — just as wrong, silently
    N=1024                 0.3%   PASSES

A clean monotone story — "it breaks below 512" — produced entirely by a fixed error crossing a
relative threshold.  Both element types failed identically, which I read as strong evidence the
fault was shared and therefore in the kernel family.  It was shared because it was in the
INSTRUMENT they shared.

THE STEP THAT ACTUALLY SETTLED IT was the all-ones fill.  With A = B = 1 the result equals the
number of contracted terms, and it was CORRECT at 128, 256, 512 and 1024.  That proved the term
count was right at every size — and, on reflection, that an all-ones C is UNIFORM, so a misindexed
read is indistinguishable from a correct one.  The test that exonerated the kernel is precisely
the test that is blind to this class of verifier bug; it was the DISAGREEMENT between all-ones
(pass) and %5/%3 (fail) that located the problem, not either result alone.

METHOD NOTE.  This is the second time in this endeavour that a confident causal claim about the
compiler turned out to be about the harness (the first: "--mma-bench drops the reference because
rank is not recoverable" — it was an overlay explicitly disabling it).  Both times the giveaway was
available earlier than I used it: a symptom that is identical across two independent element types,
or two independent kernels, is more likely to live in what they share than in each of them.

STANDING CORRECTED, THE PHASE D/E RESULTS ARE UNCHANGED IN SUBSTANCE:
  - the six element-type layers were all real compiler bugs, all still fixed;
  - fp16 MMA is correct on Intel;
  - --mma-bench really was suppressing verification since endeavour 150, and that really did mean
    no benchmarked kernel was verified — the fix simply did not reveal what I first thought it had.

CRISP fp16 ON AN ARC B580 — THE COMPLETE LADDER
================================================================================
With the verifier fixed, the sweep runs every size and skips nothing.  precision=fast:

    N                 256      512     1024     2048     4096     8192    16384
    Crisp fp16       4.82    15.84    39.79    42.05    34.13    26.78       --
    SYCL control     2.02     7.50    15.28    17.64    17.81    15.24    10.88
    oneMKL fp16      9.78    40.97    75.09    89.05   110.68   111.72   110.67
    vs control      2.39x    2.11x    2.60x    2.38x    1.92x    1.76x
    vs oneMKL         49%      39%      53%      47%      31%      24%

Every Crisp point is MMA_CORRECT — verified against a host reference on the same run, which is
newly true for benchmark mode (see Phase D).

READING THESE HONESTLY
  - Crisp beats the hand-written SYCL joint_matrix control at every size, by 1.8x to 2.6x.  That
    is the PEER-class comparison and it is a genuine result.
  - Against oneMKL the curve is the story: 47-53% in the middle, falling to 24% at 8192.  oneMKL
    keeps climbing to ~111 TFLOPS and holds it; Crisp peaks at 42 TFLOPS at N=2048 and then
    DECLINES.  A kernel that gets slower as the problem grows is not merely untuned — it is losing
    something structural (cache behaviour, occupancy, or the prefetch distance being wrong for the
    working-set size).  That falloff, not the peak, is where the next performance work is.
  - This kernel has had NO fp16 tuning whatsoever.  It is the tf32 top kernel with the element
    type changed: same 32x32 output tile, same ring depth of 2, same prefetch distance of 2
    K-steps.  Those were tuned for 32-bit operands, and at 16 bits every one of them describes a
    different amount of data.  The tile is now half the bytes; the prefetch reaches half as far in
    bytes; the register budget per fragment halved.  There is no reason to expect the tf32 optimum
    to be the fp16 optimum, and 16384 was not even reached before the sweep's growth guard stopped
    it.
  - 16384 is absent because the sweep stopped after 8192; the peers ran it.  Not a failure, but
    the ladder is incomplete at the top end and should not be presented as if Crisp declined to
    compete there.

FOR CONTEXT, the tf32 top kernel on the same part peaks at 16.33 TFLOPS (N=4096) against oneMKL
tf32's 14.31 — i.e. Crisp BEATS the vendor library in tf32 and reaches a quarter to a half of it
in fp16.  The gap is not in Crisp's MMA lowering, which is now correct and shape-optimal; it is in
everything around the MMA at 16 bits.
