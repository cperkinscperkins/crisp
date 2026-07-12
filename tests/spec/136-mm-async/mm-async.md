Our next endeavor is to begin  "Chapter 1" of our Matrix Multiply story in three chapters (see .\docs\topology.md)

"Chapter 1" isn't one thing, it's actually two:

[ ] Chapter 1 - async tile   cp.async and OpGroupAsyncCopy
[ ] Chapter 1.5 - async tiles  with CuTensorMap and LSC 2D Block Loads in Intel Xe

In this endeavor, mm-async, we are just tackling the first of those. We'll use cp.async on PTX and OpGroupAsyncCopy in SPV.  It's possible that the (load-tile ... :barrier ...) we have already is sufficient to realize this immediately.

BUT, let's look where we are going: Topology Aware Async. If the target architecture is modern, then, ultimately, Crisp should choose the Chapter 1.5 variants.  

Users can elect the "degenerate" cases explicitly though. Below are the updated design for (make-async-barrier). They are already in topology.md (Reminder that "barrier" in Crisp denotes data movement, and "sync" thread coordination, and "semaphore" semaphore).

I'm also copy/pasting the docs for `--ir-target-arch` below too.



For this endeavor I think we should:

[ ] lay the groundwork for `(make-async-barrier)` .  It should be aware of `--ir-target-arch`. We don't have `def-topology` or `def-orchestration` to tell us about Fabric etc. So the only data movement we are worried about now is between global / local.

[ ] extend `(make-async-barrier)` to support `:type` and `:mode` .

[ ] realize Chapter 1 with cp.async
[ ] realize Chapter 1 with OpGroupAsyncCopy
[ ] expand performance to have a new measurement with this async MM
[ ] expand benchmarks to measure this as well. For both L0 and CUDA. 






### `make-async-barrier`

`(make-async-barrier) => barrier`

Allocates a topologically aware data-movement barrier. Depending on the memory scope it spans, the Crisp compiler lowers this into the appropriate hardware construct (e.g., an `mbarrier` object in Shared Local Memory for TMA, or an asynchronous `cp.async.commit_group` fence). This barrier is strictly used to synchronize the state of the hardware DMA engine with the execution unit, not for arbitrary control flow.

```
(make-async-barrier &key type mode)

; example
(make-async-barrier :type :global :mode :linear)
```

There is also an _explicit_ variant of `make-async-barrier`.  The `:type` and `:mode` keys can be provided to tell the compiler exactly which async data moving APIs you want used, regardless of the topology or hardware profile in the current compilation context.  This is generally used for degenerate cases, for example, on a modern GPU architecture block-wise data copying between global and local memory is the most peformant, but there might be reasons to use the older linear data movement instructions (like `cp.async` or `OpGroupAsyncCopy`).  
Care should be taken when using these, as they make your code brittle and can easily break it. 

#### `:type` 

The `:type` choices are the same as used with `interconnect` in a `def-topology`, with the addition of `:global` to signify global/local memory movement (device VRAM).

- `:global`
- `:p2p`
- `:pcie`
- `:pgas-fabric`

#### `:mode`

When the `:type` is `:global`, then the mode can be either
- `:linear`  - selects `cp.async` when targeting PTX, ro `OpGroupAsyncCopy` when targeting SPIR-V.
- `:block` - select `CuTensorMap` ops when targeting PTX, or Intel LSC 2D Block Loads when targeting SPIR-V.




----------



#### `--ir-target-arch=<ID>` 📝

This flag tells the Crisp compiler which architecture the IR should target. It is optional, but
matches the use of `--ir-target` flag. (ie, if `--ir-target=ptx` then `--ir-target-arch` should 
be an NVidia architecture.).



| ID       | Description                    |
|----------|--------------------------------|
| `sm_80`  | NVIDIA Ampere (A100)           |
| `sm_86`  | NVIDIA Ampere (RTX 3000 Series)  |
| `sm_89`  | NVIDIA Ada Lovelace (RTX 4000 Series / L40) |
| `sm_90`  | NVIDIA Hopper (H100 / H200)      |
| `sm_100` | NVIDIA Blackwell Datacenter (B100 / B200 / GB200) |
| `sm_120` | NVIDIA Blackwell Consumer (RTX 5000 Series / PRO 6000) |
| `gen12`  | Intel Gen12                    |
| `dg2`    | Intel DG2 / Alchemist          |
| `pvc`    | Intel Ponte Vecchio            |
| `xe2`    | Intel BattleMage / Lunar Lake  |