# Numeric Type Promotion, Casting, Conversion ✅


It should surprise no one that Python, C++, and Common Lisp all have different
rules for type promotion. And, without naming names, no one will be surprised to 
learn that at least one of those systems is a constant source of bugs for its users.

Crisp takes a strict "hardware first" approach to automatic type promotion and 
requires that any auto promotion is both "safe" and "correct".

The rule is that implicit promotion is performed within the same category when
going from a smaller size to a larger size, leveraging fast hardware instructions (zero extension, sign extension, or floating-point conversion).
The three "categories" are signed integers, unsigned integers and floating point numbers.

Therefore these are the promotions Crisp performs automatically:

| | |
|-------------------|---------------------------------------------|
| Unsigned Integers | `uchar` -> `ushort` -> `uint` -> `ulong`    |
| Signed Integers   | `char` -> `short` -> `int` -> `long`        |
| Floating Point    | `half` or `bfloat16` -> `float` -> `double` |
| Integer to Float  | int → float, int → double, long → double, (etc for unsigned). |

This applies element-wise to hardware vector types as well:
`ucharN` -> `ushortN` -> `uintN` -> `ulongN`    (etc for signed integer and floating point).

All other conversions require an explicit cast.

```
;; COMPILE ERROR: No automatic promotion from float to int. (see Value Conversion section for CORRECT)
(let ((f (some-float-returning-op)))
  (some-int-op f))

;; COMPILE ERROR: No automatic promotion between signed and unsigned
(let ((u (some-unsigned-int-returning-op)))
  (some-signed-int-op u))

;; CORRECT
(let ((u (some-unsigned-int-returning-op)))
  (some-signed-int-op (to-int u)))
```

### Convert: `to-` , Cast `as-`

If you need to move between numeric types, Crisp gives you two affordances: `to-XXXX` and `as-XXXX` where `XXXX` is 
the target type name (eg. `to-float`  `as-int`)

#### Value Conversion 
`to-` converts the type "correctly" (or as correct as can be done) and will move bits to do so.  It is the equivalent
to a "static cast" in C++.  Converting across categories, or to smaller sizes, may lead to loss of information and/or 
accuracy.

IMPORTANT:  for floating point to integer conversions, `to-int` and friends are NOT DEFINED. 
Instead, you must explicitly choose which conversion you want:  `truncate`, `floor`, `ceil`
or `round`.  See the section on integer division for a comparison.

<!-- NOTE: maybe move that section on truncate/floor/ etc to yet another place? -->

```
;; CORRECT - we must use ceil, floor, truncate or round to convert floating point to integer
(let ((f (some-float-returning-op)))
  (some-int-op (ceil f)))
```

#### Bit Reinterpretation
`as-` just tells the compiler to pass the value through with no action taken. No bits moved. It is inherently unsafe.
It is the equivalent of "reinterpret cast" in C++.


```
;; this compiles, but is most likely wrong if some-int-op needs to perform actual numeric calculations
(let ((f (some-float-returning-op)))
  (some-int-op (as-int f))) ;; <-- DANGER
```

#### `(as T someVal)`

Rather than `as-XXXX`, you can also use the `as` type cast. It takes a value and a desired type arg.
Example: `(as uint someInt)` 

Note there is no equivalent shorthand for _conversion_ (ie no `to`). Use  `to-XXXX` .


