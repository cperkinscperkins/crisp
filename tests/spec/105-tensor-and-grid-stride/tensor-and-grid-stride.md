In 093 we added loop-vector-stride to Crisp. It's quite the workhorse, but is fairly straightforward
as it only deals with one dimensional vectors.

Now we are going to beging to tackle the other "stride" macros.  They are outlined in
docs\chapters\14_control_flow\11_general_purpose_tensor_stride_grid_stride_tile_stride_and_hardware_stride.md

We will start with tensor-stride and grid-stride.  The tile-stride and hardware-stride will be done
in a later effort, not this endeavor.

The tests for loop-vector-stride (both positive and negative) all seem like they
could be reproduced here for tensor and grid, but we'll likely want different arities covered
for the postiive tests.

Notes from initial discussion (2026-05-16)
------------------------------------------
- Crisp does NOT allow incomplete types at the KERNEL boundary.  Kernel params always
  have fully-resolved tensor types (known :contiguous-term, :align, etc.).  The
  "unknown CT" path matters only for sub-functions, which use tensor polymorphism.
- `:align` is handled inside the existing tensor AREF codegen, not at the stride
  macro layer.  tensor-stride only needs to emit the iteration order; the body's
  `(~ T i0 i1 ...)` accesses go through AREF, which already knows how to handle
  `:compact`, `:compact-offset`, and `:strided` layouts.
- Confirmed helpers exist already from earlier endeavors: `length~ T`, `extents~ T i`
  (per-dim extent — verify exact name), `contiguous-term~ T`.  No new accessors expected.
- `(declare (grid-level))` dispatch-context enforcement already in place from 093.

Test plan
=========

Positive tests (`tests/spec/105-tensor-and-grid-stride/`)
---------------------------------------------------------

**tensor-stride — safe variant** (no layout tag; iteration order chosen from CT)
| # | File | Coverage |
|---|---|---|
| 01 | `01-basic-1d.crisp` | tensor-stride on a 1D vector; trivial copy |
| 02 | `02-basic-2d.crisp` | matrix fill |
| 03 | `03-basic-3d.crisp` | 3D tensor fill |
| 04 | `04-subfunc-unknown-ct.crisp` | sub-function takes a polymorphic tensor (CT unknown to the callee); kernel calls it.  Verifies the runtime-decode path. |
| 05 | `05-mat-add.crisp` | 2D actual computation |
| 06 | `06-fill-hoist.crisp` | L0 hoist (mirrors 093/03) |

**tensor-stride — strict variant** (with layout tag)
| # | File | Coverage |
|---|---|---|
| 07 | `07-strict-row-major.crisp` | 2D, `:row-major` |
| 08 | `08-strict-col-major.crisp` | 2D, `:col-major` |
| 09 | `09-strict-contiguous-last.crisp` | 3D, `:contiguous-last` |
| 10 | `10-strict-contiguous-first.crisp` | 3D, `:contiguous-first` |
| 11 | `11-strict-matches-ct.crisp` | strict tag matches a known static CT (compile clean, optimized path) |

**Differentiable**
| # | File | Coverage |
|---|---|---|
| 12 | `12-diff-tensor-mul.crisp` | tensor-stride inside `--differentiate` kernel; tagged with `VERIFY-AUTODIFF` |

**grid-stride**
| # | File | Coverage |
|---|---|---|
| 13 | `13-grid-1d.crisp` | bare 1D grid-stride writing to a passed cell-of-int |
| 14 | `14-grid-2d.crisp` | 2D |
| 15 | `15-grid-3d.crisp` | 3D |
| 16 | `16-grid-into-tensor.crisp` | grid-stride iterating a virtual grid and writing into a real tensor |

Negative tests (`tests/spec/105-tensor-and-grid-stride/errors/`)
----------------------------------------------------------------
| # | File | Coverage |
|---|---|---|
| 01 | `01-not-in-grid-context.crisp` | tensor-stride outside a dispatch context — relies on existing `(declare (grid-level))` enforcement |
| 02 | `02-nested.crisp` | tensor-stride nested inside loop-vector-stride or another tensor-stride |
| 03 | `03-arity-mismatch.crisp` | bindings count ≠ tensor rank |
| 04 | `04-strict-contradicts-ct.crisp` | strict `:row-major` on a tensor whose static CT is `:col-major` |
| 05 | `05-grid-arity-mismatch.crisp` | `(grid-stride (N M) (i))` — size-list and bindings differ |
| 06 | `06-grid-empty-size-list.crisp` | `(grid-stride () (i))` — zero-arity |

Total: 16 positive + 6 negative.

Implementation plan
===================

Mirrors 093: analyzer-time macro expansion in `src/analysis/control.lisp`, added via
the compiler overlay until ready to land in source.  No new IR; expansion produces
forms that go through the existing dotimes / when / let / get-global-id / aref codegen.

Phase A — `tensor-stride` safe variant
--------------------------------------

For tensor `T` of rank `N`, expand to a single linear `dotimes` over total length,
then decode multi-D index from linear flat using `extents~`:

```
(let ((gid   (get-global-id 0))
      (gsize (get-global-work-size 0))
      (len   (length~ T)))
  (declare (grid-level))
  (dotimes (k len gsize)
    (let ((flat (+ k gid)))
      (when (< flat len)
        (let* ((i0 ...)   ; decode from flat per CT direction
               (i1 ...)
               ...)
          BODY...)))))
```

Decode-direction rules:
- CT `:last` (warp varies last binding): innermost decode unwinds from the last
  binding outward.  flat % extent[N-1] → i[N-1], then flat /= extent[N-1], etc.
- CT `:first` (warp varies first binding): symmetric — unwind from binding 0 outward.

For sub-function callees that take a tensor with unknown static CT, the decode
formula uses `contiguous-term~ T` at runtime to pick the order.  `:align` is
irrelevant at this layer — it surfaces inside `(~ T i0 i1 ...)` via the existing
AREF codegen.

Tests landed: 01, 02, 03, 04, 05, 06.

Phase B — `tensor-stride` strict variant
----------------------------------------

Same skeleton, 4-arg form `(tensor-stride T <layout-tag> (bindings) body)`:
- Query the tensor's static CT at analysis time.  If known and disagrees with the
  tag, raise a compiler error.
- Emit the iteration order dictated by `<layout-tag>` directly — no runtime branch
  needed.
- `:row-major` and `:contiguous-last` produce the same iteration; difference is
  binding-name convention and which static check fires.

Tests landed: 07, 08, 09, 10, 11.  Also negative test 04.

Phase C — `grid-stride`
-----------------------

Smaller: no tensor, no CT, no extents query.  Just a size-list of N integer
expressions.  Total iteration count is the product.  Always row-major mapping
(rightmost binding gets warp).

```
(let ((gid   (get-global-id 0))
      (gsize (get-global-work-size 0))
      (e0 <size-0>) (e1 <size-1>) ...
      (len   (* e0 e1 ...)))
  (declare (grid-level))
  (dotimes (k len gsize)
    (let ((flat (+ k gid)))
      (when (< flat len)
        (let* ((iN ...) ... (i0 ...))
          BODY...)))))
```

Tests landed: 13, 14, 15, 16.  Also negative tests 05, 06.

Phase D — AD compatibility
--------------------------

Verify AD machinery handles tensor-stride / grid-stride bodies.  Since the expansion
produces standard dotimes + when + let, and 093's expansion does the same and works
under AD, this should be free.  Test 12 is the proof.

Phase E — Hoist (L0)
--------------------

L0 hoist should work automatically because the expansion uses already-hoistable
forms.  Test 06 is the proof.

Suggested order of work
=======================

1. Draft the analyzer for safe tensor-stride (Phase A).  Get 01, 02, 05 passing.
2. Add 3D (03).  Verify decode generalizes.
3. Sub-function unknown-CT (04).  Verify runtime-decode path.
4. Add strict variant (Phase B).  Get 07–11 passing.
5. Add grid-stride (Phase C).  13–16.
6. AD test (12).  Hoist test (06).
7. Negative tests last, after positive paths are stable.

Open items to confirm during implementation
===========================================
- Confirm helper names: `length~`, `extents~` (or `extent~`?), `contiguous-term~`.
  If any is missing, plan to add.
- Confirm the existing `(declare (grid-level))` enforcement fires on tensor-stride
  outside a dispatch context.  Expect yes; if not, small fix.
- Confirm AD machinery treats the expansion's `dotimes` body as differentiable
  identically to 093.  Expect yes; test 12 verifies.

Status (2026-05-17)
===================
Phases A, B, C, E landed.  Phase D and Phase A sub-function test deferred.

What landed:
  - Phase A (safe tensor-stride): tests 01, 02, 03, 05 pass.  Analyzer in
    overlays/crisp-compiler-overlay.lisp.  Uses `length~` + `extents~` and
    integer-division decode (no `mod` op needed).
  - Phase B (strict variant): tests 07, 08, 09, 10, 11 pass.  Tag → CT
    mapping via `%ts-layout-tag-to-ct`; agreement check against the tensor's
    static CT.  Static CT extracted via `unmangle-template-struct-name`
    (helper `%ts-canonicalize-tensor-type`).
  - Phase C (grid-stride): tests 13, 14, 15, 16 pass.  Separate analyzer
    `analyze-grid-stride-expression`; reuses %ts-build-{stride,decode}-bindings
    with hard-coded CT=:last.
  - Phase E (hoist): test 06 passes on metal (Intel Arc B580 via L0).
    `BUFFER out: 0 1 2 3` confirmed.
  - Negative tests (errors/01-06): 6 tests covering grid-context, nesting,
    arity mismatch, strict-vs-CT disagreement, grid arity, empty size-list.
    All PASS.

What deferred:
  - Phase D (AD test 12).  Crisp's AD backward walker
    (%handle-single-value-backward in src/autodiff.lisp) has no case for
    `dotimes`, `if`/`when` inside a kernel body, or `set!` to a cell.
    Trying to differentiate a tensor-stride kernel raises "Function
    DOTIMES / WHEN / SET! is not differentiable."  AD-of-loops would let
    the chain rule flow through every iteration of tensor-stride — that's
    a substantial AD extension and lives outside this endeavor.  Test 12 is
    left as `forward-only` with a note for the future.
  - Phase A test 04 (sub-function unknown-CT).  Template instantiation
    resolves CT before the analyzer runs, so the "runtime-decode" path is
    defensive-only — it never triggers in practice.  Skipped pending a
    concrete need.

Test suite (post-105):
  - Positive E2E: 665/665 PASS (added 15 from this endeavor).
  - Negative: 162/162 PASS (added 6 from this endeavor).
  - One on-metal hoist L0 test (06) passes.
