## Derived Types


`def-derived-type`, `make-XXXX`, `as-XXXX`, `is-XXXX?`

`def-derived-type` defines a NEW type derived from a stated type. The purpose for this is to allow custom overload of functions and properties. Additionally, with `set-derived` the compiler can be instructed to create a type hierarchy between two types.

### def-derived-type

```lisp
(def-enumeration derived-subst :no :equal :descendant :ancestor)

(def-derived-type <new-name> <type-expr> &key subst)

```

The `type-expr` is any type that supports a `make-` function (`vector`, `soa-vector`, `tensor` and things created from `def-struct` and `def-record`). Additionally, `def-derived-type` can be used with scalars (like `int` and `float`). See below.

The `subst` key should be from the `derived-subst` enumeration:

- `:no`
A value of the derived type cannot be passed as an argument to a function that expects the original type. Nor can a value of the original type be passed to a function that expects the derived type.
- `:equal`
Values of either type can pass for each other.
- `:descendant`
A value of the derived type can be passed as an argument to a function that expects the original type. But the reverse it not true.
*Logic:* The derived type is a specific **Descendant** of the original. It inherits the structure of the original and can pass for it.
- `:ancestor`
A value of the original type can be passed as an argument to a function that expects the derived type. But the reverse is not true - compilation error.
*Logic:* The derived type is a broad **Ancestor** (or Supertype) of the original. The original type is implicitly promoted to this ancestor type.

It's very important to remember that no matter what the substitution behavior is set to, that Crisp will choose the closest overloaded function (and emit a compilation error if that cannot be clearly determined). So even if using `:equal`, if function `foo` takes a single argument and is overloaded for types `A` and `B`, `foo #'(A=>...)` will NEVER be called with a value of type `B` unless `as-A` were used.

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
(def-function distance (a b)
    (declare #'(point point => float))
    #| pythagorean formula here |# )


;; a coordinate derived type is declared with 
;; a custom distance formula for it.
(def-derived-type coordinate point :subst :no)

;; -- distance --
(def-function distance (a b)
  (declare #'(coordinate coordinate => float))
  #| haversine formula here |# )

(let ((p1 (make-point :x 1 :y 2))
      (p2 (make-point :x 3 :y 4))
      (c1 (make-coordinate :x 1 :y 2))
      (c2 (make-coordinate :x 3 :y 4)))

  (distance p1 p2)  ; <-- evaluates to pythagorean distance between p1 and p2
  (distance c1 c2)  ; <-- evaluates to haversine distance between c1 and c2
  (distance p1 c2)) ; <-- compilation error, because :subst is :no

```

* In the example above if `:subst` were `:equal` it would also error, because the compiler wouldn't be able to successfully resolve which distance overload was desired.
* In the example above, if `:subst` were instead set to `:descendant` then `(distance p1 c2)` would accept `c2` as a `point` and would return the pythagorean distance.
* Or, if `:subst` were instead set to `:ancestor` then `(distance p1 c2)` would accept `p1` as a `coordinate` and return the haversine distance.

Crisp employs "multiple dispatch" for overloaded functions, determined at compile time. It does not support runtime dynamic dispatch of any sort.


### Limitation: single pass semantics required

- The "original" type that the new type is deriving from MUST exist already. This is a requirement even when compiling multipass.  This prevents "type loops" or "type recursion", which are disallowed.
- enumerations can not be used as an "original" type.


### make-XXXX

The `make-` function is automatically generated for structural types (structs, vectors, records). It is NOT generated for scalar derived types (like those derived from `int` or `float`); use `as-<derived>` for those instead. `make-<derived-type-name>` accepts the same arguments as the original type (`make-<original-type>`).

### as-XXXX

When a derived type is declared, then two type casting functions are automatically created. `as-<original>` which can be used to cast a value of the derived type as if it is the original, and `as-<derived>` which can be used to cast an original as the derived.

```
;; continuing the example above, with two distance overloads and points p1, p2 and coordinates c1, c2

(distance (as-coordinate p1) (as-coordinate p2)) ; would return the haversine distance. Even if :subst was set to :no

(distance (as-point c1) (as-point c2)) ; returns pythagorean distance.

```

### is-XXXX?

When a derived type is defined, a matching type constraint function is also automatically defined. `is-<derived>?` evaluates to true if the type in question matches the new derived type.

Note that this does NOT accept substitutions, regardless of `:subst`. Use `is-substitutable-for?` for that.

```
(def-struct point ...) 
(def-derived-type coordinate point :subst :ancestor)

(is-point? point) => True
(is-point? coordinate) => False
(is-coordinate? point) => False
(is-coordinate? coordinate) => True

```


### Derived Types and Arithmetic Operations

`def-derived-type` can be used with numeric types. There are several use cases for this (like a custom float that is "meters" and is not interchangeable with other floats or perhaps not with "yards").

The substitution rules (`:no`, `:equal`, `:descendant`, `:ancestor`) determine the return type when mixing "original" and "derived" types in arithmetic operations. We describe this behavior using the biological concept of **Dominance** (as in genes which are "dominant" or "recessive").

- `:ancestor` is **Dominant**.
An arithmetic operation that mixes the original type and the derived `:ancestor` type returns the derived type. The derived type asserts itself over the original.
- `:descendant` is **Recessive**.
An arithmetic operation that mixes the original type and the derived `:descendant` type returns the original type. The derived type yields to the base "wild type."
- `:equal` is also **Recessive**, though because the types are interchangeable, this doesn't mean much.
- `:no` disallows mixing, so there is no valid return type.

```
(def-derived-type dominant-float float :subst :ancestor)
(def-derived-type recessive-float float :subst :descendant)

(def-function derived-type-demonstration (f d r)
  (declare #'(float dominant-float recessive-float => dominant-float float))
  ;; these two addition operations mix the original type (float)
  ;; with a derived type.
  ;; The first addition returns a 'dominant-float' because :ancestor is Dominant.
  ;; The second addition returns a simple 'float' because :descendant is Recessive.
  (return (+ f d)       
          (+ f r)))

```

But pay attention to how derived types behave when mixed with each other:

Different `:ancestor` (Dominant) types cannot be mixed with each other, even if they share a common base type.

```
(def-derived-type meters float :subst :ancestor)
(def-derived-type seconds float :subst :ancestor)

(+ meters seconds) ;; COMPILATION ERROR

```

Meanwhile, `:descendant` (Recessive) types will yield to the base type and CAN be mixed (because they both decay to the base type):

```
(def-derived-type weak-a float :subst :descendant)
(def-derived-type weak-b float :subst :descendant)

(+ weak-a weak-b) ;; evaluates to a float.

```

When mixing `:ancestor` (Dominant) and `:descendant` (Recessive) types that share a common base type, the **Dominant** type wins out.

```
(def-derived-type dominant-float float :subst :ancestor)
(def-derived-type recessive-float float :subst :descendant)

(+ dominant-float recessive-float) ;; evaluates to a dominant-float

```


### set-derived

`(set-derived ancestor-type descendant-type)`

`set-derived` instructs the compiler to create a formal type hierarchy between two previously defined struct types. Unlike `def-derived-type`, this does not create a new type; it links two existing types together.

The syntax requires the **Ancestor** type first, followed by the **Descendant** type.

- **Ancestor** : The "smaller" or contained type. A value of the Descendant type can pass for this type (it can be "sliced" or viewed as the Ancestor).
- **Descendant** : The "larger" or extension type.

This declaration automatically generates the `as-<ancestor>` and `as-<descendant>` casting functions, allowing explicit conversion between the two. Implicitly, the Descendant can usually be passed where the Ancestor is expected (equivalent to the `:descendant` substitution rule in `def-derived-type`).

#### Requirements & Validation

Since `set-derived` is inherently unsafe (mapping memory of one type to another), the compiler enforces strict rules:

- Order of Definition: Both `ancestor-type` and `descendant-type` must be fully defined and declared BEFORE `set-derived` is called.
- Structs Only: Both types must be structs. This mechanism does not support other types like records, scalars, or functions.  Note that types that are derived from structs (using `def-derived-type`) are also accepted.
- Size Safety: The size of the `ancestor-type` must be less than or equal to the size of the `descendant-type` ().
- No Loops: Type recursion (A derives from B, B derives from A) is detected and causes a compilation error.
- Shape Compatibility: The types must have compatible memory layouts (shapes) for the length of the Ancestor. For example, if the Ancestor is `[int, float]`, the Descendant must start with `[int, float, ...]`.  This requirement is of the "flattened" structs (see below). 
These member appearing in both Ancestor and Descendant don't have to have the same names, but
MUST have the strict same type. ( ie no swapping floats for ints or unsigned for signed)


As mentioned, the two structs must have compatible shape WHEN FLATTENED (and accounting for `std140` alignment). This is most easily demonstrated with an example.  Below `set-derived` is used twice and both uses are perfectly valid.

```
(def-struct point (x int) (y int))
(def-struct vertex-flat (a int) (b int) (c int))
(def-struct vertex-nest (p point) (z int))

(set-derived point vertex-flat)
(set-derived point vertex-nest) ;; alternately, we could have done (set-derived vertex-flat vertex-nest)
```

Shape compatibility is evaluated on the flattened struct layouts: nested structs are recursively expanded to their scalar members. For each data member in the ancestor, the corresponding member in the descendant must have both the same type and the same byte offset (as determined by std140 alignment). Struct-level trailing padding is not part of the comparison.


### Branded Types

Using `def-derived-type` and `:ancestor` it is possible to create two types (for example `meters` and `yards`) that are both essentially `float` and can interoperate with `float`s but cannot interoperate with one another. You can't accidentally add or multiply `meters` and `yards` 
because the type system disallows it. 

"Branded" types let us apply that same safety concept but to individual instances of structs or records. Let us imagine some sort of array struct type was defined. It could elect to have a branded index type, and then "index of A-arr" would be different than "index of B-arr" even though A-arr and B-arr were both the same type of array struct. 

Branded types support the `:subst` key just like `def-derived-type`.  This mean that how, exactly, these types can and cannot interoperate with each other and with other types is yours to decide.

#### brand
```
(brand <new-name> <type-expr> &key subst (enforce :diff))
```

`brand` is nearly identical to `def-derived-type`. 

- `brand` is only usable inside the scope of a `def-struct` or `def-record`. It cannot be used elsewhere.
- `:subst` is a required key and cannot be omitted.
- like `def-derived-type` the `<new-name>` cannot collide with any existing type
  or derived type names (or type functions). BUT it CAN collide with other branded derived type names. This allows `index-t` to act as a generic type constructor. A function can accept `(index-t x)` and work on ANY struct that defines an `index-t` brand.
  The requirement here is that the same original type is used for each.
- `:enforce` is optional. It can be set to `:always` or `:diff`.  It defaults to `:diff` (see below)
- enumeration types cannot be branded
- `:c-t` (compile time) properties cannot use branded types
- unlike `def-derived-type`, no `make-XXXX` is defined for the new branded type when the original is a struct or record.

The new type that `brand` creates is a type function that accepts an argument of the type of the parent struct/record, and that returns the qualified "branded" type.

`:enforce :always` means the branded type is always generated and enforced.
`:enforce :diff` (the default) means the branded type is only generated when generating kernel derivatives (ie when using the `--differentiate` flag). Other times, it just falls back to the original type.  


```
(def-struct someStruct
  (brand index-t ulong :subst :equal :enforce :always)
  (length index-t)
  (cur-idx index-t)
  ...)

(def-function find-location (S match)
  (declare #'(someStruct something => (index-t S)))
  (let ((len (length~ S)))
  ...)
```

In the example above, we see that `index-t` is declared as a derived type inside `someStruct`. 
`someStruct` then proceeds to use that type for the declaration of two of its properties (`length` and `cur-idx`).  `find-location` declares its return type to be an "index-t of S" with the `(index- S)` form.  It binds `len` to `(length~ S)` which means `len` is also of type "index-t of S".


### What's with all this derived and branded types? Who is this for?

If you come to Crisp from a CUDA, C++, or OpenCL background then much of this derived type stuff 
probably seems foreign and unusual to you. Crisp types are organized in a DAG, not a tree. The 
`meters` not adding with `yards` is cool, but maybe you've never needed it in the past.
And branded types aren't on the menu at any of your regular feeding establishments. 

It's a lot of rigaamarole and you probably don't ever intend to use it. Why did anyone even 
trouble to do this?

The short answer is AI workloads. AI workloads need differentiable kernels to fit and adjust training data. Crisp provides auto differentiation with the `--differentiate` flag, and to support
that Crisp needs branded types, which need derived types. And in the Lisp philosophy, 
if something is useful to the compiler, then it is likely useful to the language users. And thus
it has been exposed to all Crisp users. The author hope it serves at least one of you well.

<!--

I'm removing this section as Storage Handles are done with def-record, not def-struct
and can't be extended like this.

They CAN be extended by nesting them in a def-record. Will update.

I'm also removing the std140 comment, because the rules for set-derived are stricter
and this shouldn't be a concern. 

### Extending Views

If you want to extend a type like `vector` with your own type that has extra data members, you can use `def-struct` in conjunction with `set-derived` for this.

```
(def-struct MY-VEC 
    (base (vector int))
    (new-prop int))

;; MY-VEC is a descendant; it extends the vector and can pass as one.
(set-derived vector MY-VEC :subst :descendant)

```

### std140

All Crisp structs are aligned with the `std140` layout and alignment practice. Keep this in mind when using `set-derived` and type casting, as things might not work like you'd expect in a language like C.

-->



