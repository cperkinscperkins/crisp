## `declare` and templates


### `type-is`
```
(<T>
  (declare (type-is T #'is-floating-point?))
  ...)
``` 
`type-is` can appear in the `declare` block at the beginning of a template. It lets you
leverage [type constraints](#type-constraints).

### `value-is`
```
(<T A>
  (declare (value-is A #'is-alignment?))
  ...)
```
Also for [type constraints](#type-constraints)


