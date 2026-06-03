# Function Overloading ✅


Crisp support function overloading for functions defined with `def-function`, `def-grid-function`, as well as property access functions on 
some of the other types. Note that property access via a `soa-vector` requires an additional overload. The compiler
will warn if it detects `soa-vector` property access with an asymmetric overload.

Overloaded functions can have the same name, but different type signatures. The compiler will use the 
types of the given parameters to determine which overload should be called. 

`def-kernel` function CANNOT be overloaded. Each kernel function must have a unique name.

As mentioned, the property access functions that some types support can be overloaded as well (discussed later), 
but the `make-XXXX` functions CANNOT be overloaded. 


