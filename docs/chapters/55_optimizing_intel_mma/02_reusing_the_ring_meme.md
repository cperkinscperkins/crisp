# Reusing the "Ring" Meme


We reuse the ring concept, but we are not building a ring of scratch-matrices (SLM) and do not need async-barriers.
Instead, we build a ring of Register Tiles (a double-buffer). We issue a load into the "pong" register while the DPAS computes on the "ping" register, and we issue a prefetch into the cache for a tile even further in the future.

