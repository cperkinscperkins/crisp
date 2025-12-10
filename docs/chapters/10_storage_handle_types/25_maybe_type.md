## Maybe Type


GPU Kernels do not support exceptions. Many operations that would be segfaults on a CPU 
(like reading past the bounds of allocated memory) are simply ignored by GPU kernels.  
These can make error handling challenging, negatively impacting both correctness and performance.
Crisp provides a "maybe" type which gives developers a simple way to define and handle error states. 
The maybe type automatically interoperates with the electable kernel logging mechanism, 
helping both correctness and debugability.

### maybe and result

`maybe` is a type expression that can wrap other types.  
`maybe` means that if it has no error, the function will return a value of that type.

The compiler handles the unwrapping of the `maybe` tuple for you, 
so the code that encounters the `maybe` remains clean. 
In reality, the function will return a tuple with :OK in the first position 
and the successful value(s) in the subsequent one(s). 
If there is an error, :Err will be in the first position no value.
But this is an implementation detail.

`result` is a special form that takes as its first argumment either
the keyword :OK or :Err.  When :OK, then the subsequent args match the type
of the maybe expression and are the return value(s).  
When :Err then you can pass a message string as second argument and that may appear
in the log if the side-channel logging has been elected. Otherwise it will
be compiled away. There is no performance penalty for any :Err message
or message handling if the side-channel logging is not active.


In the example below, we have a function divides numbers safely. 
It uses `maybe` in the type signature and `result` to return the 
result or error.

```
(with-template-type (T)

  ;; -- div-safe --
  (def-function div-safe (dividend divisor)
    (declare #'(T T => (maybe T)))
    (if (= divisor 0)
      (result :Err "division by zero")
     (result :OK (/ dividend divisor)))))
  
```

### let-maybe

`let-maybe` is a binding environment that makes working with `maybe` types much easier.  
```
; Example 1

;; -- math-1 --
(def-function math-1 (a b)
  (declare #(long long => long))
 (let-maybe ((m1 (div-safe 10 a))
             (m2 (div-safe 20 b)))
          (+ m1 m2)
    :Err
       0))

; Example 2

;; -- math-2 --
(def-function math-2 (a b)
  (declare #(long long => (maybe long)))
 (let-maybe ((m1 (div-safe 10 a))
             (m2 (div-safe 20 b)))
          (+ m1 m2)))
```
Examining the above, if neither `a` or `b` are 0, then the results of the two divisions are added together and the sum is the value returned by both functions.

In Example 1, if `a` is 0, then `div-safe` will return `(result :Err)`  and the `let-maybe` will then return the expression that follows `:Err` . 
But in Example 2, where there is no `:Err` clause,  the `let-maybe` would return the `result` it got from `div-safe`.
And, aligned with that, note the return type of `math-1` is `long` whereas in `math-2` it is `(maybe long)`.
In both Examples, we will NOT evaluate the second binding (assigning `m2` to `(div-safe 20 b)`). The `let-maybe` exits as soon as it encounters a `(result :Err)`

When using `let-maybe`, while you are on the "happy path" of the bindings and the main body of the progn your code can be assured that no error was encountered.


`let-maybe` has only one `:Err` escape for all of its bindings. If you need more, consider using `or-else` around an individual assignment. See below.

#### compare to `let`

Below we use `let` instead of `let-maybe`.  Note that this will NOT compile. This is because, unlike `let-maybe`, 
the regular `let` doesn't guard and unwrap the maybe values.
The `#'+` operator only accepts numbers, it does not accept `maybe` types, and thus the expression `(+ m1 m2)` fails.

Note that if we want to use `let`, we can by leveraging the `or-else` construct (see below) which safely
guard and unwrap a single `maybe` type. 


```
; this won't compile

;; -- math-3 --
(def-function math-3 (a b)
  (declare #(long long => (maybe long)))
 (let ((m1 (div-safe 10 a))
       (m2 (div-safe 20 b)))
    (+ m1 m2)))
```



### a note about thread divergence

In the examples above (`div-safe, math1, math-2`) there are divergences being introduced into the flow of the kernel execution.

Remember that GPU kernel code is executed simultaneously by tens or even hundreds of threads sharing a single program counter. 
If any thread or group of threads needs to branch off onto a path that the others aren't taking, it results in a stall where some threads are 
simply waiting while the others finish that operation. 

Note first the explicit divergence in `div-safe`.   It  branches with `if` and then both branches return a `result`.  This
is a good example, because the branch is short and resolves again quickly.  Take care that when returning `maybe` values
that you don't introduce long branches, because if even one thread diverges, the entire warp stalls and waits.
Division by zero is not safe, so the use of `if` is mandatory. But consider using `select-if` in some cases. It
keeps threads synchronized (even though it fully calculates both consequent and alternate expressions). 


The second divergence is an implicit one. In both `math-1` and `math-2`, if a `(result :Err)` is encountered, then
that thread ceases executing the remainder of the function. It will wait until the other threads finish and then
they continue together. But note that while it is true that threads that encounter errors stall, they are NOT performing
extra work, nor are many different branches spider webbing away from the point of error. Instead the use of `maybe`
and `let-maybe` result in the minimal amount of stall and divergence. 



#### multiple return values

`maybe` and `result` support multiple return values. For example:  `(maybe int myVecType)`  `(result :OK someInt someVec)`


### Guard: or-else

`or-else` is a macro that takes a maybe and returns either 
its success value(s) or some other value(s) of the same type.

This is very useful for guaranteeing that even in the face of errors
that a function can consistently operate with SOMETHING and is not
forced to return 'maybe' simply because one of its sub-functions uses it.
 It does not prevent the `maybe` from being logged. 

```
;; -- some-math-ops --
(def-function some-math-ops (a b)
  (declare #'(float float => float))
  (let ((m (or-else (div-safe a b) 1))  ;<-- if there is an :Err, m will be '1'
        (n (+ a b)))
     (* m n)))
```


