## launch-interleaved ⚠️


`launch-interleaved` is for 1D interleaved operations on vectors. 

```
(launch-interleaved &rest launch-specification)
```

When the compiler encounters `launch-interleaved`, the hoisting code that is generated will enqueue
the kernels and data such that the memory copy and the kernel execution overlap. This helps hide latency
and is often the secret to maximizing performance and throughput.  

In the `def-orchestration` use `make-interleaved-vector` to define a vector subview onto larger data.  The subview vector will be updated for each enqueue to progress through the data.

`make-interleaved-vector` will allocate a larger data vector, but create a smaller view into that data.

If the original kernel vector type declaration declares `:compact-offset` as its alignment, then the subview merely has its offsets adjusted. But if the declaration is `:compact` then the underlying pointer
will be adjusted before each enqueue.  If you plan to adjust the hoisting code, it would probably
be best to use  `:compact-offset` as that's more flexible.

Example:
```

;; -- vector_add_chunked --
(def-kernel vector_add_chunked (A B &out C)
   ;; assume input-vec-t and output-vec-t already defined.
  (declare #(input-vec-t input-vec-t &out output-vec-t)
           (global-size :derive-from A :strategy :strided))
    (map-stride #'+ A B C))

;; -- add-interleaved --
(def-orchestration add-interleaved
  (let ((VADD_CHUNKED (gen-vector_add_chunked))
        (A-view (make-interleaved-vector VADD_CHUNKED::A))
        (B-view (make-interleaved-vector VADD_CHUNKED::B))
        (C-view (make-interleaved-vector VADD_CHUNKED::C)))
  (launch-interleaved  
    (VADD_CHUNKED len offset A-view B-view C-view))))
```
In the example above, Crisp will generate hoisting code that interleaves the memory copy  `A`, `B`, and `C` 
and the kernel execution.  It will demonstrate how to allocate some memory, pin it, 
and interatively copy it to the GPU device while executing the kernel concurrently.

Neat!




