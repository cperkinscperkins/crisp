We've been working on various matrix multiplication things since endeavor 132-mma-fundamentals.

Many of these tests are marked
;; SKIP-WITH[--differentiate]: "some excuse"

but now it is the time to get MMA working with auto differentiation.

Crisp already has very good support for auto differentiation. It prioritized mathematically correct differentiation. For example it can apply A|D down through subfunctions,  and even supports A|D for integer data types. The test system has custom directives so A|D results can even be check on metal
e.g.
;; TEST-WITH[--ir-target=spv --differentiate]
;; VERIFY-AUTODIFF: A=[1.0 2.0 3.0 4.0] at.A=1 atol=5e-3 expect.A=2.0 output-vec=4


Orientation
-----------

### Where AD hooks in

`generate-backward-walk` (src/autodiff.lisp:838) is a **source-to-source** transform over
flat ANF, and it runs **before** semantic analysis. That matters: `%explode-register-tiles`
(src/mma.lisp:1245) is invoked from the **LET analyzer**, so the AD walk sees the
*unexploded* `(make-register-tile …)` / `(mma-accumulate-via-tile …)` forms — the whole-tile
variable is still intact.

So MMA autodiff is a source-rewrite problem at exactly the same altitude as the existing
`load-tile-at` → `%load-tile-at-bwd` rules (src/autodiff.lisp:991-1027). No new codegen is
required for the *rules* themselves; the backward emits ordinary Crisp MMA forms which then
go through the normal forward analysis/explosion path.

### Today's failure modes (measured, 2026-07-28)

| spec | dies on |
| --- | --- |
| `132/02-hello-mma` | `Function LOAD-FRAGMENT-B is not differentiable` |
| `132/06-tiled-matmul` | `Function INNER-DIMENSION is not differentiable` |

Both come from `%handle-single-value-backward … :error-on-unknown t`. Note that `06` does
not even reach the MMA — it trips on *metadata* (`inner-dimension`), which is
gradient-inert and belongs in `%backward-skip-fn-p` (src/autodiff.lisp:1535). Hence P1.


The math
--------

C = A·B  ⟹  dA = dC·Bᵀ ,  dB = Aᵀ·dC

Both backward products are themselves GEMMs, so both *can* run on the tensor cores. Two
things constrain how.

### 1. Transposes are free at the fragment level

- **PTX**: `load-fragment-a/b` are per-lane index rewrites (src/mma.lisp:303-354), so a
  transpose is just swapping `(r,c)` in the address math. Zero cost.
- **SPV**: they are `CooperativeMatrixLoadKHR` with a `layout` operand
  (`%coop-layout-of`, src/mma.lisp:249), so a transpose is flipping 0↔1. Zero cost —
  *except* for the Intel B-operand restriction below.

### 2. Shape algebra — when the MMA *lowering* applies

> **READ THIS FIRST.** An earlier version of this section called the rule below "the K-tile
> contract" and declared it a hard, hardware-imposed limit on which kernels can be
> differentiated. **That was wrong and has been retracted** — see "THE VJP REGISTRY" at the end
> of this document. dA = dC·Bᵀ and dB = Aᵀ·dC hold at EVERY shape. The condition below decides
> only whether the backward can be realised with MMA INSTRUCTIONS; when it cannot, a scalar
> lowering is used instead and the kernel differentiates fine. It is a performance predicate,
> not a correctness gate.

Let the hardware instruction shape be `(M_n N_n K_n)` and the workgroup tile be
`(M_f N_f K_f)`. Mapping the backward GEMMs onto the instruction:

| GEMM | shape (M N K) | new requirement |
| --- | --- | --- |
| forward  C = A·B   | (M_f, N_f, K_f) | `M_f % M_n`, `N_f % N_n`, `K_f % K_n` |
| backward dA = dC·Bᵀ | (M_f, K_f, N_f) | **`K_f % N_n`**, `N_f % K_n` |
| backward dB = Aᵀ·dC | (K_f, N_f, M_f) | **`K_f % M_n`**, `M_f % K_n` |

Everything except the two bolded terms is already implied by the forward's own
constraints. So the *entire* additional contract is:

> **`K_tile % lcm(M_n, N_n) == 0`**

Evaluated on the two profiles we support:

- NVIDIA `(16 8 8)` → `lcm(16,8)` = **16**. Binding constraint comes from **dB**.
- Intel BMG `(8 16 8)` → `lcm(8,16)` = **16**. Binding constraint comes from **dA**.

Same number, opposite reasons.

~~This is a hard contract: violating it is a compile error.~~ **RETRACTED.** This selects the
MMA *lowering*. A tile that fails it is lowered to scalar loops and differentiates correctly —
`132/06` and `133/12` both use K-tile = 8 and both differentiate today.

### 3. Intel cannot read a transposed B operand

Intel has no ColumnMajor-B cooperative-matrix builtin, so a B operand must be declared
`:row-major` (src/mma.lisp:334). But `dA = dC·Bᵀ` wants exactly the forbidden read: B is
stored row-major `(K_f × N_f)` and the backward wants it as a row-major `(N_f × K_f)`,
i.e. a ColumnMajor load.

Fix: **stage Bᵀ through SLM.** `load-tile-at … :transpose` already exists and is already
AD-aware — `%tlc-extract-transpose-key` is threaded through the backward walk
(src/autodiff.lisp:760, 998, 1017). So the SPV backward pays one transposing SLM staging
step that PTX gets for free via index math. Known before we start, not discovered in P5.

### 4. The reduction axis flips

The forward parallelizes over (m,n) and reduces over k. The backward's dA reduces over
**n** (the forward's grid-x) and dB reduces over **m** (grid-y). A workgroup that owns
C-tile (gy,gx) therefore contributes *partial* dA to every (gy,k) and partial dB to every
(k,gx) — those partials must be summed across the grid.

That is exactly the atomic accumulation into `&out` grad handles that the AD engine
already documents as its default. Single-workgroup kernels dodge the issue entirely, so
it is deferred to P8.

### 5. Seeding dC has no PTX path

The backward must get `C_grad` (a global matrix) *into* a register tile. `load-tile` into
a register tile exists but is **Intel/SPV-only** (`Subgroup2DBlockLoadINTEL`,
src/mma.lisp:1231). PTX has no such path.

Fix: a new `load-fragment-acc` primitive — the exact inverse of `store-fragment`, whose
per-lane accumulator layout is already spelled out (src/mma.lisp:259-286). Reverse the
`set!`s into reads. Small, well-defined, and needed on both backends for symmetry. Hence P2.

### 5b. Why there is no fragment-level backward  — RETRACTED

> **This section's conclusion is wrong**, in the same way section 2's was: it argues from one
> chosen realisation (keeping everything in registers) to a claim about the mathematics. A
> fragment-level VJP is possible — route the adjoints through memory, exactly as the tile-level
> VJP already routes dC. It is currently UNREGISTERED, not impossible. Kept below as the
> record of the reasoning error.

Worked through 2026-07-28, and it killed the original P3.

Run the shape algebra on a SINGLE fragment, where by definition `M = M_n`, `N = N_n`,
`K = K_n`:

| | dA = dD·Bᵀ → (M, K, N) | dB = Aᵀ·dD → (K, N, M) |
| --- | --- | --- |
| NVIDIA (16 8 8) | (16, 8, 8) — **fits** | (8, 8, 16) → M'=8 < M_n=16 — **no** |
| Intel BMG (8 16 8) | (8, 8, 16) → N'=8 < N_n=16 — **no** | (8, 16, 8) — **fits** |

Exact mirror images, because the two vendors' shapes are transposes of one another. And it
is just the general contract firing: a single fragment has `K = K_n = 8`, and
`8 % lcm(M_n, N_n) = 8 % 16 ≠ 0`. **On both backends, one of the two backward GEMMs cannot
be expressed as a native MMA.**

Nor is a non-MMA fragment backward the answer: `dA[m,k] = Σ_n dD[m,n]·B[k,n]` contracts over
`n`, but a lane holds only two of the accumulator's columns and a single B column — the
reduction spans lanes, making it a warp-shuffle problem. Slow, intricate, and the wrong
altitude.

So the AD rule lives at the TILE level, where operands are in memory (SLM or a register
tile), the transposes are free, and `Kt % 16` can be enforced. Raw `mma-accumulate` stays a
forward-only escape hatch — which is consistent with Decision 1 (hard contract, no silent
fallback) and costs nothing user-facing: the epilogue-fusion story (ReLU, bias) rides the
`(acc)` body API on `mma-accumulate-via-tile`, not on raw `mma-accumulate`. If a raw
fragment-level gradient is ever wanted, the natural route is a user-supplied VJP, exactly as
endeavor 123 did for FFI.

### 5c. The P3b emission plan (settled 2026-07-28)

Both backward GEMMs need one TRANSPOSED operand, and the orientation is forced — the
"transpose the output instead" trick does not survive the shape check on Intel:

| formulation | GEMM shape on BMG (Mt=8, Nt=16, Kt=16) | verdict |
| --- | --- | --- |
| dA = dC·Bᵀ | (Mt, Kt, Nt) = (8, 16, 16) | fits — but needs Bᵀ as the B operand |
| dAᵀ = B·dCᵀ | (Kt, Mt, Nt) = (16, **8**, 16) | **N'=8 < N_n=16 — fails** |
| dB = Aᵀ·dC | (Kt, Nt, Mt) = (16, 16, 8) | fits — but needs Aᵀ as the A operand |
| dBᵀ = dCᵀ·A | (Nt, Kt, Mt) = (16, 16, 8) | fits, all row-major |

So dA has no transpose-free formulation on Intel. Rather than depend on ColumnMajor
cooperative loads (see the finding below), the backward stages the transposed operands into
SLM explicitly — plain workgroup-collective element copies, no MMA, cheap next to the GEMMs:

```
dC-slm  (Mt x Nt)  <- store-tile C-tile_ADJ        ; register -> SLM
AT-slm  (Kt x Mt)  <- transposing copy of A-tile
BT-slm  (Nt x Kt)  <- transposing copy of B-tile
   dA-reg (Mt x Kt) : mma-accumulate-via-tile (M N K) dA-reg dC-slm BT-slm
   dB-reg (Kt x Nt) : mma-accumulate-via-tile (M N K) dB-reg AT-slm dC-slm
store-tile dA-reg -> A-tile_ADJ ;  store-tile dB-reg -> B-tile_ADJ
```

Every operand read is row-major, so the emission is backend-neutral. Fragment decomposition
checks out on BMG: dA's A-operand is 8x16 read as 8x8 A-fragments (2 K-steps — which is
exactly what P3a unlocked), its B-operand 16x16 as 8x16 B-fragments, its accumulator 8x16 as
one acc fragment; dB's operands are 16x8 / 8x16 with a 2-fragment accumulator.

The existing 111 machinery then does the rest: `A-tile_ADJ` / `B-tile_ADJ` are already
auto-allocated by `%augment-scratch-adj-bindings`, and `%load-tile-at-bwd` already scatters
them back into `A_GRAD` / `B_GRAD`. `C-tile_ADJ` is seeded from `C_GRAD` by the `store-tile`
backward, using P2's `load-fragment-acc`.

Two transposing copies per K-tile is a real cost. It is deliberate: correctness first, and
the transposes are the obvious later optimization (a ColumnMajor operand read once that path
is trustworthy, or a swizzled staging), exactly as the forward's SLM swizzle was deferred in
132.

### 5d. OBSERVED — `:col-major` is silently ignored by the SPV cooperative loads

Found while checking whether the transposes could ride a ColumnMajor operand read.
Declaring a matrix `:contiguous-term :col-major` and loading a B fragment from it on BMG
emits `MemoryLayout = 0` (RowMajorKHR) — the same constant as the row-major A operand:

```
4 Constant 15 125 0
7 CooperativeMatrixLoadKHR 292 293 256 125 260 0    ; A, row-major
7 CooperativeMatrixLoadKHR 294 295 265 125 260 0    ; B, declared COL-major -> still 0
```

`:col-major` does canonicalize to `:first` (src/types/validation.lisp:143) and
`%coop-layout-of` maps `:first` -> 1, so the intent is not reaching the node. NOT chased —
P3b routes around it entirely — but it is worth a look on its own: a user declaring a
col-major operand on SPV today gets a RowMajor load with no diagnostic. (The on-metal probe
still printed MMA_CORRECT, because the host reference is stride-agnostic and follows the
same declared strides, so the two errors may be cancelling. That makes it more worth
investigating, not less.)

### 6. Register pressure

The backward holds dC, dA and dB accumulators simultaneously — roughly 3× the forward's
accumulator budget. `%register-tile-fit-check` (src/mma.lisp:820) must account for the
backward's tiles under `--differentiate`, otherwise a kernel that fits forward silently
blows the budget in its gradient. Folded into P4.


Decisions taken (2026-07-28, with Chris)
----------------------------------------

1. ~~**K-tile contract is hard** — compile error, no silent non-MMA fallback for dB.~~
   **REVERSED 2026-07-31.** Correct-but-slow is the default; MMA is a gated fast path. The
   original decision baked one lowering's limits into the language.
2. **`--mma-grad-test` (P6) lands before VERIFY-AUTODIFF matrices (P9).** Both eventually.
3. **SPV/BMG leads.** The dev machine is BMG, so SPV is testable immediately; PTX work is
   batched into P7 against a rented pod. Note the endeavor does **not** need sm_90 — the
   tf32 `mma.sync.m16n8k8` path is sm_80+, and wgmma (the only sm_90a construct) is out of
   scope. An A10 / L4 / RTX 3090 / 4090 pod suffices.
4. **No dedicated `matmul-backward` form.** The AD engine derives the backward from
   `mma-accumulate-via-tile`. This is deliberate: Crisp's MMA lets users fuse their own
   epilogues (ReLU, bias) via the `(acc)` body API (F3), and they must stay differentiable.
   A predefined GEMM-backward form would break that.


Phases (SPV-first)
------------------

[x] P1 — **gradient-inert shape queries.**  DONE 2026-07-28.  `inner-dimension` and
    `outer-dimensions` differentiate.  Scoped DOWN from the original sketch: the register-tile
    constructors (`make-register-tile` / `make-register-fragment` / `fill-tile`) are NOT
    gradient-inert — a register tile needs a paired `_ADJ` tile, not a skip — so they move to
    P4/P5 where they are actually exercised.
    - The two forms fail for DIFFERENT reasons, which is the whole content of the phase:
      `inner-dimension` (single-value) is rejected by the backward WALK -> a
      `%backward-skip-fn-p` entry.  `outer-dimensions` (multi-value) is already ignored
      correctly by the walk, but the backward kernel's primal REPLAY drops it -> "Unknown
      variable M".
    - The replay bug is general, not MMA-specific: `forward-bindings` in
      `%generate-backward-kernel-ast` collected only TWO-element ANF forms, so NO multi-value
      binding has ever been replayed into a backward kernel (`floor`, `truncate`, and
      multi-return user functions are all equally affected).
    - GOTCHA (cost a false start, broke 111/14 + 111/15): a multi-value binding CANNOT be
      recognized by shape after flattening.  `flatten-anf-body` (src/anf-transform.lisp:369)
      pushes real LET bindings and bare statement forms into the same flat list, and they are
      structurally identical — `(M N (outer-dimensions A B))` is a binding, but
      `(load-tile-at A tile (0))` and `(set! acc (+ acc x))` are statements, and all three are
      "symbols then a cons".  Fix: collect genuine bindings from the PRE-FLATTEN anf-body
      (where a binding is by construction an element of a LET binding list), then filter
      flat-anf by EQ so source order is preserved.  The two-element rule is kept VERBATIM so
      existing kernels replay byte-identically.
    - Overlay: `%backward-skip-fn-p`, `%collect-multi-value-anf-bindings` (new),
      `%collect-forward-primal-bindings` (new), `%generate-backward-kernel-ast`.  All defuns —
      no macro patch needed.
    - IR-VERIFIED by hand, not just exit codes: in `dot_inner_dim_grad`, A.extents[1] is read
      and drives the backward loop bound; the chain rule emits `B[k,0]*acc_adj` and
      `A[0,k]*acc_adj` into two `atomicrmw fadd` on addrspace(1).  In `dot_outer_dims_grad`,
      `{i64,i64}` is extractvalue'd into M and N, both driving nested backward loops.
    - Suite: E2E 943/943, --differentiate 943/943, unit 253/253, negative 211/211.
    - OBSERVED, out of scope: `to-float` is NOT in the skip list, so `(to-float <int>)` in a
      differentiable kernel reports "not differentiable".  An int->float conversion has a real
      (zero) derivative the engine has no rule for.  Noted, not fixed — the P1 specs use the
      shape values as loop bounds instead.
[x] P2 — **`load-fragment-acc`** (inverse of `store-fragment`), both backends.  DONE
    2026-07-28.  Prerequisite for seeding dC.
    - `(load-fragment-acc SRC (TY TX))`.  SPV -> `CooperativeMatrixLoadKHR` with Use=2 and
      layout from the source tensor's `:contiguous-term`, mirroring `analyze-store-fragment`
      so a Load/Store pair always agrees.  PTX -> the per-lane read at the m16n8 fp32
      accumulator layout, a pure REWRITE (no new codegen), like its sibling.  Tallied against
      the register budget exactly as `make-register-fragment` is — a LOADED accumulator
      occupies the same registers as a constructed one, and 144's fit-check must see both.
    - Overlay: `analyze-load-fragment-acc` (new) + `register-mma-analyzers` (verbatim + one
      entry).
    - VERIFIED, both backends.  PTX (structural, by hand): four `ld.global.b32` before the
      `mma.sync` at `shr(lane,2)` / `and(lane,3)` / `shl(...,1)` / `or(...,1)` / `or(g,8)` —
      i.e. `(g,2t) (g,2t+1) (g+8,2t) (g+8,2t+1)`, the exact addresses `store-fragment` writes;
      the `mma.sync` C operand is `{%r5,%r7,%r9,%r10}`, those four loads; the first store
      reuses the first load's address register.  SPV: disassembled to 3 `CooperativeMatrixLoadKHR`
      (A, B, accumulator) + `MulAddKHR` whose C operand IS the accumulator load, same
      pointer/stride as the Store.  **ON METAL (BMG): MMA_CORRECT.**
    - Suite: E2E 943/943, --differentiate 943/943, unit 253/253, negative 211/211.

    **GOTCHA worth keeping — you cannot test a fragment layout by round-tripping it.**
    The first cut of spec 03 "laundered" a real MMA result through memory
    (`store -> sync -> load-fragment-acc -> store`), expecting a wrong mapping to permute C.
    It cannot work: a store followed by a load of the SAME address in the SAME thread is
    always store-to-load forwardable, and a CORRECT layout makes the round-trip provably the
    identity — so `-O3` deleted the reload AND the second store outright (confirmed in the
    emitted PTX, which ended at `bar.sync; ret`).  More generally, **any self-consistent
    load/store pair is observationally equivalent to any other**, so the element->lane mapping
    is simply not observable in isolation.  It becomes observable only when the loaded value is
    a NON-ZERO seed whose contribution the host can predict — which is exactly the P3 backward
    test with a real dC.  The specs were rebuilt around the shape the backward actually uses
    (seed the accumulator from a global matrix, then MMA into it) and are explicit about
    proving REGION/COUNT correctness now and MAPPING correctness in P3.
**P3 was re-planned on 2026-07-28** after the shape algebra was worked through at the
FRAGMENT level. The original P3 ("fragment-level rule: `mma-accumulate` backward") is
**impossible**, and the original P4 absorbed what remains. See "Why there is no
fragment-level backward" below.

[x] P3a — **`mma-accumulate-via-tile` walks K WITHIN a staged tile.**  DONE 2026-07-28.
    A forward capability, but a hard prerequisite for the backward AND a latent forward
    bug fix.
    - The contract needs `Kt % 16`, i.e. at least TWO native K-steps per tile. But
      `%emit-per-frag-accumulate` fired exactly ONE, reading its operands at a hardcoded K
      tile-index 0 (`(load-fragment-a A (mi 0))`). Every shipped forward kernel got away
      with it by staging `Kt = K_n = 8` and looping K externally. **Stage anything wider and
      the surplus was silently dropped — no error, no warning, a wrong answer.** Measured on
      BMG: an 8x16 A-tile emitted ONE MulAdd; spec 05 reported `MMA_WRONG` (got 11, ref 30).
    - Fix: the K-step count is compile-time (`Kt / K_n` from the operand shapes), so the
      expansion is a pure unroll. Both operand flavours handled — SLM scratch tiles (via the
      new `*mma-scratch-tile-dims*`, published by `%explode-register-tiles`) and endeavor-142
      register tiles / ring slots (whose fragment indexing already had the stride, it just
      never used a non-zero K index). One-K-step tiles expand exactly as before.
    - Added a guard that used to be silent truncation: A's column extent must equal B's row
      extent (A is Mt x Kt, B is Kt x Nt) — a mismatch is now a hard error.
    - F3 semantics preserved: `(accum-op)` fires the fragment's WHOLE contraction — all its
      K-steps — keeping the promise that the body controls WHEN a fragment accumulates, not
      how its contraction is chopped up.
    - Overlay: `*mma-scratch-tile-dims*`, `%mma-scratch-tile-dims-from-bindings`,
      `%mma-operand-extent`, `%mma-k-steps` (all new), `%emit-per-frag-accumulate` and
      `%explode-register-tiles` (re-definitions).
    - **ON METAL (BMG): spec 05 went MMA_WRONG -> MMA_CORRECT.**  Suite: E2E 943/943,
      --differentiate 943/943, unit 253/253, negative 211/211.
[x] P3b — **tile-level rule: `mma-accumulate-via-tile` backward.**  DONE 2026-07-28.  The heart
    of the endeavor: an MMA kernel differentiates end to end.  Spec
    `06-via-tile-backward-bmg.crisp`.  Suite: E2E 943/943, --differentiate 943/943, unit
    253/253, negative 211/211, and 145 6/6 with the forward still MMA_CORRECT on BMG.
    - `%mma-ad-tile-dims-map` / `%mma-ad-tile-source-map` / `%mma-ad-transposed-stage` /
      `%mma-via-tile-backward` (+ a `-logged` wrapper — run with `--log-level=debug` to dump the
      emitted backward AST, which is by far the most useful artifact when this fails); the walk
      clause, spliced into `generate-backward-walk`; register-tile adjoint allocation
      (`%mma-ad-adj-init`, `%augment-scratch-adj-bindings`, the `scratch-adj-bindings`
      collection, and `MAKE-REGISTER-TILE` in `%backward-skip-fn-p`).
    - The emission is VERIFIED CORRECT (dumped and read by hand): all five temporaries carry
      the right shapes — dC 8x16, A^T 16x8, B^T 16x16, dA-acc 8x16, dB-acc 16x16 — with both
      GEMMs in the right operand order.
    - THE REGISTER-TILE STORE (the blocker, now fixed).  The forward
      `(store-tile C-tile C (0 0))` reached the AD walk already rewritten to `store-tile-at`
      with SCRATCH-convention element coords:

          (%STORE-TILE-AT-BWD C-TILE_ADJ C_GRAD
            ((* (TO-ULONG 0) (~ (EXTENTS~ C-TILE) 0)) ...))

      Two faults from one root cause: `extents~` is invalid on a register tile, and
      `C-TILE_ADJ` is SROA-exploded into per-fragment vars so the bare name no longer exists
      ("Unknown variable C-TILE_ADJ").

      ROOT CAUSE — and it is NOT the endeavor-107 stride pre-pass, which was the first guess.
      `store-tile` is a CL `defmacro` (src/macros.lisp:1857) that scales tile-IDs by the tile's
      extents.  On the FORWARD path it never expands: STORE-TILE has its own analyzer and the
      SROA explosion matches the un-expanded form.  The AD path runs ANF first, and
      `anf-normalize` (src/anf-transform.lisp:174) macroexpands ANY symbol carrying a
      `macro-function` BEFORE reaching its own opaque-passthrough list — a list that already
      names "STORE-TILE"/"LOAD-TILE" (line 187).  The intent was there; the expansion just
      fires first and the entry is unreachable.

      FIXED IN THE WALK, NOT IN `anf-normalize`.  Dropping STORE-TILE from that macroexpansion
      would change flat-anf for every SCRATCH-tile kernel using the sugar, and those depend on
      STORE-TILE-AT reaching the endeavor-111 rules — a silent gradient regression.  So the walk
      gained a register-tile branch (ordered BEFORE the scratch rule) that recovers the original
      tile-IDs with `%mma-ad-unscale-tile-origin` (unwrapping `(* (to-ulong G) (~ (extents~ T) i))`
      back to `G`) and emits `%load-register-tile-acc`, expanded per fragment by
      `%emit-per-frag-acc-load` — the mirror of `%emit-per-frag-store`, reading with P2's
      `load-fragment-acc`.  Note the `anf-normalize` unreachable-entry is left as-is and is worth
      a separate look.
    - One more fix: the transposing stage coerces both addends with `to-int`.  A load-tile-at
      origin can be a ULONG extent expression while the collective's loop vars are INT, and `+`
      will not mix them.
    - VERIFIED in the emitted SPIR-V, per function: forward = 2 MulAdd / 4 Load (2 K-steps);
      **backward = 4 MulAdd / 9 Load** — exactly the predicted dA (1 fragment x 2 K-steps) +
      dB (2 fragments x 1 K-step), plus the ONE accumulator-seed load from `C_GRAD`.
      Spec 06 passes both COMPILE-WITH runs and its forward is still MMA_CORRECT on BMG.
[x] P3c — **raw `mma-accumulate` under `--differentiate` is a clear compile error.**  DONE
    2026-07-28.  Spec `07-fragment-mma-not-differentiable.crisp`.
    - The generic "Function MMA-ACCUMULATE is not differentiable.  Wrap the kernel in
      'forward-only' …" gave exactly the WRONG advice: the multiply IS differentiable (spec 06),
      just not at that altitude, and `forward-only` steers the user away from the thing that
      works.  The new message states the shape reason and names `mma-accumulate-via-tile` plus
      the K >= lcm(M_n,N_n) requirement.  Covers all six fragment-level forms.
    - The spec is a negative test that CANNOT live in `errors/`: `run-error-specs.lisp` invokes
      a fixed arg list (file + `--log-level=off`) and cannot inject `--differentiate`, so the
      kernel would compile forward-only and fail for the wrong reason.
      `COMPILE-WITH[…]: FAIL "substring"` is the mechanism that carries the flag.
[x] P5 — **whole-kernel: the realistic K-LOOP shape.**  DONE 2026-07-28.  Spec
    `08-k-loop-matmul-diff-bmg.crisp`; forward MMA_CORRECT on BMG over a runtime K=32.
    - Wrapping the multiply in a `dotimes` broke the backward SILENTLY.  `flatten-anf-body`
      flattens LET and PROGN but leaves a DOTIMES body NESTED, and the rule's tile maps scanned
      only the TOP LEVEL of flat-anf — so in a loop the `load-tile-at` forms were invisible, the
      rule declared itself "not applicable", and the walk's fallthrough DROPPED the form.  The
      emitted backward had **zero** `CooperativeMatrixMulAddKHR` and would have returned a zero
      gradient.
    - Fixes: (1) the maps walk the whole tree (`%mma-ad-walk-forms`); (2) the "not applicable"
      path is now a HARD ERROR naming which operand could not be resolved.  (2) is the important
      one — returning NIL let a silent zero gradient through, the same class of failure as the
      P3a data-drop.  A quietly-wrong gradient is far worse than a kernel that will not compile.
    - Verified per function in the _grad module: forward 2 MulAdd / 4 Load / 1 Store; backward
      4 MulAdd / 9 Load / 4 Store (dC->SLM, dA, and dB's two fragments).
[ ] P5 — **whole-kernel.** `store-tile`(register) backward + the K-loop + transposed SLM
    staging. A full tiled matmul differentiates end-to-end on one workgroup.
[ ] P6 — **on-metal NUMERIC gradient verification.**  RE-PLANNED 2026-07-28: **P6 and P9 are the
    same phase**, and it is NOT a hoist feature.
    - The original plan (`--mma-grad-test` in the hoist, mirroring 134's `--mma-test`) cannot
      work: `--differentiate` and `--hoist` are HARD-INCOMPATIBLE (src/main.lisp:144), so the
      hoist never sees a backward kernel.  Making it work would mean lifting that restriction —
      a much larger architectural change than the phase was scoped for.
    - The established on-metal AD path is VERIFY-AUTODIFF, which compiles `<spec>.spv` and
      `<spec>_grad.spv` itself and drives them through its own L0 bindings, no hoist involved.
      Extending IT to 2-D matrices is the real remaining work — i.e. what was listed as P9.
    - SIZE (measured, so this is not a guess): the backward kernel of the K-looped matmul has
      **117 parameters** — six matrices at 9 exploded args each plus the implicit scratch tiles
      (the forward's two, their `_ADJ` pairs, and the backward's three staging temporaries).
      The runner binds arguments by KIND, so this wants a proper `:matrix-float` kind, not a
      bespoke launcher.  Hand-rolling one would be exactly the sort of thing that yields a
      verification you cannot trust.
    - **DONE 2026-07-28.**  Spec `09-verify-autodiff-matmul-bmg.crisp`:
      **`PASS (A: analytical=1.1994476 numerical=1.1989746 diff=4.7e-4)`** against an
      `expect.A` of exactly 1.2 — the residual is tf32's 10-bit mantissa.  **The MMA backward
      computes correct gradients on real hardware.**  It also finally closes P2's open gap:
      the seed is non-zero, so the fragment element->lane MAPPING is load-bearing and a wrong
      one would change the answer.

    What VERIFY-AUTODIFF learned (all generic, none of it MMA-specific):
      - matrix literals `[[..][..]]` — the tokenizer now tracks bracket DEPTH, not a boolean,
        which is what let a 2-D literal survive as one token;
      - `RxC@START:STEP`, a compact row-major ramp generator.  Needed because the smallest
        contract-satisfying shapes are 8x16 and 16x16 — 384 literals would make a spec
        unreadable.  Deliberately NON-uniform: a uniform matrix equals its own transpose and
        so could not catch a transposed operand;
      - `at.<name>=row,col`, `output-mat=RxC`;
      - a `:matrix-float` input kind on the 9-arg tensor ABI, plus 9-arg binding for :local
        scratch tiles.  Shapes and arg ranges come from the .metacrisp, so nothing is
        hand-wired — which is what made a 117-parameter kernel tractable at all;
      - the verify compile now forwards `--hardware-profile` (from HOIST-HARDWARE-PROFILE).
        Without it an MMA kernel falls back to the NVIDIA default shape and is rejected.

    **The bug this phase existed to catch.**  With everything above working, the first
    on-metal run returned `analytical=0.0`.  The runner launches with
    `ze-kernel-set-group-size 1 1 1` and one group — a SINGLE THREAD.  That is fine for the
    scalar/vector elementwise kernels it was built for, but MMA is SUB-GROUP COLLECTIVE and
    with one thread the cooperative ops do nothing at all, so the gradient was exactly zero.
    Hence the new `group=<n>` directive key (default 1, so every pre-145 spec is unchanged).
    No amount of IR inspection would have found this — it is precisely the class of failure
    that only numeric on-metal checking catches.
[x] P7 — **PTX / NVIDIA parity.**  DONE 2026-07-30 on a rented RTX PRO 4000 Blackwell (sm_120,
    CUDA 12.4).  Spec `10-via-tile-backward-ptx.crisp`.
    - The rule is backend-neutral by construction (the backward is emitted as ordinary Crisp
      forms that then take the normal forward path), so what this phase really tests is the
      SHAPE ALGEBRA on the other vendor's instruction.  NVIDIA (16 8 8) is the TRANSPOSE of
      Intel's (8 16 8), so the smallest legal tile mirrors it: Mt=16, Nt=8, Kt=16 (vs BMG's
      Mt=8, Nt=16, Kt=16).  Both backward GEMMs fit: dA (16,16,8), dB (16,8,16).
    - The 2-K-step operand lands on the OTHER backward GEMM than it does on BMG (dB's A^T
      here, dA's dC there), so this is a genuinely different path through
      `%emit-per-frag-accumulate` — which is why it earns its own spec rather than being
      assumed from the Intel result.
    - **NO COMPILER CHANGE WAS NEEDED.**  Both COMPILE-WITH runs and the on-metal forward
      passed against the code as written for BMG.
    - VERIFIED: PTX `mma.sync` counts per entry — forward 2, **backward 4** (dA 2 fragments x
      1 K-step, dB 1 fragment x 2 K-steps), exactly the predicted decomposition.
      **ON METAL (Blackwell): MMA_CORRECT.**  145 suite 10/10 on the pod (the BMG specs
      SKIP cleanly there).
    - Whole-suite regression on the pod: **946/953**, with 7 failures — ALL in 137 / 138 / 139 /
      140, all `--ir-target-arch=sm_90` specs, and all failing at PTX **JIT time on the device**
      after PTX generation PASSED.  wgmma and TMA/CuTensorMap are Hopper (sm_90a) constructs, so
      they cannot run on a Blackwell part — or on the RTX 4090 originally planned.  VERIFIED
      pre-existing rather than assumed: the same specs fail identically at the pre-endeavor
      commit `e05dd58`.  Every MMA spec that actually exercises the changed
      `%emit-per-frag-accumulate` (132 / 133 / 135 / 136 / 142 / 144) passed.
    - HARNESS GAP worth its own fix: those CUDA specs skip-gate on missing `nvcc` but NOT on
      insufficient compute capability, so a Hopper-only spec hard-FAILS on any lesser NVIDIA
      part instead of SKIPping.  Endeavor 140 added exactly this kind of gate for L0/Intel
      (`%intel-l0-gpu-available-p`); the CUDA side needs the arch equivalent.

    **Honest limit — the PTX backward is verified structurally, not numerically.**  The numeric
    gradient proof (P6) is BMG-only, because VERIFY-AUTODIFF drives SPIR-V through L0/OpenCL and
    NVIDIA offers no cooperative-matrix path.  The `--mma-grad-test` route is closed for the same
    reason it was on Intel (`--differentiate` and `--hoist` are incompatible).  Closing this
    would mean adding a CUDA driver-API runtime as a third `*ad-runtime*` beside `:l0` and
    `:opencl`.  That is tractable and NOT a redesign — the descriptor, ABI and metacrisp-driven
    binding logic added in P6 is runtime-agnostic; only the low-level alloc / set-arg / launch
    layer differs (~the size of the existing `l0-*` block).  The 117-parameter kernel is handled
    by that machinery either way.  Worth its own phase; the mathematical rule it would be
    re-checking is already numerically proven on BMG.
[x] P8 — **multi-workgroup + atomics.**  DONE 2026-07-30.  Spec
    `11-multi-workgroup-matmul-bmg.crisp`: **`PASS (A: analytical=4.9577484
    numerical=4.9560547 diff=1.7e-3)`** vs `expect.A` 4.96, dispatched to **2 workgroups**.
    - The atomics needed NO new work.  `%load-tile-at-bwd` (endeavor 111) has always scattered
      a tile adjoint into its global gradient with an ATOMIC add, and each workgroup accumulates
      into its own :local SLM adjoint tile first.  Confirmed in the emitted SPIR-V: backward
      carries 2 `AtomicFAdd`, forward none.
    - WHAT DID BREAK — `matrix-multiply-tile-stride` was mangled by ANF.  The endeavor-107 AD
      pre-pass knows tile-stride / grid-stride / workgroup-stride etc. but NOT the endeavor-135
      matmul macro, so it survived into ANF, which treated it as an ordinary call and normalised
      its arguments.  The BINDING-NAME LIST became a call —
      `(%ANF-T-1 (GRID-Y GRID-X GRID-K))`, hence "Function GRID-Y is not differentiable" — and
      every body form was hoisted into a temp OUTSIDE the loop binding those names.  Fixed by
      pre-lowering the macro ahead of the AD pre-pass (`%mma-ad-prelower-mmts`), exactly as the
      forward path already does before analysis.
    - Two further AD-path gaps from the same kernel, both fixed generically: a tile load/store
      in ANF VALUE position (the macro's `:epilogue` ends with `store-tile`, so it arrives as
      `(%t (store-tile-at ...))`, not a statement) and the same for `mma-accumulate-via-tile`.
      Both are VOID, so the walk unwraps the temp and re-dispatches — which repairs the
      scratch-tile path too, not just the register one.
    - VERIFY-AUTODIFF gained `groups=N` (workgroup count, default 1) alongside `group=N`
      (threads per group).  >1 is what makes the cross-workgroup accumulation real.

    **FOUND EN ROUTE — BUG 036, a pre-existing FORWARD bug.**  `matrix-multiply-tile-stride`
    never resets the register C-tile accumulator between output tiles, so ANY matmul wider than
    one output tile is silently wrong: the second tile returns with the first tile's partial sums
    added on top (`C[0][16]=60 ref 30` on BMG).  Reproduced with the SHIPPED 135/04 spec
    unmodified apart from widening the harness dims, and confirmed by construction — the same
    kernel hand-rolled with `(fill-tile C-tile 0.0)` per tile is MMA_CORRECT.  Never caught
    because every shipped spec uses exactly ONE output tile, so the loop body runs once.  Filed
    rather than fixed: it is a shipped forward macro and the fix has two decisions worth making
    deliberately (reset to 0.0 or to the tile's declared INIT; the scratch path needs a barrier
    the register path does not).  Spec 11 routes around it with an explicit `tile-stride` +
    `fill-tile`, which keeps the AD work unblocked and the forward fix separately reviewable.
    The finite difference is an independent witness: 6.154 (wrong) with the macro, 4.956 (right)
    with the reset.

[x] Closing sweep — DONE 2026-07-30.  Every `SKIP-WITH[--differentiate]` across 132 / 133 / 135
    now states the ACTUAL reason instead of the blanket "forward-only MMA".  The honest outcome
    is that almost nothing could be un-skipped, and the reasons say why:

    | count | reason |
    | --- | --- |
    | 7 | fragment-level MMA has no backward (P3c) — on one fragment M/N/K are the native shape, so one of dA/dB always fails the vendor check |
    | 7 | operands read straight from global, not staged via `load-tile-at`, so the backward cannot recover their sources to stage the transposes (P3b) |
    | 7 | K-tile 8 violates the `K % lcm(M_n,N_n) == 16` contract |
    | 1 | `to-float` has no AD rule — NOT an MMA limit (noted in P1) |
    | 1 | negative test (register fit-check is a compile-time budget error) |

    Un-skipped: `135/07-fill-tile-scratch` (its old reason, "ulong not differentiable", was
    simply stale — it differentiates).  Tried and reverted with accurate reasons:
    `132/08-outer-dimensions` (blocked on `to-float`, not on MMA) and `135/01` / `02` / `10`
    (scratch-tile matmuls that reach further than before thanks to P8's mmts pre-lowering but
    still do not differentiate).

    These are DESIGN limits, not omissions: the fragment forms are forward-only by construction,
    and a via-tile whose operands never touched `load-tile-at` gives the backward nothing to
    transpose.  The 145 specs cover each supported path with a differentiable equivalent.

CORRECTION (2026-07-30, after Chris spot-checked 132/01) — THE CONTRACT WAS NEVER ENFORCED.
The sweep above was first done by CLASSIFYING specs by which forms they contain, and only four
were actually run.  That was wrong twice over:

  1. `132/01` and `133/01` / `03` DO differentiate.  They have no differentiable INPUTS (their
     only parameter is `&out`), so the engine takes its documented trivial-backward path and
     emits a gradient kernel with no chain-rule body — vacuous, but CORRECT.  They are now
     un-skipped rather than carrying a fabricated reason.

  2. Far worse: `132/06`, `133/06`, `133/12`, `135/03`/`04`/`08`/`09` — every Kt=8 kernel —
     also "differentiated".  They should not have.  The K-tile contract was specified in P3b,
     documented above as "a HARD contract: violating it is a compile error", and **the check
     was never written**.  The consequence was silent: on BMG (8 16 8) a Kt=8 tile makes the dA
     accumulator Mt x Kt = 8x8, which decomposes into 8/16 = ZERO accumulator fragments, so that
     entire backward GEMM emitted NOTHING.  Measured on 133/12: forward 1 MulAdd, backward also
     1, where a correct backward needs both dA and dB.  The kernel compiled, ran, and returned a
     gradient missing half of itself — exactly the silent-wrong-answer class this endeavor kept
     turning up, this time introduced by the endeavor itself.

  The check now lives in `%mma-via-tile-backward`, on the ACCUMULATOR decomposition (which is
  what degenerates) rather than on the K-step count: `Kt % lcm(M_n,N_n)`, `Mt % M_n`, `Nt % N_n`.
  Kt=8 now errors with the tile shape, the instruction shape and the required multiple; Kt=16
  still compiles.

  METHOD NOTE, since it caused this: three successive attempts to survey the specs by
  pattern-matching (which forms they contain, then grepping stderr for known message text) each
  gave a different and partly wrong answer.  Only checking the compiler's EXIT STATUS per spec
  was trustworthy.

BUG 036 — FIXED 2026-07-30 (see plan/bugs.md).  `%mmts-lower` now emits a per-output-tile reset
before the K-loop, to the tile's DECLARED INIT so multi-tile matches single-tile semantics.
**Register tiles only** — 135/01 documents the scratch contract in its own body ("The macro does
NOT auto-reset a scratch C-tile — the user owns init") and 135/02 resets by hand; the register
tile's init lives in a binding OUTSIDE the loop where the user cannot reach it per-tile, and that
asymmetry is the whole justification.  An earlier cut reset both and broke 135/01 / 02 / 10.
Regression spec: `135/11-multi-tile-matmul-bmg.crisp`.
[ ] P9 (stretch) — **VERIFY-AUTODIFF matrix inputs** (`A=[[…][…]]`, `at.A=(r c)`). The
    runner is scalar-cell + 1-D-vector only today.

**Out of scope** (a future endeavor): AD over the Chapter 1-4 optimizations — async
staging (136), pipeline rings (138), warp specialization (139), wgmma (140), Intel
prefetch (142). 145 ends with a differentiable *synchronous* tiled matmul on both
backends; optimizing that gradient is a second pass over the same math.


Testing
-------

**New 145 specs lead, per phase, written before the implementation.** Un-skipping the
existing MMA specs is the *closing* move of the endeavor, not the mechanism — those
kernels were not built for AD (132/06 and 133/12 both violate the K-tile contract), and
editing them to fit would rewrite the record of endeavors 132-134.

So the endeavor finishes with a sweep over 132 / 133 / 135, dropping
`SKIP-WITH[--differentiate]` from every spec that genuinely satisfies the contract and
replacing the rest's reason string with an *accurate* one ("K-tile 8 violates the
K % lcm(M,N) contract") instead of the current blanket "forward-only MMA".

ci-stop stays at `144-mma-hardware-profile` until P5 lands.


THE VJP REGISTRY — and the retraction of the "K-tile contract"  (2026-07-31)
===========================================================================

Chris asked why 132/06 was refused when the kernel is plainly differentiable.  It is, and the
refusal was wrong.  Reviewing all nine 132 specs as INTENTIONS rather than as code, they are
only three things — `C := constant` (01, 03, 07), `C = A·B` (02, 04, 05, 09, and 06 with
staging and a K-loop), and one shape query (08).  There is exactly ONE derivative in the
directory.

WHAT WENT WRONG.  The backward was derived THROUGH a chosen lowering — register accumulator
tiles decomposed into native fragments — and that lowering's shape requirements were then
written up as "the K-tile contract", as though the hardware imposed them.  It does not.
dA = dC·Bᵀ and dB = Aᵀ·dC hold at every shape.  Only the MMA REALISATION of them needs the
tile dims to divide.  Three separate "fundamental limits" claimed in this document turned out
to be artifacts of that one choice: the K-tile contract, "no fragment-level backward exists",
and the demand that operands be staged via load-tile-at.

THE FIX is structural, not a patch.  A general VJP REGISTRY: primitive name -> a function
returning backward Crisp source, `:inert`, or NIL to decline.  The walk gained ONE dispatch
that runs ahead of its hand-written clauses, so an empty registry is provably a no-op and
migration proceeds one primitive at a time.  Scope is PRIMITIVES only — let / dotimes / if
must be structurally mirrored by the walk and are not lookups.

The load-bearing detail: **the lowering is chosen INSIDE the VJP.**  `mma-accumulate-via-tile`
returns the MMA form when the accumulators decompose into whole fragments and a plain scalar
triple-loop otherwise.  The walk never learns the fragment condition, so it cannot leak back
out as a language-level contract.  Correct-but-slow is the default; MMA is the fast path.

The scalar lowering is in fact SIMPLER than the MMA one — it indexes the original global
operands directly, needing none of the transposed SLM staging.

RESULT (all measured by compiler EXIT STATUS, not by reading the source or grepping stderr —
three pattern-matching surveys each gave a different wrong answer):

  * 14 specs across 132 / 133 / 135 that were skipped with fabricated reasons now differentiate,
    and their skips became real `COMPILE-WITH[... --differentiate]: PASS` coverage.
  * Numeric proof of the scalar path on metal — spec `12-scalar-vjp-kt8-bmg` at Kt=8, which the
    MMA path cannot express: **analytical=1.2 numerical=1.198822**.  Note it is EXACTLY 1.2
    where the MMA path (spec 09, same f and seed) gives 1.1994476 — that gap is fp32 versus
    tf32, and is direct evidence the two lowerings were both exercised.
  * Suites: E2E 944/944, --differentiate 944/944, unit 253/253, negative 211/211, 145 at 12/12
    with three numeric gradient checks.

WHAT GENUINELY REMAINS SKIPPED (8, each with a true reason):
  3  fragment-level `mma-accumulate` — no VJP registered YET.  Not impossible: a fragment VJP
     would route dC through memory exactly as the tile one does.  The earlier claim that this
     was mathematically impossible was part of the same error.
  3  scratch-C-tile matmul — the tile-stride backward resolves extents~ / ~ against a FLOAT.
     A real gap, unrelated to MMA.
  1  `C` is a reinterpreted view (`make-matrix` over the param), so its adjoint has nowhere to
     land — views at the AD boundary.
  1  `to-float` has no AD rule.
  (plus one negative test, correctly skipped.)

STILL OPEN, deliberately: padding the degenerate accumulator so the MMA fast path covers Kt=8
too (pinned with Chris); `:gradient-lowering` in the metacrisp + an `EXPECT-GRADIENT-LOWERING`
directive so a silent regression to the scalar path is caught by a test rather than a note —
neither is implemented, so neither is documented in plan/ref.metacrisp yet.


FRAGMENT-LEVEL VJP — the last MMA gap  (2026-07-31)
===================================================

Chris: "133-mma-spv has a few marked SKIP-WITH[--differentiate], yet they seem like they should
be differentiable."  Both were `hello mma` — raw fragment forms, no tiles — and both were
skipped on the strength of section 5b's claim that a fragment-level backward is IMPOSSIBLE.
That claim was wrong for the same reason the K-tile contract was: it reasoned from ONE
realisation (keep everything in registers, where dA's contraction over n spans lanes and would
need warp shuffles) to a statement about the mathematics.  Route the adjoints through MEMORY —
exactly as the tile-level VJP already routes dC — and the lane problem never arises.

FUSED, and forced to be.  Measured from the ANF the walk actually receives:

    (C-ACC   (MAKE-REGISTER-FRAGMENT 16 8 0.0))
    (%ANF-T-1 (0 0))
    (A-FRAG  (LOAD-FRAGMENT-A A %ANF-T-1))
    (B-FRAG  (LOAD-FRAGMENT-B B %ANF-T-2))
    (STORE-FRAGMENT (MMA-ACCUMULATE C-ACC A-FRAG B-FRAG) C (0 0))

`store-fragment` is opaque to ANF, so its value argument is never split into its own binding —
there is no intermediate variable on which to hang a fragment-valued adjoint.  One fused VJP is
the natural shape here, not a shortcut.

SCOPE, stated plainly: covers `store-fragment` applied DIRECTLY to an `mma-accumulate`.  An
accumulator held in registers across a loop and stored later is NOT covered.  `load-fragment-a/b`
return `:inert` only when their fragment feeds such a fused chain and DECLINE otherwise, so an
unsupported shape errors loudly rather than silently producing a zero gradient.

ONE MORE LATENT BUG FELL OUT.  A coordinate list reaches the walk as a pseudo-call binding —
`(%ANF-T-1 (0 0))`, because anf-normalize treats a bare list as a call (the same pathology that
turned `(GRID-Y GRID-X GRID-K)` into a call in P8).  The primal REPLAY then tried to analyze
`(0 0)` as an expression.  Such a binding cannot be replayed and, transitively, neither can
anything referencing it; `%collect-forward-primal-bindings` now drops both to a fixpoint.  This
was latent for every fragment kernel, not just these.

RESULT — 133-mma-spv is now FULLY CLEAR of --differentiate skips, and 132 is down to a negative
test plus one unrelated `to-float` gap.  Numeric proof on metal: spec `13-fragment-vjp-bmg`
**analytical=1.2 numerical=1.198822**.

Suites: E2E 944/944, --differentiate 944/944, unit 253/253, negative 211/211, 145 at 13/13 with
FOUR numeric gradient checks (MMA tile path, scalar tile path, multi-workgroup, fragment).

EVERY REMAINING SKIP IS NOW A NON-MMA GAP (6 total):
  3  scratch-C-tile matmul — the tile-stride backward resolves extents~ / ~ against a FLOAT.
  1  `C` is a reinterpreted view (make-matrix over the param) — views at the AD boundary.
  1  `to-float` has no AD rule.
  1  negative test (register fit-check), correctly skipped.


135's SCRATCH-C-TILE SPECS — two bugs, one fixed, one filed  (2026-07-31)
========================================================================

Chris: "I don't see anything about the kernel algorithm there that would suggest it is not
differentiable.  Remember, scratch memory results in implicit kernel args — so if you think of
the signature as (scratch-A-tile scratch-B-tile scratch-C-tile A B &out C), what's the problem?"

Correct framing, and there was no problem with the kernel.  My skip reason described a SYMPTOM
("resolves extents~ against a FLOAT") that I had never actually diagnosed.  Diagnosing it found
two separate bugs.

BUG A — FIXED.  An adjoint-NAME COLLISION.  `%handle-single-value-backward` tested the
record-ACCESSOR clause before the gradient-inert skip list.  `extents~` ends in a tilde, so
%is-accessor-p claimed it and %handle-accessor-backward minted a SCALAR adjoint for its source.
On a scratch tile that scalar `<tile>_ADJ` collided with the TENSOR `<tile>_ADJ` from
scratch-adj-bindings, and because Crisp's LET is let*-like the scalar (bound second) SHADOWED
the tensor:

    (C-TILE_ADJ 0.0)                                  <- scalar, shadows the matrix
    (SET! C-TILE_ADJ (+ C-TILE_ADJ %ANF-T-1_ADJ))

Every later `(~ C-TILE_ADJ i j)` then indexed a float.  It hit ANY differentiable kernel reading
a scratch tile's extents — every tile-stride matmul, since the expansion reads extents~ to size
the grid.

The FIRST fix attempt was to hoist the skip clause to the top of the cond.  That cost 11 specs
(101/05, 101/06, 031/05 — record-field adjoints like PA_X_ADJ went missing), because the skip
predicate also matches mangled sub-function names the later clauses need to see.  The shipped
fix guards only the accessor clause.

BUG B — FILED AS 037, NOT FIXED.  With the crash gone the kernel COMPILES — and returns a
gradient of exactly **0.0** while the finite difference correctly gives 0.06.  A backward kernel
replays the forward's BINDINGS but not its STATEMENTS: `make-scratch-matrix` is a binding so the
tiles exist, but `load-tile-at`, which FILLS them, is a statement and is never replayed.  The
staged tiles are EMPTY in the backward, so dA — which needs B's primal values — reads zeros.

Bisected, and the bisection is what identifies it:
  tile->tile scalar OVERWRITE .................... 2.0 exact
  tile->tile scalar ACCUMULATE ................... 2.0 exact
  THREE nested loops, ONE tile operand ........... 8.0 exact
  TWO tile operands (a real matmul) .............. 0.0 WRONG
Only the last needs the OTHER operand's primal value; with a constant multiplier none is
required, which is exactly why every pre-existing AD-over-tiles spec passes.

145's MMA path never hit this because its VJP reads the ORIGINAL GLOBAL operands at their
load-tile-at origins rather than the staged tiles — a workaround adopted there for this very
reason.  The scalar path has no equivalent.

**135/01, 135/02 and 135/10 therefore stay SKIPPED.**  They compile now, which makes them look
differentiable; they are not.  Un-skipping them would have turned a loud failure into a silently
wrong gradient in a green suite — the single most valuable thing the numeric check bought here.
Spec `14-scratch-tile-matmul-vjp` is kept as the record, with its VERIFY-AUTODIFF commented out
and the measured wrong value written down.

Suites after both changes: E2E 944/944, --differentiate 944/944, unit 253/253, negative 211/211,
145 at 14/14 with four numeric gradient checks.
