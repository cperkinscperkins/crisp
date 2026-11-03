# Refused at compile time ✅


| Form | The message says |
|---|---|
| `(* B B)` | use `*!` |
| `(+ B B)`, `(- B B)` | use `+!` / `-!` |
| `(* A A)` | accumulators add and subtract, and nothing else |
| `(/ q q)` | convert to float first |
| `(to-float q)`, `(to-double q)` | needs a scale |
| `(to-float 1.5 s)` | only a quantized value takes a scale |
| `(to q-a 1.5)` | applies no scale; use `(to-q-a x scale)` |
| `(+ q-a q-b)` | different quantized types |
| `(*! q-a q-b)`, undeclared | declare a `def-qint-product` |
| `(to-q-b q-a-value m)` | a multiplier applies to an accumulator: widen it first |
| `(def-qint q :base float ..)` | must be an integer |
| `(def-qint q :base char :accum char)` | must be at least 16 bits |

