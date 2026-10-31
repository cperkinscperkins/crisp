# Radix Sort 📝


Like Bitonic Sort, Radix Sort is done with multiple kernels, but its structure is a loop 
of "histogram-scan-scatter" passes, not "sort-merge-merge-merge..." like bitonic.

The easiest way to understand Radix Sort is to think of it like sorting a huge pile of mail by zip code. You don't compare two envelopes directly. Instead:
- You first create piles for the last digit of the zip code (0-9).
- You go through all the mail, putting each envelope in the correct pile.
- You stack the piles back together in order (all the 0s, then all the 1s, etc.).
- You then repeat the entire process for the second-to-last digit, and so on, until the mail is fully sorted.

Radix Sort does this with the bits of your numbers.  It loops over three kernels: histogram, prefix-sum, and scatter.

#### Radix Sort on the GPU

The entire process is a loop that has to be organized host side. For a 32-bit integer, you might loop 4 times, processing 8 bits in each pass. Inside this loop, the host orchestrates a sequence of kernel launches.

##### Step 1: The Histogram Kernel
The first kernel's job is to count the occurrences of each "digit" across the entire dataset.

How it works: Each workgroup computes a local histogram (e.g., a 256-element array for an 8-bit pass) in its fast shared memory. The leader of each workgroup then uses atomic-add! to add its local counts to a small global histogram buffer.

Result: A small array in global memory with the total count for each digit.

##### Step 2: The Prefix-Sum (Scan) Kernel
The second kernel's job is to turn the histogram counts into bucket offsets. It answers the question, "Where does the bucket for digit X begin in the final output array?"

How it works: Since the global histogram is very small (e.g., 256 elements), this is a tiny, fast kernel, often launched with just a single workgroup. It performs an exclusive scan on the histogram. (This step can sometimes even be done on the host CPU because the data size is negligible).

Result: A small array of "bucket pointers" in global memory.

##### Step 3: The Scatter (or Permute) Kernel
The third kernel's job is to actually move the data.

How it works: Each thread reads an element, looks at its current "digit," uses the bucket pointers from Step 2 to find the base address for that digit, and then uses a local counter to find its specific place within that bucket. It then writes the element to a new output buffer.

Result: A new global buffer where the data is sorted according to the current group of bits.

This new output buffer then becomes the input buffer for the next pass of the host-side loop. This is often called "ping-ponging" between two large buffers. After the final pass (on the most significant bits), the data is fully sorted.

#### Radix Sort in Crisp ✅

A working LSD radix sort of `float` is the GPU MODE `sort_v2` entry (`contests/gpu-mode/07-sort-v2/`):
`sort_radix.crisp` (reduce-then-scan, the three-kernel loop described above) and `sort_onesweep.crisp`
(one kernel per pass, decoupled look-back).  `sort_radix` is verified bit-exact against a reference sort on
the Intel Arc B580 (SPIR-V) and the H100 (PTX) -- the warp logic follows `(warp-size)`, so one source serves
both; `sort_onesweep` was verified on the H100 (on the BMG it does not launch: BUG 147), but needs a
look-back form before it compiles again -- see below.  On the H100 the
scored 100M case takes 3.75 ms (reduce-then-scan) -- correct, but about twice the board's median.

##### Keys

A float's bits become an unsigned key whose unsigned order is the float order -- positive floats flip the
sign bit, negative floats flip every bit -- and back again after the last pass:

```lisp
(def-function float-bits-to-key (b)
  (declare #'(uint => uint))
  (return (if (= (ash b -31) 1u) (lognot b) (logxor b 2147483648u))))

(def-function key-to-float-bits (k)
  (declare #'(uint => uint))
  (return (if (= (ash k -31) 1u) (logxor k 2147483648u) (lognot k))))
```

The kernels read and write the float buffers through a `uint` view: `(make-vector src uint :length n)`.

**Range reduction.**  A first pass finds the smallest and largest key; every pass then sorts
`key - kmin`, so only `ceil(bits(kmax - kmin) / 8)` 8-bit passes are needed.  Values 6252 .. 16251 differ
in their low 24 bits: 3 passes, not 4.  It is correct for any input -- all-equal input needs 0 passes (a
copy).

##### Ranking within a tile: the hard part

The scatter needs each key's STABLE rank among the keys of its tile that share its digit.  Each 256-thread
workgroup loads a tile of 4096 keys into shared memory and sorts it by the 8-bit digit with two 4-bit
counting splits (low nibble, then high).  A split: every thread counts the nibbles of its 16 keys, the
4096 counts are exclusive-scanned in (digit, thread) order, and each key goes to its digit's offset plus
the number of the thread's earlier keys with the same digit.

Here the counts live in REGISTERS: 16 counters of at most 16 fit in 8-bit fields of two `ulong`s.  (Measured
on the H100 this is no faster than counters in shared memory -- the downsweep is bound by instruction count,
not by the counters' read-modify-write.  Either works.)  Before the splits each key is ROTATED so the pass's
digit is its low byte: every digit extraction below is then a constant mask, where a run-time `ash` costs
about ten instructions.

```lisp
;; LO holds digits 0-7, HI digits 8-15, 8 bits each.
(def-function nib-inc (d)
  (declare #'(uint => ulong))
  (return (ash 1ul (to-int (* (logand d 7u) 8u)))))

(def-function nib-field (lo hi d)
  (declare #'(ulong ulong uint => uint))
  (return (to-uint (logand (ash (if (< d 8u) lo hi) (- (to-int (* (logand d 7u) 8u)))) 255ul))))

;; Stable counting sort of the 4096 keys in IN by the 4 bits at SH, into OUT.  Workgroup-uniform.
(def-grid-function split-nibble (in out cnt wtot tid sh)
  (declare #'(smem-vec smem-vec smem-vec smem-vec ulong int => nil))
  (let ((lo 0ul) (hi 0ul))                         ; count this thread's 16 keys in registers
    (dotimes (j 16ul)
      (let ((d   (logand (ash (~ in (+ (* j 257ul) tid)) (- sh)) 15u))
            (inc (nib-inc d)))
        (set! lo (+ lo (if (< d 8u) inc 0ul)))
        (set! hi (+ hi (if (< d 8u) 0ul inc)))))
    (dotimes (dg 16ul)                             ; publish the 16 counts
      (set! (~ cnt (cnt-word (+ (* dg 256ul) tid))) (nib-field lo hi (to-uint dg)))))
  (sync-workgroup)
  (let ((mine 0u))                                 ; exclusive scan of all 4096 counts
    (dotimes (j 16ul)
      (set! mine (+ mine (~ cnt (cnt-word (+ (* tid 16ul) j))))))
    (block-scan-u mine tid wtot)
    (let ((run (~ wtot (+ 32ul tid))))
      (dotimes (j 16ul)
        (let ((c (cnt-word (+ (* tid 16ul) j)))
              (v (~ cnt c)))
          (set! (~ cnt c) run)
          (set! run (+ run v))))))
  (sync-workgroup)
  (let ((lo 0ul) (hi 0ul))                         ; each key to its rank
    (dotimes (j 16ul)
      (let ((k   (~ in (+ (* j 257ul) tid)))
            (d   (logand (ash k (- sh)) 15u))
            (inc (nib-inc d))
            (r   (+ (~ cnt (cnt-word (+ (* (to-ulong d) 256ul) tid))) (nib-field lo hi d))))
        (set! lo (+ lo (if (< d 8u) inc 0ul)))
        (set! hi (+ hi (if (< d 8u) 0ul inc)))
        (set! (~ out (tile-word (to-ulong r))) k))))
  (sync-workgroup)
  (return))
```

**Layouts.**  Logical tile position `p` lives at shared word `(p mod 16) * 257 + p / 16` (`tile-word`), so
the counting reads -- thread `t` reads its 16 keys `16t .. 16t+15` -- are conflict-free; counter
`c = digit * 256 + thread` lives at word `c + c / 32` (`cnt-word`), conflict-free both for counting and for
the scan, which walks `16t .. 16t+15`.  `block-scan-u` is a 256-thread exclusive scan (warp shuffles, then
the warp totals); being a grid function it returns nothing, so it leaves each thread's prefix in shared
scratch.

After the two splits the tile is sorted by its 8-bit digit; each digit's run `[lstart, lend)` is found by
comparing neighbours, and the run is written out contiguously: key `p` goes to
`digit-base + offset-of-this-tile + (p - lstart)`.

##### Onesweep: no upsweep, no scan kernel

`sort_onesweep.crisp` removes the per-pass histogram and scan kernels:

- one read of the input finds kmin / kmax AND pass 0's histogram: `(key - kmin) mod 256` is the raw key's
  low byte rotated by kmin, so the raw low-byte histogram, read with an offset, IS pass 0's;
- each pass is one launch.  A tile takes an in-order ticket (`atomic-inc!` on a counter the last tile
  resets), sorts itself, publishes its 256 digit counts, and each thread looks back over the predecessor
  tiles for its digit -- a decoupled look-back on 64-bit status words `(tag << 32) | count`, with tags
  `epoch * 4 + 1` (this tile's count) and `epoch * 4 + 2` (the running total through this tile).  The
  epoch is unique per launch, so the status words are never re-zeroed;
- while it has its tile sorted, each tile also counts its NEXT digit and adds the 256 totals to the global
  histogram: the next pass has its digit bases without reading the keys again.

The publish is a single `atomic-store!` of the whole word, so no separate fence is needed between data
and flag.  The look-back, though, must WAIT for a predecessor that has not published yet -- an unbounded
wait, and an author cannot write one: Crisp has no `while` (only the compiler hides a spin, inside a form
that owns a VJP, as `sync-wait` does).  `sort_onesweep.crisp` was written with a `while` before that door
was closed, and does not compile today; it waits on a sanctioned look-back form 📝.

##### The library forms 📝

The functions sketched below (`histogram-pass`, `scan-histogram`, `scatter-pass`) remain the intended
library API; the kernels above are their working bodies.  The earlier "possible implementations" here did
not compile (barriers inside `def-function`, an unstable atomic scatter for the local rank, `as-bits`) and
have been removed.

##### `histogram-pass` 📝
```
(histogram-pass input-vec bit-offset &out global-histogram &optional local-histogram)
```
One pass's digit counts.  Working body today: `sort_upsweep` (per-tile counts) or, for the onesweep form, the
per-tile counts a tile publishes for itself.

##### `scan-histogram` 📝
```
(scan-histogram global-histogram &out bucket-offsets)
```
The exclusive scan of the counts.  Working body today: `sort_digit_scan`, or the per-digit look-back.

##### `scatter-pass` 📝
```
(scatter-pass input-vec bucket-offset bit-offset &out output-vec)
```
The stable scatter.  Working body today: `sort_downsweep` -- the local sort above is the "local rank within
digit" the old sketch left open, and it is the part that decides the speed.

