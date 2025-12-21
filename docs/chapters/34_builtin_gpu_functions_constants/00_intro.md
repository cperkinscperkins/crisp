# Builtin GPU Functions & Constants


- get-num-warps
- get-warp-id     index of warp WITHIN its workgroup
- get-lane-id     thread index within warp
- get-work-dim    number of dimensions the kernel was launched with 

- get-local-id   x y z     thread index inside workgroup
- get-local-work-size => (x y z)   size of workgroup

- get-workgroup-id x y z   index of group 
- get-num-groups => (x y z)     total number of workgroups

- get-global-id  x y z     thread index within all threads. always starts at 0
- get-global-id-abs x y z    absolute thread index. (equals get-global-id + get-global-offset)
- get-global-work-size => (x y z) 
- get-global-offset => (x y z)

- get-local-linear-id
- get-local-linear-size      
- get-global-linear-id
- get-global-linear-size
- get-total-threads   (same as get-global-linear-size)
- +warp-size+

- local-barrier
- mem-fence 
- sync-warp 

- get-timestamp   returns the high resolution clock counter. ( %clock64 register).

