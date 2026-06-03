# Lambda No, Curry Yes 📝

Because the GPU has only one callstack per warp (not one per thread), lambda functions are 
not supported. This is because they enable lexical closures (capturing variables from their surrounding scope),
 which would add significant complexity to the kernel's memory model and is 
 difficult to map efficiently to GPU hardware.  
The Common Lisp `labels` macro is similarly not supported for this same reason.

#### `curry` 📝

```
(curry #'someFunction <uniform-arg0> ...)
```

But a limited form of "currying" IS available.  
The `curry` form takes a function of N arguments as its first arg, followed by M uniform args where 
M <= N. It returns a new function that accepts (N-M) arguments and can be passed to other HOF functions.

By "uniform" we mean that the argument binding values that are accepted by the `curry` form MUST
be uniform across the entire workgroup.  Thus, they either must originate in the kernel parameter list,
be declared `uniform`, forced to be uniform with `to-uniform`, etc. If crossing function calls, the compiler
will check up through the call chain to make sure that it can verify that these captures to `curry` are, in fact,
uniform. This particular compiler check will 
be deferred for library functions marked as `entrypoint` BUT the requirement remains and will be enforced
when the call-chain ends up underneath a kernel.  This requirement is so capturing them doesn't introduce divergence or the complexities of capturing thread-local state

The example in the next section shows `curry` in action.

<!--
Implementation Notes
for transpilation, create a new uniquely named inline C function that takes each capture as an arg, PLUS the expected arg
and use that instead of original 
-->

#### `compose` 📝

```
(compose #'secondFunction #'firstFunction) => #'combinedFunction
```

`compose` combines to functions. For `firstFunction` whose type is `#'(T => U)` 
and `secondFunction` whose type is `#'(U => Z)`  a new function is returned that 
performs both, first calling  `firstFunction`, then followed by `secondFunction` on its output. It's type is `#'(T => Z)`.
In C++ parlance the resulting function performs `secondFunction(firstFunction(x))` . 


In the example below, we wish to use the `filter` function which takes a predicate that maps `T` to `bool`.  (ie  `#'(T => bool)` )
But we want to use `lookup`, which takes TWO arguments, not one.   We can use the `curry` form
to create a new function `lookup-ref` .  But we want to filter if the reference is even,
so we use `compose` to combine the lookup with the check for even number.

```
(def-function lookup (someVec i)
   (~ someVec i))

(def-kernel cross_table (inputVec referenceVec &out outputVec matchCount)
  (declare #'((in-vec long) (in-vec long) &out (out-vec long) (cell ulong) => nil))
  (let ((lookup-ref (curry #'lookup referenceVec))
        (lookup-even? (compose #'is-even? lookup-ref))
        (count (filter inputVec lookup-even? outputVec)))
    (set-result! matchCount count)))


```

#### `ident` 📝

```
(ident x) => f where f(anything) => x
```

Given a value `x`, the `ident` function returns another function that, given any value
returns the original `x`. 

Note: This obeys the Compile Time Resolution rule. The compiler treats `(ident x)` 
not as a dynamic function pointer, but as a direct reference to the variable `x` 
inside the target scope. It is fully inlined and zero-overhead.

