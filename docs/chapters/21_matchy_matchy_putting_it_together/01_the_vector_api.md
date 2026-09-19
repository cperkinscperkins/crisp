# **The Vector API**


Because reducing a 1D vector or tensor is so common, Crisp provides a high-level wrapper that automatically handles the grid-stride loops and applies the combinations for you:

`(reduce-vec someFunction vec identity &key out strategy)`

Instead of manually writing the strided loops and managing the scratchpads, you simply tell `reduce-vec` which Macro Strategy to employ:

```lisp
;; Example: The "Easy Button" atomic strategy
(reduce-vec #'+ my-large-vector 0.0 :out result-cell :strategy :atomic)

;; Example: The flexible "Last Man Standing" strategy for custom operations
(reduce-vec #'my-custom-hash-combine my-large-vector 0 :out result-cell :strategy :last-man-standing)

```

*(Note: all `reduce-vec` operations utilize `reduce-workgroup` as their Phase 1 under the hood).*

