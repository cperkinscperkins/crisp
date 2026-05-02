## Sum a Vector using Local Memory


Earlier we demonstrated a simple `vector_add` using grid strides. 
This example is slighly more complicated and uses several of the control flow 
constructs that have been covered so far.  

We can easily use multiple threads to stride through a vector summing it as they go. 
But if we have 1024 threads, we'll end up with a 1024 different sums that, in turn,
need to be summed.  

To then sum those up we COULD use a block of global memory that is 1024 element long.
Each thread could write its sum in it, and then one thread could sum them,
or it could be transferred back to the host and it could finish summing them. 
But this both takes a lot of memory and is the slowest type of memory. 
So we will not do that. 

Instead, we'll use two smaller scratch pads.  One is local memory that has the
same number of entries as the local_work_size of the kernel.  Local memory is fast, 
but limited to the threads in the same workgroup.  The second scratch pad
is global memory, and it is M entries wide, where M = NUM_THREADS / WORKGROUP_SIZE, 
or  M = global_work_size / local_work_size.  This the same as the number of workgroups.

The routine will use a tree reduce pattern so that half the threads in the workgroup 
add their sum to the comparable in the other half. And then repeat, halving the 
number of threads each time. This reduction is on the local scratchpad.

Lastly one thread in each work group writes its sum to the global scratchpad.

After this, we could use a global barrier and then sum that scratchpad.
But since the global scratchpad needs to be prepared by the host anyway,
it's simpler to just end the operation and enqueue a second operation to 
complete the sum.  Or sum it on the host, if that is your preference.

In our `sum_vector` routine, the host will supply the vector it wants
to be summed, plus the result vector (which is also that global scratchpad).
We could also have it provide the local scratchpad as a vector too. That 
would make the routine more flexible. But in this case, we are just
going to agree on a convention that the local_work_size is 64.



```
;; the result vector should be size M, where M = global_work_size / local_work_size
;; aka num-groups.
(def-type result-vec (vector long :align :compact :address-space :global :access :writeable :size (get-num-groups)) 

;; -- sum_vector_first_stage --
(def-kernel sum_vector_first_stage (A &out Res)
  ;; A can be any size, but Res should be num-groups
  (declare #'((in-vec long) => result-vec)) 
           (global-size :derive-from A :strategy :strided))
                                     
   (let ((sum 0))
     ;; Stride the vector, summing it up. Each thread has its own value in 'sum'
     (loop-vector-stride A (i)
        (inc! sum (~ A i)))
    
    ;; Prepare local memory and store sum in it. 
    (let ((slm (make-scratch-vector long :match-workgroup-size)))
      (in-each-thread-in-group (local-idx)
        (set! (~ slm local-idx) sum)
        
        ;; tree reduce
        (dec-times-by-half* (s (/ (get-local-size) 2))  s is 32, then 16, 8, 4, 2, 1
          (local-barrier)
          (when (< local-idx s)
            (inc! (~ slm local-idx) (~ slm (+ local-idx s))))))

      ;; move sums to global 
      (when-thread-in-group-is (0)
        (let ((wg-idx (get-workgroup-id 0)))
          (set! (~ Res wg-idx) (~ slm 0))))))) 
```

This example is provided so that you can see several "Crisp-ish" constructs used together, 
like the tree reduce `dec-time-by-half` and its `*` variant, the scratch vector creation 
all applied to the topic of a workgroup sized reduction using local memory and a local barrier. 

But, again, the vector is not fully summed. That'll require a second kernel pass. 
 The simplest solution there is to make another kernel that
employs `reduce-vec-second-stage` (see below) and then you'll have a two step solution. If you would
like to see the hoisting code in action, then use either a continuation kernel (see above) 
or  `def-orchestration` (see below).


