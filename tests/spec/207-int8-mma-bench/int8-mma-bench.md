# Endeavour 207 — int8 MMA benchmark lane (+ sync `mma.sync` int8 for A100 / Ada)

Started 2026-11-03, late evening.  Chris went to bed after scoping it; decisions are made and logged
here (D-207-n) for review.

## Status at a glance (2026-11-04, morning)

Every number below is exact against the integer oracle (max_abs_err 0).

| Target | Crisp int8 | Peer | Crisp / peer @8192 |
|---|---|---|---|
| BMG (Arc B580), XMX | **193 TOPS** | oneMKL 223 (oneDNN 226) | **87%** (89% @4096) |
| H100 SXM, wgmma | **1136 TOPS** | cuBLASLt 1415 | **80%** (105% @2048) |
| H100, requantize to s8 | 1139 TOPS | cuBLASLt 1664 | 68% |
| A100 SXM, mma.sync | 56 TOPS | cuBLASLt 353 | 15% -- the kernel is untuned (Next 1) |

- `mma.sync` int8 is BUILT and PROVEN on an A100 (specs 03/04; 01-04 also pass on H100).
- Local: unit 82/82, E2E 1759/1759, negative 465/465, and the 207 specs pass under `--differentiate`
  (01/02 declare the integer-MMA refusal).  The first full E2E run's SBCL process segfaulted AT EXIT
  (rc 139) after printing 1759/1759; the identical re-run exited 0 with 1759/1759.  Not reproduced.
- Nothing is committed; overlays are unfolded.  New decisions: D-207-1..8.  Open items: Next 1-7.

## Scope (agreed with Chris)

- A **slim lane**, not a ladder: one top int8 kernel per backend, plus epilogue variants, plus peers.
- **`mma.sync` int8 is IN** (A100 / Ada).  204 refused it only because the per-lane layouts could not be
  proven without hardware; the pod script (2026-11-03) removes that obstacle.  Abort if it turns ugly.
- Microfloat blocks are NOT benchmarked yet: they decode to half before an ordinary MMA, so a number
  would measure the decode.  They belong with B200 `tcgen05`.

## Contract

`C[M x N] (s32) = A[M x K] (s8) . B[K x N] (s8)`.  Exact integer oracle (the fixture fill is 0..4 / 0..2,
so every C is an exact small integer; no tolerance).  Report TOPS (2·M·N·K / t), not TFLOPS.

Epilogue variants (the quantization-specific part):
1. raw s32 out — the MMA alone;
2. requantize to s8 — `to-q acc multiplier`, saturating — int8-to-int8 layers;
3. dequantize to fp16 with per-row x per-column scales — the realistic W8A8 output.

## Plan

| Phase | What | Where it runs |
|---|---|---|
| A | BMG int8 top kernel (port of `sec2_top_fp16/matmul_bmg_fp16.crisp`), L0 fixture learns `s8`/`s32` | BMG, local |
| B | Typed (`def-qint`) vs plain `char` kernel: SPIR-V/PTX identical? | local compile |
| C | H100 int8 wgmma kernel (port of the fp16 wgmma top), CUDA fixture learns `s8`/`s32` | H100 pod |
| D | `mma.sync.m16n8k32` int8 lowering (TDD specs here), metal-verified | A100 / Ada pod |
| E | Epilogue variants 2 and 3 | BMG + pods |
| F | Peers: oneDNN (BMG), cuBLASLt + CUTLASS s8 (H100/A100) | BMG + pods |

## Decisions (D-207-n, for review)

1. **D-207-1 — an int8 operand register tile could not be zero-filled (a bug, fixed).**
   `(make-register-tile char (256 32) 0 :operand :a)` emitted `@__spirv_CompositeConstruct_0_8_32(i32 0)`
   against a declaration taking `i8`, and llvm-spirv refused the module ("Can't translate function
   pointer").  `%coop-coerce-scalar` resized floats but not integers.  It now truncates / sign-extends
   integer literals (overlay, `src/codegen.lisp`).  204 never hit it: its specs fed A and B straight
   from global memory.
2. **D-207-2 — `prefetch-tile :warp-partitioned` accepts 1-byte elements, in 32x32 blocks.**  It refused
   them by design (the legal block shape is width-dependent and an illegal one fails at module build).
   The legal 8-bit shapes were established OFFLINE with `ocloc -device bmg` in the bench image: height
   <= 32 and width <= 64 build; 64x32, 256x32 and 32x128 fail.  32x32 keeps the 32-byte row of the
   16-bit 32x16.  The probe was negative-controlled (it does fail the known-bad 256x32).  `ocloc` is a
   cheap legality oracle for any future 2D-block question -- no GPU needed.
3. **D-207-3 — the Intel int8 peer is oneDNN, not oneMKL.**  ~~oneMKL's integer GEMM is a CPU
   routine.~~  **WRONG, corrected 2026-11-04 (Chris caught it).**  oneMKL 2025.3's SYCL interface
   declares `gemm<int8_t,int8_t,int32_t,float>` and `gemm_bias` for all four sign pairs, and both run
   on the BMG GPU, exact: `sec2_top_int8/onemkl_int8.cpp` measured 124 / 158 / 207 / 222 TOPS (gemm)
   and 122 / 156 / 206 / 221 (gemm_bias) at 1024..8192 against oneDNN's 126 / 160 / 207 / 225 -- the
   same kernel family, within noise.  The claim was asserted, never checked.  Proposed: oneMKL
   becomes the Ceiling (as in every other Intel table) and oneDNN a reference row.

4. **D-207-4 — `mma.sync` int8 (m16n8k32) is built** (overlay, `src/mma.lisp`): s8/u8 A and B
   records (the SIGN is in the record name, since char and uchar are both LLVM i8), an s32
   accumulator record, the PTX ISA m16n8k32 lane tables (the 16-bit tables with K doubled), a packed
   `<4 x i8>`-to-i32 emitter, and `(16 8 32)` in the h100 profile and in the generated NVIDIA profile.
   All four NVVM spellings were checked with `llc -mcpu=sm_80`.  A uint tile is refused (mma.sync
   accumulates s32).  204/errors/04 now expects the SHAPE refusal ((16 8 8) is not the int8 shape).
5. **D-207-5 — the NVIDIA benchmark arch is detected** (`nvidia-smi compute_cap`), no longer `sm_90`
   everywhere in `matmul.py`.  Needed for A100 / Ada now and B200 later.
6. **D-207-6 — `tests/ci-stop.txt` moves to `207-int8-mma-bench`.**
8. **D-207-8 — two derived-type gaps in register-tile kernels, fixed** (overlay, `src/mma.lisp`), found
   by writing the BMG kernel with `def-qint` types: (a) `%register-tile-elems-from-bindings` dropped
   any element that was not a symbol, so an `(accum q-a)` tile read back as FLOAT inside the
   tile-stride macro; (b) `%coop-elem-of` returned `Q-A` for a q-a operand while the q-a register tile
   was `(coop-matrix CHAR ..)`.  Spec 05 runs the typed path on BMG: MMA_CORRECT, exact.
   **The types cost nothing:** the typed K64 benchmark kernel and its plain char/int twin have
   IDENTICAL SPIR-V instruction streams (0 differences once OpName / linkage names, which carry the
   type name, are set aside; 32 MulAdds each) -- `put_temp_files_here/207/typed/compare.sh`.  This is
   a script, not a unit test: unit tests compile in-process to LLVM IR without a SPIR-V target.
7. **D-207-7 — pods get this working tree by TARBALL** (`put_temp_files_here/207/pod-prep.sh`): clone
   `origin/main`, then extract every file that differs from it.  Nothing is pushed.

## Pod sessions (pre-rental notes, per CLAUDE.md)

- **A100 (2026-11-04, ~01:00):** `put_temp_files_here/207/nv-session.sh` -- 207 specs on metal (03/04
  are the first ever proof of the m16n8k32 lane layout), 204 as regression, then the sec2_top_int8
  lane (Crisp sync int8 + cuBLASLt) at 1024-8192.  A100 SXM/PCIe secure $1.79/hr, `--max-minutes 75`,
  ceiling $2.24.  Wasted if: the pod build fails for an environmental reason.  NOT wasted if 03/04
  fail -- that is the question being asked.

- **A100, attempt 1:** died in prep (tar as root could not chown to the Windows uid).  Pod released
  in 40 s, ~$0.02.  **Attempt 2:** ran, but `run-on-pod.sh` / `bench-on-pod.sh` `git stash` before
  pulling, which dropped every shipped TRACKED edit (ci-stop -> 0 specs, stock matmul.py).  ~$0.15.
  Fixed by committing the shipped tree inside the pod's own clone (D-207-7).  **Attempt 3** (~8 min,
  ~$0.25): **specs 01-04 PASS on A100** -- the m16n8k32 lane layout is proven on metal, s8 x s8 and
  u8 x s8 (the u8 buffer holds 200..204, so a signed misread would have shown).  The Crisp sync kernel
  was skipped: the QUERIED profile (`scripts/hw-profile/query-cuda.cu`) did not list `(16 8 32)`;
  fixed.  cuBLASLt int8 ran (below).
- **H100 + A100 (2026-11-04, ~00:45), in parallel:** H100: 207 specs, 204 regression (`RUN_204=1`),
  `sec2_top_int8` + `sec4_int8_requant`.  SXM $3.99/hr (fallback NVL / PCIe), `--max-minutes 80`,
  ceiling $5.32.  A100: `SKIP_SPECS=1`, `sec2_top_int8` only, `--max-minutes 60`, ceiling $1.79.
  Wasted if: a harness edit fails to build on the pod (all .cu files were compile-checked locally in
  `nvidia/cuda:12.4.1-devel`, and all Crisp PTX was assembled with `ptxas`).

## Findings

- **`:xe-native` lowering is 16-bit only** ("supports bfloat16 and half operands only").  The fp16
  winner uses it; the int8 lane runs the cooperative-matrix lowering.  Not pursued (yet).
- **H100 SXM (2026-11-04), TOPS, every point exact.**  Specs: 207 6/6 (the sync int8 kernels pass on
  Hopper too), 204 15/15 (no regression in the integer paths 207 touched).

  | N | **Crisp** (wgmma, 2 consumer WGs, 4-deep TMA ring) | Crisp `mma.sync` (1 warp, ch.5 geometry) | cuBLASLt IMMA (TN) | Crisp / cuBLASLt |
  |---|---|---|---|---|
  | 1024 | 132.7 | 27.1 | 183.9 | 72% |
  | 2048 | **577.2** | 50.7 | 549.5 | **105%** |
  | 4096 | 1019.5 | 80.0 | 1338.8 | 76% |
  | 8192 | **1136.0** | 92.8 | 1415.3 | **80%** |

  The wgmma int8 kernel is the fp16 2-warpgroup kernel with types swapped and K 128 per stage; no
  int8-specific tuning was done; the epilogue is the plain s32 store (197's packed-store and 199's
  stmatrix+TMA work are 16-bit paths).
- **H100 SXM, epilogue variant 2 -- REQUANTIZE** (`sec4_int8_requant`): C (s8) = sat8(rne(acc x 0.003)).
  Both contenders are verified against one oracle (exact accumulator, fp32 multiply, nearest-even,
  saturate; `common/fill_verify.h requant_s8`), and both match it EXACTLY at every point:

  | N | Crisp (`store-tile-at (to-q-a D m)`) | cuBLASLt (s8 out, float alpha) | Crisp / cuBLASLt |
  |---|---|---|---|
  | 1024 | 94.0 | 191.2 | 49% |
  | 2048 | 442.6 | 715.8 | 62% |
  | 4096 | 800.1 | 1511.2 | 53% |
  | 8192 | 1138.8 | 1663.8 | 68% |

  cuBLASLt gets FASTER with an s8 output (1664 vs its 1415 at s32: a quarter of the store bytes).
  Crisp does not: its narrowing store is 128 `st.global.b8` per thread (unpacked), the same shape as
  the scalar-b16 epilogue that cost fp16 23% before 197.  Packing four narrowed bytes into one 32-bit
  store is the obvious fix, and 197's `%pair-ok-p` / `%store-pair` is the precedent.
- **A100 SXM (2026-11-04), TOPS, every point exact:**

  | N | Crisp `mma.sync` (1 warp, ch.5 geometry) | cuBLASLt IMMA (TN) |
  |---|---|---|
  | 1024 | 16.5 | 93.3 |
  | 2048 | 31.9 | 230.3 |
  | 4096 | 42.0 | 330.9 |
  | 8192 | 53.7 | 353.2 |

  15% of cuBLASLt.  The kernel is chapter 5's ONE-warp-per-64x64 geometry: 255 registers with a 224-byte
  spill, and the `:linear` (cp.async) ring's `wait_group 0` drains every stage, so nothing overlaps.
  It proves the instruction, not the schedule.  An 8-warp variant (128x128, 32x64 per warp, 12-byte
  spill instead of 224) measured WORSE: 19.4 / 29.7 / 36.6 / 37.6.  So the spill is not the bottleneck.
  **The likely one is the operand loads:** each m16n8k32 is fed by 24 `ld.shared.b8` + 6 `prmt`
  (load-fragment-a/-b read one BYTE per element and the emitter packs them).  Every operand register
  holds four K-adjacent bytes, which are contiguous in shared memory (A row-major, B col-major), so a
  single `ld.shared.b32` per register -- or `ldmatrix` -- would cut the load count 4x.  That is a
  codegen change to the fragment loads, proposed rather than made (see Next).
- **BMG, final (2026-11-04, Docker, Arc B580), TOPS, every point exact (max_abs_err 0):**

  | N | **Crisp** (K64 + 1-byte prefetch) | K32 | K128 | no prefetch | oneDNN s8s8s32 | Crisp / oneDNN |
  |---|---|---|---|---|---|---|
  | 1024 | 112.8 | 110.4 | 94.7 | 113.5 | 125.9 | 90% |
  | 2048 | 132.4 | 131.4 | 108.2 | 115.0 | 159.6 | 83% |
  | 4096 | 183.3 | 175.3 | 135.6 | 123.6 | 206.6 | 89% |
  | 8192 | **193.3** | 167.6 | 138.8 | 127.7 | 224.8 | **86%** |

  The 1-byte warp-partitioned prefetch (D-207-2) is worth +51% at 8192 (127.7 -> 193.3).  K64 beats
  K32 by 15% at 8192; K128 spills (640 GRF/thread estimated) and loses.  oneDNN reaches ~96% of the
  B580's 233 TOPS int8 spec, so the remaining gap is real, and is the same shape as fp16's (where
  `:xe-native` closed most of it -- and `:xe-native` is 16-bit only today).
- **First BMG numbers, no prefetch (2026-11-03, Docker), all exact (max_abs_err 0):**

  | N | Crisp int8 (no prefetch) | oneDNN int8 |
  |---|---|---|
  | 1024 | 108.1 TOPS | 125.9 |
  | 2048 | 103.3 | 159.5 |
  | 4096 | 115.5 | 208.1 |
  | 8192 | 115.7 | 224.7 |

## Next (proposed, not started -- each wants Chris's go)

1. **Packed int8 operand loads for `mma.sync`** (one `ld.shared.b32` per register, or `ldmatrix`).  The
   A100 sync kernel is at 15% of cuBLASLt and the evidence points at 24 byte loads per MMA, not spills.
2. **Packed narrowing store** for `store-tile-at (to-q D m)`: four s8 per 32-bit store.  Requantize is
   at 53-68% of cuBLASLt; plain s32 is at 76-80%.
3. **`:xe-native` int8** on BMG.  It closed most of fp16's gap to the peer; it is 16-bit only today.
   BMG int8 is at 86-89% of oneDNN at 4096-8192 without it.
4. **SPIR-V int epilogues** (narrow / dequantize in the register tile).  Today a narrowing on BMG is a
   second pass through global memory (D-205-1), so epilogue variants 2 and 3 are not measured there.
5. **Epilogue variant 3, dequantize to fp16 with per-row x per-column scales** -- not built anywhere.
6. ~~A def-qint SCRATCH RING is sized at 4 bytes per element.~~  **FIXED 2026-11-04** (Chris's go) --
   see "Follow-up, 2026-11-04" below.
7. ~~Plain `char` operands with an `(accum q-a)` accumulator are accepted.~~  **DECIDED 2026-11-04:
   ACCEPT** (Chris), and the qint-role rule at the MMA built -- see "qint roles at the MMA" below.

## Follow-up, 2026-11-04 (with Chris)

- **oneMKL is the Intel int8 Ceiling** (D-207-3 corrected): `sec2_top_int8/onemkl_int8.cpp`
  (`gemm<s8,s8,s32,float>`; `bias` argv selects `gemm_bias`), wired into `matmul.py` as `OneMKL_INT8`.
  oneDNN stays as a reference row.
- **Scratch-ring width fixed** (overlay, `src/metadata.lisp` `generate-implicit-signature`).  ONE root
  cause for the profile check AND the CUDA hoist: endeavour 202 put derived numeric types through
  `%host-visible-type` in the declared signature and the tensor-map entries, but not in the implicit
  scratch entries, so the metacrisp said `(tensor q-a 3 :local ..)` and every width table (they match
  primitive NAMES) fell through to 4.  Both consumers read this one function.  Verified by hand:
  the q-a-ring requant kernel's hoist now requests 196608 bytes (was 786432; char twin 196608), the
  metacrisp says `(tensor char 3 :local ..)`, the profile check passes, and a double-depth negative
  control is refused at exactly 393216.  The kernel itself was never wrong: its entry PTX is
  identical to the char twin's once register / block numbering is normalised.  Pinned by
  `errors/02-qint-ring-width.crisp` (the refusal message must say 262144, not 1048576).
  The bench kernel keeps its char rings until item 7 is decided.
- **Report** (`scripts/crisp_bench/report.py`):
  - §2 gains `int8` (all three GPUs) and `int8→s8` (H100) tables via the shared top-section emitter,
    with two opt-in knobs:
    - `slim` drops the Control / Peer columns the lane does not have;
    - `crisp_reject` keeps Hopper's `mma.sync` builds out of the Crisp envelope.  They are a
      different instruction, so they get a reference row instead.
  - `ceil_name` labels the column cuBLASLt, not cuBLAS.
  - A GPU with no data for a section no longer gets an empty table (the int8-only A100 printed three
    grids of dashes).
  - Two superseded BMG configs (`Crisp_V_k64`, `Crisp_V_pf3`, from before K64 became the base) moved
    to `benchmarks/results/scratch/`.
  - A before/after render diff shows nothing else changed.

### qint roles at the MMA (2026-11-04, with Chris)

Chris chose ACCEPT for plain operands into an `(accum q-a)`.  Checking the rest of the space turned up
that the tile MMA path enforced NO qint rule at all: `q-a` operands into `(accum q-b)`, `q-a x q-b` with
no product, and `q-a` operands into a plain `int` all compiled.  Scalar code refuses all three.  The
element types `%check-mma-element-family` sees are the LOWERED ones (q-a is already char there).

**The rule** (Chris approved): only qint operands count, and plain bytes are untyped.
- Both plain: any 32-bit integer accumulator.
- One qint `T`: the accumulator must be `(accum T)`.
- Two different qints: a `def-qint-product` is required, and the accumulator is `(accum T U)`.

**Built** (overlay, `src/mma.lisp`):
- `%check-mma-qint-roles` reuses the scalar code's own registry (`qint-role`, `accum-type-of`,
  `%accum-key`).
- `%qint-mma-walk` runs it from `analyze-let-with-tile-explosion`, BEFORE tile explosion.  That is the
  one point where the tile, scratch and accumulator constructors, kernel parameters (via ENV) and the
  C tile's name are all still visible.  It covers `mma-accumulate-via-tile`, `wgmma-accumulate` and
  `wgmma-accumulate-via-tile`.  An operand it cannot resolve is skipped: a missed refusal is a gap, a
  false one would break a valid kernel.
- Messages name types as the author wrote them (`(accum q-a)`, not `q-a-accum`).

**Specs:**
- `06-plain-operands-qint-acc-bmg` pins the accept (MMA_CORRECT on BMG).
- `errors/03`..`06` pin the refusals: register-tile, no-product, plain-int on the sync scratch route,
  and wgmma.
- Each new error spec was positive-controlled: with the accumulator corrected, it compiles.

**The positive control found four more gaps on the NVIDIA `mma.sync` path with typed operands.**
None is reachable on SPIR-V.  The new message tells authors to write exactly such a kernel, so all four
are fixed in the overlay:
1. `%register-tile-fit-check` called SYMBOL-NAME on the raw `(accum q-a)` form.
2. `analyze-load-fragment-a`/`-b`: the s8 record holds char, and the q-a reads were not cast.  The new
   helpers are `%frag-src-derived-p` and `%frag8-read`; a raw cast is applied only when the source is
   derived.
3. `analyze-store-fragment`: the int fragment elements were stored into q-a-accum uncast
   (`%store-frag-elem-cast`).
4. `%197-pair-elem-bytes` had no width for a derived type, so the typed kernel silently lost 197's
   packed pair store.  It was correct but slower.

After these, `07-sync-int8-qint-ptx`'s kernel has a PTX entry IDENTICAL to its plain char/int twin
(registers and block numbers normalised).  Specs 03 and 04 and both A100 benchmark sync kernels are
byte-identical PTX before and after all four fixes.

### Fold (2026-11-04)

Folded by script (`put_temp_files_here/207-fold/fold.py`: live copies by offset, no capture wrappers).
- 23 defuns replaced in place, 13 new forms in `src/mma.lisp`, and the 3 validators in
  `tests/run-specs.lisp`.
- The `*nvvm-int8-signs*` defvar is placed before the `:around` method that binds it.
- Both overlays are emptied, with their history kept.

**Proof:**
- Clean build: no undefined functions or variables.
- A 2314-job corpus (every non-error spec with its TEST-WITH flags, plus `--differentiate`) is
  byte-identical before and after.  The 74 differing `.metacrisp` files differ only in the corpus
  directory embedded in `:source`.
- `gen-specials` added exactly one global (`*nvvm-int8-signs*`); the specials tail was already empty.

**Suites before the fold:** unit 392/392, negative 470/470, E2E 1766/1766.  One earlier E2E run
segfaulted mid-suite while the 2314-job corpus compiled in parallel.  Its crashing directory
(124-ad-issues) passed alone, and the unloaded full rerun was clean.  This is the same signature as
the exit-time segfault of 2026-11-03.

**Suites after the fold:** unit 392/392, negative 470/470, E2E 1766/1766.  The first post-fold
E2E run segfaulted again, in 176-reduce-multi with nothing heavy alongside; that directory passed
alone and the rerun was clean.  It is now BUG 155 in plan/bugs.md (intermittent, at a different spec
each time).

**Definition of done:** reports rebuilt (`report.py --all`), chapters split, reference.md,
call_graph.md, the globals matrix and specials regenerated, `extract_status.py` run.

## Cost of the pod work

Eight rentals, all released by `scripts/pod-session.sh` and confirmed gone (pods left: none).  Three
were wasted by my own shipping bugs (tar ownership, `git stash` dropping tracked edits, an untracked
directory missing from the list), about $0.30 together.  All told about $1.00, computed from each
session's create-to-gone time x the catalog price (RunPod's billing had not caught up when this was
written).  Every session was under five minutes of pod time.
