# Looping -- Uniform Loops ✅


A C++ `for` loop is a big liability when improperly used in a GPU kernel. If the loop isn't
performed uniformly across all the threads in a work group then massive stalls can occur
which kill throughput and performance. 

Similarly, the compiler is capable of unrolling a loop if its target is compile-time calculable.

In Crisp, you can convey both of these expectations in your code, and if the compiler detects
that it is not achievable, it will emit an error. This makes writing performant code that 
does not diverge much easier. There is much less guessing will-it/won't-it.

Crisp has `*` variants of all the looping macros. These variants allow you to tell the compiler
that you expect the loop to run uniformly across the entire warp. If the compiler detects the 
possibility for warp-level divergences, it will emit a compliation error.

Similarly, there are `+` variants where you tell the compiler that you expect the loop target
to be compile-time calculable. The compiler will error if it is not.

Note, that these variants are used to help you discover divergences. Even if you don't use them
the loop will still benefit if it is warp level uniform, and the compiler might still optimize
by unrolling. The use (or not) of the variant doesn't change the actual performance.

### detecting compile-time calculable

In this example, if the compiler detects that `someN` is not compile-time calculable, it will
emit an error.
```
(dotimes+ (x someN)
...)
```

Alternately, we could achieve the same result by using the `constexpr` declaration
```
(let ((someN someLong))
  (declare (constexpr someN))  ;; declare that we expect someN to be compile-time calculable. 
                               ;; compiler will emit an error if it is not.
   (dotimes (x someN)
      ...))
```


### detecting uniform execution
In this example, if the compiler detects that `someN` is not uniform across the warps it will
emit an error. 
```
(dotimes* (x someN)
 ...)
```

Warp level loop uniformity is the most useful/important. And that's what `dotimes*` checks.

But note, that `(declare (uniform someVal))` is a check across the entire workgroup.
So the "roll our own" approach makes for a (needlessly) stronger guarantee.

```
(let ((someN someLong))
  (declare (uniform someN))  ;; declare that we expect someN to be uniform
                             ;; ACROSS THE ENTIRE WORKGROUP 
                             ;; compiler will emit an error if it detects otherwise.
   (dotimes (x someN)
      ...))
```

### forcing uniform loop execution

If you want to FORCE a loop to be uniform across the entire workgroup, Crisp makes it easy to do that 
using the `to-uniform` declaration.

```
(let ((someN someLong))
  (declare (to-uniform someN)) 
   (dotimes* (x someN)
      ...))
```

`to-uniform` will capture the variable in workgroup thread and broadcast it to all the others.



### (uniform <varName>)
`(declare (uniform someVar))`

The compiler will check that `someVar` is uniform across the workgroup and if it is not, emit an error.

### (to-uniform <varName>)
`(declare (to-uniform someVar))`
This is a convenience declaration to help programmers set up values that are uniform in a workgroup.

The `to-uniform` declaration causes the compiler to
- initialize the variable in exactly one workgroup thread
- share it with the other threads of the workgroup via local memory and a barrier.

Furthermore
- The variable named and the `declare` invocation both MUST originate in 
the same `let` clause. 
- `to-uniform` cannot be used in other `declare` contexts.

### (constexpr <varName>)
`(declare (constexpr someVar))`

The compiler will check that `someVar` is compile-time calculable, and emit an error if it is not.



### dotimes+ 
 `dotimes+` is the `+` variant. It will throw a compiler error if it
is used without a compile-time calculable `N` value. 

### dotimes*
`dotimes*` is the `*` variant. It will throw a compiler error if it determines
that the `N` value is not uniform across the warp. 


### caution
You must still exercise vigilance over the body of the loop. 
Inserting `if`, `when` or `cond` clauses can lead to branch divergence, 
where different threads in a workgroup take different execution paths. 
This will cause stalls and kill performance. 




