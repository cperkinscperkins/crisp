## Storage Handle Arguments for Kernels

`def-kernel` is the definition for the kernel function. 
And any Storage Handle in its parameter list MUST have its element-type, number or dimensions, align, address-space and access specified in
its type definition. Only the size can be unspecified. (And for `cell`, `align` is not needed.)
The number of dimensions is (obviously) implicit for the `cell`, `vector` and `matrix` types.


```
(def-type data-from-host-t (vector-type float :std140 :global :read-only ))
(def-type result-from-kernel-t (vector-type float :std140 :global :write-only ))

;; -- my_kernel --
(def-kernel my_kernel (in:data-from-host-t &out out:result-from-kernel-t)
  ...)
```

