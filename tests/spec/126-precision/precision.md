Precision: ieee vs fast
===================================
- [x] Precision KEYS: `ieee` | `fast`  (pass 1: per-instruction FMF on FP ops; default :ieee)
- [ ] `(with-precision (<KEY>) ...)`
- [x] `(declaim (precision <KEY>))`  (pass 4 DONE 2026-07-02: first declaim in the language; %process-declaim intercepts it in visit-toplevel-form (before CL's declaim/proclaim); file-level, sets *math-precision* unless force-locked. Precedence force > declaim > math wired by splitting force/math (no longer pre-resolved) through initialize-compiler (:force-math-precision) + runner + CLI, with new *force-math-precision*. Specs 11 (declaim fast > math ieee), 12 (declaim ieee > math fast), 13 (force ieee > declaim fast) green; IR-verified declaim drives FMF with no flags; regression 803/803 both ways, 253 unit, 183 neg.)
- [x] `--math-precision`  (pass 2 DONE 2026-07-02: flag + `force > math` precedence — parsing landed with pass 1; specs 03/04 (fast/ieee) + 05/06 (precedence both directions) green; suite 796/796)
- [x] `--force-math-precision`  (pass 1 DONE 2026-07-02: codegen + runner + binary CLI + warning; specs 01/02 green, full regression 792/792 both ways, 252 unit, 183 neg)
- [ ] DEFAULT precision stays :ieee (nvcc/clang style, fast opt-in). Decided 2026-07-02 after measuring fallout: default :fast breaks the whole numerical-correctness layer (HOIST-EXPECT exact output — 07-struct-with-ct got 12 vs 7 on BMG; VERIFY-AUTODIFF finite-difference). Also flagged: that 7->12 may be an IGC fast-math miscompile on BMG — investigate when verifying the fast path on metal.
- [ ] AD × precision tests must cover BOTH precision modes: `fast` AND `ieee`, and for each denormal handling `ftz` | `preserve`. (Vehicle: div + sqrt, per the AD-interaction section.)
- [x] `--denormal-handling [ftz | preserve]`  (pass 3 DONE 2026-07-02: `denormal-fp-math`(+`-f32`) attribute stamped on every function via ensure-opencl-kernel-metadata; default :preserve; `fast`+`preserve` warning; CLI + runner + validators; specs 07/08 green; regression 798/798 both ways, 253 unit, 183 neg. SPV EXECUTION MODE DONE 2026-07-02: %emit-spirv-denorm-execution-mode emits `!spirv.ExecutionMode {kernel, 4460|4459, 32}` per entry point (ftz=DenormFlushToZero, preserve=DenormPreserve); spike-proven the translator emits the SPIR-V ExecutionMode + Capability; new binding llvm-add-named-metadata-operand; suite still 798/798 (llvm-spirv accepts it on all kernels). Robustified a brittle DWARF unit-test exact-line match along the way. ON-METAL DONE 2026-07-02: added HOIST-DENORMAL directive (passes --denormal-handling into a TEST-HOIST run) + specs 09/10 with a non-folded runtime subnormal ((gid+1)*1e-20 squared = 1e-40, scaled back in two 1e20 steps). 10-preserve RUNS ON THE BMG and confirms DenormPreserve + the hoist pipeline (res ~0.999995). **KEY FINDING: the BMG / Level-Zero stack does NOT flush f32 denormals even under DenormFlushToZero — both modes returned ~1 on metal.** The compiler emits the correct SPIR-V (spike-proven), but Intel Xe/L0 compute preserves f32 subnormals regardless (matches the Gemini caveat). So the flush can only be *demonstrated* on NVIDIA: 09-ftz is TEST-HOIST[CUDA] (expect res:0), SKIPs locally. CONFIRMED on RunPod 2026-07-02 (RTX PRO 4000 Blackwell, CUDA 12): same GPU, same kernel — ftz -> res:0 (flushed), preserve -> res:0.999995 (preserved). The flag demonstrably controls the flush on NVIDIA; PTX path (denormal-fp-math-f32 -> .ftz) works end-to-end. Suite 800/800.
- [ ] update ideal_001.md with rule about using libdevice.10.bc when using transcendentals with PTX. 
- [ ] update ideal_001.md with FTZ and SPIR-V "bubble up"  behavior 
- [ ] auto differentiation?  (let's deal with transcendentals in our NEXT endeavor, not now, or maybe just one now "sin" ?)
- [ ] update docs with 'ieee' being default, not 'fast'.  and 'preserve' default for denormals


Now that we have FFI support, we should be able to support Crisp's precision controls.

There are two forms and three flags.  The documentation for them is below.

IIRC, the file level `declaim` has not been introduced yet, so this will be its first introduction, and `precision` will, at this time, be it's only supported directive.

My initial thought is that we should proceed in the reverse order as the checkboxes above. Meaning, first we do the tests and implementation for `--force-math-precision` and its two values (`ieee` and `fast`). Can we test these options with just the regular spec validators, or will we need to expand the spec runner? We'll want tests/validaotrs for confirming the three states (`ieee`, etc).  What would be good tests for those?


 Then we do `--math-precision` (and the case where both flags are used and the `force` variant overrides).

 Then we do the `--denormal-handling` flag. Implementation-wise, this is orthogonal, but 
 it WILL have an effect on the math results and should be measurable in by our validators. 


Followed by `declaim` and `(declaim (precision <KEY>))`, and their tests. And them combined with `--math-precision`, `--denormal-handling`, both  and finally combined with the force variant.

And finally, the `with-precision` form, and combined with all earlier variants.

So that's five passes, each with their own tests, plus combinations with other forms/flags. 

That's quite a bit of testing, but hopefully we'll be able to reuse the validators.


Pass plan — refinements (agreed 2026-07-01)
-------------------------------------------
The five-pass order is right; reverse order is deliberate (force overrides everything, so it
has zero precedence interactions and lets the machinery land in the simplest driver).
Refinements to the burden model:

- **Pass 0 — foundation + spikes (do FIRST).** Before pass-1 tests: add the attribute bindings
  (`LLVMCreateStringAttribute` / `LLVMAddAttributeAtIndex`), build the precision→IR mapping, and
  run the two SPV spikes. One spike can change the whole codegen approach: if a FUNCTION-level
  fast-math attribute does NOT reach SPV `FPFastMathMode` (only the per-instruction flag did in
  the 2026-07-01 experiment), then even whole-kernel `fast` on SPV needs per-instruction FMF.
  Learn that on day one.
- **Burden is a barbell, not a ramp.** Pass 1 carries the codegen foundation (heaviest
  foundational). Pass 5 carries per-region FMF + per-REGION validators + AD region-scoping + the
  full precedence stack (heaviest scoping). Passes 2–4 are lighter (precedence + one new axis +
  the declaim feature).
- **Pass 3 (denormal) also owns:** the SPV `DenormFlushToZero` emission (our translator doesn't
  emit it from the attribute), and the `fast`+`preserve` WARNING. `fast` ⇒ `ftz` is our policy;
  `fast`+`preserve` warns, never silently flushes.
- **Pass 4 (declaim)** introduces a new language feature (first `declaim` ever) — parser/infra
  cost, not just permutations.
- **Split pass 5:** 5a = `with-precision` forward; 5b = `with-precision` × AD (the single hardest
  thing; needn't block 5a).
- **Permutations stay additive.** `--denormal-handling` is flag-only (no declaim/with-precision
  form), so it does NOT cross-multiply the precision-source matrix; the only interaction is the
  one `fast`+`preserve` warning.
- **Reusable validator.** Write pass-1 validators as `assert-precision-mode(<fn-or-region>,
  <expected>)` over the IR; later passes add a kernel + an expectation row and reuse the checker
  (per-region checking in pass 5 needs the more sophisticated variant).
- **Precedence to pin down + test as a matrix:** `--force` > `with-precision` > `declaim` >
  `--math-precision`. The non-obvious one — force beats even the most-specific `with-precision` —
  gets a dedicated pass-5 test (all four sources present → force wins).




PTX and Transcendentals
------------------------
On the PTX target, if a kernel uses an operation that has no IEEE-precise native PTX instruction (i.e. a transcendental) under `ieee` (precise), and libdevice.bc isn't on the path, that's a compile error. Pure arithmetic + div + sqrt in `ieee` compiles fine without it. Subnormal handling is orthogonal (the `--denormal-handling` axis) and doesn't affect this rule.

**How it's wired (PTX).** For a precise transcendental we link `libdevice.10.bc` into the
LLVM module (the same `.bc`-linking the FFI work built) and run LLVM's `NVVMReflect` pass
with `__CUDA_FTZ` = 0 (preserve) or 1 (flush) — driven by the orthogonal `--denormal-handling`
axis, not the `ieee`/`fast` precision key; the optimizer specializes the libdevice
body and the NVPTX backend lowers it to native PTX. All of this happens at *our* compile
time, at the LLVM-IR stage — the emitted `.ptx` is self-contained, so the user's ptxas /
driver need nothing special. The user's only obligation is that `libdevice.10.bc` be on the
path when *Crisp* compiles (exactly like any FFI `.bc`). Because we keep div/sqrt native
(`div.rn`/`sqrt.rn`), we never route them through libdevice, so `__CUDA_PREC_DIV` /
`__CUDA_PREC_SQRT` are moot — `__CUDA_FTZ` is the only reflection knob that matters.
TODO: confirm our pipeline actually runs `NVVMReflect`, and how it takes the flag in our LLVM
version (module flag `nvvm-reflect-ftz` vs the older `-nvvm-reflect-list`).


SPIR-V precision affordances (verified 2026-07-01)
--------------------------------------------------
Hand-checked by translating a crafted `.ll` (`fmul fast`, `fadd contract`, denormal attrs)
through our bundled `bin/llvm-spirv.exe --spirv-text`:

| Affordance                    | LLVM input                       | SPIR-V output                       | Status |
|-------------------------------|----------------------------------|-------------------------------------|--------|
| Per-op fast-math              | `fmul fast`                      | `Decorate <id> FPFastMathMode Fast` | ✅ translates |
| Disable FMA fusion (`ieee`)   | plain `fadd` (no `contract`)     | `ExecutionMode <ep> ContractionOff` | ✅ translates |
| Subnormal flush (`--denormal-handling=ftz`) | `denormal-fp-math`=`preserve-sign` | (nothing emitted) | ⚠️ NOT translated by our llvm-spirv |

So `fast` and `ieee` (contraction control) work today from ordinary LLVM flags. The subnormal
preserve↔flush distinction does NOT survive our translator: it ignores the `denormal-fp-math`
attribute (tried `denormal-fp-math` and `-f32`), and this build lacks `SPV_KHR_float_controls2`.

The affordance exists end-to-end in principle — SPIR-V has `OpExecutionMode DenormFlushToZero
<width>` / `DenormPreserve <width>` (via `SPV_KHR_float_controls`), and Intel Xe hardware
honors it via CR0 FTZ/DAZ bits set by IGC's thread prologue. The gap is purely in the
LLVM→SPIR-V translation step. Note: on the Vulkan/graphics path Intel drivers default to
flushing f32 denorms, but on the **OpenCL / Level-Zero compute path Crisp uses**,
DenormPreserve is more likely honored (esp. PVC-class) — so the distinction is probably real
on our target, which makes closing the gap worthwhile rather than academic.
TODO (SPV subnormal flush): emit `OpExecutionMode … DenormFlushToZero 32` ourselves (post-process,
or a translator that supports it) rather than relying on the `denormal-fp-math` attribute.
Verify on the BMG whether preserve-vs-flush is actually observable for f32 before investing.


Auto-differentiation interaction
--------------------------------
Precision and AD are largely orthogonal (the chain rule is unchanged by instruction
selection), but they intersect in ways this endeavor must cover:

- **Test vehicle: div and sqrt.** Both are native on both targets (`div.rn`/`sqrt.rn` vs
  `div.approx`/`rsqrt.approx`), need no libdevice, AND are already differentiable
  (sqrt' = 1/(2√x), itself just div+sqrt). So they exercise the full precision × AD
  intersection without any transcendental machinery. Transcendentals — and their AD, since
  sin' = cos introduces a *second* transcendental — are **DEFERRED to the next endeavor**.
  Doing even "just sin" here would drag in the libdevice/reflect + OpenCL.std ext-inst +
  transcendental-AD subsystems all at once.
- **The backward kernel MUST inherit the forward's precision (and subnormal) mode** — a
  correctness requirement, not tidiness. The backward recomputes forward primals; if the
  forward ran `fast` while the backward recomputed `ieee`, the recomputed values wouldn't match
  what the forward produced, corrupting the gradient. For passes 1–4 both axes are kernel-level,
  so inheritance is trivial (stamp `_grad` with the same attrs); only the precision axis becomes
  per-region at pass 5. Test: a `fast` differentiable kernel's `_grad` must carry the same
  fast-math attrs.
- **Test scoping by precision key:**
  - `ieee`: full end-to-end — compile + `VERIFY-AUTODIFF` passes + `_grad` carries the same
    attrs. IEEE math makes finite-difference verification valid.
  - `fast`: require compile + a produced gradient, but do NOT gate on tight `VERIFY-AUTODIFF`
    numerical agreement. Fast-math deliberately trades accuracy (reassoc, approximate
    rcp/rsqrt), so finite-difference-vs-analytical is the wrong oracle at tight tolerance —
    loosen drastically or skip the metal FD check under `fast`.
- **The subnormal axis is AD-neutral.** Flush-vs-preserve only changes subnormal values, and AD
  test inputs are normal-range (x=3.0, etc.), so `--denormal-handling` makes no numerical
  difference to the FD check. Test it as its own axis (does the kernel / `_grad` carry the chosen
  subnormal mode), independent of the precision × AD matrix.
- **`with-precision` + AD is the hardest case** — a per-region precision inside a
  differentiated function means the backward must reproduce the same per-region scoping. It
  lands in the last pass (`with-precision`), alongside the hardest binding work
  (per-instruction fast-math flags). Passes 1–3 (whole-function precision) only need to stamp
  `_grad` with the same attribute.


Implementation notes (verified 2026-07-01)
-------------------------------------------
- **Spec runner — no redesign needed.** Reuse the `TEST-WITH[--runtime-checks]` pattern
  (`run-spec-runtime-checks-pass`: bind a dynamic flag → compile to IR string → hand
  `(file ir-string)` to a named validator). Add `*compile-math-precision*` /
  `*compile-force-math-precision*` + a precision dispatch in `run-single-spec-pass`, and
  precision validators that grep the IR (modeled on `validate-has-llvm-trap`).
- **Bindings — all present (confirmed 2026-07-01).** `llvm-bindings.lisp` had none of these
  yet, but `LLVM-C.dll` (LLVM 21) exports `LLVMCreateStringAttribute`, `LLVMAddAttributeAtIndex`,
  `LLVMSetFastMathFlags`, `LLVMGetFastMathFlags`, `LLVMCanValueUseFastMathFlags`. No version
  blocker — both levers (function string-attributes and per-instruction FMF) are available.
- **SPIKE RESOLVED (2026-07-01) — precision axis needs per-instruction FMF from PASS 1, not
  pass 5.** Function-level fast-math attributes (`unsafe-fp-math` etc.) do NOT reach SPV
  `FPFastMathMode` — only per-instruction FMF does (verified). So whole-kernel `fast` on SPV
  must set the `fast` flag on each FP op via `LLVMSetFastMathFlags`. FMF is foundational, not
  back-loaded; pass 5 (`with-precision`) reuses the exact same mechanism, just region-scoped
  ("all ops in scope" → "the ops in the region"). This means the reverse-order plan holds and
  the mechanism is uniform across passes — only the *set* of ops it's applied to narrows.
- **Denormal on SPV (pass 3).** Same shape: the `denormal-fp-math` attribute does NOT reach SPV.
  Likely path — attach `!spirv.ExecutionMode` named metadata (`DenormFlushToZero` /
  `DenormPreserve`) to the kernel so the translator emits the execution mode. Spike when we reach
  pass 3.
- **Codegen approach (settled).** Precision axis → per-instruction FMF on every FP op in scope
  (`LLVMSetFastMathFlags`; common path for both targets — PTX also honors function attrs, but
  FMF works everywhere). Denormal axis → `denormal-fp-math` function attribute (PTX) +
  `!spirv.ExecutionMode` metadata (SPV).




#### precision 📝

In addition to choice of variable type, Crisp has a precision control that supports two
different options: `fast` and  `ieee`.

With the `ieee` the compiler will choose instructions that guarantee IEEE 754 compliance.
For operations like division or square root, this might mean selecting a slightly slower
but fully precise instruction sequence. This is conditional on the GPU hardware providing
IEEE 754 conforming instructions.
This might also entail disabling automatic FMAD generation, and ensuring that denormalized
numbers are handled correctly (not flushed to zero).


With the `fast` precision option, the compiler will prioritize speed, selecting faster
but potentially approximate instructcions (like `rsqrt.approx`). It might use specific
low-precision instructions if available and appropriate.  
This will likely enable FMAD generation, allow "flush-to-zero" mode for denormal numbers.
Additionally, it might disable `Nan` and `Inf`.  

Consult the Crisp documentation for any particular target for a complete rundown.

#### selecting precision

Crisp provides three avenues for selecting precision. In order of specifity, 
from the least specific to the most specific, they are: 

| What                           |  Value           | Descripotion         |
|--------------------------------|------------------|----------------------|
| `--math-precision`             | `fast` or `ieee` | compilation flag     |
| `(declaim (precision <KEY>))`  | `fast` or `ieee` | per-file declamation |
| `(with-precision (<KEY>) ...)` | `fast` or `ieee` | in-function macro    |

If there are competing values for precision, the compiler will favor the MOST specific.

Example:
```
;; 1 
(declaim (precision fast))

;; 2  ... inside some function
    (with-precision (ieee)
        (/ important-divisor important-dividend))

;; 3 ... later
    (/ nobody-divisor nobody-dividend)
```
1. the file uses `declaim` to select fast precision
2. inside some function, the `with-precision` macro is used so the "important" division is highly accurate, regardless of any other setting.
3. the "nobody" division will use less accurate but fast division by virtue of the declaim in #1.
4. in the example above, the `--math-precision` flag would always be ignored. The `declaim` at file level 
would override.

##### overriding precision: `--force-math-precision` 📝

The `--force-math-precision` compiler flag can be used to override ALL other precision choices.
It will override the developers stated intent, and for that reason it should be avoided. This flag is intended for validation and testing purposes and should not be used as part of your release
cycle.  The compiler emits a warning whenever this flag is used. 