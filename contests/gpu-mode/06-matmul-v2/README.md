# GPU MODE matmul_v2 (#540) -- Crisp entry

`c = a @ b`, fp16 in and out, `a` (M K) and `b` (K N) row-major.  Scored case (kernelbot ranks the LAST
benchmark only): **4096 x 5120 x 4096**.  Compiler work for this entry: endeavour 196
(`tests/spec/196-matmul-contest/matmul-contest.md`).

## Correctness is bit-exact

`eval.py` checks every benchmark input too, at rtol 1e-5: with outputs near 1024 that is an exact fp16
match against cuBLAS.  The probe (`put_temp_files_here/matmul_probe/exact_probe.py`) found
tensor-core accumulation in K order (`mma.sync` m16n8k16, f32 accumulate, round-to-nearest store)
matches cuBLAS **exactly** on H100, A100 and L4, while an IEEE fp32 FMA loop misses 3.7-7% of outputs by
one ulp.  So every kernel here is a tensor-core kernel with no split-K -- including the small-shape one.

## Files

| file | GPU | what |
|---|---|---|
| `matmul_h100_2wg_deep.crisp` | H100 | the benchmark suite's best fp16 kernel: two consumer warpgroups (128x256 tile), wgmma m64n256k16, 4-deep TMA ring, warp-specialized producer; `(store-tile-at (to-half D) ...)` |
| `matmul_b200_tma_mma.crisp` | (unused) | Ch4: TMA-fed register-resident `mma.sync` for B200 -- never ran (every B200 job timed out); v3 uses the 4-warp cp.async kernel there |
| `matmul_ampere_cp_async.crisp` | (v1) | 1-warp 64x64 Ch4 with the Ampere `cp.async` load-tile, 16-byte chunks (endeavour 196 (b)) |
| `matmul_small_mma.crisp` | all | shapes the fast kernels cannot tile (the 32x512x32 test ...) |
| `matmul_beauty.crisp` | all | the beauty entry: the small kernel, alone |
| `package_matmul.py` | | compiles, reads the launch ABI from the CUDA hoist, writes the submissions, submits |
| `build_diag_h100.py`, `build_diag_h100_mc.py`, `build_diag_ampere.py` | | per-arm timing diagnostics (write `diag_*_sub.py`; submit with `--mode test`, the table comes back as the error) |
| `submit.sh FILE GPU MODE LOG` | | popcorn submit that waits out the 6-tests/hour rate limit |
| `transpose_b.crisp` | (v2/v3) | B (K N) -> (N K) for wgmma: 39 us, vs 160 us for torch's `b.t()` copy; v4 needs none |
| `matmul_h100_2wg_transb.crisp` | (v4) | 2wg_deep with B staged (K N), `:b-major :mn` wgmma (transB) |
| `matmul_h100_2wg_tma.crisp` | H100 | the v5 kernel: transB + both accumulator stores `:via :tma` (stmatrix + TMA store, endeavour 199) |
| `matmul_ampere_4w.crisp` | A100, L4, B200 | the v3 kernel: 128x128 register tile over a 2x2 warp grid |
| `matmul_h100_2wg_mc.crisp` | H100 | TMA-multicast variant -- correct, slower (366 vs 309 us); not used |

## Packaging (why this one is different)

The other contests turn PTX into an inline `asm` block.  A TMA kernel takes 65 parameters and `asm` takes
30 operands, so this submission loads the PTX through the CUDA driver API (`dlopen("libcuda.so.1")`,
`cuModuleLoadDataEx`, `cuLaunchKernel`).  The launch ABI -- parameter order, scratch-ring literals,
tensor-map encodings -- is read out of the generated CUDA hoist, never hardcoded.  `CU_JIT_THREADS_PER_BLOCK`
stands in for `__launch_bounds__` (without it the 288-thread wgmma block could not launch).

The contest's `b` is (K N) N-contiguous.  Up to v3 the H100 path transposed it into a persistent (N K)
buffer for a K-major wgmma (39 us).  v4 reads it as given: `matmul_h100_2wg_transb.crisp` stages B as a
(K N) tile and passes `:b-major :mn` (endeavour 198, `tests/spec/198-wgmma-transb/`).

## Usage

```
python package_matmul.py                               # build crisp_matmul_v5.py and crisp_matmul_beauty.py
python package_matmul.py crisp_matmul_v5.py H100 test  # build, then submit one
python build_diag_h100.py                              # writes diag_h100_sub.py
```

`crisp_matmul_v1.py` .. `crisp_matmul_v4.py` are the submissions as ranked / benchmarked; `build_all` no
longer regenerates them.  v4 = the transB kernel on H100, and the 4-warp kernel with packed stores
(endeavour 197) everywhere else.  v5 = v4 with the H100 kernel's epilogue through stmatrix + TMA stores
(endeavour 199: 255.5 -> 228.0 us at the scored case, bit-exact; diag 968483, test 968484).

## Results (2026-10-28, ranked)

| GPU | submission | public us | rank | #1 us |
|---|---|---:|---|---:|
| H100 | `crisp_matmul_v5.py` (968487) | 229.8 (secret 228.7) | 29 / 43 | 205 |
| A100 | `crisp_matmul_v3.py` | 4961.6 | 59 / 60 | 596 |
| L4 | `crisp_matmul_v3.py` | 7117.0 | 25 / 25 | 1990 |
| B200 | -- | -- | every job (ours and a pure-torch probe) hit the runner's hard timeout | 92 |

B200, 2026-11-11 (the queue works again): `crisp_matmul_v6.py` -- tcgen05, tensor-memory accumulator, after a
transpose of b -- leaderboard 970691: 265.4 us, 48 / 53.  Diag (`build_diag_b200.py`, scored case):
transpose 33.8 + kernel 226.3 us; cuBLAS 139.3.  **`crisp_matmul_v7.py`** reads b as given with
`:b-major :mn` (endeavour 213, `matmul_b200_tcgen05_mn.crisp`): leaderboard 970696 **230.2 us**, every
benchmark exact; rank 48 / 53 (#47 is 201 us, median 114, #1 92).  The rest of the gap is 2-SM MMA
(`cta_group::2`) + persistent / cluster scheduling, which Crisp does not have.
Tried and rejected: v7 with the epilogue `:via :tma` (`matmul_b200_tcgen05_mn_tma.crisp`,
`build_diag_b200_v7.py`): 234.5 vs 228.4 us at the scored case, 1295 vs 867 us at 8192^3 -- the 17 KB of
staging (115712 B per workgroup) likely leaves one workgroup per SM where v7 keeps two.

A100 / L4, 2026-11-11: the 4-warp kernel's K tile per cp.async stage, one A100 runner
(`build_diag_ampere_k.py`): K16 4880 / K32 4223 / K64 6007 us at the scored case (2048 case: 695 / 725 /
1027), all exact; cuBLAS 611.  v8 = v7 with K32 (`matmul_ampere_4w_k32.crisp`): L4 leaderboard 970705
**6661.9 us** (v3 7117), A100 970704 5171 us -- worse than v5's 4863 on the board, so v5 stays there.
**The A100 / L4 lever is `ldmatrix`:** the mma.sync fragments come from shared memory as ~2.3 sixteen-bit
`ld.shared` per `mma.sync` (src/mma.lisp: "ldmatrix is a later perf optimization").  `ldmatrix.x4`
(`.trans` for the row-major B) loads four fragment registers per instruction -- an endeavour in the core
mma.sync lowering, for Chris to scope.

**v10 (endeavour 216, 2026-11-12): ldmatrix + a cp.async ring.**  The fragments now come from shared memory
by `ldmatrix.x4` (A) / `ldmatrix.x2.trans` (the (K N) B), and `matmul_ampere_4w_ring.crisp` stages A / B in
3-slot rings.  A100 twin A/B (970853): scored shape 4204 -> 3032 us; ring 2898 us (970856).  Leaderboard
970869: **A100 3555.3 us** (v5 4863; the board's runner was an SXM4, slower than diag 2's PCIe).  L4: the ring
measured 4355 us vs v8's 6662 (970860), but three L4 submissions (970865, 970866, 970870) hit GPU MODE's hard
timeout (a 4th, 970880, too; a torch.matmul control 970884 squeaked in at 1510 s -- queue congestion), so v10 is
not yet on the L4 board.  Next lever: bank conflicts (tests/spec/216-ldmatrix/ldmatrix.md,
D-216-5).

**B200 scored-shape study (2026-11-11, popcorn B200 diags; endeavour 214's 2-SM pair parked).**  Where
v7's 226 us goes, measured by removing or reshaping one thing at a time (all arms exact unless noted):
| probe (diag) | 4096 x 5120 x 4096 | 9472 x 2048 x 4096 | 8192^3 |
|---|---:|---:|---:|
| v7 | 226 | 161 | 872 |
| persistent, 296 CTAs (2 / SM) (970760) | 219 | 156 | 889 |
| 128 x 128 tile, ring 2, 3 CTAs / SM (`make_n128.py`; 970754) | 208 | 182 | 1042 |
| v7, epilogue stores REMOVED (wrong output; timing only; 970761) | 147.5 | 110.6 | 764 |
| v7, epilogue stores as `st.global.v4.b32` (hand-edited PTX, `pair_probe/make_wide_stores.py`; 970762) | 171.0 | **119.9** | **787.5** |
| 128 x 128 + `v4` stores (970762) | **150.5** | 148.6 | 992 |
| cuBLAS | 118 | 95 | 674 |

- **The epilogue was a third of the scored time** (78 of 226 us), not bandwidth (C is 42 MB, ~5 us of
  HBM): the tcgen05 32x32b layout gives a thread a whole row, and it left as 128 4-byte stores per thread,
  each warp instruction touching 32 rows.  16-byte stores take 55 us of the 78 back.  `v8` (32 B, one
  sector) needs PTX 8.8 -- not in the CUDA 12.8 ptxas used here.
- The scored shape also wants the 128 x 128 tile (2.16 waves of 128 x 256 tiles -> 2.88 of 128 x 128 at
  3 CTAs / SM); full-wave shapes want 128 x 256.
- Persistence is worth ~3% at K = 4096, nothing at 8192.
- Hand-edited PTX is not submitted: an entry is compiler output.  The compiler change became endeavour
  215 (tests/spec/215-tcgen05-vector-stores/): 16-byte tcgen05 epilogue stores, compiler-built v7 175.1 us
  and 128 x 128 152.6 us (diag 970772, exact, fallback arms forced and exact too).

**v9** (`crisp_matmul_v9.py`, endeavour 215; `build_all` now builds only v9 + beauty, v6-v8 are kept as
submitted): v8's dispatch, the B200 choosing 128 x 256 (`matmul_b200_tcgen05_mn.crisp`) or 128 x 128
(`matmul_b200_tcgen05_mn_128.crisp`) by wave fill.  B200 leaderboard 970774: **156.1 us**, rank **41 / 53**
(v7 230.2, 48).  The board labels the score a geomean of the benchmarks.


Beauty entry (`crisp_matmul_beauty.py`), H100 benchmark: 86.0 ms.  Full report: `../REPORT-matmul_v2.md`.
