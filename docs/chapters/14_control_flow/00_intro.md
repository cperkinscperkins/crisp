# Control Flow


Programming performant GPU kernels is often very different than programming performant CPU-bound code.
And Crisp's departure from other languages is significant in its approach to execution control flow.

GPUs are very fast and powerful when performing parallel operations. When working large workloads, the goal is to keep 
the full might of the GPU fully occupied running meaningful operations in parallel without stalling.  
This is no small challenge, because many routine C and Lisp constructs like `if/then` or even a simple `for` loop
can lead to bifurcations in the thread progress, which leads to idle threads which leads to poor performance.

The control flow affordances in Crisp revolve around maximizing parallelism, keeping thread workgroups and warps marching
in sync, and avoiding bifurcations. Additionally Crisp keeps the developer involved and informed of the choices and trade-offs
being made, rather than hiding them behind abstractions. 


