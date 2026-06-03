# reduce vector 📝


The previous reductions are general purpose tools that let you create algorithms that reduce over warps, workgroups, or all the threads.  
The `reduce-vec-XXXX` variants are different in that they are respondent to a `vector` (or a 1D `tensor`). 

All the vector reductions are "grid level" operations, meaning they cannot be nested in other grid level ops.


#### reduce-vec-first-stage 📝
`(reduce-vec-first-stage someFunction vec identity &out intermediateVec &optional localScratchVec)`

This variant reduces `vec` down to a `intermediateVec` vec which will hold
one reduction value per workgroup.  You can then enqueue a kernel with `reduce-vec-second-stage` and pass it `intermediateVec` to complete the reduction.

The `localScratchVec` should be the same size as the size of a workgroup (ie local work size). 

Possible Implementation
```
(<T A>
  (declare (value-is A #'is-alignment?))

  ;; -- reduce-vec-first-stage --
  (def-grid-function reduce-vec-first-stage (someFunction vec identity &out intermediateVec) 

    (declare #'((binop-type T) (in-vec T A) T &out (out-vec T A))
      (global-size :derive-from vec :strategy :strided))
    (r-t-assert-0 (= (length~ intermediateVec) (get-num-groups) "intermediatVec length must equal number of workgroups))

    (let ((sum identity))
      (loop-vector-stride vec (i)
       (set! sum (funcall someFunction sum (~ vec i)))))

    (reduce-to-workgroup someFunction sum identity :return-vec intermediateVec))))

```



#### reduce-vec-second-stage 📝

`(reduce-vec-second-stage  someFunction intermediateVec identity &out final-result &optional localScratchVec globalScratchVec)`

This variant has a different requirement than  `reduce-to-1-second-stage`: it is launched 
with just ONE workgroup, which must have the same number of threads as `intermediateVec` length.

##### optional scratch vectors
This routine accepts two optional arguments.  `localScratchVec` and `globalScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / (get-warp-size)` ). `(get-warp-size)` is usualy 32.

`reduce-vec-second-stage` also accepts an optional `globalScratchVec`. Crisp will generate it for you if you do not provide it.  
If you want to provide it yourself, it should be a `vector` whose `element-type` is the same as `<someVar>` , 
its address space MUST be `:global` and it's size is the number of workgroups 
which can be calculated as `M` where `M = global_work_size / local_work_size`. 


- when `reduce-vec-second-stage` completes, the state of the scratch vectors are indeterminant
- `final-result` will hold the final result of the reduction.


This is what an implementation of `reduce-vec-second-stage` might look like

```
;; -- reduce-vec-second-stage --
;; This kernel's only job is to run the final reduction.
;; It's launched with a single workgroup that must be large
;; enough to hold the intermediate data.
(<T A>
  (declare (value-is A #'is-alignment?))

  ;; -- reduce-vec-second-stage --
  ;; This kernel IS the final reduction.
  (def-grid-function reduce-vec-second-stage (someFunction intermediateVec identity
                                               &out final-result
                                               &optional (localScratch (make-scratch-vector T :match-workgroup-size)))
    (declare #'((binop-type T) (in-vec T A) T &out (single-result T)
                                         &optional (scratch-vec-type T))
             (grid-level)
             ;; launch just one workgroup, big enough to accomodate intermediateVec
             (num-groups :max 1)
             (local-size :derive-from intermediateVec :strategy :one-thread-per))

    (let ((local-id (get-local-id))
          (N (length~ intermediateVec)))
      
      (when (< local-id N)
        (set! (~ localScratch local-id) (~ intermediateVec local-id)))
      (local-barrier)

      (let ((val (if (< local-id N) (~ localScratch local-id) identity)))
        (reduce-to-workgroup someFunction val identity)
        (set-result! final-result val)))))
```

#### reduce-vec-warp 📝

`(reduce-vec-warp someFunction vec identity) => result`

`reduce-vec-warp` is NOT a general purpose vec reduction routine. It uses warp-level functions
to reduce, but cannot reduce any vector whose length is greater than `(get-warp-size)` (32).

Note that unlike most reductions, this is NOT a grid-level function.

This function is very handy for operation on certain "small" data types, like a `microfloat-block` (see [below](#low-precision-floats-microfloats))

Possible Implementation
```
(<T A>
  (def-function reduce-vec-warp (someFunction vec identity)
    (declare #'((binop-type T) (in-vec T A) T => T))
    (in-warp (lane-id)
      (let ((len (length~ vec))
            (v (if (< lane-id len)  (~ vec lane-id) identity)))
        ;; reduce-to-warp broadcasts. If that changes,
        ;; then be sure to sync this as well (screen for lane-id==0, etc)
        (reduce-to-warp someFunction v identity)))))
```


#### reduce-vec-atomic 📝

`(reduce-vec-atomic  someFunction vec identity &out return-vec &optional localScratchVec)`

The `reduce-vec-atomic` variant has the same limitations as `reduce-to-1-atomic`: 
`someFunction` must be one of three commutative operations: `+`, `min` or `max`
that have `atomic-XXXX!` counterparts.

- `#'+`
- `#'min`
- `#'max`

##### optional scratch vector
This routine accepts an optional scratch vector argument  `localScratchVec`.

If the `localScratchVec` optional argument is not provided, Crisp will generate it for you.
If you wish to provide it, it should be a `vector` that is writeable local memory. 
Its size should be the number of warps in a single workgroup (ie `sz = local_work_size / (get-warp-size)` ). `(get-warp-size)` is usualy 32.


- After the operation completes, the state of `localScratchVec` is indeterminant. 
- `result-vec` will hold the value of the reduction. 


Possible Implementation
```
;; -- reduce-vec-atomic --
(<T A>
  (declare (value-is A #'is-alignment?))

  (def-grid-function reduce-vec-atomic (someFunction vec identity &out return-vec
                                &optional (localScratchVec (make-scratch-vector T :match-num-warps-per-workgroup)))
    (declare #'((binop-type T) (in-vec T A) T &out (single-result T) &optional (scratch-vec-type T))
      (global-size :derive-from vec :strategy :strided))

    (c-t-assert (or (= someFunction #'+) (= someFunction #'min) (= someFunction #'max)) "only #'+, #'min or #'max are accepted operations for reduce-vec-atomic")
    
    (let ((var identity)
          (len (length~ ,vec)))
        (declare (uniform len))
        (loop-vector-stride vec (i)
          (set! var (funcall someFunction var (~ vec i)))))
        (reduce-to-1-atomic someFunction var identity return-vec localScratchVec)))

  
```


#### reduce-vec-cas 📝

`(reduce-vec-cas  someFunction vec identity return-vec &optional localScratchVec)`

This variant uses `reduce-to-1-cas` for the final reduction stage, which means than an
atomic compare and swap is used to force the order of the reduction. While this is most flexible
of the vector reductions, it might not always be the most performant solution. 

- After the operation completes, the state of `localScratchVec` is indeterminant. 
- `result-vec` will hold the value of the reduction. 

Possible Implementation
```
;; -- reduce-vec-cas --
(<T A>
  (declare (value-is A #'is-alignment?))

  (def-grid-function reduce-vec-cas (someFunction vec identity &out return-vec
                                &optional (localScratchVec (make-scratch-vector T :match-num-warps-per-workgroup)))
    (declare #'((binop-type T) (in-vec T A) T &out (single-result T) &optional (scratch-vec-type T))
            (global-size :derive-from vec :strategy :strided))

    (let ((var identity)
          (len (length~ ,vec)))
        (declare (uniform len))
        (loop-vector-stride vec (i)
          (set! var (funcall someFunction var (~ vec i)))))
        (reduce-to-1-cas someFunction var identity return-vec localScratchVec)))

```

#### reduce-vec-cont 📝

`(reduce-vec-cont  someFunction vec identity continuation-kernel-name &optional localScratchVec globalScratchVec)`

This variant uses `reduce-to-1-cont` to perform the final reduction of the vector.  A second "continuation kernel"
will be generated to complete the reduction operation.

Possible Implementation
```
;; -- reduce-vec-cont --
(<T A>
  (declare (value-is A #'is-alignment?))

  (def-grid-function reduce-vec-cont (someFunction vec identity continuation-kernel-name
                              &optional (localScratchVec (make-scratch-vector T :match-num-warps-per-workgroup))
                                        (globalScratchVec (make-scratch-vector T :match-num-workgroups :address-space :global)))
    (declare #'((binop-type T) (in-vec T) T string &optional (scratch-vec-type T) (scratch-vec-type T :global))
                (global-size :derive-from vec :strategy :strided))

    (let ((var identity)
          (len (length~ vec)))
      (declare (uniform len))
      (loop-vector-stride vec (i)
        (set! var (funcall someFunction var (~ vec i))))
      (reduce-to-1-cont someFunction var identity continuation-kernel-name localScratchVec globalScratchVec))))
```


#### binop-type 📝

`binop-type` is a type constructor that takes a type `T` and returns the function type `#(T T => T)`.


##### Commutativity
Note that unlike `reduce` in some other languages that are meant for CPUs as opposed to GPUs, the `reduce-` variants in Crisp do not guarantee any sort of order for execution. 
This means that non-commutative operations like subtraction and division will not work.
But they still work fine with commutative operations like addition, multiply, minimum and maximum. 
Additionally any function defined with `def-function` can be used with the reduction, but it will only work
correctly if it is commutative, where  `(someF a b)` is equivalent to `(someF b a)`. 

