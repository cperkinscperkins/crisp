# semaphore-release


`(semaphore-release sema new-value)`

Change the value of the semaphore. Presumably some other party might have been waiting and will now spring to action.

In the implementation this translates into an atomic write instruction coupled with a `memory_order_release` fence. The fence is the magic part. It strictly guarantees that any data your warp just calculated and stored (e.g., writing a computed tile back to Global Memory) is fully flushed and visible to the rest of the GPU before the semaphore's value actually changes.


