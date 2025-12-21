## Load Chunk / Store Chunk


```
(load-chunk  <problem-space> <chunk> &optional (identity-val 0) (<problem-space-coords>) (<chunk-size>))

(store-chunk <chunk> <problem-space> &optional transformF (<problem-space-coords>) (<chunk-size>))
```

`load-chunk` will map the chunk to the appropriate place in the problem space and 
load the chunk with the data there. If used within the scope of `thread-stride` 
then the `<problem-space-coords>` and `<chunk-size>` do not need provided.
But this function can be used in other contexts so long as those are provided. 
The loading of "cooperative", with each thread setting one value.

Similarly, `store-chunk` does the reverse - copies memory from some chunk vector
into the appropriate location in the problem space data. This is usually used with 
some `&out` output memory whose size is identical to the problem space. 

The usual practice is that the problem space vector is `:global` and the chunk is `:local`.

`load-chunk` takes an optional `identity-val` argument. This is used when the problem space
is not evenly divisible by the chunk size.  In that case, the chunk will be correctly loaded with
data from the problem space where possible, but the REMAINING values of the chunk will be loaded with `identity-val`

`store-chunk` take an optional `transformF` argument. This is a function of `binop-type` that
can be used to transform the value as it is stored. 

### local-barrier

Both `load-chunk` and `store-chunk` invoke `(local-barrier)` at the completion of their
operation. This prevents read-after-write and write-after-read race conditions. 
But be aware, that this also means these functions should NOT appear in conditional blocks 
( `when`, `if`, `cond`, `unless`) or you will incure a deadlock. The Crisp compiler should
detect this and emit an error.


