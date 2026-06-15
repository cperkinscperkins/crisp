# Fused Softmax 📝


```
(fused-softmax input-vec &out output-vec &optional scratch)
```

Softmax is a mathematical function that takes a vector of numbers (often called "logits") and converts them into a probability distribution. Each output value is between 0 and 1, and all the output values add up to 1. It's famous for being the final step in AI classification models, turning the model's "scores" into a set of confidence percentages.

The fused softmax operation is a workgroup level operation, meaning that once completed, each 
workgroup's values add up to 1. The typical use case is a vector that backs a 2D matrix is the 
input, with the workgroup size set to the row width, and the number of workgroups is equal to 
the number of rows (ie the column height) in the matrix.

`fuzed-softmax` takes an input and output vector, and optionally accepts a 
scratch vector whose length is equal to the local work size.

```
;; -- fuxed-softmaz
(<T A>
  (type-is T #'is-floating-point?)

  (def-grid-function fuzed-softmax (input-vec &out output-vec 
                          &optional (scratch-vec (make-scratch-vector T :match-workgroup-size)))
    (declare #'((in-vec T A) &out (out-vec T A) &optional (scratch-vec-type T))
      (global-size :derive-from input-vec :strategy :one-thread-per))

  (load-local input-vec scratch-vec)

  ;; find max
  (let ((lid (get-local-id))
        (xi  (~ scratch-vec lid))
        (max-val xi))
    (reduce-to-workgroup #'max max-val -INF)

    ;; subtract and exponentiate
    ;; $e^{x_i - \text{max}}$
    (let ((xi-minus-max (- xi max-val))
          (exm    (exp xi-minus-max)))
      ;; overwrite scratch
      (set! (~ scratch-vec lid) exm))

    (sync-workgroup)

    ;; sum across workgroup, 'sum' is uniform after
    (let ((sum (~ scratch-vec lid)))
      (reduce-to-workgroup #'+ sum 0.0)

      ;; divide by sum, store
      (let ((transformF (curry #'/ sum)))
        (store-global scratch-vec output-vec transformF))))))
    
```





