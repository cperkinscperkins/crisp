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


The Design Doc says this about the Size Expression:

### sizeExpression

The sizeExpression is the magic that makes these things tick. The most useful choices for sizeExpression are the following keyword symbols that Crisp supports:

:match-workgroup-size (1 per thread in group) the scratch memory allocated will match the workgroup size (ie wg-size * sizeof(T) where T is the element type)
:match-num-workgroups (1 per group in the grid).
:match-total-threads (1 per thread total)
:match-warp-size (1 per lane in warp)
:match-warp-tile (1 per warp-size squared)
:match-num-warps-per-workgroup
:match-total-warps (global_size / warp-size)
The above sizeExpression choices will automatically set the :msg that is sent back to the hoisting code.

Alternately, the sizeExpression can be a compile-time known value, in which case the hoisting code will be configured with that, or it can be any runtime value or some other Storage Handle variable. In these cases, this will be noted in the hoisting comment, but that may lack clarity. It is best ot use the :msg key as well.

#### sizeExpression for matrices and tensors
:match-workgroup-size and :match-grid-size (and :match-warp-tile) all work well when the arity of the local_work_size/global_work_size matches the arity of the Storage Handle view. If it is expected that they won’t match, use a scratch vector and reinterpret it for your needs.

Alternately, the sizeExpression can be a list in (... z y x) order.