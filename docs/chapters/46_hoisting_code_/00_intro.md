# Hoisting Code ✅


The hoisting code that Crisp outputs demonstrates the following:
- loading the kernel from disk
- using CUDA/LevelZero/OpenCL to create a program from that kernel
  be it IR or binary
- commented out code that demonstrates how to perform profiling
- then for each kernel in the output
- - allocating and preparing all the side channel memory. Using 
    Unified Memory if requested by the `--hoist-unified-memory` flag.
- - allocating and preparing the explicit memory in the kernel arguments.
- - setting the kernel arguments
- - enqueuing the kernel
- - waiting for it to complete
- - enqueing any "copy back" operations for result vectors.

Further, if the `--hoist-dynamic` flag is used, then the example code will actually 
include the string of that kernel and pass it to the in-memory compilation API (etc.).


