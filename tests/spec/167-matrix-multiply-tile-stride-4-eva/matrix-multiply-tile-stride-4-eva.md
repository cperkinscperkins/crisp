Chris Observes
==============

Some of the .crisp files for our matmul benchmarking are using matrix-multiply-tile-stride. But many are using simple tile-stride with dotimes.  Why is that? Is it because the macro isn't adequate?  

I'd like to know how many ./benchmark/matmul   .crisp files are using matrix-multiply-tile-stride, and how many are not. And of those that aren't could they be? And for those that can't, why is that? Is there some shortcoming of the macro that we should adjust? Is, perhaps, a different macro warranted that would better serve?

Ultimately, I'd like to get most of those benchmarks using that macro, with the obvious exceptions.


Claude (Web) Explores
=====================
I went ahead and did a first pass, so here's the picture so far and a proposal for what to do next.
Counts. There are 128 .crisp files under matmul. 17 actually call matrix-multiply-tile-stride; 111 don't. A plain text search overcounts: several files, including the chap5 and chap6 kernels, mention the macro only in comments.
How the 111 break down. I grouped them by keyword scan (warp specialization, wgmma, prefetch, load-tile-at, number of dotimes), so the groups are rough. I read about a dozen files in full to check them.
Bucket
Files
Likely adaptable?
Not a tiled matmul (chap0_naive ×4, common/fill.crisp)
5
Out of scope
chap1_handrolled_* (load-tile-at)
5
Mechanically yes, but that chapter exists to show the loops without the macro
One tile-stride + one K dotimes, no prefetch (_kdepth, _probe_roofline, sec2_top_*_bmg*, sec3_mma_lowering, chap4_*_bmg)
~38
Yes, readily
Same shape, plus per-tile setup before the K loop (prefetch warm-up, ring pre-seed)
~37
Probably, with a workaround
Two K loops, no warp specialization (chap5_multistage_ring* NVIDIA, sec2_top_f64/matmul_f64)
4
Unknown, need to read
Warp specialization (chap6, chap7, sec2_top NVIDIA, sec3_cluster_multicast, sec4_*_ws_*, _variant_*)
18
No
wgmma accumulator without warp specialization (_probe_wgmma_*)
4
No, as the macro is written today
So the rough answer is that about 75 look adaptable, about 22 look blocked, and the rest are out of scope or need a closer look.
The macro limitations that seem to cause the blocks come from reading the lowering in src/analysis/control.lisp and src/mma.lisp:
The macro owns exactly one K loop, inside tile-stride. Warp-specialized kernels need a separate K loop per role (the producer loads, the consumer accumulates), and the store happens only in the consumer branch. The macro has no way to express that split. This is the biggest limitation and covers all 18 warp-spec files.
The accumulator must be a register tile or a scratch tile. The per-output-tile reset (the BUG 036 fix) and the register pre-lowering only recognize make-register-tile. A make-wgmma-accumulator isn't handled, which is why those kernels reset by hand with (set! D ...).
There's no per-tile section that runs before the K loop. The macro has an :epilogue for after the loop but nothing for before it. The prefetch and ring kernels do warm-up work there. The workaround, (when (= grid-k 0) ...), is exactly what chap4_cheap_fetch/matmul.crisp already does for its reset. That works, but a :prologue marker would be cleaner.
A register accumulator must be bound in the let that directly encloses the macro. Many of the Intel kernels bind their tiles inside tile-stride. Converting them means moving those bindings out, which looks safe (sec3_mma_lowering/matmul_xe_bare.crisp already binds them outside), but it's worth confirming once.
One side finding to verify. A few hand-rolled kernels bind a register accumulator outside tile-stride and never reset it (e.g. _kdepth/bare_k16.crisp, sec3_mma_lowering/matmul_xe_bare.crisp). That's the BUG 036 pattern: it's only correct if each workgroup covers exactly one output tile. It may be fine in practice for these sizes, but converting them to the macro would fix it regardless.
How I'd proceed from here:
Convert one of each adaptable shape and compile it: one plain single-loop kernel (e.g. bare_k16) and one prefetch kernel using the grid-k = 0 workaround. That tests whether "readily adaptable" really holds. If it does, those ~75 files are mostly mechanical work.
Read the 4 unclear two-loop files and put each into a bucket.
Decide whether warp specialization is a gap in the macro or a deliberate boundary. This is the real design question. One option is a macro form with :producer / :consumer bodies, where the macro owns tile-stride and generates a K loop in each role. The wgmma limitation (#2) would probably be handled in the same design, since almost every wgmma kernel is also warp-specialized.


Plan
====

[ ] measure    — does a :let-bound register tile re-init per output tile?
[ ] write tests — ~10 positive specs, ~5 negative, 1 unit (135 has a .unit.lisp precedent)
[ ] implement  — %mmts-parse sections + %mmts-lower; finish the scratch reset + sync
[ ] pilot      — convert 3 files (one plain, one :prologue, one :let+ring); benchmark before/after
[ ] convert    — the remaining ~77, if the pilot is clean
[ ] document   — ideal_001.md + emoji, split-docs, reference.md, call-graph