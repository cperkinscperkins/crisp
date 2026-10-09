# `:stream-bytes-in-flight` ✅


`:stream-bytes-in-flight` is how many bytes of loads each thread should keep in flight in a **stream
loop** (`loop-vector-stride`, and so `reduce-vec`). The loop is unrolled by that budget over the
element size (at most x8), unless its body starts with an explicit `(declare (unroll ...))`.

```
:stream-bytes-in-flight 16
```

It is a MEASURED key, and absent means no unroll default. On an Intel Arc B580 16 bytes per thread
is the knee (57% of the read peak at one 4-byte load per trip, 99% at 16 bytes); the builtin `bmg`
profile carries it. NVIDIA parts leave it out -- their backend compiler unrolls the loop itself, and a
hint would stop it (see `tests/spec/180-loop-unroll/`).

