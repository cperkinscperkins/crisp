# Endeavour 208: tcgen05 (Blackwell tensor cores)

**Status: APPROVED 2026-11-05.**  D-208-1 to D-208-8 confirmed by Chris.  Q1 decided as (b): a declared scale layout
that the host provides and the hoist matches.  Q2: metal testing on RunPod via `pod-session.sh`.

**Progress.**
- **Phase 0 done:** `isa-notes.md`, plus the CUDA 12.8 image for `ptxas -arch=sm_100a`.
- **Phase 1 built in the overlays, and compile-verified:**
  - spec 01 passes its PTX validator, and ptxas accepts the module (42 registers, no spills);
  - errors/01-07 pass, and each hits its own message (checked by hand);
  - errors/04 and errors/06 are positive-controlled.
- **Specs 02 and 03 compile, pass their validators, and ptxas accepts them:**
  - 02 is a K loop with per-tile re-init over 2 CTAs;
  - 03 is warp-specialized with the producer FIRST, so the issuer is lane 0 of warp 1.
- **Spec 04 (the asynchronous three-role pipeline: `:on-complete`, `tcgen05-commit`) compiles, and
  ptxas accepts it.**  It has exactly two commits and no compiler-owned mbarrier.  It needed the
  VOID-branch fix below.
- **Suites (2026-11-05):** E2E 1777/1777, negative 477/477, unit 392/392.
  - The first E2E run failed 13 193-logging-output metal specs.  My let pre-pass copied every let
    body, so die / log sites lost their file:line and printed `?:0`.
  - The pre-pass now returns the same conses when it rewrites nothing.  193 is 25/25 again.
- **IR corpus:** 2309 existing jobs are byte-identical to the 207 fold's `after/`.  The only
  differences are metacrisp paths, and one transient Windows temp-file error, re-run identical.
- **ON METAL, 2026-11-05 10:53: every kernel MMA_CORRECT on an NVIDIA B200** (RunPod secure,
  driver 595.91, CUDA 12.8, compute capability 10.0).
  - The batch: the bf16 `mma.sync` control (c0), specs 01-07 (t1-t7), and the hardware-profile
    query.
  - The C buffers hold the real sums.  The harness decoded bf16 A/B (and the bf16 C of spec 06)
    rather than raw bits.
  - The first two rentals that morning were wasted by my on-pod script, about a minute each.  The
    archive's Windows uid failed `tar`'s chown, and `nvcc` is not on PATH in a non-interactive ssh
    shell.  Both are fixed in `put_temp_files_here/208/metal/`.
  - The queried profile is `benchmarks/profiles/b200.crisp`: 148 SMs, 227 KB opt-in shared memory,
    126 MB L2.  Pass it with `--hardware-profile=b200 benchmarks/profiles/b200.crisp`.
  - Earlier that morning (09:32) B200 and B300 were out of stock everywhere; the 10:50 retry found
    one at once.
  - The batch is built locally (`put_temp_files_here/208/metal/`): a bf16 `mma.sync` control, specs
    01-03 as `--mma-test` harnesses, and the hardware-profile query.  The pod only runs nvcc.
  - Run it with:
    `./scripts/pod-session.sh --gpu "NVIDIA B200" --image cu128 --max-minutes 25 -- bash -c 'put_temp_files_here/208/metal/on-pod.sh {host} {port}'`
    The ceiling is $3.33.

## Phase 4: block-scaled microfloats (APPROVED 2026-11-05)

**Chris approved** D-208-10/11 (a matrix of a block type is its codes; scales are a separate tensor tied by
`scale-layout`), D-208-16 (the `(*! w w)` refusal stays; the plan is corrected), and the deferrals.

- **D-208-17 `matrix-multiply-tile-stride` accepts a tcgen05 accumulator** (added after Chris asked).
  - Before this, the macro failed: it reads the tile shape with `(extents~ C-tile)`, which a tcgen05
    accumulator does not have.  Its reset for a non-register tile is `fill-tile` + a workgroup sync,
    which is wrong for tensor memory.
  - Now the tile shape comes from the accumulator's (M N).  The per-tile reset is the re-initialisation
    `(%tcgen05-reset D)`, which costs nothing because the first MMA overwrites.
  - It covers the synchronous form.  A warp-specialized pipeline splits the K loop between roles, so it
    stays `tile-stride` + `with-warp-specialization`, as on Hopper.
  - Spec 12.  Its PTX is instruction-identical to spec 02's hand-written loop.  MMA_CORRECT on a B200
    (16:03).

**Built (2026-11-05):**
- **The source rewrite**, at `visit-toplevel-form`, before pass 1 so scratch sizes and TMA descriptors
  are right:
  - `(make-scratch-matrix BLOCK (R K))` becomes a uchar codes tile `(R K/epb)` plus a hidden
    `X--SCALES` tile of 512-byte atoms.  The scales tile is rounded to whole KB, because the hoist packs
    tiles back to back and the next 128-byte-swizzled codes tile needs 1024-byte alignment.
  - `load-tile .. :scales S` becomes `(%208-load-scales ..)`, then the codes load.
  - The accumulate gains hidden `:%block` / `:%sf` options.
  - The `scale-layout` declarations are parsed and checked here too.
- **The scale copy** runs from the TMA load's own elected thread, in program order before the codes
  load's `arrive.expect_tx`: `mbarrier.expect_tx` for the scale bytes, then one `cp.async.bulk` per
  128-row block.
- **The MMA** issues `tcgen05.cp.32x128b.warpx4` per scale atom into scale columns assigned per site,
  then four block-scaled MMAs.  Each instruction has its own descriptor (its SF_ID).
- **PTX ISA 8.7** (`-mattr=+ptx87`) is raised only for modules holding `.block_scale`, as 204 does with
  +ptx84.
- **Metadata:** a `:microfloat` entry on the block matrix and on its scales.  The CUDA harness sizes,
  fills and TMA-describes codes in bytes, and builds a `:blocked-128x4` scales vector.  Its reference
  decodes fp4 / e4m3 / e5m2 with ue4m3 / ue8m0 scales.
- **ON METAL 2026-11-05 16:03 (B200), MMA_CORRECT:**
  - 13 NVFP4, 14 MXFP4, 15 MXFP8-e4m3 and 17 MXFP8-e5m2 (128 x 128 x K);
  - p1, NVFP4 at N = 256;
  - q2, the three roles on one tile;
  - the controls (spec 01 and spec 12).

  So the tcgen05.cp descriptor's LBO = 0 reading was right, and so is D-206-3's low-nibble-first fp4
  order: the hardware decodes it that way.
- **Spec 16, the pipelined NVFP4 kernel, MMA_CORRECT on a B200 (16:23, 256 x 512 x 1024), on a 4-slot
  ring.**
  - On 3 slots it faulted ("unspecified launch failure").  The cause is **BUG 156**, a pre-existing
    ring hazard, not anything block-scaled.
  - A ring await takes its parity from its own visit count, lap = visit div ring-count.  The slot is
    `(mod grid-k R)`, and grid-k restarts every tile.  So once a CTA does a second tile with
    steps-per-tile not a multiple of R, the await waits on the wrong phase.
  - Seven probes isolated it (`put_temp_files_here/208/p4/probes`):
    - **pass:** single tile at N = 256; roles on one tile; 2 K-steps on one tile; one tile at
      coordinates (1, 1);
    - **fault:** several tiles per CTA, with or without `:on-complete`, on one CTA or two;
    - **confirmation:** the same kernels pass on ring 4 (4 steps) and ring 1.

    Every earlier pipelined spec used 8 steps on 4 slots.  compute-sanitizer timed out and gave
    nothing.

- **Error specs:** errors/15-22 cover:
  - a load without `:scales`;
  - an undeclared or unknown scale layout;
  - a block with no kind;
  - mixed blocks;
  - a tile that is not one atom;
  - an int accumulator;
  - a declare naming a non-parameter.

  Each is spec 13 with one change, so spec 13 is their positive control.
- **Suites (2026-11-05):** E2E 1805/1805, negative 492/492, unit 392/392.  The 208 directory passes 39/39,
  with and without `--differentiate`.  IR corpus: 2310 existing jobs identical; the 4 differences are
  metacrisp paths and the 17 new jobs are the 208 specs.

**Found along the way (for review):**
- **D-208-18: uchar scratch was sized at 4 bytes per element** by the CUDA hoist.  Its width table
  knew `uchar`, but not `unsigned char`, which is `crisp-type-to-cpp-type`'s spelling.  This is
  pre-existing, and only a waste until a block-scaled ring asked for 648 KB.  Fixed in the hoist
  overlay.
- **D-208-19: an analysis-time error can be masked** by "Type Resolution: FAILED to instantiate struct
  TENSOR_UCHAR_2_LOCAL_COMPACT_LAST".
  - Pass 1's analysis of the body stops at the error, before the rewritten uchar scratch tile's
    struct is instantiated.
  - Pass 2 then builds the kernel's LLVM function type first, and fails on it.
  - This is general to scratch types first reached after an early error.  For 208, every block rule
    with literal inputs moved to rewrite time (errors/16, 19, 21 now give their own messages).
- **An SBCL derived-type trap, twice.**  An overlay copy compiled before phase 3's
  `(declaim (ftype .. %208-mma-kind))` checked the old 3- or 4-character return type.  Calling it
  through a captured function object resurfaced "i8" in the built executable, but not in-process.
  Fixed by a fresh `%208-gen-mma-plain`, called by name.

## Phase 4 proposal: block-scaled microfloats (as approved, 2026-11-05)

**What the hardware does.**  The multiply reads fp4 / fp8 codes from shared memory, as before.  It reads
one scale per 16 or 32 K-elements of each row from **tensor memory**: two more address operands.  The
scales reach tensor memory from shared memory by `tcgen05.cp`.  The accumulator is f32.  There are
three kinds, all M = 128 (from the CUTLASS SM100 atoms and the PTX ISA, section 9.7.18.10.7):

| block (206) | kind | scale | per | K / instr | K per 128-byte atom |
|---|---|---|---|---|---|
| `:base fp4 :scale fp8-e4m3 :shape (16)` = **NVFP4** | `mxf4nvf4.block_scale.scale_vec::4X` | ue4m3 | 16 | 64 | 256 |
| `:base fp4 :scale fp8-e8m0 :shape (32)` = **MXFP4** | `mxf4.block_scale.scale_vec::2X` | ue8m0 | 32 | 64 | 256 |
| `:base fp8-e4m3` or `fp8-e5m2` `:scale fp8-e8m0 :shape (32)` = **MXFP8** | `mxf8f6f4.block_scale` (1X) | ue8m0 | 32 | 32 | 128 |

**The scale layout (Q1, decided (b)).**  There is one layout, and it is cuBLASLt's, CUTLASS's
(`Sm1xxBlockScaledBasicChunk`) and torchao's `to_blocked`.  Scales come in 512-byte atoms of 128 rows x 4
scales.  Within an atom, row r and scale c sit at `(r mod 32)*16 + (r div 32)*4 + c`.  Atoms run along
K first, then down the rows.  So a checkpoint's scales, or cuBLASLt's, can be used as they are.

**Proposed surface:**

```lisp
(def-microfloat-block nvfp4 :base fp4 :scale fp8-e4m3 :accum float :shape (16))

(def-type a-mat (matrix nvfp4 :address-space :global :align :compact :contiguous-term :row-major))  ; A's codes, (M K)
(def-type a-scl (vector (scale nvfp4) :address-space :global :align :compact))                     ; A's scales

(def-kernel k (A SA B SB &out C)
  (declare #'(a-mat a-scl b-mat b-scl &out c-mat)
           (scale-layout SA :of A :blocked-128x4)
           (scale-layout SB :of B :blocked-128x4))
  (let ((A-tile (make-scratch-matrix nvfp4 (128 256)))          ; codes AND scales, in shared memory
        (B-tile (make-scratch-matrix nvfp4 (256 256)))
        (D      (make-tcgen05-accumulator float (128 256) 0.0)) ...)
    (load-tile A A-tile (gy gk) :scales SA :barrier bar :swizzle :128b)
    (load-tile B B-tile (gx gk) :scales SB :barrier bar :swizzle :128b)
    (await bar)
    (tcgen05-accumulate-via-tile (128 256 256) D A-tile B-tile :swizzle :128b)
    (store-tile-at (to-bfloat16 D) C (row col) :via :tma)))
```

- **D-208-10 A matrix of a block type is its codes.**  `(matrix nvfp4 ..)` holds the packed codes of an
  (M K) matrix, K-major: an fp4 row of K elements is K/2 bytes, with the even element in the low nibble
  (D-206-3).  The block type carries the format, scale format and block size, so the compiler picks
  the kind and checks everything from one name.  That way codes cannot be paired with the wrong
  scales' format.
- **D-208-11 The scales are a separate kernel tensor**, as in 206, where codes and scales are two
  handles.  `(scale-layout SA :of A :blocked-128x4)` is the declare Q1 asked for.  It names the layout and
  ties SA to A's extents.  The hoist sizes, fills and documents SA from it.  `:blocked-128x4` is the only
  layout offered.  A's rows must be a multiple of 128 and its K a multiple of 4 blocks (the atom).
  Other extents are refused when they are compile-time constants, and the host must pad otherwise,
  as cuBLASLt's does.
- **D-208-12 A scratch tile of a block type holds codes and scales.**  `load-tile .. :scales SA`
  TMA-loads the codes (128-byte swizzle, as today) and bulk-copies the tile's scale atoms.  They are
  contiguous in this layout: a 128 x 256 NVFP4 tile is 4 atoms, 2 KB.  Both arrive on the same
  barrier.
- **D-208-13 The compiler stages the scales into tensor memory.**  Just before the multiplies, the
  issuing thread runs `tcgen05.cp.32x128b.warpx4` from the tile's scale atoms into scale columns that
  the compiler assigns beside the accumulators.  They count toward the 512: an NVFP4 128 x 256 x 256
  step takes 16 + 16 columns.  The author writes nothing for it.
- **D-208-14 K per call is one 128-byte atom of codes**: 256 for fp4, 128 for fp8.  This matches every
  earlier kind.
- **D-208-15 Forward-only**, as D-208-8 (SKIP-WITH).
- **D-208-16 206's refusal of `(*! w w)` stays.**  The plan said this phase would replace it.  But
  `*!` is a 1-D product of two blocks, while tcgen05 is a tile multiply.  Tiles are the MMA surface
  here, as for every other element type.  I propose correcting the plan, not adding a 1-D MMA path.
- **Not in this phase:**
  - NVFP4's per-tensor fp32 global scale (D-206-9 deferred it).  An epilogue multiply would carry it.
  - fp6 (e2m3 / e3m2), which 206 has no format for.
  - Mixed formats such as e4m3 x e5m2.  These are allowed by `mxf8f6f4`, and are easy to add later.
- **Metal.**  The CUDA harness fills the codes and the scales in the blocked layout.  Its reference is
  built from 206's decode, in C.  An MMA_CORRECT therefore also checks D-206-3's nibble order against
  the hardware.

**Steps:**
1. ISA ground truth: the tensor-memory scale layout and the `tcgen05.cp` descriptor.
2. fp4 / fp8 scratch tiles and TMA.
3. The scale load and copy.
4. The three kinds.
5. Error specs.
6. The harness.
7. One B200 rental.

## Phase 3 (2026-11-05): int8 / qint, built, and MMA_CORRECT on a B200 (specs 08-11)

- **The surface is the other MMA paths' integer surface, unchanged:**
  - `(make-tcgen05-accumulator int (128 N) 0)`, or `(accum Q)`, is an s32 accumulator of N columns.
    The ring takes the same elements.
  - char / uchar operands, or a `def-qint` over them, are `kind::i8` at K = 128: one 128-byte atom,
    four K = 32 instructions.
  - The rules are reused, not copied:
    - 204's `%check-mma-element-family` gives the family, 8-bit operand, 32-bit accumulator and sign
      rules;
    - 207's `%qint-mma-walk` now also sees `make-tcgen05-accumulator(-ring)` bindings and
      `tcgen05-accumulate-via-tile`.
- **The signs live in the instruction descriptor.**  They are not in the mnemonic as on
  `mma.sync` / wgmma.  The descriptor has c_format S32 = 2 and a/b_format INT8 = 1 / UINT8 = 0
  (CUTLASS `UMMA::S8Format`).  Pinned values: s8.s8 at 128 x 128 = 136316064; u8.s8 = 136315936;
  s8.s8 at 128 x 256 = 138413216.
- **The readback:** an s32 accumulator loads into a `TCGEN05-ROW32-S32` record.  It is the same
  `tcgen05.ld`, with the cells kept as int (no bitcast).
  - With no conversion, an element of a derived accumulator (`(accum q-a)`) is raw-cast as it is
    stored.  That is 207's `%store-frag-elem-cast`, the same fix 207 needed on `mma.sync`.
  - `(to-q-out D 1.0)` requantizes through 205's `%to-q-narrow`: scale in f32, clamp to
    [-128, 127], one byte stored.
- **Specs:**
  - 08: char x char.
  - 09: uchar x char.
  - 10: q-act x q-wt into their product, then `to-q-out` as it stores.
  - 11: the three-role pipeline with a 2 x 256-column s32 accumulator ring on `def-qint` operands.
    A ring slot is 16 KB + 32 KB, so 4 slots take 192 KB.
  - errors/09-14: half into int, K = 64, another qint's accumulator, signed into uint, a char
    accumulator, `to-q` with `:via :tma`.
  - errors/11 and errors/14 are positive-controlled.  14 is caught by 199's pass-1 scan, so its
    message says "stmatrix", which tcgen05 does not use.  The fix it names (drop `:via :tma`) is the
    right one.
- **ptxas accepts 08-11.**  Spec 11 uses 108 registers, with no spills.
- **Suites:** E2E 1791/1791, negative 484/484, unit 392/392.  The 208 specs pass `--differentiate`
  25/25 (by SKIP-WITH).
  - The first E2E run failed 08 and 11 on my validators.  The dealloc operand is a register, and
    `", 128;"` also matches an address add.  Corrected copies are appended, and the code was unchanged.
- **IR corpus:** 2310 existing jobs are byte-identical to the 207 fold's `after/`.  The 4 differences
  are metacrisp source paths, and the 11 new jobs are the 208 specs.  The shared change (207's qint
  walk now also names the tcgen05 forms) is inert elsewhere.
- **ON METAL, 2026-11-05 13:59: every kernel MMA_CORRECT on an NVIDIA B200** on the first attempt
  (driver 595.91, CUDA 12.8).
  - The batch was 207's int8 `mma.sync` control (c3) plus specs 08-11.  The harnesses were
    nvcc-checked locally (`build3.sh`) before renting.
  - The pod ran for about 50 seconds, and was confirmed gone.
  - The integer compare is exact.  A is offset from zero (char straddles zero; uchar sits at
    200..204), so an output left untouched or a swapped sign format cannot pass.
- **For the fold:** `%208-mma-kind` is appended twice in phase 3, with a `declaim ftype` between.
  SBCL had kept the phase-2 copy's derived return type (a 3- or 4-character string) and rejected
  "i8" at run time.  In src there is one definition, so the declaim is dropped.

## Phase 2 (2026-11-05): built, and MMA_CORRECT on a B200 (specs 05-07)

- **tf32:** `kind::tf32` with float operands and K = 32 (one 128-byte atom, four K = 8 MMAs).  The
  descriptor's a/b_format is TF32 = 2.  It gives the same precision warning as wgmma.  Spec 07.
- **Accumulator ring:**
  - `(make-tcgen05-accumulator-ring float (128 256) :ring-count 2)` takes R x N columns;
    `(ring-get ACC s)` is a FRESH accumulator at column base + s*N.
  - With two slots the epilogue drains tile t while the MMA warp fills tile t+1.
    `acc-full` / `acc-empty` become 2-slot barrier rings.  Spec 05; the tile counter is a let-bound
    ulong that the kernel advances once per tile.
  - `ring-get` on any other ring is unchanged (it goes to `analyze-ring-get-expression`).
- **`store-tile-at (to-bfloat16 D) C (ROW COL) :via :tma` from tensor memory (spec 06):**
  - It reuses 199's pass-1 descriptor (16 x 64 boxes, SWIZZLE_128B) and the staging buffer as they
    are.
  - A tcgen05 thread owns a whole row, so there is no `stmatrix`.  Per 64-column chunk, each thread:
    loads 64 f32, converts them to bf16x2, writes its 128-byte row into its warp's 4 KB slice
    (chunk j at j ^ (row mod 8)), then lane 0 sends two boxes.
  - The slice is (warp mod slices), so a warpgroup not at warp 0 still gets four distinct slices.
  - errors/08 refuses an unconverted f32 source; its positive control compiles.
- **The harness's reference decodes a 16-bit C too**, compared in float, so spec 06 has a real
  MMA_CORRECT.
- **Not yet built:** M = 64, `:b-major :mn`, a backward (D-208-8), `cta_group::2`.  Int8 was
  phase 3; the block-scaled kinds are phase 4.

## Found along the way (for review)

- **D-208-9: a role body ending in `(signal ..)` broke `with-warp-specialization`.**
  - The lowering nests the role bodies in `if`s, and `ensure-branch-compatibility` treated only
    `nil` as void.  Statement nodes typed with the symbol `VOID` (dotimes, store-tile) counted as a
    real type.  So an epilogue ending in `signal`, which is ULONG, next to a producer ending in
    `dotimes` was refused with "Branch type mismatch in IF".
  - This is pre-existing: no H100 kernel happened to end a role with `signal`.
  - The fix adds two clauses before the error, so `VOID` takes the one-void-branch rule.  It only
    turns an error into acceptance, so nothing that compiled before can change.

## Phase 1 notes

- **The 16-bit `--mma-test` harness was broken, and is fixed in `overlays/hoist-cuda`.**
  - The hoist maps half and bfloat16 to `uint16_t`, so the role fill wrote small integers as raw bit
    patterns, and the reference multiplied those integers.  Every 16-bit MMA_CORRECT / MMA_WRONG was
    about the harness, not the kernel.  That is why no 16-bit wgmma spec ever had a metal check.
  - A 16-bit A / B is now encoded on fill and decoded in the reference.  Other types are unchanged.
- **The Blackwell smem descriptor for a K-major 128B-swizzled tile is wgmma's plus the version bit
  (46).**  The 3-bit layout field's SWIZZLE_128B = 2 at [61,64) is the same bit as wgmma's 1 at [62,64).
- **ptxas accepts `tcgen05.mma` without the disable-output-lane vector.**
- **Static shared memory grows by the TMEM slot and one mbarrier per synchronous site.**  The TMA
  tiles live in dynamic shared memory after it.  wgmma ran on metal with a static mbarrier ahead
  of its swizzled tiles, so this is expected to be fine.  If the first B200 run says MMA_WRONG,
  tile alignment under the 128B swizzle is the first suspect.
- **`with-warp-specialization` role bodies now lower to `(%in-warp-role FIRST COUNT ..)`**, analysed
  as `progn` with the role's warps bound.  That is how the issuing thread (D-208-7) and the epilogue
  rule (D-208-6) know the role.  The backward (ungated) lowering is unchanged.

Goal: native MMA on the B200, for 16-bit floats first, then for the quantized integers of 204/205/207
and the microfloat blocks of 206.  The block multiply that 206 reserved and refused, `(*! w w)`, is
implemented here.  Then benchmark it.

## What tcgen05 is

`tcgen05` is the tensor-core instruction family of datacenter Blackwell: B200 and GB200 are `sm_100a`,
and B300 is `sm_103a`.  Hopper's `wgmma` does not exist on these parts.  Today a B200 kernel falls back
to `mma.sync` (chapters 1 to 6 of the ladder).  Consumer Blackwell (RTX 50, RTX PRO 6000, `sm_120`) has
neither tcgen05 nor tensor memory, and is out of scope.

Three things change from wgmma.

1. **The accumulator lives in tensor memory (TMEM), not registers.**  TMEM is a new 256 KB per-SM
   memory, 128 lanes x 512 columns of 32-bit cells.  A 128x256 f32 accumulator takes 256 columns.
   On H100 the same accumulator costs 128 registers per thread.  That register cost held the
   two-warpgroup kernel to one CTA per SM (see `matmul_2wg_deep.crisp`).  TMEM is allocated by one
   warp (`tcgen05.alloc`, a power of two from 32 to 512 columns) and freed (`tcgen05.dealloc`)
   before the CTA exits.
2. **One thread issues the MMA.**  A single thread issues a 128x256x16 multiply.  The warpgroup does
   not cooperate as it does for wgmma.  A and B are read from shared memory through 64-bit
   descriptors.  These are the same idea as wgmma's, with a different bit layout.
3. **Completion arrives on an mbarrier.**  `tcgen05.commit [bar]` makes `bar` arrive once every MMA
   the thread has issued so far has finished.  That is how the MMA releases a shared-memory ring slot
   straight back to the producer, and how it tells the epilogue the accumulator is ready.

**Reading the result.**  `tcgen05.ld` copies TMEM into registers.  A warp may only touch its own
32-lane quarter of TMEM, chosen by `warp_id % 4`, so the epilogue is one warpgroup.  For a 128-row
accumulator, thread `t` of that warpgroup owns row `t`.

**Kinds.**  The operand type selects the instruction:

| kind | operands | accumulator | K per instruction | Crisp use |
|---|---|---|---|---|
| `kind::tf32` | float (tf32) | f32 | 8 | tf32 ladder |
| `kind::f16` | half, bfloat16 | f32 (or f16) | 16 | 16-bit, phase 1 |
| `kind::i8` | s8 / u8 | s32 | 32 | int8 and qint (204/205/207) |
| `kind::f8f6f4` | e4m3, e5m2, e2m3, e3m2, e2m1 | f32 | 32 | plain fp8, no block scale |
| `kind::mxf8f6f4.block_scale` | the same, plus an e8m0 scale per 32 | f32 | 32 | MXFP8 |
| `kind::mxf4nvf4.block_scale` | e2m1 packed, plus a ue8m0 scale per 32 or a ue4m3 scale per 16 | f32 | 64 | MXFP4, **NVFP4** |

**Block scaling.**  For the block-scaled kinds the scales also live in TMEM (`tcgen05.cp` from shared
memory).  The multiply applies one scale per 16- or 32-element K-block.  That is NVFP4 / MXFP4 / MXFP8
done in hardware: no decode and no emulation.

**Shapes (cta_group::1, one SM).**  M is 64 or 128.  N is a multiple of 8 (M=64) or 16 (M=128), up to
256.  `cta_group::2` pairs two SMs for M=256 and is deferred (see Later).

## Where we stand (checked 2026-11-05)

- The bundled LLVM is 21.1.5.  `llc` accepts `-mcpu=sm_100a` and `+ptx88`.  wgmma is emitted as
  inline asm (`%build-inline-asm-call`), and tcgen05 will be too, so LLVM's intrinsic coverage does not
  matter.
- Ground truth for the bit layouts: `third_party/cutlass/include/cute/arch/mma_sm100_desc.hpp`
  (`InstrDescriptor`, `InstrDescriptorBlockScaled`, `SmemDescriptor`), `mma_sm100_umma.hpp` (the exact
  asm strings), `copy_sm100.hpp` (`tcgen05.ld/st/cp`) and `tmem_allocator_sm100.hpp`.
  - The shared-memory descriptor is NOT wgmma's.  It has a 3-bit layout field at bits 61-63, a
    version field, a base offset and an LBO mode.  Copying the wgmma descriptor builder would compile
    cleanly and compute garbage.
- `ptxas` for `sm_100a` needs CUDA 12.8 or newer.  The local docker image is `nvidia/cuda:12.4.1`, so
  an offline assemble check needs a 12.8 image pulled.
- `scripts/pod-session.sh --image cu128` already targets the B200.  The cached catalog says B200 is
  $7.99/hr secure.  That price is re-queried before any rental.
- There is no B200 hardware profile.  The first rental queries one.
- fp8/fp4 exist only as the formats inside a `def-microfloat-block` (206), not as plain matrix
  element types.

## Proposed surface (decisions D-208-n, for review)

```lisp
(make-tcgen05-accumulator float (128 256) 0.0)        ; D in tensor memory: 256 of the 512 columns

(tcgen05-accumulate-via-tile (128 256 64) D A-tile B-tile
                             :swizzle :128b [:b-major :mn] [:on-complete barrier])

(tcgen05-commit barrier)      ; barrier arrives once every MMA this thread issued has finished

(store-tile-at D C (row col) [:via :tma])             ; tcgen05.ld, then the existing store paths
```

- **D-208-1 Names mirror wgmma.**  `make-tcgen05-accumulator` / `tcgen05-accumulate-via-tile`
  belong to the same tier as `make-wgmma-accumulator` / `wgmma-accumulate-via-tile`: named for the
  instruction, refused on any other target with a message naming the alternative.  A
  backend-neutral MMA spelling is a separate, larger question.  This endeavour does not take it on.
- **D-208-2 Synchronous by default, as wgmma is.**  Without `:on-complete`, the form issues from one
  elected thread, commits to a compiler-owned mbarrier, and every thread executing it waits.  One call
  is a complete `D += A*B`, so a plain kernel works with no warp roles.  With
  `:on-complete barrier`, it commits to that barrier and returns at once.  That is the pipelined
  form: the MMA frees the ring slot it read.
- **D-208-3 `tcgen05-commit` is its own form.**  The end-of-tile signal ("the accumulator is ready")
  covers every MMA of the K loop, not one call.  `commit` has exactly that meaning, so it gets its own
  form rather than a keyword on the last iteration.
- **D-208-4 The compiler owns TMEM.**  It allocates at kernel entry and frees at exit.  The column
  count is the sum of the kernel's tcgen05 accumulators, rounded up to a power of two.  A kernel over
  512 columns is refused, with the count in the message.  The 4-byte TMEM address lives in
  compiler-owned shared memory, the 199 implicit-scratch pattern.  It relinquishes the allocation
  permit right after allocating, so a second CTA on the SM does not stall.
- **D-208-5 Zero init only, at first.**  `tcgen05.mma` has an "ignore D" flag, so the first MMA after
  `(set! D (make-tcgen05-accumulator .. 0.0))` overwrites instead of adding, and TMEM never needs
  clearing.  A non-zero init would need a `tcgen05.st` pass.  It is refused until something needs it.
- **D-208-6 The epilogue is a warpgroup.**  `store-tile-at` on a tcgen05 accumulator must run on 128
  threads, warpgroup-aligned (TMEM's lane restriction).  Anything else is refused.  Each thread owns
  one row, so its stores are contiguous.  `:via :tma` and `to-half` / `to-bfloat16` / `to-q` reuse
  199's and 205's paths.
- **D-208-7 Issuing thread.**  The accumulate elects the first thread of whatever executes it.  In a
  pipelined kernel that is a one-warp `:mma` role of `with-warp-specialization`.
- **D-208-8 Forward-only, for now.**  Specs carry `SKIP-WITH[--differentiate]`.
  - **CORRECTION (2026-11-05):** the proposal said "as with wgmma", which was wrong.  wgmma has
    differentiated since endeavour 146.  The AD normalizer rewrites it to the sync MMA
    (`%ad-canonicalize-wgmma`), so the existing tile VJP supplies the backward.
  - tcgen05 can take the same route later, by canonicalizing the accumulator, the accumulate and
    the TMEM store to the register-tile forms.  That would make the SKIP-WITH a real gap claim.
  - The decision stands for phase 1, but the reason is "not built yet", not "wgmma does the same".
  - The hardware chapter's "wgmma is forward-only" sentence (ch 59, §5) is stale for the same reason.

A sketch of the pipelined kernel (phase 2).  It is not yet compiled; the barrier forms are the
existing ones.

```lisp
(with-warp-specialization (:epilogue 4 :producer 1 :mma 1)     ; 192 threads
  (:mma
    (set! D (make-tcgen05-accumulator float (128 256) 0.0))
    (dotimes (grid-k (/ (to-ulong K) (to-ulong 64)))
      (let ((slot (mod grid-k (to-ulong 4))))
        (await (ring-get full slot))
        (tcgen05-accumulate-via-tile (128 256 64) D (ring-get A-ring slot) (ring-get B-ring slot)
                                     :swizzle :128b :on-complete (ring-get empty slot))))
    (tcgen05-commit acc-full))
  (:producer ...)                       ; the same TMA producer as the H100 kernel
  (:epilogue
    (await acc-full)
    (store-tile-at (to-half D) C (row col) :via :tma)))
```

## Phases

0. **Ground truth.**  A notes file with the descriptor bits, K per kind, the N/M rules, `tcgen05.ld`
   shapes and the alloc rules, taken from the CUTLASS headers and the PTX ISA.  Pull a CUDA 12.8 image,
   so every PTX spec is assembled by `ptxas -arch=sm_100a` locally, at no GPU cost.
1. **Synchronous 16-bit, one CTA.**  The accumulator, the synchronous accumulate, compiler-owned TMEM
   and the direct `store-tile-at`.  Specs:
   - PTX-shape validators (alloc, `kind::f16`, commit, ld, dealloc);
   - ptxas acceptance;
   - error specs (wrong arch, shapes, over 512 columns, store outside a warpgroup, non-zero init).

   **First B200 rental:** MMA_CORRECT on metal, plus a profile query.
2. **The pipeline.**  `:on-complete`, `tcgen05-commit`, the three-role kernel, and two accumulators
   (2 x 256 columns) so the epilogue of one tile overlaps the MMAs of the next.  Also `:via :tma`, and
   `kind::tf32` (the same instruction).  **Metal:** correctness, and first bf16 numbers against cuBLAS.
3. **int8 / qint.**  `kind::i8`, under 207's qint-role rule unchanged.  An s32 accumulator, and a
   requant epilogue via `to-q`.
4. **Block-scaled microfloats.**  The MMA on `def-microfloat-block` operands:
   - NVFP4 is `mxf4nvf4`, scale_vec::4X, ue4m3 per 16;
   - MXFP4 is ue8m0 per 32;
   - MXFP8 is `mxf8f6f4`, scale_vec::1X.

   Scales are staged shared memory -> TMEM with `tcgen05.cp`.  This phase replaces 206's refusal of
   `(*! w w)` on sm_100a.  **Metal:** exact against a host reference built from 206's decode.
5. **Benchmarks.**  A B200 section in REPORT-matmul.md:
   - bf16/fp16 against cuBLAS (and a CUTLASS sm100 peer if it builds in reasonable time);
   - int8 against cuBLASLt;
   - NVFP4 / MXFP4 / MXFP8 against cuBLASLt's block-scaled GEMM.

**Later:** `cta_group::2` (M=256 over an SM pair), A read from TMEM, TMA multicast across the pair,
sparsity, and B300 / `sm_103a`.

## Open questions

- **Q1 The scale layout (decide at phase 4; flagged now because it touches 206).**  The hardware wants
  block scales in a tiled, interleaved layout: 128-row atoms, in the order `tcgen05.cp` reads them.  It
  does not want 206's one-scale-per-block row-major handle.  cuBLASLt makes the host supply that layout.
  The options:
  - (a) the compiler rearranges scales as it stages them;
  - (b) a block declares its scale layout, and the host writes it that way.

  **DECIDED (b)** (Chris, 2026-11-05): a declare names the layout the kernel expects, and the host
  provides it.  The generated hoist code matches it.  The exact layout gets verified in phase 0/4.
- **Q2 Where metal testing happens.  DECIDED: RunPod** (Chris, 2026-11-05).  A B200 rental per phase through `pod-session.sh`, one batched run
  each, at a ceiling of roughly 30 to 60 minutes at the re-queried price.  Or GPU MODE's free B200, if
  it is back.

## Not yet verified (from memory, to be pinned in phase 0)

- K per kind, and the N rules for M=64 vs M=128.
- Whether `kind::i8` exists on `sm_103a` (B300).  It matters only for the Later list.
  **Answered (phase 3):** CUTLASS's `config.hpp` enables `CUTE_ARCH_TCGEN05_S8_MMA_ENABLED` for
  SM100A, SM101A and SM110A, and not for SM103A.  So B300 has no tcgen05 int8.
- The `tcgen05.ld` shape to use for the epilogue (`32x32b.xN` is the natural one for M=128).
