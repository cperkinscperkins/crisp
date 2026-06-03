# type names vs. type constructors

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


