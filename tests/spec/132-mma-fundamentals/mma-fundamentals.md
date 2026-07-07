In this endeavor we are tackling the MMA fundamentals as outlined in .\docs\topology.md.

These are the basic building blocks that all the "Story in Three Chapters" share.

- make-register-tile
- mma-accumulate-via-tile
- load-fragment
- mma-accumulate
- inner-dimension / outer-dimension
- :mma-shapes from the hardware profile.

We start with a **synchronous** tiled matmul — call it "Chapter 0", the correctness
baseline that comes *before* the doc's three-chapter optimization arc (async →
pipelined → warp-specialized). Doing it synchronously isolates the one genuinely new,
risky thing (the MMA math path) from async-barrier timing: the sync `load-tile` /
`store-tile` are already shipped (endeavor 111), so Chapter 1 later becomes a readable
diff (`load-tile … :barrier b` + `await`) on known-correct math. `matrix-multiply-tile-stride`
is a stretch goal, most likely deferred.


Design Decisions
----------------

### Two-level model: fragment vs tile

Two distinct constructs (the doc already implies this: `make-register-fragment` at line
635 is separate from `make-register-tile`):

- **`register-fragment`** — one MMA operand/accumulator, *lane*-distributed across a
  single warp, with the ISA-fixed element→lane mapping. Shape-carrying.
- **`register-tile`** — the *workgroup*-collective logical tile (e.g. 64×64), which is a
  grid of accumulator fragments spread across the warps.

A tile is *composed of* fragments. This resolves "when is the MMA shape known?": the
**tile** is shape-agnostic logical storage; the **fragment** carries the ISA shape,
imposed when `mma-accumulate-via-tile` materializes fragments. So `make-register-tile`
does not need the shape at construction.

### `register-fragment` is a `def-record` (not a new primitive)

A fragment is *a collection of registers, non-contiguous* — the exact definition of a
record (structs are contiguous memory; records are just registers). At the IR level a
fragment is a few per-thread registers (accumulator = 4× `float`/lane; `ldmatrix.sync.x4`
/ `.x2` = 4 / 2 registers). The warp-collective meaning lives in the `ldmatrix` / `mma.sync`
intrinsics, NOT the data — so the storage is a plain thread-local record, and the ops
impose the collective interpretation.

Fragments are **auto-minted per `(shape, role, dtype)`** the way tensor/matrix records are
minted per type-args, carrying MMA c-t metadata: shape portion, role (`:a` / `:b` /
`:accumulator`), element-type, layout. Reuses record mangling, kernel-boundary handling,
and (later) the per-field grad-cell AD path.

`register-tile` composes: per-thread it's a record/array of *(fragments-per-warp)*
accumulator fragments; codegen maps fragments→warps by warp-id. The register fit-check is
then just "count the record's registers."

### Distribution & the fit check

The workgroup tile distributes across warps, then within a warp across lanes. Warp count =
`local-size ÷ simd-width`. The fit check is
`fragments_per_warp × regs_per_fragment ≤ :max-registers-per-thread`. This is exactly what
today's hardware-profile `:simd-width` + `:max-registers-per-thread` make computable.

### SIMD width source — hardware profile stays OPTIONAL

`make-register-tile` needs a known SIMD width to distribute. Sources, in order:
active hardware profile's `:simd-width` → `--ir-target-arch` implied → `--ir-target`
default (32 for `sm_*`). If NONE pins the SIMD width, `make-register-tile` is a compile
error. The profile itself remains optional; this is just one of the few forms that
require the SIMD width to be knowable somehow. (topology.md updated to state this on the
relevant forms.)

### `grid-k` is a tile INDEX

`load-tile`'s contract takes tile IDs, so the K-loop walks tile indices (0,1,2,…), not
element offsets: `(load-tile A A-tile (grid-y grid-k))` = "the grid-k-th K-chunk of A."
Chapter 0 computes the trip count explicitly — `num-k-tiles = (inner-dimension A B) ÷
tile-K-width`, deriving tile-K from the scratch tile's own extent so it can't drift from
the SLM tile size — and does NOT introduce a macro yet. Folding the grid-y/grid-x/grid-k
bookkeeping into a macro is precisely the deferred `matrix-multiply-tile-stride`.
Precondition `K % tile-K == 0`; K is runtime so guard the remainder under
`--runtime-checks` rather than pretend a compile-time check.

### Layout: `:contiguous-term` selects the intrinsic; swizzle deferred

- **Logical layout (row/col-major)** = `:contiguous-term`, a **compile-time check**. The
  operands' `:contiguous-term` selects the MMA hardware variant (`…row.col` = A row-major,
  B col-major, the canonical NVIDIA form); a layout the chosen instruction can't accept is
  a compile error. (`:transpose` on the tile load reconciles, once supported.)
- **Precision** — the `(M N K)` triple encodes operand precision (K varies by dtype:
  k16=fp16, k8=tf32, …). The `:mma-shapes` membership check verifies the operand element
  type matches the shape's precision class, also compile-time.
- **Physical SLM swizzle (bank-conflict avoidance)** — NOT required for correctness. Naive
  un-swizzled row/col-major SLM staging feeds `ldmatrix` correctly, just with conflicts.
  Swizzle is a later *performance* item (a `performance/` regression microbench), NOT in
  the Chapter 0 correctness path.

Correctness needs: `:contiguous-term` check + SLM scratch alignment/leading-dimension check
(`ldmatrix` wants contiguous, aligned rows; `make-scratch-matrix … :compact` should give
that) + precision match.

### `load-fragment` / `mma-accumulate` are user-facing

First-class, independently testable primitives (so we can unit-test a single fragment load
and a single accumulate in isolation, and an intrepid user can roll their own). This makes
`register-fragment` a first-class record type with real signatures. `mma-accumulate-via-tile`
is the sugar that composes them.


Sketches
--------

### Sketch A — "hello MMA" (one warp, one `mma.sync`), the true first-correctness test

`C[16×8] = A[16×16] · B[16×8]`, single warp, no outer tiling — the whole matrix is one tile.

```lisp
(def-type a-mat (matrix float :address-space :global :align :compact :contiguous-term :row-major))
(def-type b-mat (matrix float :address-space :global :align :compact :contiguous-term :col-major))
(def-type c-mat (matrix float :address-space :global :align :compact :contiguous-term :row-major))

(def-kernel hello_mma (A B &out C)
  (declare #'(a-mat b-mat &out c-mat)
           (local-size :set-to 32))                  ; exactly one warp — MMA is warp-collective
  (let ((A-tile (make-scratch-matrix A (16 16)))     ; SLM staging (ldmatrix reads from shared)
        (B-tile (make-scratch-matrix B (16 8)))      ; SLM
        (C-tile (make-register-tile float (16 8) 0.0))) ; accumulator, in registers
    (load-tile A A-tile (0 0))                        ; SYNCHRONOUS — no :barrier
    (load-tile B B-tile (0 0))
    (sync-workgroup)
    (mma-accumulate-via-tile (16 8 16) C-tile A-tile B-tile (acc)
      (accum-op))                                     ; fires exactly one mma
    (store-tile C-tile C (0 0))))
```

New-construct surface: `make-register-tile`, `mma-accumulate-via-tile` (+ `load-fragment` /
`mma-accumulate` internals), `:mma-shapes` check. Everything else is already shipped.

### Sketch B — Chapter 0 (synchronous tiled, the endeavor target)

Same as the doc's Chapter 1 minus async; tile shrunk from 128² (register pressure); loops
hand-rolled (`matrix-multiply-tile-stride` deferred).

```lisp
(with-template-type (T)
  (def-type mat-a (matrix T :address-space :global :align :compact :contiguous-term :row-major))
  (def-type mat-b (matrix T :address-space :global :align :compact :contiguous-term :col-major))
  (def-type mat-c (matrix T :address-space :global :align :compact :contiguous-term :row-major))

  (def-grid-function tiled_matmul (A B &out C)
    (declare #'((mat-a T) (mat-b T) (mat-c T))
             (global-size :derive-from C :strategy :strided))
    (let ((A-tile (make-scratch-matrix A (64 16)))          ; SLM: TM×TK
          (B-tile (make-scratch-matrix B (16 64)))          ; SLM: TK×TN
          (C-tile (make-register-tile T (64 64) (identity T)))) ; registers: TM×TN
      (tile-stride C C-tile (grid-y grid-x)                 ; each workgroup owns one C tile
        (do-times (grid-k (num-k-tiles A B A-tile))         ; grid-k = tile index
          (load-tile A A-tile (grid-y grid-k))              ; SYNCHRONOUS
          (load-tile B B-tile (grid-k grid-x))
          (sync-workgroup)
          (mma-accumulate-via-tile (16 8 16) C-tile A-tile B-tile (acc)
            (accum-op))                                     ; walks 64×64 in 16×8×16 steps
          (sync-workgroup))                                 ; safe to overwrite SLM
        (store-tile C-tile C (grid-y grid-x))))))
```

Chapter 1 later = swap the first `sync-workgroup` for `:barrier b` + `(await b)`.


Phases (bottom-up)
------------------

[x] P1 — `register-fragment` record type + `make-register-fragment` + `store-fragment`.
    DONE 2026-07-04. Round-trips a uniform 16x8 fp32 accumulator to a global matrix.
    - `src/mma.lisp` (new; in .asd after `templates`). The record type is registered
      PROGRAMMATICALLY via `register-struct-definition` (the `def-record` macro emits
      accessor def-functions that compile immediately — fatal in a build-loaded src file
      with no compiler session). System type: no Crisp accessors; codegen uses
      `%construct-struct` / `%extract-struct-member`.
    - Both forms are pure REWRITES to existing machinery (no new codegen):
      `make-register-fragment` -> `%construct-struct` (init splatted across r0..r3);
      `store-fragment` -> per-lane `(set! (~ dest row col) (%extract-struct-member frag i))`
      using the real m16n8 accumulator layout (g=lane/4, t=lane%4 ->
      (g,2t)(g,2t+1)(g+8,2t)(g+8,2t+1), offset by tile origin). `warp-lane` -> `to-int`
      (it's UINT; matrix indices are INT). Verified PTX: `%laneid`, `shr .. 2` for /4,
      4x `st.global.b32 ..,0x40E00000` (7.0).
    - CLOBBER-FIX (the non-obvious part): `initialize-compiler` clrhash-es both
      `*expression-analyzers*` and `*crisp-structs*` on every init, so load-time
      registration does NOT survive. Register inside the init flow instead:
      `register-mma-analyzers` (from `initialize-expression-analyzers`) and
      `register-mma-types` (from `initialize-compiler`, after `register-builtins`).
    - STILL HARDCODED (deferred): single 16x8/fp32/warp-32/4-reg shape; SIMD-width
      sourcing + register fit-check + c-t MMA metadata all await generalization.
    - Suite: E2E 846/846 both ways, unit 253/253, neg 191/191.

[x] P2 — `load-fragment-a/b` + `mma-accumulate`.  DONE 2026-07-05.  Precision = tf32
    (m16n8k8), so everything stays fp32-stored.  Spec `02-hello-mma`.
    - Fragment types (programmatic, like P1): `register-fragment-a-tf32-16x8` (4 regs),
      `register-fragment-b-tf32-8x8` (2 regs); accumulator reused from P1.
    - `load-fragment-a/b` are REWRITES (per-lane reads at the m16n8k8 operand layouts;
      A: (g,tg)(g+8,tg)(g,tg+4)(g+8,tg+4); B: (tg,g)(tg+4,g)) — NOT ldmatrix (later perf).
      Read straight from global for now (SLM staging is P4).
    - `mma-accumulate` is the ONE genuine-codegen piece: a `semantic-mma-accumulate`
      node (defstruct in src/semantic.lisp so core.lisp's node etypecases see it) +
      `generate-node-ir` that extractvalues A(4)/B(2)/C(4) fields, bitcasts A/B float→i32
      (tf32 passed as i32), declares+calls `@llvm.nvvm.mma.m16n8k8.row.col.tf32`
      ({f32x4}(i32x6,f32x4)), and insertvalues the 4 results into a new accumulator.
      Wired into the 3 core.lisp node etypecases (type / source-location /
      uniformity=:divergent).
    - store-fragment now binds FRAG to a temp first so an inline mma-accumulate is
      evaluated ONCE (verified: exactly one mma.sync in the PTX).
    - Verified PTX: `mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32` (one instr).
    - 02 is PTX-only (the NVVM intrinsic has no GENERIC lowering) -> SKIP-DEFAULT-PASS
      (re-introduced) + SKIP-WITH[--debug] (bug 033).  On-metal (RTX) verification of a
      known product = the remaining P2 follow-up.
    - Suite: unit 253, E2E 847/847 (in-process + binary non-debug), diff 847/847, neg
      191/191.  (056/07 fails only under Windows binary+debug = bug 033, unrelated.)

[x] P3 (core) — `make-register-tile` + `store-tile` overload + `mma-accumulate-via-tile`
    (bodyless) + `:mma-shapes` check.  DONE 2026-07-05.  Decision (with user): tiles are
    RECORD-OF-FRAGMENTS, single-warp-first.
    - P3a: `make-register-tile T (M N) init` mints a record whose fields are (M/16)x(N/8)
      `register-fragment-acc-f32-16x8` fragments (on-demand per (M N); dims tracked in
      `*register-tile-dims*`).  `store-tile` is OVERLOADED (analyze-store-tile-mma): a
      register-tile src → per-fragment store-fragment at (row-tile,col-tile); anything
      else delegates to the existing SLM store-tile.  Spec 03 (16x16 uniform round-trip,
      8 st.global).
    - P3b-1: `mma-accumulate-via-tile (M N K) C-tile A B` — bodyless.  Rewrites to a
      per-fragment-position unrolled `set! C-tile` of `mma-accumulate(C.frag,
      load-fragment-a(mi,0), load-fragment-b(0,nj))` (ONE K-step, K = shape's K).
      `%check-mma-shape`: (M N K) int triple + supported (tf32 (16 8 8) only for now) +
      active-profile `:mma-shapes` membership (consumes the endeavor-130 key).  Specs
      04 (1-frag→1 mma.sync), 05 (16x16→2 mma.sync), errors/01 (bad shape → CHECK-FAIL).
    - Suite: E2E 850/850 both ways, neg 192/192.
    DEFERRED within P3: the register FIT-CHECK (simd-width × max-registers-per-thread);
    `inner-dimension`/`outer-dimensions` (for the runtime K-loop — arrives with K-tiling);
    P3b-2 = the body + `accum-op`/`accum` epilogue-fusion API (bodyless covers the core).

[x] P4 (kernel) — synchronous tiled matmul COMPILES.  DONE 2026-07-05.  Spec 06.
    - Decision (with user): K-tile = MMA-K (8), so the K-loop is EXTERNAL (a runtime
      dotimes) and mma-accumulate-via-tile stays one-K-step (P3b-1 unchanged).
      Accumulation across K-tiles is automatic (mma = A·B + C; the macro set!s the tile).
    - `inner-dimension A B` -> K (rewrite to (~ (extents~ A) 1)); wrap in to-int for the
      loop math (extents are ulong).  SLM staging via the existing sync `load-tile-coords`
      (element coords) into `make-scratch-matrix float (M 8)` / `(8 N)` tiles;
      `sync-workgroup` around the MMA; `store-tile` writes the register C-tile out.
    - Kernel (single-warp, one 16x8 C-tile): stage A[:,kt*8:+8] / B[kt*8:+8,:] per
      K-step, mma-accumulate-via-tile, loop.  Verified PTX: mma.sync in the K-loop +
      st.shared (staging) + ld.shared (fragment reads).  Suite 852/852 both ways, 192 neg.
    REMAINING P4: on-metal (RTX) correctness of a known A·B product; `benchmarks/matmul/`
    vs a hand-CUDA synchronous shared-memory tiled reference; grid-stride over C
    (multi-tile) — single-workgroup for now.  `make-scratch-matrix float (M N)` accepts a
    2-list dim (non-square), good to know.

Remaining fundamentals (post-P4, 2026-07-06)
--------------------------------------------
Register RESIDENCY + an in-process optimizer landed 2026-07-06: `make-register-tile`
accumulators now explode into N per-fragment mutable vars (register-resident; were a
monolithic aggregate that SROA couldn't scalarize, dropped to `.local`), and the compile
pipeline runs `default<O3>` via `LLVMRunPasses` in-process (no `opt` binary).  The register
budget is now REAL — so the fit-check is timely.

[x] F1 — register FIT-CHECK.  DONE 2026-07-06.  Compile-time: (M/16)×(N/8) accumulator
    fragments × 4 fp32 regs ≤ budget, where budget = active profile's :max-registers-per-thread
    else `*default-max-registers-per-thread*` (255, NVIDIA max).  Lives in
    `%register-tile-fit-check`, called from `%explode-register-tiles` (the residency-fix path
    that replaces make-register-tile before analyze-make-register-tile runs).  Over-budget →
    `crisp-compiler-error` "…register budget…".  Specs: errors/02-tile-over-budget (128×128 =
    512 regs > 255, default budget) + 07-fit-check-profile (64×64 = 128 regs, fits default 255
    but COMPILE-WITH[--hardware-profile=small-regs (100)] FAILs).  Single-warp for now
    (fragments/warp = total); accumulator-only (transient A/B + addressing are the headroom).
    Suite: 854/854 both ways, 193 neg, 253 unit.
[ ] F2 — outer-dimension(s).  Companion to `inner-dimension` (done → K): the M / N
    (non-contracted) extents.  Small rewrite to `(~ (extents~ …) …)`.
[ ] F3 — accum-op / body API (P3b-2).  Epilogue-fusion body for `mma-accumulate-via-tile`:
    `(mma-accumulate-via-tile (M N K) C A B (acc) (accum-op …))` fuses a per-tile epilogue
    (scale / bias / activation) over the accumulator fragments; bodyless stays the default.

Then endeavor 133 = Intel/SPV/DPAS port (its own effort: sub-group 16 not 32, systolic 8×N
shapes, `joint_matrix` / `intel_sub_group_matrix_mad` instead of `mma.sync`).

Deferred:
- `matrix-multiply-tile-stride` (the grid-y/grid-x/grid-k convenience macro).
- SLM swizzle / bank-conflict removal → `performance/` regression microbench.
- Async tile loads (Chapter 1), pipelining/rings (Chapter 2), warp specialization (Ch 3).
- Autodiff of matmul — `SKIP-WITH[--differentiate]` throughout; a differentiable
  tensor-core GEMM is its own research problem and must not gate the first forward win
  (recall 111's AD-on-metal blocker on local-scratch vector binding).


Testing notes
-------------

- Forward-only for now: `SKIP-WITH[--differentiate]` on every spec.
- On-metal: PTX / RTX for the MMA path (SPV/Intel DPAS is a later target).
- Verify MANUALLY (per CLAUDE.md): check the emitted NVVM intrinsic + `ldmatrix` in the
  PTX, not just a passing validator.
- ci-stop: `132-mma-fundamentals`.
