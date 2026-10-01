# Why this is the optimal shape for Intel


No Warp Specialization: You don't need a producer/consumer warp split because the LSC data port and the Math/FPU data ports operate concurrently inside the same Xe Core. A single subgroup can issue the memory instructions and the math instructions without blocking itself (until the register is actually read).
No Barriers: Intel's dependency tracking is managed in hardware via the register scoreboard. When `mma-accumulate-via-tile` executes, if `ring-idx 0` hasn't finished loading from the L1 cache, the thread simply sleeps.
Register Pressure is the Only Limit: On NVIDIA, your pipelining depth is usually constrained by how much SLM you can allocate per block. On Intel, your pipeline depth is constrained by the physical size of the GRF (which is why `pipeline-stages` is set to 2 here—ping-ponging a 128x128 register tile consumes a massive amount of the GRF).


