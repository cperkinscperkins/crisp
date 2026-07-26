# Branching ⚠️


Crisp has the same four basic branching expressions as Common Lisp: `if` , `when`, `unless`, and `cond`

They each operate similarly: first evalute a predicate expression, and if true, then execute 
some consequent. With variations for multiple checks, multiple statements, etc.  
( `unless` checks the predicate for being `false`, not `true`).

#### `cond` default ✅
The default case for `cond` is not `T` like it is in Common Lisp. That would be too confusing 
with the very common `T` used for templating.  Instead in Crisp, `cond` uses `else` as the default case.

#### + variant ✅
The `+` variant checks that the predicate expression is uniform across the entire warp. If the compiler
detects that it is not, it will emit an error. This variant is EXTREMELY USEFUL when developing 
high performance non-diverging code. 


<!-- 

ANAPHORIC VARIANTS MOST LIKELY TO BE DROPPED 

#### `it` - anaphoric
All the branching expressions (except `unless`) are "anaphoric", which is a linguistic concept to describe a word that acts as a substitute for an earlier expression.
For example "The cat chased the mouse, but it got away", the word "it" is an anaphoric reference to the mouse.
Whatever.

In Crisp, `it` is the name of a variable that is automatically created in the scope of the consequent of any `if`, `when` or `cond` clause, or their variants.
`it` holds the value of the predicate expression so you don't have to stash it earlier or call it again.
A simple example should explain everything:

```
(when (length someVector)  ; <-- 'it' is now bound to that length
   (set! somethingElse it))
```
Of course this works if the vector length was non-zero. If it was zero, the consequent would be skipped entirely.
Note that THIS may not work as expected:
```
(when (> (length someVector) 0)   ; `it` is now bound to `T` the result of the `>` comparison
  (set! somethingElse it))
```

-->

