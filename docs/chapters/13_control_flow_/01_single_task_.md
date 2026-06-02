# Single Task ✅


A single task kernel is a kernel that runs on exactly one thread. While it is simple to understand be warned that it is not
necessarily performant. If you have only one single task kernel running, the majority of your GPU power idles untapped. 
When scheduling a single task kernel, look for opportunities to run it while other work is being done.

`single-task` 
Put the symbol `single-task` into the `(declare ...)` of the kernel. When it sees this, the compiler will surround
the main body of the kernel with a check to ensure it is run by only one thread.  And the hoisting code that
is generated will set the global work size (thread count) to be 1.  

```
;; -- do_little --
(def-kernel do_little (#| some args |#)
  (declare single-task)
  #| some work |#
)
```

```
// example OpenCL hoisting code
 clEnqueeuNDRangeKernel( someCommandQueue, doLittleKernel, 
                          1 /* work_dim */,
                          0 /* global_work_offset */,
                          1 /* global_work_size -- just ONE thread */,
                          1 /* local_work_size */,
                          eventCount, waitList, &someEvent); 

```
<!-- NOTE: what might be a better "real" example for single-task? -->

