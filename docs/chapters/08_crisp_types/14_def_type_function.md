## def-type-function


Similar to `def-constraint`, `def-type-function` is not a regular function.
A type function takes one type and returns another. That's it. Having such is just useful enough
to make certain macro and meta-programming tasks possible and palatable. It does not require 
a `(declare ..)` block.

Type functions are evaluated at compile time (only). They cannot perform other actions like defining types 
or generating specializations. 

Possible example:
```
;; -- get-unsigned-type --
(def-type-function get-unsigned-type (InputType)
  (cond ((<= (sizeof InputType) (sizeof uint)) 'uint)
        (T 'ulong)))
```


    
