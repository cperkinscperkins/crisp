## One Thread Per Element


When the host enqueue's a kernel it will set up the global work size, which means the host is deciding how
many threads will run your kernel.  One common strategy for simpler (and faster) kernels is to simply 
have the kernels work execute exactly once per thread. No other looping is required.  

For example, if we have a vector of 1024 items that need some work done on them, we schedule
that same number of threads: 1024. Each thread works on just one element of the vector.

This strategy is simple and flexible. While it can scale to any desired size, it 
performs suboptimally for very big kernels or very large thread work sizes. 
If a One Thread Per Element strategy works for your workload, then almost certainly
a Grid Stride will also work (see below) and that will be more performant for larger 
sized vectors. And most performant of all would be to leverage Data Interleaving (see below), 
though that requires considerably more effort to orchestrate host side.  

### in-each-thread 

`in-each-thread` is a simple macro for binding thread index values over a body of statements. 
It is useful in lots of different kernels following different strategies. 
It is quite handy when using the  "one thread per element" work strategy. 

There are three variants for 1D, 2D and 3D .
```
(in-each-thread (x) ...)       ; 1D   x is bound to the x thread index / global-id 0
(in-each-thread (x y) ...)     ; 2D   x and y bound to the global-id 0 and 1 
(in-each-thread (x y z) ...)   ; 3D  
```



```
;; 1D Vector Add
(def-type source-vec (vector float :address-space :global :access :readable))     
(def-type result-vec (vector float :address-space :global :access :write-only))    

;; -- vector_add --
(def-kernel vector_add (A B &out C)
  (declare (type A B source-vec) (type C result-vec) 
           (global-size :derive-from A :strategy :exact :msg "no bounds checking. global_work_size MUST match vector lengths exactly" ))
  (in-each-thread (i)                        ; 'i' will be bound to the thread index / global-id
    (set! (~ C i) ( + (~ A i) (~ B i)))))


;; 2D Lighten Image

;; -- lighten_image --
(def-kernel lighten_image (image-data width height)
   (declare (type image-data (vector uchar :address-space :global :access :read-write))
            (type width height ulong)
            (global-size :derive-from '(width height) :strategy :one-thread-per)) 
  (let ((image-matrix (make-tensor image-data width height)))
    (in-each-thread (x y)
      (when (check-thread-bounds x y) 
        (inc! (~ matrix x y) 30)))))
```


### in-each-thread-in-group

`in-each-thread-in-group` is a simple macro for binding thread index values over a body of statements. 
It is useful when you want every thread in a workgroup to follow a sequence of steps. 

There are three variants for 1D, 2D and 3D .
```
(in-each-thread-in-group (x) ...)       ; 1D   x is bound to the x thread index / local-id 0
(in-each-thread-in-group (x y) ...)     ; 2D   x and y bound to the local-id 0 and 1 
(in-each-thread-in-group (x y z) ...)   ; 3D  
```

### in-each-group

`in-each-group` is another binding, but it binds to the WORKGROUP index. 

```
(in-each-group (x) ...)       ; 1D   x is bound to the index of the GROUP (get-workgroup-id)
(in-each-group (x y) ...)     ; 2D   x and y bound to the wg-id 0 and 1 
(in-each-group (x y z) ...)   ; 3D  
```


### Size Matters

In the first example above, we used 1024 as the vector size and the matching thread count. That's convenient
for an example because that number is a multiple of 32 and 64, the most common warp sizes. 

When hoisting a kernel the most performant choices that maximize GPU throughput use a "local_work_size" that is both
a power of two and a multiple of the GPU warp size (32 or 64).  So typically 64, 128, or 256.  And the global work size,
the actual number of threads that will be spawned, should be a multiple of that.

But what to do if the size of your problem is NOT an even multiple of one of these nice choices?  In this case, the kernel 
should definitely use `check-thread-bounds` and the host code that hoists it should round up whatever thread count they are 
requesting to the next muliple of a nice local_work_size.



