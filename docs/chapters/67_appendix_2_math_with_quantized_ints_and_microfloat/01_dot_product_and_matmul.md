# dot product and matmul 📝


These dot product and matmul implementations work for ALL types. 

```
;; -- dot-prod-seq --
(with-template-type (T Al)
  (declare  (value-is Al #'is-alignment))

  (def-function dot-prod-seq (A B)
    (declare #'((in-vec T Al) (in-vec T Al) 
                 => (accum T)))
    (let ((sum (identity-of #'+ (accum T))))
      (declare (type sum (accum T)))
      (dotimes (i (length~ A))
        (set! sum (+ sum (*! (~ A i) (~ B i))))) ;; widening multiplication *!
      (return sum))))


;; -- dot-prod-grid --
(with-template-type (T Al)
  (declare (value-is Al #'is-alignment))

  (def-grid-function dot-prod-grid (A B &out RESULT)
    (declare #'((in-vec T Al) (in-vec T Al) &out (single-result (accum T)))
      (global-size :derive-from A :strategy :strided))
    (when-thread-is 0
      (r-t-assert (= (length~ A) (length~ B)) "lengths must match")) 
    (let ((C-scratch (make-scratch-vector (accum T) Al :name "dot product"))
          (zero (identity-of #'+ (accum T))))  
      (map-stride #'*! (A B) C-scratch) ;; widening multiplication *!
      (reduce-vec-atomic #'+ C-scratch zero RESULT)))) ;; <-- this broadcasts


;; same TILE_DIM as used by convert-layout 
(def-const TILE_DIM 32 ulong) ; warp-size on most hardware

;; -- matmul --
(with-template-type (T Al)
 (declare (value-is Al #'is-alignment))

  (def-grid-function matmul (A B &out C)
    (declare #((matrix T) (matrix T) &out (matrix (accum T)))
             (local-size :set-to `(,TILE_DIM ,TILE_DIM)) 
             (global-size :derive-from C             
                          :strategy :tiled           
                          :tile-shape TILE_DIM       ; Tile size is TILE_DIM x TILE_DIM
                          :dims 2
                          :msg "Launch one workgroup per output tile of C"))

    (let ((tile-A (make-tile TILE_DIM (base T)))
          (tile-B (make-tile TILE_DIM (base T)))
          (local-id-x (get-local-id 0)) (local-id-y (get-local-id 1))
          (group-id-x (get-group-id 0)) (group-id-y (get-group-id 1))
          (acc (identity-of #'+ (accum T)))
      (declare (type acc (accum T)))

      ;; main loop over the tiles in the inner dimension
      (dotimes (tile-num (ceil (num-cols A) TILE_DIM))

        ;; adaptive, coalesced loading
        ;; Use the 'load-tile' macro to handle the complexity.
        (load-tile A tile-A group-id-y tile-num
                   :transpose (= (get-layout A) :col-major))

        (load-tile B tile-B tile-num group-id-x
                   :transpose (= (get-layout B) :row-major))
        
        (sync-workgroup)

        ;; This part is now simple and fast, both local tiles are row-major.
        (dotimes (k TILE_DIM)
          (set! acc (+ acc (*! (~ tile-A local-id-y k)  ;; widening multiplication
                              (~ tile-B local-id-x k)))))

        (sync-workgroup))

      ;; store final result. coalesced access
      (let ((c-row (+ (* group-id-y TILE_DIM) local-id-y))
            (c-col (+ (* group-id-x TILE_DIM) local-id-x)))
        (when (and (< c-row (num-rows C)) (< c-col (num-cols C)))
          (set! (~ C c-row c-col) acc))))))
```

<!-- NOTE 
  convolve-2d and mat-vec-mult are just more of the same.
  - output is (accum T)
  - use (identiy-of #'+ (accum T)) for 0 in most places.
  - use *! (widening multiplication) instead of *

-->


#### max-pool 📝

The `max-pool` algorithm requires `max` which is not supported by `microfloat-block` so
this algorithm only works with regular floats and quantized ints.

`max-pool` is a downsampling operation, essential in convolutional neural networks (CNNs). Its main job is to shrink a feature map (like an image) while preserving the most prominent features (the ones with the highest values).

It works by sliding a "window" (usually 2x2) across the input matrix and picking the single highest value from that window to be the only value in the new, smaller output matrix.

```
;; -- max-pool--
(<T A>
  (declare (type-is (supports-max? T))  ;; maybe (supports? #'max T) but maybe not.
           (value-is A #'is-alignment?))

  (def-grid-function max-pool (input-M win-w win-h &out output-M)
    (declare #'((in-matrix T A) uint uint &out (out-matrix T A))
              (global-size :derive-from output-M :strategy :strided))
    (r-t-assert-0 (and (= (num-cols input-M) (* win-w (num-cols output-M)))
                       (= (num-rows input-M) ( win-h (num-rows output-M))))
                       "input matrix size must be output matrix size times win dim")
    (r-t-assert-0 (and (> win-w 0) (> win-h 0)) "window must have extent")
    (thread-stride output-M :global-size (xo yo)
      (let ((x-in-start (* xo win-w))
            (y-in-start (* yo win-y))
        
            (max-val -INF)) ;; (identity-of #'max T)
       (dotimes (ky win-h)
        (dotimes (kx win-w)
          (let* ((x-in (+ x-in-start kx))
                 (y-in (+ y-in-start ky))
                 ;; Note: No bounds check needed if we trust the assert
                 (pixel-val (~ input-M y-in x-in)))
                ;; This works for both f32 and qint (B=B)
                (set! max-val (max max-val pixel-val)))))
        ;; store
        (set! (~ output-M yo xo) max-val)))))

;; Remark the whole "sometimes x y z order, othertimes z y x" bothers me
;; points are usually (x, y), but C++ A[y][x]  or (~ A y x)  

```


#### Average Pool 📝

`average-pool` is a downsampling operation, just like `max-pool`. It's a core component of most convolutional neural networks (CNNs).

Its job is to shrink a feature map (like an image) by sliding a window over it. But, instead of picking the single highest value from the window (what `max-pool` does), `average-pool` calculates the mathematical average of all values within that window.

This results in a "smoother," "softer" downsampling that preserves a generalized sense of the neighborhood rather than just its single most prominent feature.  

This version of `average-pool` works with any numeric type or quantized integers. There is
not a performent version for microfloat blocks. 


```
;; -- average-pool--
(<T A>
  (declare (value-is A #'is-alignment?)
    (or (type-is T #'is-numeric?)
        (type-is T #'is-quantized-int?)))

  (def-grid-function average-pool (input-M win-w win-h &out output-M
                                  &key zero-point scale)
    (declare #'((in-matrix T A) uint uint &out (out-matrix T A))
              (global-size :derive-from output-M :strategy :strided))
    (r-t-assert-0 (and (= (num-cols input-M) (* win-w (num-cols output-M)))
                       (= (num-rows input-M) (* win-h (num-rows output-M))))
                       "input matrix size must be output matrix size times win dim")
    (r-t-assert-0 (and (> win-w 0) (> win-h 0)) "window must have extent")
    (c-t-assert (when (is-quantized-int? T) (nor  (nullp zero-point) (nullp scale)))
                "using quantized int requires :zero-point and :scale keys ")
    (thread-stride output-M :global-size (xo yo)
      (let ((x-in-start (* xo win-w))
            (y-in-start (* yo win-y))
            (win-count  (* win-w win-h))
            (acc (identity-of #'+ (accum T))))
       (dotimes (ky win-h)
        (dotimes (kx win-w)
          (let* ((x-in (+ x-in-start kx))
                 (y-in (+ y-in-start ky))
                 ;; Note: No bounds check needed if we trust the assert
                 (pixel-val (~ input-M y-in x-in)))
              ;; ADD
              (set! acc (+ acc (to (accum T) pixel-val))))))
        ;; store
        (let ((acc-f (if+ (is-quantized-int? T)
                        (to-float-accum acc zero-point scale) ;; don't square scale
                       acc))
              (avg-val (/ acc-f win-count)))
          (set! (~ output-M yo xo) avg-val))))))
```


#### ReLU 📝

ReLU stands for Rectified Linear Unit. It's the most popular activation function in modern neural networks. Its job is to introduce non-linearity into the network, which is what allows it to learn complex patterns (otherwise, the whole network would just be one giant, simple matmul).

The operation itself is a simple element-wise function: `output = max(0, input)`

It acts as a one-way gate:
- If the input is positive, it passes through unchanged ( `ReLU(5.0)` is `5.0`).
- If the input is negative, it is "rectified" (clamped) to zero ( `ReLU(-5.0)` is `0.0`).

This function is both simple to write and performant for the basic math types and quantized integers. But there is no comparable for the microfloat blocks. This asymmetry is not usually a problem however, because `matmul` outputs the `accum` type, which for microfloats is just a 32 bit float.  And a matrix of regular floats works
great with ReLU or any of the other common activation functions. 

```
;; -- ReLU--
(<T A>
  (declare (value-is A #'is-alignment?)
         (type-is (supports-max? T)))
    
  (def-grid-function relu (input-M  &out output-M &key (zero-point (identity-of #'+ T)))
    (declare #'((in-matrix T A)  &out (out-matrix T A))
              (global-size :derive-from output-M :strategy :strided))
    (c-t-assert (when (is-quantized-int? T) (not  (nullp zero-point)))
                "using quantized int requires :zero-point key. The default value would be incorrect for that type.")
    (r-t-assert-0 (and (= (num-cols input-M) (num-cols output-M))
                       (= (num-rows input-M) (num-rows output-M)))
                       "input matrix size must be output matrix size should be same")
    (thread-stride input-M :global-size (x y)
      (set! (~ output-M y x) (max zero-point (~ input-M y x))))))
```

