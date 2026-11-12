# GPU MODE Contest Report: `sort_v2`

> Generated from [`results/sort_v2.json`](results/sort_v2.json) by `python contests/gpu-mode/report.py --all`. Live leaderboard: [https://www.gpumode.com/leaderboard/542?tab=rankings](https://www.gpumode.com/leaderboard/542?tab=rankings) (Crisp commit `3def9cf0`).

**Workload:** Sort a 1-D fp32 tensor ascending; must equal torch.sort exactly. task.yml lists 5 benchmarks (100K .. 100M); kernelbot ranks by RankCriterion.LAST, so the score is the LAST case only: 100,000,000 floats (seed 6252), rows of randn + seed + i -- nearly sorted by row. The traffic below is the floor: read 400 MB once and write 400 MB once..

## § 1 — Official Leaderboard Standings

| GPU | Architecture | Rank | Public Score | Secret Score | Achieved BW / TFLOPS | % of #1 (`top1`) | Winning Crisp Kernel | Hardware Profile | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|---|
| **B200** | Blackwell (sm_100) | **#18** / 30 | **2533.57 µs** | 2532.81 µs | 315.8 GB/s | 4.6% (`115.39 µs`) | [`crisp_sort_v1.py`](07-sort-v2/crisp_sort_v1.py) ([`.crisp`](07-sort-v2/sort_radix.crisp)) | — | `2026-11-12 17:38` |
| **H100** | Hopper (sm_90) | **#17** / 30 | **3156.15 µs** | 3175.36 µs | 253.5 GB/s | 10.3% (`325.85 µs`) | [`crisp_sort_v1.py`](07-sort-v2/crisp_sort_v1.py) ([`.crisp`](07-sort-v2/sort_radix.crisp)) | — | `2026-11-12 17:38` |
| **A100** | Ampere (sm_80) | **#24** / 33 | **5794.22 µs** | 5852.40 µs | 138.1 GB/s | 10.1% (`582.90 µs`) | [`crisp_sort_v1.py`](07-sort-v2/crisp_sort_v1.py) ([`.crisp`](07-sort-v2/sort_radix.crisp)) | — | `2026-11-12 17:38` |
| **L4** | Ada Lovelace (sm_89) | **#13** / 18 | **23639.68 µs** | 23793.05 µs | 33.8 GB/s | 15.0% (`3534.85 µs`) | [`crisp_sort_v1.py`](07-sort-v2/crisp_sort_v1.py) ([`.crisp`](07-sort-v2/sort_radix.crisp)) | — | `2026-11-12 17:38` |

## § 1b — Beauty Contestant Showcase (Idiomatic Crisp)

> **Philosophy:** High-level, declarative Crisp code utilizing built-in language idioms (`loop-vector-stride`, vectorized types/views, monomorphic collective reductions) without manual pointer chasing, inline PTX hacks, or complex register budgeting.

> **Design:** Pad to a power of two with +inf, then for every stage k and distance j put each pair (i, i+j) in order -- ascending where bit k of i is clear. Distances below one 2048-key tile run in shared memory, larger ones as global passes. Runs unchanged on the BMG and the H100. (`79` SLOC)
>

> **Crisp Abstractions Showcased:**

> - def-grid-function merge-in-tile: a barrier-holding helper (dec-times-by-half+ over the distances)

> - do-power-step+ over the stages inside one tile

> - grid-stride over the pairs of one global distance

> - (declare (uniform from)): a parameter as a provably uniform loop bound



| GPU | Architecture | Beauty Score | Achieved BW / TFLOPS | % of #1 (`top1`) | % of Tuned Crisp | Winning Tuned Kernel | Mode | Submission ID |
|---|---|---:|---:|---:|---:|---|---|---:|
| **H100** | Hopper (sm_90) | **68900.00 µs** | 11.6 GB/s | **0.5%** (`325.85 µs`) | 4.6% (`3156.15 µs`) | [`crisp_sort_v1.py`](07-sort-v2/crisp_sort_v1.py) | `benchmark` | `#968685` |

### Crisp Implementation ([`07-sort-v2/sort_bitonic_beauty.crisp`](07-sort-v2/sort_bitonic_beauty.crisp))

```lisp
;; GPU MODE Challenge 07: sort_v2 -- Beauty Contestant: bitonic sort.
;;
;; Idiomatic Crisp: compare-and-swap on floats, no bit tricks.  The input is padded with +inf to a power
;; of two P; then, for every stage k = 2, 4, .. P, and every distance j = k/2 .. 1, each element i is
;; compared with i + j (for i with bit j clear) and the pair is put in order -- ascending where bit k of
;; i is clear, descending where it is set.  Distances below one tile (2048) are done in shared memory,
;; larger ones by one global pass each.  O(n log^2 n): slow at 100M, but every step is plain.
;;
;; Host loop:   bitonic_pad;  bitonic_tiles (k = 2 .. 2048, all in shared memory)
;;              for k = 4096 .. P:  for j = k/2 .. 2048: bitonic_global [j k];  bitonic_finish [k]
;;              bitonic_unpad
;; bitonic_global / bitonic_finish read and write the same buffer: the host passes it as SRC and DST.
;; Each element is read and written by one thread per launch, so the read-only path is safe.

(def-type in-vec  (vector float :address-space :global :align :compact))
(def-type out-vec (vector float :address-space :global :align :compact))
(def-type prm-vec (vector uint  :address-space :global :align :compact))
(def-type s-vec   (vector float :address-space :local  :align :compact))

;; Put (~ s i) and (~ s (+ i j)) in order: ascending when UP is 1.
(def-function order-pair (s i j up)
  (declare #'(s-vec ulong ulong uint => nil))
  (let ((a (~ s i))
        (b (~ s (+ i j))))
    (when (= (if (> a b) 1u 0u) up)
      (set! (~ s i) b)
      (set! (~ s (+ i j)) a)))
  (return))

;; The I of pair Q at distance J: Q with a 0 inserted at bit J.
(def-function pair-index (q j)
  (declare #'(ulong ulong => ulong))
  (return (+ (* (* 2ul j) (/ q j)) (rem q j))))

;; 1 where bit K of the global position G is clear (ascending), else 0.
(def-function ascending (g k)
  (declare #'(ulong ulong => uint))
  (return (if (= (logand g k) 0ul) 1u 0u)))

;; Every distance J = from .. 1 of stage K, in shared memory, for the tile at global position BASE.
(def-grid-function merge-in-tile (s base k from tid)
  (declare #'(s-vec ulong ulong ulong ulong => nil)
           (uniform from))
  (dec-times-by-half+ (j from)
    (let ((i (pair-index tid j)))
      (order-pair s i j (ascending (+ base i) k)))
    (sync-workgroup))
  (return))

(def-kernel bitonic_pad (input &out buf)
  (declare #'(in-vec &out out-vec => nil)
           (global-size :derive-from buf :strategy :strided)
           (local-size  :set-to 256))
  (let ((n (length~ input)))
    (loop-vector-stride buf (i)
      (set! (~ buf i) (if (< i n) (~ input i) (/ 1.0 0.0))))))

(def-kernel bitonic_tiles (src &out dst)
  (declare #'(in-vec &out out-vec => nil)
           (local-size :set-to 1024))
  (let ((tid  (to-ulong (get-local-id 0)))
        (base (* (to-ulong (get-workgroup-id 0)) 2048ul))
        (s    (make-scratch-vector s-vec 2048)))
    (set! (~ s tid) (~ src (+ base tid)))
    (set! (~ s (+ tid 1024ul)) (~ src (+ base (+ tid 1024ul))))
    (sync-workgroup)
    (do-power-step+ (half 2048ul)                      ; stages k = 2 .. 2048
      (merge-in-tile s base (* 2ul half) half tid))
    (set! (~ dst (+ base tid)) (~ s tid))
    (set! (~ dst (+ base (+ tid 1024ul))) (~ s (+ tid 1024ul)))))

(def-kernel bitonic_global (src prm &out dst)
  (declare #'(in-vec prm-vec &out out-vec => nil)
           (global-size :derive-from src :strategy :strided)
           (local-size  :set-to 256))
  (let ((j     (to-ulong (~ prm 0ul)))
        (k     (to-ulong (~ prm 1ul)))
        (pairs (/ (length~ src) 2ul)))
    (grid-stride (pairs) (q)
      (let ((i (pair-index q j))
            (a (~ src i))
            (b (~ src (+ i j))))
        (if (= (if (> a b) 1u 0u) (ascending i k))
            (progn (set! (~ dst i) b) (set! (~ dst (+ i j)) a))
            (progn (set! (~ dst i) a) (set! (~ dst (+ i j)) b)))))))

(def-kernel bitonic_finish (src prm &out dst)
  (declare #'(in-vec prm-vec &out out-vec => nil)
           (local-size :set-to 1024))
  (let ((tid  (to-ulong (get-local-id 0)))
        (base (* (to-ulong (get-workgroup-id 0)) 2048ul))
        (k    (to-ulong (~ prm 1ul)))
        (s    (make-scratch-vector s-vec 2048)))
    (set! (~ s tid) (~ src (+ base tid)))
    (set! (~ s (+ tid 1024ul)) (~ src (+ base (+ tid 1024ul))))
    (sync-workgroup)
    (merge-in-tile s base k 1024ul tid)
    (set! (~ dst (+ base tid)) (~ s tid))
    (set! (~ dst (+ base (+ tid 1024ul))) (~ s (+ tid 1024ul)))))

(def-kernel bitonic_unpad (buf &out output)
  (declare #'(in-vec &out out-vec => nil)
           (global-size :derive-from output :strategy :strided)
           (local-size  :set-to 256))
  (loop-vector-stride output (i)
    (set! (~ output i) (~ buf i))))
```

## § 2 — Technique Ladder & Cross-GPU Ablation (`scored case: 100,000,000 floats (ranking_by LAST)`)

Cells show **`benchmark` mean µs** (and **`[LB: public µs]`** when submitted to the official leaderboard). The fastest kernel on each GPU is **bold**.

| Step | Kernel (`.crisp` / `.py`) | Strategy | Regs | Profile | **B200** | **H100** | **A100** | **L4** |
|---|---|---|---:|---|---:|---:|---:|---:|
| 0 | [`sort_bitonic_beauty.crisp`](07-sort-v2/sort_bitonic_beauty.crisp) / [`crisp_sort_beauty.py`](07-sort-v2/crisp_sort_beauty.py) | Beauty: plain bitonic sort -- compare-and-swap, 2048-key shared-memory tiles, one global pass per large distance | None | — | — | 68900.0 | — | — |
| 1 | [`sort_radix.crisp`](07-sort-v2/sort_radix.crisp) / [`crisp_sort_v1.py`](07-sort-v2/crisp_sort_v1.py) | LSD radix: keys = order-preserving float bits minus kmin (3 passes, not 4); per pass upsweep / digit scan / downsweep; 4096-key tiles sorted in shared memory by two 4-bit splits; keys rotated so the digit is the low byte (endeavour 200) [rev c, ranked 2026-10-30; source at git 7bec7925] | 48 | — | **`LB: 2533.57`** | 4060.0 (`LB: 3749.47`) | `LB: 8155.72` | `LB: 25318.74` |
| 2 | [`sort_radix.crisp`](07-sort-v2/sort_radix.crisp) / [`crisp_sort_v1.py`](07-sort-v2/crisp_sort_v1.py) | rev i: 32-bit tile index math; 128-bit minmax loads; TILE-MAJOR histograms (the digit-major layout cost 256 scattered sectors per tile); digit scan split into sort_scan_chunks + sort_scan_tiles with sqrt(tiles) chunks [source at git c2d5e26c] | 56 | — | — | `LB: 4058.28` | `LB: 7616.85` | `LB: 28000.26` |
| 3 | [`sort_radix.crisp`](07-sort-v2/sort_radix.crisp) / [`crisp_sort_v1.py`](07-sort-v2/crisp_sort_v1.py) | rev j: run-time shifts / rotates as endeavour 211's shift-right / rotate-right / rotate-left (one funnel shift each, where a run-time ash is a select chain): downsweep SASS -15%, registers 56 -> 40 [source at git e4fa2603] | 40 | — | — | `LB: 3711.94` | `LB: 6783.83` | `LB: 24338.88` |
| 4 | [`sort_radix.crisp`](07-sort-v2/sort_radix.crisp) / [`crisp_sort_v1.py`](07-sort-v2/crisp_sort_v1.py) | rev k: the downsweep ranks with warp ballots (endeavour 212's warp-ballot), CUB-style -- 8 ballots per key give the lanes sharing its 8-bit digit, popcount gives its rank -- in place of two 4-bit counting splits; the tile is loaded into shared memory first; per-warp counters sized by (warp-size) | None | — | — | **`LB: 3156.15`** | **`LB: 5794.22`** | **`LB: 23639.68`** |

## § 3 — Key Architectural Takeaways

1. **Exact match, so radix:** the output must equal torch.sort; a radix sort on order-preserving key bits is exact by construction. One min/max pass lets every pass sort key - kmin: the scored data differ only in their low 24 bits, so 3 passes instead of 4, correct for any input.
2. **The H100 #1 (129.7 us) is below the memory floor** (~240 us to read and write 800 MB): the leaders exploit the input's near-sortedness. The median is 2094 us; Crisp ranks 19/30 at 3749.5 us.
3. **Onesweep (decoupled look-back) was correct but slower** here (1330 vs 1236 us per pass).
4. **Two compiler bugs fixed on the way:** BUG 138 (ash/popcount were out-of-line calls on PTX) and BUG 145 (a while ending a let crashed the analyzer). Endeavour 200: tests/spec/200-sort-contest/sort-contest.md.
5. **The downsweep is instruction-bound, not memory-bound:** -9% SASS gave -16% time (rev d). A run-time ash is a branch-free select chain; endeavour 211 added shift-left / shift-right / rotate-left / rotate-right (count mod width), and the per-key rotate became one funnel shift: -9.2% on the whole sort (rev j).
6. **The histogram layout was the upsweep's limit:** digit-major per-tile counts hit 256 sectors per tile; tile-major made the upsweep 193 -> 150 us per pass (a fenced no-write probe: 136).
7. **GPU MODE H100 runners differ by ~30%:** the same kernels ran 3150 vs 4063 us on two nodes, so a single leaderboard score cannot rank two kernels. Every A/B here runs all arms inside ONE test submission under eval.py's procedure (diagab_*.py). On one H100: v1c 4922, v1i 4063, v1j 3692 us; torch.sort (CUB) 5280.
8. **Warp ballots replaced the two 4-bit splits (rev k):** a CUDA probe measured it before Crisp had a ballot (diagp_ballot.py), endeavour 212 added warp-ballot / warp-any? / warp-all?, and the Crisp downsweep went -14% on the whole sort (one H100: v1j 3693, v1k 3165 us).
9. **Two traps on the way, both measured:** (1) shared memory is occupancy -- 8 KB more cost 830 us on H100 (3 vs 4 workgroups per SM), hence per-warp counters sized by (warp-size); (2) a global load inside a 16-round loop with a warp sync per round is 16 serial memory latencies -- loading the tile first took the ballot version from +7% to -14% against v1j.

## § 4 — Verified Submission & Benchmark Log

| Timestamp (UTC) | Submission ID | GPU | Mode | File | Benchmark (µs) | Public LB (µs) | Secret LB (µs) |
|---|---:|---|---|---|---:|---:|---:|
| `2026-10-30 06:46:50` | `968656` | **H100** | `test` | `crisp_sort_v1.py` | — | — | — |
| `2026-10-30 06:47:09` | `968657` | **H100** | `benchmark` | `crisp_sort_v1.py` | 4060.0 ± 0.0 | — | — |
| `2026-10-30 07:51:57` | `968679` | **H100** | `leaderboard` | `crisp_sort_v1.py` | — | **3749.47** | 475.49 |
| `2026-10-30 07:53:15` | `968680` | **A100** | `leaderboard` | `crisp_sort_v1.py` | — | **8155.72** | 985.09 |
| `2026-10-30 07:55:46` | `968684` | **H100** | `test` | `crisp_sort_beauty.py` | — | — | — |
| `2026-10-30 07:55:59` | `968685` | **H100** | `benchmark` | `crisp_sort_beauty.py` | 68900.0 ± 0.0 | — | — |
| `2026-10-30 08:10:00` | `968686` | **L4** | `leaderboard` | `crisp_sort_v1.py` | — | **25318.74** | 5061.47 |
| `2026-11-10 18:33:43` | `970307` | **H100** | `test` | `crisp_sort_v1.py` | — | — | — |
| `2026-11-10 18:34:35` | `970308` | **H100** | `leaderboard` | `crisp_sort_v1.py` | — | **4058.28** | 4066.80 |
| `2026-11-10 18:35:15` | `970309` | **A100** | `leaderboard` | `crisp_sort_v1.py` | — | **7616.85** | 8922.70 |
| `2026-11-10 18:36:52` | `970310` | **L4** | `leaderboard` | `crisp_sort_v1.py` | — | **28000.26** | 27977.37 |
| `2026-11-11 02:59:01` | `970441` | **H100** | `test` | `crisp_sort_v1.py` | — | — | — |
| `2026-11-11 02:59:31` | `970442` | **H100** | `leaderboard` | `crisp_sort_v1.py` | — | **3711.94** | 3699.62 |
| `2026-11-11 03:00:22` | `970443` | **A100** | `leaderboard` | `crisp_sort_v1.py` | — | **6783.83** | 6771.40 |
| `2026-11-11 03:08:29` | `970444` | **L4** | `leaderboard` | `crisp_sort_v1.py` | — | **24338.88** | 24399.76 |
| `2026-11-11 06:38:40` | `970484` | **H100** | `test` | `crisp_sort_v1.py` | — | — | — |
| `2026-11-11 06:39:15` | `970485` | **H100** | `leaderboard` | `crisp_sort_v1.py` | — | **3156.15** | 3175.36 |
| `2026-11-11 06:39:50` | `970486` | **A100** | `leaderboard` | `crisp_sort_v1.py` | — | **5794.22** | 5852.40 |
| `2026-11-11 06:41:25` | `970488` | **L4** | `leaderboard` | `crisp_sort_v1.py` | — | **23639.68** | 23793.05 |
| `2026-11-12 11:21:37` | `970872` | **B200** | `test` | `crisp_sort_v1.py` | — | — | — |
| `2026-11-12 11:22:23` | `970879` | **B200** | `leaderboard` | `crisp_sort_v1.py` | — | **2533.57** | 2532.81 |
