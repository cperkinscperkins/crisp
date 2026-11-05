# tcgen05 ISA notes (endeavour 208, phase 0)

Ground truth for the implementation.  Sources:
- **PTX ISA** (docs.nvidia.com, PTX 9.5 page, §9.7.18), fetched 2026-11-05.  A text copy is in
  `put_temp_files_here/208/ptxisa/ptx.txt`.
- **CUTLASS** `third_party/cutlass/include/cute/arch/`:
  - `mma_sm100_desc.hpp`
  - `mma_sm100_umma.hpp`
  - `copy_sm100.hpp`
  - `tmem_allocator_sm100.hpp`
  - `../../cutlass/arch/barrier.h`

Anything here not marked *(PTX)* or *(CUTLASS)* is inference, and metal is what settles it.

## Targets

- tcgen05 was introduced in PTX ISA **8.6**, on `sm_100a` / `sm_101a` (renamed `sm_110a`).
- The `sm_100f` family needs PTX 8.8.
- Our `llc` (LLVM 21.1.5) takes `-mcpu=sm_100a` and `+ptx86/87/88`.
- ptxas needs CUDA 12.8 or newer.
- Every tcgen05 instruction in a kernel must use the same `.cta_group` *(PTX)*.  We use `::1`
  throughout.

## Tensor memory *(PTX)*

- 128 lanes x 512 columns per CTA, in 32-bit cells.
- An address is 32 bits: **lane in [31:16], column in [15:0]**.  CUTLASS's `DP_b = 1<<21` bits is the
  same thing, 1<<16 in b32 units.
- Allocation:
  - `tcgen05.alloc.cta_group::1.sync.aligned.shared::cta.b32 [smem_dst], nCols;`
  - one whole warp executes it (`.sync.aligned`);
  - nCols is a power of 2 in [32, 512];
  - it **blocks** until the columns are free;
  - it writes the TMEM address into shared memory at `smem_dst`;
  - nCols must not increase between two allocations in one CTA.
- `tcgen05.relinquish_alloc_permit.cta_group::1.sync.aligned;`: no more allocs from this CTA after it.
- `tcgen05.dealloc.cta_group::1.sync.aligned.b32 taddr, nCols;`: everything allocated must be
  deallocated before the kernel exits.
- **Access.**  Warp `w % 4` of a warpgroup may `tcgen05.ld/st` only lanes `32*(w%4) .. +31`.  Every
  column is reachable.

## Shapes, dense, cta_group::1, no .ws *(PTX Table 48)*

| kind | M | N | K |
|---|---|---|---|
| f16 (f16/bf16 -> f16/f32) | 64, 128 | 8..256 step 8 | 16 |
| tf32 (-> f32) | 64, 128 | 8..256 step 8 | 8 |
| f8f6f4 (e4m3 e5m2 e2m3 e3m2 e2m1 -> f16/f32) | 64, 128 | 8..256 step 8 | 32 |
| i8 (s8/u8 -> s32) | 64, 128 | 8, 16, 24, 32, then step 16 to 256 | 32 |
| mxf8f6f4 + ue8m0 scale | **128 only** | 8..256 step 8 | 32 |
| mxf4 (e2m1) + ue8m0 | **128 only** | 8..256 step 8 | 64 |
| mxf4nvf4 (e2m1) + ue8m0 / **ue4m3** / ue5m3 | **128 only** | 8..256 step 8 | 64 |

CUTLASS's TF32 static_assert asks N % 16 for M=128, but the PTX table says step 8.  We follow
the PTX, and metal settles it.  K=96 is `sm_103a` only.

## Accumulator layout in TMEM *(PTX §9.7.18.10.5)*

- **M=128, cta_group::1, "Layout D"** (4x1): row `m` -> lane `m`, column `n` -> column `base+n` for
  f32/s32.  Warp `q` of the epilogue warpgroup reads rows `32q..32q+31`, and thread `t` holds row `t`.
- **M=64, no .ws, "Layout F"**: half the data path, lane alignment 0 or 16.  Phase 1 does not use it.

## The MMA *(PTX syntax, CUTLASS asm)*

```
tcgen05.mma.cta_group::1.kind::f16 [d_tmem], a_desc, b_desc, idesc, {m0,m1,m2,m3}, p_enable_input_d;
```

- One thread issues it; CUTLASS guards it with `elect_one_sync()`.
- `p_enable_input_d` false means D = A*B, ignoring the old D.  That is how init-to-zero costs nothing.
- `{m0..m3}` is the disable-output-lane mask; CUTLASS passes zeros.  The PTX syntax shows it in
  braces, and whether it may be omitted is to be settled by ptxas.
- Block-scaled:
  `tcgen05.mma.cta_group::1.kind::mxf4nvf4.block_scale.scale_vec::4X [d], a_desc, b_desc, idesc, [sfa_tmem], [sfb_tmem], p;`
  - CUTLASS uses `.block16` for NVFP4;
  - `.scale_vec::NX` and `.blockNN` are alternative spellings.

## Instruction descriptor, 32 bits *(CUTLASS `InstrDescriptor`)*

| bits | field |
|---|---|
| 0-1 | sparse id2 |
| 2 | sparse flag |
| 3 | saturate (s8 only) |
| 4-5 | **c_format**: 0 f16, 1 f32, 2 s32 |
| 7-9 | **a_format** (f16 kind: 0 f16, 1 bf16, 2 tf32; i8: 0 u8, 1 s8; f8f6f4: 0 e4m3, 1 e5m2, 3 e2m3, 4 e3m2, 5 e2m1) |
| 10-12 | **b_format** (same codes) |
| 13 / 14 | negate A / B |
| 15 | **a_major**: 0 K-major, 1 MN-major |
| 16 | **b_major** (MN-major only for 16-bit, e4m3/e5m2, int8) |
| 17-22 | **N >> 3** |
| 24-28 | **M >> 4** |
| 29 | k_size (0 except mxf8f6f4 K64) |
| 30-31 | max shift (.ws only) |

The block-scaled form (`InstrDescriptorBlockScaled`) differs:
- bits 4-5 are **b_sf_id**;
- bit 23 is **scale_format** (0 ue4m3, 1 ue8m0);
- bits 29-30 are **a_sf_id**;
- bit 31 is k_size;
- the c_format bits are gone (D is f32).

CUTLASS passes the idesc as a 64-bit "idescE" with the descriptor in the upper 32 bits.  The asm
operand is the 32-bit `uint32_t(idescE >> 32)`.

## Shared-memory descriptor, 64 bits *(CUTLASS `SmemDescriptor`, sm100)*

**This is not wgmma's descriptor.**

| bits | field |
|---|---|
| 0-13 | start address >> 4 |
| 16-29 | leading byte offset >> 4 (LBO) |
| 32-45 | stride byte offset >> 4 (SBO) |
| 46-47 | **version = 1** (Blackwell) |
| 49-51 | base offset (0 when the tile is 1024-B aligned under swizzle) |
| 52 | LBO mode (0 = relative offset) |
| 61-63 | **layout**: 0 none, 1 128B_BASE32B, 2 128B, 4 64B, 6 32B |

K-major with 128B swizzle has the canonical layout `Swizzle<3,4,3> o ((8,n),2):((8T,SBO),1)`:
- SBO is the byte stride between 8-row groups (1024 for a dense 128-byte-wide tile);
- LBO is unused, and conventionally 1;
- stepping K inside the swizzle atom adds `k_bytes >> 4` to the start address, as on wgmma.

## Completion and ordering *(PTX §9.7.18.6)*

- `tcgen05.commit.cta_group::1.mbarrier::arrive::one.shared::cluster.b64 [mbar];` makes the mbarrier
  arrive (count 1) once **all prior async tcgen05 ops of this thread** complete.  It implies
  `fence::before_thread_sync`.
- **MMA -> epilogue** (different threads):
  `mma; commit [bar]` || `try_wait [bar]; tcgen05.fence::after_thread_sync; tcgen05.ld; tcgen05.wait::ld`.
- **Epilogue -> next MMA into the same TMEM**:
  `tcgen05.ld; tcgen05.wait::ld; tcgen05.fence::before_thread_sync; mbarrier.arrive` ||
  `try_wait; tcgen05.fence::after_thread_sync; mma`.
- **Producer TMA -> MMA**: the mbarrier is enough.  Shared-memory reads by `tcgen05.mma` go through
  the async proxy, so data written by **generic** stores (not TMA) needs `fence.proxy.async`
  before the MMA reads it.
- **Alloc -> others**: alloc writes the address to shared memory, which is a weak store.  The rest
  of the CTA needs `tcgen05.fence::before_thread_sync; bar.sync; tcgen05.fence::after_thread_sync`
  before reading it.  That is the CUTLASS pattern.

## TMEM -> registers

- `tcgen05.ld.sync.aligned.32x32b.xN.b32 {r0..r(N-1)}, [taddr];` gives each thread N consecutive
  columns of its lane.  N is in {1, 2, 4, ..., 128}.
- `tcgen05.wait::ld.sync.aligned;` must come before the registers are used for memory ordering.
- `.pack::16b` packs two 16-bit columns into one register.
