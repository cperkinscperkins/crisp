# Cost of Divergent Branching ✅


Examine the following simple example:
```
   (if (should-we-do-it? a)
     (do-it a)
    (do-something-else a))
```
Let's pretend `do-it` is expensive and takes 10 seconds of wall clock time to complete.  Similary, `do-something-else` is expensive and takes 10 seconds.

So how long does the entire expression take?  The answer is surprising.  
On a CPU, we have to perform one or the other, but not both, so the answer is 10 seconds.
On a GPU the answer depends on whether the threads diverge or not.  If `should-we-do-it?` is true for all the threads in a workgroup
then the answer is the same as the CPU: 10 seconds.  But if `should-we-do-it?` is different for even just one of the threads in the workgroup, 
then the answer is 20 seconds. The first set of threads excute `do-it` while one thread waits stalled. Then all the other threads are STALLED while
one thread preforms `do-something-else`.  So our workgroup takes 20 seconds. The branches do not run independently.

If the result of `(should-we-do-it? a)` were captured in a variable and forced to be uniform with `to-uniform`, then we'd guarantee that it would take only 10 seconds, and there would be no stalling. This is because it would not diverge in a workgroup. Of course, that
might not be appropriate for some problem sets. But you can see where it is obviously superior to structure your problem so that it CAN 
take advantage of such an optimization. 


