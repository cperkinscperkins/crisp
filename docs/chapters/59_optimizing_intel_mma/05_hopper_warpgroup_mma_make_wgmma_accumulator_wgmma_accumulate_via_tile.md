# Hopper warpgroup MMA — `make-wgmma-accumulator` ✅ + `wgmma-accumulate-via-tile` ✅


On NVIDIA **Hopper (sm_90a)** the tensor-core unit is driven by `wgmma` (4th-gen *warpgroup*
async MMA) rather than the `mma.sync` used by `mma-accumulate-via-tile`.  The difference is
scope: one `wgmma` instruction spans a **warpgroup** — 4 warps / **128 threads** — and produces
a `64×N` output in a single issue (an `m64n128k8` is 64×128 = 8192 results), with the accumulator
spread across all 128 threads.  It is the instruction cuBLAS uses; on the benchmark ladder the
Crisp wgmma matmul reaches ~⅔ of the cuBLAS tf32 ceiling, versus a few percent for the naive
`mma.sync` chapters.

Two forms mirror the `make-register-tile` / `mma-accumulate-via-tile` pair:

```
(make-wgmma-accumulator <elem> (64 N) <init>)          ; the D matrix — a warpgroup accumulator
(wgmma-accumulate-via-tile (64 N K) D A B [:swizzle :128b] [:b-major :k|:mn])   ; D += A·B ; A, B are SMEM tiles
```

`make-wgmma-accumulator` mints (on demand) a `64×N` warpgroup accumulator record — `N/2` flat
`f32` registers per thread, the wgmma D thread→element mapping across the 128-thread warpgroup —
each field initialized to `<init>`.  `<elem>` is `float` (tf32) for now.  It is a **dedicated**
constructor, not a flag on `make-register-tile`, precisely because the per-thread layout is the
warpgroup one, not the per-warp fragment layout.

`wgmma-accumulate-via-tile` does `D += A·B` over the whole accumulator in one shot — **no fragment
walk** (contrast `mma-accumulate-via-tile`, which loops the fragment grid for you).  It is
**synchronous**: the macro wraps the `wgmma.fence` / `commit_group` / `wait_group` around the
accumulate, so one call is a complete `D += A·B`.  `A` and `B` are SMEM scratch tiles (from
`make-scratch-matrix`, `load-tile`, or a `:block` TMA load).

Shape rules — grounded in the ISA, checked at compile time:

- **M is fixed at 64** (wgmma is always `m64`); anything else is a compile error.
- **N is a multiple of 8 in `[8, 256]`** (the `m64nNk8` family).
- **K depends on `:swizzle`.**  Without it, `K` must be exactly **8** — a single `k8` slice fed
  from a plain row/col-major SMEM tile.  With `:swizzle :128b`, `K` may be any positive multiple
  of 8: the tile is a **K-block** of `K/8` slices, and the accumulate emits the 128-byte-swizzle
  SMEM descriptor + a `wgmma` per `k8` slice.  (`:128b` swizzle also requires the innermost 32
  tf32 elements to be 128-byte contiguous — already true for a `64×32` K-block load.)
- **local-size must be a multiple of 128** — a warpgroup is 128 threads.  A single-warpgroup
  kernel declares `(local-size :set-to 128)`; multiple warpgroups (and the producer-warp +
  consumer-warpgroup split under `with-warp-specialization`) scale that up.

```
;; one warpgroup, a single k8 tf32 accumulate
(def-kernel wgmma_min (&out C)
  (declare #'(&out mt) (global-size :set-to 128) (local-size :set-to 128))
  (let ((A-tile (make-scratch-matrix float (64 8)))
        (B-tile (make-scratch-matrix float (8 64)))
        (D      (make-wgmma-accumulator float (64 64) 0.0)))
    (wgmma-accumulate-via-tile (64 64 8) D A-tile B-tile)
    ...))

;; a 32-wide K-block (4 k8 slices) over a big n256 tile, swizzled
(wgmma-accumulate-via-tile (64 256 32) D A-tile B-tile :swizzle :128b)
```

wgmma is **forward-only** (no autodiff) and NVIDIA-Hopper-only; on other targets use
`mma-accumulate-via-tile`.

**Storing the accumulator.**  `(store-tile D C (gy gx))` places a 64×N accumulator by tile index;
`(store-tile-at D C (row col))` places it at an absolute origin (needed when two consumer warpgroups
split a 128-row tile).  The accumulator is `float`; to write a `half` / `bfloat16` matrix, convert on the
source — `(store-tile-at (to-half D) C (row col))` — and each element is rounded to nearest-even as it is
stored (endeavour 196).

**Storing through the TMA: `:via :tma`.**  The direct store writes each thread's column pairs straight to
global memory, and the whole warpgroup waits on it.  `(store-tile-at (to-half D) C (row col) :via :tma)`
sends the accumulator out the way it came in (endeavour 199): each warp converts its 16 rows to 16-bit
pairs, writes them with `stmatrix` into a 4 KB staging slice laid out as two 128-byte-swizzled 16×64
boxes, and one lane issues a TMA store per box through a tensor map of C.  The writes complete
asynchronously; a warp waits only for its slice to be *read* before reusing it.  On the H100 matmul
kernel (4096×5120×4096 fp16) it took the call from 255 to 228 µs, bit-exact.

```
(def-kernel matmul (A B &out C)
  (declare #'(a-mat b-mat &out c-mat) (local-size :set-to 288))
  ...
        (:consumer0 ...
          (store-tile-at (to-half D0) C ((* grid-y (to-ulong 128)) (* grid-x (to-ulong 256))) :via :tma))
  ...)
```

The compiler owns the staging buffer: one per kernel, 16 KB per full warpgroup of the declared
`local-size` plus 1 KB of alignment, allocated after the kernel's own scratch (count it against the
shared-memory budget — 227 KB on H100).  `:via :tma` needs a wgmma accumulator converted with
`to-half` / `to-bfloat16` (`stmatrix` moves 16-bit elements) into a matching `:row-major` destination
that is a kernel parameter, N a multiple of 64 (one 128-byte box), and a compile-time
`(local-size :set-to N)`; anything else is refused with a message naming the rule.  Without `:via` the
store is the direct one.

By default wgmma reads B **K-major**: declare B `(N K)`, i.e. a `(K N)` matrix that is `:col-major`.  A
row-major `(K N)` B (PyTorch's plain `a @ b`) is read as it is with `:b-major :mn` (endeavour 198): stage
B as a `(K N)` tile and the 16-bit wgmma reads it with transB=1.  `:mn` needs a `half` / `bfloat16`
operand (tf32 wgmma has no transpose), `:swizzle :128b`, and N a multiple of 64:

```
(B-ring (make-scratch-matrix-ring half (64 256) :ring-count 4))     ; (K N)
(load-tile B (ring-get B-ring slot) (grid-k grid-x) :barrier (ring-get full slot) :swizzle :128b)
(wgmma-accumulate-via-tile (64 256 64) D A-tile (ring-get B-ring slot) :swizzle :128b :b-major :mn)
```

A `:128b` TMA box is at most 128 bytes wide, so a `(64 256)` half tile is loaded as four 64-column boxes;
`load-tile` does that by itself.  Blackwell (sm_100) has no
wgmma — its tensor-core instruction is `tcgen05`, not yet in Crisp — so B200 kernels use
`mma-accumulate-via-tile`.


