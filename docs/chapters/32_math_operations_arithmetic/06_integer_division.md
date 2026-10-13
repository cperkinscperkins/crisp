# Integer Division ✅


There are four  integer divison functions: `/`, `ceil` ,  `floor` and `round`.

All four of them return both the quotient and remainder and differ only 
in how the results are rounded.

The remainder is available where you bind it -- `(let ((q r (floor a b))) ...)`; used as an ordinary
expression, `(floor a b)` is the quotient.  Both operands must be the same integer type (an integer literal
is converted).  On floats the two-argument forms are a compile error; with ONE argument,
`(floor x)` / `(ceil x)` / `(round x)` / `(truncate x)` convert a float to an `int` (round: ties to even).
Unsigned operands divide unsigned.

#### `rem` and `mod` ✅
The remainders on their own, for integers and floats:
- `(rem a b)` -- remainder of truncating division; its sign follows the dividend, like C++ `%`.
- `(mod a b)` -- remainder of `floor` division; its sign follows the divisor, which is what wrap-around
  indexing wants: `(mod (- i 1) n)` is `n-1` at `i = 0`.
```
(rem -1 4) => -1      (mod -1 4) => 3
(rem 7 -3) =>  1      (mod 7 -3) => -2
(mod -1.5 4.0) => 2.5
```
They agree when both operands are non-negative.  A zero float remainder keeps the dividend's sign (IEEE
`fmod`), so `(rem -8.0 4.0)` is `-0.0`.

`#(divisor divident => quotient remainder)`


#### `/` truncating division ✅

Operates the same as `/` in C++ or `truncate` in Common Lisp.  
This function rounds toward 0 and returns BOTH the quotient and the remainder.

```
(/ 10 3)   => 3 and 1

(/ -10 3)  => -3 and -1
```
Because this division operates the same as in C/C++, this division is familiar and
the "default".  But note that for many GPU numeric workloads, `floor` is more reliable
because its behavior is consistent on both the negative and positive side of the number line. 

#### `floor` ✅

This rounds the result down toward negative infinity. It returns the quotient and the remainder.
```
(floor 10 3)   => 3 and 1

(floor -10 3)  => -4 and 2
```

#### `ceil` ✅

This rounds the result up toward positive infinity. It returns the quotient and the remainder.
```
(ceil 10 3)   => 4 and -2

(ceil -10 3)  => -3 and -1
```

#### `round` ✅

In addition to the three above, there is also `round`. This performes division and rounds the quotient towards the nearest integer. If equidistant it "rounds half toward even" following the  IEEE 754 standard.  Like the others, it returns both the quotient and the remainder. 

```
(round 5 2 ) => 2 and 1.  2.5 is rounded DOWN towards the nearest even integer, which is 2
(/ 7 2)      => 3 and 1   Notice how the truncating / differs from round (below).
(round 7 2)  => 4 and -1  3.5 is rounded UP towards the nearest even integer, which is 4.  
(round 8 2)  => 4 and 0
(round 9 2)  => 4 and 1   4.5 is rounded DOWN towards the nearest even integer, which is 4. 
```

#### Comparison

|Function	    | Behavior	    | (func 10 3) | (func -10 3)|
|-------------|-------------------------|--------|--------|
| (/ a b)     |	Rounds toward zero      | 3, 1  |	-3, -1 |
| (floor a b) |	Rounds toward -∞        |	3, 1  |	-4, 2  |
| (ceil a b)	| Rounds toward +∞        |	4, -2 |	-3, -1 |
| (round a b) | Rounds nearest neighbor | 3, 1  | -3, -1 | 


