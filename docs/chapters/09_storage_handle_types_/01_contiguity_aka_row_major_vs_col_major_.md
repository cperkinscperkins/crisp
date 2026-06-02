# Contiguity  (aka row-major vs col-major )


 Except `cell`, all Storage Handles have compile-time known "contiguity".  This tells the compiler
 in which dimension the data is contiguous. 
 The compiler time property to specify this is `:contiguous-term`. It defaults to `:last` for
 all types, and by virtue of there being a default it means this is optional. Many users will
 never need it, or need to know about it.

 ```
 (tensor float 6 :address-space :global :align :compact :contiguous-term :last)

;; usable with any tensor of any arity
 :contiguous-term  :last   ;; for a matrix, this is same as :row-major
 :contiguous-term  :first  ;; same as :col-major for a matrix

;; usable only with matrices
 :contiguous-term  :row-major
 :contiguous-term  :col-major

 (tensor-stride someMatrix (row-y col-x) ...)
```


