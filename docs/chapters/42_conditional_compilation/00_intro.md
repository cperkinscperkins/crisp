# Conditional Compilation ✅


Crisp uses the `#+` and `#-` reader macros to do conditional compilation. Unlike Common Lisp, 
these are not keyed off of `*features*` (which is not supported) but intead the parameters,
which can be set via `def-parameter` or the `-D` compiler flag.

The #+ reader macro inspects the parameter that follows it. If that parameter's value is not nil, 
the subsequent S-expression is read and included in the compilation. 
If the parameter's value is nil, the reader skips the next S-expression entirely.
C/C++ programmers can consider it like `#if` that doesn't require an `#endif`

`#-` is the reverse of `#+`

Example.
```
(def-parameter full_ride T)
(def-parameter sleigh_ride nil)
(def-parameter over_ride 0)

#+full_ride
(def-type A ...)

#+sleigh_ride
(def-type B ...)

#+over_ride
(def-type C ...)
```
In the above example, `A` would be defined because `full_ride` was `T`.
But `B` would NOT be defined, because `sleigh_ride` was `nil`
And `C` would also NOT be defined, because  `0` puns as false.

And, the following compilation line would reverse those completely:
```
crisp.exe -Dfull_ride=nil -Dsleigh_ride=T -Dover_ride=1  ... etc
```


#### another example

```
;; -- calculate --
(def-function calculate (x)
  (declare #(float => float))
  (let (#+(target-has :fp64)
        (precision   (get-high-precision-v))

        #-(target-has :fp64)
        (precision   (get-low-precision-v)))
      ...))

```
See below for `target-has`.

