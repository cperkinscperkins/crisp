# `grid-reduce-cas!` 📝


`(grid-reduce-cas! someFunction <someVar> identity &out return-vec &optional localScratchVec)`

`grid-reduce-cas!` is a single-pass grid reduction that works with *any* commutative binary operation. It first reduces the variable locally using `reduce-workgroup`, and then the leader thread of each workgroup uses a global Compare-And-Swap (CAS) loop via `atomic-binop!` to safely accumulate its partial result into the `return-vec`.

**The Trade-off:**
This macro is the ultimate "low memory escape hatch." Unlike `grid-reduce-last-man!`, it requires zero global scratchpad memory. However, because every workgroup leader is trying to read, compute, and swap the exact same global address at the end of the kernel, it effectively serializes the grid into a massive traffic jam. One thread wins the CAS, while the others fail, loop, and try again. Use this only if your operation cannot use native atomics (`grid-reduce-atomic!`) AND you absolutely cannot afford the memory footprint of a global scratch buffer.

**Arguments:**

* `return-vec`: A required vector of length 1 (a `single-result`) where the final value is accumulated.
* `localScratchVec`: (Optional) Writeable local memory sized to the number of warps in the workgroup. Generated automatically if omitted.

**Result:**
After the operation, the value of `<someVar>` in any thread is indeterminant. `return-vec[0]` will hold the final global reduction.

**Possible Implementation:**

```lisp
;; -- grid-reduce-cas! --
(defmacro grid-reduce-cas! (someFunction someVar identity return-vec
                            &optional (localScratchVec (make-scratch-vector (type-of someVar) :match-num-warps-per-workgroup :msg message))
                            &key message)
  (c-t-assert (is-type-of someFunction (binop-type (type-of someVar))) "type mismatch between someFunction and someVar")
  (c-t-assert (is-type-of someVar (type-of identity)) "type mismatch between someVar and identity")
  (c-t-assert (is-type-of someVar (element-type return-vec)) "type mismatch between someVar and return-vec")
  
  `(progn
    (declare (grid-level))
    
    ;; Phase 1: Micro Strategy (Intra-Workgroup)
    (reduce-workgroup ,someFunction ,someVar ,identity :local-scratch-vec ,localScratchVec)

    ;; Phase 2: Macro Strategy (Inter-Workgroup)
    ;; Global atomic combination via Compare-And-Swap loop
    (when-thread-in-group-is 0
      (atomic-binop! (~ ,return-vec 0) ,someFunction ,someVar))))

```

