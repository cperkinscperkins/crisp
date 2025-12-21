# `let`

<!-- NOTE:  this section, and the one on set! and declare should probably appear MUCH earlier in the doc -->

`let` is the form for declaring variables in the scope of a function. 

`(let  (<VAR-DECLARATIONS>)  <PROGN>)    => (return-type-of <PROGN>)`

In Crisp `let` is like `let*` from Common Lisp. Variables are declared in order and build the
environment together.  

Unlike `let*` , Crisp `let` supports binding of multiple variables.  There is no
`multiple-variable-bind` form in Crisp, `let` is used instead.

The return value of the `let` expression is the return value(s) of the
last expression in its closure, in its implicit `progn`.

```
(let ((sum (+ a b))
      (diff  (- sum c))      ;; can refer to 'sum' since it was declared before.
      (fail  (+ someNum 9))  ;; this would fail, as someNum hasn't been declared yet.
      (someNum   0.2)        ;; is this a bfloat16, half, float or double? 
      (otherNum 0.1)    
      (quotient remainder (/ a b)))  ;; / returns multiple values, we can bind them all
  (declare (type someNum double) (type otherNum half))    ;; finally declare the type of someNum

  (dec! diff) ;; mutable
  (munch sum diff someNum otherNum remainder))  ;; <-- the return type of #'munch
                                                ;; is the return type of this `let`
```

