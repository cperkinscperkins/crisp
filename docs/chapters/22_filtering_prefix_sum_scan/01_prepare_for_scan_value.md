# `prepare-for-scan--value` 📝


```
(prepare-for-scan--value input-vec predicateF (<localScratchVar>) ...)
```

This is a macro that does most of the busy-work for you in preparation of using either `exclusive-scan-workgroup`
or `inclusive-scan-workgroup` .  It iterates over input data, applies a predicate and stores the result (1 or 0)
into a local memory buffer, which is then bound for you are ready for the scan operation.

This macro is meant to be called at the workgroup level ("shop local").

If the element type of `input-vec` is `T` then `predicateF` type is `#(T => bool)` 
The predicateF operation is called with THE VALUE at `(~ input-vec global-id)`

See an example of using it in `filter` and `find-indices` below.

