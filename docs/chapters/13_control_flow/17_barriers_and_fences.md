# Barriers and Fences ✅


The golden rule of GPU programming is: if you have threads cooperating on a task and one thread writes a value that another thread needs to read, you must use a barrier. The logical pattern is always **Write -> Barrier -> Read**, regardless of whether it's one thread writing and many reading, or many threads writing and one reading.

#### sync-workgroup ✅
`(sync-workgroup)`
This routine inserts a local barrier. It ensures that all threads in the workgroup have reached the same location before continuing. This barrier includes a memory fence that guarantees all writes to local memory by threads in the workgroup are visible to all other threads in that same workgroup. Use it after you are done writing to shared local memory and before any other thread is expected to read from it. On CUDA it will map to `__syncthreads()` and on OpenCL to `barrier(CLK_LOCAL_MEM_FENCE)`.


#### sync-warp ✅

`(sync-warp)`
This routine inserts a warp-level barrier. It ensures that all threads within the same warp (or sub-group) have reached the exact same execution point before any of them proceed. This barrier includes a memory fence scoped specifically to the warp, guaranteeing that memory writes made by threads in the warp are visible to all other threads in that same warp. Use it when coordinating fine-grained data exchanges, register shuffles, or when preventing race conditions during warp-synchronous programming. On CUDA it will map to `__syncwarp()` and in SPIR-V to the sub-group equivalent, such as `sub_group_barrier`.

#### mem-fence ✅

```
(mem-fence)                    ; grid scope -- the default
(mem-fence :scope :grid)       ; the default, said out loud
(mem-fence :scope :workgroup)  ; cheaper; orders memory within this workgroup only
```

A fence enforces the ORDERING of memory operations without synchronizing thread execution. That is
what separates it from the other coordination primitives, and it makes fences their own group in
Crisp's vocabulary:

* a **barrier** (`sync-workgroup`, `sync-warp`) makes threads wait for each other;
* a **fence** (`mem-fence`) makes one thread's writes VISIBLE to others, and makes nobody wait;
* an **arrival object** (`make-arrival-sync`, `sync-arrive`, `sync-wait`) counts participants.

A fence guarantees that all writes this thread made before it become visible to other threads before
any of its later reads or writes do. It is an advanced tool for producer-consumer patterns between
workgroups, and for ordering a store against a following atomic.

**The scope is the whole subtlety, and the default is the safe one.** `:grid` orders memory for the
entire device, which is what any CROSS-WORKGROUP publication needs -- one workgroup storing a value
that another will read. `:workgroup` orders it only among threads of this workgroup, and is cheaper.
Grid is the default because a fence that is too strong costs only performance, while one that is too
weak gives a wrong answer that testing does not reliably catch. BUG 088 was exactly that: `mem-fence`
emitted workgroup scope on PTX and device scope on SPIR-V, and `grid-reduce-last-man!` silently
depended on the stronger reading. It would have produced correct-looking results on NVIDIA hardware
anyway, because a device-coherent L2 and a neighbouring atomic masked the missing guarantee.

| | `:grid` (default) | `:workgroup` |
|---|---|---|
| NVIDIA PTX | `membar.gl` (= `__threadfence()`) | `membar.cta` (= `__threadfence_block()`) |
| SPIR-V / Level Zero | `OpMemoryBarrier`, Device scope + CrossWorkgroupMemory | `OpMemoryBarrier`, Workgroup scope + WorkgroupMemory |
| OpenCL (historical) | `mem_fence(CLK_GLOBAL_MEM_FENCE)` | `mem_fence(CLK_LOCAL_MEM_FENCE)` |

Level Zero needs no separate answer: it consumes the same SPIR-V module, so the `OpMemoryBarrier`
row covers it.

There is no narrower scope. A warp-scoped fence would be very nearly a no-op on hardware that runs a
warp in lockstep, so `:scope :subgroup` is refused rather than offered as a false economy.





