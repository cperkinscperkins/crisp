# Sum a Vector using Warps and Shuffles ✅


Would you like to calculate the sum of a vector without needing any local shared memory
and without needing any barriers? Just a drop of blood is all we need, use it to sign the
contract below.

This version starts out the same as the last one: each thread strides the vector and keeps its
own sum.  Then, instead of local memory, the warp reduces with **shuffles**: each lane fetches
another lane's sum with an XOR mask and adds it -- 16 apart, then 8, 4, 2, 1 -- a butterfly in
which every lane both gives and receives.  Lane 0 then records the warp's total in `Res`.

The workgroup is exactly one warp, so `Res` has one element per workgroup.  That ties the
workgroup size to the warp size, which can limit latency hiding (there are no "extra" warps to
run while this one stalls on memory).  The payoff is no local memory and no barriers.  Shuffles,
used correctly, are wicked fast -- they just cannot reach outside a single warp.

```
(def-type in-vec  (vector float :address-space :global :align :compact))
(def-type res-vec (vector float :address-space :global :align :compact))

;; One warp per workgroup; Res needs one element per workgroup.
(def-kernel sum_vector_warp_first_stage (A &out Res)
  (declare #'(in-vec &out res-vec => nil)
           (global-size :derive-from A :strategy :strided)
           (local-size  :set-to 32))          ; one warp -- see the note below
  (let ((sum 0.0))
    (loop-vector-stride A (i)
      (set! sum (+ sum (~ A i))))

    ;; Butterfly: s is 16, 8, 4, 2, 1 on a 32-lane warp; every lane gives and receives.
    ;; The + variant proves the loop runs uniformly, which is what makes the shuffle
    ;; inside it a legal warp collective.
    (dec-times-by-half+ (s (/ (warp-size) 2u))
      (set! sum (+ sum (shuffle-xor sum s))))

    (when (= (warp-lane) 0u)
      (set! (~ Res (get-workgroup-id 0)) sum))))
```

Things worth noticing:

- `(warp-size)` comes from the active hardware profile, so the loop reduces over 32 lanes on
  NVIDIA and 16 on a `:simd-width 16` Intel part.  It is a `uint`, hence `2u` and `0u`.
- The `local-size` must equal one warp.  On NVIDIA that is 32.  On Intel (SPIR-V) compile with a
  hardware profile (e.g. `--hardware-profile=bmg`) and give `local-size` that profile's
  `:simd-width` (16 for BMG): Crisp refuses to compile a warp collective for SPIR-V unless it can
  pin the subgroup size, rather than guess.  `(local-size :set-to (warp-size))` is the intended
  spelling, but it is not yet resolved when the SPIR-V subgroup size is pinned (BUG 118).
- A `float` accumulator moves 32 bits per shuffle; a `long` or `double` moves two 32-bit halves.

As before, `Res` holds one partial sum per workgroup.  And as before, **in practice use
`(reduce-vec #'+ A 0.0 out)`**, which chooses warp shuffles where the hardware supports them and
finishes the cross-workgroup step for you.

