# Refused at compile time ✅


| Case | The message says |
|---|---|
| `(*! w w)`, `(* w w)` | no target multiplies blocks directly yet |
| `(+ w w)` | Cannot operate on .. |
| `(max (~ w 0) (~ w 1))` | codes from different blocks have different scales |
| `(+ (~ w 0) (~ w 1))` | a microfloat code is not a number until it is decoded |
| A block, or a record holding a handle, as a kernel parameter | cannot be a kernel parameter |
| `:base fp8-e8m0` | `:base` must be fp4, fp8-e4m3 or fp8-e5m2 |
| An odd `fp4` `:shape` | must have an even size |
| `:shape (4 4)` | one positive block size |
| `:accum half` | `:accum` must be float for now |
| `(scale q-a)` on a qint | only a microfloat block has a scale |


