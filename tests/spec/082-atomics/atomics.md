The differentiation of tensors which has been recently added, requires atomic-add! to safely differentiate.
We deferred it.

SO in this endeavor I hope to do two things:

- realize all the base atomic operations
- update the auto-differentiation so it uses the atomic op correctly.

The docs for just the atomics are below.

We'll need a series of tests. For the atomics themselves. Should we use  xxx.unit.lisp or a .crisp tests?
Not sure how to test the differnetiate aspect.


Implementation Plan (082-atomics)
==================================

Scope
-----
Implement: atomic-add!, atomic-sub!, atomic-inc!, atomic-dec!, atomic-min!, atomic-max!,
           atomic-xchg!, atomic-set! (alias for atomic-xchg!)
Deferred:  atomic-binop!, atomic-op! — require dotimes+ which does not exist yet.

LLVM Atomic Ordering
--------------------
All ops use LLVMAtomicOrderingSequentiallyConsistent (value=7), single-thread=0.
This is the safe, correct, conventional choice for GPU (matches CUDA atomicAdd semantics).
SPIR-V and PTX both support it. Can be relaxed later if profiling demands it.

atomic-inc! / atomic-dec! use LLVMAtomicRMWBinOpAdd / Sub with a literal delta of 1.
No wrap semantics, works for all numeric types including float.

Grid-Level Context Check (minimal first pass)
----------------------------------------------
The full grid-vs-thread context system is future work. For now, a minimal check:
- At analysis time, check compiler-context-declarations for absence of (entry-point)
  declaration => we are in thread context (a plain def-function, not a kernel).
- If thread context AND the atomic target is in :global address space => compiler error.
- A def-kernel always has (entry-point) in its declarations, so atomics are allowed there.
- When def-grid-function is added later, it gets its own entry-point variant and this
  check will extend naturally.

AD Integration
--------------
In %handle-single-value-backward (autodiff.lisp), the tensor scatter gradient currently
emits a non-atomic read-modify-write:
  (set! (~ src_GRAD idx...) (+ (~ src_GRAD idx...) adj(v)))
This is a race condition when multiple threads scatter to the same gradient index.
Fix: redefine %handle-single-value-backward in the overlay to emit instead:
  (atomic-add! (~ src_GRAD idx...) adj(v))
This is a one-line change in the backward walk.

Files Changed
-------------
Patch (Chris applies to source):
  src/semantic.lisp — add (defstruct semantic-atomic-rmw type op target-node delta-node
                           source-location)

Append to overlays/crisp-llvm-bindings-overlay.lisp:
  - LLVMBuildAtomicRMW defcfun
  - defconstant for LLVMAtomicOrdering and LLVMAtomicRMWBinOp enum values:
      xchg=0, add=1, sub=2, max=7, min=8, umax=9, umin=10, fadd=11, fsub=12, fmax=13, fmin=14
      seq-cst ordering = 7

Append to overlays/crisp-compiler-overlay.lisp:
  - %analyze-atomic-rmw-expression (shared helper: parse target aref, parse delta,
      validate numeric type, grid-level check)
  - Seven analyzer functions: atomic-add!, atomic-sub!, atomic-inc!, atomic-dec!,
      atomic-min!, atomic-max!, atomic-xchg! (atomic-set! registers to same fn)
  - register-ops-analyzers redef — adds all seven registrations
  - semantic-node-type redef — adds (semantic-atomic-rmw (semantic-atomic-rmw-type node))
      to the etypecase
  - semantic-node-source-location redef — adds the new case
  - generate-node-ir defmethod for semantic-atomic-rmw:
      extracts ptr from semantic-aref target (3rd value of generate-node-ir on aref),
      picks LLVM opcode based on op + type category (signed/unsigned/float),
      calls llvm-build-atomic-rmw, returns old value
  - %handle-single-value-backward redef — tensor scatter uses atomic-add! not set!+add

Tests (TDD, .crisp E2E checking IR output)
-------------------------------------------
tests/spec/082-atomics/
  01-atomic-add-cell.crisp
  02-atomic-sub-cell.crisp
  03-atomic-inc-cell.crisp
  04-atomic-dec-cell.crisp
  05-atomic-min-cell.crisp
  06-atomic-max-cell.crisp
  07-atomic-xchg-cell.crisp
  08-atomic-add-tensor.crisp
  09-atomic-set-alias.crisp          (atomic-set! = atomic-xchg!)
  10-tensor-ad-with-atomics.crisp    (;; TEST-WITH[--differentiate])
  errors/
    01-non-memory-target.crisp
    02-wrong-arg-count.crisp





Atomic Operations
Crisp provides a number of built-in atomic operations that perform their work on shared memory locations. Each function is guaranteed to be a single, indivisible transaction. Each one updates some variable in place and returns the value at the location BEFORE the modification occured.

atomic-add!
Adds a value to a memory location, updating it. This routine returns the value BEFORE this modification. This “fetch-and-add” behavior is the classic parallel reduction primitive.

Syntax: (atomic-add! location delta)

Example: (let ((old (atomic-add! (~ result 0) 1))) ...) This example adds 1 to the first element of the result vector. The variable old will have whatever was in (~ result 0) before the addition occured.

atomic-sub!
Subtracts a value from a memory location, updating it. This routine returns the value BEFORE this modification..

Syntax: (atomic-sub! location delta)

Example: (let ((old (atomic-sub! (~ total-vec 0) 1))) ...) This example decrements a shared counter. old will be set to whatever was there BEFORE the modification.

atomic-inc!
Atomically increments a memory location by 1. Returns the value there previously.

Syntax: (atomic-inc! location)

Example: (let ((old (atomic-inc! (~ counter-vec 0)))) ...)

atomic-dec!
Atomically decrements a memory location by 1. Returns the value there previously.

Syntax: (atomic-dec! location)

Example: (let ((old (atomic-dec! (~ tasks-vec 0)))) ...)

atomic-min!
Compares a value at a memory location with a new value and stores the minimum of the two. Returns the value there previously.

Syntax: (atomic-min! location new-value)

Example: (let ((old (atomic-min! (~ min-across-threads-vec 0) local-min))) ...)

atomic-max!
Compares a value at a memory location with a new value and stores the maximum of the two. Returns the value there previously.

Syntax: (atomic-max! location new-value)

Example: (let ((old (atomic-max! (~ max-across-threads-vec 0) local-max))) ...)

atomic-xchg! | atomic-set!
Atomically exchanges the value at a memory location with a new value and returns the old value. It does this UNCONDITIONALLY.

Syntax: (atomic-xchg! location new-value)

Example: (let ((old-value (atomic-xchg! (~ thread-lock-vec 0) 1))) ...)

atomic-set! is just an alias for atomic-xchg! .

atomic-binop!
Syntax: (atomic-binop! location binop-f arg)

Uses an atomic CAS (Compare and Swap) under the hood. atomic-binop! will call a binary op function #(T T => T) with arg and the value at location and then store the new value back in the location. This is a CONDITIONAL exchange. Returns the value there previously.

Example:

;reduce someVar across all groups
(when-thread-in-group=is 0
  (let ((old-value (atomic-binop! (~ result-vec 0) #'+ someVar)))
    ...))
; IMPLEMENTATION NOTES
;; The macro generates a BOUNDED loop to guarantee termination.
(dotimes+ (retry-count 1000) ; Use a generous but finite limit
  (let ((old-val (~ global-result 0)))
    (let ((new-val (funcall #'+ old-val my-partial-sum)))
      (when (atomic-cas! (~ global-result 0) old-val new-val)
        ;; If the CAS succeeded, break the loop.
        (return-from-loop)))))
atomic-op!
Syntax: (atomic-op! location op-f)

Uses an atomic CAS (Compare and Swap) under the hood. atomic-op! calls a unary function #(T => T) with the value at location and then store the result back to location. This is a CONDITIONAL exchange. Returns the value there previously.

Example: (let ((old-value (atomic-op! (~ global-counter 0) #'plus-ten))) ...)

atomics and grid level operations
Using any atomic operation on :global memory makes the containing function or macro into a grid level operation. The compiler will emit an error if attempted in the thread level context of a def-function. Use def-grid-function instead. If writing a defmacro, be sure to include (declare (grid-level)) in its progn expansion.

Example: Summing a Vector to One Value.
The last time we summed a vector, our result vector had M entries, one for each workgroup which the host was exected to sum up.

This time, our result vector only needs to have space for one entry. Each thread-0 of each workgroup will add its sum to the first element of the result vector. ( It mightn’t be the worst idea to make sure that it’s value is 0 before hoisting)

;; 32 warps maximum for most hardware
(def-constant +warp-size+ 32 ulong)

;; the source vector can be any size. 
(def-type source-vec (vector long :address-space :global :access :readable))     

;; the final result vector is just has 1 long value
(def-type result-vec (vector long :address-space :global :access :writeable :length 1)) 

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


