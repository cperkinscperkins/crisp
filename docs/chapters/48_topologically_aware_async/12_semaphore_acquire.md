# semaphore-acquire


`(semaphore-acquire sema expected-value)`

Wait on the semaphore until its value equals `expected-value`.

In the implementation this translates into a spin-wait loop that atomically polls the memory address using a `memory_order_acquire` fence. It will loop—inserting hardware yield/sleep instructions to save power—until the semaphore equals the expected-value. The acquire fence guarantees that your warp will not speculatively start reading memory for the next step until the lock is officially acquired.

