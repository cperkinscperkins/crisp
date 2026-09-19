
In this endeavor we'll be looking to implement the variants of "dotimes" that Crisp supports.

"dotimes" itself was impleemnted back in endeavor 092.  tests\spec\092-dotimes\dotimes.md had the discussion and the tests alongside.


And note, that endeavor 120 which did "uniform" also introduced "dotimes+" which supports uniformity checks.
tests\spec\120-uniform\uniform.md


In this endeavor we want to implement both the "regular" and "+" uniform variant of the following:

- [x] dotimes / dotimes+
- [ ] dec-times / dec-times+
- [ ] dec-times-by-half / dec-times-by-half+
- [ ] dec-times-by-factor / dec-times-by-factor+
- [ ] do-times-by-doubling / do-times-by-doubling+
- [ ] do-times-by-multiply / do-times-by-multiply+
- [ ] do-power-step / do-power-step+
- [ ] dec-power-step / dec-power-step+


I've excerpted the docs for these from the design doc. It is below:

Plan
====

[x] Write tests, including auto-diff  (2026-09-19: 01-08 on-metal sequences + gates,
    09-15 VERIFY-AUTODIFF, errors/01-12; expected values cross-checked against a Python
    reference model of D2-D6)
[x] implement  (2026-09-19, overlays/crisp-compiler-overlay.lisp -- 27/27 specs; all 7
    VERIFY-AUTODIFF pass on L0; see Implementation notes below)
[ ] bump docs (docs/ideal_001.md) 


Decisions (agreed 2026-09-19)
=============================
These supersede the design-doc excerpt below wherever they differ, and are what
"bump docs" must carry into ideal_001.md.

D1. Lowering: generalize the loop node (option B)
-------------------------------------------------
One generalized counted-loop node rather than eight codegen paths: `semantic-dotimes`
(or a successor) gains an init value, a direction and a step op (add / sub / mul / udiv),
and codegen emits the native loop condition.  The ~6 places in ANF and AD that recognise
loops by string-matching "DOTIMES"/"DOTIMES+" (anf-transform ~176, ~294; autodiff ~1083,
~2310, ~4839, ~4990) become ONE family predicate.

Why not analyzer-level expansion (the grid-stride pattern): ANF and AD run on source forms
and never see an analyzer expansion.  ANF hoists the body out of an unrecognised loop head,
which is exactly how with-warp-specialization's gating silently vanished (see
src/macros.lisp ~972).  Pure sugar forms may still desugar EARLY (before ANF) onto a
family member.

D2. Types: unsigned only
------------------------
All operands (N, init, factor, stride) must be unsigned integer types.  Non-negative
integer LITERALS are accepted and coerced to ulong (index literals are `int`, so otherwise
`(dec-times (i 10) ...)` would be rejected).  Negative literals, signed variables and floats
are compile errors.  `i` takes N's type.  (dotimes / dotimes+ are unchanged -- they keep
accepting signed types.)

D3. Termination gates (humorless)
---------------------------------
Crisp promises bounded loops, and init=0 or factor<=1 would loop forever.
- Literal `init` = 0, `stride` = 0 or `factor` <= 1  =>  compile error.
- Runtime `init` = 0, `stride` = 0 or `factor` <= 1  =>  the loop runs ZERO iterations.
  (stride 0 matters for dec-times: its start ((N-1)/s)*s would divide by zero.)
  NOTE: plain `dotimes` had the same hole -- `(dotimes (i n 0) ...)` never terminated,
  and so did a negative stride on a signed dotimes.  FIXED in 172 under the same rule
  (BUG 065): literal -> compile error, runtime -> zero iterations.  The codegen guard
  folds to `br i1 true` for constant strides, so no existing loop changed shape.
  Specs: 092-dotimes/errors/02-zero-stride.crisp and 092-dotimes/08-runtime-stride-gate.crisp.
- Multiplicative steps are overflow-safe: the loop exits when `i > N / factor` rather than
  computing `i * factor` past ULONG_MAX.  Invisible to users; it keeps termination a
  guarantee rather than a hope.
If any of these forms keep causing trouble, we drop them.

D4. dec-times is the EXACT reverse of dotimes
---------------------------------------------
`(dec-times (i N s))` visits exactly the values `(dotimes (i N s))` visits, in reverse.
It starts at `((N-1) / s) * s` (integer division), which is N-1 when s = 1.  NOT N-1 and
NOT N-s in general:
    N=6 s=2:  dotimes 0 2 4      dec-times 4 2 0
    N=5 s=2:  dotimes 0 2 4      dec-times 4 2 0   (N-s would give 3 1 -- wrong)
N = 0 runs zero iterations.  With unsigned `i`, `i >= 0` is always true, so the loop must
be counted or wraparound-safe, never `while i >= 0`.

D5. Every form has a + variant
------------------------------
Including do-times-by-doubling+, do-times-by-multiply+, do-power-step+ and dec-power-step+
(the docs were inconsistent; there is no reason to omit them).  A + variant requires EVERY
operand (N, init, factor, stride) to be provably uniform; the loop variable inherits that
uniformity.  (Doc cleanup: one heading says "do-times-by-double+", and the + text says
workgroup-uniform in one place and warp-uniform in another.  Implementation =
calculate-uniformity-state, as dotimes+.)

D6. dec-power-step uses a real clz op
-------------------------------------
dec-power-step starts at the largest power of two strictly below the limit (= half the
padded limit): 230 -> 128, 256 -> 128, 257 -> 256; limit <= 1 runs zero iterations.
Computed with a count-leading-zeros op (llvm.ctlz; lowers on SPIR-V and PTX), not a
doubling pre-loop.  Likely reused in 175.

do-power-step needs no clz: i = 1, 2, 4, ... while i < limit.  That matches every doc
example (100 -> 1..64, 64 -> 1..32, 1 -> none).

D7. AD: follow the dotimes convention; reverse order is a 175 prerequisite
--------------------------------------------------------------------------
The backward pass currently replays a loop in FORWARD order.  That is correct for
accumulation loops, and the new forms follow it; each gets a VERIFY-AUTODIFF spec of
that shape.  But a dec-times-by-half tree reduction (with barriers over shared memory)
needs its backward in REVERSE order -- the gradient broadcasts back down the tree.  That
is explicitly out of scope for 172 and is a known prerequisite for 175 (reductions).


Implementation notes (2026-09-19)
=================================
All in overlays/crisp-compiler-overlay.lisp; each definition is tagged with its src/ home.

NEW (hand-written):
- `*dotimes-family-names*`, `%dotimes-family-head-p`   -> src/anf-transform.lisp
- `%dotimes-backward-head` (backward emits the plain head; DOTIMES+ -> dotimes as before)
- `%anf-normalize-dotimes` (replaced: normalizes ALL binding operands, not just limit/stride)
- `semantic-loop-variant` struct, `(:include semantic-dotimes)`   -> src/semantic.lisp
  The :include means the two core.lisp etypecases need NO new clause.
- `*loop-variant-specs*`, `analyze-loop-variant-expression` + helpers,
  `register-loop-variant-analyzers`   -> src/analysis/control.lisp
- `generate-node-ir (semantic-loop-variant)`, `%loop-variant-coerce`   -> src/codegen.lisp
  One guarded, bottom-tested loop for all kinds; per-kind guard / start / latch table in
  its docstring.  dec-power-step start = 1 << (W-1 - ctlz(N-1)), llvm.ctlz.iW.

WHOLE-FUNCTION COPIES (extracted from src/ by script; the only change is noted):
- `anf-normalize`, `%collect-locally-bound-vars`, `generate-backward-walk`:
  the DOTIMES/DOTIMES+ name test -> `%dotimes-family-head-p`
- `%gfw-process-dotimes`: emits the loop's own head via `%dotimes-backward-head`
- `register-control-analyzers`: adds the `(register-loop-variant-analyzers)` call.
  (A top-level registration does NOT survive initialize-compiler's clrhash.)

When folding in: the new head symbols are interned at load, not declared in
src/package.lisp -- consider exporting them alongside dotimes+.

Observed, not changed: the loop variable's alloca is emitted at the current insert
point, as dotimes does -- so a loop nested inside another loop gets its alloca in a
non-entry block.  Pre-existing dotimes behaviour; noting it for 175, which will nest
these loops.


Test plan (draft)
=================
Per form (plain and +):
- iteration sequence verified on metal (TEST-HOIST[L0] / HOIST-EXPECT) against the doc
  examples, including the boundary cases (N=0, N=1, non-divisible stride, non-power-of-2
  limit)
- VERIFY-AUTODIFF accumulation kernel (no forward-only, no SKIP-WITH)
- + variant accepts uniform operands

Errors (errors/):
- signed variable / float / negative literal operand
- literal init = 0; literal factor = 0 and 1
- + variant with a divergent N, and with a divergent factor / init / stride
- malformed binding (wrong arity)

Runtime gates (on metal): runtime init = 0 and factor = 1 run zero iterations; N near
ULONG_MAX with factor 2 terminates.



EXCERPT OF DESIGN DOC
=====================


### Looping Constructs ✅

Here is a list of the looping constructs supported by Crisp. Some are discussed elsewhere.

- loop-vector-stride / loop-soa-stride
- tensor-stride
- grid-stride
- tile-stride
- hardware-stride
- stride helper functions:
- - tensor-coords
- - tile-coords
- - tile-indices
- - load-tile
- - store-tile
- workgroup-stride
- dotimes / dotimes+
- do-times-by-doubling
- do-times-by-multiply
- dec-times / dec-times+
- dec-times-by-half / dec-times-by-half+
- dec-times-by-factor / dec-times-by-factor+
- do-power-step
- dec-power-step

#### Immutable Index
All of the above bind a loop index. Unlike in a C++ `for` loop, that index value is immutable in the 
body of the loop.

#### + variants 📝
Most of the Looping Constructs have a variant whose name ends in `+`. 
The compiler will check that the target `N` is uniform across the workgroup. If the compiler
detects that it is not workgroup-level uniform, it will emit an error. 

These variants are fully differentiable under `--differentiate`; see "Requirements for Differentiable Kernels."

#### variants compared
Let's start with a simple example:
```
(dotimes (x (+ a b)) 
   ...)
```
Each thread will calculate `(+ a b)` independently, and then loop that many times.  If that value `(+ a b)` differs
between threads, the loop will not be uniformly executed and this may result in a LOT of stalling.

`+`
```
(dotimes+ (x (+ a b))
 ...)
```
If `(+ a b)` is calculable at compile time, then this is fine. The compiler will insert that value and the loop will be uniform. The compiler might even elect to unroll the loop for faster performance.


Otherwise the compiler will check that both `a` and `b` are warp-level uniform. If they are, then their sum is as well and 
this will both compile just fine, but it'll execute quickly without stalling. But if the compiler
detects that this is not warp-level uniform it will emit an error.



#### dotimes / dotimes+  ⚠️
```
 (dotimes (i N:ulong &optional (stride:ulong 1)) 
    ...)
```
Binds `i` to 0, counts up to N, incrementing by `stride` each time through the loop. `stride` is optional, defaults to 1.

#### dec-times / dec-times+  📝
```
  (dec-times (i N:ulong &optional (stride:ulong 1))
    ...)
```
Binds `i` to `N-1` and counts down to `0`, subtracting `stride` each time through the loop. `stride` is optional, defaults to 1.
This is the opposite of `dotimes`


#### do-times-by-doubling / do-times-by-double+ 📝
```
  (do-times-by-doubling (i:ulong init:ulong N:ulong) 
   ...)
```
Binds `i` to `init`. Each time through the loop, `i` is doubled until
it reaches (or exceeds) `N`.  The last call will always have `i` bound to a value less than or equal to `N`.

Example: If `init` is 1 and `N` is 64: i => 1, 2, 4, 8, 16, 32, 64
Example: If `init` is 1 and `N` is 100: i => 1, 2, 4, 8, 16, 32, 64

#### do-times-by-multiply / do-times-by-multiply+  📝
```
  (do-times-by-multiply (i:ulong init:ulong N:ulong factor:ulong)
   ...)
```
Binds `i` to `init`. Each time through the loop, `i` is multiplied by `factor` until i reaches (or exceeds) `N`.  The last call will always have 
`i` bound to a value less than or equal to `N`.

The `factor` value must be greater than 1.

Example:  `init` is 1  `N` is 64 and the `factor` is 4:  i => 1, 4, 16, 64


#### dec-times-by-half / dec-times-by-half+  📝
```
  (dec-times-by-half (i:ulong N:ulong)
    ...)
```
Binds `i` to `N`. Each time through the loop, `i` is divided by two until it reaches 1.  The last call will always have `i` bound to `1`, it is never bound to `0` .
Example: If `N` is 64:  i => 64, 32, 16, 8, 4, 2, 1  
Example: If `N` is 100: i => 100, 50, 25, 12, 6, 3, 1

This is very useful for reductions where we have all 64 threads in a warp perform a calculation, then 32, down to the last thread which has 
the full value.  See the example for `sum_vector` with barriers below. 

If your algorithm always needs powers of two, make sure `N` is a power of 2 itself, or consider using `dec-power-step` instead ( below ).

#### dec-times-by-factor / dec-times-by-factor+ 📝
```
  (dec-times-by-factor (i:ulong N:ulong factor:ulong)
     ...)
```
`dec-times-by-factor` is a generalized version of `dec-times-by-half`.  This routine requires a third argument, the `factor`, which is a non-negative integer that must be greater than 1. 
(A `factor` of 2 will result in the same sequence as `dec-times-by-half`). 

`dec-times-by-factor+` requires that BOTH `N` and `factor` are `uniform` values. 

Binds `i` to `N`. Each time through the loop, i is divided by `factor` using integer division. 
The loop continues as long as `i` is greater than or equal to 1. `i` is never bound to 0.

Example #1:  `N` is 64 and the `factor` is 4:  i => 64, 16, 4, 1
Example #2:  `N` is 24 and the `factor` is 5:  i => 24, 4


#### do-power-step / do-power-step+ 📝

```
  (do-power-step (step-var:ulong limit:ulong) 
     ...)
```
`do-power-step` binds `step-var` to the powers of 2 up to `limit` (or the next power of 2 if it is not itself a power of 2).
The highest value `step-var` will have is half the "padded" limit.
For example, in `(do-power-step (i 100) ..)`, the limit of 100 gets rounded up to the next power of 2 which is 128.
This would then have seven steps, binding `i` in turn to 1, 2, 4, 8, 16, 32, and 64
The number of steps taken is `(log2 padded_limit)` ( aka `(log padded_limit 2)`)

##### possible implementation
```
;; -- do-power-step --
(defmacro do-power-step ((step-var limit) &body body)
  "Loops log2(padded_limit) times, where padded_limit is the next
   highest power of two from limit. Binds step-var to 1, 2, 4, 8..."
  (let ((d (gensym))
        (padded-limit (gensym)))
    `(let ((,padded-limit (next-power-of-2 ,limit)))
       (dotimes (,d (log2 ,padded-limit))
         (let ((,step-var (expt 2 ,d)))
           ,@body)))))
```


#### dec-power-step / dec-power-step+ 📝

```
  (dec-power-step (step-var:ulong limit:ulong) 
     ...)
```
The reverse of `do-power-step`, `dec-power-step` starts with `step-var` bound to half the padded limit and decremented until it is 1.
E.G. In `(dec-power-step (i 230) ...)` the limit of 230 would be raised to the next power of two, which is 256.
So `i` would be bound to 128, 64, 32, 16, 8, 4, 2, and 1. 

##### possible implementation
```
-- dec-power-step --
(defmacro dec-power-step ((step-var limit) &body body)
  "Loops log2(padded_limit) times, binding step-var to ..., 8, 4, 2, 1."
  (let ((d (gensym))
        (padded-limit (gensym)))
    `(let ((,padded-limit (next-power-of-2 ,limit)))
       (dec-times (,d (log2 ,padded-limit))
         (let ((,step-var (expt 2 ,d)))
           ,@body)))))
```

