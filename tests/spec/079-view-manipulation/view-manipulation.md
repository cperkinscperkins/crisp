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

