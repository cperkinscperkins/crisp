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

### 2. Shape algebra — the K-tile contract

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

Same number, opposite reasons. This is a **hard contract**: violating it is a compile
error naming the K-tile, the profile shape, and the required multiple. It is *not* silently
downgraded to a scalar-FMA fallback.

Consequence: `132/06-tiled-matmul` and `133/12-tiled-matmul-bmg` both use K-tile = 8 and
therefore **cannot** simply be un-skipped. New specs are needed. (See Testing, below.)

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

### 5b. Why there is no fragment-level backward

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

1. **K-tile contract is hard** — compile error, no silent non-MMA fallback for dB.
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
[/] P3b — **tile-level rule: `mma-accumulate-via-tile` backward.** IN PROGRESS 2026-07-28.
    Spec `06-via-tile-backward-bmg.crisp` (forward already MMA_CORRECT on metal; the
    `--differentiate` COMPILE-WITH is the red TDD test).
    - DONE: `%mma-ad-tile-dims-map` / `%mma-ad-tile-source-map` / `%mma-ad-transposed-stage` /
      `%mma-via-tile-backward` (+ a `-logged` wrapper — run with `--log-level=debug` to dump the
      emitted backward AST, which is by far the most useful artifact when this fails); the walk
      clause, spliced into `generate-backward-walk`; register-tile adjoint allocation
      (`%mma-ad-adj-init`, `%augment-scratch-adj-bindings`, the `scratch-adj-bindings`
      collection, and `MAKE-REGISTER-TILE` in `%backward-skip-fn-p`).
    - The emission is VERIFIED CORRECT (dumped and read by hand): all five temporaries carry
      the right shapes — dC 8x16, A^T 16x8, B^T 16x16, dA-acc 8x16, dB-acc 16x16 — with both
      GEMMs in the right operand order.
    - REMAINING, and precisely diagnosed. The forward `(store-tile C-tile C (0 0))` is rewritten
      by the endeavor-107 AD PRE-PASS (`%expand-stride-macros-in-form`, which runs only on the
      AD path) into a `store-tile-at` with element coords computed the SCRATCH way:

          (%STORE-TILE-AT-BWD C-TILE_ADJ C_GRAD
            ((* (TO-ULONG 0) (~ (EXTENTS~ C-TILE) 0)) ...))

      But `C-tile` is a REGISTER tile. Two faults from that one root cause: `extents~` is
      invalid on a register tile, and `C-TILE_ADJ` is SROA-exploded into per-fragment vars so
      the bare name no longer exists — hence "Unknown variable C-TILE_ADJ". The three fixes:
        1. the AD pre-pass must NOT expand a `store-tile` whose tile is a register tile;
        2. the walk's `store-tile` backward needs a register-tile branch that seeds the adjoint
           fragments from `C_GRAD` — which is exactly what P2's `load-fragment-acc` was built
           for, and where the fragment element->lane MAPPING finally becomes observable;
        3. a `%load-register-tile-acc` internal form + `%emit-per-frag-acc-load` in
           `%explode-rewrite-body-form` (the mirror of `%emit-per-frag-store`).
[ ] P3c — **raw `mma-accumulate` under `--differentiate` is a clear compile error**, naming the
    tile form as the differentiable surface. Negative spec.
[ ] P5 — **whole-kernel.** `store-tile`(register) backward + the K-loop + transposed SLM
    staging. A full tiled matmul differentiates end-to-end on one workgroup.
[ ] P6 — **on-metal verification.** `--mma-grad-test` in the hoist (host-computes dA/dB,
    prints `MMA_GRAD_CORRECT`), mirroring 134's `--mma-test`. L0/BMG first.
[ ] P7 — **PTX parity.** Index-math transposes, `mma.sync` backward, rented sm_80+ pod.
[ ] P8 — **multi-workgroup + atomics;** un-skip 135's `matrix-multiply-tile-stride`.
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
