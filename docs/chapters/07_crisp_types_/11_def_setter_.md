## def-setter ✅


`def-setter` can be used to define an overloaded function to set any property.
It uses the same name of the property but takes an additional argument.  
The return type for all setting functions is always nil.  

If the setter parameters are typed, there is no need for an additonal declare.

```
;; this custom setter function negates x

;;;  x~  (setter)
(def-setter x~ (p newVal)
   (declare #'(point float => nil))
   (set! (~x~ p) (- newVal))) 

(set! (x~ somePoint) 14) ;; <-- the x of somePoint is actually stored as -14 
```

If overloading the setting of a struct property and you wish to use that struct
consistently and correctly in a `soa-vector`, then an additional overload
for that is recommended as well. The compiler will warn if it detects the absence.
In the future, Crisp may handle this automatically. 
```
;; additional overload if we are using soa-vectors.

;;;  x~   (setter soa)
(def-setter x~ (sv idx newVal)
    (declare #'((soa-vector point) ulong float => nil))
    (set! (~ (x~ sv) idx) newVal))
```


