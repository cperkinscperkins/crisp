# Topologically Aware Compilation ✅


Crisp has a lot of macros and forms — more than most languages.  Striding, reductions, async
behaviours, tiling and matrix multiply all have forms that make kernel writing more
straightforward.

Experienced readers may look at a form like `loop-vector-stride` and think "sure, that's
convenient, but I can get the global size, the vector size and set up a stride myself."  True.
But these forms exist for a reason beyond ease of use: they carry enough structure for the
compiler to reshape what they lower to.  The same `tile-stride` loop becomes a synchronous copy, a
`cp.async` pipeline, a TMA descriptor transfer, or a warp-specialized producer/consumer handshake,
depending on the barriers you hand it and the hardware you aim at — without rewriting the kernel.
And Performant with a capital P: pipelining, warp specialization, and tensor-core MMA all
reachable from the same source.

The sections that follow cover that machinery: **hardware profiles**, the **async tile** forms and
their barriers, **clusters**, **synchronization**, **rings**, and the **matrix-multiply / MMA**
forms, including the two vendor optimization arcs — NVIDIA staging global→SLM asynchronously,
Intel block-loading global→registers.

Crisp is not auto-optimizing the kernel for you; that is an ongoing area of research.  You choose
the optimization strategy that fits your problem and write it, and these forms make that
straightforward.  Real matrix multiplication kernels are used throughout.

> **Cluster-scale topologies are deferred.**  An earlier design took this further — a
> `def-topology` describing a torus mesh or fat-tree superpod, a `def-orchestration` placing data
> across it, and "out of core" processing for data too large to fit on one GPU.  That work is set
> aside and lives in [`topology.md`](topology.md).  Everything here ships today on a single GPU.

> **What are the choices?**  [`performance-levers.md`](performance-levers.md) enumerates every
> knob that changes the speed of a tuned register-resident MMA matmul, organised by who sets it —
> kernel source, compiler, enqueue, and the platform underneath.  It records measured magnitudes,
> the levers that turn out **not** to be independent of one another, and a list of things that
> were tried and did not pay, so they are not re-tried blind.


