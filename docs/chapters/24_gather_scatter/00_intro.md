# Gather / Scatter


A very common practice in GPU programming is gathering and scattering.

The "gather" operation is like shopping in a big store with a list of locations and a basket.
At every location, the item is taken from the shelf and put into the basket.

The "scatter" operation is the reverse.  With basket in one hand and the list of locations in the other, you go through the store putting items onto the shelf at that location. 

Care must be taken when "scattering" that no location is in the list twice. Otherwise a race
will occur. This can possibly be addressed with an atomic operation (slow), but the better
solution is to just not make that mistake. 

Also note that both gather (reading `big-source-vec`) and scatter (writing `big-dest-vec`) involve uncoalesced memory access if the `index-vec` is irregular, which can impact performance.

```
(with-template-type (T)

  ;; -- gather-all --
  (def-grid-function gather-all (big-source-vec index-vec &out basket-vec)
    (declare #((vector T :align A) (vector ulong) &out (result-vec-type T)))
    (r-t-assert-0 (<= (length~ index-vec) (length~ basket-vec)) "basket-vec cannot be smaller than index-vec")
    (let ((limit (length~ big-source-vec)))
      (loop-vector-stride index-vec (i)
        (let ((loc (~ index-vec i)))
          (when (< loc limit)
            (let ((val (~ big-source-vec loc)))
              (set! (~ basket-vec i) val)))))))

  ;; -- scatter-all! --
  (def-grid-function scatter-all! (basket-vec index-vec &out big-dest-vec)
    (declare #((vector T) (vector ulong) &out (result-vec-type T)))
    (r-t-assert-0 (<= (length~ index-vec) (length~ basket-vec)) "basket-vec cannot be smaller than index-vec")
    (let ((limit (length~ big-dest-vec)))
      (loop-vector-stride index-vec (i)
        (let ((val (~ basket-vec i))
              (loc (~ index-vec i)))
          (when (< loc limit)
            (set! (~ big-dest-vec loc) val)))))))
```

### `find-indices`

```
(find-indices big-vector predicateF &out result-vec count-vec)
```

`gather-all` and `scatter-all!` are great, but where does one get an `index-vec` shopping list?

Say hello to `find-indices`.  Find indices take a vector and predicate function and it'll record
the results in a result-vec, and a count-vec that tells you exactly how many results were found.
If there are more results than fit in `result-vec` that is fine, they simply aren't recorded. 
But the count in `count-vec` is correct regardless.


```
;; SLOW - DO NOT USE
(with-template-type (T)

  ;; -- find-indices-naive --
  (def-grid-function find-indices-naive (big-vector predicateF &out result-vec count-vec)
    (declare #((vector T) predicate-type &out (vector T) (vector ulong :size 1)))
    (let ((limit (length~ result-vec)))
      (loop-vector-stride big-vector (i)
        (when (funcall predicateF (~ big-vector i))
          (let ((c (atomic-inc! (~ count-vec 0))  ; <-- kiss your performance goodbye
            (when (< c limit)
              (set! (~ result-vec c) i)))))))))

```

```
(with-template-type (T A) ; T = element type, A = alignment
  (declare (value-is A #'is-alignment?))

  ;; -- find-indices --
  (def-grid-function find-indices (input-vec predicateF
                                    &out result-index-vec ; Output: indices (ulong)
                                    &out result-count-vec) ; Output: final count (ulong, size 1)
    ;; Declare the function signature
    (declare #((vector T :address-space :global :access :readable :align A) ; Input data vector
               (predicate-type T) ; Predicate function #(T => bool)
               &out (vector ulong :address-space :global :access :writeable :align A) ; Output index vector
               &out (vector ulong :address-space :global :access :writeable :align :std140 :length 1) ; Output count vector
               => nil)
             ;; Declare optional local memory buffers for the scan algorithm
             &optional (local-flags (make-scratch-vector uint :match-workgroup-size))
                       (local-scan-results (make-scratch-vector uint :match-workgroup-size))
                       (local-info (make-scratch-vector uint 2))) ; For wg_total and wg_offset

    ;; first step - detect local matches
    (let ((is-a-match nil) ; Per-thread flag to store match result
          (global-id (get-global-id))
          (local-id (get-local-id)))

      ;; Check if within bounds and apply predicate
      (when (< global-id (length~ input-vec))
        (set! is-a-match (funcall predicateF (~ input-vec global-id))))

      ;; Write 1 for match, 0 for miss to local memory
      (set! (~ local-flags local-id) (select-if is-a-match 1 0))
      (local-barrier) ; Ensure all flags are written before scanning

    ;; next perform exclusive scan on the flags to get local indices
    (let ((workgroup-total (exclusive-scan-workgroup local-flags)))
      ;; 'local-flags' now holds local indices [0, 0, 1, 1, 2...]

      ;; Leader thread saves the workgroup's total count to local memory
      (when (= local-id 0)
        (set! (~ local-info 0) workgroup-total)))
    (local-barrier) ; Ensure total count is visible before atomic add

    ;; then get global write offset
    ;; Only the leader thread performs the atomic operation
    (when (= local-id 0)
      ;; Atomically add this workgroup's total to the global counter
      ;; (The global counter must be initialized to 0 by the host)
      (let ((offset (atomic-add! (~ result-count-vec 0) (~ local-info 0))))
        ;; Share the obtained global offset with the workgroup via local memory
        (set! (~ local-info 1) offset)))
    (local-barrier) ; Ensure the global offset is visible to all threads before writing

    ;; fainally, write results (indices) to global mem
    ;; Only threads that found a match perform a write
    (when is-a-match
      ;; Calculate the final global write position
      (let ((final-write-pos (+ (~ local-flags local-id) ; Local index from scan
                                  (~ local-info 1))))     ; Global offset for the group

        ;; Bounds check against the result index vector size
        (when (< final-write-pos (length~ result-index-vec))
          ;; Write the INDEX (global-id), not the data value
          (set! (~ result-index-vec final-write-pos) global-id)))))))            
```


