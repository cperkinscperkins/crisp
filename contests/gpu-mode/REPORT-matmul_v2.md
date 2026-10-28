# GPU MODE Contest Report: `matmul_v2`

> Generated from [`results/matmul_v2.json`](results/matmul_v2.json) by `python contests/gpu-mode/report.py --all`. Live leaderboard: [https://www.gpumode.com/leaderboard/540?tab=rankings](https://www.gpumode.com/leaderboard/540?tab=rankings) (Crisp commit `0e648a7f`).

**Workload:** C = A @ B with A (M K) and B (K N) row-major fp16, C fp16. task.yml lists 8 benchmarks (128^3 .. 4096x5120x4096); kernelbot ranks by RankCriterion.LAST, so the score is the LAST case only: m=4096 n=5120 k=4096 (171.8 GFLOP). Correctness is checked on the benchmark inputs too at rtol 1e-5: bit-exact fp16 against cuBLAS..

## § 1 — Official Leaderboard Standings

| GPU | Architecture | Rank | Public Score | Secret Score | Achieved BW / TFLOPS | % of #1 (`top1`) | Winning Crisp Kernel | Hardware Profile | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|---|
| **H100** | Hopper (sm_90) | **#41** / 43 | **340.26 µs** | 341.17 µs | 505 TFLOPS | 60.2% (`204.96 µs`) | [`crisp_matmul_v2.py`](06-matmul-v2/crisp_matmul_v2.py) ([`.crisp`](06-matmul-v2/matmul_h100_2wg_deep.crisp)) | — | `2026-10-28 09:51` |
| **A100** | Ampere (sm_80) | **#59** / 60 | **4961.62 µs** | 4959.40 µs | 35 TFLOPS | 12.0% (`595.63 µs`) | [`crisp_matmul_v3.py`](06-matmul-v2/crisp_matmul_v3.py) ([`.crisp`](06-matmul-v2/matmul_ampere_4w.crisp)) | `h100` | `2026-10-28 09:51` |
| **L4** | Ada Lovelace (sm_89) | **#25** / 25 | **7116.96 µs** | 7134.11 µs | 24 TFLOPS | 28.0% (`1989.62 µs`) | [`crisp_matmul_v3.py`](06-matmul-v2/crisp_matmul_v3.py) ([`.crisp`](06-matmul-v2/matmul_ampere_4w.crisp)) | `h100` | `2026-10-28 09:51` |

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
| **H100** | Hopper (sm_90) | **86000.00 µs** | 2 TFLOPS | **0.2%** (`204.96 µs`) | 0.4% (`340.26 µs`) | [`crisp_matmul_v2.py`](06-matmul-v2/crisp_matmul_v2.py) | `benchmark` | `#968316` |

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
| 2 | [`matmul_h100_2wg_deep.crisp`](06-matmul-v2/matmul_h100_2wg_deep.crisp) / [`crisp_matmul_v2.py`](06-matmul-v2/crisp_matmul_v2.py) | H100: 2wg_deep after a Crisp tiled transpose of B (`transpose_b.crisp`, 39 us; torch's `b.t()` copy was 160 us) | None | — | — | **`LB: 340.26`** | — | — |
| 3 | [`matmul_ampere_4w.crisp`](06-matmul-v2/matmul_ampere_4w.crisp) / [`crisp_matmul_v3.py`](06-matmul-v2/crisp_matmul_v3.py) | A100/L4/B200: 4-warp 128x128 register tile (:warps), flattened 16-byte cp.async walk, await + bar.sync; H100 as v2 | None | `h100` | — | — | **`LB: 4961.62`** | **`LB: 7116.96`** |

## § 3 — Key Architectural Takeaways

1. **The check is bit-exact, so only tensor cores qualify:** `eval.py` re-checks every benchmark input at rtol 1e-5, and with fp16 outputs near 1024 that is an exact match against cuBLAS. A probe (no Crisp) found `mma.sync` m16n8k16 with f32 accumulation summed in K order matches cuBLAS on **all 21M outputs** on H100, A100 and L4, while an IEEE fp32 FMA loop misses 3.7-7% by one ulp. Every Crisp kernel here is a tensor-core kernel with no split-K -- including the small-shape fallback.
2. **The field is cuBLAS:** #1 / median on 2026-10-27 were H100 205 / 221 us, B200 92 / 114, A100 596 / 683, L4 1990 / 2255 -- most entries call `torch.matmul`. Crisp entries rank H100 41/43, A100 59/60, L4 25/25.
3. **H100 -- the kernel is the benchmark suite's, the transpose was the surprise:** wgmma reads B K-major and the contest's `b` is (K N) N-contiguous. A per-arm diagnostic on the scored case: the 2wg_deep kernel 306-309 us (~560 TFLOPS, matching the suite's 545 at 4096^3), torch's `b.t()` copy **160 us**. A tiled Crisp transpose (`transpose_b.crisp`, coalesced both sides through a 64x65 shared tile) takes **39 us**: 462 -> 340 us. wgmma transB (on `plan/scramble.md`) would remove it.
4. **TMA multicast does not help 2wg_deep:** a 2x2-cluster multicast variant was correct and slower (366 vs 309 us); the two-warpgroup tile already reuses each TMA load twice.
5. **A100 / L4 needed compiler work (endeavour 196):** the Ampere `cp.async` load-tile refused 16-bit tiles (cp.async moves 4/8/16 bytes) -- it now copies 16-byte chunks spread over every thread; the register fit-check refused a 4-warp distributed tile; and `await` on a cp.async barrier lacked the CTA barrier after `wait_group` (2.8% wrong outputs once tiles were shared across warps). A100 6.78 -> 4.96 ms. The remaining gap is operand fragments read from shared memory one 2-byte element at a time (no `ldmatrix`).
6. **Packaging:** a TMA kernel takes 65 parameters, more than an inline `asm` statement accepts, so this entry loads the PTX through the CUDA driver API (`dlopen` libcuda, `cuModuleLoadDataEx`) with the launch ABI read out of the CUDA hoist. `CU_JIT_THREADS_PER_BLOCK` stands in for `__launch_bounds__`; without it the 288-thread wgmma block failed to launch.
7. **B200:** Blackwell has no wgmma (its instruction is tcgen05 -- a future endeavour), so the B200 path is the same 4-warp `mma.sync` kernel. Every B200 submission of ours hit the runner's hard timeout (~1570 s), including a plain-CUDA probe with no Crisp in it; no B200 score yet.

## § 4 — Verified Submission & Benchmark Log

| Timestamp (UTC) | Submission ID | GPU | Mode | File | Benchmark (µs) | Public LB (µs) | Secret LB (µs) |
|---|---:|---|---|---|---:|---:|---:|
| `2026-10-28 07:57:15` | `968311` | **A100** | `benchmark` | `crisp_matmul_v1.py` | 6780.0 ± 4.0 | — | — |
| `2026-10-28 07:57:15` | `968314` | **H100** | `leaderboard` | `crisp_matmul_v2.py` | — | **340.26** | 341.17 |
| `2026-10-28 08:38:14` | `968316` | **H100** | `benchmark` | `crisp_matmul_beauty.py` | 86000.0 ± 20.0 | — | — |
| `2026-10-28 08:50:09` | `968301` | **H100** | `benchmark` | `crisp_matmul_v1.py` | 465.0 ± 0.3 | — | — |
| `2026-10-28 09:39:55` | `968318` | **A100** | `leaderboard` | `crisp_matmul_v3.py` | — | **4961.62** | 4959.40 |
| `2026-10-28 09:39:55` | `968319` | **L4** | `leaderboard` | `crisp_matmul_v3.py` | — | **7116.96** | 7134.11 |
