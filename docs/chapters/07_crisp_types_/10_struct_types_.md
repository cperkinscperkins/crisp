# Struct Types ✅


`def-struct` defines a structure and makes a new type. 

It also generates functions to create instances of struct (`make-XXXX`), and to access its members.
Additionally, the type constraint function `is-XXXX?` is also generated.

Storage Handles can be specialized to struct types. If a struct needs to be passed directly to a 
kernel, that is the most common way of doing so for both input and output arguments. Note that structs CAN be passed directly to a kernel, without being wrapped by a Storage Handle. But in that
case the struct is configured with constant memory and is read only, immutable. 

<!-- NOTES:  The compiler will treat these custom "functions"  as direct data offsets.  
If a user wants to pass #'make-point or #'x~ as first order arguments, 
then the compiler will generate a function for that.

Common Lisp would generate "point-x", but Crisp generates "x~".
I believe Clojure allows structs and vects to be in the function position:  (somePoint 'x)  (someVec i)
and I have to admit, that's fairly compelling. Might have to consider it. 
-->


```
(def-struct point
    (x float)
    (y float))


;; make-XXXX
(make-point :x 3 :y 4)
;; type signature of make-point is #'(&key :x float :y float => point)
```

### member data rules

A struct can contain any type that has a fixed, known size at compile time.
This would include:
- Scalar types (`int`, `float`, etc)
- Hardware vector types (`float4` etc)
- Other structs
- Compile time sized `array` 
- Views to large data (`cell`, `vector`, `tensor`, `matrix`)

But it excludes:
- `functions` and `kernels`
- Crisp specific internals, like `storage`

Note also that views can't be exchanged with the host directly. A struct that contains a view
cannot use the C interop for data exchange with host. Marshalling would be required.

### layout and alignment 

Crisp structs follow a strict "scalar" layout.
- Basci scalar types are aligned to a multiple of their own size ( a 1-byte `char` aligns to 1, a 4-byte `float` aligns to 4, an 8-byte `double` aligns to 8).
-  A struct's overall alignment is equal to the alignment of its most strictly aligned member.  If a struct contains a `char` and a `float`, the struct's alignment is 4.
- Padding: Members are placed at the lowest available offset that satisfies their alignment. The total size of the struct is padded at the end to be a multiple of its overall alignment.
- Storage Handles - (ie `(vector someStruct)` ) The stride of a storage handle is exactly the size of the struct. Zero extra padding between elements.



### type constraints: is-XXXX?

Using `def-struct` automatically generates `is-XXXX?` for that struct name, which can be used as a type constraint function
in `with-template-type`.  See the discussion of type constraints in `with-template-type` for more information.

### compile-time properties
```
(def-struct addressable
   (value int)
   (address-space address-space :c-t)
   (access access :c-t :read-write))
```


The `:c-t` key can be used to label any property as a compile-time property. It can be inspected
via a property accessor, just like any property (e.g. `(access~ someAddressable)`).  But cannot be changed at runtime. It becomes part of the type declaration for the struct.

A default value can follow the `:c-t` key.  This default will be used if a call to `make-XXXX` did not specifiy it. 

```
;; example #1
(let ((v (make-addressable :value 10 :address-space :global :access :read-only))
      ;; access has a default value, so can be elided:
      (v2 (make-addressable :value 20 :address-space :global)))
   ...)

;; example #2 
(def-function has-addressable-arg (a b)
   (declare (type a (addressable :address-space :global :access :read-only))
            (type b (addressable :address-space :global))
            (return-type nil))
   ...)
```
<!-- 

THIS IMPLEMENTATION DETAIL IS BEING REALIZED

> [!NOTE]
> **Implementation Status**: The implicit syntax shown above (where constructor arguments like `:address-space` are automatically promoted to type parameters) is a future goal. 
> Currently, to achieve this behavior, you must use **Explicit Templates**:
> ```lisp
> (with-template-type (T &optional (AS :global))
>    (def-struct addressable (val T) (space address-space :c-t AS)))
>
> ;; Specialize explicitly
> (def-type-alias GlobalAddr (addressable-type int :global))
> (make-GlobalAddr :val 10)
> ```

-->

### type names vs. type constructors
When a struct is defined with `def-struct`, its name becomes a new type name (e.g., `point`).

If the struct has compile time properties (`:c-t`) then those become part of its complete type constructor.

Example:
```
(def-struct addressable
   (value int)
   (address-space address-space :c-t)
   (access access :c-t :read-write))

(def-function foo (a)
  (declare (type a (addressable :address-space :local :access :read-only)) ...))
```

If a struct is defined within a `with-template-type` block, the system also generates a type constructor (e.g., `point`). This constructor must be used with its type arguments to create a concrete type, like `(point int)`.


### member access: `XXXX~`
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

#### Non Overrideable Member Access: `~XXXX~`
Addiitonally, a non-overridable function to access members is also automatically generated. That function name is `~` followed by the member name, followed by `~` again.   This function can be used to get a value directly
from a struct bypassing any custom overload of the access, and can be passed to `set!` as well. 

These are mostly used by the overloaded member access functions, but are occasionally useful when dealing with
atomics or other places where diverting through a custom access function is not desired.

```
(let ((horiz-x (~x~ somePoint)))    ; get x from somePoint
   (set! (~x~ otherPoint) (+ horiz-x 10))  ; set x of otherPoint 
 ...)
```

#### overloading member access function
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

#### `with-struct-accessors`  - ADVANCED 

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




