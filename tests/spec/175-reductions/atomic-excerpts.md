
### Atomic Operations ⚠️
Crisp provides a number of built-in atomic operations that perform their work on shared memory locations. Each function is guaranteed to be a single, indivisible transaction.  Each one updates some variable in place and returns the value at the location BEFORE the modification occured.

#### atomic-add! ✅
Adds a value to a memory location, updating it. This routine returns the value BEFORE this modification. This "fetch-and-add" behavior is the classic parallel reduction primitive.

Syntax: `(atomic-add! location delta)`

Example: `(let ((old (atomic-add! (~ result 0) 1))) ...)`
 This example adds 1 to the first element of the result vector. The variable `old` will
 have whatever was in `(~ result 0)` before the addition occured.

#### atomic-sub!
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
;; The macro generates a BOUNDED loop to guarantee termination.
(dotimes+ (retry-count 1000) ; Use a generous but finite limit
  (let ((old-val (~ global-result 0)))
    (let ((new-val (funcall #'+ old-val my-partial-sum)))
      (when (atomic-cas! (~ global-result 0) old-val new-val)
        ;; If the CAS succeeded, break the loop.
        (return-from-loop)))))
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

