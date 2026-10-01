# `signal` ✅


`(signal barrier) => nil`

Manually notifies the specified `barrier`. This is predominantly used in pipelined or warp-specialized loops where the Consumer warp must explicitly tell the Producer warp's DMA engine that a specific chunk of Shared Local Memory has been fully read and is safe to be overwritten by the next memory fetch.


