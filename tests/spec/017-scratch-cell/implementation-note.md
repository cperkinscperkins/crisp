Scratch Cells are our first "Side Channel" Storage Handle.

Look at this calling tree

Kernel_A()
 => B()
   => C()
     c = make-scratch-cell
     => D(c)
      => E(c)

The scratch cell is instantiated in C(). But kernels cannot allocate memory. So the scratch
cell needs to implicitly added as a "Side Channel" to call chain from the kernel to C().
Below that, the cell can be passed explicitly and does not need "Side Channel" modification.


    