## map


### map-stride
`map-stride` uses Grid Stride to visit every element of some source vector or tensor and pass it
as an argument to a provided function, and then store it at the same position in some destination vector or tensor.

```
(map-stride #'someFunc (A) Z)   
```
Requirements:
- `someFunc` has the signature `#((element-type A) => (element-type Z))`
- `A` and `Z` are a  `vector`  or `tensor`
- `A` and `Z` have the same dimensions.
- `A` is `readable` and `Z` is `writeable`

`map-stride` can accept multiple sources, and/or multiple destinations, so long as the signature
of `someFunc` accepts the matching number of parameters and/or returns the matching number of values.
The additional source or destinations have the same requirements as above (same dimensions, etc)
```
(map-stride #'someFunc (A0 .. An) Z0 ... Zm)
```

Example:
```
;; simplest vector_add
(map-stride #'+ (A B) C)

;; function returning multiple values used

;; -- analyze --
(def-function analyze (v)
  (declare #'(ulong => bool bool))
  (return (is-even? v) (appears-in-fibonacci? v)))
...
(map-stride #'analyze (A) EvenAnalysis FibAnalysis)
```



