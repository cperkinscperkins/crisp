# Optimizing Intel MMA


Intel's fast path is **not** an async-copy-to-SLM story, so it does **not** reuse the NVIDIA arc
(async barrier + `load-tile :barrier` + rings).  Instead it optimizes by loading tiles **directly
from global memory into registers**, in the DPAS-ready layout, via **LSC 2D block loads**
(`OpSubgroup2DBlockLoadINTEL` and its `…Transpose` / `…Transform` VNNI variants).  This is a
subgroup-collective load straight into per-lane registers — there is **no SLM staging and no
barrier** — so it is a *fragment-load* mechanism that fuses into the MMA, not a `load-tile`.

Latency is hidden not with an async barrier but with **`OpSubgroup2DBlockPrefetchINTEL`** — a
prefetch hint that warms the cache for the *next* tile while the current one computes; the
subsequent block load then hits cache.

Requires **DG2 or newer** (Gen12 lacks it).

