# global-exclusive-scan 📝


Unfortunately, doing an exclusive scan on a really big vector is not a simple isolated operation. 
It starts with an upsweep operation, which is simple enough. That populates an output vec that is
divided into workgroup-sized sections with localized exclusive scan.  It also populates
a `block-sums` vector whose length is the number of workgroups. 

If that `block-sums` vector's length fits within the size of a single workgroup, then simply call
`exclusive-scan-workgroup` on it to order it. And then move onto the downsweep stage.
But if the `block-sums` is too long, then call `global-exclusive-scan-upsweep` on IT and get 
ANOTHER block sums that is shorter. Repeat as necessary until you finally get a blocksum that fits
in a workgroup.
The number of upsweep *P*asses can be calculated with this formula
$$P = \lceil \frac{\log(N)}{\log(W)} \rceil$$
Where:
- *P* is the number of "upsweep" passes (and, of course, downsweep passes as well)
- *N* is the length of the original input vector.
- *W* is the workgroup size (usually 256)

Then apply the `global-exclusive-scan-downsweep` algorithm with the blocksums and finally apply it 
to the output vector from the very first pass. 

Note that it is imperative that the workgroup-size and workgroup-count is the same for each matching "pair"
of upsweep / downsweep calls.

What could be simpler?

```
(<T A>
  (def-grid-function global-exclusive-scan-upsweep (input-vec &out output-vec block-sums
                                    &optional (scratch-vec (make-scratch-vector T :match-workgroup-size)))
    (declare #'((in-vec T A) &out (out-vec T A) (out-vec T A) &optional (scratch-vector T))
      (global-size :derive-from input-vec :strategy :strided))
    (r-t-assert-0 (= (length~ block-sums (get-num-workgroups))) "block-sums length should be the number of workgroups")
    (r-t-assert-0 (= (length~ input-vec) (length~ output-vec)) "in/out vec lengths don't match")
    (hardware-stride input-vec :workgroup-idx (wg-idx)
      (load-tile input-vec scratch-vec)
      (let ((total (exclusive-scan-workgroup scratch-vec))) ;; scratch-vec now reordered. local-barrier within exclusive-scan-wg
        (when (= 0 (get-local-id))
          (set! (~ block-sums wg-idx) total)))
      (local-barrier)
      (store-tile scratch-vec output-vec)))

  (def-grid-function global-exclusive-scan-downsweep (input-vec block-sums &out output-vec)
    (declare #'((in-vec T A) (in-vec T A) &out (out-vec T A))
      (global-size :derive-from  input-vec :strategy :strided))
    (r-t-assert-0 (= (length~ input-vec) (length~ output-vec)) "in/out vec lengths don't match")
    (loop-vector-stride input-vec (i)
      (let ((val (~ input-vec i))
            (prefix (~ block-sums (get-group-id 0))))
          (set! (~ output-vec i) (+ val prefix))))))


;; All orchestrations are for "demo" purposes only, but that is especially true for this one.
;; We do two recursive upsweeps and two matching downsweeps. But the actual number of 
;; upsweeps and downsweeps required will depend on the size of your vector and the
;; size and number of workgroups available (see the formula above)
(<T A M>
  (def-orchestration global-exclusive-scan
    (let ((upsweep-kernel (gen-global-exclusive-scan-upsweep T A "${M}_upsweep_${T}"))
          (downsweep-kernel (gen-global-exclusive-scan-downsweep T A "${M}_downsweep_${T}"))
          (ex-scan-wg-kernel (gen-ex_scan_wg_kernel T A "${M}_ex_scan_kernel_${T}"))
          (IN (make-hoist-vector upsweep-kernel::input-vec))
          (OUT (make-hoist-vector upsweep-kernel::output-vec))
          (BLOCK-SUMS-1 (make-hoist-vector upsweep-kernel::block-sums))
          (SCRATCH (make-hoist-vector upsweep-kernel::output-vec))
          (BLOCK-SUMS-2 (make-hoist-vector ex-scan-wg-kernel::in-vec)))
      ;; we will sometimes pass a vector as BOTH input and output to modify it in place.
      (launch-sequential
        (upsweep-kernel IN OUT BLOCK-SUMS-1)
        (upsweep-kernel BLOCK-SUMS-1 SCRATCH BLOCK-SUMS-2) 
        (ex-scan-wg-kernel BLOCK-SUMS-2)
        (downsweep-kernel SCRATCH BLOCK-SUMS-2 BLCck-SUMS-1)
        (downsweep-kernel OUT BLOCK-SUMS-1 OUT)))))
    
```

