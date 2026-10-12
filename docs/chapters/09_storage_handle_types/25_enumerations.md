# Enumerations ✅


```
(def-enumeration address-space (:global 1) :local :private)

(vector int :address-space :global)
```

In the example above, `def-enumeration` defines a new type called `address-space`, which is just a set of keywords.
Unless enumerations have conflicting keys, all unconflicted keys are automatically promoted to the 
global default namespace. ( And we don't support namespaces ).

#### type constraints: is-XXXX? ✅

Using `def-enumeration` automatically generates `is-XXXX?` for that enumeration name, which can be used as a type constraint function
in `with-template-type`.  See the discussion of type constraints in `with-template-type` for more information.

#### Using enumeration values ✅

- Compare enumeration values with `=` (and `!=`): `(if (= mode :mul) ...)`.  Crisp has one equality; there is no `eq`.
- An `if` whose branches are keywords of the same enumeration has that enumeration's type: `(if (> v 0.0) :mul :add)`.
- A bare keyword passed to a template function makes the template parameter the enumeration that contains the keyword.
  If the keyword belongs to several enumerations (a conflicting key), that is a compile error: pass it through a parameter
  declared with the enumeration you mean.
- Under `--differentiate` an enumeration value carries no gradient; a function that returns one is differentiated like one
  that returns an `int`.



