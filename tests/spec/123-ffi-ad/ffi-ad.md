In the 122-ffi endeavor we added Foreign Function Interface (FFI) support to Crisp.
But it does not support any sort of Auto-Differentiation and its tests all skip the --differentiate pass.

In this 123-ffi-ad endeavor, we'll be extending the Crisp A|D system to include FFI.

Reminder: The Crisp A|D system DOES differentiate integer arguments as well. It promotes their
gradients to floats (and 64-bit ints to doubles). The Crisp A|D system is "mathematically correct",
much more so than JAX or other systems. We'll want to preserve that.


The Syntax
==========

```
old: (def-foreign-function <some_c_name> <some_crisp_signature>)
new: (def-foreign-function <some_c_name> <some_crisp_signature> &optional <some_backward_function_name>)
```

The user defines that backward function as an ordinary `def-function` in Crisp, and it must have a
very specific signature (mechanically derived from the forward signature — see below). When the FFI
function is called from inside a `--differentiate` kernel, the compiler routes the backward pass
through the named function.


=====================================================================
PLAN & DECISIONS (2026-06-24) — agreed with Chris after vetting the Gemini
discussion against the actual codebase. This section is the source of truth;
the original Gemini transcript has been removed (it was sound in spirit but used
fictional Crisp constructs and a couple of wrong type rules).
=====================================================================

### Key realization: the user's backward IS a hand-written `_GRAD` companion

Crisp already has a complete machinery for differentiable sub-functions. When a normal `def-function`
is differentiated, the compiler auto-generates a `<NAME>_GRAD` companion and registers it in
`*differentiable-functions*` with this convention (see `%generate-backward-companion-ast-body` and
`%emit-sub-fn-backward` in `src/autodiff.lisp`):

```
companion params  =  primals  ++  seed-per-return  ++  [&out tensor-grad-out (_GRAD) cells]
companion returns =  one delta per differentiable scalar input, in order
```

That is *exactly* the VJP convention. So FFI-AD does NOT get a parallel ABI. Instead:

  A foreign function with a user-supplied backward is registered into `*differentiable-functions*`
  with `:bkwd-name` = the user's function, and the EXISTING sub-function backward machinery
  (`%handle-sub-fn-call-backward` → `%emit-sub-fn-backward`) drives it for free.

The forward-pass codegen of the foreign call is unchanged (122 already emits the external decl +
call). A|D only adds the backward routing.

### Decisions

1. **Register the named backward** in `*differentiable-functions*` and ride the existing
   sub-function backward path. No bespoke FFI VJP code path.
2. **Scope**: active-memory *returns* (a foreign fn that returns a `voidp`/buffer that participates
   in diff) are DEFERRED to a later pass. First passes are scalar-only, then pointer-input + shadow.
3. **Shadow sourcing for pointer inputs**: a `voidp`/`c-pointer` argument carries no shape metadata
   (unlike a tensor, which owns a `_GRAD` cell). In practice such a pointer is produced by
   `(base-ptr~ <storage>)`. The compiler routes the shadow as `(base-ptr~ <storage>_GRAD)` — the
   base pointer of that storage's gradient cell. This is the one genuinely new bit of plumbing.

### Corrections to the earlier (Gemini) writeup

- **Not "universally float".** Seeds and adjoints follow `%promote-to-float-adjoint`: `float`→`float`,
  small int→`float`, but **`long`/`ulong`→`double`**. The seed for a `long` return is a `double`.
  (The *returned* grad slots in the existing sub-fn ABI are uniformly `float`, which is why
  Gemini's "returns are float" happens to match — but seeds are not.)
- **No `voidp`/`handlep` keywords as Gemini wrote them.** Real Crisp: `voidp` is an alias for
  `(c-pointer :address-space :generic)`; a handle is `(c-handle <held-ptr-type>)`. Handles are
  treated as passive (non-differentiable) in the seed/shadow/return phases.
- **Implementation reality the abstraction hid**: pointers have no shape; see decision 3.

### Integration points (for when we implement)

- `def-foreign-function` macro: add `&optional bkwd`. (Macros can't be late-bound via overlay, so this
  one small edit is a patch Chris applies; `register-foreign-function` is a defun and can ride the
  overlay.)
- `register-foreign-function`: when `bkwd` is supplied, also register an entry in
  `*differentiable-functions*` (`:bkwd-name`, `:n-float-params`, `:n-return`, pointer-arg indices for
  shadow routing).
- Backward walk: confirm `%emit-sub-fn-backward` handles the pointer-shadow args sourced from
  `base-ptr~`/`_GRAD` (the tensor case already does an analogous `<arg>_GRAD` append; pointers need
  the base-ptr~ indirection).
- Negative test: calling an FFI function with NO registered backward inside a `--differentiate`
  kernel must error cleanly (today these tests `SKIP-WITH[--differentiate]`).


The VJP Signature Rule (vetted)
===============================

When you call a foreign function inside a `--differentiate` kernel, the compiler cannot see inside the
C black box, so you must supply its backward pass — a Vector-Jacobian Product (VJP) — as the third
argument to `def-foreign-function`. The compiler mechanically derives the VJP's required signature
from the forward signature; your `def-function` must match it exactly.

Type categories:
- **Active scalars** — `int`, `float`, `long`, etc. Differentiated; gradients promoted
  (`int`/`float`→`float`, `long`/`ulong`→`double`).
- **Active memory** — `(c-pointer ...)` / `voidp`. Differentiated via shadow buffers.
- **Passive** — `(c-handle ...)`. Ignored in every gradient phase.

**VJP inputs** (appended strictly in this order):
1. **Primals** — the exact original forward arguments.
2. **Seeds for active returns** — if the forward returns an active scalar, append its gradient seed
   (promoted type). (Active-memory returns are out of scope for now.)
3. **Shadow pointers for active-memory inputs** — for each pointer argument, append a shadow pointer
   into which the VJP accumulates that buffer's gradient.

**VJP outputs**:
- One gradient per active **scalar** input, in forward order. (Promoted: `float`, or `double` for
  64-bit primals.) Pointer-input gradients are written through the shadow pointers, not returned.

> Crisp does not trivialize integers. An `int` primal still demands a returned `float` gradient; a
> `long` primal a `double`. The compiler's signature generator is blind to semantics — even a
> logically-zero gradient (e.g. a buffer `size`) must be returned as `0.0` to keep the ABI sound.


Signature mapping examples
==========================

| Forward FFI signature                                | Derived VJP signature                                                      |
|------------------------------------------------------|-----------------------------------------------------------------------------|
| `#'(float float => float)`                           | `#'(float float  float  => float float)`                                    |
| `#'(float int => int float)`                         | `#'(float int  float float  => float float)`                                |
| `#'(float => long)`                                  | `#'(float  double  => float)`  ← long-return seed is **double**             |
| `#'(float int voidp (c-handle ptr-t) => int)`        | `#'(float int voidp (c-handle ptr-t)  float  voidp  => float float)`        |
| `#'(float int voidp (c-handle ptr-t) => nil)`        | `#'(float int voidp (c-handle ptr-t)  voidp  => float float)`               |
| `#'(float int (c-handle ptr-t) => voidp)`            | DEFERRED (active-memory return)                                             |

Reading the fourth row: primals `float int voidp handle`; one `float` seed for the `int` return;
one `voidp` shadow for the `voidp` input (the handle is passive, no shadow); returns `float float`
for the `float` and `int` inputs.


User Docs (draft — Chris will crib into the design doc)
=======================================================

## Automatic Differentiation over the FFI Boundary

To use a foreign function within a differentiated kernel, provide its backward pass as the third
argument to `def-foreign-function`. The compiler derives the required signature of that backward
function from the forward signature using the VJP rule above.

### Example 1 — A transcendental, no buffers

A foreign C function computing `sin`:

```c
/* libmath.c */  float c_sinf(float x) { return sinf(x); }
```

Forward: `y = sin(x)`. Backward (chain rule): `dx = dy * cos(x)`.

Forward FFI signature `#'(float => float)` derives VJP signature `#'(float float => float)`:
primal `x`, seed `dy`, returns `dx`.

```lisp
;; Declare the foreign function and name its backward.
(def-foreign-function c_sinf #'(float => float) c-sinf-bwd)

;; The backward is an ordinary def-function whose signature matches the derived VJP.
(def-function c-sinf-bwd ((x float) (dy float))
  (declare #'(float float => float))
  (* dy (cos x)))                       ;; dx = dy * cos(x)

;; Now c_sinf is differentiable wherever it is called from a --differentiate kernel.
(def-type cell-f (cell float :address-space :global))

(def-kernel use_sinf (x &out y)
  (declare #'(float &out cell-f))
  (set! (~ y) (c_sinf x)))
```

A two-input forward (e.g. `#'(float float => float)`) is identical in shape: the VJP takes both
primals plus the seed and returns both partials in order — `#'(float float float => float float)`.

### Example 2 — A buffer op with shadow accumulation (the aggressive case)

A foreign C function applies `sin` elementwise over a global buffer:

```c
/* libvec.c (OpenCL for spv / CUDA for ptx) */
void c_vsin(int n, __global const float *in, __global float *out) {
  for (int i = 0; i < n; ++i) out[i] = sin(in[i]);
}
```

Forward FFI `#'(int (c-pointer :global) (c-pointer :global) => nil)` derives VJP
`#'(int (c-pointer :global) (c-pointer :global) (c-pointer :global) (c-pointer :global) => float)`:

- **Primals:** `n`, `in`, `out`
- **Seeds:** none (`=> nil`)
- **Shadows:** `shadow-in` (for `in`), `shadow-out` (for `out`) — one per pointer input, in order.
  The shadow of the *output* buffer carries the incoming downstream gradient; the shadow of the
  *input* buffer is where we accumulate.
- **Returns:** `float` — the gradient for the scalar `n` (semantically 0).

```lisp
(def-type fvec (vector float :address-space :global :align :compact))

(def-foreign-function c_vsin
  #'(int (c-pointer :global) (c-pointer :global) => nil)
  c-vsin-bwd)

;; VJP: shadow-in[i] += shadow-out[i] * cos(in[i]) ; return 0.0 for n.
(def-function c-vsin-bwd ((n int)
                          (in        (c-pointer :global))
                          (out       (c-pointer :global))
                          (shadow-in  (c-pointer :global))
                          (shadow-out (c-pointer :global)))
  (declare #'(int (c-pointer :global) (c-pointer :global)
              (c-pointer :global) (c-pointer :global) => float))
  (let ((vin  (marshall-vector in         n fvec))
        (vsi  (marshall-vector shadow-in  n fvec))
        (vso  (marshall-vector shadow-out n fvec)))
    (dotimes (i n)
      (set! (~ vsi i)
            (+ (~ vsi i) (* (~ vso i) (cos (~ vin i)))))))
  0.0)                                    ;; gradient for the int primal n
```

**Automatic shadow routing.** The user's kernel never threads shadow pointers manually. It calls the
forward function normally, passing buffer base pointers:

```lisp
(def-kernel use_vsin (n in &out out)
  (declare #'(int fvec &out fvec))
  (c_vsin n (base-ptr~ in) (base-ptr~ out)))
```

When differentiating, the compiler sees that `(base-ptr~ in)` / `(base-ptr~ out)` come from
differentiable tensors and supplies `(base-ptr~ in_GRAD)` / `(base-ptr~ out_GRAD)` as the matching
shadow arguments — the base pointers of those tensors' gradient cells. The mechanical ABI lets the
graph route the gradients blindly while the actual accumulation happens inside the VJP.


TDD Test Ladder
===============

Build `.bc` per target as in 122 (OpenCL `__global` for spv, CUDA/plain for ptx). Use the five
challenge signatures as the backbone of the signature-derivation coverage, plus:

**HARNESS PREREQUISITE (first implementation task).** FFI specs route exclusively
through `run-spec-ffi-runs`, which today is forward-only: it hardcodes the binary
args to `--ir-target` + `--log-level` (NOT forwarding the global `--differentiate`
flag), skips hoist under `--differentiate`, and never reaches the VERIFY-AUTODIFF
pass. So none of the AD tests below can be *driven* yet.

Fix (no new directive): make `run-spec-ffi-runs` honor `*compile-differentiate*`,
exactly like the non-FFI path does — when set, add `--differentiate` to the binary
invocation and run the VERIFY-AUTODIFF pass with the `.bc` linked. The suite is run
under `--differentiate` by CI; the 122 specs opt out via `SKIP-WITH[--differentiate]`
(skipped at parse time, before the FFI branch), while 123 specs lack that skip and
so fall through to the FFI path and get differentiated.

**Pass 1 — scalar only** — IMPLEMENTED & GREEN 2026-06-24 (full suite 771/771 both
forward and `--differentiate`). Implementation: `def-foreign-function` gained the
optional backward arg (src/macros.lisp); `register-foreign-function` +
`%register-foreign-backward` + `%ffi-active-scalar-param-p` wire the VJP into
`*differentiable-functions*` (src/compiler.lisp); `run-spec-ffi-runs` now forwards
the global `--differentiate` flag and expects `<name>_grad.<type>` (tests/run-specs.lisp).
The existing sub-function backward machinery (`%handle-sub-fn-call-backward` →
`%emit-sub-fn-backward`) drives everything — no new backward-walk code.
- [x] `01-ffi-cube-scalar` — `#'(float => float)`. IR verified: backward kernel reads
      seed from `y_grad`, calls `@c_cube_bwd(x, dy)`, routes delta to `x_grad`.
- [x] `02-ffi-wmul-two-input` — `#'(float float => float)`. IR: `@c_wmul_bwd(a,b,dy)`
      returns `{float,float}`, both partials in forward order.
- [x] `03-ffi-int-promote` — `#'(int => int)`. IR: `@c_idbl_bwd(i32 primal, float seed)`
      → float delta. Integer differentiation across FFI confirmed (n-active-scalars
      counts ints, unlike the sub-fn `%count-differentiable-contributions`).
- [~] `04-ffi-long-return` — `#'(float => long)`. SKIP-WITH[--differentiate]. DISCOVERED
      GAP: a `long` foreign result's adjoint is typed `float` by the AD machinery
      while its grad cell is `double` → "Expected FLOAT but inferred DOUBLE". Reproduces
      with a trivial VJP body AND (independently) with a long output cell — so it's a
      broader long/double **output-adjoint** gap, NOT the FFI VJP wiring. Forward FFI
      path still verified. Needs its own endeavor; the double-seed promotion rule in the
      docs remains correct (it rides `%promote-to-float-adjoint` once outputs support it).
- [x] `errors/01-no-backward` — FFI call with NO backward inside `--differentiate` →
      "Function C_CUBE is not differentiable". Pattern: TEST-EXPECT: PASS +
      FAIL-WITH[--differentiate] (no FFI-LINK; error fires in the backward walk before
      linking, so the normal runner drives it — like 080-advanced-ad/errors).
- [x] `errors/02-mismatched-vjp` — backward whose signature mismatches the derived VJP
      → "No matching function overload found for 'C-CUBE-BWD'". Same pattern.

**Negative-test mechanics (resolved 2026-06-24).** The error-spec runner
(run-error-specs.lisp) is forward-only, no `--differentiate`, no `.bc`, and keys on
`;; CHECK-FAIL:` (whose substring IS asserted). So it suits front-end errors only.
For `--differentiate` negatives, DON'T use TEST-WITH[--differentiate] — use
`TEST-EXPECT: PASS` + `FAIL-WITH[--differentiate]: "..."`. `expect-failure` is computed
once per file from the active GLOBAL flags (run-specs.lisp ~L2091); CI runs the suite
forward then `--differentiate`, so the two passes check both expectations. TEST-WITH
would instead append a differentiate run DURING the forward pass, which fails while the
expectation is still "pass" → miscounted. (Note: FAIL-WITH's message is documentation —
the normal runner only flips the expectation, it does not assert the string; CHECK-FAIL
does assert it.)

**Bonus — 122 (basic FFI) negatives** (were missing): added
`122-ffi/errors/01-unknown-type-in-sig` ("Unknown type 'FLORP'.") and
`02-call-arity-mismatch` ("No matching function overload found for 'MY_ADD'"). Both are
front-end errors needing no `.bc`, run by the error-spec runner (CHECK-FAIL).
NOTE: a foreign signature that DISAGREES WITH THE .bc (e.g. Crisp says `float` but the
symbol is `int`) is NOT caught at Crisp-compile time — the `.bc` is matched by name at
LLVM link; a type disagreement surfaces (if at all) as an LLVM linker/verifier error on
the ptx/spv target, not a clean Crisp diagnostic. Possible future enhancement.

Suite after negatives: 775/775 forward & --differentiate; error-spec 183/183.

**Pass 2 — pointer input + shadow routing** — IMPLEMENTED & GREEN 2026-06-24.
The genuinely-new code. Mechanism:
- `%register-foreign-backward` now stores `:active-scalar-indices` and
  `:pointer-param-indices` (src/compiler.lisp; new predicate `%ffi-pointer-param-p`).
- New dynamic map `*ffi-baseptr-src*` (src/autodiff.lisp), built in
  `generate-backward-walk` from `(t (base-ptr~ src))` ANF bindings: pointer-temp → source storage.
- New `%emit-foreign-backward` emits `(BKWD primals... seeds... shadows...)` where each
  shadow = `(base-ptr~ <src>_GRAD)`, and accumulates the returned deltas ONLY into the
  active-scalar args (skipping pointer/handle positions by index). Foreign calls now route
  here from `%handle-sub-fn-call-backward`, the multi-value branch, AND a new VOID-statement
  branch (a `=> nil` foreign call was previously misparsed as a multi-value binding and
  silently dropped — that was the core bug).
- [x] `05-ffi-buffer-shadow` — `#'(int (c-pointer :global) (c-pointer :global) => nil)`,
      c_vsq (out=in^2). IR verified: `use_vsq_grad` calls
      `c_vsq_bwd(n, base-ptr(in), base-ptr(out), base-ptr(in_GRAD), base-ptr(out_GRAD))`,
      return → n's adjoint. Realistic VJP body marshals the raw shadow pointers
      (contiguous, length n) and does `shadow_in[i] += shadow_out[i] * 2*in[i]`. Passes the
      harness forward AND `--differentiate` (ptx + spv) with the `.bc` linked.
      (On-metal VERIFY-AUTODIFF for buffer FFI awaits FFI+VAD harness integration.)

**Pass 3 — handles passive** — IMPLEMENTED & GREEN 2026-06-24.
A `(c-handle ...)` param is neither an active scalar nor active memory, so it lands in
NEITHER index list → no seed, no shadow, no returned gradient. Also: `make-c-handle` /
`get-pointer` / `c-pointer` / `c-handle` added to `%backward-skip-fn-p` (gradient-inert).
- [x] `pass3-handle-passive.unit.lisp` — registers `#'(float int (c-pointer) (c-handle) => int)`
      and asserts active-scalar-indices=(0 1), pointer-param-indices=(2); the handle (3) is in
      neither. Real gate (raises on Parachute failure; verified it fails when broken).
  KNOWN GAP (separate endeavor): using a handle IN a differentiated kernel is blocked because
  `make-c-handle`'s `(c-pointer ...)` type argument is ANF-flattened during backward-kernel
  regeneration and rejected as "Unsupported form 'C-POINTER'". The VJP passivity ABI (verified
  by the unit test) is independent of this; the fix lives in anf-transform/analysis, not FFI-AD.

**Deferred**
- [ ] active-memory returns (`=> voidp` seed pointer) — revisit when a real use case lands.
- [ ] `04-ffi-long-return` (long/double output-adjoint) — separate AD gap (see Pass 1).
- [ ] make-c-handle under `--differentiate` (Pass 3 known gap above).
- [ ] on-metal VERIFY-AUTODIFF for FFI (needs the VAD pass to link the `.bc`).

Final state 2026-06-24: Pass 1+2+3 complete. Suite 776/776 forward & --differentiate;
error-spec 183/183. ci-stop `123-ffi-ad`.
