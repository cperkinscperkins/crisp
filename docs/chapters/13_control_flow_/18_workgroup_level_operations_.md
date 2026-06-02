# Workgroup Level Operations ✅


Workgroup-level operations are a bit like grid-level, in that multiple threads are being coordinated in
the context of some `progn`, but the scope of coordination is limited to within a single workgroup.  
Workgroup level operations cannot be nested inside other workgroup-level operations, 
in this regard they are similar to grid level ops. But workgroup level
operations CAN be invoked in thread-level contexts (so long as that doesn't result in nested workgroup level contexts).

### `(declare (workgroup-level))`

`workgroup-level` is a declaration that tells the compiler (and other users) that a particular `progn` is a workgroup level
context. If you are writing a `defmacro` that is doing workgroup level coordination, then be sure to include
this declaration in its expansion.


