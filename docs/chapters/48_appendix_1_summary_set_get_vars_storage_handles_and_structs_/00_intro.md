# APPENDIX #1 - Summary: set / get vars, storage handles, and structs ✅


```
;; -- ACCESS 
someVar
(~ cell)
(~ vec i)
(~ mat y x)
(~ tensor ... z y x)
(x~ somePt)
(x~ soaVec<point> i)

;; -- SET!
(set! someVar val)
(set! (~ cell) Val)
(set! (~ vec i) val)
(set! (~ mat y x) val)
(set! (~ tens ... z y x) val)
(set! (x~ somePt) val)
(set! (x~ soaVec<point> i) val)

;; -- OVERRIDE GET ( ~ )
(def-function ~ (cellT) ...)
(def-function ~ (vecT i) ...)
(def-function ~ (matT y x) ...)
(def-function ~ (tensT ... z y x) ...)

;; -- OVERRIDE SET! ( ~ )
(def-setter ~ ((cellT) val) ...)
(def-setter ~ ((vecT i) val) ...)
(def-setter ~ ((matT y x) val) ...)
(def-setter ~ ((tensT ... z y x) val) ... )

;; -- OVERRIDE PROPERTY ACCESS
(def-function x~ (pointT) ...)
(def-function x~ (soaVec<point> i) ...)

;; -- OVERRIDE PROPERTY SET
(def-setter x~ (pointT val) ... )
(def-setter x~ ((soaVec<point> i) val) ...)

;; -- ATOMIC OPERATION
(atomic-inc! someVar)
(atomic-inc! (~ cell))
(atomic-inc! (~ vec i))
(atomic-inc! (~ mat y x))
(atomic-inc! (~ tens ... z y x))
(atomic-inc! (x~ somePt)
(atomic-inc! (~ soaVec<point> i))

;; -- ATOMIC-SET!  / ATOMIC-XCHG!
(atomic-set! someVar val)
(atomic-set! (~ cell) val)
(atomic-set! (~ vec i) val)
(atomic-set! (~ mat y x) val)
(atomic-set (~ tens ... z y x) val)
(atomic-set! (x~ somePt) val)
(atomic-set! (x~ soaVec<point> i) val)
```




