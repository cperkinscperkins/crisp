# Thread Level / Grid Level / Dispatch ✅


> A GPU is not a CPU
>
> — ( this author )

In most Lisp languages, `progn` is a term used to desribe a set of code that is grouped together and bound 
by parentheses. In C++ we might say "the body of a function" or the "body of a closure". In C++ a `progn` is
typically surrounded by curly braces `{ ... }`  .

In Crisp, the `progn` that appear in function bodies implicitly have one of three "contexts" that
inform the compiler on the type and scope of actions that might be taking place in that `progn`.
These three contexts are

- thread level
- grid level
- dispatch

A thread level context is one where the action taking place within it is independent of what
is occurring in other threads. Typically this means there is no expection that it work with 
a particular piece of global memory or perform atomic operations on global memory. Thread level
contexts are the default in functions defined by `def-function`. Importantly, inside a thread
level `progn` it is illegal to make grid level or dispatch level operations/calls.   

In contrast in a grid level context there is an expectation that thread with such-and-such id is
accessing global memory at such-and-such index, or performing atomic operations on global memory.
Grid level contexts most often come from macros like `loop-vector-stride`. Inside a grid level
`progn` making thread level operations is perfectly fine. But calling OTHER grid level operations
is forbidden. In other words, grid level operations cannot nest inside one another.

A dispatch context is a context where we can call either thread level or grid level 
operations freely. But note, that if a grid level `progn` is opened that inside its body the
restriction on calling other grid level operations still applies. Dispatch contexts are 
associated with `def-kernel` and `def-grid-function`.  And note that while grid level operations
cannot be nested inside one another, a dispatch context CAN call them sequentially, one after another.

This author likes the analogy of a garment factory, where there are long tables with sewing machines
running along them. As a worker finishes their task (sewing buttons perhaps), they pass the garment on to the next
machine on the table (which sews seams).  In this analogy, a single GPU thread is like the long table.
The call stack of functions calling one another on that thread is the individual machines sewing then passing the work to the next.
A thread level `progn` can contain the actions that can be performed by a person sitting at one machine.
The long tables are grouped together into small workgroups. If there is some coordination that must 
occur within a workgroup, (via local memory and local barriers perhaps), that's fine. A worker can do that 
("Hey, look at what Jim is doing").
But if you need to coordinate multiple workgroups, or ALL the tables in the factory, well that's a
a grid level operation. That requires management. A single worker sitting at a sewing machine cannot
 "call" a grid level operation. 


