## Declaring Types - Functions ⚠️


Types MUST be declared for parameters to functions and the function return type.  

Grid functions and kernel functions ( `def-grid-function`, `def-kernel` ) also need their paramters to be typed.
They both have no return value and can either specify that, or elide it from the type signature.

There are various mechanisms for declaring parameter and return types.  Easiest to illustrate them with code.

```
;; A -- use a declare block. (return-type <type>) for the containing function, (type <varName> <type>) for each variable.
(def-function addInts (a b)
    (declare (return-type int) (type a int) (type b int))
  (+ a b))

;; B -- type can declare multiple names to the same type.
(def-function addInts (a b)
    (declare (return-type int) (type a b int))
  (+ a b))

;; C -- declare block with a single type signature for entire function.
;       if a type signature appears in declare, it's assumed to be for the function. 
(def-function addLongs (a b)
    (declare #'(long long => long))
  (+ a b))

;; E -- multiple values return
(def-function divInts (a b)
; divInts returns both the quotient AND the remainder.
    (declare #'(int int => int int))
    ...)

(def-function divIntsAgain (a b)
    (declare (type a b int) (return-type int int))
    ...)

;; F -- type-signature can refer to other functions
(def-function addPreciously (a b)
    (declare #'(long long => (return-type-of #'addInts)))
    ...)

(def-function addIntsSometimes (a b)
   (declare (type-signature-of #'addInts)) 
   ...)



;; G -- NIL return type (ie 'void' in C)   
(def-function doSomething ()
  (declare (return-type NIL))
  ;OR
  (declare #'(=> NIL))
  ...)

;; H -- keyword & optional arguments
(def-function survive (&key birds fish zombies)
  (declare (return-type NIL) (type birds fish zombies int))
  ;OR 
  (declare #'(&key :birds int :fish int :zombies int => NIL))

  (if (is-set? birds)    ;; <-- use is-set? to check if a variable is set or not.
  ...)

(def-function addSome (x &optional y)
  (declare (return-type NIL) (type x y int))
  ;OR
  (declare #'(int &optional int => NIL))

  (when (is-set? y)    ;; <-- is-set? to check 
  ...)

; default values do not appear in type signature
(def-function addSome (x &optional (y 30))
  (declare #'(int &optional int => NIL))
  ...)

;; I -- skip return type in kernels and grid functions
(def-grid-function bury (meters)
  (declare (type meters float))
   ...)

(def-grid-function sharpen (edge)
  (declare #'(float => nil))   ; nil is return type
  ; OR
  (declare #'(float))          ; no need for return type

;; J - &out -- write-only-vectors
(def-grid-function vector-add (A B &out C)
   (declare #( v-type v-type &out v-type))
    ...)
```

### Lazy Monomorphic Generation

Use of `&optional` and `&key` leads to function generation for
each option.  In other words, an optional declaration like so:
 `(def-function foo (&optional a) ...)` 
 results in TWO possible versions of `foo` being generated. One with zero
 arguments, and one with `a`.  To avoid combinatorial explosion, the compiler generates these lazily, as needed. 




