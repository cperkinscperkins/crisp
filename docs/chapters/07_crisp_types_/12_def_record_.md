# def-record ✅


`def-record` is very simlar to `def-struct`. Records "pun" as structs. The crucial difference is that while structs result in contiguous memory (though aligned and padded), records are not contiguous in memory.  Records are just a collection of register, of memory addresses. They act as virtualized structures.

`def-record` undergirds the Crisp "implicit" argument passing - how the many and sundry pieces of data required for a `tensor` get bound into one virtual variable passed from function to function. 

`def-record` has the exact same syntax and affordances as `def-struct`, including overloadable `XXXXy~` property accessors and non-overloadable `~XXXX~` accessors, and  support for `def-setter`, `def-derived-type`, templates , compile-time properties and more.

Though there is no equivalent of `soa-vector` for records.  

```
(def-record virtual-point
  (x float)
  (y float)
  (d bool :c-t)) ;; <-- some compile-time known property

(def-kernel-exact some_op (vpx vpy)
  (declare (type vpx vpy float))
  (let ((v-p (make-virtual-point :x vpx :y vpy :d (target-has :fp64 T))))
    ...))
```



### Notes

- Importantly, types defined by `def-record` cannot be wrapped in Storage Handles.
- Both records and structs can be passed directly to kernels on the kernel boundary. 
- - But when doing so structs are immutable and cannot have their properties changed.
- - Records, on the other hand, are mutable in the current thread context. Any value
    change is not communicated back to the host or to other threads.
- kernels with structs directly on the parameter boundary (not in a Storage Handle) cannot
  be auto differentiated (with the `--differentiate` flag)
- In contrast, kernels with records directly on the parameter boundary CAN be auto differentiated,
  though that would be unusual.

<!-- IMPLEMENTATION NOTE
  So make-XXXX for records is capturing register identities, not values.
  This should work fine for 
    - kernel arguments
    - function arguments that originated as kernel arguments.
    - memory (:global, :local etc)

  But we have to be careful with temporaries, especially things that might 
  be modelled with alloca:

  (let ((someStruct (make-some-struct :x 10 :y 20))
        (someValue  10)
        (someRecord (make-some-record :vx someValue :vss someStruct)))
      (return someRecord))   

  If a record-of-a-struct "explodes-and-flattens" it to registers, that should be fine.
  But otherwise the code above could have an implicit "use-after-free" or incorrect
  reuse of    :vss someStruct   

  Therefore record-of-struct "explodes-and-flattens" the struct to registers.  
-->

> Implementation Note: consider changing `make-` to `marshall-` for `def-record`.


