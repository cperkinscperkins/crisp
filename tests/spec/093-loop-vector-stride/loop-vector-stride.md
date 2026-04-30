
DOCS
The main docs about "striding" and "loop-vector-stride' are at 
docs\chapters\14_control_flow\10_looping_grid_stride.md

and the more general "thread-stride" is mostly covered here
docs\chapters\14_control_flow\11_general_purpose_thread_stride.md
docs\chapters\14_control_flow\12_load_chunk_store_chunk.md
docs\chapters\14_control_flow\13_workgroup_stride.md
(plus the async chunk operations, but that's pretty far afield).

ENDEAVOR
This next endeavor is to implement the loop-vector-stride macro.  
It is used repeatedly in the design docs.

I think this macro can just be a one off. It does not need to be built from
the more general thread-stride form.  But I included the thread-stride docs 
for completeness.

Questions
- do we have everything we need?  We just implemented and tested dotimes. That should work.
- would loop-vector-stride be "Crisp in Crisp"?
- How should we test loop-vector-stride?

Comment
- remember, in Crisp unbound loops and recursion are both disallowed. So we cannot expose a "while"
  to the users. I think the dotimes should be sufficient. It actually supports an optional stride arg 
  (though, probably we won't need it)

