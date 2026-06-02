# Storage Handle Arguments for Kernels ⚠️

`def-kernel` is the definition for the kernel function. 
And any Storage Handle in its parameter list MUST have its element-type, number or dimensions, align, and address-space specified in
its type definition. Only the size can be unspecified. (And for `cell`, `align` is not needed.)
The number of dimensions is (obviously) implicit for the `cell`, `vector` and `matrix` types.


```
(def-type data-from-host-t (vector float :align :compact :address-space :global))
(def-type result-from-kernel-t (vector float :align :compact :address-space :global))

;; -- my_kernel --
(def-kernel my_kernel (in &out out)
  (declare #'(data-from-host-t &out result-from-kernel-t))
  ...)
```

