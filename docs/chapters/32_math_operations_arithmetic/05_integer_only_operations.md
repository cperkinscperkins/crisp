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

#### Shifts and rotates: `shift-left` `shift-right` `rotate-left` `rotate-right` ✅

`ash` is the shift that is always right.  These four are the shifts that are always cheap: the count is taken
**modulo the bit width** (OpenCL C's rule), so every count is still defined, but there is no select chain to
pay for -- a shift is one instruction (two if the compiler cannot prove the count's range), and a 32-bit
rotate is one funnel shift (`shf.l.wrap` / `shf.r.wrap` on NVIDIA).  Reach for them when the count is a
run-time value in a hot loop; `ash` costs a few selects there because it must honour a count of either
sign and any size.
```
(shift-left 1u 3)         => 8
(shift-left 1u 33)        => 2            ; 33 mod 32 = 1
(shift-left 1u -1)        => 2147483648   ; -1 mod 32 = 31: NOT a right shift
(shift-right -16 2)       => -4           ; signed: arithmetic (sign fill)
(shift-right 4294967295u 28) => 15        ; unsigned: logical
(rotate-right 1u 1)       => 2147483648
(rotate-left 2147483649u 1) => 3
(rotate-right x -1)       ; = (rotate-left x 1)
```
The first operand is a scalar integer of any width and fixes the result type; the count may be any integer
type.  All four are integer operators, so they carry no gradient under `--differentiate`.

