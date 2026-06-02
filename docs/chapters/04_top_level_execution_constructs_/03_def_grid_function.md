# `def-grid-function`


```
;; -- vector_add --
(def-grid-function vector-add (A B &out C)
  ;; <type-declaration-here>
  (loop-vector-stride A (i)
     (set! (~ C i) (do-add (~ A i) (~ B i))))) 
```

`def-grid-function` also defines a function, much like `def-function` above. 
Grid functions have a "dispatch context" at their top level. They
are called "grid functions" because the CAN invoke grid level operations 
(as opposed to thread level functions which cannot).

Grid functions
- accept arguments, including higher order function args
- CANNOT return values
- have a "dispatch context" in the top level
- can call thread level functinos
- can call grid level functions
- can use Lisp-style naming rules (dashes ok).


