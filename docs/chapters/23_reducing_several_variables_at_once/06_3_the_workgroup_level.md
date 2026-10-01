# 3. The Workgroup Level


`reduce-workgroup` takes the same clauses. Each clause may name its own `:return-vec` and
`:local-scratch-vec`:

```lisp
(reduce-workgroup #'argmax-combine
                  ((my-val (type-min float) :return-vec wg-vals)
                   (my-idx (type-max ulong) :return-vec wg-idxs))
                  :message "argmax partials")
```

