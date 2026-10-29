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
| H100 | `crisp_matmul_v4.py` (968463) | 253.7 (secret 255.9) | 36 / 43 | 205 |
| A100 | `crisp_matmul_v3.py` | 4961.6 | 59 / 60 | 596 |
| L4 | `crisp_matmul_v3.py` | 7117.0 | 25 / 25 | 1990 |
| B200 | -- | -- | every job (ours and a pure-torch probe) hit the runner's hard timeout | 92 |

Beauty entry (`crisp_matmul_beauty.py`), H100 benchmark: 86.0 ms.  Full report: `../REPORT-matmul_v2.md`.
