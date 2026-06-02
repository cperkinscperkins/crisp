# `op-pack-11` / `op-unpack-11`

Take three floats and store them in 32 bits by converting two of them to 11 bit floats and the third
to a 10 bit float.  Unpacking them to normal 4-byte floats for operations

```
(op-pack-11 float-1 float-2 float-3) => uint
(op-unpack-11 uint) => float-1 float-2 float-3
```

### Best Practice

Rather than passing a vector of `uint` around, use `def-derived-type` to
define your own type and do the packing in the setters and getters.

```
(def-derived-type my-HSL-vec (vector uint :align :compact) :subst :no)

(def-function ~ (vec index)
   (declare #'(my-HSL-vec uint => float float float))
   (op-unpack-11 (~ vec index)))


(def-setter ~ (vec index f1 f2 f3)
   (declare #'(my-HSL-vec uint float float float => nil))
   (set! (~ vec index) (op-pack-11 f1 f2 f3))))


(def-kernel distort (hsl-scene)
  (declare (type hsl-scene my-HSL-vec))
  (loop-vector-stride hsl-scene (i)
    (let ((hue sat light (~ hsl-scene i)))
      ;; note - can someone tell me what this does? I bet it's not good.
      ;; but, hey, it's coalesced access. So who cares? 
      (inc! hue .3)
      (dec! sat .2)
      (inc! light .1)
      (set! (~ hsl-scene i) hue sat light))))
```

