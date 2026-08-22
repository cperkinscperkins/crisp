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
cannot address them at all.  There is no NVIDIA bf16 section in the report whatsoever — not
attempted, not skipped.

And it is worse than "not implemented": `benchmarks/results/` holds **SEVEN**
`sec2_top_bf16_Crisp_*.json` files and **every one has `results: []`**.  The kernel is being
attempted, repeatedly, and producing nothing.  Whatever is wrong fails quietly enough that six
re-runs did not make it obvious.

That is the whole case.  Every other item below is real but smaller.

---

## The core problem: `:mma-shapes` is not typed

`def-hardware-profile` carries `:mma-shapes` as a bare list of `(M N K)` triples — see
`src/hardware-profile.lisp` (`*hardware-profile-schema*`) and the builtin profiles in
`src/mma.lisp`:

```lisp
:mma-shapes ((8 16 8))                      ; bmg   — XMX tf32
:mma-shapes ((16 8 8) (16 8 4) (16 8 16))   ; h100  — tf32 / and NOT tf32
```

A shape triple alone cannot say **what element type it is a shape FOR**, and the native shape
differs by type on both vendors.  So a profile cannot currently express "this device does
`(8 16 16)` in bf16 and `(8 16 8)` in tf32", and `%check-mma-shape` has no type to validate
against.  That is the gap this endeavour closes.

Note the h100 list already mixes tf32 and non-tf32 shapes with no way to tell them apart —
so the untyped form is not merely incomplete, it is already ambiguous.

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

## Phase 0 — diagnose before designing  (DO THIS FIRST)

Seven empty result files mean the current failure is not understood.  Before touching the
profile schema, establish:

1. Does `benchmarks/matmul/sec2_top_bf16/matmul_bmg_bf16.crisp` **compile**?  To what?
2. Does its harness (`matmul_bmg_bf16_bench_l0`) **run**, and what does it print?
3. Is the empty `results: []` a compile failure, a run failure, or a parse failure in the driver?

It is entirely possible the answer changes the shape of this endeavour — e.g. if bf16 lowers
but the DPAS shape is wrong, that is a narrower fix than a schema change.  **Do not assume the
schema is the blocker until the current failure is named.**

---

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
