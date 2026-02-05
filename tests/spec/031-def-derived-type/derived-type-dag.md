User Derived Types mean we now have type trees. "type loops" and "type recursion" are disallowed, and the type deriviation declarations do not support multipass semantics - meaning that for any 

`(def-derived-type NEW ORIG :subst :v)` , the `ORIG` type MUST exist already, else a compile error.

This, for example, should error:
```
(def-derived-type coordinate point :subst :equal)
(def-struct point (x int) (y int))
```
whereas if the two expressions were in reverse order, it'd be fine. 


IMPLEMENTATION
==============

Each of the three numeric type classes (signed integers, unsigned integers, floating points) will need to be its own DAG prepopulated with the numeric types Crisp supports.

QUESTION: what about the machine vector types like float4 etc? 


Additionaly, there will have to be a "collection" of struct DAGs for types derived from structs.
And a collection of record DAGs for types derived from def-record.

Obviously, the Compiler itself will likely need some helper routines like `find-common-ancestor` and `is-type-in-DAG`, `is-type-derived-from?` `is-type-ancestor-to?` .  
There is a `(is-substitutable-for? substT baseT)` in the design doc for users. We don't  have type constraints supported yet. 