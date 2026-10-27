# Looping -- Uniform Loops ✅


A C++ `for` loop is a big liability when improperly used in a GPU kernel. If the loop isn't
performed uniformly across all the threads in a work group then massive stalls can occur
which kill throughput and performance. 

Similarly, the compiler is capable of unrolling a loop if its target is compile-time calculable.

In Crisp, you can convey these expectations in your code, and if the compiler detects
that it is not achievable, it will emit an error. This makes writing performant code that 
does not diverge much easier. There is much less guessing will-it/won't-it.

Crisp has `+` variants of all the looping macros. These variants allow you to tell the compiler
that you expect the loop to run uniformly across the entire WORKGROUP -- every thread runs the same
iterations, which is what makes a barrier inside the loop legal. If the compiler cannot prove that,
it will emit a compilation error. (A loop that is only uniform across each warp -- see *Two levels*
below -- is written with the plain form; warp collectives inside it are still legal.)

Note, that these variants are used to help you discover divergences. Even if you don't use them
the loop will still benefit if it is warp level uniform, and the compiler might still optimize
by unrolling. The use (or not) of the variant doesn't change the actual performance.


#### `provably-uniform?` and `provably-divergent?` ✅

```
(provably-uniform? <someExpre>)
(provably-divergent? <someExpr>)
```
`provably-uniform?` and `provably-divergent?` are compile-time forms that can be used to develop your own macros.

When evaluating uniformity, there are four possibilities:
- the compiler can prove to itself that some variable is uniform across the workgroup (`:uniform`)
- the compiler can prove to itself that it is uniform across each WARP, but not necessarily between
  warps (`:warp-uniform` -- see *Two levels* below)
- the compiler can prove to itself that some variable diverges in the workgroup (`:divergent`)
- the compiler is unable to prove anything about the variable or expression uniformity (`:unknown`).

Keep that in mind because `(not (provably-uniform? var))` does NOT necessarily mean that `(provably-divergent? var)` would be true.
`provably-uniform?` means WORKGROUP-uniform; a warp-uniform value is not.  `(uniformity-state x)` returns
the keyword itself.

The `+` variants (`if+`, `dotimes+`) etc all use `provably-uniform?` and emit an error if that is not determinable. 




#### detecting uniform execution ✅
In this example, if the compiler cannot prove that `someN` is uniform across the WORKGROUP it will
emit an error.
```
(dotimes+ (x someN)
 ...)
```

`dotimes+` checks workgroup-level uniformity, because that is what a barrier inside the loop needs.
A loop whose bound is only warp-uniform is written with plain `dotimes`: warp collectives inside it
are still legal, barriers are not (*Two levels*, below).



#### forcing uniform loop execution ✅

If you want to FORCE a loop to be uniform, Crisp makes it easy to do that
using `to-workgroup-uniform` or `to-warp-uniform`.

```
(let ((someN (to-workgroup-uniform (some-expression ...))))
   (dotimes+ (x someN)
      ...))
```

`to-workgroup-uniform` captures the value in local thread 0, broadcasts it through workgroup memory
between two `sync-workgroup` barriers, and every thread takes thread 0's value.
`to-warp-uniform` is similar, but broadcasts lane 0's value through the warp with a shuffle; the result
is uniform across each warp only (`:warp-uniform`), so it satisfies a warp collective's needs but not
`if+` / `dotimes+`.  It moves the 32- and 64-bit scalars (int, uint, float, long, ulong, double).

Both are real operations, not assertions (before Endeavour 194 they emitted only a barrier / a
`__syncwarp` and passed each thread's own value through -- a per-thread value the analyser then believed
uniform).  So each is also a COLLECTIVE: `to-workgroup-uniform` is refused where only some threads of
the workgroup arrive, `to-warp-uniform` where lanes of a warp may have split.

These two expression can ONLY be used in a let binding.  They cannot be used in any normal position like a regular lisp form. This is because of the barriers they might introduce, they need consistent predictable ordering.

Note that these two forms are HEAVY HANDED and not performant (though, when used correctly, performance can be gained).
If the value is uniform already and only the compiler cannot see it, `(declare (uniform x))` (below)
says so for free.



#### Two levels: workgroup-uniform and warp-uniform ✅

Two different questions decide whether a construct is legal at some point in a kernel:

* **Does every thread of the WORKGROUP arrive here?**  A barrier needs this: `sync-workgroup`,
  `sync-wait`, `to-workgroup-uniform`, the tile operations with an internal barrier, or a call to a
  function that reaches one.
* **Does every lane of the WARP arrive here?**  A warp collective needs only this: the shuffles,
  `reduce-warp`, `to-warp-uniform`, `sync-warp`, or a call to a function that reaches one.

A condition, a loop bound or a loop exit decides which questions still get a yes:

| what governs the code | barriers | warp collectives |
|---|---|---|
| workgroup-uniform (`:uniform`) | legal | legal |
| warp-uniform (`:warp-uniform`) -- whole warps take it or skip it | refused | legal |
| per-thread (`:divergent`), or not provably either (`:unknown`) | refused | refused |

This applies alike to `if` / `when` / `unless` / `cond`, to the bound of a plain `dotimes` (a trip count
that differs between threads divides them exactly like a branch), and to a loop's early exits
(`return-from-loop`, below).

**Where warp-uniform values come from.**  `to-warp-uniform`; `(warp-id)`; a variable after `reduce-warp`
(every lane holds the reduction); a full-width `shuffle` from a lane every lane names; a call to a
function whose every `(return ...)` is warp-uniform (whatever its arguments); `(/ tid K)` where `tid` is
the local thread index (`(get-local-linear-id)`, or `(get-local-id 0)`, through casts) of a kernel with
a declared 1-D `local-size`, and `K` a literal the warp size divides -- the usual "warp 0 does X",
`(when (= (/ tid 32ul) 0ul) ...)`; and anything computed only from those and workgroup-uniform values.  A variable `set!` inside a warp-uniform branch is at best
warp-uniform afterwards -- the other warps never saw the store.

**Calls.**  A call reaches whatever its callee reaches, transitively: calling a function that holds a
barrier where only some threads arrive is the same deadlock as writing the barrier there.

```
(let ((w0 (to-warp-uniform (< (get-local-id 0) 32ul))))   ; warp-uniform
  (when w0
    (set! x (shuffle-xor x 1ul))      ; legal: every lane of an entering warp is here
    (sync-workgroup)))                ; ERROR: only some warps arrive
```

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




