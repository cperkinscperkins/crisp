Advanced Crisp: Topological Aware Compilation
------------------------------------------------

As you've seen in the Crisp design documentation, it has a lot of macros and forms, more so than other languages.  Striding, reductions, async behaviors, tiling and more all have various macros and forms that help make kernel writing more straightforward.

Experienced readers may look at a form like `loop-vector-stride` and think "sure, that's convenient, but I can get the global size, the vector size and set up a stride myself. It's not THAT much trouble". And that is true. But Crisp has these forms for a reason (besides ease-of-use) and that reason is that many of these forms are Topologically Aware. Which is to say, that with these forms you can write a performant kernel that can be compiled either for a single GPU, or for a cluster organized as a Torus Mesh or a Fat Tree Superpod or whatever. And we mean Performant with a capital "P", exploiting pipelining, warp specialization, tensor core MMAs and more. Crisp users can target these different systems without rewriting their kernel code or worrying about NVLink vs OpenSHMem, Unified Bus or other fabrics. 

Crisp also supports "out of core" orchestration, where the data is too large to fit on the GPU, but needs to be progressively enqueued and processed in chunks. 

To make this happen the Crisp compiler needs three things:

- `def-topology` to describe the organizaion of your cluster
- `def-orchestration`  with location and memory distribution information
- `def-kernel` with the optimized kernel code. 

And for absolute maximum performance, you might want to name or provide a hardware profile (via `--hardware-profile` and/or `def-hardware-profile`) as well, which tell the compiler about the specific machine characteristics of a target.

Note that Crisp is not auto-optimizing the kernel for you. That is an ongoing area of research. You will have to choose the optimization strategy that fits your problem domain and code it. But Crisp forms make this a straightforward endeavor. We'll use real examples of matrix multiplication and Flash Attention as we progress.

Hardware Profiles 
-----------------

`--ir-target`, when set to `ptx` or `spv` tells the compiler the IR target, which will usually be `ptx` for NVidia hardware and `spv` for Intel (and possibly others).  When compiling a kernel that is often enough, nothing more is needed.  But for some capabilties and or optimizations, the  `--ir-target-arch` flag can be used to further inform about the exact architecutre (like `sm_80` or `xe2`).  But for absolutely maximum performance optimizations, the compiler can be given specific bounds and capabilities of a targeted hardware and then it can tailor to those.  These "specific bounds and capabilities" are called a "hardware profile".

Hardware profiles are recommeended, but they are always optional. 

The Crisp compiler already knows about some hardware profiles. Those are listed below and their name alone as a flag or `:profile` value is sufficient to leverage them. But if Crisp doesn't have the exact profile for your hardware defined already, it is easy to provide it with `def-hardware-profile`.

Note that a hardware profile says nothing about that actual architecture. It may seem strange, but to the Crisp compiler these are orthogonal concerns. Note that this means that Crisp can be employed for certain types of micro-optimizations or experiments. If you know that when your kernel runs, the GPU will be already partially employed running something else, then use a custom shrunken hardware profile to optimize for the capabilities that WILL be available. This avoids the "Empty Room Fallacy" that ensnares other GPU toolchains.

### `def-hardware-profile`  ✅
```
(def-hardware-profile <name> <profile-proplist...>)
```

`def-hardware-profile` just associates a `<name>` with a profile property list. The `<name>` can then be used as the value for the `--hardware-profile` compilation flag, or used with `:profile` value in a `compute-unit` member of a `def-topology` (see below)

```
(def-hardware-profile nvidia-h100-sxm
   
  ;; --- Compute & Vector Core Mechanics ---
  :simd-width 32  📝
  :compute-units 132  ⚠️                     
  :max-registers-per-cu 65536  📝            
  :max-registers-per-thread 255  📝

  ;; --- Local Memory Hierarchy ---
  :max-shared-memory-per-block 227KB  ✅     
  :l2-cache-size 50MB  📝
  :native-cache-line-size 128  📝           

  ;; --- Execution & Work-Group Bounds ---
  :max-work-group-dims '(1024 1024 64)  ✅
  :max-total-threads-per-block 1024  ✅
  :max-concurrent-kernels 128  📝

  ;; matrix units
  :mma-shapes '((16 8 16) (8 8 8)))  📝  ; list of (M N K) triples
```

Missing Keys: an incomplete `def-hardware-profile`, one without the full set of keys as illustrated above, is fine.
However any optimizations that depend on it will simply not be taken. 

Unkonwn Keys: a `def-hardware-profile` sporting any key outside the ones listed above will result in a compilation error.

### `:mma-shapes`

`:mma-shapes` the matrix-multiply-accumulate (tensor-core / DPAS) instruction shapes the hardware natively supports, each an (M N K) triple. An MMA computes D[M×N] = A[M×K]·B[K×N] + C[M×N], so all three dimensions identify it, and the same M×N typically comes in several K variants for different operand precisions (NVIDIA m16n8k8 for tf32, m16n8k16 for fp16, m16n8k32 for int8; Intel similarly). The form is vendor-neutral, mapping to NVIDIA mma.mMnNkK and Intel joint_matrix shapes alike.

```
:mma-shapes '((16 8 16) (16 8 8) (8 8 128))
```

### Crisp predefined hardware profiles

- `bmg`


### `--hardware-profile`

This compiler flag names a hardware profile to use for optimization/validation.  It can be one of the Crisp builtin hardware profiles, or can be the name of a profile in one of the .crisp files in the compiler invocation. 

It is an error to use this flag if a topology or orchestration is specifying a hardware profile. 







Topologies
----------

> **⚠ DEFERRED (2026-07).**  `def-topology` / `def-orchestration` and everything in this section
> (multi-device meshes, fabrics, `:distribution` / `:location`) are **set aside for now** — the
> intended direction for multi-GPU / cluster / out-of-core work, but not on the current path.  The
> single-GPU MMA optimization arcs (see "Matrix Multiplication Optimization") do not depend on it,
> and `make-async-barrier` no longer takes a `:type` key.  Read this section as design intent, not
> current behavior.

A topology can be defined with `def-topology`. We'll go over it in a second, but it is essentially a function that returns an `interconnect`. These three examples of a typical single user workstation, a 10 node cluster of a supercomputer, and a mesh might help:

```
;; note this first topology leverages the hardware profile from above.
(def-topology my-workstation ()
  (let  ((main-cpu (compute-unit :id 'xeon-cpu :type :cpu-socket :memory 512GB))
         (main-gpu (compute-unit :id 'h100-tile :type :gpu-tile :memory 64GB :arch :sm_90 :profile nvidia-h100-sxm))
         (pcie-bus (interconnect :id 'host-bus :type :pcie :children (list main-cpu main-gpu))))
    pcie-bus))

(def-topology aurora-cluster (num-nodes)
  (let  (;; The Leaf Nodes (The actual compute and memory)
         (pvc-tile   (compute-unit :id 'pvc-tile :type :gpu-tile :memory 64GB :arch :pvc))
         (xeon-cpu   (compute-unit :id 'xeon-cpu :type :cpu-socket :memory 512GB))

         ;; LEVEL 1: Package Interconnect (The EMIB Bridge)
         ;; Defines the :far distance between two tightly coupled tiles.
         (pvc-pkg    (interconnect :type :p2p 
                                   :children (make-nodes 2 :initial-element pvc-tile)))

         ;; LEVEL 2: Intra-Node Fabric (The Xe-Link)
         ;; Defines the :far distance across the baseboard.
         (xe-fabric  (interconnect :type :p2p 
                                   :children (make-nodes 6 :initial-element pvc-pkg)))

         ;; LEVEL 3: The Host Bus (PCIe or CXL)
         ;; This is where heterogeneity lives. The PCIe bus connects 
         ;; the CPU socket AND the entire GPU fabric together.
         ;; Defines the :host distance.
         (host-node  (interconnect :type :pcie 
                                   :children (list xeon-cpu xe-fabric)))

         ;; LEVEL 4: The Cluster Spine (InfiniBand/Slingshot)
         ;; Defines the :distant optical hop.
         (spine      (interconnect :type :pgas-fabric 
                                   :children (make-nodes num-nodes :initial-element host-node))))
    
    ;; Return the root of the tree
    spine))


(def-topology my-heterogeneous-mesh (w h)
  (let  (;; 1. Define the physical compute unit types
         (pvc-tile   (compute-unit :type :gpu-tile :memory 64GB :arch :pvc))
         (xeon-cpu   (compute-unit :type :cpu-socket :memory 512GB))

         ;; 2. Construct the 2D device-side fabric
         ;; The compiler emits fast 1-step pulls (:p2p), while 
         ;; the metadata provides the logical grid for Crisp macros.
         (main-mesh  (interconnect :type :p2p 
                                   :dimensions (list w h) 
                                   :wrap-around NIL
                                   :children (make-nodes (* w h) :initial-element pvc-tile)))

         ;; 3. Construct the Host Bus (PCIe / CXL) to bridge them
         (host-bus   (interconnect :type :pcie 
                                   :children (list xeon-cpu main-mesh))))
    
    ;; Return the highest-level interconnect as the root
    host-bus))

```

Note that `def-topology` is its own Domain Specific Language (DSL), and supports `make-nodes`, `list` and others forms that are NOT supported in the Crisp kernel language. It uses the same `let` form as Crisp.

The `def-topology` form can take arguments, but CANNOT be templated.

### `:id`

The id keyword is optional, but recommended. It is a symbol that will be used to refer to the node in the topology tree. In `def-orchestration` if you need to tell the compiler where data should be allocated or distributed it will have to be by id.  

### `compute-unit`

```
(compute-unit :type <type> :memory <size> :arch <arch>)
```
The `compute-unit` is a leaf node in a topology tree. The `:type` keyword can be one of
`:gpu-tile` or `:cpu-socket`. These are the only two supported types.

The `:memory` keyword is the amount of memory in that compute unit. It can be specified as a number followed immediately by `GB` or `TB`.  At the moment the `:memory` key is only used if doing "out of core" orchestration, so it is optional if you are not targeting that.

The `:arch` specifier indicated the target architecture. The values are the same as the ones supported by the `--ir-target-arch` flag:

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


The `:profile` specifier indicates a hardware profile. It can be one of the Crisp built-in hardware profiles or any defined by `def-hardware-profile`.  


### `interconnect`

```
(interconnect :type <type> :children <list-of-nodes> &key :dimensions <list> :wrap-around <bool>)
```
The `interconnect` is a branch node in the topology tree. The return value of `def-topology` must be an `interconnect`. 

#### `:type`
The `:type` keyword tells the Crisp compiler's backend exactly which memory visibility boundary it is crossing, dictating how asynchronous memory pulls and synchronization barriers are lowered into hardware instructions. It can be one of:

- `:p2p`
- `:pcie`
- `:pgas-fabric`


##### `:p2p` (Peer-to-Peer Addressing)

This represents a "scale-up" boundary where multiple compute units share Unified Virtual Addressing without host operating system intervention.

* **Hardware Equivalents:** NVIDIA NVLink, Intel Xe-Link, PCIe P2P, or on-package bridges like Intel EMIB (e.g., between tiles on a Ponte Vecchio card).


##### `:pcie` (Host Bus)

This represents the boundary separating device memory from standard system memory.

* **Hardware Equivalents:** The motherboard PCIe bus or CXL interconnects separating the CPU sockets from the GPU fabric.


##### `:pgas-fabric` (Network)

This represents a "scale-out" boundary, connecting discrete nodes across a network where memory must be moved via Remote Direct Memory Access (RDMA) rather than local memory controllers.

* **Hardware Equivalents:** InfiniBand, HPE Slingshot, or standard RoCE cluster spines.


#### `:children`

This is a list of compute-units and or interconnects that are connected by this interconnect.
You can use `make-nodes` if the list is uniform. e.g.,  `(make-nodes 10 :initial-element pvc-tile)`.  Otherwise `(list thing-one thing-two)`.

#### Algorithmic Metadata (Optional)
While the compiler only needs the `:type` to generate bare-metal hardware instructions, advanced Crisp macros (like topological shifts or stencil operations) need to know the logical shape of the network to calculate neighbor IDs. The default is branch and leaf, but for meshes and torus you can optionally supply this metadata to the interconnect:

`:dimensions` - A list representing the logical shape of the fabric (e.g., '(4 4) for a 16-node 2D mesh, or '(2 2 4) for a 3D topology).

`:wrap-around` - A boolean (T or NIL). If T, the topology acts as a Torus, meaning macros that shift data past the edge of the `:dimensions` will loop back to the other side rather than throwing an out-of-bounds error.

Example of a 2D Torus Mesh:
```
(interconnect :type :pgas-fabric 
              :dimensions '(4 4) 
              :wrap-around T 
              :children my-sixteen-host-nodes)
```


def-orchestration
-----------------

For topologically aware synchronization, a `def-orchestration` is required and it must be expanded so that it's allocation directives include either `:distribution` or `:location`.
A single topology should be bound to the result of a `def-topology` function and used with the allocation directives. More than one topology would be an error.


```
(def-topology my-cluster (N)...)
(def-kernel optimized_kernel (matrix weights &out result) ...)

(def-orchestration run-on-cluster (&key node-count)
  (let  ((kernel (gen-optimized_kernel))
         (topo   (my-cluster node-count))

         (mat     (allocate-tensor kernel::matrix
                                   :topology topo
                                   :distribution '(:block (64 64))))
         
         (weights (allocate-tensor kernel::weights
                                   :topology topo
                                   :distribution :replicated))

         (res     (allocate-tensor kernel::result
                                   :topology topo
                                   :location '(xeon-cpu (0 0)))))

    (launch-kernel (kernel mat weights res))))

(gen-run-on-cluster :node-count 16)

```


### `:distribution`

The `:distribution` keyword dictates how a tensor is logically and physically partitioned across the compute units within the specified `:topology`.

Supported distribution strategies include:

- '(:block (<dims>))`: Partitions the tensor into contiguous chunks of the specified dimensions (e.g., `'(:block (64 64))`) and distributes them across the network grid.
- `:replicated`: Duplicates the entire tensor, placing a complete copy on every compute unit within the targeted topology.

When combined with a custom topology, this explicit mapping gives the compiler the dependency awareness needed to automatically generate the underlying NCCL, oneCCL, or raw PGAS signaling required for distributed execution.

### `:location`

The `:location` keyword explicitly pins the allocation of a tensor or buffer to a specific physical node within the hardware architecture.

- Topological IDs: When using a custom `def-topology`, the location targets the symbol assigned to the `:id` of a `compute-unit`. For example, `'(xeon-cpu)` or `'(pvc-tile)`.
- Coordinate Addressing: For multi-node fabrics or meshes, coordinates can be appended to the ID to target a specific node in the logical grid, such as `'(xeon-cpu (0 0))`.
- Default Locations: If you are not utilizing a custom topology (such as for local "Out of Core" orchestration on a single workstation), you can bypass IDs and simply use `:host` or `:device`.

By declaring the exact physical residency, the compiler can evaluate the interconnect boundaries (e.g., `:p2p`, `:pcie`, or `:pgas-fabric`) between nodes. This dictates whether a topologically aware `make-async-barrier` is lowered into a local LLVM-IR address space transfer or a network-level RDMA pull.

### What does this do?

Once a `def-orchestration` is expanded to use a topology then the topologically aware `make-async-barrier` routine and all consumers of those barriers (`load-tile`, `store-tile`, `await` et al) are adjusted by the compiler. If the compiler sees that the data movement requires a simple address space transfer, then the LLVM-IR it lowers handles that. But if it determines that requires a transfer across the PGAS fabric, then it becomes that. Additionally, the kernel signature might be modified to accept an implicit `CUTensorMap`, if required. On the hoisting side, the python example code that is generated will demonstrate how to initialize data with NCCL/OneCCL scatter, launch kernels, initialize a `CUtensorMap` (if reuquired), move data with allreduce and gather.

Topologically Aware Async
-------------------------

```
(let ((barrier (make-async-barrier)))

  (load-tile A A-tile (... grid-y grid-x) :transpose <bool> :identity <val> :barrier barrier)
  (load-tile-at A A-tile (... y x) :transpose <bool> :identity <val> :barrier barrier)

  (store-tile C-Tile C ( ... grid-y grid-x) :transpose <bool> :transformF <func> :barrier barrier) ;; illegal to use transfomF and barrier together.
  (store-tile-at C-Tile C ( ... y x) :transpose <bool> :transformF <func> :barrier barrier) ;; illegal to use transfomF and barrier together.

  (await barrier)

  (signal barrier))

   ;; Sometimes `make-async-barrier` is going to need a <CUTensorMap>. 
   ;; 1 - Do we have enough information at compile-time to produce one without further user intervention?
   ;;     If not, what more information do we need?
   ;; 2 - We might have to pass that as another "side channel" argument, like we do scratch tensors. 
   ;;     Meaning the kernel arg list has the <CUTensorMap> added at the beginning, but hidden from the user.
   ;;     Like scratch tensors, it must be passed down the call chain implicitly until it reaches where it is needed. 

```

### `make-async-barrier`

`(make-async-barrier) => barrier`

Allocates a data-movement barrier that synchronizes the state of the hardware DMA engine (an
async global→local memory transfer) with the execution unit.  It is strictly for tracking that
transfer, not for arbitrary control flow.  A `:barrier` on `load-tile` / `store-tile` links the
transfer to this barrier; `await` blocks until the bytes have landed.

```
(make-async-barrier &key mode)

; examples
(make-async-barrier)                  ; arch-automatic (see below)
(make-async-barrier :mode :linear)    ; force the linear async copy
```

> **Note.**  An earlier design had a `:type` key (`:global` / `:p2p` / `:pcie` / `:pgas-fabric`)
> tied to `def-topology` for cross-device / fabric transfers.  `def-topology` is set aside for
> now (see the deferred section below), so **`:type` is gone** — the only data movement this
> barrier governs is global↔local (device VRAM), which needs no key.

#### `:mode`

`:mode` selects which async global→local mechanism the barrier governs.  Omit it for the
arch-automatic default; pass it explicitly to force a specific mechanism (for degenerate cases —
this makes your code arch-brittle, so take care).

- `:linear` — `cp.async` on PTX, `OpGroupAsyncCopy` on SPIR-V.  A per-element / per-row
  cooperative copy global→SLM.  **Shipped** and metal-verified on both backends.  Valid on
  every supported arch.
- `:block` — `CuTensorMap` (TMA) on PTX.  A bulk descriptor-driven 2D copy global→SLM.
  **NVIDIA sm_90+ only.**  On an older NVIDIA arch it is a compile error (needs sm_90+); **on
  Intel it is a compile error** — Intel's fast 2D path (LSC 2D block loads) loads global→
  *registers*, not SLM, and is **not** a barrier-governed transfer at all (see "Optimizing
  Intel MMA").  (`:block` codegen lands with the CuTensorMap chapter.)

#### The arch-automatic default

With no `:mode`, the barrier picks the best global→local async copy for the elected architecture
(`--ir-target-arch`, or the per-backend default):

- **NVIDIA sm_90+** → `:block` (TMA / CuTensorMap).
- **NVIDIA < sm_90** (incl. the default `sm_80`) → `:linear` (`cp.async`).
- **Intel** (any arch) → **always `:linear`** (`OpGroupAsyncCopy`).

> **Guidance for Intel.**  `:linear` on Intel is a genuine async copy and useful for large /
> contiguous tiles, but it is a per-*row* `OpGroupAsyncCopy` — for the small, strided fetches a
> matmul does, it costs more than it saves.  On Intel, prefer a plain synchronous `load-tile`
> (no `:barrier`) for those, or the direct register block-load path (Intel MMA optimization).

> **Implementation status.**  The `:block` default on capable NVIDIA lands incrementally: until
> the CuTensorMap chapter ships, a bare `(make-async-barrier)` stays `:linear` everywhere so
> there is always a real lowering behind it.

### `load-tile`

`(load-tile src dest (... grid-y grid-x) &key transpose identity barrier) => nil`

Initiates a bulk memory transfer from the `src` tensor to the `dest` tensor (typically moving from Global Memory to SLM or registers).

* **Tile IDs (`grid-y`, `grid-x`):** The target location is specified using logical Tile Identifiers, which map to the strided chunks defined by the tensor's block distribution.  On a single GPU (no topology) this means simply: **the tile-ID is scaled by the `dest` tile's extent** to give the element origin in `src` — coord `(1 1)` with a `64×64` `dest` reads `src[64:128, 64:128]`.  These are exactly the `grid-y`/`grid-x` bindings that `tile-stride` and `matrix-multiply-tile-stride` hand you, so `(load-tile A A-tile (grid-y grid-k))` "just works".  When you need an exact element offset instead (unaligned / ragged), use `load-tile-at`.
* **`:transpose`:** A boolean indicating if the hardware should transpose the data during the load (leveraging tensor core layout features).
* **`:identity`:** A fallback value used for out-of-bounds padding if the tile intersects the edge of the source tensor.
* **`:barrier`:** Links this memory transfer to a previously created `async-barrier`. The hardware DMA engine will automatically signal this barrier when the bytes physically arrive in the destination memory space.

### `load-tile-at`

`(load-tile-at src dest (... y x) &key transpose identity barrier) => nil`

Functions identically to `load-tile`, but instead of using logical Tile IDs, the location is specified using exact **Element Coordinates** (the specific scalar index offsets, such as the top-left pixel). This is necessary for unaligned loads, halo exchanges, or ragged boundary processing.

### `store-tile`

`(store-tile src dest (... grid-y grid-x) &key transpose transformF barrier) => nil`

Initiates a bulk memory transfer from the `src` tensor (usually registers or SLM) back to the `dest` tensor (usually Global Memory), targeting a specific logical Tile ID.

* **`:transformF`:** An optional epilogue function (e.g., `relu`) applied to the data during the store operation.
* **`:barrier`:** If provided, delegates the write out to the async DMA engine.
* **Note:** It is strictly illegal to use `:transformF` and `:barrier` simultaneously. A hardware DMA engine cannot apply arbitrary mathematical functions; it only moves raw bytes. If you need epilogue fusion, the warp must perform the math inline before storing.

### `store-tile-at`

`(store-tile-at src dest (... y x) &key transpose transformF barrier) => nil`

Functions identically to `store-tile`, but uses exact **Element Coordinates** rather than logical Tile IDs to position the data in the destination tensor.

### `await`

`(await barrier) => nil`

Halts the execution of the calling warp or workgroup until the specified `barrier` has been fully signaled by the hardware DMA engine. This guarantees that all asynchronous bytes tracked by the barrier are visible in memory, ensuring the execution unit does not read garbage data.

### `signal`

`(signal barrier) => nil`

Manually notifies the specified `barrier`. This is predominantly used in pipelined or warp-specialized loops where the Consumer warp must explicitly tell the Producer warp's DMA engine that a specific chunk of Shared Local Memory has been fully read and is safe to be overwritten by the next memory fetch.


### More Tile helpers
```
(position-tile tile-tensor tensor (... grid-y grid-x))
(position-tile-at tile-tensor tensor (... y x))
```

These functions have a very similar API to the load/store tile functions above. But they do not transfer any data, instead they simply update the tile metadata. This is useful when a tile is being used a view into a larger (parent) tensor and you want to move that "window". 



### Note about OpenSHMem Barrier

supporting `make-async-barrier` over OpenSHMem is tricky.

OpenSHMEM / InfiniBand (The Real Threat)
Network interface cards (NICs) do not natively understand SLM mbarrier objects. To pipeline RDMA transfers, you must abandon quiet() entirely during the inner loops and move to Fine-Grained Network Signaling.
Modern PGAS libraries (like NVSHMEM 3.x+ and OpenSHMEM 1.5+) have explicit APIs for this:
Instead of issuing a generic nvshmem_get, the compiler emits nvshmem_get_nbi (Non-Blocking Implicit).
Instead of calling quiet(), you use Signal Flags.
When (make-async-barrier) is called for a network topology, the compiler allocates an atomic integer flag in device Global Memory (not SLM).
Here is what the compiler makes the hardware do:
Issue: The Producer warp fires the RDMA read request, and attaches a directive telling the NIC: "When you finish writing these bytes, write the value '1' to this specific signal flag."
Wait: When the Consumer warp calls (await b1), it does NOT call quiet(). It compiles down to a hardware polling loop (nvshmem_wait_until) that watches only b1's specific signal flag.
Because b1 and b2 have separate, dedicated signal flags in memory, b1 can safely signal completion and allow the math to start while the network is still physically transferring b2.


### Crisp Terminology

"barrier" - data movement.
"sync" - thread synchronization. collective waiting
"semaphore"  - individual waiting.  Used primarily for interop, but useful in-kernel too.

### Sync Operations
```
(sync-workgroup)
(sync-warp)

(make-arrival-sync <count>) => sync-handle
(sync-arrive sync-handle) => nil
(sync-wait sync-handle) => nil
```

(sync-workgroup): Same as `barrier(CLK_LOCAL_MEM_FENCE)`.

(sync-warp): Implemented via `__builtin_shflsync(0xFFFFFFFF, 0)`.

(make-arrival-sync count) : A thread-count barrier. Returns a handle used by the consumer to block until `count` threads have called (sync-arrive). Implementation uses a global atomic counter.

(sync-arrive sync-handle) : non-blocking. Puts one "unit" into the sync bucket.
(sync-wait sync-handle) : blocks until "count" units have been put into the sync bucket.


### Semaphore Operations
```
(make-semaphore :address-space :global/:local :initial-value <int> :scope :system/:device) => sema
(semaphore-release sema new-value)
(semaphore-acquire sema expected-value)

;; semaphore type declaration:
(semaphore :address-space <as> :scope <s>)
;; :scope defaults to :device.
;; :address-space must be provided for a complete type definition (as would be required at the kernel boundary).
```

Semaphore is just a location in :global or :local address space.  Must be enqueued by the host.  
Crisp will need a semaphore data type. (and a marshall- routine)

`make-semaphore` for :global has to do the "side channel" thing. Gets implicitly added to the kernel arglist. 

`make-semaphore` for :local must be prepared by host, BUT can be "carved out" of kernel space since it is a known fixed size.
Obviously, we can't do 'make-semaphore` in a loop etc.  

#### make-semaphore
`(make-semaphore &key address-space initial-value (scope :device)) => sema`

For semaphores used within the same kernel call, it is only necessary to set `:address-space` to `:local`.
If a semaphore is used between kernel calls, then the `:address-space` should be `:global`.

For interoperating with Vulkan, OpenGL, or CPU-side code, the `:scope` must be set to `:system`.
If interoperating with other kernels but in the same execution context, then the `:scope` should be `:device`.

### semaphore-acquire

`(semaphore-acquire sema expected-value)`

Wait on the semaphore until its value equals `expected-value`.

In the implementation this translates into a spin-wait loop that atomically polls the memory address using a `memory_order_acquire` fence. It will loop—inserting hardware yield/sleep instructions to save power—until the semaphore equals the expected-value. The acquire fence guarantees that your warp will not speculatively start reading memory for the next step until the lock is officially acquired.

### semaphore-release

`(semaphore-release sema new-value)`

Change the value of the semaphore. Presumably some other party might have been waiting and will now spring to action.

In the implementation this translates into an atomic write instruction coupled with a `memory_order_release` fence. The fence is the magic part. It strictly guarantees that any data your warp just calculated and stored (e.g., writing a computed tile back to Global Memory) is fully flushed and visible to the rest of the GPU before the semaphore's value actually changes.





Rings
-----

```
(make-scratch-vector-ring <tensorType> <dim> :ring-count <count>) => ring
(make-scratch-matrix-ring <tensorType> (<dimensions>) :ring-count <count>) => ring
(make-scratch-tensor-ring <tensorType> (<dimensions>) :ring-count <count>) => ring

(make-async-barrier-ring :ring-count <count> &key mode arrivals) => ring


(ring-get <ring> <index>) => <object>
```

For pipelining, we often need several scratch memory pads that we cycle through. Thus one can be loading while
another is being used for read or write. And if we are performaing async loading, we'll need a matching barrier.

The `<tensorType>` can be a type declaration or just a tensor variable.  
`<dimensions>` is a list of integers, which must be known at compile-time. They cannot be runtime variables.
`<dim>` is a compile time constant integer, used for the vector variant.

`ring-get` takes a ring and an index and returns the nth object in the ring.  The `<index>` may be a
**runtime** value — the pipelining main loop indexes with `(mod (+ ring-idx 1) stages)` — which is
exactly what makes a ring a ring.

> **How a ring is built.**  A ring of N slots is ONE allocation with the ring as a *prepended
> dimension* — `(make-scratch-matrix-ring float (64 8) :ring-count 3)` is a rank-3 scratch tensor
> `(3 64 8)` whose **dim 0 is the slot** — and `ring-get` is an offset view into it.  So the slots
> are contiguous in SLM and a ring costs exactly **one** implicit kernel argument no matter how
> deep it is.  A barrier ring is the same idea: `N` mbarriers laid out contiguously, and a plain
> `(make-async-barrier)` is simply **a ring of 1**.

### `make-async-barrier-ring`

`(make-async-barrier-ring :ring-count <count> &key mode arrivals) => ring`

- **`:ring-count`** — required. A positive compile-time integer: the pipeline depth (how many
  stages are in flight at once).
- **`:mode`** — exactly as `make-async-barrier` (`:linear` / `:block`; omit for arch-automatic).
  Every slot in the ring shares the mode.
- **`:arrivals`** — **required for `:mode :block`**; ignored otherwise.  How many transfers **each
  slot** tracks *per pipeline stage* — i.e. how many `load-tile`s name that one slot in a single
  stage.  The classic A+B staging is `2`.

> **Why `:arrivals` is explicit and not inferred.**  A `:block` (TMA) barrier is a hardware
> mbarrier: it completes when *both* its arrival count and its expected transaction bytes are
> satisfied, so the count must be exactly right — **too high and the barrier never completes (the
> kernel hangs); too low and you read a half-arrived tile.**  For a *single* `make-async-barrier`
> the compiler infers it by counting the `:block` loads that name that barrier, which is correct
> because such a kernel has one stage in the text.  Through a **ring** that inference breaks: the
> prologue and the main loop *both* load the same ring, so the textual count (2 in the prologue +
> 2 in the main loop = 4) is **not** the per-stage arrival count (2).  Grouping loads "per phase"
> statically is fragile, and the failure mode is a silent GPU hang — so Crisp asks you to say it.
> You already know the number: it is how many `load-tile`s you wrote against one slot.

```
;; three stages in flight; each stage stages an A-tile and a B-tile under its own barrier slot.
(make-async-barrier-ring :ring-count 3 :mode :block :arrivals 2)
```

> **`:initial-state`** (`:signaled` / `:waiting`) is **deferred** — it is only meaningful for warp
> specialization (a producer/consumer pair needs an "empty" ring that starts signaled), so it
> lands with that chapter rather than here.


Warp Specialization
-------------------

```
(with-warp-specialization (:producer 1 :consumer 3)
  
  (:producer 
    ...
  )
  
  (:consumer
    ...
  ))
```

Warp specialization allows you to split a single kernel into multiple distinct behaviors that execute on different warps within the same thread block.

In the example above, one warp will be dedicated to some work labelled `:producer`, and three warps will be
performing the work labelled `:consumer`. So the overall workgroup must be sized to be 4 times `(get-warp-size)`

`with-warp-specialization` can have as many labels as you want, so long as the workgroup is a multiple of the sum of the labels.

When `--runtime-checks` is enabled, the compiler will insert a check to ensure the workgroup size is correct.



Matrix Multiplication
---------------------

### `make-register-tile`
```
(make-register-tile <type> <dimensions> <initial-value>)

(make-register-tile float (128 128) 0.0)
```
`make-register-tile` reserves a space of registers and wraps their memory in a tensor.  
The `<dimensions>` argument is a list of integers, which must be known at compile-time. They cannot be runtime variables.

A register tile is extremely performant, but overuse can dramatically increase the register pressure from 
your kernel, leading to lower overall occupancy. In most matrix multiplication operations, only the highly trafficed
"C" tile of the result is stored in registers. The others are :local :address-space scratch matrices.

A register tile is a **warp-collective** abstraction, not thread-local. The logical tile
(e.g. 64×64) is distributed by the compiler across the warps of the workgroup, and within
each warp across its lanes. Computing that distribution requires a known **SIMD width**.
That width is taken from the active hardware profile's `:simd-width` if one is in play;
otherwise it is inferred from `--ir-target-arch` (or the `--ir-target` default — e.g. 32
for `sm_*`). If none of those pins the SIMD width, `make-register-tile` is a compile error.
The hardware profile stays optional in general — this is simply one of the few forms that
needs the SIMD width to be knowable. When a profile *is* supplied, its `:simd-width` and
`:max-registers-per-thread` additionally let the compiler verify at compile time that the
distributed fragments actually fit the physical register file.

### matrix-multiply-tile-stride
```
(matrix-multiply-tile-stride <C-matrix> <C-matrix-tile> <K-inner-dim-scalar> <k-step> (<grid-bindings>) ...)

```

If you have matrices `A`, `B` and `C` such that you are planning multiply them `(A x B = C)` then
the `matrix-multiply-tile-stride` macro will help stride and walk the space correctly by a tile.
The macro doesn't take `A` or `B` as arguments, it's not performing the multiplication itself,
 it simply needs to know the `C` matrix, the tile matrix view into `C`, the inner dimension of the multiplication (aka `K`), and which tile dimension strides `K`.  Then it'll loop, and in each loop `<grid-bindings>` will
 be set for you.  Use tihs macro in conjunction with `mma-accumultae-via-tile` to make matrix multiplication
 easy.



`<k-step>` is the K-extent of the staging tiles. It is the dimension A-tile and B-tile share.   `K / <k-step>` give the loop trip count.
 

`<grid-bindings>` are `(grid-y grid-x grid-k)`

Inside the body of the macro, `grid-k` will be the fastest changing term as it loops over K. 
This macro is very handy for producing matrix multiply kernels.  If used in conjunction with `mma-accumulate-via-tile` 
then nearly all the boilerplate of a matrix multiply is handled.

**The `:epilogue` (store + fusion).** The macro owns the `grid-y`/`grid-x` spatial and `grid-k`
reduction loops, but it does **not** store `C-tile` for you.  Split the body with an `:epilogue`
marker: forms **before** it run once per K-step (the reduction); forms **after** it run once per
tile, post-reduction, with `grid-y`/`grid-x` in scope and `C-tile` complete.  That is where your
store — and any fused epilogue (ReLU, bias, scale) — go:

```
(matrix-multiply-tile-stride C C-tile K k-step (grid-y grid-x grid-k)
  ;; per-K-step reduction body
  (load-tile A A-tile (grid-y grid-k))
  (load-tile B B-tile (grid-k grid-x))
  (sync-workgroup)
  (mma-accumulate-via-tile (16 8 8) C-tile A-tile B-tile)
  (sync-workgroup)
  :epilogue                               ; <- once per tile, post-reduction
  (relu C-tile)                           ; optional fused epilogue on the completed tile
  (store-tile C-tile C (grid-y grid-x)))  ; explicit store — you own the write-back
```

The explicit `:epilogue` keeps
the macro lean and the store honest — and it makes the progression to ring pipelining / warp
specialization (which also store explicitly) consistent.  **If a kernel never stores its `C-tile`,
the compiler warns** (a matmul that discards its result is almost always a bug).

> **Where does the activation go — `my-accum` or `:epilogue`?**  `mma-accumulate-via-tile` exposes
> a per-fragment accumulator (`my-accum`, in registers) for fusion, and the macro exposes a
> per-tile `:epilogue`.  Use whichever owns the *complete* reduction: if
> `mma-accumulate-via-tile` does the whole K-contraction itself, fuse on `my-accum` (finer,
> in-register).  But in this **staged** pattern — the macro's `grid-k` loop calls
> `mma-accumulate-via-tile` once per K-step — `my-accum` holds a **partial** sum each step, so the
> activation belongs in the macro's `:epilogue` (on the completed `C-tile`), **not** on `my-accum`.

**Grid semantics.** `grid-y` / `grid-x` are TILE-IDs — 0-based tile coordinates over `C`'s output
tiles (sized by `C-tile`) — which is exactly what `load-tile` / `store-tile` expect (they scale a
tile-ID by the tile's extent).  `grid-k` is the K-step index, `0 .. K/<k-step> - 1`.  The macro is
grid-strided: a workgroup owns **≥ 1** `C`-tile and strides across the grid, so it works whether
you launch one workgroup per output tile (a 2-D grid = (#row-tiles, #col-tiles)) or fewer.

**Accumulator reset.** When a workgroup owns more than one `C`-tile, the register `C-tile` is reused
across tiles, so reset it at the start of each tile's reduction with `fill-tile`:
`(when (= grid-k 0) (fill-tile C-tile (identity-value)))`.  A one-tile-per-workgroup launch does not
need this — `make-register-tile`'s init covers the single tile.

**Chapter 0 (synchronous) — what ships today.** The Chapter-0 body is fully synchronous: stage with
plain `load-tile` (no `:barrier`), `sync-workgroup`, `mma-accumulate-via-tile`, `sync-workgroup`.
```
(def-kernel matmul (A B &out C)
  (declare #'(a-mat b-mat &out c-mat) (local-size :set-to 32))
  (let ((A-tile (make-scratch-matrix float (64 8)))
        (B-tile (make-scratch-matrix float (8 64)))
        (C-tile (make-register-tile float (64 64) 0.0))
        (K      (inner-dimension A B)))
    (matrix-multiply-tile-stride C C-tile K 8 (grid-y grid-x grid-k)
      (load-tile A A-tile (grid-y grid-k))
      (load-tile B B-tile (grid-k grid-x))
      (sync-workgroup)
      (mma-accumulate-via-tile (16 8 8) C-tile A-tile B-tile)
      (sync-workgroup)
      :epilogue                               ; <- once per tile, post-K-loop
      (store-tile C-tile C (grid-y grid-x))))) ; you own the store
```
The kernel above is the **shared synchronous baseline** — it ships and is metal-correct on both
NVIDIA and Intel.  From here the optimization story **splits by vendor**, because the two machines
hide memory latency in fundamentally different ways (NVIDIA stages global→SLM asynchronously and
feeds the tensor cores from SLM; Intel's fast path loads global→*registers* directly).  So there
is no single "three chapters" arc — there are **two separate arcs** over the same baseline.  See
"Optimizing NVIDIA MMA" and "Optimizing Intel MMA" below.


### inner-dimension
`(inner-dimension A B) => ulong`
Returns the size of the inner dimensions of two tensors (the dimension used for matrix multiplication).

### outer-dimensions
`(outer-dimensions A B) => M N`

### fill-tile
```
(file-tile <some-tensor> <some-value>)
```
`fill-tile` can be used with any tensor, (vectors, matrices, etc). It simply fills it with a value.
It is a simple cooperative workgroup operation (it usually uses `workgroup-stride` under the covers) and is intended, as named, to be used on simple tiles.  For a very large tensor, use one of the other strides to implement your own.  Note: for register tiles (`make-register-tile`) it gets unrolled per fragment. Quite performant. 


Matrix Multiplication Optimization — Two Vendor Arcs
----------------------------------------------------

The synchronous tiled matmul above is the shared baseline (metal-correct on both vendors).
Optimizing past it **splits by machine** — NVIDIA stages global→SLM asynchronously and feeds the
tensor cores from SLM; Intel loads global→registers directly.  Two arcs, one baseline.

Optimizing NVIDIA MMA
---------------------

NVIDIA hides memory latency by staging tiles **global→SLM asynchronously** (tracked by an async
barrier), then feeding the tensor cores from SLM.  Over the synchronous baseline:

1. **`cp.async` (`:mode :linear`)** — async per-element copy global→SLM.  **Shipped**, metal-verified.
2. **CuTensorMap (`:mode :block`)** — bulk, descriptor-driven 2D copy global→SLM (sm_90+ / TMA).  *Next.*
3. **Ring pipelining** — barrier + storage-handle rings so one stage loads while another computes.
4. **Warp specialization** — dedicated producer / consumer warps over the rings.

The examples below build up this arc.

### Chapter 1 — Basic Matrix Multiply with async tile loading

We use basic async tile loading to hide some of the memory latency when fetching tiles.

We also use the highly performant `mma-accumulate-via-tile` to perform the matrix multiply.

```
(with-template-type (T)
  (def-type mat (matrix T :address-space :global :align :compact :contiguous-term :row-major))

  (def-grid-function basic-matrix-multiply (A B &out C)
    (declare #'((mat T) (mat T) (mat T))
               (global-size :derive-from C :strategy :strided))  
    (let ((A-tile (make-scratch-matrix A (128 128)))
          (B-tile (make-scratch-matrix B (128 128)))
          (C-tile (make-register-tile T (128 128) (identity T)))
          (K (inner-dimension A B))
          (k-step   128)
          (barrier (make-async-barrier))) ;; arch-automatic: :block on sm_90+, else :linear
    (matrix-multiply-tile-stride C C-tile K k-step (grid-y grid-x grid-k)

      (load-tile A A-tile (grid-y grid-k) :barrier barrier) 
      (load-tile B B-tile (grid-k grid-x) :barrier barrier )
      (await barrier) 
      
        (mma-accumulate-via-tile (16 8 8) C-tile A-tile B-tile (my-accum)
            ;; accum-op is available here; call it to fire the DPAS/MMA for THIS K-step.
            ;; NOTE: this is the STAGED pattern — the macro's grid-k loop calls us once per
            ;; K-step, so my-accum is a PARTIAL sum here.  Do NOT fuse activation on it; the
            ;; activation goes in the :epilogue below, on the completed C-tile.
            (accum-op))
        ;; (Another barrier usually goes here before the next 'k' iteration overwrites SLM)
        (sync-workgroup)
      :epilogue
        ;; K-loop done — C-tile is complete.  Fuse the epilogue on the finished tile, then store.
        (relu C-tile)
        (add-bias C-tile bias-tile)          ;; <-- fictional operation for illustration
        (store-tile C-tile C (grid-y grid-x))))))
```



### mma-accumulate-via-tile
```
(mma-accumulate-via-tile (<sz-expr>) C-tile A-tile B-tile (<accum-binding>) 
  ;; in the context of this macro, the helper `accum-op` is available.
  ;; call it once to perform the MMA accumulation.
  ...)
```

`mma-accumulate-via-tile` walks the tile in steps of `<sz-expr>` — an `(M N K)` triple that must match one of the Tensor MMA units of the underlying hardware.
The `<sz-expr>` you pass to `mma-accumulate-via-tile` is checked against the active profile's `:mma-shapes` (also an `(M N K)` triple). A shape the hardware doesn't list is a compile error. With no active profile, the shape is accepted unchecked.

Also note the multiplicity constraints: the output tile's M and N (128x128 in the code above) must each be a multiple of the shape's M and N, and the K-loop extent (the matrices' inner dimension) must be a multiple of the shape's K.

Two further compile-time constraints, both checked from information you already declare:

- **Operand layout (and the Intel / NVIDIA difference).** The A and B matrices' `:contiguous-term`
  (`:row-major` / `:col-major`) selects which hardware MMA variant is emitted — the canonical
  NVIDIA form is A row-major, B **column-major** (`mma…row.col`). A layout the chosen instruction
  cannot accept is a compile error; use `:transpose` on the tile load to reconcile a source that
  is stored the other way.  **Intel (SPV / DPAS) is different:** there is no ColumnMajor-B
  cooperative-matrix builtin, so on the SPV path the **B operand must be declared `:row-major`**
  (the hardware expects B in VNNI-packed row-major form).  This is a genuine per-vendor storage
  requirement — the same source can't be `:col-major` B for NVIDIA and `:row-major` B for Intel —
  so a portable kernel either declares B per target or transposes on load.  (It parallels the
  shape difference: NVIDIA tf32 `(16 8 8)` vs Intel XMX `(8 16 8)`.)
- **Precision.** The `(M N K)` triple encodes operand *precision* — the same M×N comes in
  several K variants for different dtypes (e.g. k16 for fp16, k8 for tf32). The shape you pass
  must match your operands' element type, or it is a compile error.

Physical SLM *swizzling* (bank-conflict avoidance) is a separate performance optimization, not
a correctness requirement — a plain row/col-major staging feeds the fragment loads correctly.

The three chapter kernels above pass `(16 8 8)` — the **tf32** shape (K=8), matching tf32/`float`
operands. The same M×N with **fp16** operands is `(16 8 16)`, which is the variant the expansion
below illustrates (note its `mma.m16n8k16` intrinsic and K-step of 16).

Below is an example of the triple loop that `mma-accumulate-via-tile` might expand into.
```
(let ((accum (make-register-fragment 16 8 0.0)))   ; accumulator is M×N; K is the contraction, looped by tk
  (dotimes (tk 128 16)
    (dotimes (ty 128 16)
      (dotimes (tx 128 8)
        (let ((frag-a (load-fragment-a A-shared ty tk))      ; Lowers to ldmatrix.sync.x4
              (frag-b (load-fragment-b B-shared tk tx)))     ; Lowers to ldmatrix.sync.x2
          ;; Lowers directly to NVVM intrinsic: @llvm.nvvm.mma.m16n8k16.row.col
          (setf accum (mma-accumulate accum frag-a frag-b)))))))
```

### Fragment primitives (the low-level building blocks)

`mma-accumulate-via-tile` composes these lower-level forms.  Most kernels never write them
directly — reach for them only when you need a hand-rolled MMA loop the macro doesn't cover.
A *fragment* is one hardware MMA operand's worth of data, distributed across a warp's lanes.

```
(make-register-fragment <M> <N> <init>)          => an M×N accumulator fragment, filled with <init>
(load-fragment-a <src> (<ty> <tk>))              => the A operand fragment at tile (ty, tk)
(load-fragment-b <src> (<tk> <tx>))              => the B operand fragment at tile (tk, tx)
(mma-accumulate <c-frag> <a-frag> <b-frag>)      => a new accumulator = a-frag · b-frag + c-frag
(store-fragment <frag> <dest> (<ty> <tx>))       => write accumulator <frag> to <dest> at tile (ty, tx)
```

- The tile coordinates are in **fragment units** (a fragment is the MMA shape's M×N / M×K / K×N block),
  not element units.
- `<src>` / `<dest>` may be global memory or an SLM scratch tile — the per-lane layout is the same.
- These are **warp-collective**: each lane holds its slice of the fragment; the forms lower to the
  per-lane reads/writes (and, on NVIDIA, a single `mma.sync` for `mma-accumulate`).  On the SPV
  path they lower to `CooperativeMatrixLoadKHR` / `…StoreKHR` / the coop-matrix multiply — the
  operand `:contiguous-term` drives the KHR MemoryLayout (so B's row-major requirement above
  applies here too).
- `make-register-tile` is a *tile* of these fragments (an (M/frag-M)×(N/frag-N) grid), and
  `mma-accumulate-via-tile` walks that grid for you.

### Matrix Multiply with pipelining

We use rings to set up a load/execute pipeline. 

```
(with-template-type (T)
  (def-type mat (matrix T :address-space :global :align :compact :contiguous-term :row-major))

  (def-grid-function pipeline-matrix-multiply (A B &out C)
    (declare #'((mat T) (mat T) (mat T))
               (global-size :derive-from C :strategy :strided)) 
    ;; NB: the ring depth (3) is a repeated LITERAL — :ring-count needs a compile-time integer
    ;; and Crisp has no constant form, so a `(let ((pipeline-stages 3)) … :ring-count
    ;; pipeline-stages)` binding would NOT compile.  We keep it as a plain 3 throughout.
    (let ((A-tile-ring (make-scratch-matrix-ring A (128 128) :ring-count 3))
          (B-tile-ring (make-scratch-matrix-ring B (128 128) :ring-count 3))
          (C-tile (make-register-tile T (128 128) (identity T)))
          ;; :arrivals 2 — each slot tracks its stage's A-load + B-load.  REQUIRED for :block, and
          ;; NOT inferable (the prologue and the main loop both load the ring), so you state it.
          (barrier-ring (make-async-barrier-ring :ring-count 3 :mode :block :arrivals 2))
          (n-k-steps    (/ (inner-dimension A B) 128)))

      ;; Outer loops for C-tile (X and Y coordinates).  tile-stride binds grid-y / grid-x as
      ;; TILE-IDs — exactly what load-tile consumes — and a register C-tile's shape must be given
      ;; as the compile-time (M N) size-list (the register tile SROA-explodes, so its symbol is
      ;; gone by tile-stride time).
      (tile-stride C (128 128) (grid-y grid-x)

        ;; 1. PROLOGUE: fill the pipeline for the current C-tile.  Plain dotimes: ring-get takes a
        ;; runtime index, so it serves both the prologue and the main loop.  (to-ulong i) — a
        ;; dotimes counter is int, but tile-IDs / ring indices are ulong.
        (dotimes (i 3)
          ;; Stride along K, keeping Y and X locked to the current block.
          (load-tile A (ring-get A-tile-ring (to-ulong i)) (grid-y (to-ulong i)) :barrier (ring-get barrier-ring (to-ulong i)))
          (load-tile B (ring-get B-tile-ring (to-ulong i)) ((to-ulong i) grid-x) :barrier (ring-get barrier-ring (to-ulong i))))

        ;; 2. MAIN K-LOOP.  The ring slot is just (mod grid-k 3) — no mutable ring-idx / set!.
        (dotimes (grid-k n-k-steps)
          (let ((slot (mod grid-k (to-ulong 3))))

            ;; Wait for the current stage's data to arrive in SLM.
            (await (ring-get barrier-ring slot))

            ;; Execute the math from SLM into registers.
            (let ((A-tile (ring-get A-tile-ring slot))
                  (B-tile (ring-get B-tile-ring slot)))
              (mma-accumulate-via-tile (16 8 8) C-tile A-tile B-tile (my-accum)
                ;; STAGED (this loop calls us once per K-step) -> my-accum is a PARTIAL sum;
                ;; fuse activation in the epilogue below, on the completed C-tile, not here.
                (accum-op)))

            ;; Every thread must be DONE reading this slot's SLM before the prefetch below
            ;; overwrites it — the ring wraps onto the slot we just consumed.  This sync goes
            ;; BEFORE the prefetch (issuing it after would race the overwrite against the reads).
            (sync-workgroup)

            ;; Issue the fetch for the NEXT chunk of K (grid-k + 3) into the slot we just freed,
            ;; so it lands while the following stage computes.  The guard is uniform (it depends
            ;; only on the K-loop counter), but a dotimes counter reads as :unknown uniformity, so
            ;; load-tile's internal sync-workgroup would be flagged divergent — assert it with
            ;; to-workgroup-uniform (which must be a let initializer).
            (let ((next-k (+ grid-k (to-ulong 3))))
              (let ((more-k? (to-workgroup-uniform (< next-k n-k-steps))))
                (when more-k? ;; don't fetch past the end of K
                  (load-tile A (ring-get A-tile-ring slot) (grid-y next-k) :barrier (ring-get barrier-ring slot))
                  (load-tile B (ring-get B-tile-ring slot) (next-k grid-x) :barrier (ring-get barrier-ring slot)))))))

        :epilogue
        ;; 3. EPILOGUE: C-tile is complete — fuse activation on the finished tile, then store.
        (relu C-Tile)                        ;; <-- the RIGHT place to fuse (complete C-tile)
        (store-tile C-Tile C (grid-y grid-x))))))
```

### Matrix Multiply with Pipelining via Warp Specialization

```
(with-template-type (T)
  (def-type mat (matrix T :address-space :global :align :compact :contiguous-term :row-major))

  (def-grid-function warp-specialized-matrix-multiply (A B &out C)
    (declare #'((mat T) (mat T) (mat T))
               (global-size :derive-from C :strategy :strided)) 

    (let ((pipeline-stages 3)
          (A-tile-ring (make-scratch-matrix-ring A (128 128) :ring-count pipeline-stages))
          (B-tile-ring (make-scratch-matrix-ring B (128 128) :ring-count pipeline-stages))
          (C-tile (make-register-tile T (128 128) (identity T)))
          (M N (outer-dimensions A B))
          (K (inner-dimension A B))
          
        ;; 1. The Barriers
        ;; Starts 'empty' (signaled) so the Producer can immediately begin fetching
        (empty-barrier-ring (make-async-barrier-ring :ring-count pipeline-stages :initial-state :signaled))
        ;; Starts 'waiting' so the Consumer doesn't read garbage data
        (full-barrier-ring  (make-async-barrier-ring :ring-count pipeline-stages :initial-state :waiting)))

    ;; Outer loop
    (tile-stride C C-tile (grid-y grid-x) 
      
      ;; Split the execution! 
      ;; The compiler will physically map these to different warps in the Workgroup.
      (with-warp-specialization (:producer 1 :consumer 3)
        
        ;; ==========================================
        ;; THE PRODUCER BLOCK (Memory only)
        ;; ==========================================
        (:producer
          (let ((ring-idx 0))
            (do-times (grid-k K)
              
              ;; 1. Wait for the Consumer to say this SLM slot is empty/safe.
              (await (ring-get empty-barrier-ring ring-idx))
              
              ;; 2. Issue the hardware fetch. 
              ;; The hardware DMA engine will AUTOMATICALLY signal the full-barrier when the bytes arrive.
              (load-tile A (ring-get A-tile-ring ring-idx) (grid-y grid-k) :barrier (ring-get full-barrier-ring ring-idx))
              (load-tile B (ring-get B-tile-ring ring-idx) (grid-k grid-x) :barrier (ring-get full-barrier-ring ring-idx))
              
              ;; 3. Move to the next ring slot
              (set! ring-idx (mod (+ ring-idx 1) pipeline-stages)))))
        
        ;; ==========================================
        ;; THE CONSUMER BLOCK (Math only)
        ;; ==========================================
        (:consumer
          (let ((ring-idx 0))
            (do-times (grid-k K-tiles)
              
              ;; 1. Wait for the hardware DMA to say the bytes have arrived.
              (await (ring-get full-barrier-ring ring-idx))
              
              ;; 2. Execute the pure math
              (let ((A-tile (ring-get A-tile-ring ring-idx))
                    (B-tile (ring-get B-tile-ring ring-idx)))
                (mma-accumulate-via-tile (16 8 8) C-tile A-tile B-tile (my-accum)
                  (accum-op)))
              
              ;; 3. Manually signal to the Producer that we are done reading this slot.
              (signal (ring-get empty-barrier-ring ring-idx))
              
              ;; 4. Move to the next ring slot
              (set! ring-idx (mod (+ ring-idx 1) pipeline-stages)))
          
          ;; EPILOGUE (Only the Consumer writes back to Global Memory!)
          (add-bias C-tile bias-tile) ;; <-- fictional operation for illustrative purposes
          (relu C-tile)
          (store-tile C-tile C  (grid-y grid-x)))))))))

```


Optimizing Intel MMA
--------------------

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

Status / open design: the spike confirms `__spirv_Subgroup2DBlockLoadINTEL` emits the real opcode
and the Arc B580 loads through it into registers (an SLM destination is rejected at JIT — proof it
targets registers, not SLM).  The Crisp surface for this — the fragment-load / prefetch forms and
how they compose with `mma-accumulate-via-tile` — and whether there is anything past the initial
block-load win, is the "Optimizing Intel MMA" arc still to be mapped out.


### Deferred: topology-aware orchestration (`def-topology` / `def-orchestration`)

The `def-topology` / `def-orchestration` design in the earlier part of this document (multi-device
meshes, fabrics, `:distribution` / `:location`, cross-device `make-async-barrier :type`) is **set
aside for now**.  It remains the intended direction for multi-GPU / cluster / out-of-core work, but
the single-GPU MMA optimization arcs above do not depend on it, and `make-async-barrier` no longer
takes a `:type` key (see its updated spec).


Out of Core Orchestration
-------------------------

`def-orchestration` can also be used to stage "Out of Core" execution where data is too large to fit on the device and must be pipelined through the system. 

The kernel can be passed "chunks" of a larger Storage Handle. 

There are four steps to make this work:
1. use `allocate-massive-tensor`
2. use `tile-from` to create tiles of that massive tensor
3. use the `:pipeline-stages` key to indicate how many chunks to pipeline.
4. write a kernel that operates on `:align :strided` tensors. 

When this `def-orchestration` is output, memory copies will be initiated for each tile set and the kernel called while the next set is loading. 

Not every Storage Handle needs to be massive and tiled, just those you require pipelining.

You are welcome to use `def-topology` to define a topology, but most Out of Core operations are just for one workstation. In this case, no topology is necessaray, simply use `:location :host` or `:location :device` .


Vector Add Example
```
(def-type stride-vec-t (vector float :align :strided :address-space :global))

;; -- vector_add_chunked --
(def-kernel vector_add_chunked (A B &out C)
  (declare #(stride-vec-t stride-vec-t &out stride-vec-t)
           (global-size :derive-from A :strategy :strided))
    (map-stride #'+ A B C))

;; -- add-interleaved --
(def-orchestration add-interleaved ()
  (let ((VADD_CHUNKED (gen-vector_add_chunked))
        (A (allocate-massive-tensor VADD_CHUNKED::A :location :host))
        (B (allocate-massive-tensor VADD_CHUNKED::B :location :host))
        (C (allocate-massive-tensor VADD_CHUNKED::C :location :host))
        (A-view (tile-from A '(65536) :location :device))
        (B-view (tile-from B '(65536) :location :device))
        (C-view (tile-from C '(65536) :location :device)))
  (launch-kernel  
    (VADD_CHUNKED A-view B-view C-view) :pipeline-stages 2)))
```


Matrix Multiplication Example
```
(def-topology my-workstation () ...)
(def-kernel partial_mult (A-Tile B-Tile &out C-Tile) ...)

(def-orchestration o-o-c-matmul ()
(let ((KERNEL  (gen-partial_mult))
      (topo (my-workstation))
         (A (allocate-massive-tensor KERNEL::A-Tile :topology topo :location '(xeon-cpu)))
         (B (allocate-massive-tensor KERNEL::B-Tile  :topology topo :location '(xeon-cpu)))
         (C (allocate-massive-tensor KERNEL::C-Tile :topology topo :location '(xeon-cpu)))
         (A-tile (tile-from A '(1024 1024) :topology topo :location '(pvc-tile))) 
         (B-tile (tile-from B '(1024 1024) :topology topo :location '(pvc-tile)))
         (C-tile (tile-from C '(1024 1024) :topology topo :location '(pvc-tile))))
  (launch-kernel-matrix-contract A B C (KERNAL A-tile B-Ttle C-tile) :pipeline-stages 2)))

The "super tile" size should be some maximally divisible even number near  (sqrt (/ GPU-VRAM (* pipeline-stages 3))).  Maybe lower GPU-VRAM to 85% to avoid register pressure, etc.
```

### `allocate-massive-tensor`

`(allocate-massive-tensor <VectorType> &key :topology <topo> :location <loc>) => massive-tensor`

`allocate-massive-tensor` means that whatever tensor is being allocated is really big, presumably bigger than the VRAM on the GPU. The expectation is that any kernel will only be able to operate on part of it any one time (see `tile-from` ), never the whole. 

`allocate-massive-tensor` does not support the `:shared` or `:distribution` keys.

If you are not using a custom topology, the `:topology` key can be skipped. Just use `:location :host`.


### `tile-from`

`(tile-from massive-var <SizeExpr> :topology <topo> :location <loc>) => tensor`

Create a tensor view into a massive tensor. This tensor will have the same arity and type as the original, except its `:align` will be `:strided`.

The `:location` arg is a location into the `:topology` value. Or just use `:host`.


### `:pipeline-stages`

The `:pipeline-stages` key is accepted by the `launch-kernel` and `launch-kernel-matrix-contract` forms. The number of tiles used by the kernel will be multiplied by the `:pipeline-stages`. The enqueue of the kernel is interleaved with tile retrieval. 



Primitives
-----------

For users who want to roll their own async operations and don't want topologically aware forms.

### Raw Memory Movement 

```
(cp-async dest src size) -> Lowers to cp.async or sycl::group_async_copy.

(pgas-put dest src size pe) -> Lowers to nvshmem_putmem / shmem_put.

(pgas-get dest src size pe) -> Lowers to nvshmem_getmem / shmem_get.

(pgas-put-nbi dest src size pe) -> Non-blocking implicit put.
```

### Raw Synchronization 

```
(slm-commit) -> Lowers to cp.async.commit_group.

(slm-wait <group-count>) -> Lowers to cp.async.wait_group.

(pgas-quiet) -> Lowers to shmem_quiet().
```

### Fine-Grained Signaling 

```
(pgas-signal dest-flag value pe) -> Lowers to shmem_signal_add or nvshmem_signal_op.

(pgas-wait-until flag condition value) -> Lowers to shmem_wait_until.
```




IMPORTANT NOTES
----------------

Both global semaphores and CUTensorMap need "side channel" support. That will have to be added.  Effects metadata, hoisting, everything.


More Distributions.
For 1.0, Crisp is targeting :distribution values of :block and :replicated.  Ultimately, in some 2.0 version, we may want to expand to include:
- :block
- :block-cyclic
- :halo
- :sparse
- :irregular

Most of these should be realizable in Crisp 1.0 with macros. But for maximum performance, with a capital "P", the compiler will likely need to be involved.

