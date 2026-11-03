# The Tile-Level Path: Integer MMA ✅


Scalar `*!` is an ordinary integer multiply and is legal on every target. The tensor hardware is reached
only through the existing [Matrix Multiplication](#matrix-multiplication) forms, which accept 8-bit
integer operands (`char`, `uchar`, or a `def-qint` over them) with a 32-bit `int` accumulator. Those are
all the hardware offers.

| Target | Form | Notes |
|---|---|---|
| Intel XMX (BMG) | `mma-accumulate-via-tile` with `(8 16 32)` | All four sign pairs.  K=32 is the int8 shape |
| NVIDIA Hopper (H100) | `make-wgmma-accumulator` + `wgmma-accumulate-via-tile` | K=32 per slice.  A mixed-sign kernel needs PTX 8.4 |
| NVIDIA below Hopper | none | Synchronous `mma.sync` is refused (see below) |

On NVIDIA, `wgmma` reads B as `(N K)`, so declare B `:col-major` as for the 16-bit forms.

```lisp
(def-qint q-act :base uchar :accum int)
(def-qint q-wt  :base char  :accum int)
(def-qint q-out :base char  :accum int)
(def-qint-product q-dot (q-act q-wt) :accum int)

(def-type a-mat (matrix q-act :address-space :global :align :compact :contiguous-term :row-major))
(def-type b-mat (matrix q-wt  :address-space :global :align :compact :contiguous-term :col-major))
(def-type c-mat (matrix q-out :address-space :global :align :compact :contiguous-term :row-major))

(def-kernel wgmma_narrow (A B &out C)
  (declare #'(a-mat b-mat &out c-mat)
           (global-size :set-to 128) (local-size :set-to 128))
  (let ((A-tile (make-scratch-matrix q-act (64 128)))
        (B-tile (make-scratch-matrix q-wt (64 128)))
        (D      (make-wgmma-accumulator (accum q-act q-wt) (64 64) 0))
        (bar    (make-async-barrier :mode :block)))
    (load-tile A A-tile (0 0) :barrier bar :swizzle :128b)
    (load-tile B B-tile (0 0) :barrier bar :swizzle :128b)
    (await bar)
    (wgmma-accumulate-via-tile (64 64 128) D A-tile B-tile :swizzle :128b)
    (store-tile-at (to-q-out D 1.0) C (0 0))))   ; narrows each element as it is stored
```

`(to-q-out D m)` on the store's source narrows each accumulator element as it is stored, the same way
`(to-half D)` does for 16-bit output.

**On Intel, narrowing takes two steps.** A SPIR-V cooperative-matrix store writes a whole fragment, with
no per-element hook, and every way of converting the matrix itself was probed on BMG and failed (IGC
crashes, or the store silently delivers nothing). So `(store-tile (to-q-a D m) C ..)` is refused on
SPIR-V. Store into an `int` matrix, then narrow its elements:

```lisp
(def-hardware-profile bmg :simd-width 16 :mma-shapes ((8 16 8) (8 16 32)))

(def-qint q-a :base char :accum int)
(def-type a-mat (matrix q-a :address-space :global :align :compact :contiguous-term :row-major))
(def-type c-mat (matrix q-a-accum :address-space :global :align :compact :contiguous-term :row-major))

(def-kernel xmx_two_step (A B &out C N)
  (declare #'(a-mat a-mat &out c-mat a-mat)
           (global-size :set-to 16) (local-size :set-to 16))
  (let ((D (make-register-tile (accum q-a) (16 16) 0)))
    (mma-accumulate-via-tile (8 16 32) D A B)
    (store-tile D C (0 0))
    (mem-fence)
    (dotimes (row 16)
      (dotimes (col 16)
        (set! (~ N row col) (to-q-a (~ C row col) 0.5))))))
```

`(to-half D)` on a store's source is refused on SPIR-V for the same reason.

A shape and element combination the hardware does not have is a compile-time error at the MMA form. The
compiler will NOT silently generate a slow emulation path. This is a core design choice: it is better to
give you a compile-time error than to let you ship a kernel that is 100x slower than you intended. So
`(def-qint q :base short :accum long)` is legal, and it only fails if that type reaches an MMA form.

| Case | The message says |
|---|---|
| An integer operand with a float accumulator, or the reverse | integer and float do not mix |
| A signed operand with an unsigned accumulator | must be signed |
| An integer register tile on NVIDIA (`mma.sync`) | has no NVIDIA lowering; use `wgmma` |
| `wgmma` int8 with K other than 32 per slice | K must be 32 |
| XMX int8 at a non-int8 K | operands need K=32 |
| A hardware profile with no int8 shape | is not one of the active hardware |
| `store-tile-at (to-q D m) .. :via :tma` | the TMA store path moves 16-bit elements |

> Implementation note: synchronous `mma.sync` int8 assembles, but each shape needs its own per-lane
> register layout, which can only be proven on metal, while `wgmma` reads shared memory. So there is no
> integer MMA below Hopper (for example, on Ada) yet.

