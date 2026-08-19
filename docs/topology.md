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

Hardware Profiles ✅
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

### `:mma-shapes` ✅

`:mma-shapes` the matrix-multiply-accumulate (tensor-core / DPAS) instruction shapes the hardware natively supports, each an (M N K) triple. An MMA computes D[M×N] = A[M×K]·B[K×N] + C[M×N], so all three dimensions identify it, and the same M×N typically comes in several K variants for different operand precisions (NVIDIA m16n8k8 for tf32, m16n8k16 for fp16, m16n8k32 for int8; Intel similarly). The form is vendor-neutral, mapping to NVIDIA mma.mMnNkK and Intel joint_matrix shapes alike.

```
:mma-shapes '((16 8 16) (16 8 8) (8 8 128))
```

### Crisp predefined hardware profiles

- `bmg`
- `h100`


### `--hardware-profile` ✅

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


Clusters and Distributed Shared Memory
--------------------------------------

Workgroup clusters and Distributed Shared Memory (DSMEM) are performance features introduced by NVidia in their Hopper architecture (`sm_90` and later).  In contrast, Intel hardware uses prefetching directly to large GRF banks instead (discussed later).

### What a cluster is, and what it buys you

Ordinarily a workgroup's shared memory is private: no other workgroup can see it, and the hardware
gives you no way to co-ordinate with a neighbour except by going all the way out to global memory.
A **cluster** relaxes exactly that.  It is a small group of workgroups — two, four, or eight — that
the hardware guarantees are resident *at the same time on the same GPC*, and which can therefore
see one another's shared memory.  That shared window across the group is what NVidia calls
**Distributed Shared Memory**.

Two capabilities follow, and everything else in this section is a consequence of one of them:

1. **A workgroup can reach a peer's shared memory** — so a barrier can be released by another
   workgroup ([`:mode :cluster`](#mode)), and a `sync-cluster` can rendezvous the whole group.
2. **One fetch can serve the whole group** — a single `load-tile` can pull a tile from global
   memory *once* and have the hardware deliver it into every member's shared memory
   ([`:multicast`](#multicast)).  In a matrix multiply, workgroups in the same cluster row want
   byte-identical `B` tiles, so the traffic for that operand falls by the size of the group.

The second is the reason most kernels reach for a cluster at all.

### The honest part: it is not free, and it does not always pay

A cluster constrains the scheduler.  Its workgroups must be co-resident on one GPC, so the more
of them there are, the less freedom the hardware has to place them.  Measured on an H100:
a cluster of **two costs nothing** (0.97–1.01× against the same kernel with no cluster), while a
cluster of **four can cost a great deal** — as much as 0.58× at a problem size where the grid
exactly fills the machine, and that penalty is paid whether or not you multicast anything.

Multicast has its own applicability rule, and it is narrower than it first appears.  It pays only
when **both** of these hold:

* **the machine is saturated** — below full occupancy there is no contention for memory bandwidth
  to relieve, so multicast is pure overhead; and
* **the kernel is fetch-limited rather than compute-limited** — a well-pipelined kernel that
  already hides its loads behind computation is not waiting on the fetch that multicast makes
  cheaper, while multicast's bookkeeping is on the critical path regardless.

Both conditions are easy to miss.  The same `:multicast true` that wins **+15.7%** on a 64×128
tile at N=2048 *loses* **7–10%** on a 64×256 tile that is equally saturated but has enough
arithmetic per byte to hide its loads.  There is a worked measurement of both sides in
`benchmarks/matmul/chap4_cluster_multicast/cluster-multicast.md`.

The practical advice: **reach for a cluster of two before a cluster of four**, and treat
`:multicast` as something to measure rather than something to assume.  Crisp is built so that
measuring it is a one-keyword change with everything else held fixed.

### Declaring it

If targeting modern NVidia architectures and hoping to exploit clusters and DSMEM you will want
your kernel to declare this.

### cluster-size 📝

```
(cluster-size &key set-to msg)
```

```
(declare (cluster-size :set-to 2))       ; 2 workgroups along axis 0 (rows)
(declare (cluster-size :set-to (2 1)))   ; identical, written explicitly
(declare (cluster-size :set-to (2 2)))   ; a 2x2 cluster — 4 workgroups
```

A **workgroup cluster** is a set of workgroups that the hardware guarantees will be
co-resident and co-scheduled, close enough to one another that they can address each
other's local memory and participate in a shared barrier. `cluster-size` declares how
many workgroups make up one cluster, and in what shape.

> **The value is a count of WORKGROUPS, not threads.** Every sibling declaration in this
> family — `global-size`, `local-size` — is measured in threads. This one is not.
> `(cluster-size :set-to 2)` means *two workgroups*, however many threads each of those
> contains. Writing `(cluster-size :set-to 256)` is not a large cluster; it is a request
> the hardware will refuse.

#### Why you would declare one

Two capabilities become available to a kernel once its workgroups are clustered:

1. **Distributed Shared Memory (DSMEM)** — a workgroup can read and write the `:local`
   memory of its cluster peers, and `sync-cluster` becomes meaningful across more than
   one workgroup.
2. **Multicast tile loads** — when several workgroups in a cluster need the *same* tile,
   the hardware can fetch it from global memory once and deliver it into every one of
   their local memories simultaneously. For a tiled matrix multiply this cuts the global
   traffic for the shared operand by the cluster's extent along the axis that operand
   does not depend on.

The second is the reason `cluster-size` exists at all today. `cluster-size` makes multicast
*possible*; an individual load asks for it with [`:multicast`](#multicast) on `load-tile`.
You never write a destination mask or elect an issuing workgroup — the compiler derives
both — but you do say which loads you expect to multicast, so that a load which cannot is
a compile error rather than a silent doubling of bandwidth.

#### Axes follow `:tile-shape`

The axis order is the same one `:tile-shape` uses: **axis 0 tracks dimension 0**. For a
row-major output tile grid that means axis 0 is rows and axis 1 is columns — the opposite
of the CUDA `x = columns` convention. This is not a matter of taste; see the measurement
under [:tile-shape](#tile-shape), where getting it backwards cost ~1.3x.

So for a matrix multiply that wants its two workgroups to share the `B` operand:

```lisp
(declare (global-size :derive-from C :strategy :strided :tile-shape (64 256))
         (cluster-size :set-to (2 1)))    ; 2 workgroups along ROWS
```

Both workgroups sit at the same column position and differ only by row, so both need the
same columns of `B` and different rows of `A`. `B` is therefore multicast and `A` is not.

#### A 2-D cluster multicasts BOTH operands

A 1-D cluster can only ever help one operand, and the shape above shows why: it halves `B`'s
traffic and does nothing for `A`. A matmul is symmetric in this respect --

    C[m,n] = sum_k A[m,k] * B[k,n]

`A` does not depend on `n`; `B` does not depend on `m`. So a cluster laid out over BOTH axes
lets each operand be fetched once per group instead of once per workgroup:

```lisp
(declare (global-size :derive-from C :strategy :strided :tile-shape (64 256))
         (cluster-size :set-to (2 2)))    ; 4 workgroups: 2 rows x 2 columns
```

Every workgroup in a cluster ROW wants the same `A` tile; every workgroup in a cluster COLUMN
wants the same `B` tile. Those are different sets of workgroups, which is exactly why the
group is a property of the LOAD rather than of the cluster.

**You do not declare which operand groups which way.** The compiler reads each load's tile
coordinates against the enclosing `tile-stride` variables: a coordinate list that does not
mention an axis's variable is invariant along that axis, and the invariant axes ARE the
multicast group. In

```lisp
(load-tile A (ring-get A-ring slot) (grid-y grid-k) :barrier ... :multicast true)
(load-tile B (ring-get B-ring slot) (grid-x grid-k) :barrier ... :multicast true)
```

`A`'s coordinates never mention `grid-x` and `B`'s never mention `grid-y`, so the two loads
receive orthogonal groups from one rule. A load whose coordinates vary along *every* clustered
axis has no group and is refused -- multicasting it would deliver one workgroup's tile to
another.

Cluster extents need not be equal: `(4 2)` is eight workgroups in a 4-row by 2-column
arrangement. Eight is the largest cluster CUDA guarantees portably; larger is opt-in per
architecture.

The rank of `cluster-size` must agree with the rank of `:tile-shape`, exactly as
`global-size` and `local-size` must agree in arity with each other. Axes beyond the
declared rank are 1. A scalar is shorthand for a rank-1 value, following
`(local-size :set-to 256)`.

`cluster-size` is permitted on a kernel with no `:tile-shape`, but there is then no tile
grid for the compiler to reason about, so `:multicast` cannot be honoured and is refused.
The declaration still enables DSMEM and a cluster-wide `sync-cluster`, which may be all
you want.

#### This declaration DOES affect the compiled kernel

Every other declaration in this family is advisory: it shapes the hoisting code Crisp
generates and leaves the kernel itself untouched. **`cluster-size` is not advisory.** It
determines:

- whether a `load-tile` **may** multicast at all (an individual load still asks with
  [`:multicast`](#multicast); without a cluster, that request is a compile error)
- the multicast destination mask
- which workgroup in each multicast group issues the load
- whether the compiler emits the cluster entry and exit fences (see
  [sync-cluster](#sync-cluster))

Because the compiler needs the shape at code generation time, the cluster dimensions are
also recorded in the generated PTX, which makes the host/kernel agreement something the
driver enforces at launch rather than a convention the hoisting code is trusted to honor.

Two things follow from this that are worth stating plainly:

- **There is no `:derive-from`.** A shape that is baked into code generation cannot be
  computed from a host-side runtime value.
- **A silent fallback would be a performance trap.** See *Degradation* below.

#### Limits and divisibility

**Cluster extent.** The portable maximum is 8 workgroups per cluster. Larger clusters are
supported on some parts (16 on Hopper) but require an explicit opt-in and are not portable
across devices; Crisp treats anything above 8 as requiring that opt-in.

> Measured on an H100 PCIe: a cluster of 8 launches; a cluster of 16 fails with
> `cudaErrorInvalidClusterSize`; a cluster of 16 succeeds once
> `cudaFuncSetAttribute(k, cudaFuncAttributeNonPortableClusterSizeAllowed, 1)` has been set.
> Larger clusters also reduce the number of blocks that can be resident, which is the
> scheduling cost behind the guidance below.

For a tiled matrix multiply, small is the point. A 2-workgroup cluster already collects the
entire traffic reduction on the shared operand, and larger clusters constrain the scheduler
— every workgroup in a cluster must be placed together, so a wide cluster quantizes badly
against the machine and can cost more in scheduling than it recovers in bandwidth.

**Divisibility.** The grid dimensions must be divisible by the cluster dimensions. Under
`:tile-shape` the grid is `CEIL(extent[k] / tile_shape[k])`, which is derived from the
*problem*, so divisibility is not automatic. A 4096-row problem in 64-row tiles gives 64
row-tiles and divides evenly by 2; a 320-row problem gives 5 row-tiles and does not.

Crisp handles the two strategies differently, mirroring the split already described under
[Device dispatch limits](#device-dispatch-limits--where-strided-and-exact-genuinely-differ):

- **`:strided`** — the grid is **padded** up to a multiple of the cluster dimensions and
  the fact is noted in the hoisting comments. The extra workgroups find no tiles left to
  claim and exit; the `tile-stride` loop guarantees every tile is still covered. The cost
  is a small amount of wasted dispatch, not correctness.
- **`:exact`** — there is no stride loop, so a padded workgroup would have no tile and a
  truncated grid would silently skip one. A grid that is not divisible by the cluster
  dimensions is therefore a hard **error**, naming both the tile shape and the cluster
  shape that conflict.

**This is enforced by the driver, per axis, as a hard launch error** — measured on an H100 PCIe
(sm_90, CUDA 12.4) via `cudaLaunchKernelEx`:

| grid | cluster | launch result |
|---|---|---|
| `(4,1,1)` | `(2,1,1)` | `cudaSuccess` |
| `(3,1,1)` | `(2,1,1)` | **`cudaErrorInvalidClusterSize`** |
| `(4,3,1)` | `(2,2,1)` | **`cudaErrorInvalidClusterSize`** (the y axis) |

Not a warning, not a silent clamp — a non-divisible grid simply does not launch.  So the policy
above is not a preference between two workable options: *something* has to happen, and padding
is the only one of the two that leaves `:strided` correct.

#### Degradation

Clusters require NVIDIA Hopper (`sm_90`) or later. On earlier NVIDIA architectures and on
Intel there is no equivalent, and the cluster extent collapses to 1.

Unlike [sync-cluster](#sync-cluster) — where degrading to `sync-workgroup` is semantically
exact and costs nothing — **degrading `cluster-size` is not free**. The kernel still
computes the correct answer, but every multicast becomes an ordinary per-workgroup load
and the traffic reduction that motivated the declaration is gone. Nothing about the result
reveals this.

Crisp therefore does not degrade silently: a kernel declaring `cluster-size` for a target
without cluster support emits a diagnostic, and the effective cluster extent is recorded
in the kernel's metadata so a test or a benchmark harness can assert on it rather than
inferring it from a timing number.

> **A clustered *matmul* is nevertheless NVIDIA-only, and for a different reason.**  The
> degrade above is not the whole story: a multicast pipeline also carries a
> [`:mode :cluster`](#mode) barrier ring, and `:cluster` — like `:block` before it — is a hard
> **compile error** on SPIR-V, not a degrade.  So such a kernel does not run slower on Intel;
> it does not build there.
>
> The two behaviours are deliberate and follow existing precedent.  `cluster-size` is launch
> geometry and harmless on its own, so it degrades — exactly as `local-size` does not error
> merely because a device cannot honour the value you asked for.  A `:cluster` barrier is an
> object that cannot exist on the target, so it errors — exactly as `:block` already does.

#### Interaction with other declarations

- **`:tile-shape`** — supplies the axis vocabulary and the grid whose divisibility is
  constrained. Required before any `:multicast` load can be honoured.
- **`:occupancy`** — does not apply. `:occupancy` scales the occupancy-sized `:strided`
  grid, which is only used when no `:tile-shape` is present; a cluster without a tile
  shape performs no multicast.
- **`local-size`** — independent. Cluster extent counts workgroups; `local-size` sizes
  each one.
- **`num-groups`** — a `:max` constraint must still be satisfied after the grid is padded
  to a cluster multiple.

#### Example

```
;; -- matmul --
;; 64x256 output tiles, two workgroups per cluster stacked along rows.
;; Both workgroups in a cluster need the same 256 columns of B, so B is
;; fetched once from global memory and multicast into both.
(def-kernel matmul (A B &out C)
  (declare #'(a-mat b-mat &out c-mat)
           (local-size   :set-to 160)
           (global-size  :derive-from C :strategy :strided :tile-shape (64 256))
           (cluster-size :set-to (2 1) :msg "share the B tile across the row pair"))
  ...)
```

#### `:msg`

As with `global-size` and `local-size`, `:msg` takes a string that is emitted as a comment
at the point where the hoisting code configures the cluster dimensions.


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

### `make-async-barrier` ✅

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

`:mode` answers one question: **what kind of object is this barrier, and how far does it reach?**
Omit it for the arch-automatic default; pass it explicitly to pin a specific kind (for degenerate
cases, or when reach is part of your algorithm rather than a property of the hardware).

The values form a ladder, each rung strictly more capable than the one below it:

| `:mode` | what the barrier IS | how far it reaches |
|---|---|---|
| `:linear` | the backend's group-async-copy handle | the workgroup |
| `:block` | a real mbarrier object | the workgroup |
| `:cluster` | a real mbarrier object | the whole workgroup cluster |

- `:linear` — `cp.async` on PTX, `OpGroupAsyncCopy` on SPIR-V.  A per-element / per-row
  cooperative copy global→SLM.  **Shipped** and metal-verified on both backends.  Valid on
  every supported arch.  Note the handle is not the same thing on both backends: on PTX
  `commit_group`/`wait_group` need no object at all, so the barrier is a *phantom* and the
  compiler emits a constant; on SPIR-V it owns a `target("spirv.Event")` slot that the async
  copies chain through.
- `:block` — `CuTensorMap` (TMA) on PTX.  A bulk descriptor-driven 2D copy global→SLM,
  completing on a **workgroup-local** mbarrier (`mbarrier.arrive.expect_tx.shared::cta` /
  `mbarrier.try_wait.parity.shared::cta`).  **NVIDIA sm_90+ only.**  On an older NVIDIA arch it
  is a compile error (needs sm_90+); **on Intel it is a compile error** — Intel's fast 2D path
  (LSC 2D block loads) loads global→*registers*, not SLM, and is **not** a barrier-governed
  transfer at all (see "Optimizing Intel MMA").
- `:cluster` 📝 — a real mbarrier that **peer workgroups in the same cluster may arrive on**
  (`mbarrier.arrive.shared::cluster` against a mapped peer address).  **NVIDIA sm_90+ only**,
  and only meaningful when the kernel declares a [cluster-size](#workgroup-clusters).

##### Which barriers need which rung

A pipelined kernel usually has two barrier rings, and they do **not** want the same rung:

- The **data-arrival** ring (conventionally `full`) is `:block` even in a clustered kernel.
  This surprises people, so it is worth being explicit: a multicast tile load writes into
  several workgroups' SLM at once, but the transaction completes on **each destination
  workgroup's own** mbarrier.  Every workgroup still waits on a barrier it owns, so the barrier
  is workgroup-local and `:block` describes it exactly.
- The **buffer-free** ring (conventionally `empty`) is the one that becomes `:cluster`.  It
  carries no transfer at all — no `load-tile` ever names it — and exists so consumers can tell
  the producer a slot is safe to overwrite.  Once a producer is filling slots in *peer*
  workgroups, those peers must be able to arrive on its barrier, and that is cluster reach.

So in a clustered matmul it is the barrier governing **no** data movement that gains `:cluster`,
while the barrier the multicast actually targets stays `:block`.  Both readings are literal once
you take `:mode` to mean "kind and reach" rather than "which DMA engine".


> **On Intel, only the bottom rung exists.**  `:block` and `:cluster` are both compile errors on
> SPIR-V, and `:mode :linear` **rings** (`:ring-count` > 1) are not implemented there either.  In
> practice that means a barrier *ring* of any kind is NVIDIA-only today, and Intel's fast matmul
> path reaches its throughput without barrier-governed staging at all — via direct register
> block-load prefetch.  This is not new with `:cluster`; it is the shape the key already had.

#### The arch-automatic default

With no `:mode`, the barrier picks the best global→local async copy for the elected architecture
(`--ir-target-arch`, or the per-backend default):

- **NVIDIA sm_90+** → `:block` (TMA / CuTensorMap).
- **NVIDIA < sm_90** (incl. the default `sm_80`) → `:linear` (`cp.async`).
- **Intel** (any arch) → **always `:linear`** (`OpGroupAsyncCopy`).

> **Arch-automatic never selects `:cluster`, even on sm_90+ with a cluster declared.**  The
> automatic default picks the best mechanism *the hardware can realize* — a capability question.
> Reach is not a capability question: it is a claim about your algorithm, namely that peer
> workgroups will arrive on this barrier.  Guessing it wrong does not cost throughput, it hangs
> the kernel, which is the same reason [`:arrivals`](#make-async-barrier-ring) is never inferred.
> `:cluster` is always written explicitly.

> **Guidance for Intel.**  `:linear` on Intel is a genuine async copy and useful for large /
> contiguous tiles, but it is a per-*row* `OpGroupAsyncCopy` — for the small, strided fetches a
> matmul does, it costs more than it saves.  On Intel, prefer a plain synchronous `load-tile`
> (no `:barrier`) for those, or the direct register block-load prefetch path (Intel MMA optimization).


### `load-tile` ✅

`(load-tile src dest (... grid-y grid-x) &key transpose identity barrier multicast) => nil`

Initiates a bulk memory transfer from the `src` tensor to the `dest` tensor (typically moving from Global Memory to SLM or registers).

* **Tile IDs (`grid-y`, `grid-x`):** The target location is specified using logical Tile Identifiers, which map to the strided chunks defined by the tensor's block distribution.  On a single GPU (no topology) this means simply: **the tile-ID is scaled by the `dest` tile's extent** to give the element origin in `src` — coord `(1 1)` with a `64×64` `dest` reads `src[64:128, 64:128]`.  These are exactly the `grid-y`/`grid-x` bindings that `tile-stride` and `matrix-multiply-tile-stride` hand you, so `(load-tile A A-tile (grid-y grid-k))` "just works".  When you need an exact element offset instead (unaligned / ragged), use `load-tile-at`.
* **`:transpose`:** A boolean indicating if the hardware should transpose the data during the load (leveraging tensor core layout features).
* **`:identity`:** A fallback value used for out-of-bounds padding if the tile intersects the edge of the source tensor.
* **`:barrier`:** Links this memory transfer to a previously created `async-barrier`. The hardware DMA engine will automatically signal this barrier when the bytes physically arrive in the destination memory space.
* **`:multicast`:** A boolean asserting that this tile is identical across one axis of the workgroup cluster and should be fetched once for all of them. Omitting it gives an ordinary per-workgroup load. See below.

#### `:multicast` 📝

`(load-tile src dest (... grid-y grid-x) &key transpose identity barrier multicast)`

In a kernel that declares a [`cluster-size`](#cluster-size), a tile that **every workgroup along
one cluster axis needs identically** can be fetched from global memory *once* and delivered into
all of their local memories simultaneously.  `:multicast` asks for that.

```lisp
;; cluster is (2 1) — two workgroups stacked along rows (axis 0)
(load-tile A (ring-get A-ring slot) (grid-y grid-k) :barrier (ring-get full slot))
(load-tile B (ring-get B-ring slot) (grid-x grid-k) :barrier (ring-get full slot) :multicast true)
```

`A`'s coordinates depend on `grid-y`, so the two workgroups need *different* rows of `A` — it is
not multicast, and asking for it would be wrong rather than merely wasteful.  `B`'s coordinates
ignore `grid-y`, so both workgroups want the same columns of `B` and one fetch serves the pair.

##### It is an assertion, not a directive

`:multicast` is a plain boolean.  You are **not** specifying an axis, a destination mask, or an
issuing workgroup — the compiler derives all three from the tile coordinates and the declared
cluster shape.  What you are saying is **"I expect this load to multicast,"** and the compiler
either does it or refuses to compile, naming the coordinate that conflicts.

> **A note on `true`.**  Crisp does not have a boolean literal yet; `true` and `false` are still
> pending (see the language-changes list).  Existing boolean keys such as `:transpose` are written
> with Common Lisp's `t` today, which is a stopgap rather than a decision — `t` and `T` are the
> *same symbol* to the reader, so it collides with the `T` that templates bind constantly.
> `:multicast` is documented with `true` because it is not implemented yet and there is no reason
> to add a second occurrence that will need migrating.

That division matters in both directions:

- **The mask and the leader are not writable by hand in any sane way.**  Exactly one workgroup per
  multicast group issues the fetch.  For a 2-workgroup cluster that is trivially the first; for a
  2x2 cluster the leader differs *per operand*, because `A`'s multicast groups and `B`'s partition
  the cluster differently.  Deriving that is the compiler's job.
- **Whether a load *should* multicast is not the compiler's call to make silently.**  A `load-tile`
  that quietly declines to multicast still computes the correct answer — at exactly the bandwidth
  you were trying to avoid paying, with nothing in the output to reveal it.  Making the intent
  explicit turns that silent 2x into a compile error.

This follows the same rule as [`:arrivals`](#make-async-barrier-ring): you state a fact you know,
the compiler checks shape rather than guessing intent.

##### Why this is a key on `load-tile` and not a barrier `:mode`

Everywhere else, a `load-tile`'s lowering is chosen by its `:barrier` — no barrier means a
synchronous copy, and a barrier's [`:mode`](#mode) picks which asynchronous mechanism.  Multicast
is the exception, and the example above shows why: **both loads name the same barrier, and only one
of them multicasts.**

The barrier cannot express the difference because it is not per-operand.  It is per-*stage* — that
is the entire meaning of `:arrivals 2`, "this slot tracks two transfers."  Multicast is a finer
choice *within* the TMA mechanism that varies from operand to operand, so it has no barrier to
hang on and belongs at the call site.

##### The barrier stays workgroup-local

A multicast writes into peer workgroups' local memory, but each destination workgroup's transaction
completes on **its own** mbarrier.  Every workgroup still waits on a barrier it owns, which is why
the data-arrival ring stays [`:mode :block`](#mode) in a clustered kernel rather than becoming
`:cluster`.  See [Which barriers need which rung](#which-barriers-need-which-rung).

##### Errors

`:multicast` is refused, with the conflicting coordinate named, when:

- the kernel declares no `cluster-size`, or the cluster extent is 1
- the tile's coordinates depend on **every** cluster axis, so no two workgroups want the same tile
- the target is not NVIDIA `sm_90+`

### `load-tile-at` ✅

`(load-tile-at src dest (... y x) &key transpose identity barrier) => nil`

Functions identically to `load-tile`, but instead of using logical Tile IDs, the location is specified using exact **Element Coordinates** (the specific scalar index offsets, such as the top-left pixel). This is necessary for unaligned loads, halo exchanges, or ragged boundary processing.

Note that, unlike `load-tile`, this does NOT accept the `:multicast` key. This is because proper resolution for multicast requires tile grid coordinates. 

### `store-tile` ✅

`(store-tile src dest (... grid-y grid-x) &key transpose transformF barrier) => nil`

Initiates a bulk memory transfer from the `src` tensor (usually registers or SLM) back to the `dest` tensor (usually Global Memory), targeting a specific logical Tile ID.

* **`:transformF`:** An optional epilogue function (e.g., `relu`) applied to the data during the store operation.
* **`:barrier`:** If provided, delegates the write out to the async DMA engine.
* **Note:** It is strictly illegal to use `:transformF` and `:barrier` simultaneously. A hardware DMA engine cannot apply arbitrary mathematical functions; it only moves raw bytes. If you need epilogue fusion, the warp must perform the math inline before storing.

### `store-tile-at` ✅

`(store-tile-at src dest (... y x) &key transpose transformF barrier) => nil`

Functions identically to `store-tile`, but uses exact **Element Coordinates** rather than logical Tile IDs to position the data in the destination tensor.

### `await` ✅

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
(sync-cluster)
(sync-workgroup) ✅
(sync-warp)


(make-arrival-sync <count>) => sync-handle
(sync-arrive sync-handle) => nil
(sync-wait sync-handle) => nil
```

#### sync-cluster

```
(sync-cluster)          ; arrive + wait, ordered.  The safe default.

;;  - OR -

(sync-cluster :arrive)  ; non-blocking: "I'm here"
(sync-cluster :wait)    ; block until all CTAs have arrived
```

`sync-cluster` makes every thread in the workgroup cluster wait until they have all arrived at the same point.

The default usage `(sync-cluster)` is simple and direct. It both announces that the thread is participating with other threads in the cluster and has completed any DSMEM (Distributed Shared Memory) operations and then waits for other threads to catch up.  Rather than going those two at once it is possible to split and use `(sync-cluster :arrive)` to make the announcement and then perform the actual wait `(sync-cluster :wait)` later. BUT, if you do this there are certain limitations that must be observed:
- the `:arrive` MUST be paired with a `:wait` and these CANNOT nest. (one pair at a time).
- `return` or otherwise exiting a routine between `:arrive` and `:wait` is disallowed.
- reading or writing to a cluster peers SMEM between `:arrive` and `:wait` is discouraged.
- modifying `:local` memory that was DSMEM published will likely result in a race and should be discouraged. This may not always be detectable by the compiler. Be wary of Crisp routines that modify local memory like `load-tile` and `load-local`

The compiler refuses the violations it can detect statically - unpaired or nested `:arrive`, divergent placement, peer access in the window, and returning before the `:wait`. It cannot detect every case of the last restriction; absence of an error is not proof of correctness.

Cluster synchronization is a NVidia feature that requires the Hopper architecture (`sm_90` or later).  If `sync-cluster` is used with earlier architectures or on Intel it simply degrades to `sync-workgroup`.  Note also if a kernel is not explicitly enqueued with a cluster specified then the cluster count is 1, meaning it is functionally exactly the same as `sync-workgroup`.

> **Verified, not assumed.**  The equivalence above holds only if the cluster barrier also
> rendezvouses the threads *within* a workgroup.  It does: NVIDIA's own
> `cooperative_groups::cluster_group::sync()` is implemented as `barrier_arrive(); barrier_wait();`
> with no `__syncthreads()` anywhere, and compiling it emits exactly `barrier.cluster.arrive;`
> + `barrier.cluster.wait;` — no `bar.sync`.  Since Cooperative Groups documents `sync()` as
> rendezvousing *all threads in the group*, and a cluster group's threads are all threads of all
> its workgroups, the cluster barrier must cover intra-workgroup convergence.  Crisp therefore
> emits no implicit `sync-workgroup` alongside it.  (CUDA 12.4 headers; PTX checked on sm_90a.)
>
> The same check settled the `:relaxed` question: NVIDIA's default `cluster.sync()` emits the
> **non-relaxed** form, which is the same default Crisp uses.

Like many sync operations, using `sync-cluster` in a divergent context (`if`, `cond`, or warp specialization block) can lead to deadlocks. Crisp will emit a compilation error if it encounters this situation. 




#### sync-workgroup

(sync-workgroup): Same as `barrier(CLK_LOCAL_MEM_FENCE)`.

#### sync-warp

(sync-warp): Implemented via `__builtin_shflsync(0xFFFFFFFF, 0)`.


#### Sync on Arrival

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





Rings ✅
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

### `make-async-barrier-ring` ✅

`(make-async-barrier-ring :ring-count <count> &key mode arrivals) => ring`

- **`:ring-count`** — required. A positive compile-time integer: the pipeline depth (how many
  stages are in flight at once).
- **`:mode`** — exactly as `make-async-barrier` (`:linear` / `:block` / `:cluster`; omit for
  arch-automatic).  Every slot in the ring shares the mode.  On **SPIR-V, `:linear` rings are not
  yet implemented** (they would need per-slot `spirv.Event` chaining) — a genuine ring
  (`ring-count > 1`) with `:mode :linear` is a compile error there; a single
  `(make-async-barrier :mode :linear)` is fine.  Since `:block` and `:cluster` are also SPIR-V
  compile errors, **a barrier ring of any mode is NVIDIA-only today**.
- **`:arrivals`** — **required for every barrier ring** (both modes).  How many transfers **each
  slot** tracks *per pipeline stage* — i.e. how many `load-tile`s name that one slot in a single
  stage.  The classic A+B staging is `2`.  It means the same thing to every lowering:
  - `:block` — the mbarrier's init **arrival count**.
  - `:cluster` — likewise the mbarrier's init arrival count, **scaled by the compiler** — see
    "`:arrivals` is per-workgroup" below.
  - `:linear` — the loads-per-stage factor in the `cp.async.wait_group((ring-count − 1) × arrivals)`
    depth (each `:linear` `load-tile` commits one group), i.e. how many groups a stage closes.
    Cluster reach has no meaning on this rung.

> **Why `:arrivals` is explicit and not inferred.**  A `:block` (TMA) barrier is a hardware
> mbarrier: it completes when *both* its arrival count and its expected transaction bytes are
> satisfied, so the count must be exactly right — **too high and the barrier never completes (the
> kernel hangs); too low and you read a half-arrived tile.**  The `:linear` `wait_group` depth is
> less catastrophic but still wrong if the count is off (no overlap, or reading too early).  For a
> *single* `make-async-barrier` the compiler infers it by counting the loads that name that
> barrier, which is correct because such a kernel has one stage in the text.  Through a **ring**
> that inference breaks: the prologue and the main loop *both* load the same ring, so the textual
> count (2 in the prologue + 2 in the main loop = 4) is **not** the per-stage count (2).  Grouping
> loads "per phase" statically is fragile, so Crisp asks you to say it — you already know the
> number: it is how many `load-tile`s you wrote against one slot.  Requiring it for **both** modes
> also keeps an arch-automatic ring kernel portable: the same `:arrivals` works whether the arch
> resolves to `:block` on sm_90+ or `:linear` on sm_80.

> **`:arrivals` is per-workgroup, and stays that way under `:cluster`.**  On a `:cluster` ring the
> barrier really does collect more arrivals than the number you wrote, because peers arrive on it
> too.  **You do not write the bigger number.**  `:arrivals` remains what it has always been — how
> many transfers *one workgroup* puts through *one slot* in *one stage* — and the compiler scales
> it by the declared cluster extent.
>
> This is the same division of labour the rule above describes, not an exception to it: you state
> a fact you know (what your own workgroup does per stage), the compiler computes a consequence
> from a fact it knows (how many workgroups are in the cluster).  Making you do the multiplication
> would mean that adding a single `cluster-size` line to a working kernel silently requires editing
> an unrelated barrier declaration, and forgetting it hangs the GPU.

```
;; three stages in flight; each stage stages an A-tile and a B-tile under its own barrier slot.
(make-async-barrier-ring :ring-count 3 :mode :block  :arrivals 2)   ; NVIDIA sm_90+ (TMA mbarriers)
(make-async-barrier-ring :ring-count 3 :mode :linear :arrivals 2)   ; sm_80+ (cp.async wait_group 4)

;; a clustered pipeline: the data-arrival ring stays workgroup-local, the buffer-free ring
;; gains cluster reach so peer workgroups can release the producer's slots.
(make-async-barrier-ring :ring-count 3 :mode :block   :arrivals 2 :initial-state :waiting)
(make-async-barrier-ring :ring-count 3 :mode :cluster :arrivals 4 :initial-state :signaled)
```


Warp Specialization ✅
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



Matrix Multiplication ✅
---------------------

### `make-register-tile` ✅
```
(make-register-tile <type> <dimensions> <initial-value> &key warps)

(make-register-tile float (128 128) 0.0)
(make-register-tile float (64 64) 0.0 :warps '(false true true))   ; warp-specialized: tile on the 2 consumer warps
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

#### `:warps` — the warp participation mask (for warp specialization)

By default the tile distributes across **every** warp of the workgroup.  That is wrong under
**warp specialization**: if only the *consumer* warps run the MMA, any fragment the compiler
placed on a producer warp would never be computed — a wrong result.  `:warps` fixes that by
letting you say **exactly which warps hold the tile**, as a flat boolean **topology map**,
positional over the workgroup's warp layout:

```
(make-register-tile float (64 64) 0.0 :warps '(false true true))
;; warp 0 holds no fragment; warps 1 and 2 split the tile.  Pairs with a
;; (with-warp-specialization (:producer 1 :consumer 2) ...) whose producer is warp 0.
```

- **Elements** are `true` / `false` (or, equivalently, `1` / `0`).  The mask is deliberately
  decoupled from `with-warp-specialization` — `make-register-tile` is declared in the outer
  `let`, outside any role block, so it references warps *positionally*, not by role name.  It is
  **your** responsibility to line the `true`s up with the warps that actually run the MMA (the
  same discipline as `:arrivals` — the compiler checks shape, not intent).
- **Length** must equal the workgroup's warp count (`local-size / warp-size`).  When `local-size`
  is statically known this is a **compile-time** error; otherwise it is deferred to an
  `--runtime-checks` assertion.
- **Even division (compile-time).**  An `(M N K)` MMA fragment is `M×N`, computed collectively by
  one whole warp, so a tile is a grid of `(tile-M / frag-M) × (tile-N / frag-N)` fragments (e.g.
  a 64×64 tile with `(16 8 8)` = `4×8 = 32` fragments).  The number of `true` warps **must evenly
  divide** that fragment count, or it is a compile error.  So a 32-fragment tile allows 1 / 2 / 4 /
  8 / 16 / 32 consumers — **not 3** (this is why the warp-spec example below uses `:consumer 2`,
  not the `:consumer 3` an earlier draft showed).
- **Occupancy note.**  More `true` (consumer) warps sharing one C-tile ⇒ fewer fragments per warp
  ⇒ fewer registers per thread ⇒ higher occupancy.  So the consumer count is the real lever
  against the single-warp register wall (Endeavor 138's 4096 plateau) — worth sweeping.

### matrix-multiply-tile-stride ✅
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
> per-tile `:epilogue`.  The form that does the fusing in either place is
> [`map-elements!`](#map-elements----fusing-your-own-code-into-the-epilogue).
> Use whichever owns the *complete* reduction: if
> `mma-accumulate-via-tile` does the whole K-contraction itself, fuse on `my-accum` (finer,
> in-register).  But in this **staged** pattern — the macro's `grid-k` loop calls
> `mma-accumulate-via-tile` once per K-step — `my-accum` holds a **partial** sum each step, so the
> activation belongs in the macro's `:epilogue` (on the completed `C-tile`), **not** on `my-accum`.
> Fusing on `my-accum` here is a compile-time **error**, not merely bad practice — see the
> partial-sum warning under `map-elements!` for why even a linear function is wrong.

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


### inner-dimension ✅
`(inner-dimension A B) => ulong`
Returns the size of the inner dimensions of two tensors (the dimension used for matrix multiplication).

### outer-dimensions ✅
`(outer-dimensions A B) => M N`

### fill-tile ✅
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



### mma-accumulate-via-tile ✅
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

### map-elements! ✅ — fusing your own code into the epilogue

```
(map-elements! <fragment-or-tile> #'<unary-fn>)   => nil ; applied to every element, IN PLACE
```

Applies a **unary function to every element**, in place, while the data is still in registers.
This is the mechanism for a fused epilogue — an activation, a scale, a clamp, anything
elementwise — without a round trip through memory.

**Status.**  The **fragment** form (on `mma-accumulate-via-tile`'s accum binding) is implemented
on both backends and verified on hardware.  The **whole-tile** form (in an `:epilogue`) and
`--differentiate` support are in flight; see `tests/spec/150-fused-epilogue/`.

The function is an ordinary Crisp `def-function`, not a compiler builtin:

```
(def-function leaky-relu (x)
  (declare #'(float => float))
  (if (> x 0.0) x (* x 0.5)))

(mma-accumulate-via-tile (16 8 8) C-tile A B (acc)
  (accum-op)                              ; the MMA fires
  (map-elements! acc #'leaky-relu))       ; then YOUR code, on the accumulator, in registers
```

That is the whole point: vendor libraries offer a fixed menu of epilogues (bias, relu, gelu …),
and anything off the menu costs you a full round trip to HBM — write C, read C, write C.  Here
the activation is just a function you wrote.  Crisp realises first-order functions by **template
monomorphization**, so there is no function-pointer indirection in the emitted kernel.

**It is the same idiom as `store-tile`'s `:transformF`**, at a different altitude.  Three places
can carry a per-element transform, and which one you want depends on where the data is:

| site | when it runs | form |
|---|---|---|
| accumulator fragment | in registers, per fragment | `map-elements!` on the accum binding |
| completed C-tile | in registers, once per output tile | `map-elements!` in the `:epilogue` |
| during the write-out | as each element goes to memory | `store-tile … :transformF #'f` |

For a pure elementwise activation, `:transformF` is often the best of the three — it rides a
store you were already doing, so it costs nothing extra.

> **⚠️ Do NOT fuse on `acc` inside a staged K-loop.**  When `matrix-multiply-tile-stride`'s
> `grid-k` loop calls `mma-accumulate-via-tile` once per K-step, `acc` holds a **partial sum**,
> and a map applied there mutates the accumulator that later K-steps keep adding to.  With `p1`
> and `p2` the two K-steps' contributions, doubling once in the `:epilogue` gives `2·p1 + 2·p2`,
> while doubling per K-step gives `4·p1 + 2·p2`.  Note this is **not** a statement about
> non-linear functions — the only function that survives per-step application is the identity,
> so even a scale is wrong.  The compiler refuses it; put the map in the `:epilogue`, where the
> tile is complete.

**Elementwise only, and that is deliberate.**  A fragment is warp-collective, and which logical
`(row, col)` a given register holds is a per-vendor layout detail.  An elementwise function does
not care — applying `f` to each register independently is identical to applying it to the logical
matrix — which is exactly what makes this portable.  Operations that *do* need the coordinate
(adding a bias along N, row-wise reductions like softmax) are not expressible this way and are
not supported.

**What it lowers to.**  The two vendors differ, and it shows up in the generated code:

- **NVIDIA / PTX** — a fragment is a record of scalar registers whose count is known at compile
  time, so the map is **unrolled** fieldwise (four applications for a tf32 `m16n8k8`
  accumulator), directly after the `mma.sync`.
- **Intel / SPV** — a fragment is an opaque cooperative matrix whose per-invocation component
  count is a **runtime** value (`OpCooperativeMatrixLengthKHR`), so the map is a **loop** over the
  components, each reached with `OpAccessChain`.  This is the same fact as the paragraph above:
  the kernel never learns which logical element it holds.

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

### Matrix Multiply with pipelining ✅

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

### Matrix Multiply with Pipelining via Warp Specialization ✅

```
(with-template-type (T)
  (def-type mat (matrix T :address-space :global :align :compact :contiguous-term :row-major))

  (def-grid-function warp-specialized-matrix-multiply (A B &out C)
    (declare #'((mat T) (mat T) (mat T))
               (global-size :derive-from C :strategy :strided)) 

    ;; ring depth 3 is a repeated LITERAL (:ring-count needs a compile-time integer — see Chapter 2).
    (let ((A-tile-ring (make-scratch-matrix-ring A (128 128) :ring-count 3))
          (B-tile-ring (make-scratch-matrix-ring B (128 128) :ring-count 3))
          ;; C-tile lives on the 2 CONSUMER warps only (warp 0 is the producer, holds no fragment).
          ;; 128x128 with (16 8 8) = 8x16 = 128 fragments; 2 consumers -> 64 each (evenly divides).
          (C-tile (make-register-tile T (128 128) (identity T) :warps '(false true true)))
          (M N (outer-dimensions A B))
          (K (inner-dimension A B))
          (n-k-steps (/ K 128))   ; k-step is the 128-wide staging tile; producer & consumer share this count
          
        ;; 1. The Barriers.  Both are ring depth 3; :arrivals is how many transfers land on each
        ;; slot per stage (Chapter 2 makes it required for every barrier ring).
        ;; empty starts 'signaled' so the Producer can immediately begin fetching; the Consumer
        ;;   arrives it ONCE per slot (its single `signal`), so :arrivals 1.
        (empty-barrier-ring (make-async-barrier-ring :ring-count 3 :arrivals 1 :initial-state :signaled))
        ;; full starts 'waiting' so the Consumer doesn't read garbage; the Producer's two loads
        ;;   (A + B) arrive it, so :arrivals 2.
        (full-barrier-ring  (make-async-barrier-ring :ring-count 3 :arrivals 2 :initial-state :waiting)))

    ;; Outer loop
    (tile-stride C C-tile (grid-y grid-x) 
      
      ;; Split the execution!  The compiler physically maps these to different warps.
      ;; :consumer 2 (not 3) so the 128-fragment C-tile divides evenly across the consumers;
      ;; the workgroup is (1 + 2) * warp-size = 3 warps.
      (with-warp-specialization (:producer 1 :consumer 2)
        
        ;; ==========================================
        ;; THE PRODUCER BLOCK (Memory only)
        ;; ==========================================
        (:producer
          (let ((ring-idx 0))
            (dotimes (grid-k n-k-steps)
              
              ;; 1. Wait for the Consumer to say this SLM slot is empty/safe.
              (await (ring-get empty-barrier-ring ring-idx))
              
              ;; 2. Issue the hardware fetch. 
              ;; The hardware DMA engine will AUTOMATICALLY signal the full-barrier when the bytes arrive.
              (load-tile A (ring-get A-tile-ring ring-idx) (grid-y grid-k) :barrier (ring-get full-barrier-ring ring-idx))
              (load-tile B (ring-get B-tile-ring ring-idx) (grid-k grid-x) :barrier (ring-get full-barrier-ring ring-idx))
              
              ;; 3. Move to the next ring slot
              (set! ring-idx (mod (+ ring-idx 1) 3)))))
        
        ;; ==========================================
        ;; THE CONSUMER BLOCK (Math only)
        ;; ==========================================
        (:consumer
          (let ((ring-idx 0))
            (dotimes (grid-k n-k-steps)
              
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
              (set! ring-idx (mod (+ ring-idx 1) 3)))
          
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


### Operand layout: Intel MMA operands must be `:row-major` ✅

An Intel MMA operand — the `A` and `B` matrices, and the accumulator — must be declared
`:contiguous-term :row-major` (equivalently `:last`). A `:col-major` operand is a **compile
error**, not a silent fallback:

```
Intel cooperative-matrix (MMA) operands cannot be :col-major (:contiguous-term :first).
IGC ships no PackedA_ColumnMajor / PackedB_ColumnMajor load builtin, so such a kernel
fails to build on the device, and a ColumnMajor accumulator computes incorrectly.
Declare the operand :row-major, or stage an explicit transpose into scratch and feed the
MMA from there. (NVIDIA/PTX is unaffected.)
```

This is a limitation of the **hardware's builtin library**, not a Crisp design choice, and it
was measured rather than assumed. Crisp translates `:col-major` to `MemoryLayout =
ColumnMajorKHR` on the `CooperativeMatrixLoadKHR`, which is valid SPIR-V — but on an Arc B580
(driver 32.0.101.8864) IGC then fails the module build with:

```
undefined reference to `__builtin_spriv_OpJointMatrixLoadINTEL_
  PackedB_ColumnMajor_SG16_8x16_i32_8_global_v8i8_pi32_i32'
```

and the same for `PackedA_ColumnMajor` on a column-major `A`. IGC simply does not ship
ColumnMajor variants of the operand-load builtins. A column-major **accumulator** is a
slightly different story — that builtin *does* exist and the module builds — but it then
computes the wrong result on metal, so it is refused too, conservatively, until that is
understood.

Failing at compile time with a sentence is deliberate. The alternatives are worse: emitting
the honest ColumnMajor load makes the kernel fail at `zeModuleCreate` quoting a mangled
builtin name, and silently transposing the operand behind your back would quietly change a
kernel's performance characteristics.

**If you need a column-major operand**, stage the transpose explicitly into scratch and feed
the MMA from the staged tile. That keeps the cost visible and under your control — it is what
the MMA autodiff backward does for its transposed operands.

> **This is per-vendor, like the shapes.** On NVIDIA/PTX the layout is baked into the
> `mma.sync` instruction variant (`row.col`) rather than read from the tensor type, and
> `:col-major` **B** is the *canonical* form there. So the same source may want a different
> operand layout per backend, exactly as it wants a different `:mma-shapes` triple.

Specs: `133-mma-spv/13-col-major-operand-refused-bmg`, `14-col-major-accum-refused-bmg`.
History: `plan/bugs.md` #035 — for months Crisp *dropped* the declared layout here, so
`:col-major` was a silent no-op and you compiled a row-major kernel without being told.
Four shipped specs were unknowingly relying on that.

### Reusing the "Ring" Meme

We reuse the ring concept, but we are not building a ring of scratch-matrices (SLM) and do not need async-barriers.
Instead, we build a ring of Register Tiles (a double-buffer). We issue a load into the "pong" register while the DPAS computes on the "ping" register, and we issue a prefetch into the cache for a tile even further in the future.

### The Optimal Intel Pipelined MMA

The goal here is to stretch the synchronous baseline to achieve the optimal LSC 2D Block Prefetch pipeline on Intel hardware.

```
(with-template-type (T)
  (def-type mat (matrix T :address-space :global :align :compact :contiguous-term :row-major))

  (def-grid-function intel-prefetch-matrix-multiply (A B &out C)
    (declare #'((mat T) (mat T) &out (mat T))
               (global-size :derive-from C :strategy :strided)) 

    ;; Ping-Pong Register Double Buffering. 
    ;; Notice: We use make-register-tile-ring, NOT scratch-matrix-ring.
    (let ((pipeline-stages 2) 
          (A-reg-ring (make-register-tile-ring T (128 128) :ring-count pipeline-stages))
          (B-reg-ring (make-register-tile-ring T (128 128) :ring-count pipeline-stages))
          (C-tile (make-register-tile T (128 128) (identity T)))
          (M N (outer-dimensions A B))
          (K (inner-dimension A B)))

      ;; ==========================================
      ;; THE PROLOGUE (Prime the Pump)
      ;; ==========================================
      ;; 1. Fire cache prefetches for k=0 and k=1
      (prefetch-tile A (grid-y 0) :size (128 128))
      (prefetch-tile B (0 grid-x) :size (128 128))
      (prefetch-tile A (grid-y 1) :size (128 128))
      (prefetch-tile B (1 grid-x) :size (128 128))

      ;; 2. Issue the actual register block-loads for k=0
      (load-tile A (ring-get A-reg-ring 0) (grid-y 0))
      (load-tile B (ring-get B-reg-ring 0) (0 grid-x))

      (tile-stride C C-tile (grid-y grid-x) 
        
        ;; ==========================================
        ;; THE K-LOOP PIPELINE
        ;; ==========================================
        (let ((ring-idx 0))
          (do-times (grid-k K)
            (let ((next-k (+ grid-k 1))
                  (prefetch-k (+ grid-k 2))
                  (next-ring-idx (mod next-k pipeline-stages)))

              ;; 1. Issue prefetch for future K.
              ;; This lowers to OpSubgroup2DBlockPrefetchINTEL (Fire and forget into L1)
              (when (< prefetch-k K)
                (prefetch-tile A (grid-y prefetch-k) :size (128 128))
                (prefetch-tile B (prefetch-k grid-x) :size (128 128)))

              ;; 2. Issue register load for the NEXT k.
              ;; This lowers to OpSubgroup2DBlockLoadINTEL (L1 -> GRF).
              ;; The hardware scoreboard tracks this dependency automatically.
              (when (< next-k K)
                (load-tile A (ring-get A-reg-ring next-ring-idx) (grid-y next-k))
                (load-tile B (ring-get B-reg-ring next-ring-idx) (next-k grid-x)))

              ;; 3. Compute on the CURRENT k.
              ;; DPAS executes against the 'ping' registers while the 'pong' registers are loading.
              (mma-accumulate-via-tile (16 8 8) C-tile 
                                       (ring-get A-reg-ring ring-idx) 
                                       (ring-get B-reg-ring ring-idx))
              
              ;; 4. Swap buffers
              (setf ring-idx next-ring-idx))))

        :epilogue
          (relu C-tile) 
          (store-tile C-tile C (grid-y grid-x))))))
```

### Why this is the optimal shape for Intel

No Warp Specialization: You don't need a producer/consumer warp split because the LSC data port and the Math/FPU data ports operate concurrently inside the same Xe Core. A single subgroup can issue the memory instructions and the math instructions without blocking itself (until the register is actually read).
No Barriers: Intel's dependency tracking is managed in hardware via the register scoreboard. When `mma-accumulate-via-tile` executes, if `ring-idx 0` hasn't finished loading from the L1 cache, the thread simply sleeps.
Register Pressure is the Only Limit: On NVIDIA, your pipelining depth is usually constrained by how much SLM you can allocate per block. On Intel, your pipeline depth is constrained by the physical size of the GRF (which is why `pipeline-stages` is set to 2 here—ping-ponging a 128x128 register tile consumes a massive amount of the GRF).



### Hopper warpgroup MMA — `make-wgmma-accumulator` ✅ + `wgmma-accumulate-via-tile` ✅

On NVIDIA **Hopper (sm_90a)** the tensor-core unit is driven by `wgmma` (4th-gen *warpgroup*
async MMA) rather than the `mma.sync` used by `mma-accumulate-via-tile`.  The difference is
scope: one `wgmma` instruction spans a **warpgroup** — 4 warps / **128 threads** — and produces
a `64×N` output in a single issue (an `m64n128k8` is 64×128 = 8192 results), with the accumulator
spread across all 128 threads.  It is the instruction cuBLAS uses; on the benchmark ladder the
Crisp wgmma matmul reaches ~⅔ of the cuBLAS tf32 ceiling, versus a few percent for the naive
`mma.sync` chapters.

Two forms mirror the `make-register-tile` / `mma-accumulate-via-tile` pair:

```
(make-wgmma-accumulator <elem> (64 N) <init>)          ; the D matrix — a warpgroup accumulator
(wgmma-accumulate-via-tile (64 N K) D A B [:swizzle :128b])   ; D += A·B ; A, B are SMEM tiles
```

`make-wgmma-accumulator` mints (on demand) a `64×N` warpgroup accumulator record — `N/2` flat
`f32` registers per thread, the wgmma D thread→element mapping across the 128-thread warpgroup —
each field initialized to `<init>`.  `<elem>` is `float` (tf32) for now.  It is a **dedicated**
constructor, not a flag on `make-register-tile`, precisely because the per-thread layout is the
warpgroup one, not the per-warp fragment layout.

`wgmma-accumulate-via-tile` does `D += A·B` over the whole accumulator in one shot — **no fragment
walk** (contrast `mma-accumulate-via-tile`, which loops the fragment grid for you).  It is
**synchronous**: the macro wraps the `wgmma.fence` / `commit_group` / `wait_group` around the
accumulate, so one call is a complete `D += A·B`.  `A` and `B` are SMEM scratch tiles (from
`make-scratch-matrix`, `load-tile`, or a `:block` TMA load).

Shape rules — grounded in the ISA, checked at compile time:

- **M is fixed at 64** (wgmma is always `m64`); anything else is a compile error.
- **N is a multiple of 8 in `[8, 256]`** (the `m64nNk8` family).
- **K depends on `:swizzle`.**  Without it, `K` must be exactly **8** — a single `k8` slice fed
  from a plain row/col-major SMEM tile.  With `:swizzle :128b`, `K` may be any positive multiple
  of 8: the tile is a **K-block** of `K/8` slices, and the accumulate emits the 128-byte-swizzle
  SMEM descriptor + a `wgmma` per `k8` slice.  (`:128b` swizzle also requires the innermost 32
  tf32 elements to be 128-byte contiguous — already true for a `64×32` K-block load.)
- **local-size must be a multiple of 128** — a warpgroup is 128 threads.  A single-warpgroup
  kernel declares `(local-size :set-to 128)`; multiple warpgroups (and the producer-warp +
  consumer-warpgroup split under `with-warp-specialization`) scale that up.

```
;; one warpgroup, a single k8 tf32 accumulate
(def-kernel wgmma_min (&out C)
  (declare #'(&out mt) (global-size :set-to 128) (local-size :set-to 128))
  (let ((A-tile (make-scratch-matrix float (64 8)))
        (B-tile (make-scratch-matrix float (8 64)))
        (D      (make-wgmma-accumulator float (64 64) 0.0)))
    (wgmma-accumulate-via-tile (64 64 8) D A-tile B-tile)
    ...))

;; a 32-wide K-block (4 k8 slices) over a big n256 tile, swizzled
(wgmma-accumulate-via-tile (64 256 32) D A-tile B-tile :swizzle :128b)
```

wgmma is **forward-only** (no autodiff) and NVIDIA-Hopper-only; on other targets use
`mma-accumulate-via-tile`.


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

