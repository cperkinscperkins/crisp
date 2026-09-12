Crisp: Deferred Cluster-Scale Topology
--------------------------------------

> **⚠ DEFERRED.**  Everything in this document is set aside.  It describes an earlier, larger
> design in which a Crisp kernel could be compiled for a cluster — a torus mesh, a fat-tree
> superpod — as readily as for one GPU, with `def-topology` describing the machine and
> `def-orchestration` placing data across it.  None of it is implemented.

The material that **did** ship — hardware profiles, async tile loading and its barriers,
clusters and DSMEM, synchronization, rings, warp specialization, and the matrix-multiply / MMA
forms with both vendor optimization arcs — now lives in the main design document under
**Topologically Aware Compilation** in [`ideal_001.md`](ideal_001.md).  Look there first; this
document is kept for the cluster-scale design that has not been built.

What remains here:

- **Topologies** — `def-topology`, `compute-unit`, `interconnect`, and the algorithmic metadata
  that would let the compiler reason about a fabric.
- **`def-orchestration`** — data distribution and residency across a topology.
- **Out of Core Orchestration** — progressively enqueuing data too large to fit on the device.
- **Primitives** — the raw movement / synchronization / signaling forms those would need.


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

