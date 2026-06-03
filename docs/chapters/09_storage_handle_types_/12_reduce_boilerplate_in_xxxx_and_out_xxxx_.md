# Reduce Boilerplate: `in-XXXX` and `out-XXXX` 📝


```
(in-cell T)
(out-cell T)
(in-vec T A)
(out-vec T A)
(in-mat T A)
(out-mat T A)
```

Storage Handler type declarations can be long, but for most kernel arguments there are 
 two common choices:  global readable Storage Handles for input paramters, and global writeable Storage Handles
for output parrameters.  Crisp has prepared pairs of `def-type` aliases to make this easier.
 Just specialize them with the element type and align and you are set.

Example:
```
(def-kernel my_kernel (A B &out C)
  (declare #'((in-vec float :compact) (in-vec float :compact) (out-vec float :compact)))
  ...)
```

Possible Implmenetionat
```
(<T A>   ;; <-- shorthand notation for with-template-type
  (def-type in-vec (vector T :align A :address-space :global))
  (def-type out-vec (vector T :align A :address-space :global)))
```


