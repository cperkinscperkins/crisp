# `inclusive-scan-workgroup` 📝


The sister to `exclusive-scan-workgroup`, its output at any index is the sum of the elements up to _and including_ `i`.

```
Output: #(0 1 1 2 3 3)
```

#### Possible Implementation

This is a possible implementation of `exclusive-scan-workgroup` realized via a Belloch Scan:

```
;; -- exclusive-scan-workgroup --
(defmacro exclusive-scan-workgroup (local-vec)
  `(let ((local-id (get-local-id))
         (wg-size (get-local-linear-size)))
    (declare (workgroup-level))
     
     ;; first pass - the up-sweep (reduction tree)
     ;; In each step, we add the value from 2^d elements away.
     (do-power-step (stride wg-size)
      (when (>= local-id stride)
        (set! (~ ,local-vec local-id)
              (+ (~ ,local-vec local-id)
                (~ ,local-vec (- local-id stride)))))
       (sync-workgroup))

     ;; The last element now holds the total sum. We save it and clear
     ;; that slot to start the exclusive scan.
     (let ((total-sum (~ ,local-vec (- wg-size 1))))
       (when (= local-id (- wg-size 1))
         (set! (~ ,local-vec local-id) 0))
       (sync-workgroup)

       ;; second pass - down sweep
       ;; Now we work back down the tree, distributing the sums.
       (dec-power-step (stride wg-size)
        (when (>= local-id stride)
          ;; Swap and add values between a thread and its partner
          (let ((partner-idx (- local-id stride)))
            (let ((temp (~ ,local-vec partner-idx)))
              (set! (~ ,local-vec partner-idx) (~ ,local-vec local-id))
              (set! (~ ,local-vec local-id) (+ temp (~ ,local-vec local-id))))))
         (sync-workgroup))

       ;; The macro can return the total sum from the workgroup
       total-sum)))
```



