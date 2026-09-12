# GPU Memory ⚠️


In the next section we introduce the Storage Handles (`cell`, `vector`, `tensor`). These are the only
data types Crisp supports for passing, or making available, blocks of memory
from the host TO the kernel. They are also the only vehicles for getting
any data back FROM a kernel, even if it's just a single digit (see the `cell` subsection).

For the kernel authors perspective there are three types of memory with
which we need to concern ourselves: Global, Local, and Constant.

#### Global Memory

Global memory is the largest memory space available to the GPU, typically measured in gigabytes (GB). It's accessible by all threads across all workgroups and is the only memory space directly accessible by the host CPU for transferring data to and from the GPU.

Any memory you prepare host-side and pass to the kernel will reside in global memory. Likewise, any results passed back from the kernel (`&out`) must also be in global memory.

But global memory access is slow.

#### Local Memory

Local memory (also called "shared memory") is fast. It is a low-latency high bandwidth on-chip memory space.
Its size is typically measured in kilobytes (KB) per compute unit (48KB to 128KB), and this
limited pool is shared among all workgroups running concurrently on that unit.

It must be prepared by the host, but the host 
can only prepare it to be available, it cannot write into it. It is not usable as a 
communication channel between host and kernel. 

Local memory is bound to a workgroup. It cannot be used to share 
data between workgroups. For that, global memory is needed.

Because it's a limited resource, requesting excessive local memory per workgroup can reduce the number of workgroups that run concurrently (lower occupancy), potentially impacting overall performance. 

#### Constant Memory

Constant memory is another fast on-chip memory that is optimized for broadcast scenarios. 
It is read only memory from the kernels perspective, but it CAN be initialized by the host. 
It is usually limited to 64KB per compute unit, and is ideal for small, read-only lookup tables, configuration
parameters, or coefficients that are shared by all threads.

With Crisp you have two ways of preparing constant memory: 
- Define and initialize it entirely at compile time using `def-constant-vector`. Kernels access it by its defined name.
- Declare a kernel parameter as Storage Handle type with `:constant` address space. The host is then responsible for allocating and initializing a read-only buffer and passing it to the kernel. The hoisting code generator will produce example code demonstrating the necessary host API calls.

#### Private Memory
`:private`  - need to be written


