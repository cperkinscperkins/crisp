# Compile Time Resolution ✅


Crisp does not support "true" higher order functions. Doing so would introduce too much divergence,
which would destory performance.

Instead, all higher order function usages must be resolveable at compile time.

The flip side benefit of this is that expressions like this:
```
(map-stride #'op-fma (A-vec B-vec C-vec) RES-vec)
```
are possible to express AND and are performant. There is no actual "function call" to `op-fma`. 

#### Runtime Function Variables forbidden

While it is possible to assign a variable to a #'function, the restrictions on compile time resolveable 
are still in place. 

For example, this will result in a compile error if `someExpr` is not determinable by the compiler to be compile time constant.
```
(let ((f (if someExpr #'+ #'-)))  ...)
```
If that was the intention, then these would work
```
(let ((f (if+ someExpr #'+ #'-)))  ...)
; OR
(let ((someExpr ...)
      (f (if someExpr #'+ #'-)))
  (declare (constexpr someExr)) ...)
```

