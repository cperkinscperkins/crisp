# Looping Constructs ✅


Here is a list of the looping constructs supported by Crisp. Some are discussed elsewhere.

- loop-vector-stride / loop-soa-stride
- tensor-stride
- grid-stride
- tile-stride
- hardware-stride
- stride helper functions:
- - tensor-coords
- - tile-coords
- - tile-indices
- - load-tile
- - store-tile
- workgroup-stride
- dotimes / dotimes+ / dotimes*
- do-times-by-doubling
- do-times-by-multiply
- dec-times / dec-times+ / dec-times*
- dec-times-by-half / dec-times-by-half+ / dec-times-by-half*
- dec-times-by-factor / dec-times-by-factor+ / dec-times-by-factor*
- do-power-step
- dec-power-step

#### Immutable Index
All of the above bind a loop index. Unlike in a C++ `for` loop, that index value is immutable in the 
body of the loop.

#### + variants 📝
Most of the Looping Constructs have a variant whose name ends in `+`. These variants 
only accept compile-time calculable values for their target `N` . The compiler will emit
an error if `N` is not. 

#### * variants 📝
The compiler will check that the target `N` is uniform across the warp. If the compiler
detects that it is not warp-level uniform, it will emit an error. 

#### variants compared
Let's start with a simple example:
```
(dotimes (x (+ a b)) 
   ...)
```
Each thread will calculate `(+ a b)` independently, and then loop that many times.  If that value `(+ a b)` differs
between threads, the loop will not be uniformly executed and this may result in a LOT of stalling.

`+`
```
(dotimes+ (x (+ a b))
 ...)
```
If `(+ a b)` is calculable at compile time, then this is fine. The compiler will insert that value and the loop 
will be uniform. The compiler might even elect to unroll the loop for faster performance.



`*`
```
(dotimes* (x (+ a b))
 ...)
```
The compiler will check that both `a` and `b` are warp-level uniform. If they are, then their sum is as well and 
this will both compile just fine, but it'll execute quickly without stalling. But if the compiler
detects that this is not warp-level uniform it will emit an error.



#### dotimes / dotimes+ / dotimes* ⚠️
```
 (dotimes (i N:ulong &optional (stride:ulong 1)) 
    ...)
```
Binds `i` to 0, counts up to N, incrementing by `stride` each time through the loop. `stride` is optional, defaults to 1.

#### dec-times / dec-times+ / dec-times* 📝
```
  (dec-times (i N:ulong &optional (stride:ulong 1))
    ...)
```
Binds `i` to `N-1` and counts down to `0`, subtracting `stride` each time through the loop. `stride` is optional, defaults to 1.
This is the opposite of `dotimes`


#### do-times-by-doubling / do-times-by-double+ / do-times-by-doubling* 📝
```
  (do-times-by-doubling (i:ulong init:ulong N:ulong) 
   ...)
```
Binds `i` to `init`. Each time through the loop, `i` is doubled until
it reaches (or exceeds) `N`.  The last call will always have `i` bound to a value less than or equal to `N`.

Example: If `init` is 1 and `N` is 64: i => 1, 2, 4, 8, 16, 32, 64
Example: If `init` is 1 and `N` is 100: i => 1, 2, 4, 8, 16, 32, 64

#### do-times-by-multiply / do-times-by-multiply+ / do-times-by-multiply* 📝
```
  (do-times-by-multiply (i:ulong init:ulong N:ulong factor:ulong)
   ...)
```
Binds `i` to `init`. Each time through the loop, `i` is multiplied by `factor` until i reaches (or exceeds) `N`.  The last call will always have 
`i` bound to a value less than or equal to `N`.

The `factor` value must be greater than 1.

Example:  `init` is 1  `N` is 64 and the `factor` is 4:  i => 1, 4, 16, 64


#### dec-times-by-half / dec-times-by-half+ / dec-times-by-half* 📝
```
  (dec-times-by-half (i:ulong N:ulong)
    ...)
```
Binds `i` to `N`. Each time through the loop, `i` is divided by two until it reaches 1.  The last call will always have `i` bound to `1`, it is never bound to `0` .
Example: If `N` is 64:  i => 64, 32, 16, 8, 4, 2, 1  
Example: If `N` is 100: i => 100, 50, 25, 12, 6, 3, 1

This is very useful for reductions where we have all 64 threads in a warp perform a calculation, then 32, down to the last thread which has 
the full value.  See the example for `sum_vector` with barriers below. 

If your algorithm always needs powers of two, make sure `N` is a power of 2 itself, or consider using `dec-power-step` instead ( below ).

#### dec-times-by-factor / dec-times-by-factor+ / dec-times-by-factor* 📝
```
  (dec-times-by-factor (i:ulong N:ulong factor:ulong)
     ...)
```
`dec-times-by-factor` is a generalized version of `dec-times-by-half`.  This routine requires a third argument, the `factor`, which is a non-negative integer that must be greater than 1. 
(A `factor` of 2 will result in the same sequence as `dec-times-by-half`). 

`dec-times-by-factor+` requires that BOTH `N` and `factor` are `uniform` values. 

Binds `i` to `N`. Each time through the loop, i is divided by `factor` using integer division. 
The loop continues as long as `i` is greater than or equal to 1. `i` is never bound to 0.

Example #1:  `N` is 64 and the `factor` is 4:  i => 64, 16, 4, 1
Example #2:  `N` is 24 and the `factor` is 5:  i => 24, 4


#### do-power-step / do-power-step+ / do-power-step* 📝

```
  (do-power-step (step-var:ulong limit:ulong) 
     ...)
```
`do-power-step` binds `step-var` to the powers of 2 up to `limit` (or the next power of 2 if it is not itself a power of 2).
The highest value `step-var` will have is half the "padded" limit.
For example, in `(do-power-step (i 100) ..)`, the limit of 100 gets rounded up to the next power of 2 which is 128.
This would then have seven steps, binding `i` in turn to 1, 2, 4, 8, 16, 32, and 64
The number of steps taken is `(log2 padded_limit)` ( aka `(log padded_limit 2)`)

##### possible implementation
```
;; -- do-power-step --
(defmacro do-power-step ((step-var limit) &body body)
  "Loops log2(padded_limit) times, where padded_limit is the next
   highest power of two from limit. Binds step-var to 1, 2, 4, 8..."
  (let ((d (gensym))
        (padded-limit (gensym)))
    `(let ((,padded-limit (next-power-of-2 ,limit)))
       (dotimes (,d (log2 ,padded-limit))
         (let ((,step-var (expt 2 ,d)))
           ,@body)))))
```


#### dec-power-step / dec-power-step+ / dec-power-step* 📝

```
  (dec-power-step (step-var:ulong limit:ulong) 
     ...)
```
The reverse of `do-power-step`, `dec-power-step` starts with `step-var` bound to half the padded limit and decremented until it is 1.
E.G. In `(dec-power-step (i 230) ...)` the limit of 230 would be raised to the next power of two, which is 256.
So `i` would be bound to 128, 64, 32, 16, 8, 4, 2, and 1. 

##### possible implementation
```
-- dec-power-step --
(defmacro dec-power-step ((step-var limit) &body body)
  "Loops log2(padded_limit) times, binding step-var to ..., 8, 4, 2, 1."
  (let ((d (gensym))
        (padded-limit (gensym)))
    `(let ((,padded-limit (next-power-of-2 ,limit)))
       (dec-times (,d (log2 ,padded-limit))
         (let ((,step-var (expt 2 ,d)))
           ,@body)))))
```


