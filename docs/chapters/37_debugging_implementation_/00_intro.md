# Debugging Implementation ✅


The perennial challenge of using debug logging on a GPU is that there is just TOO MUCH of it. 
Thousands of threads all logging identical messages isn't helping anyone, especially if the 
memory has to be anticipated and allocated in advance, and especially when there is inevitably contention
between threads to write to that memory. Performance degrades, output buffers fill up, and
tempers rise.


Crisp attempts to ameliorate that by providing SUBDIVIDED logging, as well as "first N" and "last N" 
message options to address debug buffer overflow. What this means is the debug buffer handed to the kernel
can be divided in differrent ways, ways to limit who logs, or ways to ensure that certain critical logging is performed and accessible.  Unfortunately, these options have to be
selected at compile time, rather than when enqueueing the kernel. Perhaps some intrepid user
can use the [In-Memory Compilation API](#in-memory-compilation-api) to make a handy tool.

