# when-thread-is / abs-when-thread-is 📝


The `single-task` declaration above is a convenience, but it signals its limitation to the compiler
for the entire kernel. Oftentimes you will have kernels that are employing some parallel strategy 
(like Grid Stride, see below) but perhaps before embarking on that you might need a small bit of
initialization done by just one thread before or after the big show. Like preparing ballots for a shuffle,
or gathering up the last results of a big reduction. For this purpose `when-thread-is` can be used.
It simply surrounds its work with an implicit `(when (= someId (- (get-global-id 0) (get-global-offset ))) ...)` block.

`when-thread-is` uses a _relative_  thread id. Meaning, no matter what `global_offset` might have been used when enqueeuing
the kernel, the range of thread ids always starts at 0 and goes up to the `global_work_size` .  This means that if your kernel
is launched concurrently in two different thread groups that it can safely and consistently use `when-thread-is`  (especially `(when-thread-is 0 ...)` which is the most common usage).

This differs from OpenCL `get_global_id` which returns an absolute thread id (and is the source of many bugs and confusion).
`abs-when-thread-is` uses the absolute thread id and has the same interface as `when-thread-is`

```
(when-thread-is id <expr>)
;; when a multi-dimensional NDRange is used to enqueue the kernel, use these
(when-thread-is x-id y-id  <expr>)        
(when-thread-is x-id y-id z-id <expr>)   
```

Example:
```
(def-kernel k (#| some args |#)
  ;; first prepare
  (when-thread-is 0
    (let  ... ))

  ;; now do parallel grid stride
  (loop-vector-stride vec (i) 
    ...))
```

