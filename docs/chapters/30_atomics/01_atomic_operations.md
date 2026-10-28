# Atomic Operations ⚠️

Crisp provides a number of built-in atomic operations that perform their work on shared memory locations. Each function is guaranteed to be a single, indivisible transaction.  Each one updates some variable in place and returns the value at the location BEFORE the modification occured.  (`atomic-load` and `atomic-store!`, at the end of this section, are the exceptions: a plain atomic read and a plain atomic write.)

#### atomic-add! ✅
Adds a value to a memory location, updating it. This routine returns the value BEFORE this modification. This "fetch-and-add" behavior is the classic parallel reduction primitive.

Syntax: `(atomic-add! location delta)`

Example: `(let ((old (atomic-add! (~ result 0) 1))) ...)`
 This example adds 1 to the first element of the result vector. The variable `old` will
 have whatever was in `(~ result 0)` before the addition occured.

#### atomic-sub! ✅
Subtracts a value from a memory location, updating it. This routine returns the value BEFORE this modification..

Syntax: `(atomic-sub! location delta)`

Example: `(let ((old (atomic-sub! (~ total-vec 0) 1))) ...)`
This example decrements a shared counter. `old` will be set to whatever was there BEFORE the modification.

#### atomic-inc! ✅
Atomically increments a memory location by 1.  Returns the value there previously.

Syntax: `(atomic-inc! location)`

Example: `(let ((old (atomic-inc! (~ counter-vec 0)))) ...)`

#### atomic-dec! ✅
Atomically decrements a memory location by 1. Returns the value there previously.

Syntax: `(atomic-dec! location)`

Example: `(let ((old (atomic-dec! (~ tasks-vec 0)))) ...)`

#### atomic-min! ✅
Compares a value at a memory location with a new value and stores the minimum of the two. Returns the value there previously.

Syntax: `(atomic-min! location new-value)`

Example: `(let ((old (atomic-min! (~ min-across-threads-vec 0) local-min))) ...)`

#### atomic-max! ✅
Compares a value at a memory location with a new value and stores the maximum of the two. Returns the value there previously.

Syntax: `(atomic-max! location new-value)`

Example: `(let ((old (atomic-max! (~ max-across-threads-vec 0) local-max))) ...)`

#### atomic-xchg!  |   atomic-set! ✅
Atomically exchanges the value at a memory location with a new value and returns the old value.  It does this UNCONDITIONALLY. 

Syntax: `(atomic-xchg! location new-value)`

Example: `(let ((old-value (atomic-xchg! (~ thread-lock-vec 0) 1))) ...)`

`atomic-set!` is just an alias for `atomic-xchg!` .  

#### atomic-binop! ✅
Syntax: `(atomic-binop! location binop-f arg)`

Uses an atomic CAS (Compare and Swap) under the hood. `atomic-binop!` 
will call a binary op function `#(T T => T)` with `arg` and the value at `location`
and then store the new value back in the `location`.  This is a CONDITIONAL exchange.
Returns the value there previously.

Example: 
```
;reduce someVar across all groups
(when-thread-in-group=is 0
  (let ((old-value (atomic-binop! (~ result-vec 0) #'+ someVar)))
    ...))
```

```
; IMPLEMENTATION NOTES
;; A BOUNDED retry loop.  The bound is the number of contenders + 1: a CAS fails only because another
;; thread's CAS succeeded, and each contender succeeds once.  It leaves as soon as its own CAS succeeds.
(dotimes (retry (+ contenders 1))
  (let ((old-val (~ global-result 0)))
    (let ((new-val (funcall #'+ old-val my-partial-sum)))
      (when (= (%atomic-cas-ok! (~ global-result 0) old-val new-val) 1)
        (return-from-loop)))))
;; ...followed by a runtime assert that it succeeded: an exhausted retry would be a LOST update.
```

#### atomic-op! ✅
Syntax: `(atomic-op! location op-f)`

Uses an atomic CAS (Compare and Swap) under the hood. 
`atomic-op!` calls a unary function `#(T => T)` with the value at `location`
and then store the result back to `location`. This is a CONDITIONAL exchange.
Returns the value there previously.

Example: `(let ((old-value (atomic-op! (~ global-counter 0) #'plus-ten))) ...)`

#### atomics and grid level operations

Using any atomic operation on `:global` memory makes the containing function or macro into a 
grid level operation.  The compiler will emit an error if attempted in the thread level context
of a `def-function`. Use `def-grid-function` instead. 
 If writing a `defmacro`, be sure to include `(declare (grid-level))` in its `progn` 
expansion. 

> ⚠️ **NOT ENFORCED YET (BUG 087).** As of 2026-09-22 a plain `def-function` performing a
> `:global` atomic compiles cleanly, with no error and no warning -- the refusal described above
> does not happen. The paragraph records the INTENDED rule, not current behaviour. It matters
> because a `def-function` is thread-level, so nothing marks the containing dispatch as a grid
> operation, and both the hoisting code and the uniformity analysis are then working from the
> wrong premise for any kernel that reaches a global atomic through a helper.



#### atomic-cas! ✅
(Compare-and-Swap) Compares the value at a memory location with an expected value. If they are the
same, it writes a new value. **The old value is always returned**, as with every other Crisp atomic,
so the caller detects success by comparing the returned value against the one it expected. This is
the most powerful atomic primitive, and every other atomic can be built from it.

Syntax: `(atomic-cas! location expected-value new-value)`

Example: `(atomic-cas! (~ current-value-vec 0) 0 1)`

**You cannot spin on it, and that is deliberate.** A CAS is normally used in a retry loop -- read,
compute, swap, and go round again if somebody beat you to it -- and such a loop is unbounded by
nature. Crisp is intentionally not Turing-complete, so there is no unbounded loop to write it with:
`while` is not part of the surface language, and `dotimes` / `dotimes+` both take a bound. A retry
loop you write yourself is therefore necessarily bounded, and you must decide the bound.

**`atomic-binop!` and `atomic-op!` are that loop, already written.** They wrap `atomic-cas!` in a
bounded retry whose limit is derived rather than guessed -- a CAS fails only because another thread's
CAS succeeded, and each contending thread needs to succeed just once, so the number of contenders is
a sufficient bound -- and they assert loudly if it is ever exhausted, because a silently abandoned
retry is a lost update. Prefer them unless you specifically need a single attempt.

**On floating point, the comparison is on bit patterns.** `cmpxchg` takes only integer operands, so
a float CAS reinterprets both values at the same width, which is also how CUDA's float `atomicCAS`
idiom works. Two consequences are worth knowing: `+0.0` and `-0.0` do not match each other, and a
NaN never matches itself. Both hold for every hardware float CAS.

**Not differentiable.** A CAS returns which thread won a race, which is not a function of the
program's inputs -- two identical runs can legitimately return different values -- so there is no
derivative to take. `--differentiate` refuses it rather than returning a gradient of zero, which
would be indistinguishable from a correct answer. For a differentiable accumulation use
`atomic-add!`, `(atomic-binop! loc #'+ x)`, or one of the `grid-reduce-*` strategies.

#### atomic-load ✅
Atomically reads a memory location and returns its value.  It changes nothing, so it has no `!`, and
unlike every atomic above it does not return "the value before a modification" -- there is no
modification.  Use it to POLL a location that other threads write: a flag, a ticket, a packed
value-and-state word.

Syntax: `(atomic-load location)`

Example: `(when (= (atomic-load (~ ready 0)) 1u) ...)`

Before `atomic-load` existed, a poll had to be a read-modify-write that changes nothing --
`(atomic-add! (~ flag 0) 0)` -- which PTX executes as an `atom` at L2.  `atomic-load` is a plain
relaxed load: `ld.relaxed.gpu` on NVIDIA, `OpAtomicLoad` (Device scope, Relaxed) on SPIR-V.

#### atomic-store! ✅
Atomically writes a value to a memory location.  It is not an exchange and returns nothing useful
(like `set!`); when you need the old value, use `atomic-xchg!`.

Syntax: `(atomic-store! location value)`

Example: `(atomic-store! (~ ready 0) 1u)`

PTX `st.relaxed.gpu`; SPIR-V `OpAtomicStore` (Device scope, Relaxed).

**Both are relaxed, like every Crisp atomic.**  They are indivisible -- a 64-bit word is never seen
half-written -- and they order nothing.  The publish / poll idiom puts the ordering in fences:

```lisp
;; publisher                          ;; poller
(set! (~ data i) v)                   (when (= (atomic-load (~ flag i)) 1u)
(mem-fence)                             (mem-fence)
(atomic-store! (~ flag i) 1u)           (~ data i))
```

When the value and its state fit in ONE word, no fence is needed at all: the word is the message.

**Types.**  The element must be a 32- or 64-bit scalar: `int`, `uint`, `long`, `ulong`, `float`,
`double`.  8- and 16-bit elements, device vectors (`float4`) and structs are refused -- the SPIR-V
lowering would need 16-bit atomic extensions, and a vector is more than one word.  Both work on
`:global` and `:local` memory, and an `atomic-load` may read an `&out` parameter (polling your own
outputs is the point), as every atomic RMW may.

**Measure before replacing an `atomic-xchg!` publish.**  In a decoupled-lookback prefix sum on H100
(2026-10-27), polling with `atomic-load` instead of `(atomic-add! loc 0)` was neutral, but publishing
with `atomic-store!` instead of `atomic-xchg!` made the kernel 20% SLOWER (presumably the pollers
see a relaxed store later than an `atom.exch`; nothing else in the PTX differed).  `atomic-store!` is the right tool when nobody is spinning on the location.

**Autodiff.**  `atomic-load` is not differentiable, for any element type: it reads a value another
thread (or an earlier statement) published, and the backward kernel -- a separate launch that replays
the forward's bindings but not its statements -- cannot reproduce it.  An integer `atomic-store!` is
inert (no derivative to carry); a floating-point one is refused, because it exists to hand a value to
another thread and that dataflow is invisible to the backward pass.

#### Example: Summing a Vector to One Value.

The last time we summed a vector, our result vector had M entries, one for each workgroup 
which the host was exected to sum up. 

This time, our result vector only needs to have space for one entry. Each thread-0 of each
workgroup will add its sum to the first element of the result vector.
( It mightn't be the worst idea to make sure that it's value is 0 before hoisting) 

```
;; 32 warps maximum for most hardware
(def-constant +warp-size+ 32 ulong)

;; the source vector can be any size. 
(def-type source-vec (vector long :address-space :global))     

;; the final result vector is just has 1 long value
(def-type result-vec (vector long :address-space :global :length 1)) 

;; -- calculate-this-thread-sum --
(def-grid-function calculate-this-thread-sum (A)
  (declare #(source-vec -> long))
  (let ((sum 0))
    (loop-vector-stride A (i)
      (inc! sum (~ A i))))) ; <-- inc! implicity returns final sum

;; -- sum_vector_warp_to_one --
(def-kernel sum_vector_warp_to_one (A Res)
    (declare #'(source-vec result-vec => nil)
             (local-size :set-to +warp-size+ ...)
             (global-size :derive-from A :strategy :strided))

    (let ((sum (calculate-this-thread-sum A)))
        (in-warp (lane-id)
            (dec-times-by-half+ (s (/ +warp-size+ 2))
                (inc! sum (shuffle-xor sum s))))
    
    ;; Final reduction to a single value
    (when-thread-in-group-is (0)
        ;; Use atomic-add to contribute this workgroup's sum to the final result
        (atomic-add! (~ Res 0) sum))))
```


