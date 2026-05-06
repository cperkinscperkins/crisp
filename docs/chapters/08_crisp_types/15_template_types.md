## Template Types


`with-template-type` can wrap several `def-` declarations to template them. 


Doing so automatically generates a type specifier (e.g. `(point long)`) and specializer function that 
can explicitly instantiate the template for a type:  `gen-XXXX` (e.g. `(gen-addTwo long)` or `(gen-point float)`).
where `XXXX` is the name of the function, struct, vector, etc that was defined.


```
(with-template-type (T)

  ;; -- addTwo --
  (def-function addTwo (a b)
      (declare (type a b T) (return-type T))
    (+ a b)))


(with-template-type (T U A)
    (declare (type-is U #'is-floating-point?) (value-is A #'is-address-space?))

  ;; -- move-discrete --
  (def-function move-discrete (a b)
     (declare (type a T) (type b U) (return-type (vector U :address-space A)))
     ...))

; we can template structs as well
(with-template-type (T)
  ;; -- point -- 
  (def-struct point (x T) (y T)))

```

It is possible to put a binding form (like `let`) between, so long as its bindings are evaluable
at compile time.  
Example:
```
(with-template-type (T &optional (M ""))
  (let ((make-reduce-l-s-v (gen-make-reduction-local-scratch-vec T M)))

    ;; -- reduce-something --
    (def-function reduce-something (someFunction someThing &optional (localScratchVec (make-reduce-s-v)))
      ...)))
```


Note that automatic numeric type promotion does not occur during template argument deduction. 
All arguments passed to a templated function must match the expected type exactly, 
or an explicit conversion function (like `to-float`) must be used.

### Syntactic Sugar: `(<T> ...`

`(with-template-type (T U)`  can get a little long to type and swallow. For that reason,
Crisp has a bit of syntactic suger that can make them slighly more palatable:

```
(<T U>  
 (def-...
```

Borrowing from C++, the type vars can appear between `<  >`  and that expression
can stand-in for the wordier `with-template-type (T)` .  


### XXXX type function

`with-template-type` AUTOMATICALLY defines a new type expression: XXXXX  for whatever it is wrapping.
That type expression can be used to specialize the template and return that specific type.
Example:
```
(with-template-type (T)
  ;; -- point --
  (def-struct point (x T) (y T)))

(point int)  <== evaluates to the type, which is a point specialized to int.


;; I don't like this example as it's not really realizable.
(with-template-type (T U A)
    (declare (type-is U #'is-floating-point?) (value-is A #'is-address-space?))

  ;; -- move-discrete --
  (def-function move-discrete (a b)
     (declare (type a T) (type b U) (return-type (vector U :address-space A)))
     ...))

(move-discrete int float :global) ; that specfic type. 
```

#### Incomplete Types

Passing `nil` as a type argument when specializing with `XXXX` produces an incomplete type. 
This can help make interoperation between different functions and structures more flexible.

Incomplete types are used in function signatures (only). Use them when you need to define 
a flexibe function, one that is typed to a struct or vector or similar, but maybe doesn't need
ALL the information normally needed when we define it. But once it is _used_ the compiler will make sure that
all the needed type information is present (or it'll error :-) )

```
(with-template-type (T U)
  ;; -- pair --
  (def-struct pair (first T) (second U)))

(def-type incomplete-p-t (pair nil (vector long)))  ;; <-- a pair with a vector in the second type. Who cares what's in the first?

;; -- sum-length --
(def-function sum-length (a b)
  (declare (type a b incomplete-p-t) (return-type ulong)) 
  (+ (length~ (second~ a)  (length~ (second~ b)))))

```


### gen-XXXX

`with-template-type` ALSO AUTOMATICALLY defines an expression to get or construct a specialized form
of whatever it is wrapping.  This is `gen-XXXX` 

```
(with-template-type (T)

  ;; -- addTwo --
  (def-function addTwo (a b)
      (declare #'(T T => T))
    (+ a b)))

(reduce-to-workgroup someVector (gen-addTwo int)) ; <-- specialize "addTwo" for int and pass that to reduce-to-workgroup


; template over a struct
(with-template-type (T)
  ;; -- point --
  (def-struct point (x T y T)))

(gen-point int)                         ; a. generate the template. 
(setf g-horizon (make-point :x a :y b)) ; b. now use it (assuming 'a' and 'b' are ints)

(map-stride #'make-point (vec-of-X vec-of-Y) vec-of-points)
```

In the case of templates, `gen-XXXX` is a special form or macro, not a function. 
It cannot be passed as an argument or referenced (ie  #'gen-addTwo is illegal)

As type inference is expanded, it may not be necessary to use `gen-XXXX` except in
limited cases. 

Note that `gen-XXXX` CANNOT instantiate an incomplete type. Passing `nil` as type arg is not allowed.

<!-- QUESTION: How DO incomplete types get made into complete types? Such that they could then be instantiated. 
      ANSWER: That's not how they work. They just make function signatures flexible. 
              They are never instantiated themselves. They just let a function sneak by for a 
              bit without having to have ALL the info.  A complete type will still need to be provided once
              someone USES the function. -->

#### kernels

Crisp can template kernels as well. But any kernel that is templated MUST have 
specializations generated with `gen-XXXX` .  Furthermore, kernel functions must have 
unique names, so when applied to kernels `gen-XXXX` takes one additional last argument
which is a string name that the compiler should give the kernel. 

```
(with-template-type (T)

   ;; -- happy_stance --
   (def-kernel happy_stance (data:(vector T :address-space :global)
     ...)))

(gen-happy_stance float "happy_stance_f")
(gen-happy_stance int  "happy_stance_i")
```

#### kernels from `def-grid-function`

Very often, especially when writing library code, you will want to
write some access pattern as a grid function for someone to use in their
kernel. Perhaps a grid function to "sweep up" results.

But it also the case that you may also want that function as a standalone kernel.
This is very common GPU-land where because marshalling individual workgroups is out of our
power, the most expedient course is to simply follow one kernel with another, rather than
trying to combine them. To assist with this very common "double usage" need, 
the `gen-` prefix can be used with any grid function (templated or not) and
a kernel will be produced if that third string argument is present.

```
(with-template-type (T)
  (def-grid-function templated-sweep-f ...))

(def-grid-function other-sweep-f ...)

(gen-templated-sweep-f ulong) ;; <-- this just generates the ulong specializtion
(gen-templated-sweep-f ulong "my_sweep_kernel")  ; <-- this generates a kernel

(gen-other-sweep-f "my_other_sweep_kernel") ; <-- generates a kernel from an untemplated grid function
```


### &optional &key

The `with-template-type` argument list supports `&optional` and `&key` 

```
(with-template-type (T &optional C)
  ;; -- Point --
  (def-struct Point (x T) (y T)
    (when C '(color C)) ; The color field is optional
  ))
```

### type constraints

Sometimes we want to declare that a type adheres to some rule or condition. These are called "type constraints"
and Crisp supports them in conjuction with `with-template-type` and `declare`. We've already had some examples
in the fictional `move-discrete` shown earlier.  

Here is another example.
```
(with-template-type (T U)
  (declare (type-is T #'is-orderable?) (type-is U #'is-point?))
   ;; def-something  ...)
```

Crisp has several built-in type constraint functions:
- `is-numeric?` / `is-scalar?`
- `is-hardware-vector?`
- `is-integer?`
- `is-floating-point?`
- `is-orderable?`  => returns T if the type supports both `<` and `>` 

Additionally `def-enumeration` and `def-struct` automatically generate a `is-XXXX?` type constraint function
 for that enumeration or struct.   

Lastly, a custom type constraint function can be defined with `def-constraint` (see below).

#### `type-is` vs. `value-is`

The with-template-type form can be used to create generics that are parameterized by types (e.g., T which could be `int` or `float`) or by compile-time values (e.g., A which could be `:strided` or `:compact`). Crisp provides two corresponding constraint checks:

- `type-is` is used to constrain a template type parameter. It expects a type parameter and a predicate that operates on types.
`(type-is T #'is-numeric?)`
- `value-is` is used to constrain a template value parameter. It expects a value parameter and a predicate that operates on values. The most common use is for enumeration literals.

```
(def-enumeration phylum :arthropoda :chordata :nematoda )

;; Here, P is a template VALUE parameter, not a type parameter.
(with-template-type (P)
   (declare (value-is P #'is-phylum?))  
   (def-SOMETHING ...))

(gen-SOMETHING :chordata)  ; <-- awesome . Crisp generates a chordate. 
(gen-SOMETHING phylum)     ; <-- error .  The constraint expects a phylum value, not its type.
(gen-SOMETHING float)      ; <-- error.  'float' is a type, not a value from the 'phylum' enum
```


