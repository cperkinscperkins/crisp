## when-global-linear-id-is / when-local-linear-id-is


Unlike the previous `when-XXXX-is` , these two calculate the relevant linear id, and so there are no
variants for higher dimensions.   
Note that the global linear id is always relative, an absolute version isn't supported.  (See discussion of `when-thread-is` / `abs-when-thread-is` above.)

```
(when-global-linear-id-is id <expr>)

(when-local-linear-id-is id <expr>)

```

