# when-is-last-warp / when-is-last-thread 📝

```
(when-is-last-warp (lane-id) ...)
(when-is-last-thread (local-id) ...) ; <-- available in 0,1,2,3 arity
```
That "last man standing" pattern is also availabe for the last warp in a workgroup,
or the last thread in a workgroup. These use a local `atomic-dec!` so they have less
stall. See `when-is-last-workgroup` for an explanation. 

For the last thread or warp in the last workgroup, simply compose the two constructs:
```
(when-is-last-workgroup ()
  (when-is-last-thread ()
   ...))
```

