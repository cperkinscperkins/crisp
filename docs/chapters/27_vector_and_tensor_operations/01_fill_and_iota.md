## `fill` and `iota`


```
(fill someVec someValue)
(iota someVec)
```

The `fill` and `iota` operations work directly only their vector parameters. `fill` sets every entry to `someValue`,
and `iota` fills the vector with its same indices.

Possible Implementation
```
 ;; -- fill --
(<T A> 
  (declare (value-is A #'is-alignment?))

  (def-grid-function fill (someVec someValue)
    (declare #'((vector T :align A :address-space :global :access :read-write) T))
    (loop-vector-stride someVec (i)
      (set! (~ someVec i) someValue))))

;; -- iota --
(<T A>
  (declare (value-is A #'is-alignment?)
          (type-is T #'is-scalar?))

  (def-grid-function iota (someVec)
    (declare #'((vector T :align A :address-space :global :access :read-write)))
    (loop-vector-stride someVec (i)
      (set! (~ someVec i) (to T i))))) ;; <-- not supposed to be (to T ...)
```

