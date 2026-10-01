# Signatures


```lisp
;; independent
(reduce-warp      (clause ...) &optional active-threads)
(reduce-workgroup (clause ...) &key message)
(grid-reduce!     (clause ...) &key strategy atomic-counter election-flag-cell message)

;; dependent
(reduce-warp      combiner (clause ...) &optional active-threads)
(reduce-workgroup combiner (clause ...) &key message)
(grid-reduce!     combiner (clause ...) &key strategy atomic-counter election-flag-cell message)
```

