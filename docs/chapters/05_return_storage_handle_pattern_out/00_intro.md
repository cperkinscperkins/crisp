# Return Storage Handle Pattern `&out` ✅


Because kernel and grid functions cannot return values, the accepted
pattern is to pass memory to them where you want results to be recorded.
This is very common in GPU-land.

But there are caveats that if not well managed can lead to bugs.
It may be tempting to use a grid operation to calculate something, and 
then, afterward, "peek" at the solution.  

Like so
```
;; --- INCORRECT ---
;; -- calc --
(def-kernel calc (A B)
 ;; <type-declaration-here>
 
 ;; use grid level operation to square every element of A,
 ;; storing it in B
  (loop-vector-stride A (i)
    (set! (~ i B) (square (~ i A))))
  
 ;; check for lucky number in (~ B 7)  ie B[7]
 ;; this "peek" is a race condition. The thread executing here
 ;; has no guarantee that thread 7 has completed yet.
 (let ((lucky-num (~ B 7)))
   ;; do-something
  ...))
```

But this won't work. B[7] WILL hold the right value, someday. 
But at the time the thread the kernel is runnign on has finished its part 
of the `loop-vector-stride` there is no guarantee that the B[7] is done.
The odds are high that reading B[7] will result in garbage. This is a
classic race condition.

This is a very easy mistake to make, in all languages. For this reason, Crisp
has the `&out` parameter list specifier.  
Any variables after `&out` must be a `:global` Storage Handle ( ie an acceptable proxy, like `vector` `soa-vector`, `cell`, `tensor` ).

Importantly, within the functions scope the compiler enforces a write-only contract. 
Any attempt to read from an `&out` parameter will result in a compile-time error. 
Thus protecting you from accidentally making the race condition mistake.

```
;; --- CORRECT ---
;; -- calc --
(def-kernel calc (A &out B)
 ;; <type-declaration-here>
 
 ;; use grid level operation to square every element of A,
 ;; storing it in B
  (loop-vector-stride A (i)
    (set! (~ i B) (square (~ i A)))))
```

If you are implementing the "return-data-via-storage-handle-parameter" pattern,
then use `&out` and enlist the compilers help in enforcing usage boundaries.


The `&out` parameter list keyword marks the beginning of the output parameters. 
All subsequent parameters in the list are treated as output parameters and are subject 
to the write-only contract within the function's scope. Following  `&out` there can be `&optional` and then `&key` paramters, these are NOT considered to be `&out` parameters.
Note that these advanced signature constructs are order sensitive. The order is `&out => &optional => &key` and it is a compile error to order them otherwise.

`&out` parameters can only be Storage Handles (`cell`, `vector`, `matrix` or `tensor`). 
Any other type for an `&out` parameter is a compilation error.


