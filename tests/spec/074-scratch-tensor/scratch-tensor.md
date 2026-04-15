The "cell" Storage Handle was introduced some time ago.  Whereas the "tensor" Storage Handle (and the "vector" and "matrix", which are just synactic sugar for (tensor T 1) and (tensor T 2)) have only recently been added and the full feature surface is still underway.


Look at this calling tree

Kernel_A()
 => B()
   => C()
     c = make-scratch-tensor
     => D(c)
      => E(c)

The scratch tensor is instantiated in C(). But kernels cannot allocate memory. So the scratch
tensor needs to implicitly added as a "Side Channel" to call chain from the kernel to C().
Below that, the cell can be passed explicitly and does not need "Side Channel" modification.

Remember that all Storage Handles are built on def-record, which is a "virtual" struct, and records
are passed via SROA (Scalar Replacement of Aggregates) expansion.  The implicit "scratch" args
are passed at the beginning of the kernel signature. 

docs\chapters\07_argument_passing_and_side_channels\00_intro.md has a good overview of the 
concept of "Side Channels" and "Scratch" memory.
docs\chapters\10_storage_handle_types\15_side_channel_storage_handles.md has a bit more detail.

Note that unlike the very simple (make-scratch-cell T) , the make-scratch-XXXX forms have a sizeExpression

(make-scratch-tensor element-type N sizeExpression &key strides address-space align access name msg)
(make-scratch-tensor tensor-type sizeExpression &key address-space align access name msg)



The scratch cell tests that exist already are spread out:
- 017-scratch-cell/scratch-cell.crisp
- 022-def-kernel\13-scratch-cells-and-kernel-boundary.crisp
- 022-def-kernel\scratch-propagation.unit.lisp
- 028-metadata\18-implicit-scratch-cell-signature.crisp
- 029-hoist-l0\19-implicit-scratch-cell-hoisted.crisp

But since all those features are done now, we can have all the tensors ones in this directory.

Lastly, while vector and matrix are simply syntactic sugar for tensor, we should probably have a few tests that use them explicitly.