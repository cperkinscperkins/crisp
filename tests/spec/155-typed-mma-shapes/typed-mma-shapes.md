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
