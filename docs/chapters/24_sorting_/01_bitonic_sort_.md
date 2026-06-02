## Bitonic Sort ⚠️


Crisp provides a "toolkit" for bitonic sort.  If the sort can be performed by a single workgroup, then there are functions for that.
But if the sort is occurring across a vector larger than than, then a multi-stage approach is required.


In the first stage, you hoist/enqueue a kernel which will invoke one of the `bitonic-sort-workgroup` functions. Crisp provides premade kernel definitions for this if you require no other processing.

In the second stage, you hoist a `bitonic_merge_pass` kernel repeatedly until the sort is completed.

### psuedo demonstration

#### generate the kernels
```
;; generate kernel that sorts in place a vector of floats using :compact alignment
(gen-bitonic_sort_workgroup_in_place float :compact "stage_one_kernel")

;; generate the merge kernel
(gen-bintonic_merge_pass float :compact "stage_two_kernel")
```

#### load and enqueue the first kernel

This is a simplified Python example of hoisting the first kernel.

```
import crisp_runtime
import numpy as np

# --- Setup ---
# 1. Load the kernels you generated. The runtime finds them by the names you provided.
stage_one_kernel = crisp_runtime.load_kernel("stage_one_kernel")
stage_two_kernel = crisp_runtime.load_kernel("stage_two_kernel") # Loaded for the next phase

# 2. Prepare data on the host (the application's responsibility)
# For this example, an array of 1024 elements
host_data = np.array(np.random.rand(1024), dtype=np.float32)
data_size = host_data.nbytes

# 3. Create GPU buffers
buffer = crisp_runtime.create_buffer(host_data)

# --- Launch Kernel 1 ---
# 4. Set kernel arguments by name
stage_one_kernel.set_arg("data", buffer)

# 5. Determine launch configuration and enqueue
workgroup_size = 256 # Must be a power of 2 for this algorithm
global_size = host_data.size
stage_one_kernel.launch(queue, global_size, workgroup_size)

# The host would then wait for the queue to finish before starting Stage 2.
```

#### loop the second kernel

```
# loop through the merge stages.
j = workgroup_size * 2
while j <= data_size:
    k = j / 2
    while k > 0:
        # Launch the simple merge kernel for each pass
        stage_two_kernel.launch(queue, data, j, k)
        k = k / 2
    j = j * 2
``` 


### `bitonic-sort-workgroup`

```
(bitonic-sort-workgroup data-in data-out &key keyF)
(bitonic-sort-workgroup! data &key keyF)
(bitonic-sort-soa-workgroup <property> soa-data-in soa-data-out)
(bitonic-sort-soa-workgroup! <property> soa-data)

(gen-bitonic_sort_workgroup  elementT alignment kernelName &key keyF)
(gen-bitonic_sort_workgroup_in_place elementT alignment kernelName &key keyF)
(gen-bitonic_sort_soa_workgroup structT property alignment kernelName)
(gen-bitonic_sort_soa_workgroup_in_place structT property alignment kernelName)
```

For both `vector` and `soa-vector` there are two variants of bitonic sorting for workgroups. One takes both input and output data, and the
other performs the sort in place and takes just one data argument.

For all variants, the `local_work_size` MUST be a power of 2. 

The `soa-vector` variants key the sorting off a property. The property named must be an `is-orderable?` type.
If the property access has an overload for `soa-vector` then that overload will be used.

The `vector` variants support an optional `keyF` function `#(T => U) (type-is U #:is-orderable?)`.  Typically
a `keyF` would be used if the `vector` was one of some struct (like `point`) and `keyF` would then 
be a property retrieval function (like `x~`). But technically, the `keyF` can be anything so long as it 
returns an orderable value (for example, it could add the `x` and `y` values of the point and return their sum).
The astute reader will observe that could be done with an overload property function as well. 

Lastly, note for `vector` of structs, that the Crisp developer can choose between overloading `>` and `<` 
for some struct, using a custom `keyF` function, using a property access function `~x`, or and overloaded property
access function, to influence or intercept the ordering. 

But for the `soa-vector` variant, beyond simply specifying the property to key off, the only 
intercept is via an overload that includes `soa-vector`.


The core operation in Bitonic Sort is a simple compare-and-swap. The entire algorithm is just a series of 
these compare-and-swap steps organized into a perfectly predictable, geometric pattern.

When bitonic sorting, we repeatedly merge "bitonic sequences" (sequences that first increase then decrease, or vice-versa) into larger sorted sequences.
We do this in a highly choreographed fashion. Every step we perform the same simple move (compare-and-swap with a partner), 
but the distance to the partner changes in a fixed sequence (1 step away, then 2 steps away, then 4, etc.). 
The pattern is the same regardless of what the input numbers are.
When swapping, there is a sorting direction. `direction == true` for an ascending sort, and `direction == false` for descending one. 


A possible implementation might be

```
;; helper function
(with-template-type (T U) ; T is element type, U is key type
  ;; U must be orderable, T doesn't have to be if keyF is provided.
  (declare (type-is U #'is-orderable?))

  ;; -- bitonic-compare-and-swap --
  (def-function bitonic-compare-and-swap (local-vec idx1 idx2 direction &optional (keyF nil))
    (declare #((vector T) ulong ulong bool &optional #(T => U) => nil))
    (let ((val1 (~ local-vec idx1))
          (val2 (~ local-vec idx2)))

      ;; extract keys if keyF is provided, otherwise use the values themselves
      (let ((key1 (if keyF (funcall keyF val1) val1))
            (key2 (if keyF (funcall keyF val2) val2)))

        ;; Compare the keys
        (when (if direction (> key1 key2) (< key1 key2))
          ;; Swap the original full values (structs)
          (set! (~ local-vec idx1) val2)
          (set! (~ local-vec idx2) val1)))))

;; out of place sort
(with-template-type (T A)
  ;; Constraint relaxed: T only needs to be orderable IF keyF is NOT provided.
  ;; The compiler/constraint system needs to handle this conditional constraint.
  (declare (value-is A #'is-alignment?))

  -- bitonic-sort-workgroup --
  (def-function bitonic-sort-workgroup (data-in data-out &key keyF)
    (declare (local-size :set-to 256 :msg "local-work-size should be a power of 2 for bitonic-sort-workgroup")
             #((vector T :address-space :global) (vector T :address-space :global) 
                &key #'(T => #_is-orderable?) => nil))
    (let ((N   (get-local-linear-size)) ;; should be power of 2.
         (shared-array (make-scratch-vector T :match-workgroup-size))
         (global-id (get-global-id))
         (local-id (get-local-id)))
      (r-t-assert-0 (is-power-of-2 N) "local_work_size should be a power of 2")
      ;; load data from global to shared memory 
      ;; Each thread loads one element. For simplicity, assume N = global_size
      (when (< global-id N) ;; Boundary check for global data
        (set! (~ shared-array local-id) (~ data-in global-id)))
      (local-barrier)

      ;; perform Bitonic Sort
      ;; Outer loop: Builds increasingly large bitonic sequences
      ;; 'j' represents the size of the bitonic sequence being formed
      (do-power-step (j N)  ; Iterates j = 1, 2, 4, ... N/2
        ;; Inner loop: Merges bitonic sequences of size 'j'
        ;; 'k' represents the sub-sequence length to compare (j/2, j/4, ... 1)
        (dec-times-by-half (k (/ j 2))
          ;; Determine sorting direction for this phase
          ;; The first half of the sequences sort ascending, second half  descending
          (let ((direction (> (bit-and local-id (+ j j)) 0))) ; Determines if this half sorts UP or DOWN
                (partner-id (bit-xor local-id k))) ; Partner is 'k' distance away

            (when (< partner-id N) ; Ensure partner ID is within bounds (for non-power-of-2 sizes)
              (bitonic-compare-and-swap shared-array local-id partner-id direction keyF))) 
          (local-barrier)))

      ; store sorted data from shared to global memory
      (when (< global-id N) ;; Boundary check for global data
        (set! (~ data-out global-id) (~ shared-array local-id)))
      (local-barrier)))

;; in place sorting
(with-template-type (T A)
  ;; Constraint relaxed: T only needs to be orderable IF keyF is NOT provided.
  ;; The compiler/constraint system needs to handle this conditional constraint.
  (declare (value-is A #'is-alignment?))

  ;; -- bitonic-sort-workgroup! --
  (def-function bitonic-sort-workgroup! (data &key keyF)
    (declare #((vector T :address-space :global A) &key (function T => #_is-orderable?) => nil))
    (bitonic-sort-workgroup data data :key keyF)))


;; Kernels. These don't use the key. Define your own if you need to set one.
(with-template-type (T A)
  (declare (type-is T #'is-orderable?) (value-is A #'is-alignment?))

  -- bitonic_sort_workgroup --
  (def-kernel bitonic_sort_workgroup (data-in data-out)
    (declare #((vector T :address-space :global) (vector T :address-space :global) => nil))
    (bitonic-sort-workgroup data-in data-out)))
    
(with-template-type (T A)
  (declare (type-is T #'is-orderable?) (value-is A #'is-alignment?))

  -- bitonic_sort_workgroup_in_place --
  (def-kernel bitonic_sort_workgroup_in_place (data)
    (declare #((vector T :address-space :global) => nil))
    (bitonic-sort-workgroup! data)))
```

### `bitonic_merge_pass`

```
(bitonic-merge-pass data j k &keyF)

(gen-bintonic_merge_pass elementT alignment kernelName &key keyF)
(gen-bintonic_soa_merge_pass structT property alignment kernelName)
```
The merge pass is provided as both a function you can use, and a kernel template that can be generated. 
The function takes 
It will generate a kernel that takes a data, j and k arguments. 
The generated hoisting code will demonstrate how to manipulate j and k
on each subsequent call.

```
   ;; generate the kernel we need
   (gen-bintonic_merge_pass ulong :compact "my_bintonic_merge_pass_kernel")
```



Possible Implementation

```
(with-template-type (T A)
  ;; Constraint relaxed: T only needs to be orderable IF keyF is NOT provided.
  ;; The compiler/constraint system needs to handle this conditional constraint.
  (declare (value-is A #'is-alignment?)) 

  ;; -- bitonic-merge-pass --
  (def-function bitonic-merge-pass (data j k &key keyF)
    (declare #((vector T :address-space :global :align A) ulong ulong &key #'(T => #_is-orderable?) => nil))

    (let ((i (get-global-id)))
      
      ;; 1. Determine the sorting direction for this thread.
      ;; This logic splits the array into regions that sort ascending
      ;; and regions that sort descending to form the next bitonic sequence.
      (let ((direction (> (bit-and i j) 0)))

        ;; 2. Find the partner thread to compare-and-swap with.
        (let ((partner-id (bit-xor i k)))
          
          ;; 3. Guard: Ensure each pair is processed only ONCE, by the thread
          ;;    with the lower index. This prevents a "double swap".
          (when (< i partner-id)
            (let ((val1 (~ data i))
                  (val2 (~ data partner-id))
                  (key1 (if keyF (funcall keyF val1) val1))
                  (key2 (if keyF (funcall keyF val2) val2)))
              
              ;; 4. Perform the compare-and-swap based on the direction.
              (when (if direction
                        (> key1 key2)   ; Ascending sort for this region
                        (< key1 key2))  ; Descending sort for this region
                (set! (~ data i) val2)
                (set! (~ data partner-id) val1)))))))))

;; kernel doesn't take a key. Define your own if you wish to use one.
(with-template-type (T A)
  (declare (type-is T #'is-orderable?) (value-is A #'is-alignment?)) 

  ;; -- bitonic_merge_pass --
  (def-kernel bitonic_merge_pass (data j k)
    (declare #((vector T :address-space :global :align A) ulong ulong => nil))
    (bitonic-merge-pass data j k)))
```

### Don't Make Me Think `gen-bitonic-sort-vector`

```
(gen-bitonic-sort-vector elementT alignment) ;;  &key keyF
(gen-bitonic-sort-soa-vector elementT alignment)

(gen-bitonic-sort-vector! elementT alignment) ;;  &key keyF
(gen-bitonic-sort-soa-vector! structT property alignment)
```

If you don't want a toolkit, Crisp provides some "orchestrations" that will sort the vector.  
If generated, then the two kernels will be compiled and the hoisting example code will correctly show
how to calculate `j` and `k` and enqueue the merge pass until done.  


`soa-vector` variants of these two orchestrations are provided as well. 


Possible implementation.
```
(with-template-type (T L)

  ;; bitonic_sort_vector_in_place
  (def-kernel bitonic_sort_vector_in_place (vec)
    (declare #((vector T :address-space :global :length L)))
    (bitonic-sort-workgroup vec vec)))



(with-template-type (T L)

  ;; bitonic-sort-vector!
  (def-orchestration bitonic-sort-vector!
    (launch-sequential (gen-bitonic_sort_vector_in_place T L "bitonic_sort_vector_in_place_${T}_${L}"))

    ; +wg-size+ is available as a constant in def-orchestration

    (do-times-by-doubling (j (* 2 +wg-size+))
      (do-times-by-half (k (/ j 2))
        (launch-sequential ((gen-bitonic_merge_pass T L "bintonic_merge_pass_${T}_${L}")
                              bitonic_sort_vector_in_place_T_L::vec j k))))))


```


