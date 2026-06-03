# Convolution 📝


```
;; -- convolve-2d --
(<T>
  (def-grid-function convolve-2d (input-m filter-m &out output-m)
    (declare #'((matrix T) (matrix T) &out (matrix T))
      (global-size :derive-from input-m :strategy :strided))
    (let ((width (num-cols input-m))
          (height (num-rows input-m))
          (f-width (num-cols filter-m))
          (f-height (num-rows filter-m))
          (f-center-x (floor f-width 2))
          (f-center-y (floor f-height 2)))
      (r-t-assert-0 (and (= width (num-cols output-m)) (= height (num-rows output-m)))
               "dimensions for input and output matrix must match")
      (thread-stride '(width height) :global-size (x y)
        (let ((acc (zero T)))
          (dotimes (ky f-height)
            (dotimes (kx f-width)
              ;; center filter on x,y
              (let* ((offset-x (- kx f-center-x)) ; e.g., 0-1 = -1
                     (offset-y (- ky f-center-y)) ; e.g., 1-1 = 0
                     (pixel-x (+ x offset-x))
                     (pixel-y (+ y offset-y)))
                (when (and (>= pixel-x 0) (< pixel-x width)
                           (>= pixel-y 0) (< pixel-y height))
                  (let ((pixel (~ input-m pixel-y pixel-x))
                        (filt-v (~ filter-m ky kx)))
                   (set! acc (+ acc (* pixel filt-v))))))))
            ;; after enumerating filter, store
            (set! (~ output-m y x) acc))))))
```



