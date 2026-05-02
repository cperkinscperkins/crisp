## Async Memory Operations


Crisp supports hardware-accelerated asynchronous memory copies (DMA). These operations allow the GPU
to fetch data in the background while the Execution Units (EUs) continue processing other instructions.

These operations are non-blocking. They return a `request-token`. You MUST eventually wait on this
token using `await-request` before accessing the destination memory.

### `request-load-local`
`(request-load-local global-vec local-vec &optional identity) => request-token`

Initiates a copy from global memory to local memory. Returns a token representing the inflight operation.

IMPORTANT: accessing `global-vec` or `local-vec` before the request completes will result in BAD THINGS.  
In C++ lingo this is called "Undefined Behavior". In other languages it is referred to as "C++-like behavior".

The `check-async-hazards` static analysis can be elected to have the compiler check for you.

### `request-load-tile`
```
(request-load-tile ...) => request-token
```
There are async variants for the tile scratch helpers as well.



### `await-request`
`(await-request token | list-of-tokens)`

Blocks execution until the specified memory request(s) are complete. This compiles to a hardware-specific
wait instruction (e.g., `wait_group_events` or `cp.async.wait_group`).

### Safety
If you enable `(declare (check-async-hazards))`, the compiler will track the status of your local
memory buffers. It will emit an error if you attempt to read from `local-vec` between the `request-`
and the `await-`.


### `request-store-global`  / `request-store-tile` 
```
(request-store-global local-scratch-vec global-vec) => request-token
(request-store-tile ...) => request-token
```

Storage back to global memory does NOT yet have wide architecture support.  Crisp has these routines, but be aware that
the hardware choices that actually support this are limited. Your kernel may fail to compile or execute correctly on non-supporting hardware.




