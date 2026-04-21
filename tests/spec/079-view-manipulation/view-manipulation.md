Now that storage handle reinterpretation is in place, it should be straightforward
to test "view manipulation" (and implement if needed).

All the Storage Handles (cell, vector, matrix, tensor) are "views" onto storage data pointers.
These views can be manipulated. The offset, strides, and extents are all mutable values.  
It is very useful, for example, to reinterpret a cell at some offset of a vector and then 
"move" the cell forward or backward.  Same applies to all.

These operations are, of course, fundamentally unsafe. Crisp, as ever, will optionally
insert checks to make sure boundaries aren't exceeded if the --runtime-checks compiler 
flag is used. Otherwise, no runtime checks are inserted and it's assumed the user knows
what they are doing. 

Initial Tests:
- setting each mutable scalar (offset~, length~)
- setting virtual array elemtns (offset~[0], strides~[0], extenst~[1])

Then tests for:
Reading through a modified view — the practical use case. Test 01 sets offset~ but never dereferences through c afterward. The critical correctness question is: does (~ c) after (set! (offset~ c) 2) produce IR that loads the offset from the alloca (runtime value) vs using the compile-time offset baked in? Currently unverified.

Tensor-dimension mutations — tests 03/04/05 cover vector/matrix. A test setting (set! (~ (offset~ tensor) k) val) for an N-dim tensor would complete the coverage.

CHECK directives — the current tests have no IR validation. They only check "compiles without error." A CHECK on the insertvalue instruction with the correct field index and type would give us confidence the IR is right.