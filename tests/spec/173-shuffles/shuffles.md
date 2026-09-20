Endeavour 173 — Shuffles
========================

We are working towards support of reductions (endeavour 175), but first we need the
supporting work. 172-do-times-variants brought in `dec-times-by-half+` and friends; proper
warp reductions also need shuffle support. So let's do that now.

Ops in this endeavour:

- [ ] `warp-size`
- [ ] `shuffle`
- [ ] `shuffle-up`
- [ ] `shuffle-down`
- [ ] `shuffle-xor`

Explicitly **out of scope** (they were only in the same section of the design doc):
`in-warp`, `warp-ballot`, `warp-any?`, `warp-all?`.

Plan
====

- [x] write tests
- [x] consider A|D requirements, write more tests
- [ ] implement main portion
- [ ] add support for A|D
- [x] update docs with any API changes/remarks (`docs/ideal_001.md`, "Warps & Shuffles")


Decisions
=========

**D1 — `warp-size`, not `get-warp-size`.** Matches the existing `warp-id` / `warp-lane` /
`warp-count` family, which already drop the `get-` prefix. The design doc's
`(get-warp-size)` spelling was off-convention and has been corrected throughout.

Note `warp-count` (warps per workgroup) and `warp-size` (lanes per warp) are different
things and will be confused; the doc now says so explicitly.

**D2 — `warp-size` is a COMPILE-TIME constant**, resolved from the active hardware
profile's `:simd-width`, defaulting to 32 with no profile. It must fold to a literal so it
is legal as a loop limit, as a `(local-size :set-to ...)` value, and as an operand of a `+`
uniform loop form. A runtime `SubgroupSize` builtin could not be any of those.

**D3 — `width` is in scope now, even though segmented reductions are a 1.0 concern.** It is
nearly free on the path that matters (see D5), it changes nothing about A|D (see D8), and
it turned out to be what makes the test suite portable at all (see F2). Adding it later
would mean reopening the AD rules.

**D4 — `width` must be a compile-time power of two, not wider than `(warp-size)`.** PTX
would tolerate a register (clamp/segmask live in the `c` operand), so this is a deliberate
Crisp restriction: the other two rules are only checkable statically, a lane-varying width
is meaningless, and a constant folds the SPIR-V segment arithmetic away.

**D5 — `shuffle-xor` rejects `lane-mask >= width`.** XOR by a mask smaller than the segment
can never leave it, so a segmented xor and an unsegmented one are the *same instruction*.
The only case where `width` is observable on xor is `mask >= width`, and that request is
self-contradictory. Rejecting it beats inheriting whatever the clamp hardware does (the two
backends need not agree, and neither behaviour is useful).

**D6 — a shuffle is a warp collective; divergent use is a compile error.** Reuses the 111
Phase 1 machinery (`*in-divergent-conditional*` / `%tlc-check-not-divergent`) rather than a
second checker. This is what licenses emitting an unconditional full membermask on PTX.

**D7 — on SPIR-V, a shuffle without a pinned subgroup size is a compile error.** 156 emits
the SubgroupSize execution mode only under a deliberately narrow guard (profile names
`:simd-width`, local-size compile-time known, work-items a whole multiple of it). That
guard must stay narrow — a thousand shipped specs depend on it. So the requirement belongs
to the *shuffle*: if a kernel shuffles and cannot be pinned, say so. Never guess at 32. On
Intel the driver picks 8/16/32, and a reduction written for 16 that runs on 32 returns a
wrong answer rather than crashing.

**D8 — A|D rules.** A shuffle is a gather across lanes, so its adjoint is a scatter-add.

| forward | adjoint | cost |
|---|---|---|
| `shuffle-xor v m w` | `shuffle-xor adj m w` (involution — self-transposing) | free |
| `shuffle-up v d w` | `shuffle-down adj d w` + edge lanes self-contribute | cheap |
| `shuffle-down v d w` | `shuffle-up adj d w` + edge lanes self-contribute | cheap |
| `shuffle v <const> w` | the inverse permutation | cheap |
| `shuffle v <runtime> w` | **compile error** | — |

The runtime-index case is a genuine scatter-add: several lanes may read the same source, so
the adjoint must sum an unknown number of contributions, which is not a shuffle. It is a
hard error — **not** `forward-only`, and **not** a `%backward-skip-fn-p` entry (a shuffle
carries a value, so per the skip-list rule it must never go on that list).

**D9 — 64-bit decomposition is in scope.** The hardware shuffle moves 32 bits. The design
doc's own flagship example sums an `(in-vec long)`, and 175 will want `double` reductions,
so `long`/`double` are on the critical path, not an extra.

**D10 — the A|D specs use unrolled shuffles, not loops.** A shuffle inside a
`dec-times-by-half+` would drag in reverse-order loop replay (149 replays forward
statements backward; a descending uniform loop must reverse to an ascending one). That is a
175 prerequisite and is deliberately isolated from 173.


Test ladder
===========

Forward specs are **exact permutation fingerprints**, not aggregates — a sum would hide
precisely the edge-lane bugs that matter. Seed is `v(L) = 10L + 7` so that lane INDEX and
lane VALUE stay distinguishable (a result of `27` is unambiguously lane 2's data). Every
lane shuffles unconditionally; only the store is gated.

| spec | pins |
|---|---|
| `01-warp-size-uniform` | `(warp-size)` folds and is uniform — legal as a `+` loop limit |
| `02-shuffle-xor-metal` | xor masks 1 and 2, full warp |
| `03-shuffle-idx-metal` | broadcast, and neighbour read (the unsegmented control for 05) |
| `04-shuffle-up-down-edges-metal` | delta 1 both directions; the LOWER edge keeps its own value |
| `05-shuffle-width-idx-metal` | `width 4` — differs from 03 in exactly one lane, and that lane is the feature |
| `06-shuffle-width-up-down-metal` | `width 4`, delta 2 — BOTH segment edges, two lanes each |
| `07-shuffle-64bit-metal` | `ulong` hi/lo decomposition; seeds exceed 2^32 so both halves must move |
| `08-shuffle-double-metal` | `double` decomposition; the fraction lives in the low mantissa |
| `errors/01` | width not a power of two |
| `errors/02` | width wider than the warp |
| `errors/03` | xor mask crosses its segment (D5) |
| `errors/04` | shuffle in a divergent conditional (D6) |
| `errors/05` | width not compile-time (D4) |
| `errors/06` | SPIR-V without a pinned subgroup size (D7) |

A|D specs are profile-pinned to `bmg` (D7 requires a pinned subgroup size on SPIR-V anyway,
and it makes the geometry deterministic at 16 lanes). All are **unrolled** per D10. Geometry
follows `146/01`: 64 threads over `4x16`, one element per thread — never a shared cell,
which would accumulate once per thread in the backward and measure the warp width instead of
the derivative.

| spec | pins | wrong answer if broken |
|---|---|---|
| `09-diff-shuffle-xor` | involution: adjoint is the same op. `d/dA[2] = w(3) = 4.0` | `3.0` if the adjoint skips the shuffle |
| `10-diff-shuffle-up-down-edges` | both transposes AND both edge self-terms; `width` passes through A\|D. `d/dA[0] = 3.0`, `d/dB[3] = 7.0` | `2.0` / `3.0` if the edge term is dropped |
| `11-diff-shuffle-static-index` | a literal target is a broadcast, so its adjoint is a 16-way fan-in. `d/dA[2] = 16.0` | `32.0` if the subgroup size is not pinned |
| `12-diff-shuffle-double` | the same rule through the 64-bit decomposition, at a tighter `atol` | a half-transposed adjoint |
| `errors/07` | runtime target rejected under `--differentiate` (D8) | — |

**The weight is not decoration.** `VERIFY-AUTODIFF` differentiates `sum(C)`, and a sum is
permutation-invariant: unweighted, `d sum(C)/dA[k]` reads `1.0` for every `k` whether or not
the shuffle happened. Weighting by `col + 1` breaks that symmetry so a misdelivered adjoint
lands on a different number. `11` is the exception — a broadcast is already asymmetric, so it
needs no weight.


Findings from writing the tests
===============================

**F1 — `width` is invisible on `shuffle-xor`.** See D5. There is consequently no metal test
for width+xor, only the negative one. Worth knowing before someone goes looking for it.

**F2 — `width` is what makes the suite portable.** The L0 hoist harness gives a rank-1
tensor exactly 4 elements (hardcoded in `%l0-emit-tensor-arg`; the only override is
`:tile-shape` pad-up), and the warp's *upper* edge sits at lane 31 on NVIDIA but lane 15 on
BMG — unpinnable in a single `HOIST-EXPECT`. `(width 4)` pulls both segment edges into
lanes 0..3, so `06` tests the upper-edge rule portably. Without `width`, only the lower edge
was ever testable.

**F3 — `CHECK-FAIL` matches the FILENAME, not just the kernel name.** The check is
`(search expected (concat stdout stderr))` and the path is passed as argv, so
`CHECK-FAIL: "exceeds"` inside `02-width-exceeds-warp-size.crisp` passes vacuously. Four of
the six negative specs here were written that way before it was caught. Our standing note
only warned about kernel names.

**F4 — negative specs take flags via `CHECK-FAIL-FLAGS:`, not `TEST-WITH[...]`,** and
`CHECK-FAIL` is only read from the first 5 lines of the file (`CHECK-FAIL-FLAGS` from the
first 8).

**F5 — `hardware-stride :warp-idx` has a live BMG bug.** `src/analysis/control.lisp` says
the chunk size is "currently hardcoded to 32 as a placeholder for `(get-warp-size)`", so on
a `:simd-width 16` profile it strides by 32 over 16-lane warps. Implementing D2 fixes it as
a side effect. Candidate for `plan/bugs.md`.

**F6 — `GET-WARP-SIZE` is already half-wired.** It is registered `:uniform` in
`%uni-builtin-state` (`src/analysis/core.lisp`), and `139-warp-specialization.md` claims the
builtin "EXISTS (from 111/115)". It does not. The uniformity entry should be reconciled to
`WARP-SIZE` per D1.

**F7 — `let*` compiles forward but breaks `--differentiate`, and blames `SET!`.** Found by
writing the A|D specs: all four failed with

    Function SET! is not differentiable.

with no shuffle involved at all — a kernel with `let*` and a plain `(* 2.0 (~ A row col))`
reproduces it. The same kernel with `let` differentiates fine, and the `let*` version
compiles fine *without* `--differentiate`.

The reason `let*` was never needed is the real finding: **Crisp's `let` is already
sequential** (let\*-like) — stated in `167/09`'s header and relied on by `145/14`. So `let*`
is redundant, and the specs here use `let`.

That leaves a compiler bug worth its own entry: `let*` should either be rejected outright
(`Unsupported form LET*`) or differentiate. Compiling forward and then failing backward
under another form's name is the same misattribution shape as the "`GRID-Y` is not
differentiable" ANF bug. Candidate for `plan/bugs.md` alongside F5.


Implementation notes
====================

Already in place: `warp-id` / `warp-lane` / `warp-count` with both lowerings
(`src/codegen.lisp`, the `:warp-*` cases); the divergence checker; `:simd-width` in
`def-hardware-profile`; the 156 SubgroupSize pinning; 172's uniformity-checked `+` forms.

Lowerings needed:

| op | PTX | SPIR-V |
|---|---|---|
| `shuffle` | `shfl.sync.idx.b32` | `OpGroupNonUniformShuffle` |
| `shuffle-up` | `shfl.sync.up.b32` | `OpGroupNonUniformShuffleUp` |
| `shuffle-down` | `shfl.sync.down.b32` | `OpGroupNonUniformShuffleDown` |
| `shuffle-xor` | `shfl.sync.bfly.b32` | `OpGroupNonUniformShuffleXor` |

PTX packs clamp/segmask into the `c` operand (verify the exact per-mode encoding against the
ISA doc when implementing). SPIR-V has no width operand at all, so segmentation is
synthesised: free for xor (D5), a masked target index for idx, and a boundary predicate plus
select for up/down. Capability `GroupNonUniformShuffle`.
