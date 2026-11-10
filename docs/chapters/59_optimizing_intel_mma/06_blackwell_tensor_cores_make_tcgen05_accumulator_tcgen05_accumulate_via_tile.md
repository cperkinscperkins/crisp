# Blackwell tensor cores — `make-tcgen05-accumulator` ✅ + `tcgen05-accumulate-via-tile` ✅


On NVIDIA **Blackwell datacenter parts (B200 / GB200, `sm_100a`)** the tensor-core instruction is
`tcgen05`.  Three things change from Hopper's wgmma:

- **The accumulator lives in tensor memory**, a 256 KB per-SM memory of 128 lanes x 512 columns.  A
  128 x 256 f32 accumulator takes 256 columns and no registers.  On Hopper it took 128 registers per
  thread.
- **One thread issues the multiply**, reading A and B from shared memory.
- **Completion arrives on an mbarrier.**  The multiply can free its shared-memory slot by itself, and
  can tell the epilogue its accumulator is ready.

```
(make-tcgen05-accumulator float (128 N) 0.0)                     ; D, in tensor memory
(make-tcgen05-accumulator int (128 N) 0)                         ; s32, for 8-bit operands; or (accum Q)
(make-tcgen05-accumulator-ring float (128 N) :ring-count R)      ; R of them; (ring-get ACC i) is D_i
(make-scratch-matrix nvfp4 (128 256))                            ; a block tile: codes + scales (below)
(tcgen05-accumulate-via-tile (128 N K) D A B :swizzle :128b [:on-complete BARRIER])
(tcgen05-commit BARRIER)        ; BARRIER arrives when every MMA this thread issued has finished
(store-tile D C (gy gx))   (store-tile-at D C (row col))   (store-tile-at (to-bfloat16 D) C (row col) :via :tma)
```

**The accumulator.**  The compiler allocates the kernel's tensor memory at entry and frees it at
exit.  A float or int accumulator takes N columns (one 32-bit cell per element), and the kernel's
total may not exceed 512.  The
accumulator must initialise a `let` binding, and its initial value must be 0.  The first multiply
after (re)initialisation overwrites the accumulator instead of adding to it, so zero costs nothing.
`(set! D (make-tcgen05-accumulator ...))` re-initialises D in place, and `(ring-get ACC i)` is always
a fresh accumulator.

**The accumulate.**
- A is `(128 K)` and B is `(N K)`, both K-major in shared memory, as a `:128b` TMA `load-tile` lays
  them down.
- half / bfloat16 operands take `K = 64`; float (tf32) operands take `K = 32`; char / uchar operands
  take `K = 128`.  Either way K is one 128-byte swizzle atom.
- **8-bit integer operands** (char, uchar, or a `def-qint` over them) accumulate into an int or
  `(accum Q)` accumulator, as on every other MMA path.
  - The signs of A and B are independent.
  - The element-family and sign rules are integer MMA's.  A `def-qint` operand must accumulate into
    its own `(accum Q)` (or its declared product's).
  - `(store-tile-at (to-q-out D 1.0) C (row col))` requantizes each element as it stores it,
    saturating.  That is a direct store: `:via :tma` moves 16-bit boxes.
- N is a multiple of 16 up to 256.  M is 128.
- **Without `:on-complete` the form is synchronous:** one thread issues it, and every thread
  executing the form waits until it has finished.  A plain 128-thread kernel needs nothing else.
- **With `:on-complete BARRIER` it returns at once**, and BARRIER arrives (count 1) when the
  multiply has finished reading its operands.  That is how a pipelined kernel's MMA warp frees an
  operand ring slot.
- `(tcgen05-commit BARRIER)` signals that every multiply issued so far is done.  That is the end of a
  tile.
- The issuing thread is lane 0 of the enclosing `with-warp-specialization` role's first warp, or of
  warp 0 outside a role.

**Reading it back.**
- `store-tile` / `store-tile-at` on a tcgen05 accumulator run on exactly one warpgroup.  Warp w may
  read only tensor-memory lanes `32(w mod 4) .. +31`, so storing takes four consecutive warps.  So
  the storing role is 4 warps, or the kernel is 128 threads.
- Thread t holds row t.
- `(to-half D)` / `(to-bfloat16 D)` convert as they store.
- With `:via :tma` each warp stages its 32 rows in the 128-byte swizzle and sends them as TMA boxes.
- A fused activation goes on the store: `(store-tile-at (to-bfloat16 D) C (row col) :transformF #'relu)`
  applies the function to each element as it leaves tensor memory, before the conversion (endeavour
  210).  It is the only fused epilogue here: `map-elements!` works on registers and the accumulator is
  in tensor memory, so `map-elements!` on it is refused.  Not yet with `:via :tma`.

```
(with-warp-specialization (:epilogue 4 :producer 1 :mma 1)
  (:epilogue
    (await (ring-get acc-full s))
    (store-tile-at (to-bfloat16 (ring-get acc s)) C (row col) :via :tma)
    (signal (ring-get acc-empty s)))
  (:producer ...)                                        ; TMA into the operand ring, as on Hopper
  (:mma
    (await (ring-get acc-empty s))
    (let ((D (ring-get acc s)))
      (dotimes (grid-k (/ (to-ulong K) (to-ulong 64)))
        (let ((slot (mod grid-k (to-ulong 4))))
          (await (ring-get full slot))
          (tcgen05-accumulate-via-tile (128 256 64) D (ring-get A-ring slot) (ring-get B-ring slot)
                                       :swizzle :128b :on-complete (ring-get empty slot)))))
    (tcgen05-commit (ring-get acc-full s))))
```

**Block-scaled microfloats (NVFP4, MXFP4, MXFP8).**  A matrix whose element is a `def-microfloat-block`
holds that block's packed codes.  It is `(M K)` in elements, and fp4 packs two codes per byte.  Its
scales are a separate vector, in the layout the kernel declares:

```
(def-microfloat-block nvfp4 :base fp4 :scale fp8-e4m3 :accum float :shape (16))
(def-type a-mat (matrix nvfp4 :address-space :global :align :compact :contiguous-term :row-major))
(def-type s-vec (vector (scale nvfp4) :address-space :global :align :compact))

(declare (scale-layout SA :of A :blocked-128x4) (scale-layout SB :of B :blocked-128x4))
(let ((A-tile (make-scratch-matrix nvfp4 (128 256)))         ; codes and scales, in shared memory
      (D      (make-tcgen05-accumulator float (128 N) 0.0)) ...)
  (load-tile A A-tile (gy gk) :scales SA :barrier bar :swizzle :128b)
  ...
  (tcgen05-accumulate-via-tile (128 N 256) D A-tile B-tile :swizzle :128b))
```

- **The three blocks** are:
  - NVFP4 (`:base fp4 :scale fp8-e4m3 :shape (16)`), `kind::mxf4nvf4`;
  - MXFP4 (`fp4`, `fp8-e8m0`, 32), `kind::mxf4`;
  - MXFP8 (`fp8-e4m3` or `fp8-e5m2`, `fp8-e8m0`, 32), `kind::mxf8f6f4`.

  Any other block is refused.
- **K per call** is one 128-byte atom of codes: 256 for fp4, 128 for fp8.  A block tile is
  `(R K)`, with R a multiple of 128.  N is 128 or 256.  The accumulator is f32.  A and B are the same
  block.
- **`:blocked-128x4`** is the one layout.  It is cuBLASLt's, CUTLASS's and torchao's `to_blocked`:
  512-byte atoms of 128 rows x 4 scales, row r and scale c at `(r mod 32)*16 + (r div 32)*4 + c`, with
  atoms along K first.  The host provides the scales that way, and the generated hoist does.
- **The compiler does the rest.**  The load copies the tile's scale atoms beside the codes.  The
  multiply copies them into tensor memory (`tcgen05.cp`) into columns it assigns, which count toward
  the 512.  Then it issues the block-scaled MMAs.
- fp4's even element is the low nibble (D-206-3), and the hardware agrees.

**`matrix-multiply-tile-stride`** takes a tcgen05 accumulator as its C-tile, bound in `:let` or outside.
Its tile shape is the accumulator's (M N), and the per-tile reset is a re-initialisation, which costs
nothing.  It is the synchronous form; a warp-specialized pipeline stays `tile-stride` + roles.

**Target and status.**
- tcgen05 needs `--ir-target-arch=sm_100a`.  Plain `sm_100` is refused: the instructions are
  architecture-specific, and the driver would refuse them anyway.
- Consumer Blackwell (`sm_120`) has no tcgen05.
- Forward-only for now.
- Verified on a B200: every spec in tests/spec/208-tcgen05 is MMA_CORRECT (endeavour 208).  The
  synchronous, pipelined, accumulator-ring, `:via :tma`, tf32, int8 (all sign pairs), qint
  requantizing, NVFP4 / MXFP4 / MXFP8 (e4m3 and e5m2) and `matrix-multiply-tile-stride` forms all ran.
- Not built yet: M = 64, `:b-major :mn`, `cta_group::2`, mixed microfloat formats, fp6, and NVFP4's
  per-tensor global scale.


