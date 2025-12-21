# Complex Numbers


Complex numbers are fairly straightforward in Crisp.

The implementation Crisp provides uses a template and `def-struct` like so:

```
(with-template-type (T)
  (declare (type-is T #'is-floating-point?))
  ;; -- complex --
  (def-struct complex (real T) (imag T)))

```
Thus to make them: `(make-complex :real someFloat :imag otherFloat)`
Or declare their type: `(complex-type double)`

The arithmetic functions fall out easily:
```

;; this macro lets us use "a b c d" notation in the body of our
;; binary arithmetic functions. Much easier to read. 
;; Just remmber to wrap in parantheses: (a)

;; -- with-complex-components --
(defmacro with-complex-components ((z1 z2) &body body)
  "Establishes local macros a, b, c, d for the components of z1 and z2."
  `(macrolet ((a () '(real~ ,z1))
               (b () '(imag~ ,z1))
               (c () '(real~ ,z2))
               (d () '(imag~ ,z2)))
     ;; Execute the body within the scope of the local macros
     ,@body))

(with-template-type (T)
  (declare (type-is T #'is-floating-point?))

  ;; ( + ) Addition
  (def-function + (Z1 Z2)
    (declare #((complex-type T) (complex-type T) => (complex-type T)))
    ;; $(a+c) + (b+d)i$
    (with-complex-components (Z1 Z2)
      (make-complex :real (+ (a) (c))
                    :imag (+ (b) (d)))))

  ;; ( - ) Subtraction
  (def-function - (Z1 Z2)
    (declare #((complex-type T) (complex-type T) => (complex-type T)))
    ;; $(a-c) + (b-d)i$
    (with-complex-components (Z1 Z2)
      (make-complex :real (- (a) (c))
                    :imag (- (b) (d)))))

  ;; ( * ) Multiplication
  (def-function * (Z1 Z2)
    (declare #((complex-type T) (complex-type T) => (complex-type T)))
    ;; $(ac-bd) + (ad+bc)i$
    (with-complex-components (Z1 Z2)
      (make-complex :real (- (* (a) (c)) (* (b) (d)))
                    :imag (+ (* (a) (d)) (* (b) (c))))))

  ;; ( / ) Division
  (def-function / (Z1 Z2)
    (declare #((complex-type T) (complex-type T) => (complex-type T)))
    ;; Formula: (ac+bd)/(c²+d²) + (bc-ad)/(c²+d²) i
    (with-complex-components (Z1 Z2)
      (let ((denom (+ (* (c) (c)) (* (d) (d)))))
        (make-complex
          :real (/ (+ (* (a) (c)) (* (b) (d))) denom)
          :imag (/ (- (* (b) (c)) (* (a) (d))) denom))))))
```

Additionally, Crisp provides the following operations for complex numbers:

| Operation       | Descrption                                              |
|-----------------|---------------------------------------------------------|
| `(conjugate z)` |  If $z = a + bi$, returns $a - bi$.                     |
| `(magnitude z)` | Returns $\sqrt{a^2 + b^2}$ (a real number).             |
| `(phase z)`     | Returns the angle $\text{atan2}(b, a)$ (a real number). |
| `(real~ Z)`     | Retrieve the `:real` part of the complex                |
| `(imag~ Z)`     | Retrive the `:imag` part of the complex                 |


And the transcendantals ( `exp`, `log`, `sqrt`, `sin`, `cos`, etc )

