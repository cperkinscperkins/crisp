# Endeavour 186 — contest-fixes

The fixes that came out of LeetGPU challenge 01 (vector add, AntiGravity's submissions, 2026-10-16/17):
BUG 059 (silent mis-typed element stores), BUG 125 (read-only loads lost through views), BUG 124 (register
spills invisible from Crisp).  Branch `contest-fixes`.

## BUG 059 — an element holds exactly its own type

**Found:** `set!` into a storage element (vector / matrix / tensor / cell) was never type-checked, and
codegen stored the value at its own width.  So a float into a `half` wrote 4 bytes into a 2-byte slot,
double→float wrote 8, float→double wrote 4, and int↔float swapped bit patterns.  It was all silent.  A
plain variable's `set!` was already strict.

**Done:**
- `%check-element-store-type` (`src/analysis/structs.lisp`, Sub-case 2b of `%analyze-set!-call-accessor`)
  refuses the mismatch with "convert it explicitly, e.g. (to-half x)".  The value is taken in
  single-value context; a brand (or brand instance) compares by its base type; a type that does not
  resolve is let through.
- `to-half` / `as-half` / `to-bfloat16` / `as-bfloat16` are exported and imported (they were always
  registered, never reachable from a kernel).
- `(to bfloat16 x)` on SPIR-V (bf16 carried as `i16`) is the round-to-nearest-even bit encoding, with NaN
  mapped to `0x7FC0` (`%f32-to-bf16-bits-rne`, `codegen.lisp`).
- `load-tile-at`'s identity (default `0`, an int) is converted to the tile's element type by the internal
  form `(%element-of-cast TILE VALUE)`, `src/analysis/control.lisp`, in both expansions.

**Fallout fixed in specs:** 11 specs stored mismatched values.  Their sources now say `7l`, `8ul`,
`(to long ..)` or `(to-double ..)`; 015's `kernel-proximate` drops a nonsensical `to-float`.  The 167
IR unit test's `store float 0.0` needle now names `addrspace(3)`, because the identity alloca's
initializer matched it.  052/19 and 052/21 exposed **BUG 126** (a float adjoint stored into a
`point`-typed grad cell) and carry `KNOWN-ISSUE[differentiate]: BUG-126`.

| Spec | Claim |
|---|---|
| 01-to-half-element-metal | `to-half` RNE bits on BMG, ties to even (`15360 15360 15360 15361`) |
| 02-to-bfloat16-element-metal | `to-bfloat16` RNE bits on BMG (`16256 16256 16256 16257`) |
| errors/01-03 | float→half, double→float, int→float element stores refused |

## BUG 125 — a view of a read-only input stays read-only

`%readonly-syms-after-binding` (`codegen.lisp`) updates the read-only set per `let` binding, scoped to the
body:
- a view (`make-vector` / `-matrix` / `-tensor` / `-cell`) or a plain alias of a read-only name joins it;
- the kernel-entry reassembly (`A` re-bound to the struct built from `A_PTR ...`) is the same tensor;
- any other binding of the name shadows it.

| Spec | Claim |
|---|---|
| 03-readonly-view-metal | the float4 add: the `a4` / `b4` loads (b4 is a view of a view) carry `!invariant.load`, the output `c4` does not; PTX operand loads are all `ld.global.nc.v4.b32`; `C = 0 2 4 6` on BMG |
| 04-readonly-name-shadowed | a `let` rebinding `A` to scratch: its SLM loads are unmarked, while `B`'s global load is still marked |

The IR claims are in `contest-fixes.unit.lisp`.  **Caveat, pre-existing:** "params before `&out` are
read-only" is assumed, not enforced; a write into an input compiles.

## BUG 124 — report registers and spills

The CUDA launcher (`emit-kernel-resource-report`, `src/hoist-cuda/main.lisp`) and both bench harnesses
query `cuFuncGetAttribute` `NUM_REGS` / `LOCAL_SIZE_BYTES` after loading the kernel.  They print or JSON
the numbers and warn when local bytes are non-zero.  These are the driver's numbers on the GPU in use, so
no `ptxas` is needed.  **Not run on a GPU yet** (no nvcc on the dev box).

## Status

- [x] BUG 059 + fallout; to-half / to-bfloat16 verified on BMG
- [x] BUG 125, IR + PTX checked by hand, unit-tested; on metal for correctness
- [x] BUG 124 option (b) emitted; generated launcher read by hand
- [ ] BUG 124 / 125 perf: one pod or LeetGPU run of the float4 kernel would show both (the `.nc` effect and
      the resource line)
- [ ] BUG 126 (AD of cell-of-struct) — open
