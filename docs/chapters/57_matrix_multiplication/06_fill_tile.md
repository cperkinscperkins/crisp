# fill-tile ✅

```
(fill-tile <some-tensor> <some-value>)
```
`fill-tile` can be used with any tensor, (vectors, matrices, etc). It simply fills it with a value.
It is a simple cooperative workgroup operation (it usually uses `workgroup-stride` under the covers) and is intended, as named, to be used on simple tiles.  For a very large tensor, use one of the other strides to implement your own.  Note: for register tiles (`make-register-tile`) it gets unrolled per fragment. Quite performant. 


