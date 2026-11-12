# Endeavour 214 (PARKED 2026-11-11) -- tcgen05 across an SM pair (`cta_group::2`)

2026-11-11, branch gpumode-convolv.  PARKED by Chris after step 1: the pair is exact on metal but buys ~8% only on
full-wave shapes and nothing on the contest's scored one, and a feature with no current user is not built.
The design (agreed in review) and the step-1 protocol below are the reference if a workload needs it.

## Why
The B200 matmul leaders (and CUTLASS's best sm100 configs, endeavour 209) run the Blackwell tensor
core in its 2-SM mode.  209 measured CUTLASS's 2-SM configs winning at 4096-8192 almost everywhere;
our matmul_v2 entry (v7, 230 us) is a 1-SM kernel at ~760 TFLOPS on the scored shape.

## The hardware, briefly
Two workgroups in a cluster whose ranks differ only in bit 0 form a **CTA pair** on two SMs.  With
`.cta_group::2`:
- **One MMA covers both.**  A single thread in the pair (by convention the even rank, "the leader")
  issues `tcgen05.mma.cta_group::2` with M = 256.  Each SM's tensor core computes 128 rows and writes them
  into **its own** tensor memory, at the same column address in both.
- **A is split by rows, B by columns.**  Each workgroup stages ITS 128 rows of A and **half of B's N
  columns** in its own shared memory, at the same offsets; the descriptors name one address, which is
  read in both.  So the pair fetches B once, not twice -- and each SM's per-stage shared memory
  for a 128 x 256 x 64 step drops from 48 KB to 32 KB (deeper ring, or wider N).
- **The plumbing is pair-wide.**  `tcgen05.alloc/dealloc/relinquish .cta_group::2` (one warp per
  workgroup, collectively); TMA loads with `.cta_group::2` so each workgroup's bytes complete on the
  **leader's** mbarrier; `tcgen05.commit.cta_group::2 ... .multicast::cluster` with a CTA mask so one
  commit signals the same barrier in both workgroups.
- The epilogue is unchanged: each workgroup's warps `tcgen05.ld` their own 128 rows.

(ISA details to be re-confirmed against the PTX ISA in step 1; written from CUTLASS's sm100 2-SM
pipeline and the 208 isa-notes.)

## What the author writes -- recommendation: the per-workgroup view, with an assertion

Crisp already has every cluster piece this needs (endeavour 152): `(cluster-size ...)`,
`:mode :cluster` barriers (arrivals written per workgroup, multiplied by the extent), and
`load-tile :multicast true`, which is an **assertion the compiler checks**, deriving the leader
and the mask itself.  2-SM MMA is the same idea one level down: both workgroups need the **same B
tile**, and instead of the TMA delivering it twice (multicast), the tensor core reads each half
where it lies.  So the kernel is v7, written per workgroup, plus a declaration and one key:

```lisp
(def-kernel matmul (A B &out C)
  (declare #'(a-mat b-mat &out c-mat)
           (cluster-size 2 1)                         ; a pair stacked along rows
           (global-size :derive-from C :strategy :strided)
           (local-size :set-to 192))
  (let ((A-ring (make-scratch-matrix-ring half (128 64) :ring-count 3))
        (B-ring (make-scratch-matrix-ring half (64 256) :ring-count 3 :split :cta-pair)) ; holds 64 x 128 here
        (D      (make-tcgen05-accumulator float (128 256) 0.0))         ; this workgroup's rows
        (full   (make-async-barrier-ring :ring-count 3 :mode :cluster :arrivals 2 ...))
        ...)
    (tile-stride C (128 256) (grid-y grid-x)
      (with-warp-specialization (:epilogue 4 :producer 1 :mma 1)
        (:producer ... (load-tile B (ring-get B-ring slot) (grid-k grid-x) :barrier .. :swizzle :128b))
        (:mma ... (tcgen05-accumulate-via-tile (128 256 64) D (ring-get A-ring slot) (ring-get B-ring slot)
                                               :swizzle :128b :b-major :mn :cta-pair true ...))
        (:epilogue ... (store-tile (to-half D) C (grid-y grid-x)))))))
```

`:cta-pair true` says "the other workgroup of my pair needs this same B tile, and computes the
next 128 rows".  The compiler checks it, or refuses, naming what conflicts:
- the cluster has extent 2 along rows (`(cluster-size 2 1)`), on sm_100a;
- B's `load-tile` coordinates ignore `grid-y` (the `:multicast` test, reused) and A's use it;
- the barriers that the pair shares are `:mode :cluster` (the arrivals rule then already reads right).

And it derives the rest -- none of it is writable by hand in a sane way, which is 152's argument:
| piece | lowering |
|---|---|
| B ring | declared `:split :cta-pair`: the logical pair tile (64 256), half of it (64 x 128) stored per workgroup; a `load-tile` into it fetches this workgroup's half, coordinates still in pair-tile units |
| loads | `.cta_group::2` TMA; completion lands on the leader's slot of `full` |
| the MMA | M = 256 in the instruction descriptor; issued only in the leader (the peer's `:mma` role waits on nothing) |
| `empty` / `acc-full` | `tcgen05.commit.cta_group::2 ... multicast::cluster`, mask 0b11 |
| `acc-empty` | both epilogues arrive on the leader's barrier (remote arrive: 152 step 5) |
| tensor memory | `tcgen05.alloc/dealloc/relinquish .cta_group::2` |
| entry / exit | a cluster barrier after the pair's alloc (neither side touches tensor memory before both have it) and before `dealloc` / exit: the leader's MMAs read the peer's shared memory and its commits signal the peer's barriers, so neither workgroup may tear down while the other can still use the pair's memory |

**Why the ring carries the tag (review, 2026-11-11).**  The first draft wrote a plain `(64 256)` ring
and let the compiler halve it because a downstream MMA said `:cta-pair` -- action at a distance: the
binding would misstate the SM's shared-memory footprint (3 stages in 96 KB, not 144), and the
analyzer would need a backward pass from the MMA operand to the `let`.  With `:split :cta-pair` on
the ring, every check is local: the ring knows it is split, `load-tile` into it fetches the half,
and `:cta-pair` on the MMA *requires* its B to be a split ring (refusal otherwise).  Declaring the
honest per-workgroup shape `(64 128)` instead was considered and rejected: `load-tile` scales its
grid coordinates by the declared extent, so the author would have to compute
`2 * grid-x + rank` by hand -- the rank arithmetic 152 keeps out of source.

**Rejected alternative -- the pair's view** (`tile-stride C (256 256)`, `(256 256 64)` MMA, a
`(256 64)` A ring).  Every declaration would describe storage that exists in no single
workgroup, and the epilogue's `store-tile` of a `(256 256)` D would silently store only half.  It
fights Crisp's per-workgroup model everywhere; the per-workgroup view changes one key.

## Questions (answered in review 2026-11-11, pending Chris's final word)
1. **Name.**  Explicit `:cta-pair true` -- never implied by `(cluster-size 2 1)`, which is also a
   legitimate shape for a multicast-TMA kernel with 1-SM MMAs.  `:cta-pair` over `:pair` (overloaded
   in Lisp); the same word tags the ring (`:split :cta-pair`).
2. **Barrier rewriting.**  Require `:mode :cluster` explicitly on the barriers the pair shares (152's
   rule: a barrier signalled across SMs says so, and its `:arrivals` then reads right).
3. **Persistent walk.**  Not needed: the tile grid beats persistent (209, and the probe below on
   the contest's shapes).  If it is ever wanted, the walk would have to move pairs, not single
   tiles (BUG 157's flat walk does not know about clusters).
4. **A multicast too?**  Later.  Keeping `:cta-pair` distinct from `cluster-size` is what makes it
   clean: `(cluster-size 2 2)`, the row pair `:cta-pair`, the column pair `:multicast` on A.

## Plan (steps)
1. **Price it before building it: hand-edited PTX.**  Take v7's generated PTX, edit it to
   `cta_group::2` by hand (alloc, idesc M = 256, half-B loads, leader-only MMA, multicast commits,
   remote acc-empty), and add `.reqnctapercluster 2, 1, 1` so the contest's plain `cuLaunchKernel`
   launcher (no `cuLaunchKernelEx`) launches pairs unchanged.  Include the entry/exit cluster
   barriers from the table: a fast workgroup that deallocates or exits while its peer is still in
   `tcgen05.ld` (or the leader's MMAs still read its shared memory) hangs or corrupts the probe and
   would be mistaken for a slow one.  Run on the B200 via popcorn (free).
   Proceed only if it is clearly faster than v7.
2. Analyzer: `:cta-pair` and its refusals (error specs first).
3. Codegen: the table above; PTX validator specs pinning the instruction forms and the descriptor.
4. Metal: popcorn B200 (exact vs cuBLAS) -> matmul v9.
5. Docs: ideal_001 Blackwell section, writing-crisp, the fold.

## Probe: persistent v7 (2026-11-11)
`contests/gpu-mode/06-matmul-v2/matmul_b200_tcgen05_mn_p.crisp`: v7 with one workgroup per SM (148 x
192), a 2-slot accumulator ring (all 512 columns) and a 4-deep TMA ring (192 KB); A/B by
`build_diag_b200_p.py`, popcorn B200 test 970717 (clear_l2_cache, median):

| shape | v7 tile grid (2 / SM, ring 2) | persistent (1 / SM, acc ring 2, ring 4) | cuBLAS |
|---|---:|---:|---:|
| 4096 x 5120 x 4096 (scored) | **226.1 us** | 228.4 us | 125.0 us |
| 8192^3 | **879.6 us** | 1018.9 us | 663.6 us |

Both exact (bad = 0).  Persistent is a wash on the scored shape and 16% slower at 8192 -- the same
answer 209 round 2 gave (dense fp16: tile grid +8-10%).  Two resident workgroups already overlap
one tile's epilogue with the other's mainloop, and they bring 8 epilogue warps per SM to drain tensor
memory against the persistent kernel's 4.  So scheduling is not where the gap is; the per-SM data
rate is, and that is what the pair attacks (B fetched once per pair, 32 KB per stage instead of 48).
The pair kernel therefore starts from v7's tile grid, not from a persistent walk.

## Step 1 -- hand-edited PTX (2026-11-11, in progress)
`put_temp_files_here/214/make_pair_ptx.py` edits v7's PTX (v7.ptx) into `pair.ptx`: `.reqnctapercluster
2, 1, 1`; alloc / relinquish / dealloc `.cta_group::2`; idesc M = 256 (272695312); MMA and both commits
`.cta_group::2`, commits `.multicast::cluster` mask 3; peer's MMA warp skips the wait and the issue;
producers load A + their half of B (columns `+128 * rank`, 2 boxes) with `.cta_group::2` TMA completing on
the leader's full[slot] (mapa), arrive remotely (`.release.cluster`, full count 4); epilogue arrives
on the leader's acc-empty (count 8); cluster barrier after init and before dealloc.  ptxas clean
first try (68 regs).  Diag `contests/gpu-mode/06-matmul-v2/build_diag_b200_pair.py`, popcorn B200 test.

| arm | 4096 x 5120 x 4096 | 8192^3 | note |
|---|---:|---:|---|
| v7 | 228 / 228 / 234 | 869 / 853 / 873 | three runs |
| v7 + `.reqnctapercluster 2,1,1` only | 230.3 | 854.0 | cluster launch is free (H1 out) |
| pair, ring 2 | 451.6 / 453.5 / 447.6 | 1949 / 2035 / 1886 | **exact** (bad = 0), 2x slower |
| pair, ring 3 (half-B slots, 96 KB) | 455.6 | 1874.9 | depth does not help (H2 latency out) |
| pair, ring 4 (128 KB, 1 CTA / SM) | 510.8 | 2834.4 | forced onto separate SMs: worse (same-SM placement out) |

The protocol is CORRECT on metal -- leader / peer roles, the B split, multicast commits, remote
barriers, teardown -- which de-risks the codegen.  The 2x is not latency, occupancy or placement.

**The 2x was the full-barrier arrive** (test 970733):

| arm | 4096 x 5120 x 4096 | 8192^3 |
|---|---:|---:|
| v7 | 226.3 | 873.5 |
| pair, both producers arrive remotely `.release.cluster` | 449.5 | 1875.1 |
| pair, **leader-only local arrive** expecting both CTAs' bytes (`pairL`) | **248.9** | **859.1** |
| pair, remote arrives `.relaxed.cluster` (`pairX`) | 250.7 | 879.8 |

A cluster-scope release on every k step's arrive doubled the kernel -- F-209-9 again (a cluster-scope
fence cost the multicast kernel 45%).  CUTLASS's protocol: only the leader arrives (locally, `expect_tx`
= the pair's bytes), the peer's TMA merely completes on the leader's barrier.  **Codegen rule for
step 3:** never put a cluster-scope release on the per-k-step path; the full ring stays count 2 and
lives in the leader.  (The ring-3 / ring-4 rows above were measured under the slow arrive and are
re-run on pairL.)

**Ring depth on the fixed arrive** (test 970734): pairL ring 2 / 3 / 4 / 6 = 250.9 / **234.5** / 232.5 /
281.8 us on the scored shape (v7 228.3), 863 / **812** / 957 / 1390 at 8192^3 (v7 875).  Ring 3 (half-B
slots, 96 KB, still two CTAs per SM) is the pair's shape; one CTA per SM (ring 4, 6) loses, as in 209.

**Wave quantization** (test 970745; TFLOPS = 2MNK / time):

| shape | tiles / waves (296 slots) | v7 | pair r3 | cuBLAS |
|---|---|---:|---:|---:|
| 4096 x 5120 x 4096 (scored) | 640 / 2.16 | 746 | 726 | 1198 |
| 9472 x 2048 x 4096 | 592 / 2.00 | 959 | **1041** | 1409 |
| 9472 x 3072 x 4096 | 888 / 3.00 | 941 | **999** | 1467 |
| 8192^3 | 2048 / 6.92 | 1247 | **1345** | 1637 |

Readings:
- The pair is worth **+7-9% wherever the waves are full** and -3% on the scored shape.
- The scored shape loses ~22% to quantization alone: v7 runs 746 TFLOPS there against ~950 on full-wave
  shapes with the same K.  No MMA mode changes that; it needs smaller or uneven work units in the
  last wave (split-K / stream-K, or a tile shape whose count fits 296), i.e. scheduling.
- Short K costs too: ~950-1040 TFLOPS at K = 4096 against 1250-1345 at K = 8192 -- per-tile
  prologue / epilogue that the two resident CTAs do not fully hide.

## Step 1 verdict (2026-11-11)
The hand-edited pair is exact on metal and the protocol is now known (incl. the arrive rule), but it
does not clear this doc's bar ("clearly faster than v7") on the contest's scored shape.  Building
214 buys ~8% on large, full-wave matmuls -- a general capability, not a contest lever.  Decision for
Chris: build 214 now for that 8%, or park it (doc + PTX scripts are the reference) and spend the next
step on the scored shape's real losses (last-wave quantization, short-K per-tile overhead).
Artifacts: contests/gpu-mode/06-matmul-v2/pair_probe/ (make_pair_ptx.py, make_pair_ring.py, make_pair_arrive.py; run
in a directory holding v7.ptx, dumped from build_kernel(B200_TCMN)),
contests/gpu-mode/06-matmul-v2/build_diag_b200_pair.py.
