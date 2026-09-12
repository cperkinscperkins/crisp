# Looping - Grid Stride ✅


The One Thread Per Element strategy is simple and it can scale to any size. But if the number of threads
needed is greater than the maximum number on your GPU, then the driver will have to juggle and reload 
kernels and workgroups until the problem space is complete. This can be suboptimal for performance. 
In many of these cases, we can simply launch of bunch of threads and have them each loop internally a bit.
This could mean there would be no juggling or reloading required. 
Each thread would have to perform their work N times without overlapping. 
Where N = Size-of-Problem / Number-of-Threads-Launched.  

A grid-stride loop is a common pattern for processing large datasets that are bigger than the number of threads launched. It ensures that each thread processes multiple data elements while maintaining full occupancy and avoiding divergence.

The Crisp stride primitives are designed to encourage coalesced memory access patterns by default, helping the
programmer achieve maximum performance.

#### IMPORTANT - NO NESTING

Both `loop-vector-stride` and  `tensor-stride` operations are "grid level" operations. That is discussed below. Essentially,
grid level operations cannot nest inside one another. The compiler will error if you attempt to do so.

Also the body of those two `-stride` operations cannot call other "grid level" operations like the variants
on `reduce-`, `filter-` and others. You are welcome to use multiple grid level operations, they just
cannot be nested.  

But a grid-level stride CAN call `workgroup-stride`, which has a "workgroup level" context.  

#### `loop-vector-stride` ✅

 `loop-vector-stride` iterates over a vector  using the Grid Stride strategy. 
This macro is simple, clear and less error prone than trying to roll your own.
The bound value (`x`) is never out-of-bounds of the vector. 

```
(loop-vector-stride vec (x) ...)       ; 1D   x is some element index in the vector. 
```
In the example below, `vector_add` becomes trivial. But also note that no matter how big the vector,
so long as the hoisting code sets the `global_work_size` to be close to the actual number of hardware
threads available, that this `vector_add` will be much faster than the "One Thread Per" strategy when
the number of elements in the vector is larger than the number of available hardware threads.

The only way to make `vector_add` faster is to use interleaved memory and kernel execution (discussed below).
```
;; -- vector_add --
(def-kernel vector_add (A B &out C)
  (declare (type A B source-vec) (type C result-vec)
     (global-size :derive-from A :strategy :strided))       
  (loop-vector-stride A (i)                   
    (set! (~ C i) ( + (~ A i) (~ B i)))))
```

#### loop-soa-stride 📝
`(loop-soa-stride soaVec (i) ...)`

`loop-soa-stride` iterates over a `soa-vector` using the Grid Stride strategy. 


#### strided strategy ✅

As was discussed in [Hoisting and Enqueueing a Kernel](#hoisting-and-enqueing-a-kernel) it is good practice
to `declare` your kernels global work size expectations and the strategy it hopes to employ.

The `:strided` strategy is almost always the correct choice when doing grid strides of various flavors.


#### grid stride example with explanation.
```
;; -- vector_add --
(def-kernel vector_add (A B &out C)
  ;; assumes A, B and C are all the same length.
  (declare #'((in-vec float) (in-vec float) &out (out-vec float))
     (global-size :derive-from A :strategy :strided))     
  (loop-vector-stride A (i)        
    (set! (~ C i) ( + (~ A i) (~ B i)))))
```

Let's imagine that our vectors A, B, and C each have 100,000 elements. And imagine that our hosting code has set the 
`global_work_size` to 1024. That is, 1024 threads are each running this kernel in parallel.

`loop-vector-stride (i)` establishes a loop, with `i` bound to an index, and the the body setting the vector C at that index
to the sum of A and B at that index (or in C: `C[i] = A[i] + B[i]`)

This runs in parallel so `i` is bound like so across all the threads:
```
    Loop Iteration #1:  0     1     2    3    4    ... 1023
```
And then, the next time through the loop, we don't increment by 1, instead we "stride", we increment _by the number of threads_, which 
we imagined is 1024.  We keep striding until we hit the target which is the lenght of A, 
which we imagined at the outset was 100,000 elements, is where we'll stop striding.
```
    Loop Iteration #2:  1024 1025 1026 1027 1028   ... 2047
    Loop Iteration #3:  2048 2049 2050 2051 2052   ... 3071
    Loop Iteration #4:  3072 3073 3074 3075 3076   ... 4095
    ...
    Last Iter     #98: 99328 99329 99330  --  99999 in 671st position. Threads 672 to 1023 do nothing in last iteration.
```
Hey! That looks like a grid!  

As you can see, all the indeces from 0 to 99,999 are visited, and our calculation is performed at each index. 
In a very short time (just 98 iterations), these 1024 threads add vectors A and B and store them in C. Wow!


