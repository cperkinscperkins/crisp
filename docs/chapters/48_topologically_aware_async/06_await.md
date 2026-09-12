# `await` ✅


`(await barrier) => nil`

Halts the execution of the calling warp or workgroup until the specified `barrier` has been fully signaled by the hardware DMA engine. This guarantees that all asynchronous bytes tracked by the barrier are visible in memory, ensuring the execution unit does not read garbage data.

