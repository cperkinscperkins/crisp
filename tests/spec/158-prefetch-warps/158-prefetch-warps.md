# 158 — `prefetch-tile` warp partitioning

## Why

Round 2 of the roofline probe (`benchmarks/matmul/_probe_roofline/`) measured prefetch at the
shipped 16-subgroup geometry as **2.6–2.9x SLOWER**. That is not a result about prefetch. It is a
result about `prefetch-tile`, which has no notion of warps, so **every one of the 16 subgroups
issued every one of the 24 prefetches** — 384 per workgroup per K-step against 256 loads.

SYCL-TLA does not do that. Its mainloop builds the prefetch as a TiledCopy and slices it per
thread:

```cpp
auto prefetch_a     = make_block_2d_prefetch(copy_a);      // <ValType, sg_count>
auto thr_prefetch_A = prefetch_a.get_slice(thread_idx);
auto pAgA           = thr_prefetch_A.partition_S(gA);
```

Until Crisp can express that, "prefetch measured 2.6x slower" is an uninterpretable negative —
exactly the kind of note that stops the next person for the wrong reason, the way endeavour 156's
premise was "falsified" for a whole endeavour because multi-subgroup was only ever tried at K=16.

**This endeavour is about making prefetch measurable, not about making it win.** Round 1 showed
fetch and math are already ~95% overlapped, so prefetch can only pay through memory-level
parallelism among the loads, and arm C's headroom looks address- or locality-shaped. A flat result
here is a perfectly good outcome; an *interpretable* one is the requirement.

## The API

```lisp
(prefetch-tile A (grid-y prefetch-k) :size (128 32) :warp-partitioned true)
```

`:warp-partitioned` and nothing more.

**Why not a `:warps` boolean mask** (the first proposal, rejected): on `make-register-tile` the
mask carries real information, because under warp specialization some warps genuinely do not hold
the tile. A prefetch has **no destination**, so there is nothing a warp can fail to hold — the mask
would be all-`true` in every kernel forever, i.e. a keyword that can only be got wrong.

`:size` is the **workgroup footprint** (the same units as the matching `load-tile`), and the
compiler tiles it into legal hardware blocks and distributes them. The user never writes a block
index. Compare — this is the CURRENT hand-tiled form for the same thing, and the reason the
keyword is worth having at all:

```lisp
;; before: 24 forms, hand-derived, with the 16-column hardware limit hand-applied
(prefetch-tile A ((+ (* grid-y (to-ulong 4)) (to-ulong 0))
                  (+ (* prefetch-k (to-ulong 2)) (to-ulong 0))) :size (32 16))
;; ... 23 more ...
```

## The target kernel, in full

The thing this endeavour has to make work. Written BEFORE the implementation, deliberately — and
it already earned that: writing it is what surfaced the mask-is-always-true problem.

```lisp
(declaim (precision fast))
(def-type a-mat (matrix half :address-space :global :align :compact :contiguous-term :row-major))
(def-type b-mat (matrix half :address-space :global :align :compact :contiguous-term :row-major))
(def-type c-mat (matrix float :address-space :global :align :compact :contiguous-term :row-major))

(def-kernel matmul (A B &out C)
  (declare #'(a-mat b-mat &out c-mat)
           (global-size :derive-from C :strategy :strided)
           (local-size :set-to 256))
  (let ((A-tile (make-register-tile half  (128  32) 0.0 :operand :a :warps W16))
        (B-tile (make-register-tile half  ( 32 256) 0.0 :operand :b :warps W16))
        (C-tile (make-register-tile float (128 256) 0.0               :warps W16))
        (n-k-steps (/ (to-ulong (inner-dimension A B)) (to-ulong 32))))
    (tile-stride C (128 256) (grid-y grid-x)
      (progn
        (dotimes (grid-k n-k-steps)
          (let ((prefetch-k (+ grid-k (to-ulong 2))))
            (when (< prefetch-k n-k-steps)
              (prefetch-tile A (grid-y     prefetch-k) :size (128  32) :warp-partitioned true)
              (prefetch-tile B (prefetch-k grid-x)     :size ( 32 256) :warp-partitioned true))
            (load-tile A A-tile (grid-y grid-k))
            (load-tile B B-tile (grid-k grid-x))
            (mma-accumulate-via-tile (8 16 16) C-tile A-tile B-tile)))
        :epilogue
        (store-tile C-tile C (grid-y grid-x))))))
```

(`W16` above stands for the literal 16-element all-true `:warps` mask the register tiles already
require; it is written out in the actual spec files.)

Two things this shape already tells us:

1. **The prefetch coordinates are in the same units as the matching `load-tile`** — `(grid-y
   prefetch-k)` against `(grid-y grid-k)`. That is the whole readability argument, and it only
   works because `:size` is the footprint rather than a hardware block.
2. **Both prefetches sit inside ONE `when`** — which is the `v1_one_when` shape, and that shape
   WORKS. Together with a branch-free distribution, that is why BUG 051 (below) does **not** stand
   between us and this kernel. An earlier draft of this document claimed the opposite; writing the
   kernel out is what showed it was wrong.

## Irregularity is the NORMAL case

At 16 warps with 32x16 blocks, in this one kernel:

| operand | footprint | blocks | over 16 warps |
|---|---|---:|---|
| A | 128x32 | 4x2 = **8** | 8 warps get one, 8 get none — **irregular** |
| B | 32x256 | 1x16 = **16** | exactly 1 each — regular |

Both cases occur in the same kernel, so this is not an edge case to defer. Three ways to resolve:

1. **Idle warps** — needs a branch, which hits BUG 051.
2. **Duplicate assignment** — warp 8 re-prefetches block 0. Branch-free, and legitimate because a
   prefetch is a HINT: the cost is one instruction and a second touch of an already-warm line.
   Still 1 per warp against today's 24.
3. **Compiler picks the block shape to fit the warp count** — if 16r x 16c is legal for 16-bit, A
   becomes 8x2 = 16 blocks, exactly 1 per warp, and the irregularity disappears. Legality unknown;
   cheap to test, and an illegal shape fails at MODULE BUILD rather than at compile time.

Plan: try 3, fall back to 2, never 1.

## BUG 051 — `prefetch-tile` is dropped inside branches

Found while bisecting why the first `:warps` desugaring emitted 2 prefetches instead of 24. Same
kernel, one construct changed, counting `Subgroup2DBlockPrefetchINTEL` in the emitted SPIR-V:

| variant | construct | emitted | expected |
|---|---|---:|---:|
| `v3_no_when` | 4 bare `prefetch-tile` | **4** | 4 OK |
| `v1_one_when` | one `when` holding all 4 | **4** | 4 OK |
| `v2_four_when` | four SIBLING `when`s, 1 each | **1** | 4 BAD |
| `v4_nested_if` | nested `if` chain | **0** | 4 BAD |
| `v5_when_loads` | two sibling `when`s holding `load-tile` | **16 loads** | 16 OK |

`v5` is the control that matters: sibling `when`s are **not** broken in general. The loss is
specific to `prefetch-tile`, the one statement here that is void and yields no value.

**CAUSE IS A HYPOTHESIS.** The branching analyzers look value-oriented, and a branch whose body
yields nothing appears to be discarded; `load-tile` survives because it writes a register tile.
That is the same family as the recorded `crisp.compiler::cond` quirk ("drops the value when a
clause has only a test, no body"). Confirm before believing.

**Round-2 arm B is unaffected**: `probe_loads_pf2/pf3` put all 24 prefetches inside a SINGLE `when`
(the `v1` shape) and the SPIR-V confirmed all 24. That measurement stands as taken.

## Specs

Written FIRST, and all of them RED. The API they describe does not exist yet.

| spec | pins |
|---|---|
| `errors/unknown-warp-count` | `:warp-partitioned` with no statically known `local-size` is refused |
| `errors/untileable-footprint` | a footprint that does not tile into whole hardware blocks is refused |
| `errors/non-16bit-element` | a non-2-byte operand is refused (block shape is element-width dependent) |
| `01-warp-partitioned-spv` | **the distribution actually takes** — at most one prefetch per subgroup |
| `02-unpartitioned-unchanged-spv` | `prefetch-tile` WITHOUT the keyword is byte-for-byte untouched |

Two validators are part of the implementation, not of the spec:
`validate-spv-prefetch-partitioned` and `validate-spv-prefetch-unpartitioned`, each defined in
BOTH `tests/run-specs.lisp` and `:crisp.compiler` delegating to one shared body — the two-package
convention endeavours 152/155/157 all landed on.

**Rung 01 is the one that matters, and it cannot be a benchmark.** A kernel that is 16x
over-issued is still numerically CORRECT, so no correctness check can catch it, and a timing can
only tell you something is wrong, never what. The assertion has to be on the emitted SPIR-V.

Still to write, once the above are green: the target kernel at rung `03`, and
`TEST-HOIST[L0]` + `MMA_CORRECT` on metal at rung `04`.

## BUG 051 is NOT a blocker for this endeavour

Recorded because it is a real defect — a user can write sibling `when`s each holding a
`prefetch-tile` today and silently lose all but one — but it does **not** stand between us and the
target kernel, and this endeavour should not chase it:

- the target kernel puts BOTH prefetches inside ONE `when`, which is the `v1_one_when` shape, and
  that shape **works** (4 of 4 emitted);
- the distribution is **branch-free** by design, so the compiler never generates the sibling
  branches that trigger it.

051 is therefore a latent defect in the pre-existing *coordinate* form of `prefetch-tile`, found
incidentally while bisecting the prototype. Its reproduction lives in
`put_temp_files_here/bug-051-repro/` — deliberately NOT under `tests/spec/`, because the runner
globs `**/*.crisp` and two of those five variants encode BUGGY output as though it were expected.

## Status

**Specs written, implementation not started.** The `:warps` spelling and the desugaring currently
in `overlays/crisp-compiler-overlay.lisp` are a PROTOTYPE that this document supersedes:
`:warp-partitioned` replaces the mask, and a branch-free distribution replaces the per-warp `when`
chain. That prototype is fenced with a SUPERSEDED marker in the overlay; rewrite, do not merge.
