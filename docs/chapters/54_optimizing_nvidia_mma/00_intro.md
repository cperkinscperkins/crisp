# Optimizing NVIDIA MMA


NVIDIA hides memory latency by staging tiles **global→SLM asynchronously** (tracked by an async
barrier), then feeding the tensor cores from SLM.  Over the synchronous baseline:

1. **`cp.async` (`:mode :linear`)** — async per-element copy global→SLM.
2. **CuTensorMap (`:mode :block`)** — bulk, descriptor-driven 2D copy global→SLM (sm_90+ / TMA).
3. **Ring pipelining** — barrier + storage-handle rings so one stage loads while another computes.
4. **Warp specialization** — dedicated producer / consumer warps over the rings.
5. **Warpgroup MMA (`wgmma`)** — Hopper's asynchronous warpgroup-wide MMA, the instruction cuBLAS
   itself uses.

All five ship and are metal-verified on an H100.

The examples below build up this arc.

