# **Matchy Matchy: Putting it Together**


By combining Phase 1 and Phase 2, you create your algorithms.  Every grid-level construct runs its own
Phase 1 -- a `reduce-workgroup`, which is itself a warp shuffle followed by a shared-memory sweep -- and
must be reached by every thread, so in practice you choose the Phase 2 strategy:

**The Speed Demon:** `grid-reduce!` (its default, `:last-man-standing`)
One kernel, no contention on the result, any commutative function, any number of workgroups, and a
result that is the same bit for bit from run to run.

**The Easy Button:** `grid-reduce!` with `:strategy :atomic`
Summing (or taking the min or max of) a massive grid: no global scratch at all, at the cost of
contention on a single address.

And when one warp is all you need, `reduce-warp` alone is the fastest of all: registers only, no barriers.

