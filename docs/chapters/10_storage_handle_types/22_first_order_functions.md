## First Order Functions


- `def-function` defines a function
- `#'some-func-name` is how to refer to the function handle
- `#'(<arg-type> ... => <return-type> ...)` can be used to wrap the function type signature
- `(type-signature-of #'someFunction)` can get the type signature of a function
- `(return-type-of #'someFunction)` can get the return type of a function. 

<!--
QUESTION: `(return-type-of (type-signature-of #'someFunction))` supported?
ANSWER: I guess. 
-->
```
(def-type my-vec-t (vector int :local))

;; -- count-if --
(def-function count-if (v predicate?)
    (declare (return-type ulong) (type v my-vec-t) (type predicate? #'(int => bool)))
    ...)

;; -- count-if -- 
(def-function count-if (v pred?)
    (declare #'(my-vec-t #'(int => bool) => ulong))
    ...)
```



