# Barriers and Fences ✅


The golden rule of GPU programming is: if you have threads cooperating on a task and one thread writes a value that another thread needs to read, you must use a barrier. The logical pattern is always **Write -> Barrier -> Read**, regardless of whether it's one thread writing and many reading, or many threads writing and one reading.

#### local-barrier ✅
`(local-barrier)`
This routine inserts a local barrier. It ensures that all threads in the workgroup have reached the same location before continuing. This barrier includes a memory fence that guarantees all writes to local memory by threads in the workgroup are visible to all other threads in that same workgroup. Use it after you are done writing to shared local memory and before any other thread is expected to read from it. On CUDA it will map to `__syncthreads()` and on OpenCL to `barrier(CLK_LOCAL_MEM_FENCE)`.

#### mem-fence ✅
(mem-fence &key local global)
This routine inserts a memory fence to enforce the ordering of memory operations. Unlike a barrier, a fence does not synchronize thread execution.

A fence guarantees that all writes to a memory space (e.g., :global) before the fence are visible to other threads before any reads or writes after the fence are executed by this thread. This is an advanced feature for preventing subtle race conditions in complex algorithms, especially those involving atomic operations or producer-consumer patterns between different workgroups.

On CUDA, (mem-fence :global) maps to __threadfence(). On OpenCL, it maps to mem_fence(CLK_GLOBAL_MEM_FENCE).

<!-- WHAT are the comparables for LevelZero? -->




