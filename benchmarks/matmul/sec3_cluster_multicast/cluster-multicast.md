# Side chapter — Clusters and TMA multicast: does it pay?

**This chapter is not a rung.** Every other chapter in the ladder adds a technique and goes
faster. This one is a *controlled comparison*: two kernels identical in every respect except one
`:multicast true` per load. It exists because the honest answer to "should I use multicast?" is
"it depends", and the dependence is measurable.

It is deliberately **slower than chapter 3**. Chapter 3 uses a 64×256 output tile and reaches
~268 TFLOPS; this pair uses 64×128 and reaches ~189/213. The narrower tile is the point — a
64×256 tile requires N ≥ 256, and plenty of real matmuls do not have that. The question here is
what multicast is worth **when your problem forces a narrower tile**.

## What multicast does

With a cluster of workgroups, one `load-tile` can fetch a tile **once** and have the hardware
deliver it into every cluster member's shared memory, instead of each workgroup fetching its own
copy. In a matmul, workgroups in the same cluster row want byte-identical `B`, so one fetch can
serve them all.

```lisp
(cluster-size :set-to (2 1))                                    ; two workgroups, along ROWS
(load-tile B (ring-get B-ring slot) (grid-x grid-k)
           :barrier (ring-get full slot) :swizzle :128b :multicast true)
```

`A` varies along the clustered axis, so it cannot multicast and does not ask to — the compiler
refuses a `:multicast` it cannot honour rather than silently declining.

## The measurement (H100 NVL, tf32, warmup=20 iters=100)

| N | Crisp | Crisp + multicast | multicast | vs cuBLAS |
|---:|---:|---:|---:|---:|
| 256 | 3.3 | 3.2 | −3.0% | 61% → 59% |
| 512 | 20.0 | 19.0 | −5.2% | 66% → 62% |
| 1024 | 100.3 | 94.2 | −6.1% | 76% → 71% |
| 2048 | 164.9 | 190.7 | **+15.7%** | 52% → 60% |
| 4096 | 188.8 | 212.8 | **+12.7%** | 50% → 56% |

## The lesson: two conditions, both required

Multicast pays only when **both** hold. Neither alone is enough, and that is what makes this
worth a chapter.

**1. The machine must be saturated.** The crossover above sits exactly where the grid fills the
GPU:

| N | CTAs | residency waves | multicast |
|---:|---:|---:|---:|
| 1024 | 128 | 0.24 | −6.1% |
| 2048 | 512 | **0.97** | +15.7% |
| 4096 | 2048 | 3.88 | +12.7% |

(This kernel uses 96 registers/thread → 4 CTAs/SM → 528 resident on 132 SMs.) Below saturation
there is no contention for L2 bandwidth to relieve, so multicast is pure overhead.

**2. The kernel must be fetch-limited, not compute-limited.** At chapter 3's *wider* 64×256 tile
the same change **loses 7–10%**, measured twice at both 2048 and 4096 — and that tile is equally
saturated (0.97 waves at N=2048). Its arithmetic intensity is 25.6 FLOP/byte against 21.3 here,
and its warp-specialised pipeline already hides operand fetch behind compute. Multicast cannot
speed up a fetch nobody is waiting on, while its bookkeeping is on the critical path regardless.

So: **saturated *and* fetch-limited.** Chapter 3 is saturated but compute-limited; this kernel at
N ≤ 1024 is fetch-limited but not saturated. Only the bottom two rows satisfy both.

## What is being compared, precisely

Both kernels declare the **same** `(cluster-size :set-to (2 1))`. The baseline never multicasts,
so the cluster buys it nothing — but forming a cluster of two is free (measured 0.97–1.01×), and
holding it constant means the only variable is the multicast itself.

One caveat stated honestly: the multicast kernel also upgrades its `empty` barrier to
`:mode :cluster`, and that is not an independent choice. With multicast the group leader writes
into its *peers'* shared memory, so it may not reuse a ring slot until those peers have drained
it — which a workgroup-local barrier cannot express. The measured gain is therefore *"multicast
and what it requires"*, not multicast in isolation.

## Why there is no hand-written competitor

The other chapters carry a `CUDA_Apples` kernel to show that Crisp's abstraction costs nothing
against a human writing the same algorithm. Here the claim is different and narrower — it is
Crisp-versus-Crisp, one keyword apart — so a hand-written mirror would answer a question nobody
asked. cuBLAS is retained only for scale, so the reader can see both variants sit at roughly
half of the vendor library rather than reading "+15.7%" as though it closed the gap.
