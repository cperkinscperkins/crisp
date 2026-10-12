# Integer Only Operations ✅


- `ash`   ;; arithmetic shift `(ash I count)`
- `logand`
- `logior`
- `logxor`
- `lognot`
- `popcount`

`ash` follows Common Lisp and is defined for EVERY count, identically on every GPU: a positive count shifts
left, a negative count shifts right -- arithmetic (sign fill) for signed types, logical for unsigned -- and a
shift by at least the bit width gives 0 (left), or 0 / -1 (right, -1 for a negative signed value).  A literal
count compiles to a single shift; a run-time count adds a select or two, branch-free.
```
(ash 1 3)    => 8
(ash -16 -2) => -4
(ash 5 40)   => 0     ; on an int
(ash -5 -40) => -1
```
`popcount` counts the set bits of the two's-complement representation, so `(popcount -1)` on an `int` is 32
(Common Lisp's `logcount` would count the zero bits of a negative number instead).
`logand` / `logior` / `logxor` take two operands of the same integer type; `lognot` one.

