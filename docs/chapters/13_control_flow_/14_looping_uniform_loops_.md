# Looping -- Uniform Loops ✅


A C++ `for` loop is a big liability when improperly used in a GPU kernel. If the loop isn't
performed uniformly across all the threads in a work group then massive stalls can occur
which kill throughput and performance. 

Similarly, the compiler is capable of unrolling a loop if its target is compile-time calculable.

In Crisp, you can convey these expectations in your code, and if the compiler detects
that it is not achievable, it will emit an error. This makes writing performant code that 
does not diverge much easier. There is much less guessing will-it/won't-it.

Crisp has `+` variants of all the looping macros. These variants allow you to tell the compiler
that you expect the loop to run uniformly across the entire warp. If the compiler detects the 
possibility for warp-level divergences, it will emit a compliation error.

Note, that these variants are used to help you discover divergences. Even if you don't use them
the loop will still benefit if it is warp level uniform, and the compiler might still optimize
by unrolling. The use (or not) of the variant doesn't change the actual performance.


#### `provably-uniform?` and `provably-divergent?` ✅

```
(provably-uniform? <someExpre>)
(provably-divergent? <someExpr>)
```
`provably-uniform?` and `provably-divergent?` are compile-time forms that can be used to develop your own macros.

When evaluating uniformity, there are three possibilities: 
- the compiler can prove to itself that some variable is uniform across the workgroup
- the compiler can prove to itself that some variable diverges in the workgroup
- the compiler is unable to prove anything about the variable or expression uniformity.

Keep that in mind because because `(not (provably-uniform? var))` does NOT necessarily mean that `(provably-divergent? var)` would be true. 

The `+` variants (`if+`, `dotimes+`) etc all use `provably-uniform?` and emit an error if that is not determiinable. 




#### detecting uniform execution ✅
In this example, if the compiler detects that `someN` is not uniform across the warps it will
emit an error. 
```
(dotimes+ (x someN)
 ...)
```

Warp level loop uniformity is the most useful/important. And that's what `dotimes+` checks.



#### forcing uniform loop execution ✅

If you want to FORCE a loop to be uniform across the entire workgroup, Crisp makes it easy to do that 
using the `to-workgroup-uniform` or `to-warp-uniform` .

```
(let ((someN (to-workgroup-uniform (some-expression ...))))
   (dotimes* (x someN)
      ...))
```

`to-workgroup-uniform` will capture the variable in workgroup thread, use a `sync-workgroup` barrier and broadcast it to all the others.
`to-warp-uniform` is similar, but uses shuffles to broadcast through the warp. 

Note that these to forms are HEAVY HANDED and not peformant (though, when used correctly, performance can be gained).



#### providing uniformity hints to the compiler ✅
`(declare (uniform someVar))`

If you know that a variable will be uniform, even if the compiler cannot determine that by itself,
you can tell it using this declaration. 
The compiler will check that `someVar` isn't provably divergent. If it detects that it is, it will emit an error. Otherwise, the variable will be taken as uniform and that will influence the uniformity check peformed by `provably-uniform?`



#### (constexpr <varName>) 📝
`(declare (constexpr someVar))`

The compiler will check that `someVar` is compile-time calculable, and emit an error if it is not.



#### dotimes+  ✅
 `dotimes+` is the `+` variant.  It will throw a compiler error if it determines
that the `N` value is not uniform across the warp. 


#### caution
You must still exercise vigilance over the body of the loop. 
Inserting `if`, `when` or `cond` clauses can lead to branch divergence, 
where different threads in a workgroup take different execution paths. 
This will cause stalls and kill performance. 




