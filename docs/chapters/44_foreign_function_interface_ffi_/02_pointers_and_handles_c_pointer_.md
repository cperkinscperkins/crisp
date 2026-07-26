# pointers and handles: `c-pointer` ✅


```
(c-pointer :address-space <:global | :generic | :local | :constant | :private>)
```

`c-pointer` can be used to declare a pointer variable type. It must be qualified with `:address-space`.

Just as in `def-kernel-exact`, pointer arguments to foreign functions can have their type declared using `voidp` or `c-pointer`. But note that to actually use a pointer or dereference it, you'll need to use a marshalling form (like `marshall-cell` or `marshall-vector`), which will require a complete type that has `:address-space`, `:align` and possibly other properties to be specified.

