# Matrix Multiplication Optimization — Two Vendor Arcs


The synchronous tiled matmul above is the shared baseline (metal-correct on both vendors).
Optimizing past it **splits by machine** — NVIDIA stages global→SLM asynchronously and feeds the
tensor cores from SLM; Intel loads global→registers directly.  Two arcs, one baseline.

