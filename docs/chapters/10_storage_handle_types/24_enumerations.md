## Enumerations


```
(def-enumeration address-space (:global 1) :local :private)

; Both of these are acceptable usage:
(vector int :global)
(vector float address-space:global)

```

In the example above, `def-enumeration` defines a new type called `address-space`, which is just a set of keywords.
Unless enumerations have conflicting keys, all unconflicted keys are automatically promoted to the 
global default namespace. ( And we don't support namespaces ).

### type constraints: is-XXXX?

Using `def-enumeration` automatically generates `is-XXXX?` for that enumeration name, which can be used as a type constraint function
in `with-template-type`.  See the discussion of type constraints in `with-template-type` for more information.



