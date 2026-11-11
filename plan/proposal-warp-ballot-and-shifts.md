PROPOSAL -- warp ballot, cheap shifts and rotates
=================================================
2026-11-10, from the sort_v2 resume (branch resume-gpumode).  For discussion; nothing here is built.

Why now
-------
The radix sort (contests/gpu-mode/07-sort-v2/sort_radix.crisp, "v1i") is at 3150 us for 100M keys on H100
(per pass: upsweep 150, scan 51, downsweep 783).  Every lever that needed no language change has been
pulled (32-bit tile math, tile-major histograms, input-sized scan, 128-bit loads).  The downsweep is 77%
of the time and it is INSTRUCTION-bound, not memory-bound (v1d: -9% SASS gave -16% time).  What is left in
it is two things Crisp cannot spell cheaply:

1. **A run-time shift / rotate.**  `(ash x n)` is defined for every n (either sign, any size), so with a
   run-time n it lowers to a branch-free select chain (~10 instructions; `%185-ash-body`).  The downsweep
   rotates each key once on load and once on store by the pass's shift.
2. **A warp vote.**  The local sort is two 4-bit counting splits, each with a 4096-counter workgroup scan
   and four barriers.  The standard GPU answer (CUB's BlockRadixRankMatch / Onesweep) ranks keys by a full
   8-bit digit in ONE pass using warp ballots: 8 ballots give each lane the mask of lanes holding the same
   digit; popcount of that mask below the lane is the rank.

Evidence, measured
------------------
* **Shift/rotate (measured on metal, 2026-11-10, submission 970311).**  A probe with four downsweep copies,
  each with the shift as a literal (0/8/16/24) so the rotate is one SHF, picked per pass by the runtime.
  The results stay correct (torch.equal True at 100M / 10M / 1M).
  - SASS (ptxas sm_90a): downsweep 3056 -> 2608 instructions (-15%; SEL 528 -> 392, ISETP 260 -> 154).
    Registers 56 -> 40.
  - H100, 100M: downsweep 783 -> ~690 us per pass (-12%); wall 3150 -> 2892 us (-8%).
  - That is the CEILING for a run-time rotate/shift builtin: a run-time `shf.r.wrap` is the same single
    instruction as the literal one.
* **Ballot: not measured yet.**  The estimate below is arithmetic, and the first step of that half of the
  plan is a probe to replace it (see Staging).

Part A -- shifts and rotates (small, self-contained)
----------------------------------------------------
Spelling (integer types; `n` any integer type):

| form | meaning | PTX | SPIR-V |
|---|---|---|---|
| `(shift-left x n)`  | x << (n mod bits) | `shl` (+ `and` unless the range is known) | `OpShiftLeftLogical` of `n & (bits-1)` |
| `(shift-right x n)` | x >> (n mod bits); logical for unsigned, arithmetic for signed | `shr.u` / `shr.s` | `OpShiftRightLogical` / `Arithmetic` |
| `(rotate-left x n)`, `(rotate-right x n)` | rotate by n mod bits | `llvm.fshl/fshr(x, x, n)` -> `shf.l/r.wrap` | OpenCL.std `rotate`, or the LLVM SPIR-V backend's funnel-shift expansion |

* **Count semantics: modulo the width (OpenCL C's rule).**  This is the cheapest thing that is DEFINED on
  every target.  LLVM's shifts are poison for n >= bits, and SPIR-V's are undefined, so "n mod bits" costs
  at most one `and`, which LLVM drops whenever it can prove the range (it already does for the downsweep's
  nibble counters: `(* (logand d 7u) 8u)` became a bare `shl.b64`).  The alternative, "n >= bits gives 0",
  is what `ash` does and needs the compare + select we are trying to lose.
* **`ash` stays as it is**: the Lisp-faithful, defined-everywhere shift.  The new forms are the
  "I know what I am doing" spelling, the way `shuffle-xor` sits beside `reduce-warp`.
* **AD.**  They are integer operators: list them beside ASH / LOGAND / POPCOUNT in autodiff.lisp:970.
* **Hook.**  The same pattern as `%185-ash` in codegen.lisp: `%hw-lower` methods with `%185-helper-call`
  (noinline on SPIR-V only -- the BUG 120 family), so each must be BMG-validated on metal, which is
  part of the definition of done anyway.
* **Sort payoff.**  `rot-right` / `rot-left` become one form each.  The upsweep's per-key
  `(logand (ash k (- shift)) 255u)` also becomes `(logand (shift-right k shift) 255u)`, which ptxas can
  fuse into one `bfe`.  Expected: up to the ~280 us measured above at 100M.

Part B -- warp vote (the real lever, bigger)
--------------------------------------------
The design document already has the spelling (ideal_001.md, "Ballot Operations", status not implemented):

* `(warp-ballot pred) -> uint` -- bit L set iff lane L's predicate is true.
* `(warp-any? pred)`, `(warp-all? pred) -> bool`.

Lowering:

| form | PTX | SPIR-V |
|---|---|---|
| `warp-ballot` | `llvm.nvvm.vote.ballot.sync(0xffffffff, p)` | `__spirv_GroupNonUniformBallot(Subgroup, p)`, component 0 of the uvec4 |
| `warp-any?` | `llvm.nvvm.vote.any.sync` | `__spirv_GroupNonUniformAny` |
| `warp-all?` | `llvm.nvvm.vote.all.sync` | `__spirv_GroupNonUniformAll` |

* **Collective rules.**  These are the shuffles' rules verbatim: add all three to
  `*warp-collective-operator-names*` (codegen.lisp:8285), so the uniformity check, the SPIR-V
  subgroup-size pinning (needs `--hardware-profile`), and the BUG 141 nested-loop restriction all apply
  for free.  The full mask is correct because Crisp only allows a collective under warp-uniform control.
  The results of `warp-any?` / `warp-all?` / `warp-ballot` are themselves warp-uniform, which the
  uniformity pass should learn, the way it knows `reduce-warp`'s result is uniform.
* **Width.**  A uint covers 32 lanes (NVIDIA) and 16 (BMG).  A 64-wide target would need `ulong`, so I
  suggest the type be "uint when the profile's warp-size <= 32" and an error otherwise, until such a
  target exists.
* **AD.**  The result is an integer mask (or a bool): not differentiable, so it goes on the same list.
* **What it does NOT need.**  I'd leave out `warp-match-any` (PTX `match.any.sync`), and lane masks such
  as `%lanemask_lt`:
  - `match` has no SPIR-V core equivalent, and 8 ballots do the same job portably.  That is CUB's own
    fallback path.
  - The lane mask is `(- (shift-left 1u (warp-lane)) 1u)`, two instructions once Part A exists.
  - Both can come later if a probe shows they matter.

What the downsweep would become (sketch, 8-bit digit d of a key held by every lane, all lanes active
because the tile is padded with the largest key as it is today):

```lisp
;; warp-private digit counters: wcnt[warp * 256 + digit]
(let ((peers (lognot 0u)))
  (dotimes+ (b 8u)                                   ; uniform, unrolled: 8 ballots
    (let ((bit (= (logand (shift-right d b) 1u) 1u))
          (v   (warp-ballot bit)))
      (set! peers (logand peers (if bit v (lognot v))))))
  (let ((below (popcount (logand peers (- (shift-left 1u (warp-lane)) 1u))))
        (c     (~ wcnt (+ wbase d))))                ; every peer reads the same old count
    (sync-warp)
    (when (= below 0u)                               ; the lowest peer bumps it
      (set! (~ wcnt (+ wbase d)) (+ c (popcount peers))))
    (sync-warp)
    (+ c below)))                                    ; this key's rank within (warp, digit)
```

16 rounds of that per thread, then ONE scan of the 256 x (warps) counters in (digit, warp) order, then
each key goes straight to its place in the sorted tile.  Compared with today:
* one 8-bit ranking instead of two 4-bit splits: two counter scans and four barriers become one scan and
  two barriers, and one shared-memory scatter instead of two;
* the "where does each digit's run start" loop disappears, because the scan already gives it;
* stability holds if warp w owns tile positions [w*512, (w+1)*512), round-major, which is also a coalesced
  load.

Arithmetic estimate, per key: ~25 instructions for the ballot ranking, against ~55 today for the two
splits.  If the downsweep stays instruction-bound, that is on the order of a further -30% of it, on top of
Part A.  **This is the number the probe must confirm before we build anything.**

Staging (each step is a go / no-go for the next)
------------------------------------------------
1. **Part A** (shift-left / shift-right / rotate-left / rotate-right), with specs, BMG metal and AD
   listing.  Small; its value is already measured (~-8% wall at 100M).  The sort uses it straight away.
2. **Ballot probe (no compiler work).**  A CUDA C twin of the downsweep with the ballot ranking, run
   through popcorn on the H100 in test mode next to the Crisp downsweep, results checked.  That turns
   the -30% guess into a number.  This is the "probe before building" rule (memory: gpumode-per-case-diag).
3. **Part B** only if step 2 pays: warp-ballot / any? / all? with specs (PTX + BMG metal), the uniformity
   pass taught that their results are warp-uniform, and docs (writing-crisp.md, ideal_001.md status).
4. The sort's downsweep rewritten on ballots, BMG bit-exact, then the H100 diagnostic and the leaderboard.

Decisions (Chris, 2026-11-10)
-----------------------------
* Names: `shift-left` / `shift-right` / `rotate-left` / `rotate-right`.
* Count semantics: modulo the width (OpenCL C's rule).
* `warp-ballot` returns `uint`; a profile whose warp-size is over 32 is a compile error until such a target
  exists (option a).
