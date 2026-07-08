# Async Memory Operations 📝


Crisp supports hardware-accelerated asynchronous memory copies (DMA). These operations allow the GPU
to fetch data in the background while the Execution Units (EUs) continue processing other instructions.

These operations are non-blocking. They return a `request-token`. You MUST eventually wait on this
token using `await-request` before accessing the destination memory.

#### `load-local` with `:barrier`
`(load-local global-vec local-vec &key identity barrier)`

Initiates an asynchronous copy from global memory to local memory.

IMPORTANT: accessing `global-vec` or `local-vec` before the request completes will result in BAD THINGS.  
In C++ lingo this is called "Undefined Behavior". In other languages it is referred to as "C++-like behavior".

The `check-async-hazards` static analysis can be elected to have the compiler check for you.


#### `await-request`
`(await-request token | list-of-tokens)`

Blocks execution until the specified memory request(s) are complete. This compiles to a hardware-specific
wait instruction (e.g., `wait_group_events` or `cp.async.wait_group`).

#### Safety
If you enable `(declare (check-async-hazards))`, the compiler will track the status of your local
memory buffers. It will emit an error if you attempt to read from `local-vec` between the `request-`
and the `await-`.


#### `request-store-global` 
```
(request-store-global local-scratch-vec global-vec) => request-token
```

Storage back to global memory does NOT yet have wide architecture support.  Crisp has these routines, but be aware that
the hardware choices that actually support this are limited. Your kernel may fail to compile or execute correctly on non-supporting hardware.

#### Tile Support : `request-load-tile-at` / `request-store-tile-coords` ✅

```
(request-load-tile-at source-tensor dest-tile (... tensor-row-y tensor-col-x) &key (identity 0) transpose) => request token

(request-store-tile-coords source-tile dest-tensor  (... tensor-row-y tensor-col-x) &key transpose) => request token
```
There are async variants for the tile scratch helpers as well.

-->


