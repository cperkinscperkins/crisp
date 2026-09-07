In this endeavor we are going to make sure that 64-bit / DOUBLE is working with MMA, and we are going to add it to the benchmarking. 

I believe this will be NVidia Only, as the only Intel hardware we have access to is BMG. If you know of a way to pursue this on BMG (maybe just the most basic matrix multiplication walk?, let me know).

Unlike the other MMA, which is focused on "fast" math, this is ieee.
- --math-precision=ieee
- [ ] 64 bit (NVidia) should ERROR on the ieee + ftz combination. That is 32 bit only!


Plan
====

- the benchmarking ( .\benchmarks\matmul ) has the "MMA Techniques" ladder, which is a series of chapters ( 0 to 7 ) where we slow implement each MMA technique and benchmark it against the previous chapter.  Presently this is for 16 bit and 32 bit.  Now we'll want to add a series of 64-bit chapters to the ladder.

- if needed, we can also add TDD tests to this endeavors directory. WE'll do this if we need to modify the compiler implementation to support those benchmarks. 

- the new 64-bit MMA Techniques ladder should be added to the report.

- In Section 2, for 16 bit and 32 bit,  for each matrix size we choose the fastest MMA Technique and benchmark it against competitors ( CuBLAS, CUTLASS and custom CUDA in the case of NVidia ).  We'll want to do the same for 64-bit and incorporate it into the report.

