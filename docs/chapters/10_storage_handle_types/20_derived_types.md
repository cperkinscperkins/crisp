## Derived Types


`def-derived-type` ,  `make-XXXX`, `as-XXXX`, `is-XXXX?`

`def-derived-type` defines a NEW type derived from a stated type. The purpose for this
is to allow custom overload of functions and properties.

Additionally, with `set-derived` the compiler can be instructed to create a type hierarchy
between two types. 

### def-derived-type

```
(def-enumeration derived-subst :no :equal :pass-orig :pass-derived)

(def-derived-type <new-name> <type-expr> &key (subst :no))
```
The `type-expr` is any type that supports a `make-` function (`vector`, `soa-vector`,  `tensor` and things created from `def-struct` )  
<!-- what about numeric types? bool, or nil ?  Definitely NOT functions or kernels, right?-->


The `subst` key should be from the `derived-subst` enumeration
| key           | Description            |
|---------------|------------------------|
| :no           |   A value of the derived type cannot be passeed as an argument to a function that expects the original type. Nor can a value of the original type be passed to a function that expects the derived type.|
| :equal        |   Values of either type can pass for each other.        |
| :pass-orig    |   A value of the derived type can be passed as an argument to a function that expects the original type. But the reverse it not true.  In languages like C++ or Java, this behavior is as if the derived type were a subclass of the original type. |
| :pass-derived | A value of the original type can be passed as an argument to a function that expects the derived type. But the reverse is not true - compilation error. If thinking like C++, this is like making the derived type act as the parent, as a super class (something C++ can't do). |


It's very important to remember that no matter what the substitution behavior is set to, that Crisp will choose the closest
overloaded function (and emit a compilation error if that cannot be clearly determined).
So even if using `:equal`, if function `foo` takes a single argument and is overloaded for types `A` and  `B` ,  `foo #'(A=>...)` will 
NEVER be called with a value of type `B`  unless `as-A ` were used.

`def-derived-type` is one of the `def-` constructs that CANNOT be wrapped by `with-template-type`. 


### Example

```
;; def-struct makes a new type 'point'
;; and we make a 'distance' function that takes points.
;; -- point --
(def-struct point
    (x float)
    (y float))

;; -- distance --
(def-function distance (a  b )
    (declare #'(point point => float))
    #| pythagorean formula here |#  )


;; a coordinate derived type is declared with 
;; a custom distance formula for it.
(def-derived-type coordinate point :subst :no)

;; -- distance --
(def-function distance (a b)
  (declare #'(coordinate coordinate => float))
  #| haversine formula here |# )

(let ((p1 (make-point 1 2))
      (p2  (make-point 3 4 ))
      (c1 (make-coordinate 1 2))
      (c2 (make-coordinate 3 4)))

  (distance p1 p2)  ; <-- evaluates to pythagorean distance between p1 and p2
  (distance c1 c2)  ; <-- evaluates to haversine distance between c1 and c2
  (distance p1 c2)) ; <-- compilation error. because :subst is :no 
                    
```

In the example above if `:subst` were `:equal` it would also error, 
because the compiler wouldn't be able to successfully resolve which 
distance overload was desired.

In the example above, if `:subst` were instead set to `:pass-orig` then
`(distance p1 c2)` would accept `c2` as a `point` and would return the 
pythagorean distance.

Or, if `:subst` were instead set to `:pass-derived` then
`(distance p1 c2)` would accept `p1` as a `coordinate` and return 
the haversine distance. 

Crisp employs "multiple dispatch" for overloaded functions, determined at compile
time. It does not support runtime dynamic dispatch of any sort.

### make-XXXX

The `make-<derived-type-name>` is automatically generated  and accepts the same arguments
as the original type. 

### as-XXXX

When a derived type is declared, then two type casting functions are automatically created.
 `as-<original>` which can be used to cast an value of the derived type as if it is the original, and
 `as-<dervied>` which can be used to cast an original as the derived.

 ```
 ;; continuing the example above, with two distance overloads and points p1, p2 and coordinates c1, c2

 (distance (as-coordinate p1) (as-coordinate p2)) ; would return the haversine distance. Even if :subst was set to :no

 (distance (as-point c1) (as-point c2)) ; retuns pythagorean distance. 
 ```

### is-XXXX?
 
When a derived type is defined, a matching type constraint function is also automatically defined.
`is-<derived>?` evaluates to true if the type in question matches the new derived type.  
 
Note that this does NOT accept substitutions, regardless of `:subst`.  Use `is-substitutable-for?` for that.

```
(def-struct point ...) 
(def-derived-type coordinate point :subst :pass-derived)

(is-point? point) => True
(is-point? coordinate) => False
(is-coordinate? point) => False
(is-coordinate? coordinate) => True.
```



### set-derived

`(set-derived original-type derived-type &key subst)`

If you have two existing types you can simply state that one derives from the other 
with `set-derived`.  Using `set-derived` will generate the two `as-XXXX` type casting
functions, just like `def-derived` does.  But no new `make-XXXX` function is defined.

As `set-derived` is inherently unsafe, the compiler enforces certain sizing rules, 
depending on the value of `subst`.  

`d-sz` is the derived size
`o-sz` is the original size

| `subst`       | rule                |
|---------------|---------------------|
| :no           | (no rule)           |
| :equal        | `d-sz` == `o-sz`    |  
| :pass-orig    | `o-sz` <= `d-sz`    |
| :pass-derived | `d-sz` <= `o-sz`    |

#### extending views

If you want to extend a type like `vector` with your own type that has extra data members,
you can use `def-struct` in conjunction with `set-derived` for this.
Example:
```
(def-struct MY-VEC 
    (base (vector))
    (new-prop int))

(set-derived vector MY-VIEW-type :subst :pass-orig)
```

#### std140

All Crisp structs are aligned with the `std140` layout and alignment practice. 
Keep this in mind when using `set-derived` and type casting, as things
might not work like you'd expect in a language like C. 




