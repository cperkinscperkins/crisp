# Warps & Shuffles ✅

Witchcraft.

The shuffle primitives are special hardware instructions that allow threads
within a single warp directly exchange register values with each other without 
using shared memory. They are very powerful and fast operations.

For most NVidia hardware there are at most 32 lanes in a single warp.  Very often workgroups
are BIGGER than a single warp, so plan your algorithm accordingly. shuffles work across warps, not 
workgroups. 

For some algorithms, setting the workgroup size to be the same as the maximum warp size makes
the algorithm easier to implement. But be careful if you do this, because multiple warps
in a workgroup take up slack whenever there is a stall accessing memory.  If your workgroup
has only one warp, that advantage is surrendered.  However, if you decide to use tha strategy then be sure the `local_work_size` used when enqueueing the kernel matches.  A `(local-size :set-to 32)` declaration with a nice message can help communicate that to whoever is developing
the hoisting.

