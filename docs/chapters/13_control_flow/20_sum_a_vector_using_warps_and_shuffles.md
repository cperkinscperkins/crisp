# Sum a Vector using Warps and Shuffles ✅


Would you like to calculate the sum of a vector without needing any local shared memory
and without needing any barriers? Just a drop of blood is all we need, use it to sign the
contract below.

This version starts out the same as the last one. The grid stride legerdemain is used and
each of the threads holds its own copy of a sum. Then, as before, we reduce. Half the warp
uses a shuffle and an XOR mask to fetch the sum from another thread and add it. Then half
again, and so on. And then we record the results into the same Result vector.

The result vector should be size M, where M = global_work_size / local_work_size. This is
the same size as the number of workgroups.

Note that this version ties the workgroup size to the size of a single warp. Doing so might
limit the latency-hiding opportunities, because there are no "extra" warps to fill in if
this one stalls on a memory access. But that potential penalty is offset by the use of
shuffles instead of local memory and barriers. Shuffles, used correctly, are wicked fast —
they just cannot reach outside a single warp.

This version of vector summing is likely faster than the last one.

```
;; the source vector can be any size.
(def-type source-vec (in-vec long :compact))

;; the result vector should be size M, where M = global_work_size / local_work_size
;; aka num-groups
(def-type result-vec (vector long :align :compact :address-space :global :size (get-num-groups)))


;; -- calculate-this-thread-sum --
(def-function calculate-this-thread-sum (A)
  (declare #(source-vec -> long))
  (let ((sum 0))
    (loop-vector-stride A (i)
      (inc! sum (~ A i))))) ; <-- inc! implicitly returns final sum


;; -- sum_vector_warp_first_stage --
(def-kernel sum_vector_warp_first_stage (A Res)
    (declare #'(source-vec result-vec => nil)
             (local-size :set-to (warp-size)
                         :msg "this kernel requires the local work size to equal the warp size")
             (global-size :derive-from A :strategy :strided))
  ;; Stride the vector, summing it up. Each thread has its own value in 'sum'
  (let ((sum (calculate-this-thread-sum A)))

    ;; Reduce. `s` descends 16, 8, 4, 2, 1 on a 32-lane warp, and every lane both gives
    ;; and receives at each step -- a butterfly. The `+` form is not decoration: it is
    ;; what proves the loop runs uniformly, which is what makes the shuffle inside it a
    ;; legal warp collective.
    (dec-times-by-half+ (s (/ (warp-size) 2))
       (inc! sum (shuffle-xor sum s)))

    ;; move sum to global
    (when-thread-in-group-is (0)
      (let ((wg-idx (get-workgroup-id 0)))
          (set! (~ Res wg-idx) sum)))))
```

Two things worth noticing, because they are the difference between this compiling
everywhere and this working only on the machine you wrote it on.

First, nothing here says 32. `(warp-size)` is a compile-time constant that comes from the
active hardware profile, so the same source reduces over 32 lanes on NVIDIA and 16 on a
`:simd-width 16` Intel part, and the `local-size` declaration follows it automatically.

Second, `sum` is a `long`. Each `shuffle-xor` therefore moves 64 bits as two 32-bit halves
(see **Supported Types**). That is real instruction count, and if you do not need the range
a `float` or `int` accumulator halves it.

Like the previous sum_vector demonstration, this example is provided so that you can see
"Crisp-ish" constructs used together, this time with shuffles and warps. The vector is not
fully summed. That requires a second kernel pass. Most expedient is to make another kernel
that employs `reduce-vec-second-stage` (see below) and then you will have a two step
solution. If you would like to see the hoisting code in action, then use either a
continuation kernel (see above) or `def-orchestration` (see below).

