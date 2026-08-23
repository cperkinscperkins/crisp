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
