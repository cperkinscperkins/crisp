# GPU MODE Contest Report: `sort_v2`

> Generated from [`results/sort_v2.json`](results/sort_v2.json) by `python contests/gpu-mode/report.py --all`. Live leaderboard: [https://www.gpumode.com/leaderboard/542?tab=rankings](https://www.gpumode.com/leaderboard/542?tab=rankings) (Crisp commit `28ca6e51`).

**Workload:** Sort a 1-D fp32 tensor ascending; must equal torch.sort exactly. task.yml lists 5 benchmarks (100K .. 100M); kernelbot ranks by RankCriterion.LAST, so the score is the LAST case only: 100,000,000 floats (seed 6252), rows of randn + seed + i -- nearly sorted by row. The traffic below is the floor: read 400 MB once and write 400 MB once..

## § 1 — Official Leaderboard Standings

| GPU | Architecture | Rank | Public Score | Secret Score | Achieved BW / TFLOPS | % of #1 (`top1`) | Winning Crisp Kernel | Hardware Profile | Captured (UTC) |
|---|---|---:|---:|---:|---:|---:|---|---|---|
| **H100** | Hopper (sm_90) | **#19** / 30 | **3749.47 µs** | 475.49 µs | 213.4 GB/s | 7.9% (`296.75 µs`) | [`crisp_sort_v1.py`](07-sort-v2/crisp_sort_v1.py) ([`.crisp`](07-sort-v2/sort_radix.crisp)) | — | `2026-10-30 08:19` |
| **A100** | Ampere (sm_80) | **#24** / 33 | **8155.72 µs** | 985.09 µs | 98.1 GB/s | 6.8% (`557.12 µs`) | [`crisp_sort_v1.py`](07-sort-v2/crisp_sort_v1.py) ([`.crisp`](07-sort-v2/sort_radix.crisp)) | — | `2026-10-30 08:19` |
| **L4** | Ada Lovelace (sm_89) | **#16** / 20 | **25318.74 µs** | 5061.47 µs | 31.6 GB/s | 12.5% (`3165.53 µs`) | [`crisp_sort_v1.py`](07-sort-v2/crisp_sort_v1.py) ([`.crisp`](07-sort-v2/sort_radix.crisp)) | — | `2026-10-30 08:19` |

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
| **H100** | Hopper (sm_90) | **68900.00 µs** | 11.6 GB/s | **0.4%** (`296.75 µs`) | 5.4% (`3749.47 µs`) | [`crisp_sort_v1.py`](07-sort-v2/crisp_sort_v1.py) | `benchmark` | `#968685` |

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
| 1 | [`sort_radix.crisp`](07-sort-v2/sort_radix.crisp) / [`crisp_sort_v1.py`](07-sort-v2/crisp_sort_v1.py) | LSD radix: keys = order-preserving float bits minus kmin (3 passes, not 4); per pass upsweep / digit scan / downsweep; 4096-key tiles sorted in shared memory by two 4-bit splits; keys rotated so the digit is the low byte (endeavour 200) | 48 | — | — | **4060.0 (`LB: 3749.47`)** | **`LB: 8155.72`** | **`LB: 25318.74`** |

## § 3 — Key Architectural Takeaways

1. **Exact match, so radix:** the output must equal torch.sort; a radix sort on order-preserving key bits is exact by construction. One min/max pass lets every pass sort key - kmin: the scored data differ only in their low 24 bits, so 3 passes instead of 4, correct for any input.
2. **The H100 #1 (129.7 us) is below the memory floor** (~240 us to read and write 800 MB): the leaders exploit the input's near-sortedness. The median is 2094 us; Crisp ranks 19/30 at 3749.5 us.
3. **The downsweep is instruction-bound, not memory-bound:** probes showed ~38K cycles per 4096-key tile; packed register counters bought nothing, a run-time ash cost ~200 us per pass. The next lever is a warp ballot/match builtin for one-pass 8-bit ranking (a compiler feature).
4. **Onesweep (decoupled look-back) was correct but slower** here (1330 vs 1236 us per pass).
5. **Two compiler bugs fixed on the way:** BUG 138 (ash/popcount were out-of-line calls on PTX) and BUG 145 (a while ending a let crashed the analyzer). Endeavour 200: tests/spec/200-sort-contest/sort-contest.md.

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
