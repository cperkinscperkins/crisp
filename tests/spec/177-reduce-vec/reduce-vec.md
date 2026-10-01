In endeavor 175 we implemented reductions in Crisp. 
Crisp doesn't have a one-size-fits-all approach to reductions but instead has some "first stage" and "second stage" forms that can be composed by the user.

.\tests\spec\175-reductions\reductions-excerpt.md    has an update excerpt of their documentation.

In this endeavor we'll be implementing reduce-vec.  Tis builds on the reductions we've already implemented.  I've excerpted its API below.



I'd there are quite a few &key arguments that the original reductions require (e.g. local-scratch-vec global-scratch-vec atomic-counter election-flag-cell )
I'd like to explore having them have default values, so they aren't always required.  (make-scratch-cell results in IMPLICIT paSS. WE SHOULD USE IT.)






DOCS
====

### **The Vector API**

Because reducing a 1D vector or tensor is so common, Crisp provides a high-level wrapper that automatically handles the grid-stride loops and applies the combinations for you:

`(reduce-vec someFunction vec identity &key out strategy)`

Instead of manually writing the strided loops and managing the scratchpads, you simply tell `reduce-vec` which Macro Strategy to employ:


The `strategy` is one of:
```
(def-enum reduction-strategy :atomic :last-man-standing :cas )
```
The "second stage" isn't available because it requires a second kernel enqueue.


```lisp
;; Example: The "Easy Button" atomic strategy
(reduce-vec #'+ my-large-vector 0.0 :out result-cell :strategy :atomic)

;; Example: The flexible "Last Man Standing" strategy for custom operations
(reduce-vec #'my-custom-hash-combine my-large-vector 0 :out result-cell :strategy :last-man-standing)

```

*(Note: all `reduce-vec` operations utilize `reduce-workgroup` as their Phase 1 under the hood).*
