When adding features to Crisp we usually try to address autodifferentiation at the same time. But that is not always possible.

We've been adding MMA support for some time now. Asynchronous tile loads, prefetch, wgmma, DSMEM, barriers and split barriers and more.  In edneavors 145, 146, 146 and 149 we addressed autodifferentiation for those new MMA techniques. With great difficulty, truth be told.  Part of the problem is that our AutoDiff works by doing an ANF transform and chain rule replacement on a forward kernel to produce a backwards one, but many of these MMA techniques are delicate data moving dances and they are resistent to that sort of transformation. But they don't need to be, fundamentally the overall math is the same, regardless of the optimization used, and therefore the derivative can likewise be the same - the derivative does NOT have to participte in this optmization at all. 

In this endeavor (163-autodiff-revisit) I want to review the work done since endeavor 149 and make sure everything is auto differentiating correctly. Several of those tests had SKIP-WITH[--autodifferentiate] put on them for expediency. Hopefully they are easy to address.

Be careful to not get caught in the trap of being unable to see the forest for the trees. Use the VJP "shortcuts" to preserve the math of the derivative kernel and avoid having to autodifferentiate data moving forms at all.


The thesis
----------

> **Warp specialization, pipelining, prefetch, rings, TMA and wgmma do not change what the
> kernel computes.  They change *when and where the bytes arrive*.  The math is still
> C = A·B.**

There is no wgmma VJP, no warp-specialization VJP, no prefetch VJP.  There is **the
tile-level VJP that 145 already shipped and gradient-checked four separate ways on metal.**

So every "forward-only" skip in the table below should reduce to the same shape of work:
make the differentiator see *through* the schedule to the math, then reuse the VJP that
already exists.  Where that fails, the defect is that a scheduling construct leaked into
the differentiator's view of the math — **not** that the construct needs its own derivative.

This is the forest.  When a task starts to feel like inventing a derivative for a *staging
strategy*, we have walked into the trees and should stop.


TASKS
======

- inventory the tests which are using SKIP-WITH[-differntiate] since endeavor 149.
- identify those that should be autodifferentiable.
- fix / implement what is needed to make the AD work for those tests
- remove the SKIP-WITH from them.
- use this endeavor to add any ADDITIONAL tests that might be needed (for example, if we need to extend the primal replay mechanism or something)
