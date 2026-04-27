Strategy
========

The "strategy" declaration in Crisp is very unique to the Crisp language. It is not the sort of thing
seen in other languages.  I know that the actual key :strategy is just one thing in the parent global-size
and local-size declarations. I just, out of habit, refer to these two declarations as "strategies".

That's what we will be supporting in this endeavor. Support for the local-size and global-size declarations.


The strategies inform the metadata
and, in turn, the output of the .cpp or .py that whatever hoisting application is performing.

Sometimes the strategy does effect how the compilation of the kernel proceeds, but mostly just 
when inserting runtime checks (when the `--runtime-checks` flag is passed).


THE DESIGN
----------
Start by reviewing .\docs\chapters\14_control_flow\07_hoisting_and_enqueing_a_kernel.md
This doc is clutch.

THE METADATA
------------
I've updated the plan\ref.metacrisp with my current thinking about how this should appear in the 
metadata. BUT, this is open to change, if you think we should go about it differently. Let me know.

Essentially,
 Pretend our kernel is like the following
 (def-kernel lighten_image (image-data width height)
   (declare (type image-data (vector uchar :address-space :global :access :read-write))
            (type width height ulong)
            (global-size :derive-from ( width height) :strategy :one-thread-per))
    ...)

  
  Then the metadata for the kernel will have a :global-size entry
  and it's value will be a direct copy of that declaration 
  e.g.
  (:name "lighten_image"
    :source #P"path/to/lighten.crisp"
    :global-size (global-size :derive-from ( width height) :strategy :one-thread-per)
    ... etc.)

  The :declared-signature block of the metadata has the names, in order, along with their
  real arg index range.  If needed, that information can be cross-referenced from there.

But, again, this design is not set in stone yet. If you'd like to adjust it, we can.


TESTING
-------
As this is primarily work in the hoisting app, the tests will probably revolve around that.

We need
    global-size / local-size
times
    :set-to  / :derive-from
also
    num-groups

plus 
    :strategy
    - :one-thread-per
    - :strided
    - :interleaved
    - :exact
    - :tiled & :tile-shape


AND, unless you think it is too much work, we should probably do
- check-thread-bounds
- check-wg-bounds

That seems like the test surface might be fairly substantial.  Let me know your thoughts.


