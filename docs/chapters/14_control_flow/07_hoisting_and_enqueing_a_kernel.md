## Hoisting and Enqueing a Kernel


Crisp refers to the overall effort of getting a kernel read from disk, preparing the data, and actually enqueueing it as "hoisting". The Crisp compiler
can output hoisting example code for any kernel it compiles. That hoisting code is tailored to the kernel itself and the compilation targets,
which ensures that assumptions and dependencies are adhered to by both sides.

There are two important decisions that the host must make at the moment a kernel is enqueued. 
1. global work size - how many threads are spawned simultaneously for this kernels operation. 
2. local work size - how many threads are grouped together such that they can share fast local memory.
But note that in specifying these two values, you are also making a third very important decision:
3. number of workgroups.    The number of workgroups is simply the global work size divided by the local work size:
`num-groups = global-size / local-size`.  It is not uncommon to have kernels where the number of workgroups
cannot exceed the local work size. When this restriction is in place, certain algorithms become much simpler. 


Typically, the most performant choices that maximize GPU throughput use a "local_work_size" that is both
a power of two and a multiple of the GPU warp size (32 or 64).  So typically 64, 128, or 256.  And the global_work_size,
the actual number of threads that will be spawned, should be a multiple of that. 

Crisp has a number of `declare` directives that allow the host and the kernel to agree on what, or how, these values will be set. They tell the story of who expects what. These all go in the kernel's top level `declare` block.


### global-size / local-size
```
(global-size &key set-to VALS derive-from EXPR strategy:SYM tile-shape:(<extents>) dims:ulong msg:string)
(local-size &key set-to VALS derive-from EXPR strategy:SYM  tile-shape:(<extents>) dims:ulong msg:string)
```
These directives tells the hoisting code about how the kernel expects the global_work_size or local_work_size to be set.  
If both are used, then their arity must agree. And, the `work_dim` value the hoisting code sets will also match their arity.


The local_work_size is the number of threads grouped together in a single workgroup. This is number is usually best a power of two and multiple of the GPU warp size ( 32 or 64 ).
The global_work_size is the number of threads that the kernel will be enqueued upon. For maximum throughput, it is best to be a multiple of the local_work_size. 

A single directive CANNOT use both the `:set-to` and `:derive-from` keys.

These directives are optional but hightly encouraged as they serve to both document intent to future readers
of your kernel code, but also so the hoisting code is configuring things correctly for your kernel.

#### :msg
The `:msg` key takes a string that will be output into the comment at the place where the hoisting code is setting the particular value. 


#### :dims
The `:dims` key just takes the number `1` , `2` or `3` to express the required arity.  If using `:set-to` or `:derive-from` then
`:dims` is not usually needed.  But there will be times when a kernel doesn't have particular size requirements but DOES
have arity expectations.  Communicate them with `:dims`

If the `:dims` declaration does not match the arity of `:set-to` or `:derived-from`, or the arity differs between `global-size` and `local-size` then the compiler will error.

```
;; -- operate_2D --
(def-kernel operate_2D ()
   (declare (global-size :dims 2))
   ...)
```


#### :set-to
The `:set-to` key instructs the hoisting code to use a specific value, (or values if multi-dimensional).

```
; Crisp Code
;; -- fun --
(def-kernel fun ()
  (declare (local-size :set-to 256))
   ...)

;; -- do_something --
(def-kernel do_something ()
  (declare (global-size :set-to '(512 256)  :msg "please don't change"))
  (declare (local-size :set-to '(32 32)))
  ... )

// possibly resulting C++ enqueue in hoisting example
// note that the work_dim is 2, which matches the arity of :set-to
 clEnqueeuNDRangeKernel( someCommandQueue, doSomethingKernel, 
                          2             /* work_dim */,
                          0             /* global_work_offset */,
                          { 512, 256 }  /* global_work_size  please don't change */,
                          { 32, 32 }    /* local_work_size */,
                          ...);
```

#### :derive-from
The `:derive-from` key instructs the hoisting code that the kernel expects the size value to be in response to the named kernel parameter.  If the expression names a vector, then in response to its length. How "in response to" should be
intepreted is specified by the `:strategy` key (see below).  
It can take a single symbol (for a vector, implying its length) or a list of symbols (for scalar parameters representing dimensions).

```
;; Crisp Code

;; -- lighten_image --
(def-kernel lighten_image (image-data width height)
   (declare (type image-data (vector uchar :address-space :global))
            (type width height ulong)
            (global-size :derive-from '(width height) :strategy :one-thread-per :msg "ensure enough threads for every pixel of image, otherwise use the stepping convolution")) 
  ...)

// hoisting
 ...
 clSetKernelArg(lightenImageKernel, 1, sizeof(unsigned long), &imageWidth);
 clSetKernelArg(lightenImageKernel, 2, sizeof(unsigned long), &imageHeight);
 clEnqueeuNDRangeKernel( someCommandQueue, lightenImageKernel, 
                          2                            /* work_dim */,
                          0                            /* global_work_offset */,
                          { imageWidth, imageHeight }  /* global_work_size ensure enough threads for every pixel of image, otherwise use the stepping convolution */,
                          ...);
```

#### :strategy

The `:strategy` key is most useful when used in conjunction with `:derive-from` (above). 

With `:derive-from` we are telling the hoisting code, "take such-and-such vectors size into consideration when setting the
global work size".  And the `:strategy` tells it _how_ that should be done.

It can be one of five possible values.

- `:one-thread-per`  This strategy means we expect there to be at least one global thread for each element of the vector. See [One Thread Per Element](#one-thread-per-element) discussion below.

- `:strided` This strategy tells the hoisting code that we are expecting to use a grid stride pattern to walk
the vector. (Read more at [Looping -- Grid Stride](#looping---grid-stride)). In this case the hoisting code
will try to size the global work size near the number of threads actually available on the hardware (and not more).

- `:interleaved` This strategy tells the hoisting code that we are expecting this kernels launching to be interleaved
with a progressive chunked memory transfer. It's a good practice to document expectations further with the `:msg` key.
See [`launch-interleaved`](#launch-interleaved) for more information.

- `:exact` This strategy tells the hoisting code to set the global work size to be exactly the size, no more no less. This
strategy could also be used with the `:set-to` key.

- `:tiled`  This signals that the kernel ises a tiled algorithm (like `matmul` or `convert-layout` below).  The global
size isn't based on the total number of elements, but on the number of tiles needed to cover the input data.
The host code generator would calculate the grid dimensions based on the input matrix/tensor dimensions and the tile dimensions.
When using this strategy, be sure to also use the `:tile-shape` key so the hoisting code can calculate accordingly.



If the `:strategy` is not provided, then the default assumption is `:one-thread-per`. 


#### :tile-shape

`:tile-shape`  When  using the `:tiled` strategy you can provide the extents of the tile so the host can 
calculate accordingly.  

### num-groups
```
(declare (num-groups :max :local-size :msg "number of groups can't be bigger than a local work size"))
;OR
(declare (num-groups :max <someExpr> :msg "But here's my number, so call me maybe."))
```

As mentioned earlier, the number of workgroups for a kernel is simply the "global work size" divided by the "local work size". 
Thus the need to have any kernel specify it is redundant. Simply declaring `global-size` and `local-size` are sufficient.

But there are cases where kernels make assumptions about the number of workgroups. The most common one being that the 
number of workgroups cannot exceed the local work size. In that even simply `(declare (num-groups :max :local-size))`.
This will help document this restriction to anyone reading the kernel code, and the hoisting code that is 
generated will also abide by that restriction (and note it in the comments).

Alternately, some other expression can be provided. And, as with `local-size` and `global-size` and optional `:msg` 
can be used to inject a comment into the hoisting code.




### check-thread-bounds
By itself, the `global-size` expressions above doesn't result in any change to the 
the way the kernel compiles or runs. It is mostly for communicating intent to the host which 
will be hoisting the kernel. But it DOES interoperate with the `check-thread-bounds` predicate.

```
(check-thread-bounds i)
(check-thread-bounds x y)
(check-thread-bounds x y z)
```
`check-thread-bounds` returns T if the provided index value(s) is less than the value specified by the `global_work_size` when the kernel was enqueued. This makes it very useful for bounds checking, especially if the `global_work_size` 
has been "rounded up" to a multiple of the workgroup size by the host.

```
;; -- lighten_image --
(def-kernel lighten_image (image-data width height)
   (declare (type image-data (vector uchar :address-space :global))
            (type width height ulong)
            (global-size :derive-from ( width height) :strategy :one-thread-per)) ; <-- this sets the upper bound for check-thread-bounds 
  (let ((image-matrix (make-tensor image-data width height)))
    (in-each-thread (x y)
      (when (check-thread-bounds x y) 
        (inc! (~ matrix x y) 30)))))

```

### check-wg-bounds
Like `check-thread-bounds` but influenced by the `local_work_size` enqueue value and meant to be used on workgroup indeces.

### declaring local-size / global-size in sub functions.
The declarations of the local or global size preference is optional, though highly recommended. It can be done
in the scope of a `def-kernel` or in the scope of a `def-function`.  The compiler will look at the call chain for any kernel to see what values it should request in the hoisting code for global and local sizes.  
If there are competing declarations in the kernel and different sub functions then the compiler will emit a warning informing you. When there are conflicts the hoisting code will recommend that the GREATEST of the competing sizes
be used. 


### check-async-hazards

If present, the scope is checked to see if there is illegal access of memory between an async `(request-)` and the matching `(await-request )`
A compile error is emitted if forbidden access is detected.



