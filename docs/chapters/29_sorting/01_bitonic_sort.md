# Bitonic Sort 📝


Crisp provides a "toolkit" for bitonic sort.  If the sort can be performed by a single workgroup, then there are functions for that.
But if the sort is occurring across a vector larger than than, then a multi-stage approach is required.


In the first stage, you hoist/enqueue a kernel which will invoke one of the `bitonic-sort-workgroup` functions. Crisp provides premade kernel definitions for this if you require no other processing.

In the second stage, you hoist a `bitonic_merge_pass` kernel repeatedly until the sort is completed.

#### A working bitonic sort, today ✅

The toolkit below is still 📝, but bitonic sort itself is plain Crisp today.  This is the GPU MODE
`sort_v2` "beauty" entry (`contests/gpu-mode/07-sort-v2/sort_bitonic_beauty.crisp`), verified bit-exact
against a reference sort on the Intel Arc B580 (SPIR-V) and the H100 (PTX).

The input is padded with `+inf` to a power of two `P`.  For every stage `k = 2, 4, .. P` and every distance
`j = k/2 .. 1`, element `i` (with bit `j` of `i` clear) is compared with `i + j` and the pair is put in
order: ascending where bit `k` of `i` is clear, descending where it is set.  Distances below one tile
(2048 elements) run in shared memory; each larger one is a global pass.

```lisp
(def-type in-vec  (vector float :address-space :global :align :compact))
(def-type out-vec (vector float :address-space :global :align :compact))
(def-type prm-vec (vector uint  :address-space :global :align :compact))
(def-type s-vec   (vector float :address-space :local  :align :compact))

;; Put (~ s i) and (~ s (+ i j)) in order: ascending when UP is 1.
(def-function order-pair (s i j up)
  (declare #'(s-vec ulong ulong uint => nil))
  (let ((a (~ s i))
        (b (~ s (+ i j))))
    (when (= (if (> a b) 1u 0u) up)
      (set! (~ s i) b)
      (set! (~ s (+ i j)) a)))
  (return))

;; The I of pair Q at distance J: Q with a 0 inserted at bit J.
(def-function pair-index (q j)
  (declare #'(ulong ulong => ulong))
  (return (+ (* (* 2ul j) (/ q j)) (rem q j))))

;; 1 where bit K of the global position G is clear (ascending), else 0.
(def-function ascending (g k)
  (declare #'(ulong ulong => uint))
  (return (if (= (logand g k) 0ul) 1u 0u)))

;; Every distance J = from .. 1 of stage K, in shared memory, for the tile at global position BASE.
(def-grid-function merge-in-tile (s base k from tid)
  (declare #'(s-vec ulong ulong ulong ulong => nil)
           (uniform from))
  (dec-times-by-half+ (j from)
    (let ((i (pair-index tid j)))
      (order-pair s i j (ascending (+ base i) k)))
    (sync-workgroup))
  (return))

(def-kernel bitonic_tiles (src &out dst)          ; stages k = 2 .. 2048, all in shared memory
  (declare #'(in-vec &out out-vec => nil)
           (local-size :set-to 1024))
  (let ((tid  (to-ulong (get-local-id 0)))
        (base (* (to-ulong (get-workgroup-id 0)) 2048ul))
        (s    (make-scratch-vector s-vec 2048)))
    (set! (~ s tid) (~ src (+ base tid)))
    (set! (~ s (+ tid 1024ul)) (~ src (+ base (+ tid 1024ul))))
    (sync-workgroup)
    (do-power-step+ (half 2048ul)
      (merge-in-tile s base (* 2ul half) half tid))
    (set! (~ dst (+ base tid)) (~ s tid))
    (set! (~ dst (+ base (+ tid 1024ul))) (~ s (+ tid 1024ul)))))

(def-kernel bitonic_global (src prm &out dst)     ; one distance j >= 2048 of stage k
  (declare #'(in-vec prm-vec &out out-vec => nil)
           (global-size :derive-from src :strategy :strided)
           (local-size  :set-to 256))
  (let ((j     (to-ulong (~ prm 0ul)))
        (k     (to-ulong (~ prm 1ul)))
        (pairs (/ (length~ src) 2ul)))
    (grid-stride (pairs) (q)
      (let ((i (pair-index q j))
            (a (~ src i))
            (b (~ src (+ i j))))
        (if (= (if (> a b) 1u 0u) (ascending i k))
            (progn (set! (~ dst i) b) (set! (~ dst (+ i j)) a))
            (progn (set! (~ dst i) a) (set! (~ dst (+ i j)) b)))))))
```

`bitonic_finish` (distances 1024 .. 1 of one stage `k`, in shared memory) is `bitonic_tiles` with
`(merge-in-tile s base k 1024ul tid)` in place of the stage loop; `bitonic_pad` / `bitonic_unpad` copy in
and out.  The host loop:

```text
bitonic_pad;  bitonic_tiles
for k = 4096 .. P:   for j = k/2 .. 2048:  bitonic_global [j k]
                     bitonic_finish [k]
bitonic_unpad
```

`bitonic_global` and `bitonic_finish` read and write the same buffer: the host passes it as both `src` and
`dst`.  Each element is read and written by one thread per launch, so the read-only load path is safe.

What writing it taught (each is now in `docs/writing-crisp.md`): a helper that holds a barrier must be a
`def-grid-function`, and a grid function returns nothing; shared scratch passed to a helper is an ordinary
parameter (an `&out` parameter is write-only); a loop bound that is a parameter needs `(declare (uniform
...))` before `dec-times-by-half+` will accept it.

#### `bitonic-sort-workgroup` 📝

```
(bitonic-sort-workgroup data-in data-out &key keyF)
(bitonic-sort-workgroup! data &key keyF)
(bitonic-sort-soa-workgroup <property> soa-data-in soa-data-out)
(bitonic-sort-soa-workgroup! <property> soa-data)

(gen-bitonic_sort_workgroup  elementT alignment kernelName &key keyF)
(gen-bitonic_sort_workgroup_in_place elementT alignment kernelName &key keyF)
(gen-bitonic_sort_soa_workgroup structT property alignment kernelName)
(gen-bitonic_sort_soa_workgroup_in_place structT property alignment kernelName)
```

For both `vector` and `soa-vector` there are two variants of bitonic sorting for workgroups. One takes both input and output data, and the
other performs the sort in place and takes just one data argument.

For all variants, the `local_work_size` MUST be a power of 2. 

The `soa-vector` variants key the sorting off a property. The property named must be an `is-orderable?` type.
If the property access has an overload for `soa-vector` then that overload will be used.

The `vector` variants support an optional `keyF` function `#(T => U) (type-is U #:is-orderable?)`.  Typically
a `keyF` would be used if the `vector` was one of some struct (like `point`) and `keyF` would then 
be a property retrieval function (like `x~`). But technically, the `keyF` can be anything so long as it 
returns an orderable value (for example, it could add the `x` and `y` values of the point and return their sum).
The astute reader will observe that could be done with an overload property function as well. 

Lastly, note for `vector` of structs, that the Crisp developer can choose between overloading `>` and `<` 
for some struct, using a custom `keyF` function, using a property access function `~x`, or and overloaded property
access function, to influence or intercept the ordering. 

But for the `soa-vector` variant, beyond simply specifying the property to key off, the only 
intercept is via an overload that includes `soa-vector`.


The core operation in Bitonic Sort is a simple compare-and-swap. The entire algorithm is just a series of 
these compare-and-swap steps organized into a perfectly predictable, geometric pattern.

When bitonic sorting, we repeatedly merge "bitonic sequences" (sequences that first increase then decrease, or vice-versa) into larger sorted sequences.
We do this in a highly choreographed fashion. Every step we perform the same simple move (compare-and-swap with a partner), 
but the distance to the partner changes in a fixed sequence (1 step away, then 2 steps away, then 4, etc.). 
The pattern is the same regardless of what the input numbers are.
When swapping, there is a sorting direction. `direction == true` for an ascending sort, and `direction == false` for descending one. 


The working `order-pair` / `merge-in-tile` / `bitonic_tiles` above are what this function would
wrap.  (The sketch that used to be here did not compile: it held a barrier in a `def-function`,
returned a value from a function that synchronizes, and used a run-time loop bound without proving
it uniform -- see the notes at the end of *A working bitonic sort*.)

#### `bitonic_merge_pass` 📝

```
(bitonic-merge-pass data j k &keyF)

(gen-bintonic_merge_pass elementT alignment kernelName &key keyF)
(gen-bintonic_soa_merge_pass structT property alignment kernelName)
```
The merge pass is provided as both a function you can use, and a kernel template that can be
generated.  The generated kernel takes `data`, `j` and `k`; the generated hoisting code shows how
to step `j` and `k` between launches.  Its working form today is `bitonic_global` above (one
global distance) plus `bitonic_finish` (the distances below one tile, in shared memory).

#### Don't Make Me Think `gen-bitonic-sort-vector` 📝

```
(gen-bitonic-sort-vector elementT alignment) ;;  &key keyF
(gen-bitonic-sort-soa-vector elementT alignment)

(gen-bitonic-sort-vector! elementT alignment) ;;  &key keyF
(gen-bitonic-sort-soa-vector! structT property alignment)
```

If you don't want a toolkit, Crisp provides some "orchestrations" that will sort the vector.  
If generated, then the two kernels will be compiled and the hoisting example code will correctly show
how to calculate `j` and `k` and enqueue the merge pass until done.  


`soa-vector` variants of these two orchestrations are provided as well. 


The host loop under *A working bitonic sort* is exactly the orchestration this would generate.

