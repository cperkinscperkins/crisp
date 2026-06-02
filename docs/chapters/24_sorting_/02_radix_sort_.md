# Radix Sort ⚠️


Like Bitonic Sort, Radix Sort is done with multiple kernels, but its structure is a loop 
of "histogram-scan-scatter" passes, not "sort-merge-merge-merge..." like bitonic.

The easiest way to understand Radix Sort is to think of it like sorting a huge pile of mail by zip code. You don't compare two envelopes directly. Instead:
- You first create piles for the last digit of the zip code (0-9).
- You go through all the mail, putting each envelope in the correct pile.
- You stack the piles back together in order (all the 0s, then all the 1s, etc.).
- You then repeat the entire process for the second-to-last digit, and so on, until the mail is fully sorted.

Radix Sort does this with the bits of your numbers.  It loops over three kernels: histogram, prefix-sum, and scatter.

### Radix Sort on the GPU

The entire process is a loop that has to be organized host side. For a 32-bit integer, you might loop 4 times, processing 8 bits in each pass. Inside this loop, the host orchestrates a sequence of kernel launches.

#### Step 1: The Histogram Kernel
The first kernel's job is to count the occurrences of each "digit" across the entire dataset.

How it works: Each workgroup computes a local histogram (e.g., a 256-element array for an 8-bit pass) in its fast shared memory. The leader of each workgroup then uses atomic-add! to add its local counts to a small global histogram buffer.

Result: A small array in global memory with the total count for each digit.

#### Step 2: The Prefix-Sum (Scan) Kernel
The second kernel's job is to turn the histogram counts into bucket offsets. It answers the question, "Where does the bucket for digit X begin in the final output array?"

How it works: Since the global histogram is very small (e.g., 256 elements), this is a tiny, fast kernel, often launched with just a single workgroup. It performs an exclusive scan on the histogram. (This step can sometimes even be done on the host CPU because the data size is negligible).

Result: A small array of "bucket pointers" in global memory.

#### Step 3: The Scatter (or Permute) Kernel
The third kernel's job is to actually move the data.

How it works: Each thread reads an element, looks at its current "digit," uses the bucket pointers from Step 2 to find the base address for that digit, and then uses a local counter to find its specific place within that bucket. It then writes the element to a new output buffer.

Result: A new global buffer where the data is sorted according to the current group of bits.

This new output buffer then becomes the input buffer for the next pass of the host-side loop. This is often called "ping-ponging" between two large buffers. After the final pass (on the most significant bits), the data is fully sorted.

### Radix Sort in Crisp


#### `histogram-pass`
```
 (histogram-pass input-vec bit-offset &out global-histogram  &optional local-histogram)
```

 - this routine requires that the `local_work_size` is set to 256
 - similarly the `global-histogram` vector parameter must consist of 256 `uint`
 - the `local-histogram` scratch vector is optional, it should be 256 `uint` as well. If not provided,
  Crisp will use the scratch vector side channel to fulfill it.


Possible Implementation
```
(def-constraint is-signed-integer? (T)
   (and (is-signed? T) (is-integer? T)))

;;
;; histogram-pass
;; 
(with-template-type (T A)
  (declare (type-is T #'is-numeric?) (value-is A #'is-alignment?))

  ;; -- histogram-pass --
  (def-grid-function histogram-pass (input-vec bit-offset &out global-histogram  
                                                     &optional (local-histogram (make-scratch-vector uint 256))
    (declare #((in-vec T A) uint &out (out-vec uint A 256)  &optional (scratch-vector-type T)))
              (local-work-size :set-to 256 :msg "local_work_size must be 256 for histogram kernel"))
              
    ;; setup
    (let ((local-id (get-local-id))
          (local-size (get-local-size)))

      ;; initialize local histogram
      ;; The workgroup must zero-out its local histogram. This is done in parallel.
      ;; Each thread clears a portion of the 256-element array.
      (set! (~ local-histogram local-id) 0)
      (local-barrier)

      ;; build local histogram
      ;; Each thread processes its slice of the large input vector.
      ;; note we have to handle floats and unsigned digits special to make sure 
      ;; they are bit-wise evaluable. 
      (loop-vector-stride input-vec (i)
        ;; a. Get the value from the input vector.
        (let ((initial-val (~ input-vec i))
              (base-val  #+(is-floating-point? T) (as-bits initial-val uint)
                          #-(is-floating-point? T) initial-val)
              (val    #+(is-signed-integer? T) (logxor base-val #x80000000)
                       #-(is-signed-integer? T) base-val))

          #+(is-floating-point? T)
          (when (is-negative? initial-val)
              (set! val (lognot val)))

          ;; b. Isolate the 8-bit "digit" we're sorting by in this pass.
          (let ((digit (bit-and (ash val (- bit-offset)) #xFF)))
            ;; c. Atomically increment the counter for that digit IN LOCAL MEMORY.
            ;;    Atomics on local memory are very fast.
            (atomic-add! (~ local-histogram digit) 1))))
      (local-barrier)

      ;; combine into local histogram
      ;; Now that the local histogram is complete, the workgroup adds its results
      ;; to the final global histogram.
      ;; Each thread is responsible for one bin of the local histogram.
      (when (< local-id 256)
        (let ((count-for-this-bin (~ local-histogram local-id)))
          (when (> count-for-this-bin 0)
            ;; Atomically add this workgroup's count for this bin to the global total.
            (atomic-add! (~ global-histogram local-id) count-for-this-bin)))) )))
```

### scan histogram pass

```
(scan-histogram global-histogram &out bucket-offsets)
```

The `global-histogram` that was the output of `histogram-pass` is the input of this routine.
And its output is a prefix-sum vector.


```
;;
;; scan-historgram
;;
(with-template-type (A)
  (declare (value-is A #'is-alignment?))

  ;; -- scan-histogram --
  (def-function scan-histogram (global-histogram &out bucket-offsets)
    (declare #((in-vec uint  A 256)
              &out (out-vec uint  A 256) => nil)
            ;; Ensure this kernel runs with only ONE workgroup of size 256
            (local-size :set-to 256 :strategy :exact)
            (global-size :set-to 256 :strategy :exact))

    (let ((local-id (get-local-id))
           ;; A buffer in fast local memory to perform the scan
          (local-scan-buffer (make-local-scratch-vector uint 256)))

      ;; load data from global to local
      ;; each thread loads one count from the global histogram
      (set! (~ local-scan-buffer local-id) (~ global-histogram local-id))
      (local-barrier) ; ensure load is complete before scan begins

      ;; perform Parallel Exclusive Scan in local memory 
      ;; uses the built-in primitive - modifies
      ;; 'local-scan-buffer' in place and returns the total sum (which is ignored)
      (exclusive-scan-workgroup local-scan-buffer)
      ;; no barrier needed here, scan primitive includes own internal barriers.

      ;; store results from local to global
      ;; Each thread writes one offset back to the global output buffer.
      (set! (~ bucket-offsets local-id) (~ local-scan-buffer local-id)))))
```


### scatter pass

```
(scatter-pass input-vec bucket-offset bit-offset &out output-vec)
```

Ping-Pong: This kernel reads from `input-vec` and writes to `output-vec`. The host needs to swap these buffers between passes.

Transformations: The `radix-transform` helper encapsulates the bitwise logic for signed integers and floats.

Local Rank (The Tricky Part): The local-rank-within-digit function is the most complex part. A high-performance implementation requires another clever scan algorithm within the workgroup. 

```
;;
;; scatter pass
;;
(with-template-type (T A)
  (declare (type-is T #'is-numeric?) (value-is A #'is-alignment?))

  ;; -- scatter-pass --
  (def-grid-function scatter-pass (input-vec bucket-offsets bit-offset &out output-vec)
    (declare #((in-vec T A) ; Input data
               (in-vec uint  A 256) ; Bucket offsets
              uint ; Current bit offset
              &out (out-vec T A))) ; Output data

    ;; setup shared memory
    (let ((wg-size (get-local-size))
           ;; Need space to store the data tile for this workgroup
          (local-data-tile (make-scratch-vector T :match-workgroup-size ))
           ;; Need space to store the 'digit' for each element in the tile
          (local-digits (make-scratch-vector uint :match-workgroup-size ))
           ;; Need space for the local scan (prefix sum) result for each thread
          (local-scan-indices (make-scratch-vector uint :match-workgroup-size))

          (local-id (get-local-id))
          (global-id (get-global-id)))

      ;; load data tile
      ;; Each thread loads one element into local memory.
      (load-local input-vec local-data-tile)
      

      ;; calculate digits and local scan
      ;; each thread determines its element's digit for this pass.
      (let ((initial-val (~ local-data-tile local-id))
            ;; Apply signed/float transformations (same as histogram kernel)
            (sortable-int (radix-transform initial-val)) ; Use a helper/macro  
            (digit (bit-and (ash sortable-int (- bit-offset)) #xFF)))

        (set! (~ local-digits local-id) digit)
        (local-barrier)

        ;; Perform a local scan on the digits to find the rank within the workgroup
        ;; Need a scan that counts occurrences of each digit.
        (let ((local-rank (local-rank-within-digit local-digits local-id)))
          (set! (~ local-scan-indices local-id) local-rank)))
      (local-barrier)

      ;; calculate global write position
      ;; Read the starting offset for this element's digit from the global offsets.
      (let ((global-bucket-offset (~ bucket-offsets (~ local-digits local-id)))
            (local-rank (~ local-scan-indices local-id)))

        (let ((final-write-pos (+ global-bucket-offset local-rank)))

          ;; write to global output
          ;; Write the ORIGINAL element value to its final sorted position for this pass.
          (when (< global-id (length~ input-vec)) ; Bounds check
            (set! (~ output-vec final-write-pos) (~ local-data-tile local-id))))))))

;;
;; get-unsigned-type
;;

;; -- get-unsigned-type --
(def-type-function get-unsigned-type (T)
  ;; Helper to determine the corresponding unsigned integer type
  (cond ((<= (sizeof T) (sizeof uint)) 'uint)
        (else 'ulong)))

;;
;; radix-transform
;;
;; we could also realize this as a series of overloads.
(with-template-type (T)
  ;; Ensure T is a type we can work with
  (declare (type-is T #'is-numeric?))

  ;; Determine the corresponding unsigned integer type (UintT) for the result
  (let ((UintT (get-unsigned-type T)))

    ;; -- radix-transform --
    (def-function radix-transform (value)
      ;; The function returns an unsigned integer of the same size as T
      (declare #'(T => UintT))

      (cond
        
        ((is-unsigned-integer? T)
         ;; No transformation needed, just ensure it's the right uint type if T was smaller
         (as UintT value))

        
        ((is-signed-integer? T)
         ;; Calculate the mask for the most significant bit (sign bit)
         (let ((msb-mask (ash 1 (- (* (sizeof T) 8) 1))))
           (declare (type msb-mask uint))
           ;; Flip the sign bit using XOR to map negatives below positives
           (logxor (as UintT value) msb-mask)))

        
        ((is-floating-point? T)
         ;; Bit-cast the float to an unsigned integer of the same size
         (let ((as-uint (as-bits uint value)))
           ;; Check if the original float value was negative
           (if (< value 0.0)
               ;; If negative, flip ALL bits to reverse their order
               (lognot as-uint)
               ;; If positive, add the sign bit offset (same as signed int XOR)
               (let ((msb-mask (ash 1 (- (* (sizeof T) 8) 1))))
                 (logxor as-uint msb-mask)))))

        ;; Should not be reached if T is numeric
        (else (c-t-error "Unsupported type for radix_transform"))))))

;;
;; local-rank-within-digit
;;
(with-template-type (A) ;; A is the alignment
  (declare (value-is A #'is-alignment?))
  ;; This function calculates the 0-based rank of a thread among threads
  ;; in the same workgroup that have the same digit for the current radix pass.
  ;; It uses fast atomic operations on local memory.

  ;; -- local-rank-within-digit --
  (def-function local-rank-within-digit (local-digits ;; Input: array (size=wg_size) of digits (0-255) for each thread
                                          local-id     ;; Input: this thread's local ID
                                          ;; Optional scratch space for atomic counters
                                          &optional (digit-counts (make-scratch-vector uint 256 :align A)))
    (declare #((vector uint :address-space :local) uint &optional (vector uint :address-space :local :align A :length 256) => uint))

    ;; initialize the shared counter array
    ;; Need to zero out the 256 counters. This can be done in parallel.
    ;; Assuming local_work_size >= 256. If not, this needs a loop.
    (when (< local-id 256)
      (set! (~ digit-counts local-id) 0))
    ;; Ensure all counters are zero before any thread proceeds.
    (local-barrier)

    ;; atomically increment and get rank
    ;; each thread reads its digit for the current pass.
    (let ((my-digit (~ local-digits local-id)))

      ;; Atomically increment the counter for that specific digit in local memory.
      ;; The 'atomic-add!' returns the value *before* the increment.
      ;; This previous value is exactly the 0-based rank needed.
      ;; (e.g. the first thread with digit '5' gets rank 0, the second gets rank 1, etc.)
      (let ((rank (atomic-add! (~ digit-counts my-digit) 1)))

        ;; synchronize
        (local-barrier)

        ;; return the calculated rank
        rank))))
```

### coordinating all three: histogram / san / scatter

Finally, after defining `histogram-pass`, `scan-histogram` and `scatter-pass` we
are ready to use Radix Sort. 

The most difficult part to grasp is that these three kernels are run repeatedly, 
8 bits at a time. The orchestration below demonstrates how to run them. 

Just use `(gen-radix-sort Type Alignment)` and the Crisp compiler will build the correct
kernels and the hoisting example code will walk through everything.

```
;;  the three passes and their param names, for reference.
;;  (histogram_pass input-vec bit-offset &out global-histogram  &optional local-histogram)
;;  (scan_historgram global-histogram &out bucket-offsets)
;;  (scatter_pass input-vec bucket-offsets bit-offset &out output-vec)


#
# radix-sort orchestration
#
(with-template-type (T A)
  (declare (type-is T #'is-numeric?) (value-is A #'is-alignment?))

  ;; -- radix-sort --
  (def-orchestration radix-sort
    ;; the goal is to start with the unsorted input-vec (that we'll pass to the first kernel, histogram-pass)
    ;; and finally end up with the sorted output-vec.

    (let ((histogram_pass_kernel (gen-histogram_pass T A "histogram_pass_kernel"))
          (buffer-A (make-hoist-vector histogram_pass_kernel::input-vec))
          (buffer-B (make-hoist-vector histogram_pass_kernel::input-vec :empty T)))

      (let ((num-passes (/ (* (sizeof T) 8) 8)) ;; why is this not just sizeof T?
            (N (* num-passes 8)))
        (dotimes (bit-offset N 8)
          (launch-sequential 
            (histogram_pass_kernel buffer-A bit-offset _)
            ((gen-scan_histogram A "scan_histogram") histogram_pass::global-histogram _)
            ((gen-scatter_pass T A)) scan_histogram::global-histogram scan_histogram::bucket-offsets bit-offset buffer-B)
          (swap-refs buffer-A buffer-B))) ;; <-- orchestration only routine. ping pong

      (let ((final-buffer (if (even? num-passes) buffer-A buffer-B)))
        ; present victory?
      ))))

```



