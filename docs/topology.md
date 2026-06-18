Advanced Crisp: Topological Aware Compilation
------------------------------------------------

As you've seen in the Crisp design documentation, it has a lot of macros and forms, more so than other languages.  Striding, reductions, async behaviors, tiling and more all have various macros and forms that help make kernel writing more straightforward.

Experienced readers may look at a form like `loop-vector-stride` and think "sure, that's convenient, but I can get the global size, the vector size and set up a stride myself. It's not THAT much trouble". And that is true. But Crisp has these forms for a reason (besides ease-of-use) and that reason is that many of these forms are Topologically Aware. Which is to say, that with these forms you can write a performant kernel that can be compiled either for a single GPU, or for a cluster organized as a Torus Mesh or a Fat Tree Superpod or whatever. And we mean Performant with a capital "P", exploiting pipelining, warp specialization, tensor core MMAs and more. Crisp users can target these different systems without rewriting their kernel code or worrying about NVLink vs OpenSHMem, Unified Bus or other fabrics. 

Crisp also supports "out of core" orchestration, where the data is too large to fit on the GPU, but needs to be progressively enqueued and processed in chunks. 

To make this happen the Crisp compiler needs three things:

- `def-topology` to describe the organizaion of your cluster
- `def-orchestration`  with location and memory distribution information
- `def-kernel` with the optimized kernel code. 

Note that Crisp is not auto-optimizing the kernel for you. That is an ongoing area of research. You will have to choose the optimization strategy that fits your problem domain and code it. But Crisp forms make this a straightforward endeavor. We'll use real examples of matrix multiplication and Flash Attention as we progress.


Topologies
----------

A topology can be defined with `def-topology`. We'll go over it in a second, but it is essentially a function that returns an `interconnect`. These three examples of a typical single user workstation, a 10 node cluster of a supercomputer, and a mesh might help:

```
(def-topology my-workstation ()
  (let  ((main-cpu (compute-unit :id 'xeon-cpu :type :cpu-socket :memory 512GB))
         (main-gpu (compute-unit :id 'pvc-tile :type :gpu-tile :memory 64GB :arch :pvc))
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

Once a `def-orchestration` is expanded to use a topology then the topologically aware `make-async-barrier` routine and all consumers of those barriers (`position-tile-in`, `store-tile`, `await` et al) are adjusted by the compiler. If the compiler sees that the data movement requires a simple address space transfer, then the LLVM-IR it lowers handles that. But if it determines that requires a transfer across the PGAS fabric, then it becomes that. Additionally, the kernel signature might be modified to accept an implicit `CUTensorMap`, if required. On the hoisting side, the python example code that is generated will demonstrate how to initialize data with NCCL/OneCCL scatter, launch kernels, initialize a `CUtensorMap` (if reuquired), move data with allreduce and gather.

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

Allocates a topologically aware data-movement barrier. Depending on the memory scope it spans, the Crisp compiler lowers this into the appropriate hardware construct (e.g., an `mbarrier` object in Shared Local Memory for TMA, or an asynchronous `cp.async.commit_group` fence). This barrier is strictly used to synchronize the state of the hardware DMA engine with the execution unit, not for arbitrary control flow.

### `load-tile`

`(load-tile src dest (... grid-y grid-x) &key transpose identity barrier) => nil`

Initiates a bulk memory transfer from the `src` tensor to the `dest` tensor (typically moving from Global Memory to SLM or registers).

* **Tile IDs (`grid-y`, `grid-x`):** The target location is specified using logical Tile Identifiers, which map to the strided chunks defined by the tensor's block distribution.
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

(make-async-barrier-ring :ring-count <count>) => ring


(ring-get <ring> <index>) => <object>
```

For pipelining, we often need several scratch memory pads that we cycle through. Thus one can be loading while
another is being used for read or write. And if we are performaing async loading, we'll need a matching barrier.

The `<tensorType>` can be a type declaration or just a tensor variable.  
`<dimensions>` is a list of integers, which must be known at compile-time. They cannot be runtime variables.
`<dim>` is a compile time constant integer, used for the vector variant.

`ring-get` takes a ring and an index and returns the nth object in the ring. 

;; Q: does make-async-barrier-ring need :initial-state :signaled / :waiting ?


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

### matrix-multiply-tile-stride
```
(matrix-multiply-tile-stride <matrix> <matrix-tile> <inner-dim-scalar> (<grid-bindings>) ...)
```

<grid-bindings> are `(grid-y grid-x grid-k)`

Inside the body of the macro, `grid-k` will be the fastest changing term as it loops over K. 
This macro is very handy for producing matrix multiply kernels.  If used in conjunction with `mma-accumulate-via-tile` 
then nearly all the boilerplate of a matrix multiply is handled.


### inner-dimension
`(inner-dimension A B) => ulong`
Returns the size of the inner dimensions of two tensors (the dimension used for matrix multiplication).

### outer-dimensions
`(outer-dimensions A B) => M N`



Matrix Multiplication Optimization - A Story In Three Chapters.
---------------------------------------------------------------

### Basic Matrix Multiply with async tile loading.

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
          (barrier (make-async-barrier))) ;;topology aware async
    (matrix-multiply-tile-stride C C-tile K (grid-y grid-x grid-k)

      (load-tile A A-tile (grid-y grid-k) :barrier barrier) 
      (load-tile B B-tile (grid-k grid-x) :barrier barrier )
      (await barrier) 
      
        (mma-accumulate-via-tile (16 8) C-tile A-tile B-tile (my-accum)
            ;; We are now inside the innermost loop!
            ;; The developer decides when (or if) to execute the math.
            ;; accum-op is available in this context.
            (accum-op) ;; Fires the DPAS/MMA instruction
            ;; Developer can immediately do epilogue fusion while still in registers
            (relu my-accum) 
            (add-bias my-accum bias-tile)) ;; <-- fictional operation for illustrative purposes
        ;; (Another barrier usually goes here before the next 'k' iteration overwrites SLM)
        (sync-workgroup))
      ;; 4. Loop is done. Store the final computed 128x128 tile back to Global Memory C
      (store-tile C-Tile C (grid-y grid-x) :barrier barrier))))
```



### mma-accumulate-via-tile
```
(mma-accumulate-via-tile (<sz-expr>) C-tile A-tile B-tile (<accum-binding>) 
  ;; in the context of this macro, the helper `accum-op` is available.
  ;; call it once to perform the MMA accumulation.
  ...)
```

`mmm-accumulate-via-tile` walks tiles using an even smaller tile of size `<sz-expr>`. 
`<sz-expr>` must evaluate to a list of integers that match the Tensor MMA units of the underlying hardware.
For Intel hardware these sizes are 8x8x8, 8x8, or 16x16x16, 16x16. 
For Nvidia there are various sizes.  16x8 is very common.

Also note that the overall tile size ( 128x128 in the code above) must be a multiple of the MMA units, of `<sz-expr>`. 

Below is an example of the triple loop that `mma-accumulate-via-tile` might expand into.
```
(let ((accum (make-register-fragment 16 8 0.0)))
  (dotimes (tk 128 16)
    (dotimes (ty 128 16)
      (dotimes (tx 128 8)
        (let ((frag-a (load-fragment-a A-shared ty tk))      ; Lowers to ldmatrix.sync.x4
              (frag-b (load-fragment-b B-shared tk tx)))     ; Lowers to ldmatrix.sync.x2
          ;; Lowers directly to NVVM intrinsic: @llvm.nvvm.mma.m16n8k16.row.col
          (setf accum (mma-accumulate accum frag-a frag-b)))))))
```

### Matrix Multiply with pipelining

We use rings to set up a load/execute pipeline. 

```
(with-template-type (T)
  (def-type mat (matrix T :address-space :global :align :compact :contiguous-term :row-major))

  (def-grid-function pipeline-matrix-multiply (A B &out C)
    (declare #'((mat T) (mat T) (mat T))
               (global-size :derive-from C :strategy :strided)) 
    (let ((pipeline-stages 3)
          (A-tile-ring (make-scratch-matrix-ring A (128 128) :ring-count pipeline-stages))
          (B-tile-ring (make-scratch-matrix-ring B (128 128) :ring-count pipeline-stages))
          (C-tile (make-register-tile T (128 128) (identity T)))
          (barrier-ring (make-async-barrier-ring :ring-count pipeline-stages)))

      ;; Outer loops for C-tile (X and Y coordinates)
      (tile-stride C C-tile (grid-y grid-x) 
        
        ;; 1. PROLOGUE: Fill the pipeline for the current C-tile
        (do-times+ (i pipeline-stages)
          ;; Striding along K, keeping Y and X locked to the current block
          (load-tile A (ring-get A-tile-ring i) grid-y i :barrier (ring-get barrier-ring i)) 
          (load-tile B (ring-get B-tile-ring i) i grid-x :barrier (ring-get barrier-ring i)))

        ;; 2. MAIN K-LOOP
        (let ((ring-idx 0))
          (do-times (grid-k K)
            
            ;; Wait for the current stage's data to arrive in SLM
            (await (ring-get barrier-ring ring-idx)) 

            ;; Execute the math from SLM into registers
            (let ((A-tile (ring-get A-tile-ring ring-idx))
                  (B-tile (ring-get B-tile-ring ring-idx)))
              (mma-accumulate-via-tile (16 8) C-tile A-tile B-tile (my-accum)
                (accum-op)
                ;; Developer can immediately do epilogue fusion while still in registers
                (relu my-accum)
                (add-bias my-accum bias-tile))) ;; <-- fictional operation for illustrative purposes

            
            ;; Issue the fetch for the NEXT chunk of K, wrapping the ring buffer
            ;; We fetch (grid-k + pipeline-stages) to stay ahead of the compute
            (let ((next-k (+ grid-k pipeline-stages)))
              (when (< next-k K) ;; Don't fetch out of bounds at the end of the matrix
                (load-tile A (ring-get A-tile-ring ring-idx) grid-y next-k :barrier (ring-get barrier-ring ring-idx))
                (load-tile B (ring-get B-tile-ring ring-idx) next-k grid-x :barrier (ring-get barrier-ring ring-idx))))
            
            ;; Execution barrier to ensure all math is done before we overwrite SLM on the next wrap
            (sync-workgroup)
            
            ;; Advance the ring pointer (modulo pipeline-stages)
            (set! ring-idx (mod (+ ring-idx 1) pipeline-stages))))

        ;; 3. EPILOGUE: C-tile is complete. Store it.
        ;; we can also do Relu and friends on the C-Tile now.
        (store-tile C-Tile C (grid-y grid-x) :barrier barrier)))))
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
                (mma-accumulate-via-tile (16 8) C-tile A-tile B-tile (my-accum)
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

