# Reduce Variants 📝


Crisp provide several choices and building blocks for reductions. There are "shop local" variants that perform
quick efficient reductions at the warp or workgroup level. And there are also some Single Pass grid level
routines that first "shop local" using the warp or workgroup routines and then "act global"
to gather up the results of the reduction across the different workgroups.

This first set of reductions reduce a variable ( `<someVar>` ) with a commutative operation ( `someFunction`)
across threads (of a warp, of a workgroup, or all)

- reduce-to-warp
- reduce-to-workgroup
- reduce-to-1-second-stage
- reduce-to-1-atomic
- reduce-to-1-cas
- reduce-to-1-cont

The second set of reductions reduce a vector, with various techniques. They employ
grid strides however, which means you'll want to declare `:strategy :strided` if you use them in your own
functions/kernels.

- reduce-vec-first-stage
- reduce-vec-second-stage
- reduce-vec-warp
- reduce-vec-atomic
- reduce-vec-cas
- reduce-vec-cont

Note that the `XXXX-atomic` and `XXXX-cas` variants are Single Pass variants that require only one
kernel to complete their calculation, though they use atomics which may have performance earmarks.
The `XXXX-cont` variation is single construct that uses kernel continuations, so they are "two pass"
solutions.  The `XXXX-second-stage` is a small "sweep up and finish" construct that completes a "first stage" of 
some reduction.  For vectors that "first stage" is `reduce-vec-first-stage`.  For variables, the first
stage would be `reduce-to-workgroup`.  Note that `reduce-to-workgoup` is a VERY useful workhorse
and is used by many of the other reductions. Lastly `reduce-to-warp` is a thread level operation 
that is special case and very fast. It is used by `reduce-to-workgroup`. 


#### optional scratch vector arguments.

Some of the reduce functions accept `&optional` arguments for local and global scratch vectors.  
These vectors are consistently sized relative the warp, workgroup and global thread count. 
If not provided Crisp will generate the scratch memory for you.



#### reduce-to-warp 📝

`(reduce-to-warp someFunction <someVar> identity &optional (active-threads (get-warp-size)) )`

`reduce-to-warp` is a macro that applies `someFunction` to `<someVar>` expression in the current thread and another thread in
the same warp. It does this iteratively until all the threads in the warp whose id is less than `active-threads`
 have been reduced. At the culmination of this operation, each warp will have `someVar` set to the final reduction value in each thread of that warp.   Note that using a value for `active-threads` that is GREATER than the warp size for the GPU hardware
 is undefined behavior. This reduction cannot reduce more than `+warp-size+` threads.

`reduce-to-warp` achieves its reduction using shuffles and `dec-times-by-half+` without using barriers or local memory. 
It is extremely fast. But it is limited to just one warp. The kernel could `(declare (local-size :set-to 32))` where 32 is max thread count per warp for most GPUs, 
and this is a good fit for many problems. But a workgroup that consists of multiple warps is often better
 because if one warp needs to pause while it fetches memory, another warp can be run in its stead - but this only happens within a single workgroup. Note that while `reduce-to-warp` does coordinate other threads at the warp level, it is NOT
 a grid level operation can be used in a wide variety of situations and applications.

- `someFunction` is a `binop-type`, meaning it has type `#(T T => T)` where `T` is the type of `<someVar>`
- After completion `<someVar>` in all the threads of the warp will be bound to the final value of the reduction.
- `reduce-to-warp` returns nil. 



The example below will output "warp total: 640" repeatedly, once for each warp, assuming 32 threads per warp and each warp fully occupied. 
```
(let ((someVar  20))
  (reduce-to-warp #'+ someVar)
  (when-thread-in-warp-is 0
    (r-t-output "warp total: " someVar)))  ;; => "warp total: 640"     
```

Possible Implementation:

```
;; -- reduce-to-warp --
(defmacro reduce-to-warp (someFunction someVar identity  &optional (active-threads (get-warp-size)))
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  `(in-warp (lane-id)
    (declare (warp-convergent)) ;; <-- tells compiler cannot be called in divergent branch.
    ;; Active threads use their value. Inactive threads use the identity.
    (let ((val (if (< lane-id ,active-threads)
                    ,someVar
                    ,identity)))

      ;; Perform the full, unconditional reduction on 'val'.
      ;; The loop bounds are always based on the full warp size.
      (dec-times-by-half+ (s (/ (get-warp-size) 2))
        (set! val (funcall ,someFunction (shuffle-xor val s) val)))

      ;; Write the final result (from lane 0) back into someVar for all threads.
      (set! ,someVar (shuffle val 0)))))
```



#### reduce-to-workgroup 📝

`(reduce-to-workgroup someFunction <someVar> identity &key return-vec local-scratch-vec message )`

`reduce-to-workgroup` is very useful workhorse construct.  It applies the reduction across all threads and results
in each the 0 thread of each workgroup having the final reduction (and optionally storing it in `return-vec`).
Functionally, `reduce-to-workgroup` is much the same as `reduce-to-warp` but it reduces all the threads in the workgroup, not just in the warp.  The value `<someVar>` will be `uniform` at the completion of this operation.
In addition to `someFunction` , `<someVar>` and `identity` it also accepts two `&key` arguments.

Like `reduce-to-warp` this is NOT a grid level operation and it can be used in a wide variety of contexts and situations.

##### return-vec
The `:return-vec` is a vector that will store the return results (if desired).  This is a vector of the same
element type as `<someVar>`. Its address space MUST be `:global` and it's size is the number of workgroups 
which can be calculated as `M` where `M = global_work_size / local_work_size`.   
If the `:return-vec` is not provided, the result is not preserved in memory. But after `reduce-to-workgroup` 
finishes, `<someVar>` will be the result of the reduction in its same workgroup. So it is usable if your
next operations can be performed within the workgroup.

##### local-scratch-vec
The `:local-scratch-vec` key.  If not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / (get-warp-size)` ). `(get-warp-size)` is usualy 32. 

##### message
The `:message` will be applied to the creation of the `:local-scratch-vec` if Crisp is generating it on your
behalf.  This can help inform the hoisting code for what the extra scratch memory is needed.


- After completion `<someVar>` in all the threads of the workgroup will be bound to the final value of the reduction.
- `:return-vec` (if provided) will store the results of each individual workgroup's reduction.
- The state of `localScratchVec` is indeterminant 
- `reduce-to-workgroup` returns nil.

Possible Implementation
```
;; -- reduce-to-workgroup --
(defmacro reduce-to-workgroup (someFunction someVar identity &key message 
                                                             (local-scratch-vec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup :msg message))
                                                             return-vec)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (if return-vec (is-type-of (element-type return-vec) (type-of someVar)) T) "type mismatch of return-vec and someVar")

  `(progn
    ; After this local-scratch-vec contains partial sum from each warp in the wg
    (declare (workgroup-level))
    (reduce-to-warp ,someFunction ,someVar ,identity)
    (when-thread-in-warp-is 0
      (set! (~ ,local-scratch-vec (get-warp-id)) ,someVar))
    (sync-workgroup)

    ; inter warp reduction
    (let ((num-warps (ceil (get-local-work-size) (get-warp-size)))
          (local-id (get-local-id)))
        ; Only a subset of threads needed for this phase.
        (when (< local-id num-warps)
          ; The loop iterates s => num_warps/2, num_warps/4, ... , 1
          (dec-times-by-half (s (floor num-warps 2))
            ; The first 's' threads are active in this pass.
            (when (< local-id s)
              (let ((partner-idx (+ local-id s)))
                ; Each active thread combines its value with its partner's.
                (set! (~ ,local-scratch-vec local-id)
                      (funcall ,someFunction
                              (~ ,local-scratch-vec local-id)
                              (~ ,local-scratch-vec partner-idx))))))
          ; barrier needed between each pass 
          (sync-workgroup)))

      ; The final result is in local-scratch-vec[0]. Load it to thread 0
      (when-thread-in-group-is 0
        (set! ,someVar (~ ,local-scratch-vec 0))
        (when ,return-vec (set! (~ ,return-vec (get-group-id)) ,someVar)))
      ; broadcast to entire workgroup
      (when-thread-in-group-is 0
        (set! (~ ,local-scratch-vec 0) ,someVar))
      (sync-workgroup)
      (set! ,someVar (~ ,local-scratch-vec 0))))

      ;; add (declare (uniform ,someVar)) ??  

```

#### reduce-to-1-second-stage 📝

`(reduce-to-1-second-stage someFunction <someVar> identity &out final-result &optional localScratchVec globalScratchVec)`

`reduce-to-1-second-stage` is much the same as `reduce-to-workgroup` but reduces all threads in all workgroups down to one single value.
That value will be stored in `final-result` which is a `single-result`.  `someVar` will also be correctly set in the very last workgroup,
but not other workgroups which will hold intermediate values. 

Also this routing has a restriction in that the number of workgroups MUST NOT BE greater than `local_work_size`.  If this is
violated, this routine will runtime assert. However, remember that runtime asserts are only observable when 
the debug logging option has been elected when compiling. 

##### optional scratch vectors
This routine accepts two optional arguments.  `localScratchVec` and `globalScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector`  that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / (get-warp-size)` ). `(get-warp-size)` is usualy 32.

`reduce-to-1-second-stage` also accepts an optional `globalScratchVec`. Crisp will generate it for you if you do not provide it.  
If you want to provide it yourself, it should be a `vector` whose `element-type` is the same as `<someVar>` , 
its address space MUST be `:global` and it's size is the number of workgroups 
which can be calculated as `M` where `M = global_work_size / local_work_size`. 


- After the operation completes, the state of both `localScratchVec` and `globalScratchVec` are indeterminant. 
- `reduce-to-1-second-stage` returns nil.
- `<someVar>` in thread 0 of workgroup 0 will hold the final value of the reduction
              this is the same as global linear thread id of 0.
              Its value is indeterminant in OTHER threads.
- `final-result` will hold the final result of the reduction.

```
(let ((someVar (some-calculation ...)))
   (reduce-to-1-second-stage #'+ someVar 0 output-single)
```

Possible Implementation
```
;; -- reduce-to-1-second-stage -- 
(defmacro reduce-to-1-second-stage (someFunction someVar identity out-single 
                                    &optional (localScratchVec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup :msg message))
                                              (globalScratchVec (make-scratch-vector (type-of someVar) :match-num-workgroups :address-space :global :msg message))
                                    &key message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  `(progn
    (declare (grid-level) (num-groups :max :local-size))
    (r-t-assert-0 (<= (get-num-groups) (get-local-work-size)) "number of groups cannot be larger than local_work_size for reduce-to-1-second-stage")

    ; after this the globalScratchVec will one value per group.
    (reduce-to-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,localScratchVec :return-vec ,globalScratchVec)
    

    ; inter thread reduction.  Easiest and fastest if it fits in one warp,
    ; or one workgroup.
    (when-is-last-workgroup ()
      (let ((N (length~ ,globalScratchVec))
            (l-w-s (get-local-work-size)))
        (declare (uniform N l-w-s))
        (cond*  ((< N (get-warp-size))
                  (let ((lane-id (get-lane-id))
                        (var (if (< lane-id N) (~ ,globalScratchVec lane-id) ,identity)))
                    (reduce-to-warp ,someFunction var ,identity N)
                    ; Broadcast to all threads in wg
                    (when-thread-in-group-is 0
                      (set! (~ ,localScratchVec 0) var))
                    (sync-workgroup)
                    (set! ,someVar (~ ,localScratchVec 0))))
                ((< N l-w-s)
                  (let ((local-id (get-local-id))
                        (var (if (< local-id N) (~ ,globalScratchVec local-id) ,identity))))
                    (reduce-to-workgroup ,someFunction var ,identity :local-scratch-vec ,localScratchVec)
                    (set! ,someVar var)))
        (set-result! ,out-single ,someVar)))))
                    
```

#### reduce-to-1-atomic 📝

`(reduce-to-1-atomic someFunction <someVar> identity &out return-vec &optional localScratchVec)`

`reduce-to-1-atomic` is a reduction of a variable like the others, but it is a single pass operation.
No "second stage" kernel is needed.  It reduces all threads in all workgroups down to one single value.
That value is stored in `return-vec` which is a required argument. It should be a vector of length 1 (ie, a `single-result`)

Unlike `reduce-to-1-second-stage`, `reduce-to-1-atomic` can work across all threads and is not constrained by workgroup sizes.  
Instead `reduce-to-1-atomic` has a different limitation: `someFunction` must be one of three commutative operations: `+`, `min` or `max`
that have `atomic-XXXX!` counterparts.

- `#'+`
- `#'min`
- `#'max`

It is a compilation error to use it with any other operation. 

##### optional scratch vector
This routine accepts an optional scratch vector argument  `localScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / (get-warp-size)` ). `(get-warp-size)` is usualy 32.


- After the operation completes, the state of `localScratchVec` is indeterminant. 
- `reduce-to-1-atomic` returns nil.
- After the operation the value of  `<someVar>` in any thread is indeterminant.
- `result-vec` will hold the value of the reduction.


Possible Implementation
```
;; -- reduce-to-1-atomic --
(defmacro reduce-to-1-atomic (someFunction someVar identity return-vec
                              &optional (localScratchVec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup :msg message))
                              &key message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (is-type-of someVar (element-type return-vec)) "type mismatch between someVar and return-vec")
  (c-t-assert (or (= someFunction #'+) (= someFunction #'min) (= someFunction #'max)) "only #'+, #'min or #'max are accepted operations for reduce-to-1-atomic")

  `(let ((atomic-op (get-atomic-equivalent ,someFunction)))
     (declare (grid-level))
    ; after this the globalScratchVec will one value per group.
    (reduce-to-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,localScratchVec)

    ; atomic combination
    (when-thread-in-group-is 0
      (funcall atomic-op (~ ,return-vec 0) ,someVar)))) 
```

#### reduce-to-1-cas 📝

`(reduce-to-1-cas someFunction <someVar> identity &out return-vec  &optional localScratchVec)`

`reduce-to-1-cas` is a reduction of a variable like the others, but it is a single pass operation.
No "second stage" kernel is needed.  It reduces all threads in all workgroups down to one single value.
That value is stored in `return-vec` which is a required argument. It should be a vector of length 1 (ie, a `single-result`)

Unlike `reduce-to-1-atomic` , which only works with a few operations, `reduce-to-1-cas` can work with ANY commutative binary operation.
It does this via atomic compare and swap (via `atomic-binop!`) which, while flexible, might not always be the most performant solution.


##### optional scratch vector
This routine accepts an optional scratch vector argument  `localScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / (get-warp-size)` ). `(get-warp-size)` is usualy 32.


- After the operation completes, the state of `localScratchVec` is indeterminant. 
- `reduce-to-1-cas` returns nil.
- After the operation the value of  `<someVar>` in any thread is indeterminant.
- `result-vec` will hold the value of the reduction.



Possible Implementation
```
;; -- reduce-to-1-cas --
(defmacro reduce-to-1-cas (someFunction someVar identity return-vec
                              &optional (localScratchVec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup :msg message))
                              &key message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (is-type-of someVar (element-type return-vec)) "type mismatch between someVar and return-vec")
  `(progn
    (declare (grid-level))
    ; after this the globalScratchVec will one value per group.
    (reduce-to-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,localScratchVec)

    ; atomic combination
    (when-thread-in-group-is 0
      (atomic-binop! (~ ,return-vec 0) ,someFunction ,someVar))))
```

#### reduce-to-1-cont 📝
`(reduce-to-1-cont someFunction <someVar> identity continuation-kernel-name &optional globalScratchVec localScratchVec)`

`reduce-to-1-cont` is quite different than the other reduction macros.  It performs the first part of a reduction,
reducing within the workgroup, storing the result in a global scratch vector.

But it also defines a new kernel which will then handle the second part of the reduction. And THAT kernel
is invoked with the same two scratch vectors and a one element result vector.  
The result of the final reduction will be stored in ITS `result-vec` argument.

Note that the second "continuation kernel" will be hoisted with a quite different configuration from
the one that `reduce-to-1-cont` is in. That kernel's workgroup size will be the same size (or bigger) as
the global scratch vector.

Also note that the `reduce-to-1-cont` macro requires that both `someFunction` and `identity` be compile-time identifiable. 
The compiler will emit and error if it cannot identify them.


##### optional scratch vectors
This routine accepts two optional arguments.  `localScratchVec` and `globalScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector`  that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / (get-warp-size)` ). `(get-warp-size)` is usualy 32.

`reduce-to-1-cont` also accepts an optional `globalScratchVec`. Crisp will generate it for you if you do not provide it.  
If you want to provide it yourself, it should be a `vector` whose `element-type` is the same as `<someVar>` , 
its address space MUST be `:global` and it's size is the number of workgroups 
which can be calculated as `M` where `M = global_work_size / local_work_size`. 




Possible Implementation
```
;; -- reduce-to-1-cont --
(defmacro reduce-to-1-cont (someFunction someVar identity continuation-kernel-name
                             &optional (globalScratchVec (make-scratch-vector (type-of someVar) :match-num-workgroups :address-space :global))
                                       (localScratchVec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup))) 
   (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
   (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
   `(let-kernel ((continuation-k  (l-s-v g-s-v result-cell)
                  (declare (kernel-name ,continuation-kernel-name)
                           (type l-s-v (scratch-vec-type (type-of ,someVar)))
                           (type g-s-v (scratch-vec-type (type-of ,someVar) :global))
                           (type result-cell (cell (type-of ,someVar)))
                           (local-size :derive-from g-s-v :msg (string-concat ,continuation-kernel-name "requires a local_work_size at least as big as the global-scratch-vector")))
                      (let ((num-items (length~ g-s-v))
                            (local-id (get-local-id))
                            ;; Each thread in the workgroup loads one partial result.
                            ;; If there are more threads than items, inactive threads get the identity.
                            (val (if (< local-id num-items)
                                      (~ g-s-v local-id)
                                      ,identity)))
                        
                        ;; Perform a standard workgroup reduction on the partial results.
                        (reduce-to-workgroup ,someFunction val ,identity :local-scratch-vec l-s-v)
                        
                        ;; The final result is now in 'val' of all wg threads.
                        ;; To avoid contention, only thread 0 writes the final result to the output vector.
                        (when (= local-id 0)
                          (set! (~ result-cell) val))) ))

      (declare (grid-level))
      ; after reduce-to-workgroup the globalScratchVec will one value per group.
      (reduce-to-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,localScratchVec :result-vec ,globalScratchVec)
      
       ;; this isn't a real invocation. It just demonstrates to the hoisting code 
       ;; HOW this function expects the "continuation" kernel to be called.
      (launch-kernel (continuation-k ,globalScratchVec ,localScratchVec (allocate-cell (type-of ,someVar)))))  
      
```


