# Sum a Vector using Local Memory ✅


Earlier we demonstrated a simple `vector_add` using grid strides.
This example is slightly more complicated and uses several of the control flow
constructs that have been covered so far.

We can easily use multiple threads to stride through a vector summing it as they go.
But if we have 1024 threads, we'll end up with 1024 different sums that, in turn,
need to be summed.

We COULD write all 1024 into global memory and sum them from one thread, or on the host.
But that is a lot of the slowest kind of memory, so we will not do that.

Instead, each workgroup reduces its own threads' sums in **local memory**, which is fast but
shared only within a workgroup, using a tree: half the threads add the other half's value to
their own, then half again, until one value is left.  One thread per workgroup then writes that
value to the result vector `Res`, which has one element per workgroup
(global_work_size / local_work_size of them).

```
(def-type in-vec  (vector float :address-space :global :align :compact))
(def-type res-vec (vector float :address-space :global :align :compact))

;; Res needs one element per workgroup.
(def-kernel sum_vector_first_stage (A &out Res)
  (declare #'(in-vec &out res-vec => nil)
           (global-size :derive-from A :strategy :strided)
           (local-size  :set-to 64))
  (let ((sum 0.0))
    ;; Stride the vector. Each thread accumulates its own partial sum.
    (loop-vector-stride A (i)
      (set! sum (+ sum (~ A i))))

    ;; One slot per thread of the workgroup, in fast local memory.
    (let ((slm (make-scratch-vector float :match-workgroup-size))
          (lid (get-local-linear-id)))
      (set! (~ slm lid) sum)

      ;; Tree reduce (lid is a ulong, hence 32ul): s is 32, 16, 8, 4, 2, 1.  The barrier at the
      ;; top of each step makes the previous step's writes visible.  The + variant proves the
      ;; loop is uniform, which a barrier inside a loop requires.
      (dec-times-by-half+ (s 32ul)
        (sync-workgroup)
        (when (< lid s)
          (set! (~ slm lid) (+ (~ slm lid) (~ slm (+ lid s))))))

      ;; Thread 0 wrote the last step itself, so it can read slot 0 without another barrier.
      (when (= lid 0ul)
        (set! (~ Res (get-workgroup-id 0)) (~ slm 0))))))
```

This example shows several "Crisp-ish" constructs working together: a vector stride, a scratch
vector sized by `:match-workgroup-size`, the halving loop `dec-times-by-half+`, and
`sync-workgroup`.  Note the literal suffixes: Crisp does not silently convert integer types, so a
literal compared with the `ulong` from `get-local-linear-id` is written `32ul` / `0ul`.

The vector is not fully summed yet -- `Res` holds one partial sum per workgroup and needs a second
pass.  **In practice you do not write any of this by hand**: `(reduce-vec #'+ A 0.0 out)` does the
whole reduction, including the cross-workgroup step, and picks the strategy for the hardware (see
*The Vector API*).


