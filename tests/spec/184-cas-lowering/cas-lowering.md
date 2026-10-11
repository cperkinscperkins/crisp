The benchmarks both benchmark a ladder of "techniques" and compare top-techniques (for any size) against other Crisp contenders.  We've been benchmarking the reductions lately, and when working the ladder noticed that that reduction via CAS was slow on both Intel and NVidia. See ./benchmarks/REPORT-reduction.md

This new endeavor is to investigate and fix that. You remarked earlier that you thought it might be a lowering issue.  Functionally, I imagine the reductions via CAS should already be under test under 175-reductions. Not sure if there will be the need for more tests as this is addressed.


---

Findings (2026-10-10)
=====================

Confirmed a lowering issue.  Detail: `put_temp_files_here/184/findings.md`.

1. **No early exit (the main cost).**  `atomic-binop!` / `atomic-op!` expand to
   `(dotimes+ (r (+ global-size 1)) (when (= done 0) ...))`.  The design sketch broke out with
   `(return-from-loop)`, which was never implemented, so every contender runs all
   global-size + 1 iterations even when it wins on the first try.  Explains the flat cost.
2. **Loop state left in memory.**  `dotimes`, the 172 variants and `let` build their allocas at the
   current insert point.  SROA / mem2reg only promote ENTRY-block allocas, so any loop or `let` inside
   a branch keeps its variables in memory.  General -- not CAS-specific.  Separate step.
3. **seq_cst at system scope.**  NVPTX ignores ordering on atomicrmw (so `:atomic` was cheap) but
   puts `fence.sc.sys` before every cmpxchg.  DECIDED: every atomic becomes relaxed at device
   scope (`syncscope("device")`, which both NVPTX and llvm-spirv honour; "agent" is not honoured by
   llvm-spirv), and ordering only ever comes from an explicit `mem-fence`.  last-man-standing
   already orders that way (183).
4. **The retry re-reads with a plain load.**  It should reuse the value cmpxchg returns, and the read
   that remains should be a relaxed atomic load (a racing non-atomic load is undefined in LLVM).

The bound stays as 175 derived it: contenders + 1, asserting if exhausted.


Plan (draft -- for discussion)
==============================

Step 1 -- `return-from-loop` (option B: what the original design intended)
-------------------------------------------------------------------------
D1  `(return-from-loop)` -- no value.  Exits the innermost LEXICALLY enclosing loop of the dotimes
    family (`dotimes` and the non-+ 172 variants).  Codegen: each loop pushes its exit block on a
    dynamic stack while it generates its body; `return-from-loop` emits `br exit` and continues in a
    fresh unreachable block, so the existing `terminator-p` checks need no change.
D2  REFUSED inside a `+` loop (`dotimes+`, `dec-times+`, ...).  A `+` loop promises a uniform trip
    count, and a per-thread exit breaks that promise.  (Later, if wanted: allow it when the guarding
    condition is provably uniform.)
D3  REFUSED outside a dotimes-family loop, including inside the stride loops (`loop-vector-stride`,
    `tile-stride`, ...), whose hidden loops a user cannot see.  Lexical only: a function body
    called from a loop cannot exit the caller's loop.
D4  A loop whose body contains `return-from-loop` is analysed as DIVERGENT
    (`*in-divergent-conditional*`), so a barrier or collective inside it is refused with the
    existing message.  Threads that exit early never reach a later iteration's barrier.
D5  `--differentiate`: a loop containing `return-from-loop` is refused for now, with a clear
    message (a real gap: the backward pass needs the per-thread trip count).  `atomic-binop!` keeps its
    own semantic VJP, so it is unaffected.
D6  The CAS expansion becomes plain `dotimes` (it is already inside a per-thread `when`), with
    `(return-from-loop)` on success.  The r-t-assert stays.

Specs (TDD), tests/spec/184-cas-lowering/
  01 dotimes: find the first matching index, exit early            (metal)
  02 a 172 variant with an early exit                               (metal)
  03 nested loops: exits only the inner loop                        (metal)
  04 atomic-binop! loop exits on success -- .unit.lisp claim on the LLVM-IR
  errors/ outside a loop; inside dotimes+; barrier in a breakable loop; under --differentiate
  Existing coverage stays green: 175/33,35,38,39,47,48,51 and 37 (diff atomic-binop!).
Then: BMG rollup rows wg_cas / warp_cas.

Step 2 -- relaxed, device-scope atomics (decided)
Step 3 -- entry-block allocas (general; own measurement across the suite)
