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
