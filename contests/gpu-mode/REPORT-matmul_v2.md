# GPU MODE Contest Report: `matmul_v2`

> Generated from [`results/matmul_v2.json`](results/matmul_v2.json) by `python contests/gpu-mode/report.py --all`. Live leaderboard: [https://www.gpumode.com/leaderboard/540?tab=rankings](https://www.gpumode.com/leaderboard/540?tab=rankings) (Crisp commit `be872d6a`).

**Workload:** C = A @ B with A (M K) and B (K N) row-major fp16, C fp16. task.yml lists 8 benchmarks (128^3 .. 4096x5120x4096); kernelbot ranks by RankCriterion.LAST, so the score is the LAST case only: m=4096 n=5120 k=4096 (171.8 GFLOP). Correctness is checked on the benchmark inputs too at rtol 1e-5: bit-exact fp16 against cuBLAS..

## § 1 — Official Leaderboard Standings

| GPU | Architecture | Rank | Public Score | Secret Score | Achieved BW / TFLOPS | % of #1 (`top1`) | Winning Crisp Kernel | Hardware Profile | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|---|
| **B200** | Blackwell (sm_100) | **#41** / 53 | **156.12 µs** | 154.66 µs | 1100 TFLOPS | 59.0% (`92.10 µs`) | [`crisp_matmul_v9.py`](06-matmul-v2/crisp_matmul_v9.py) ([`.crisp`](06-matmul-v2/matmul_b200_tcgen05_mn_128.crisp)) | `b200` | `2026-11-12 11:52` |
| **H100** | Hopper (sm_90) | **#29** / 44 | **229.79 µs** | 228.67 µs | 748 TFLOPS | 89.2% (`204.96 µs`) | [`crisp_matmul_v5.py`](06-matmul-v2/crisp_matmul_v5.py) ([`.crisp`](06-matmul-v2/matmul_h100_2wg_tma.crisp)) | — | `2026-11-12 11:52` |
| **A100** | Ampere (sm_80) | **#56** / 57 | **3555.33 µs** | 3556.01 µs | 48 TFLOPS | 16.8% (`595.63 µs`) | [`crisp_matmul_v10.py`](06-matmul-v2/crisp_matmul_v10.py) ([`.crisp`](06-matmul-v2/matmul_ampere_4w_ring.crisp)) | `h100` | `2026-11-12 11:52` |
| **L4** | Ada Lovelace (sm_89) | **#21** / 21 | **6661.90 µs** | 6605.77 µs | 26 TFLOPS | 29.9% (`1989.62 µs`) | [`crisp_matmul_v8.py`](06-matmul-v2/crisp_matmul_v8.py) ([`.crisp`](06-matmul-v2/matmul_ampere_4w_k32.crisp)) | — | `2026-11-12 11:52` |

## § 1b — Beauty Contestant Showcase (Idiomatic Crisp)

> **Philosophy:** High-level, declarative Crisp code utilizing built-in language idioms (`loop-vector-stride`, vectorized types/views, monomorphic collective reductions) without manual pointer chasing, inline PTX hacks, or complex register budgeting.

> **Design:** 13-line Crisp matmul that runs unchanged on B200, H100, A100 and L4 and is bit-exact against cuBLAS: `matrix-multiply-tile-stride` walks output tiles and K, `load-tile` stages A and B slices, `mma-accumulate-via-tile` accumulates in f32 on the tensor cores, and `(store-tile (to-half C-tile) ...)` rounds to fp16 as it stores (`13` SLOC)
>

> **Crisp Abstractions Showcased:**

> - matrix-multiply-tile-stride: output-tile walk + K walk + epilogue in one form

> - make-register-tile: an f32 accumulator that lives in registers

> - mma-accumulate-via-tile (16 8 16): fp16 tensor-core MMA from staged shared-memory tiles

> - (store-tile (to-half C-tile) C ...): fused round-to-nearest narrowing on the store (endeavour 196)



| GPU | Architecture | Beauty Score | Achieved BW / TFLOPS | % of #1 (`top1`) | % of Tuned Crisp | Winning Tuned Kernel | Mode | Submission ID |
|---|---|---:|---:|---:|---:|---|---|---:|
| **H100** | Hopper (sm_90) | **86000.00 µs** | 2 TFLOPS | **0.2%** (`204.96 µs`) | 0.3% (`229.79 µs`) | [`crisp_matmul_v5.py`](06-matmul-v2/crisp_matmul_v5.py) | `benchmark` | `#968316` |

### Crisp Implementation ([`06-matmul-v2/matmul_beauty.crisp`](06-matmul-v2/matmul_beauty.crisp))

```lisp
;; matmul_v2 beauty entry: C = A B in fp16, on the tensor cores, in one portable kernel.
;;
;; Each warp owns a 16x8 tile of C.  matrix-multiply-tile-stride walks the output tiles and, for each,
;; the K dimension 16 at a time: stage a 16x16 slice of A and a 16x8 slice of B in shared memory, and
;; accumulate their product into an f32 register tile on the tensor cores.  The epilogue rounds the
;; accumulator to half as it stores it.  Summing K in order on the tensor cores is also what makes the
;; result bit-identical to torch's `a @ b`.
(def-type a-mat (matrix half :address-space :global :align :compact :contiguous-term :row-major))
(def-type b-mat (matrix half :address-space :global :align :compact :contiguous-term :row-major))
(def-type c-mat (matrix half :address-space :global :align :compact :contiguous-term :row-major))

(def-kernel matmul (A B &out C)
  (declare #'(a-mat b-mat &out c-mat) (local-size :set-to 32))
  (let ((A-tile (make-scratch-matrix half (16 16)))
        (B-tile (make-scratch-matrix half (16 8)))
        (C-tile (make-register-tile float (16 8) 0.0))
        (K      (inner-dimension A B)))
    (matrix-multiply-tile-stride C C-tile K 16 (grid-y grid-x grid-k)
      (load-tile A A-tile (grid-y grid-k))
      (load-tile B B-tile (grid-k grid-x))
      (sync-workgroup)
      (mma-accumulate-via-tile (16 8 16) C-tile A-tile B-tile)
      (sync-workgroup)
      :epilogue
      (store-tile (to-half C-tile) C (grid-y grid-x)))))
```

## § 2 — Technique Ladder & Cross-GPU Ablation (`scored case: 4096x5120x4096 (ranking_by LAST)`)

Cells show **`benchmark` mean µs** (and **`[LB: public µs]`** when submitted to the official leaderboard). The fastest kernel on each GPU is **bold**.

| Step | Kernel (`.crisp` / `.py`) | Strategy | Regs | Profile | **B200** | **H100** | **A100** | **L4** |
|---|---|---|---:|---|---:|---:|---:|---:|
| 0 | [`matmul_beauty.crisp`](06-matmul-v2/matmul_beauty.crisp) / [`crisp_matmul_beauty.py`](06-matmul-v2/crisp_matmul_beauty.py) | Beauty: one portable 13-line tensor-core kernel -- matrix-multiply-tile-stride, one warp per 16x8 tile, mma.sync m16n8k16, (store-tile (to-half C-tile) ...) | None | `h100` | — | 86000.0 | — | — |
| 1 | [`matmul_h100_2wg_deep.crisp`](06-matmul-v2/matmul_h100_2wg_deep.crisp) / [`crisp_matmul_v1.py`](06-matmul-v2/crisp_matmul_v1.py) | H100: 2wg_deep (2 consumer warpgroups, wgmma m64n256k16, 4-deep TMA ring) after torch `b.t()` copy; A100/L4: 1-warp 64x64 mma.sync, vectorized cp.async (first cut) | None | — | — | 465.0 | 6780.0 | — |
| 2 | [`matmul_h100_2wg_deep.crisp`](06-matmul-v2/matmul_h100_2wg_deep.crisp) / [`crisp_matmul_v2.py`](06-matmul-v2/crisp_matmul_v2.py) | H100: 2wg_deep after a Crisp tiled transpose of B (`transpose_b.crisp`, 39 us; torch's `b.t()` copy was 160 us) | None | — | — | `LB: 340.26` | — | — |
| 3 | [`matmul_ampere_4w.crisp`](06-matmul-v2/matmul_ampere_4w.crisp) / [`crisp_matmul_v3.py`](06-matmul-v2/crisp_matmul_v3.py) | A100/L4/B200: 4-warp 128x128 register tile (:warps), flattened 16-byte cp.async walk, await + bar.sync; H100 as v2 | None | `h100` | — | — | `LB: 4961.62` | `LB: 7116.96` |
| 4 | [`matmul_h100_2wg_transb.crisp`](06-matmul-v2/matmul_h100_2wg_transb.crisp) / [`crisp_matmul_v4.py`](06-matmul-v2/crisp_matmul_v4.py) | H100: 2wg_deep reading B as given (K N) via wgmma transB (:b-major :mn); transpose kernel gone (endeavour 198) | None | — | — | `LB: 253.74` | — | — |
| 5 | [`matmul_h100_2wg_tma.crisp`](06-matmul-v2/matmul_h100_2wg_tma.crisp) / [`crisp_matmul_v5.py`](06-matmul-v2/crisp_matmul_v5.py) | H100: v4 with both accumulator stores (store-tile-at ... :via :tma) -- stmatrix + per-warp TMA store (endeavour 199) | None | — | — | **`LB: 229.79`** | `LB: 4862.98` | `LB: 7055.49` |
| 6 | [`matmul_b200_tcgen05.crisp`](06-matmul-v2/matmul_b200_tcgen05.crisp) / [`crisp_matmul_v6.py`](06-matmul-v2/crisp_matmul_v6.py) | B200: first tcgen05 entry (endeavour 208/209 kernel: accumulator in tensor memory, warp-specialized, 2-deep TMA ring, 128x256 tile) after a Crisp transpose of b -- 265 us; the transpose was 34 of it | None | `b200` | `LB: 265.44` | — | — | — |
| 7 | [`matmul_b200_tcgen05_mn.crisp`](06-matmul-v2/matmul_b200_tcgen05_mn.crisp) / [`crisp_matmul_v7.py`](06-matmul-v2/crisp_matmul_v7.py) | B200: v6 reading b as given via tcgen05 :b-major :mn (endeavour 213) -- transpose gone, 230 us | None | `b200` | `LB: 230.18` | — | — | — |
| 8 | [`matmul_ampere_4w_k32.crisp`](06-matmul-v2/matmul_ampere_4w_k32.crisp) / [`crisp_matmul_v8.py`](06-matmul-v2/crisp_matmul_v8.py) | A100 / L4: the 4-warp mma.sync kernel with K = 32 per stage -- L4 7117 -> 6662 us; A100 keeps v5 on the board | None | — | — | — | `LB: 5170.52` | **`LB: 6661.90`** |
| 9 | [`matmul_b200_tcgen05_mn_128.crisp`](06-matmul-v2/matmul_b200_tcgen05_mn_128.crisp) / [`crisp_matmul_v9.py`](06-matmul-v2/crisp_matmul_v9.py) | B200: 16-byte tcgen05 epilogue stores (endeavour 215; the 4-byte stores were a third of v7's time) and a 128x128 tile at 3 workgroups / SM where it fills the waves better (the scored shape) -- 156 us | None | `b200` | **`LB: 156.12`** | — | — | — |
| 10 | [`matmul_ampere_4w_ring.crisp`](06-matmul-v2/matmul_ampere_4w_ring.crisp) / [`crisp_matmul_v10.py`](06-matmul-v2/crisp_matmul_v10.py) | A100 / L4 (endeavour 216): mma.sync fragments from shared memory by ldmatrix (x4 for A, x2.trans for the (K N) B) instead of 8 / 4 ld.shared.b16 each, and a 3-slot cp.async ring -- A100 4863 -> 3555 us; H100 / B200 as v9 | None | `h100` | — | — | **`LB: 3555.33`** | — |

## § 3 — Key Architectural Takeaways

1. **The check is bit-exact, so only tensor cores qualify:** `eval.py` re-checks every benchmark input at rtol 1e-5, and with fp16 outputs near 1024 that is an exact match against cuBLAS. A probe (no Crisp) found `mma.sync` m16n8k16 with f32 accumulation summed in K order matches cuBLAS on **all 21M outputs** on H100, A100 and L4, while an IEEE fp32 FMA loop misses 3.7-7% by one ulp. Every Crisp kernel here is a tensor-core kernel with no split-K -- including the small-shape fallback.
2. **The field is cuBLAS:** #1 / median on 2026-10-27 were H100 205 / 221 us, B200 92 / 114, A100 596 / 683, L4 1990 / 2255 -- most entries call `torch.matmul`. Crisp entries rank H100 41/43, A100 59/60, L4 25/25.
3. **H100 -- the kernel is the benchmark suite's, the transpose was the surprise:** wgmma reads B K-major and the contest's `b` is (K N) N-contiguous. A per-arm diagnostic on the scored case: the 2wg_deep kernel 306-309 us (~560 TFLOPS, matching the suite's 545 at 4096^3), torch's `b.t()` copy **160 us**. A tiled Crisp transpose (`transpose_b.crisp`, coalesced both sides through a 64x65 shared tile) takes **39 us**: 462 -> 340 us. wgmma transB (on `plan/scramble.md`) would remove it.
4. **TMA multicast does not help 2wg_deep:** a 2x2-cluster multicast variant was correct and slower (366 vs 309 us); the two-warpgroup tile already reuses each TMA load twice.
5. **A100 / L4 needed compiler work (endeavour 196):** the Ampere `cp.async` load-tile refused 16-bit tiles (cp.async moves 4/8/16 bytes) -- it now copies 16-byte chunks spread over every thread; the register fit-check refused a 4-warp distributed tile; and `await` on a cp.async barrier lacked the CTA barrier after `wait_group` (2.8% wrong outputs once tiles were shared across warps). A100 6.78 -> 4.96 ms. The remaining gap is operand fragments read from shared memory one 2-byte element at a time (no `ldmatrix`).
6. **Packaging:** a TMA kernel takes 65 parameters, more than an inline `asm` statement accepts, so this entry loads the PTX through the CUDA driver API (`dlopen` libcuda, `cuModuleLoadDataEx`) with the launch ABI read out of the CUDA hoist. `CU_JIT_THREADS_PER_BLOCK` stands in for `__launch_bounds__`; without it the 288-thread wgmma block failed to launch.
7. **B200 -- tcgen05, then the epilogue:** the B200 path is Crisp's tcgen05 kernel (endeavours 208/209: accumulator in tensor memory, warp-specialized producer / MMA / epilogue). v6 transposed b first (265 us); tcgen05 `:b-major :mn` (endeavour 213) read it as given (230 us). Pricing v7 one piece at a time on popcorn (no rental) found the real cost: with the epilogue's stores removed it ran 147.5 us -- the tcgen05 layout hands each thread a whole row, and it left as 4-byte stores, 32 rows per warp instruction. 16-byte stores (endeavour 215) plus a 128x128 tile for the scored shape's 2.16-wave quantization: **156 us**, rank 41/53. Measured and rejected on the way: persistent scheduling (~3%), and a 2-SM `cta_group::2` pair (exact on metal, +7-9% only on full-wave shapes; endeavour 214, parked).
8. **ldmatrix closed a third of the A100 gap (endeavour 216):** a twin A/B on one A100 (same compiler, ldmatrix switched off) took the scored shape from 4204 to 3032 us, bit-exact; the 3-slot cp.async ring adds ~5%. What is left (A100 ~2.9 ms vs cuBLAS ~0.64) is, by arithmetic, shared-memory bank conflicts: the scratch tiles' 64 B / 256 B row pitches make the ldmatrix reads 4- and 8-way conflicted. A padded or swizzled scratch layout is the next lever (tests/spec/216-ldmatrix/ldmatrix.md, D-216-5).

## § 4 — Verified Submission & Benchmark Log

| Timestamp (UTC) | Submission ID | GPU | Mode | File | Benchmark (µs) | Public LB (µs) | Secret LB (µs) |
|---|---:|---|---|---|---:|---:|---:|
| `2026-10-28 07:57:15` | `968311` | **A100** | `benchmark` | `crisp_matmul_v1.py` | 6780.0 ± 4.0 | — | — |
| `2026-10-28 07:57:15` | `968314` | **H100** | `leaderboard` | `crisp_matmul_v2.py` | — | **340.26** | 341.17 |
| `2026-10-28 08:38:14` | `968316` | **H100** | `benchmark` | `crisp_matmul_beauty.py` | 86000.0 ± 20.0 | — | — |
| `2026-10-28 08:50:09` | `968301` | **H100** | `benchmark` | `crisp_matmul_v1.py` | 465.0 ± 0.3 | — | — |
| `2026-10-28 09:39:55` | `968318` | **A100** | `leaderboard` | `crisp_matmul_v3.py` | — | **4961.62** | 4959.40 |
| `2026-10-28 09:39:55` | `968319` | **L4** | `leaderboard` | `crisp_matmul_v3.py` | — | **7116.96** | 7134.11 |
| `2026-10-29 01:30:05` | `968463` | **H100** | `leaderboard` | `crisp_matmul_v4.py` | — | **253.74** | 255.92 |
| `2026-10-29 05:49:36` | `968487` | **H100** | `leaderboard` | `crisp_matmul_v5.py` | — | **229.79** | 228.67 |
| `2026-10-30 06:28:35` | `968649` | **A100** | `leaderboard` | `crisp_matmul_v5.py` | — | **4862.98** | 4929.54 |
| `2026-10-30 06:46:58` | `968650` | **L4** | `leaderboard` | `crisp_matmul_v5.py` | — | **7055.49** | 7020.40 |
| `2026-11-11 21:56:46` | `970690` | **B200** | `test` | `crisp_matmul_v6.py` | — | — | — |
| `2026-11-11 21:58:56` | `970691` | **B200** | `leaderboard` | `crisp_matmul_v6.py` | — | **265.44** | 265.24 |
| `2026-11-11 22:00:22` | `None` | **B200** | `test` | `diag_b200_sub.py` | — | — | — |
| `2026-11-11 22:03:05` | `970692` | **B200** | `test` | `diag_b200_sub.py` | — | — | — |
| `2026-11-11 22:16:23` | `970695` | **B200** | `test` | `crisp_matmul_v7.py` | — | — | — |
| `2026-11-11 22:21:07` | `970696` | **B200** | `leaderboard` | `crisp_matmul_v7.py` | — | **230.18** | 230.26 |
| `2026-11-11 22:34:23` | `970699` | **B200** | `test` | `diag_b200_v7_sub.py` | — | — | — |
| `2026-11-11 22:49:29` | `970702` | **A100** | `test` | `diag_ampere_k_sub.py` | — | — | — |
| `2026-11-11 22:52:35` | `970704` | **A100** | `leaderboard` | `crisp_matmul_v8.py` | — | **5170.52** | 5154.82 |
| `2026-11-11 23:14:09` | `970705` | **L4** | `leaderboard` | `crisp_matmul_v8.py` | — | **6661.90** | 6605.77 |
| `2026-11-12 03:47:53` | `970717` | **B200** | `test` | `diag_b200_p_sub.py` | — | — | — |
| `2026-11-12 03:47:53` | `970724` | **B200** | `test` | `diag_b200_pair_sub.py` | — | — | — |
| `2026-11-12 03:47:53` | `970726` | **B200** | `test` | `diag_b200_pair_sub.py` | — | — | — |
| `2026-11-12 03:47:53` | `970727` | **B200** | `test` | `diag_b200_pair_sub.py` | — | — | — |
| `2026-11-12 03:47:53` | `970733` | **B200** | `test` | `diag_b200_pair_sub.py` | — | — | — |
| `2026-11-12 03:47:53` | `970734` | **B200** | `test` | `diag_b200_pair_sub.py` | — | — | — |
| `2026-11-12 03:47:53` | `970745` | **B200** | `test` | `diag_b200_pair_sub.py` | — | — | — |
| `2026-11-12 03:47:53` | `970754` | **B200** | `test` | `diag_b200_n128_sub.py` | — | — | — |
| `2026-11-12 03:47:53` | `970760` | **B200** | `test` | `diag_b200_n128_sub.py` | — | — | — |
| `2026-11-12 03:47:53` | `970761` | **B200** | `test` | `_diag_noepi_sub.py` | — | — | — |
| `2026-11-12 03:47:53` | `970762` | **B200** | `test` | `_diag_v4_sub.py` | — | — | — |
| `2026-11-12 03:47:53` | `970772` | **B200** | `test` | `diag_b200_215_sub.py` | — | — | — |
| `2026-11-12 03:47:53` | `970773` | **B200** | `test` | `crisp_matmul_v9.py` | — | — | — |
| `2026-11-12 03:47:53` | `970774` | **B200** | `leaderboard` | `crisp_matmul_v9.py` | — | **156.12** | 154.66 |
| `2026-11-12 08:32:50` | `970853` | **A100** | `test` | `diag_ampere_216_sub.py` | — | — | — |
| `2026-11-12 09:01:05` | `970856` | **A100** | `test` | `diag_ampere_216b_sub.py` | — | — | — |
| `2026-11-12 09:31:07` | `970860` | **L4** | `test` | `diag_ampere_216b_sub.py` | — | — | — |
| `2026-11-12 09:47:47` | `970864` | **A100** | `test` | `crisp_matmul_v10.py` | — | — | — |
| `2026-11-12 09:47:57` | `970863` | **A100** | `test` | `diag_ampere_216c_sub.py` | — | — | — |
| `2026-11-12 10:17:51` | `970865` | **L4** | `test` | `crisp_matmul_v10.py` | — | — | — |
| `2026-11-12 10:18:01` | `970866` | **L4** | `test` | `diag_ampere_216c_sub.py` | — | — | — |
| `2026-11-12 10:21:50` | `970869` | **A100** | `leaderboard` | `crisp_matmul_v10.py` | — | **3555.33** | 3556.01 |
| `2026-11-12 10:51:57` | `970870` | **L4** | `test` | `crisp_matmul_v10.py` | — | — | — |
| `2026-11-12 11:52:31` | `970880` | **L4** | `test` | `crisp_matmul_v10.py` | — | — | — |
