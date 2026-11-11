# Endeavour 211 — shift-left / shift-right / rotate-left / rotate-right

Branch `resume-gpumode`, 2026-11-10.  Part A of `plan/proposal-warp-ballot-and-shifts.md`.

## Why

`(ash x n)` is defined for every count: either sign, any size.  With a run-time `n` it lowers to a
branch-free select chain of about ten instructions (`%185-ash-body`).  The sort_v2 radix sort rotates every key
by the pass's digit shift.  A probe with that shift as a literal (diagp_rotk.py, H100, 2026-11-10) gave:
- SASS of the downsweep: -15% (3056 -> 2608);
- downsweep time: -12% (783 -> ~690 us per pass at 100M);
- wall time of the sort: -8%.

## Decisions (Chris, 2026-11-10)

- **Names:** `shift-left`, `shift-right`, `rotate-left`, `rotate-right`.  `ash` keeps its Common Lisp meaning.
- **Count semantics:** the count is taken MODULO THE WIDTH (OpenCL C's rule).  It is defined on every target, at
  the cost of at most one `and`.  A negative count wraps as well, so `(shift-left x -1)` shifts left by 31; it is
  not a right shift.
- **shift-right:** logical for an unsigned operand, arithmetic for a signed one.
- (Part B, for later: `warp-ballot` returns `uint`; a warp size over 32 is an error until such a target exists.)

## Implementation (overlay, to fold)

- **Analysis:** `analyze-211-shift-op` (src/analysis/ops.lisp), registered from
  `%185-register-math-op-analyzers` (whole-function overlay copy).  The first operand must be a scalar integer
  and fixes the result type.  The count may be any integer type.
- **Lowering:** `%hw-lower` methods `%211-shift-left` / `-shift-right` / `-rotate-left` / `-rotate-right` ->
  `%211-lower` -> `%185-helper-call` (`__crisp_<op>_<type>`, noinline on SPIR-V only) -> `%211-shift-rotate-body`.
  - Shifts: `and (bits-1)`, then `shl` / `lshr` / `ashr`.
  - Rotates: `llvm.fshl` / `llvm.fshr (x, x, n)`.  Their count is already taken modulo the width.
- **AD:** the four names join the integer-operator list in `%185-math-backward` (whole-function overlay copy,
  script-extracted).

## Specs

| spec | what it checks |
|---|---|
| 01-shift-32-metal | uint / int shifts with run-time counts: in range, == width, > width, negative (BMG) |
| 02-rotate-32-metal | uint / int rotates, a round trip, a negative count (BMG) |
| 03-shift-rotate-64-metal | ulong / long, counts mod 64, an int count on a 64-bit operand (BMG) |
| 04-lowering-ptx-spv-metal | PTX: `shf.l.wrap.b32` and `shf.r.wrap.b32`, no `selp.b32`, no helper call; SPIR-V: 4 helpers with DontInline; L0 metal (CUDA metal where nvcc exists) |
| 05-shift-rotate-diff | VERIFY-AUTODIFF: the four forms on the active path are zero-gradient operators; d/dx = 17 |
| errors/01-float-operand | "shift-left: operands must be integers" |
| errors/02-float-count | "rotate-right: the count must be an integer" |

## Log

- 2026-11-10: specs written first (red: "Unsupported form").  After the overlay, 7/7 pass.
  - **BMG metal:** all four metal specs show exactly the expected buffers.
  - **--differentiate:** analytical gradient 17.0.  The finite-difference check needed atol 1e-2, because out is
    about 42 and the float32 finite difference has error ~2e-3.
  - **Negative suite:** 499/499.
- 2026-11-10: the validators' regexes lost their backslashes to a bash heredoc (memory:
  bash-heredoc-collapses-backslashes), so `\b` read as `b` and both failed.  Fixed with Edit.
- PTX note: NVPTX keeps an `and.b32 n, 31` in front of `shf.*.wrap`.  It is redundant, because `.wrap` already
  takes the count mod 32.  Whether ptxas drops it gets checked in the sort's SASS.

## Payoff: sort_v2 v1j (contests/gpu-mode/07-sort-v2/sort_radix_v1j.crisp)

v1i with the run-time ash sites rewritten as shift-right / rotate-right / rotate-left (put_temp_files_here/
gpumode/sort/make_v1j.py).  BMG bit-exact.  SASS downsweep 3056 -> 2616 (the literal-shift probe: 2608),
registers 56 -> 40.  Same-machine A/B under eval.py's procedure (diagab_211.py, H100 submission 970439, 100M,
mean of 8):

| arm | us |
|---|---:|
| v1i | 4067 |
| **v1j** | **3692 (-9.2%)** |
| literal-shift probe | 3704 |
| torch.sort (CUB) | 5280 |

v1j beats the "ceiling" probe slightly because the upsweep's per-key digit shift is cheap now too.

## Suites (2026-11-10, overlay live)

unit 392/392 (0 failed); E2E 1828/1828; negative 499/499; --differentiate on 211: 7/7.  (The E2E process
hit an SBCL "Memory fault ... Foreign function" AFTER printing its summary -- at shutdown, exit 0.)
v1j folded into contests/gpu-mode/07-sort-v2/sort_radix.crisp; crisp_sort_v1.py's PTX is byte-identical
to the measured arm.
