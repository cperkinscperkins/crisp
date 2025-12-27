## Incomplete Types


An "Incomplete Type" is a composite type (defined via `def-record` or `def-struct`) where one or more of its compile-time properties have not been specified in type declaration.

For example, given a record definition:
```lisp
(def-record pants
  (size int)
  (color someEnum :c-t))
```

The `make-pants` call is always required to have both `:size` and `:color` specified (e.g. `(make-pants :size 32 :color :blue)`), but the actual declaration of the type, as might appear in a function parameter list, can elide compile time properties and be "incomplete".
```
;; a 'complete' type: all compile time properties specified
(pants :color :blue)

;; an 'incomplete' type: one or more compile time properties unspecified:
(pants)
;; also valid and 'incomplete':
pants
```

Incomplete types allow for polymorphism in internal functions. You can write a function that accepts any kind of `pants`, regardless of (compile time) color.

### Rules for Incomplete Types:
1. **Allowed in `def-function` and `def-grid-function`**: You may declare parameters with incomplete types in standard functions.
2. **Forbidden in `def-kernel` and `def-kernel-exact`**: Kernel parameters (the boundary between host and device) MUST have fully specified complete types. The host must know the exact layout and semantics of the data it is passing. Incomplete types cannot be used there.  Note that  `gen-XXXXX`, which can be used to generate a kernel from a grid function, when encountering an incomplete type will use its default value (if specified) or emit a compile error (if no default was specified)
3. **Compile Time Properties Only**: Runtime member fields are not required in the type declaration anyway, so the question of "complete" vs "incomplete" does not apply to them.

This question of "complete" vs "incomplete" matters because if a `:c-t` property
is declared in the type constructor, then the compiler will enforce that requirement. Whereas an incomplete type is more flexible. 

```
(def-record pants
    (size int)
    (color someEnum :c-t))

(def-function op-only-blue (blue-pants)
  (declare (type blue-pants (pants :color :blue)) (return-type nil))
  ...)

;; this function takes any pant, but calls an operation that only
;; accepts blue pants.  This is potentially a problem, but, by itself,
;; would not trigger a compile time error. 
(def-function remeasure (p)
  (declare #'(pants => int))
  (op-only-blue p)
  (- (size~ p) 2))

;; kernels are required to have complete types for all parameters and return
;; values.  Here, we see (pants :color :blue) is specified, therefore
;; this is safe and no compile error is generated.
;; BUT if the color were :red, then an error would appear.
(def-kernel omg (cbp &out csz)
   (declare #'((in-cell (pants :color :blue)) &out (out-cell int)))
   (let ((new-size (remeasure (~ cbp))))
     (set! (~ csz) new-size)))
```



