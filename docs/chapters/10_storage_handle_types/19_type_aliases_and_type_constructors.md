## Type Aliases and Type Constructors


The type names for vectors and functions,  etc. can be rather long and ungainly. 
 `def-type` is provided to help shorten these and make them more usable.  

In it's simplest application, it just provides type aliasing.

```
(def-type T int)  ;
(def-type addTwoT  (type-signature-of #'addTwo))
(def-type addThreeT #'(long long long => long))
(def-type floatVecT (vector-type float :global))
```

A **Type Constructor** is a function that takes a type as an argument and returns a new, specialized type. In Crisp, you create these using the `with-template-type` form, which provides a clean and powerful way to define generic types. When you use `with-template-type` to define a new type (like a struct or a vector alias), the compiler automatically generates a corresponding `XXXX-type` function, which is your type constructor. You can then use this function to create concrete types, such as `(anotherGlobalVecT-type int)` which represents a global vector of integers, which can be used in your function declarations. This approach separates the definition of the generic type from its specific instantiation, making your code more readable and reusable.

```
(with-template-type (T)
  (def-type anotherGlobalVecT (vector-type T :global)))

;; -- count-ints --
(def-function count-ints (v)
    (declare #'((anotherGlobalVecT-type int) => ulong))
 ...)

```
<!--
NOTE FOR FUTURE DEVELOPMENT: `(def-type-function (T U V) ...)`  
In theory we might be able to allow the user to define their own type functions.
They would just have to return a type. Because it potentially might call actual functions
(either user defined or built-in) it would mean CRISP code would need to be exectuable by
the compiler. Which will probably happen, if we are being totally honest. So long as it
didn't directly invoke any GPU-only capaibilities (like the shuffle functions) it could work.
-->


