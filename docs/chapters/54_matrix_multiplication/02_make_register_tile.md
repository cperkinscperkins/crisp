# `make-register-tile` ✅

```
(make-register-tile <elem> (<M> <N>) <initial-value> &key operand warps)

(make-register-tile float (16 16) 0.0)                             ; a 16x16 accumulator
(make-register-tile float (16 8)  0.0 :operand :a)                 ; a register-resident A operand
(make-register-tile float (64 64) 0.0 :warps '(false true true))   ; warp-specialized: 2 consumers
```

A register tile is a tensor whose storage is the register file.  It is the fastest tile Crisp has and
the scarcest — registers spent here come straight off occupancy — so the usual arrangement keeps the
heavily-written `C` accumulator in registers and leaves the operands in `:local` scratch, with
`:operand` available when an operand is worth promoting too.

`(<M> <N>)` must be compile-time integers, and **multiples of the fragment shape** for the element
type and operand.  A tile smaller than one fragment holds nothing at all — every `store-tile` /
`fill-tile` / `mma-accumulate-via-tile` over it would expand to no code — so it is refused rather
than compiled into an empty kernel.

A register tile is **warp-collective**, not thread-local: the logical tile is distributed across the
warps of the workgroup and, within each warp, across its lanes.  Warp size comes from the active
hardware profile's `:simd-width`, and defaults to 32.

On NVIDIA the tile is checked against the register file at compile time — fragments × 4 registers
against the profile's `:max-registers-per-thread` (255 by default) — so a 128×128 accumulator is
refused as 512 registers/thread rather than left to spill silently.  On SPIR-V that check is not made
here: register residency of a cooperative matrix belongs to the driver, and the profile's GRF model
accounts for it separately.

#### `:operand` — which matrix this tile holds

`:a`, `:b` or `:acc` (default `:acc`).  The MMA shape gives each operand its own fragment geometry —
A is `M×K`, B is `K×N`, the accumulator `M×N` — and `:operand` picks which one, so an operand tile's
fragments match what `load-fragment-a` / `load-fragment-b` produce.  `(<M> <N>)` must tile evenly
into that shape.

It also changes how a `:warps` mask distributes the tile.  An accumulator splits by the *number* of
participating warps; an **operand** splits by the warp-grid axis its warps share — rows for `:a`,
columns for `:b` — because warps in one grid row all read the same rows of A.

#### `:warps` — the warp participation mask (for warp specialization)

By default the tile distributes across **every** warp of the workgroup.  That is wrong under
**warp specialization**: if only the *consumer* warps run the MMA, any fragment the compiler placed
on a producer warp would never be computed — a wrong result.  `:warps` says exactly which warps hold
the tile, as a flat boolean map, positional over the workgroup's warps:

```
(make-register-tile float (64 64) 0.0 :warps '(false true true))
;; warp 0 holds no fragment; warps 1 and 2 split the tile.  Pairs with a
;; (with-warp-specialization (:producer 1 :consumer 2) ...) whose producer is warp 0.
```

- **Elements** are `true` / `false` (or, equivalently, `1` / `0`).  The mask is positional rather
  than by role name — the tile is declared in the outer `let`, outside any role block — so lining
  the `true`s up with the warps that actually run the MMA is yours to get right.  The compiler
  checks shape, not intent.
- **Length** must equal the workgroup's warp count (`local-size / warp-size`).  When `local-size` is
  statically known a mismatch is a **compile-time** error; otherwise it defers to an
  `--runtime-checks` assertion.
- **At least one** warp must be `true`, and the participating warps must be **contiguous** — a
  non-contiguous mask is not yet supported.
- **Even division.**  A tile is a grid of `(M / frag-M) × (N / frag-N)` fragments — a 64×64
  accumulator over a 16×8 fragment is `4×8 = 32`.  The number of participating warps must divide
  that count evenly, so 32 fragments admit 1 / 2 / 4 / 8 / 16 / 32 warps — **not 3**.
- **Occupancy lever.**  More participating warps ⇒ fewer fragments each ⇒ fewer registers per
  thread ⇒ higher occupancy.  The consumer count is the real lever against the single-warp register
  wall, and is worth sweeping.

