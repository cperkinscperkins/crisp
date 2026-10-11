# Atomics ⚠️

Barriers are used when we have a structured, cooperative algorithm when we know exactly when threads write
and when they read, especially when there is no contention for the location being written to.
Atomics serve a similar purpose, but they are used when the multiple threads may
need to write to a same location at unpredictable times. They are used when you need a thread-safe "read-modify-write" operation. An atomic operation ensures that the entire sequence—reading the value, performing a calculation, and writing the new value back—happens as a single, indivisible transaction. This prevents data corruption from race conditions.

Atomics operations are only useful when done to values that reside in memory shared between threads, so 
:local or :global memory, typically.  Possibly values declared as `uniform`. But a typical value declared in a `let` 
clause will be a register variable and is not subject to contention between threads and does not need
atomic operations performed. The compiler will warn you if it detects this situation. 

In some languages, atomics are a variable type, but in Crisp, it's simply an operation that can be coordinated
on any variable that has possible contention. 

**Atomics order nothing.**  A Crisp atomic is *atomic* -- its read-modify-write is indivisible -- and
that is all: it is relaxed, at device scope.  It does not make this thread's other writes visible to
anyone, and it does not order them.  When an atomic is used as a SIGNAL ("my partial result is in
memory, and this increment says so"), the ordering comes from an explicit `mem-fence`: one after the
writes and before the atomic on the publishing side, and one after seeing the atomic and before the
reads on the receiving side.  `grid-reduce!`'s `:last-man-standing` strategy is built exactly that way.
Keeping the ordering in a fence you can see, instead of inside every atomic, keeps the common case
cheap -- accumulation, where only atomicity matters.  (On NVIDIA a sequentially consistent CAS costs a
system-wide fence on every attempt.)


