# compile-time properties

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

A `make-XXXX` call gives its value the complete type: when `address-space` has no default,
`(make-addressable :value 10 :address-space :global)` is an `(addressable :address-space :global)`.
Such a value can be passed to a parameter declared with that complete type, with a `def-type` alias of it
(`(def-type global-addr (addressable :address-space :global))`), or with the bare, incomplete `addressable` --
in which case the function is instantiated once per distinct set of compile-time values.  Runtime members are
read, and `set!` through their accessors, on any of these.

> **Implementation status**: a property that HAS a default (`access` above) is not yet carried into the type
> when `make-XXXX` overrides it -- the value keeps the default's type, and its `access~` answers the default
> (adversarial ADV-023, together with ADV-012 / ADV-013).
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

