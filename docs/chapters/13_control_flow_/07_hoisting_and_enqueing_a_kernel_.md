# Hoisting and Enqueing a Kernel ⚠️


Crisp refers to the overall effort of getting a kernel read from disk, preparing the data, and actually enqueueing it as "hoisting". The Crisp compiler
can output hoisting example code for any kernel it compiles. That hoisting code is tailored to the kernel itself and the compilation targets,
which ensures that assumptions and dependencies are adhered to by both sides.

There are two important decisions that the host must make at the moment a kernel is enqueued. 
1. global work size - how many threads are spawned simultaneously for this kernels operation. 
2. local work size - how many threads are grouped together such that they can share fast local memory.
But note that in specifying these two values, you are also making a third very important decision:
3. number of workgroups.    The number of workgroups is simply the global work size divided by the local work size:
`num-groups = global-size / local-size`.  It is not uncommon to have kernels where the number of workgroups
cannot exceed the local work size. When this restriction is in place, certain algorithms become much simpler. 


Typically, the most performant choices that maximize GPU throughput use a "local_work_size" that is both
a power of two and a multiple of the GPU warp size (32 or 64).  So typically 64, 128, or 256.  And the global_work_size,
the actual number of threads that will be spawned, should be a multiple of that. 

Crisp has a number of `declare` directives that allow the host and the kernel to agree on what, or how, these values will be set. They tell the story of who expects what. These all go in the kernel's top level `declare` block.


#### global-size / local-size ✅
```
(global-size &key set-to VALS derive-from EXPR strategy:SYM tile-shape:(<extents>) dims:ulong msg:string)
(local-size &key set-to VALS derive-from EXPR strategy:SYM  tile-shape:(<extents>) dims:ulong msg:string)
```
These directives tells the hoisting code about how the kernel expects the global_work_size or local_work_size to be set.  
If both are used, then their arity must agree. And, the `work_dim` value the hoisting code sets will also match their arity.


The local_work_size is the number of threads grouped together in a single workgroup. This is number is usually best a power of two and multiple of the GPU warp size ( 32 or 64 ).
The global_work_size is the number of threads that the kernel will be enqueued upon. For maximum throughput, it is best to be a multiple of the local_work_size. 

A single directive CANNOT use both the `:set-to` and `:derive-from` keys.

These directives are optional but hightly encouraged as they serve to both document intent to future readers
of your kernel code, but also so the hoisting code is configuring things correctly for your kernel.

##### :msg 📝
The `:msg` key takes a string that will be output into the comment at the place where the hoisting code is setting the particular value. 


##### :dims 📝
The `:dims` key just takes the number `1` , `2` or `3` to express the required arity.  If using `:set-to` or `:derive-from` then
`:dims` is not usually needed.  But there will be times when a kernel doesn't have particular size requirements but DOES
have arity expectations.  Communicate them with `:dims`

If the `:dims` declaration does not match the arity of `:set-to` or `:derived-from`, or the arity differs between `global-size` and `local-size` then the compiler will error.

```
;; -- operate_2D --
(def-kernel operate_2D ()
   (declare (global-size :dims 2))
   ...)
```


##### :set-to ✅
The `:set-to` key instructs the hoisting code to use a specific value, (or values if multi-dimensional).

```
; Crisp Code
;; -- fun --
(def-kernel fun ()
  (declare (local-size :set-to 256))
   ...)

;; -- do_something --
(def-kernel do_something ()
  (declare (global-size :set-to '(512 256)  :msg "please don't change"))
  (declare (local-size :set-to '(32 32)))
  ... )

// possibly resulting C++ enqueue in hoisting example
// note that the work_dim is 2, which matches the arity of :set-to
 clEnqueeuNDRangeKernel( someCommandQueue, doSomethingKernel, 
                          2             /* work_dim */,
                          0             /* global_work_offset */,
                          { 512, 256 }  /* global_work_size  please don't change */,
                          { 32, 32 }    /* local_work_size */,
                          ...);
```

##### :derive-from ✅
The `:derive-from` key instructs the hoisting code that the kernel expects the size value to be in response to the named kernel parameter.  If the expression names a vector, then in response to its length. How "in response to" should be
intepreted is specified by the `:strategy` key (see below).  
It can take a single symbol (for a vector, implying its length) or a list of symbols (for scalar parameters representing dimensions).

```
;; Crisp Code

;; -- lighten_image --
(def-kernel lighten_image (image-data width height)
   (declare (type image-data (vector uchar :address-space :global))
            (type width height ulong)
            (global-size :derive-from '(width height) :strategy :one-thread-per :msg "ensure enough threads for every pixel of image, otherwise use the stepping convolution")) 
  ...)

// hoisting
 ...
 clSetKernelArg(lightenImageKernel, 1, sizeof(unsigned long), &imageWidth);
 clSetKernelArg(lightenImageKernel, 2, sizeof(unsigned long), &imageHeight);
 clEnqueeuNDRangeKernel( someCommandQueue, lightenImageKernel, 
                          2                            /* work_dim */,
                          0                            /* global_work_offset */,
                          { imageWidth, imageHeight }  /* global_work_size ensure enough threads for every pixel of image, otherwise use the stepping convolution */,
                          ...);
```

##### :strategy ✅

The `:strategy` key is most useful when used in conjunction with `:derive-from` (above). 

With `:derive-from` we are telling the hoisting code, "take such-and-such vectors size into consideration when setting the
global work size".  And the `:strategy` tells it _how_ that should be done.

It can be one of four possible values.

- `:one-thread-per`  This strategy means we expect there to be at least one global thread for each element of the vector. See [One Thread Per Element](#one-thread-per-element) discussion below.

- `:strided` This strategy tells the hoisting code that we are expecting to use a grid stride pattern to walk
the vector. (Read more at [Looping -- Grid Stride](#looping---grid-stride)). **Without** a `:tile-shape` the
global work size defaults to filling the machine once — one grid's worth of resident workgroups.
**With** a `:tile-shape` the grid instead covers the tile grid exactly — see [:tile-shape](#tile-shape) below,
which governs grid *shape* for every strategy.

**"Fill the machine once" is a starting point, not a target.** It is a reasonable default precisely
because it needs no measurement, but it is not what "fastest" means and Crisp does not claim it is.
Measured, the best grid for a kernel has landed *both* below and above it: kernels ending in a global
atomic do more atomic traffic as the group count rises, while latency-bound kernels often keep improving
past full occupancy. On Intel BMG a reduction was fastest at **2× oversubscribed**, and degraded on either
side of that. Use [`:occupancy`](#occupancy) to say where your kernel actually wants to sit — it scales
this default in either direction, and it carries the numbers.

- `:exact` This strategy tells the hoisting code to set the global work size to be exactly the size, no more no less. This
strategy could also be used with the `:set-to` key. If combined with `:tile-shape`, `:exact` calculates exactly enough workgroups to cover the number of tiles.

- `:interleaved` Accepted by the parser but **not yet implemented** — it currently falls back to the
default dispatch of a single workgroup. Do not rely on it.

If the `:strategy` is not provided, then the default assumption is `:one-thread-per`.


##### :tile-shape ✅

```
(declare (global-size :derive-from (width height) :strategy :strided :tile-shape (64 64)))
;; or derived from an output tensor, which supplies its own per-dimension extents:
(declare (global-size :derive-from C :strategy :strided :tile-shape (32 32)))
```

The `:tile-shape` key defines the geometric extents of the work processed by a single workgroup.

**`:tile-shape` determines the RANK and SHAPE of the dispatch grid; `:strategy` only determines
sizing policy along it.** When a `:tile-shape` is present, the launch is rank-N with

```
group_count[k] = CEIL(extent[k] / tile_shape[k])
```

— **dispatch axis `k` is drawn from dimension `k` of the `:derive-from` source.** A tensor
`:derive-from` supplies `extent[k]` per dimension; a scalar list supplies its k'th parameter.
Axes beyond the tile-shape's rank are 1.

This holds for **both** `:exact` and `:strided`: given the same `:tile-shape` and the same extents,
they compute the *same* grid. What still separates them is whether the kernel **loops** — `:strided`
has a `tile-stride` loop, `:exact` does not — and that is not a documentation nicety. It decides what
the host is permitted to do when the computed grid will not fit the device (see
[Device dispatch limits](#device-dispatch-limits--where-strided-and-exact-genuinely-differ) below).
So: same formula, different licence.

This declaration should always be used when utilizing the `tile-stride` or `matrix-multiply-tile-stride`
macros so the host orchestrator understands the block partitioning. **Omitting it on an N-dimensional
`tile-stride` kernel is a performance trap, not merely a missing hint** — see below.

###### Why `:strided` covers the tile grid rather than max occupancy

Earlier, `:strided` ignored `:tile-shape` and always emitted a *one-dimensional*, occupancy-sized grid.
Under an N-dimensional `tile-stride` loop a 1-D grid does not simply under-dispatch: the axes with
extent 1 are **serialized inside each workgroup**. Results stay correct — the stride loop still covers
every tile — so the only symptom is lost throughput, which is why it went unnoticed for a long time.

Measured on Intel BMG (Arc B580, 640 hardware threads), `matmul_bmg_prefetch`, tf32, TFLOPS:

| size | tile grid | 1-D occupancy grid | occupancy-clamped 2-D | **exact tile cover** |
|---|---|---:|---:|---:|
| 1024³ | 32×32 | 1.40 | 8.10 `(32,20)` | **10.52** `(32,32)` |
| 2048³ | 64×64 | 1.40 | 6.26 `(64,10)` | **8.64** `(64,64)` |
| 4096³ | 128×128 | 1.37 | 4.26 `(128,5)` | **7.46** `(128,128)` |

At 4096 the exact grid is 16384 workgroups — 25× oversubscribed against the occupancy budget of 640 —
and it still wins by 75%. The margin *widens* with size, so there is no crossover at which clamping
starts to pay (up to 4096, the largest measured). **For tiled kernels, "cover the tile grid" beats
"fill the machine."** `:occupancy` remains available if you measure a case that wants fewer groups.

The axis mapping was likewise measured, on a non-square 512×2048 problem (16 row-tiles × 64 col-tiles):
`(16,64)` gave 12.28 TFLOPS versus `(64,16)` at 9.41. So axis 0 tracks dimension 0 (rows) — the
opposite of the CUDA `x = columns` convention. Both orderings compute correct results; getting it
backwards costs ~1.3× and nothing else. Do not "correct" it without re-measuring.

###### Device dispatch limits — where `:strided` and `:exact` genuinely differ

A tile grid scales with the **problem**, not the hardware, so unlike an occupancy-sized grid it can
in principle exceed what the device will accept (`maxGroupCountX/Y/Z` from
`zeDeviceGetComputeProperties`). The two strategies must handle that differently, and the
difference is one of correctness rather than taste:

- **`:strided`** has a `tile-stride` loop that covers any tile the grid does not reach, so the host
  **clamps** the grid to the device limit and notes it. The cost is throughput, not correctness.
- **`:exact`** launches one workgroup per tile with no loop, so a clamped grid would **silently skip
  tiles**. Exceeding the limit is therefore a hard **error** directing you to `:strided`.

This is the one place the two strategies diverge once a `:tile-shape` is present, and it is the
reason to keep them distinct rather than collapsing them into one key.

For scale: Intel BMG (Arc B580) reports `maxGroupCountX/Y/Z` of `UINT32_MAX`, so a 32×32-tile cover
would not reach the limit until roughly N = 1.4 × 10¹¹. The guard is effectively inert on that part
today — it exists because the bound became *reachable in principle* the moment grid size started
tracking the problem, and because the strided/exact split above must never be silent.


##### `:occupancy` ✅

The `:occupancy` key is a **grid-size multiplier** for the `:strided` strategy.
Accepts any number greater than `0.0` (default `1.0`). **Values above `1.0` are legal and
useful** — see [oversubscription](#oversubscription-values-above-10) below.

**The denominator, stated exactly.** `:occupancy` is a ratio against the **maximum number of
workgroups of this kernel that the device can hold resident simultaneously**:

```
group_count = :occupancy × max_resident_workgroups
```

- **CUDA** — `cuOccupancyMaxActiveBlocksPerMultiprocessor(kernel, block_size, smem) × SM count`.
  A real per-kernel query, so register and shared-memory pressure are accounted for.
- **Level Zero** — `numSlices × numSubslicesPerSlice × numEUsPerSubslice × numThreadsPerEU`,
  divided by the hardware threads one workgroup occupies
  (`ceil(local_size / physicalEUSimdWidth)`), then halved if `zeKernelGetProperties` reports
  register spill. Level Zero has no single per-kernel occupancy query, so this approximates one.

It is worth being precise about this because the denominator is the whole meaning of the number:
"0.5" says nothing without "of what?". An earlier version of two hand-written benchmark harnesses
used *EU count* instead, which is a different quantity — on Intel BMG the two answers differed by
exactly 2×, so the same declaration meant two different grids depending on who read it.

`:occupancy` scales only the **occupancy-sized** grid, i.e. `:strided` **without** a
`:tile-shape`. When a `:tile-shape` is present the grid is the tile grid and `:occupancy` does not
apply — see [:tile-shape](#tile-shape).

> **Note on the Level Zero call.** This used to say `zeDeviceGetComputeProperties`. That is a
> different query and cannot do this job: `ze_device_compute_properties_t` returns *dispatch
> limits* (`maxTotalGroupSize`, `maxGroupSizeX/Y/Z`, `maxGroupCountX/Y/Z`, `maxSharedLocalMemory`,
> `subGroupSizes`) and contains nothing about how many threads the device has. Machine capacity —
> `numSlices × numSubslicesPerSlice × numEUsPerSubslice × numThreadsPerEU`, each thread
> `physicalEUSimdWidth` wide — comes from `zeDeviceGetProperties`. Unlike CUDA, Level Zero has no
> single per-kernel occupancy query; Crisp approximates one by derating that capacity when
> `zeKernelGetProperties` reports register spill.

Maximum theoretical occupancy is necessary but not
sufficient for peak performance. Real workloads compete for shared resources
that don't scale with thread count:

- L2 cache pressure -  more concurrent workgroups thrash the L2.
- LSU queue depth -  finite per-SM load/store queues saturate.
- Atomic serialization - kernels ending in `atomic-add!` to global memory
  serialize at the atomic site. More workgroups = more atomic ops queued.
- Per-block fixed overhead amortization - shared-memory setup and
  barriers cost the same regardless of how much work each thread does.

Those pressures are real, but whether they add up to "use a smaller grid" is a question about a
specific kernel on specific hardware, and it must be measured. **Do not reach for a low `:occupancy`
on the theory above.**

**Measured — Intel BMG (Arc B580), `benchmarks/reduction` `sum_reduce`, median kernel µs:**

| `:occupancy` | groups | N = 1M | N = 16M |
|---|---:|---:|---:|
| 0.05 | 8 | 65.83 | 2737.07 |
| 0.15 | 24 | 29.22 | 941.30 |
| 0.50 | 80 | 11.54 | 306.07 |
| **1.00** | **160** | **8.84** | **191.46** |

Monotonic: more groups is better at every step, and the advantage *widens* with N — 7.4× at 1M and
14.3× at 16M between the lowest and highest setting. This is a reduction that ends in a global atomic,
i.e. precisely the pattern the theory says should prefer a small grid, and on this hardware it does
the opposite. The curve has not flattened at `1.0` either, which suggests the optimum lies beyond the
largest grid the ratio can express.

**Measured — NVIDIA H100 PCIe (114 SMs), the same kernel, median kernel µs:**

| `:occupancy` | blocks | N = 1M | N = 16M | N = 64M |
|---|---:|---:|---:|---:|
| 0.05 | 34 | 21.60 | 311.46 | 1204.29 |
| 0.15 | 102 | 15.36 | 116.32 | 427.33 |
| 0.50 | 342 | 14.46 | 52.90 | 170.30 |
| 0.75 | 513 | **13.92** | **48.13** | 152.10 |
| 1.00 | 684 | 14.72 | 48.13 | **146.94** |

**Both vendors agree: derating is a pessimization here.** A `0.15` derate costs 2.4× at 16M and
2.9× at 64M on H100, and 3.3–4.9× on BMG. The often-repeated "≈0.2 for reductions" figure does not
survive measurement on either vendor — including NVIDIA, where it originated.

###### Oversubscription: values above 1.0

`1.0` means "exactly fill the machine once". That is a natural *default*, but it is **not** the
optimum, and it is worth knowing that you can ask for more — many readers will not realise the
possibility, since a ratio reads like something that ought to be capped at one whole machine.

Re-running the Intel BMG reduction with the cap removed (`local-size 256`, so
`max_resident_workgroups` = 80):

| `:occupancy` | groups | N = 1M | N = 16M |
|---|---:|---:|---:|
| 0.50 | 40 | 17.26 | 589.58 |
| 1.00 | 80 | 11.54 | 307.01 |
| **2.00** | **160** | **8.84** | **192.50** |
| 4.00 | 320 | 11.96 | 238.26 |
| 8.00 | 640 | 15.39 | 211.22 |
| 16.00 | 1280 | 22.98 | 213.20 |

**The optimum is 2× oversubscribed** — 1.3× faster than filling the machine at 1M, 1.6× at 16M —
and it degrades again beyond that. So this is a genuine interior optimum, not "more is always
better": you cannot reach it by clamping, and you cannot reach it by removing the knob.

That is the case for keeping `:occupancy`. It expresses something the compiler cannot infer — how
far past resident capacity *this* kernel's latency-hiding keeps paying — and the answer is neither
the default nor unbounded. `benchmarks/reduction`'s `sum_reduce` therefore declares
`:occupancy 2.0`, and its performance ratchet mirrors it.

Two caveats worth carrying: the optimum is per-kernel and per-device, so 2.0 is *this* kernel's
answer on *this* GPU, not a new rule of thumb; and oversubscription is only safe because
`:strided` kernels loop — a grid larger than the problem is covered by the stride loop.

The atomic-pressure effect is real but small: on H100 the curve turns over slightly at small N
(`0.75` beats `1.00` by ~5% at 1M, they tie at 16M, and `1.00` wins at 64M). That is worth a knob,
not a recommendation — which is exactly what `:occupancy` now is. Reach for it when you have a
measurement, not on theory. Bandwidth-bound kernels without atomics benefit from `1.0`.

> Because both vendors want the same value, a single scalar in kernel source is sufficient today —
> there is no need for per-target occupancy values or a `def-hardware-profile` default. If a future
> kernel is ever found where the two vendors genuinely disagree, that is the point at which this
> key needs to grow, and not before.

Note that `:occupancy` derates the *occupancy-sized* `:strided` grid — the one used when no
`:tile-shape` is given. It is not applied as a clamp on a tile-grid dispatch, because measurement
showed clamping a tiled launch below its tile count to be a pessimization at every size tested
(see [:tile-shape](#tile-shape)). Tiled kernels that genuinely want fewer groups should say so
with an explicit `:set-to`.

Remember, these declarations influence any hoisting code that Crisp outputs (`--hoist=L0` or `--hoist=CUDA`), the kernel itself is NOT effected in any way. **`cluster-size` is the one exception** — it is consumed at code generation time and changes what the kernel compiles to. See its own section below for why. 

```
;; -- sum_reduce_tree --
;; NOTE: the 0.5 here is illustrative SYNTAX, not a recommendation.  On BMG this kernel
;; is fastest at the 1.0 default (see the table above); a derate should follow a
;; measurement on your hardware, not this example.
(def-kernel sum_reduce_tree (input &out result)
  (declare #'(in-vec &out out-cell => nil))
  (declare (global-size :derive-from input :strategy :strided :occupancy 0.5)
           (local-size  :set-to 256))
  ...)
```


#### num-groups 📝
```
(declare (num-groups :max :local-size :msg "number of groups can't be bigger than a local work size"))
;OR
(declare (num-groups :max <someExpr> :msg "But here's my number, so call me maybe."))
```

As mentioned earlier, the number of workgroups for a kernel is simply the "global work size" divided by the "local work size". 
Thus the need to have any kernel specify it is redundant. Simply declaring `global-size` and `local-size` are sufficient.

But there are cases where kernels make assumptions about the number of workgroups. The most common one being that the 
number of workgroups cannot exceed the local work size. In that even simply `(declare (num-groups :max :local-size))`.
This will help document this restriction to anyone reading the kernel code, and the hoisting code that is 
generated will also abide by that restriction (and note it in the comments).

Alternately, some other expression can be provided. And, as with `local-size` and `global-size` and optional `:msg` 
can be used to inject a comment into the hoisting code.


#### cluster-size 📝
```
(cluster-size &key set-to msg)
```

On NVIDIA Hopper (`sm_90`) and later, workgroups can be grouped into **clusters** — sets of
workgroups guaranteed to be co-resident, able to address one another's local memory and share a
barrier. `(cluster-size :set-to (2 1))` declares two workgroups per cluster, stacked along axis 0.

Note the unit: `cluster-size` counts **workgroups**, where `global-size` and `local-size` count
threads.

Unlike every other declaration in this section, **`cluster-size` changes the compiled kernel**, not
just the hoisting code — it governs whether tile loads are multicast across the cluster and what
synchronization the compiler must emit. It is documented with the rest of the cluster material in
`topology.md`.


#### cluster-size 📝

```
(cluster-size &key set-to msg)
```

```lisp
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

##### Why you would declare one

Two capabilities become available to a kernel once its workgroups are clustered:

1. **Distributed Shared Memory (DSMEM)** — a workgroup can read and write the `:local`
   memory of its cluster peers, and `sync-cluster` becomes meaningful across more than
   one workgroup.
2. **Multicast tile loads** — when several workgroups in a cluster need the *same* tile,
   the hardware can fetch it from global memory once and deliver it into every one of
   their local memories simultaneously. For a tiled matrix multiply this cuts the global
   traffic for the shared operand by the cluster's extent along the axis that operand
   does not depend on.

The second is the reason `cluster-size` exists at all today. See
[load-tile](#load-tile) for how the multicast is deduced — the kernel body does not
change, and there is no mask for you to write.

##### Axes follow `:tile-shape`

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

The rank of `cluster-size` must agree with the rank of `:tile-shape`, exactly as
`global-size` and `local-size` must agree in arity with each other. Axes beyond the
declared rank are 1. A scalar is shorthand for a rank-1 value, following
`(local-size :set-to 256)`.

`cluster-size` is permitted on a kernel with no `:tile-shape`, but there is then no tile
grid for the compiler to reason about and no multicast will be deduced. The declaration
still enables DSMEM and a cluster-wide `sync-cluster`, which may be all you want.

##### This declaration DOES affect the compiled kernel

Every other declaration in this family is advisory: it shapes the hoisting code Crisp
generates and leaves the kernel itself untouched. **`cluster-size` is not advisory.** It
determines:

- whether a `load-tile` lowers to a multicast at all
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

##### Limits and divisibility

**Cluster extent.** The portable maximum is 8 workgroups per cluster. Larger clusters are
supported on some parts (16 on Hopper) but require an explicit opt-in and are not portable
across devices; Crisp treats anything above 8 as requiring that opt-in.

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

> **Open decision.** The padding policy above is proposed, not settled. It follows the
> precedent set by the device-dispatch-limit rules, but it has not been measured, and
> "pad the grid" is not the only defensible answer for `:strided`.

##### Degradation

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

##### Interaction with other declarations

- **`:tile-shape`** — supplies the axis vocabulary and the grid whose divisibility is
  constrained. Required for multicast to be deduced.
- **`:occupancy`** — does not apply. `:occupancy` scales the occupancy-sized `:strided`
  grid, which is only used when no `:tile-shape` is present; a cluster without a tile
  shape performs no multicast.
- **`local-size`** — independent. Cluster extent counts workgroups; `local-size` sizes
  each one.
- **`num-groups`** — a `:max` constraint must still be satisfied after the grid is padded
  to a cluster multiple.

##### Example

```lisp
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

##### `:msg`

As with `global-size` and `local-size`, `:msg` takes a string that is emitted as a comment
at the point where the hoisting code configures the cluster dimensions.



#### check-thread-bounds 📝
By itself, the `global-size` expressions above doesn't result in any change to the 
the way the kernel compiles or runs. It is mostly for communicating intent to the host which 
will be hoisting the kernel. But it DOES interoperate with the `check-thread-bounds` predicate.

```
(check-thread-bounds i)
(check-thread-bounds x y)
(check-thread-bounds x y z)
```
`check-thread-bounds` returns T if the provided index value(s) is less than the value specified by the `global_work_size` when the kernel was enqueued. This makes it very useful for bounds checking, especially if the `global_work_size` 
has been "rounded up" to a multiple of the workgroup size by the host.

```
;; -- lighten_image --
(def-kernel lighten_image (image-data width height)
   (declare (type image-data (vector uchar :address-space :global))
            (type width height ulong)
            (global-size :derive-from ( width height) :strategy :one-thread-per)) ; <-- this sets the upper bound for check-thread-bounds 
  (let ((image-matrix (make-tensor image-data width height)))
    (in-each-thread (x y)
      (when (check-thread-bounds x y) 
        (inc! (~ matrix x y) 30)))))

```

#### check-wg-bounds 📝
Like `check-thread-bounds` but influenced by the `local_work_size` enqueue value and meant to be used on workgroup indeces.

#### declaring local-size / global-size in sub functions.
The declarations of the local or global size preference is optional, though highly recommended. It can be done
in the scope of a `def-kernel` or in the scope of a `def-function`.  The compiler will look at the call chain for any kernel to see what values it should request in the hoisting code for global and local sizes.  
If there are competing declarations in the kernel and different sub functions then the compiler will emit a warning informing you. When there are conflicts the hoisting code will recommend that the GREATEST of the competing sizes
be used. 


#### check-async-hazards 📝

If present, the scope is checked to see if there is illegal access of memory between an async `(request-)` and the matching `(await-request )`
A compile error is emitted if forbidden access is detected.



