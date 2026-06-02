# Vector Conversion Operations ✅


The conversion operations operate on entire vectors of floats and microfloat blocks. A `quantize-to-...` and 
`dequantize-from-...` operation are defined for each invocation of `def-microfloat-block`.

### quantize-to-XXXX
```
(quantize-to-XXXX float-input-vec &out microfloat-block-vec)

(quantize-to-XXXX float-input-matrix &out microfloat-block-matrix)
```
`quantize-to-XXXX` takes either a vector (or matrix) of floats as an input arg, and a vector (or matrix) of microfloat blocks
as an output parameter.  

For 1D vectors note that length of the input vector is `count` times the length 
of the microfloat block output vector.

For 2D matrices, the length of each row of the input vector is `shape[1]` times the length of each
row of the microfloat block output matrix. 

These  are grid-level functions. 

Example:
```
(quantize-to-mf-celsius f32-input-vec mf-celcius-output-vec)
```

Possible Implementation
```
;; -- quantize-to-... --
(<F A MFB>
  (declare 
    (type-is F #'is-floating-point?)
    (value-is A #'is-alignment?)
    (type-is MFB #'is-microfloat-block?))

   ;; 1D
  (def-grid-function quantize-to-XXXX (input-vec &out output-mfb-vec 
                              &optional (scratch-vec (make-scratch-vector F (ceil-pow2 (count MFB)))))
    (declare #((in-vec F A) &out (out-vec MFB :compact)))
    (r-t-assert-0 (= (length~ input-vec) (* (count MFB) (length~ output-mfb-vec)))
                  "lengths don't match")
    (c-t-assert (<= (count MFB) +warp-size+) "microfloat-block must be smaller than warp-size elements")
    ;; 
    (thread-stride (length~ output-mfb-vec) (ceil-pow2 (count MFB)) (warp-num)
      ;; we may be loading a smaller tile than we declared to thread stride,
      ;; so we can't use the short version of load-tile. 
      (let ((identity-val (identity-of #'max F)))
        (load-tile input-vec scratch-vec identity-val '(warp-num) '((count MFB))) 
        (let ((max-val (reduce-vec-warp scratch-vec #'max identity-val)) ;;
              (scale-f (to (scale MFB) max-val))
              (target-block (~ output-mfb-vec warp-num)))
          (when-thread-in-warp-is 0 
            (set! (scale~ target-block) scale-f))
          (in-warp (lane-id)
            (when (< lane-id (count MFB))
              (set! (~ target-block lane-id) (to (base MFB) (/ (~ scratch-vec lane-id) max-val)))))))))

    ;; 2D
    (def-grid-function quantize-to-XXXX (input-tv &out output-mfb-tv 
                              &optional (scratch-vec (make-scratch-vector F (ceil-pow2 (num-cols MFB)))))
      (declare #((tensor 3 (in-vec F A)) &out (tensor 3 (out-vec MFB :compact))))
      (r-t-assert-0 (= (num-cols input-tv) (* (num-cols MFB) (num-rows MFB))) "confusing")
      (r-t-assert-0 (= (num-planes input-tv) (num-planes output-mfb-tv)) "number of planes not matching")
      (r-t-assert-0 (= (num-rows intput-tv) (num-rows output-mfb-tv)) "number of rows should match")
      

      ;; workgroup


            
                

```

### dequantize-from-XXXX
```
(dequantize-from-XXXX microfloat-block-vec &out float-input-vec )
```
`dequantize-from-XXXX` takes a a vector of microfloat blocks as an input arg
 and an output vector of floats as an output parameter.  Note that length of the output vector is `:count` times the length of the microfloat block input vector.

This is a grid-level function. 

Possible Implementation
```
;; -- dequantize-from-... --
(<MFB F A>
  (declare 
    (type-is F #'is-floating-point?)
    (value-is A #'is-alignment?)
    (type-is MFB #'is-microfloat-block?))

  (def-grid-function dequantize-from-XXXX (input-mfb-vec &out output-vec)
    (declare #((in-vec MFB :compact) &out (out-vec F A)))
    (r-t-assert-0 (= (length~ output-vec) (* (count MFB) (length~ input-mfb-vec)))
                  "lengths don't match")

    ;; be sure to "gen-" to-float for the desired F output type
    (loop-vector-stride output-vec (i)
      (let ((which-block index-in-block (floor i (count MFB)))
            (target-block (~ input-mfb-vec which-block))
            (value (to-float target-block index-in-block)))
        (set! (~ output-vec i) value)))))
```
            


