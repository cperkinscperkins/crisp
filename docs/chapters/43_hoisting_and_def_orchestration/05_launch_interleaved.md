## launch-interleaved

```
(launch-interleaved (hoist-vectors) (len offset) &rest launch-specification)
```

When the compiler encounters `launch-interleaved`, the hoisting code that is generated will enqueue
the kernels and data such that the memory copy and the kernel execution overlap. This helps hide latency
and is often the secret to maximizing performance and throughput.  

The kernel launched should have, in addition to one or more vector data arguments, a parameter that can
accept an "offset" into the vector and a paramter that accepts a "length". 

The hoist vectors that you want to be progressively interleaved with the kernel execution are passed in the
first argument list to `launch-interleaved`. 

Following that is the binding which binds the `len` and `offset` variable names.

And then the launch specifications.


Example:
```

;; -- vector_add_chunked --
(def-kernel vector_add_chunked (len offset A B &out C)
   ;; assume input-vec-t and output-vec-t already defined.
  (declare #(ulong ulong input-vec-t input-vec-t &out output-vec-t)
           (global-size :derive-from len :strategy :interleaved
                         :msg "this kernel processes data defined by offset/len"))
  (let ((A-view (make-vector A len offset))
        (B-view (make-vector B len offset))
        (C-view (make-vector C len offset)))
    (map-stride #'+ A-view B-view C-view)))

;; -- add-interleaved --
(def-orchestration add-interleaved
  (let ((VADD_CHUNKED (gen-vector_add_chunked))
        (A (make-hoist-vector VADD_CHUNKED::A))
        (B (make-hoist-vector VADD_CHUNKED::B))
        (C (make-hoist-vector VADD_CHUNKED::C)))
  (launch-interleaved (A B C) (len offset) 
    (VADD_CHUNKED len offset A B C))))
```
In the example above, Crisp will generate hoisting code that interleaves the memory copy  `A`, `B`, and `C` 
and the kernel execution.  It will demonstrate how to allocate some memory, pin it, 
and interatively copy it to the GPU device while executing the kernel concurrently.

Neat!




