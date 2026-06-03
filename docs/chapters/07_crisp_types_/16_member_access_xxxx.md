# member access: `XXXX~`

Functions to access members are autmatically generated. The function name is the member name follow by `~`.

This function can be used to get a value, and in conjunction with `set!` it can be used to change it.

These functions can be overloaded, so you can make your own custom setters or getters for your structs. 
See "overloading member access function" below for more infomation. 

```
; function #'x~ and #'y~ are automatically generated
x~ #'(point => float)
y~ #'(point => float)

; example:

;; -- align-y --
(def-function align-y (p1 p2)
  (declare #'(point point => nil))
  (let ((horiz (y~ p1)))    ; get 'y from point p1
    (set! (y~ p2) horiz)))  ; set 'y of point p2 to that value


```

#### Non Overrideable Member Access: `~XXXX~` ✅
Addiitonally, a non-overridable function to access members is also automatically generated. That function name is `~` followed by the member name, followed by `~` again.   This function can be used to get a value directly
from a struct bypassing any custom overload of the access, and can be passed to `set!` as well. 

These are mostly used by the overloaded member access functions, but are occasionally useful when dealing with
atomics or other places where diverting through a custom access function is not desired.

```
(let ((horiz-x (~x~ somePoint)))    ; get x from somePoint
   (set! (~x~ otherPoint) (+ horiz-x 10))  ; set x of otherPoint 
 ...)
```

#### overloading member access function ✅
The access functions that are just one tilde followed by the member name can all be overloaded and thus
custom accessor functions can be provided. 
Simply define a function of the same name and the correct type.


In this example, this function flips a point over the vertical axis
by returning the negatiion of the x value.

```
;;;  x~
(def-function x~ (p:point)
  (declare (return-type float))
  (- (~x~ p)))  ;; internally use the non-overrideable access function.

(let ((p (make-point 5 0))
      (neg-x (x~ p)))   ; neg-x will be -5 because of the overloaded x~ function above.
    ...)  
       
```

#### AoS and SoA

Crisp supports vectors of structs. The standard Crisp `vector` can be used for an "Array of Structs" (AoS) layout, but there is also
`soa-vector` which can be used for "Struct of Arrays" (SoA) layout. See `soa-vector` below.

#### Overload member access and soa-vector

The overload member access functions (like `x~` in the previous section) will NOT WORK for structs in a `soa-vector`. 
If you want to overload access there too, an additional overload function must be defined:

```
;;;  (x~ sv) returns the vector of ALL x values, we are adjusting the one at idx
(def-function x~ (sv idx)
    (declare (type sv (soa-vector point)) (type idx ulong) (return-type float))
    (- (~ (x~ sv) idx)))
```

The compiler will emit a warning if it encounters access on a soa-vector for a struct that has asymmetric property accessor overloads.

In the future, Crisp may handle this automatically. 

#### `with-struct-accessors`  - ADVANCED  ✅

In Crisp, like in C++, the struct type itself is not runtime inspectable. But unlike C++, Crisp has compile time affordances
that help you write macros that generically walk all the properties. One of those affordance is `with-struct-accessors`.

```
(defmacro with-struct-accessors (struct-type (aos-var &optional soa-var) &key (access :public) &body body) ...)
```
This is an iterate-and-bind macro that loops over all the properties of `struct-type`. The return
values of the `body` are gathered up and can be expanded (via `,@`) where needed.  
Each time through the loop `aos-var` will be bound to some  accessor (e.g. `x~` then `y~` for the `point` type) that can take a struct argument.  If provided, `soa-var` will be the soa accessor variant that takes a `soa-vector` and an index `ulong`.  

The `:access` key determines which class of accessor is enumerated. If `:public` it 
enumerates the main public accessors (`x~` etc).  If `:raw` it enumerates the non overrideable
accessors (`~x~`).

See the "possible implementation" of  `convert-aos-to-soa` below for a usage example.




