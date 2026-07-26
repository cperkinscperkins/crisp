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

