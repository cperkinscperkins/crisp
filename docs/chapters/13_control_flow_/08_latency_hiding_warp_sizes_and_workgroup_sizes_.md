# Latency Hiding - warp sizes and workgroup sizes ✅


As mentioned in passing, most GPUs have a warp size of 32 threads, and the best practice is to use a `local_work_size` (ie a work group size) that is a multiple of the warp size when enqueueing.  But why is that?
The answer is Latency Hiding. When a warp needs to access memory it may become stalled waiting for that memory.  
While it is stalled the GPU can run OTHER warps to "hide" the latency. But it can only run other warps that 
are within the same workgroup. So this is the reason the workgroup size is best set as a multiple of the warp size.

There are times when it is simplest, and indeed fastest, to simply set the `local_work_size` to 32, to the warp size. This ensures that workgroup thread communication can always just be done with a shuffle, and without needing `:local` memory or barriers. But this is only a good strategy if you are sure your kernel is relatively stall-free. If it stalls because of branch divergence or memory access, then there is no other warp to take up the slack, which makes the overall operation slower.  



