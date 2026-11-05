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
- **Not yet run on metal.**  B200 and B300 were out of stock on RunPod (secure and community,
  CUDA 12.8-13.0) at 09:32 on 2026-11-05.  No pod was created.
  - The batch is built locally (`put_temp_files_here/208/metal/`): a bf16 `mma.sync` control, specs
    01-03 as `--mma-test` harnesses, and the hardware-profile query.  The pod only runs nvcc.
  - Run it with:
    `./scripts/pod-session.sh --gpu "NVIDIA B200" --image cu128 --max-minutes 25 -- bash -c 'put_temp_files_here/208/metal/on-pod.sh {host} {port}'`
    The ceiling is $3.33.

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
- The `tcgen05.ld` shape to use for the epilogue (`32x32b.xN` is the natural one for M=128).
