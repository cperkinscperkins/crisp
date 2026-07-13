This endeavor is a continuation of our last one ( .\tests\spec\136-mm-async\mm-async.md).

We are working our way through the MMA "Chapters" in .\docs\topology.md . In the last endeavor we added basic linear async DMA operations, and began modified the (make-async-barrier) routine to both take keys alowing a uses to specify the exact DMA they want govered, and preparing it for the optimal when those keys aren't used.

[x] Chapter 1 - async tile   cp.async and OpGroupAsyncCopy
[ ] Chapter 1.5 - async tiles  with CuTensorMap and LSC 2D Block Loads in Intel Xe

Now we are working on "Chapter 1.5" . 

Here is some of the work that needs to be done. Each entry most likely needs at least one TDD test.

[ ] DEFALTS: when no --ir-target-arch is provided, let's assume it is sm_80 if Nvidia and DG2 if Intel.
[ ] :mode :block support for (make-async-barrier :type :global :mode XXXX)
[ ] we should throw a compilation error when :block can't be realized
     For PTX, that would be if --ir-target-arch is not provided (or is earler than sm_90)
     For Intel, that would be if --ir-target-arch is Gen12.
[ ] (make-async-barrier) with NO :type / :mode should choose whatever matches the elected (or default if none) architecture.
[ ] CuTensorMap will require an implicit argument added to the kernel like we already do for scratch memory.
[ ] if a sub-function is the one caling make-asynch-barrier, then the CuTensorMap will also have to be added 
as an implicit argument to it interfact and ALL OF ITS CALLERS, just like we do now with scratch memory in sub-functions.  We will definitely need some tests for this.
[ ] We should definitely test the full MMA with the :block async copies.
[ ] And benchmark.
