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

## in-warp
`(in-warp (<id-name>) ...)`
`in-warp` binds the thread's lane id to the `id-name` expression for the statements in its body.  

It is within the scope of an `in-warp` block that the various shuffle operations can occur. They cannot
be used otherwise. <!-- NOTE: I don't think this has to be true at all. Maybe? -->

<!-- IMPLEMENTATION NOTE
  CUDA:   unsigned int lane_id = threadIdx.x % 32;
  OpenCL: unsigned int lane_id = get_sub_group_local_id();
-->


### shuffle
`(shuffle <someVar> target-lane-id &optional (width (get-warp-size)))`
The `(shuffle ...)` expression evaluates to the current value of `someVar` as it is in another thread. 
THe target lane-id is provided directly to `shuffle`.

### shuffle-up  / shuffle-down
`(shuffle-up <someVar> delta &optional (width (get-warp-size)))`
`(shuffle-down <someVar> delta &optional (width (get-warp-size)))`
These expressions evaluate to the current value of `someVar` in a thread that is plus or minus `delta` lanes over.
Note that `-up` / `-down` do not necessarily have an intuitive interpretation. The direction is where the data 
is going to, rather than the operation performed with the delta. So `shuffle-up` SUBTRACTS `delta` from the current 
lane id and returns the value of `someVar` from that lower lane (ie, the data is shuffling "up" to our higher lane).
Meanwhile, `shuffle-down` ADDS `delta` to the current lane id and return the value of `someVar` from that higher
lane (ie, the data is shuffling "down" to us.) Whatever. 

### shuffle-xor
`(shuffle-xor <someVar> &optional lane-id-mask:ulong (width (get-warp-size)))`

Those other shuffle operations do cool tricks. But `shuffle-xor` is where real sorcery occurs.

The `(shuffle-xor ...)` expression evaluates to the current value of `someVar` as it is in one of the other threads.  
The target lane id is calculated by taking the current thread lane id and XOR-ing with the `lane-id-mask` argument.
`shuffle-xor` only needs to be given the name of the variable to fetch and the mask, it gets the current lane id automatically.  

`shuffle-xor` is very useful for tree reducing.  See the `sum_vector_warp` example below. 
The magic occurs in the interaction between the descending-by-half mask gotten from `dec-times-by-half` and `shuffle-xor`
This gives us a butterfly communication pattern, which allows all threads to contribute to a reduction in a logarithmic
number of steps.
```
(dec-times-by-half (s (/ (get-warp-size) 2)) ;;start the descent with half the warp size. ie 16 then 8, 4, 2, 1
        ... (shuffle-xor someVal s))
```


### Ballot Operations
The ballot primitives allow the warp to vote on a predicate.


#### warp-ballot
`(warp-ballot predicate:bool) -> uint`
Returns a bitmask where the Nth bit is set if the Nth thread in the warp evaluated `predicate` to true.

Think of `warp-ballot` as a bitwise poll of the warp. Every thread passes in a boolean (the predicate). 
The hardware collects these booleans from all active threads simultaneously and packs 
them into a single 32-bit integer.
If Thread 0 says true, the 0th bit of the integer is 1.
If Thread 1 says false, the 1st bit of the integer is 0.

Each thread receives this same composite integer containing the votes of everyone in the warp.

This is a very useful operation often used in conjunction with the `popcount` bit operation. (See the Bit Twiddling section)

#### warp-any? / warp-all?
`(warp-any? predicate:bool) -> bool`
`(warp-all? predicate:bool) -> bool`
Returns true if any (or all) active threads in the warp evaluate `predicate` to true. These are extremely fast hardware reductions.

### Supported Types
The shuffle operations natively support 32-bit types (`int`, `uint`, `float`). 
Crisp will automatically decompose larger types (like `double`, vectors, or structs) into multiple 32-bit shuffle operations for you.

