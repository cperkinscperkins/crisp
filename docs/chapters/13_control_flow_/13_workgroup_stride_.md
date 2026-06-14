# workgroup-stride ✅

```
(workgroup-stride <tile-tensor> (<bindings>) ...)
```
`workgroup-stride` is the primary workhorse for computations within a single workgroup. It is designed to walk the coordinates of a `:local` or `:private` tensor (a "tile") using the full parallel resources of the workgroup. 

<!--
#### The "One Coordinate" Binding
The `<bindings>` always represent the local coordinates within the `<tile-tensor>`. If you are striding a $16 \times 16$ tile, the bindings will range from $(0,0)$ to $(15,15)$. The macro ensures that:
- Coalesced Access: The contiguous dimension of the tile is automatically mapped to the fastest hardware dimension (the warp lane) to prevent bank conflicts.
- Cooperative Execution: If the tile is larger than the physical workgroup size, the macro handles the serial-parallel tiling required to visit every element.

```
Example: Simple cooperative increment
(let ((my-tile (make-scratch-matrix float (16 16) :local)))
  (tile-stride big-matrix my-tile (y x)
    (load-tile big-matrix my-tile)
    
    (workgroup-stride my-tile (ly lx)
       ;; ly and lx are always 0-15, mapped to workgroup hardware
       (inc! (~ my-tile ly lx) 1.0))
       
    (store-tile my-tile big-matrix)))
```
-->

#### Hardware Context Helpers ✅

Instead of "modes" or "tags" that change how the stride works, Crisp provides helper macros that can be used inside the body of a `workgroup-stride` to access hardware-level information. This allows you to write warp-aware logic without losing your place in the tensor's coordinate system.

#### Helper Description 
- `(warp-id)` Returns the index of the current warp within the workgroup.
- `(warp-lane)` Returns the index of the current thread within its warp (e.g., 0–31).
- `(warp-count)` Returns the total number of warps in the current workgroup. 

#### Example: Warp-Aware Logic
This pattern is useful for algorithms where only one "representative" thread per warp should perform a specific task, such as updating a shared counter or coordinating a sub-group shuffle.

```
(workgroup-stride my-tile (ly lx)
  ;; Every thread does the common work
  (set! (~ my-tile ly lx) (expensive-calculation ly lx))
  
  ;; Only the first lane in every warp handles logging or sync
  (when (== (warp-lane) 0)
    (atomic-inc! (some-shared-counter) 1)))
```

#### Implementation Notes

- Implicit Synchronization: To maintain maximum performance, `workgroup-stride` does not inject a `(local-barrier)` at the end of its block. If your logic requires all threads to finish a pass before moving to the next, call `(local-barrier)` explicitly.
- Arity Consistency: The number of `<bindings>` must match the arity of the `<tile-tensor>`.
- Scope: The bindings `(ly lx)` represent the position within the tile, while any bindings from an outer tile-stride (e.g., y x) remain available for calculating positions relative to the global problem space.


                     

#### `ceil-pow2` 📝

For certain operations, like warp reductions, it is imperative that certain activities
fit completely in a warp and are not "split" across warp divide. 

If the argument to `ceil-pow2` is a power of 2, it'll be returns. But if not, then the
next hightest power of 2 will be returned. This can be very handy in loops
or for making sure tile strides don't split work across the warp boundary. 

```
(ceil-pow2 4) => 4
(ceil-pow2 5) => 8
```



