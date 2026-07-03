Transcendentals
===============
- [x] across both precisions (ieee precise / fast → native_* SPV, __nv_fast_* PTX)
- [x] and both subnormal handling (nvvm-reflect-ftz on PTX; DenormFlushToZero mode on SPV)
- [x] and auto differentiation for each (Phase 1 + Phase 5 across the FP matrix, on BMG/L0)
- [x] error when transcendentals and ieee and no libdevice.bc when outputting PTX (Phase 4; %ptx-finalize-libdevice)
- [~] other errors? — the missing-libdevice error can't get an auto CHECK-FAIL (negative runner can't inject --ir-target=ptx); verified manually.


Ok, now that we've done FFI and precison controls, we are ready to expose the transcendental functions, and probably  include with them some of the other floating point operations (if not exposed already).

The main tricky bits here are for PTX if the precision is :ieee then the user needs to pass in the libdevice.10.bc file themselves to the crisp compiler.  And we'll want our run-on-pod.sh script to do the same.

Then, more trickiness is that these functions will need backwards functions written for them. The FFI system has an affordance for that. But what about when we AREN'T using the FFI?   So auto-differentiation support is definitely an important aspect.

And then there is the dreaded combination of "what does AD look like with flush to zero or fast precision?".  I don't even know the answer to that.


Phase 0 — spike findings (2026-07-02)
=====================================
Ran on the local BMG box (bundled `bin/llc.exe`, `bin/llvm-as.exe`, `bin/llvm-spirv.exe`)
plus a RunPod probe (RTX 4000 Ada, driver 550, CUDA 12.4, `libdevice.10.bc` present at
`/usr/local/cuda/nvvm/libdevice/`). Current state: `sin`/`cos` are the only two wired
(analyzer `def-unary-math-analyzer`, codegen `def-unary-math-codegen … "llvm.sin"`, AD rule
in autodiff.lisp). They compile+translate on SPV today; on PTX they crash llc (below).

**SPV — trivial.** All 11 intrinsics (`llvm.{sin,cos,tan,asin,acos,atan,exp,log,log2,pow,atan2}.f32`)
parse in LLVM 21 and translate cleanly to OpenCL ExtInst (`sin`…`atan2`) via our bundled
llvm-spirv. So the SPV forward path for every function is just the two macro registrations +
an AD rule — no fallback machinery. (Precision on SPV — precise ExtInst vs `native_*` vs FMF —
is the open Phase-2 question.)

**PTX — the real work, and messier than the design doc implies.**
- Plain `llvm.sin.f32` (ieee, no libdevice) **crashes** our bundled llc (nvptx backend,
  `0xC0000005` access violation). So PTX transcendentals must be intercepted/lowered *before*
  llc ever sees a bare intrinsic.
- With the `afn` fast-math flag, only `sin`/`cos` get a native `.approx.f32`. Everything else
  (`exp log log2 tan atan asin acos atan2 pow`) → *"no libcall available" / "Cannot select"* —
  llc cannot lower them without libdevice.
- Native hardware approx primitives confirmed to lower clean & libdevice-free: `sin.approx`,
  `cos.approx`, `ex2.approx`, `lg2.approx` (also rcp/rsqrt/sqrt). So a libdevice-free FAST path
  is possible *only by composing*: `exp = ex2(x·log2e)`, `log = lg2·ln2`, `log2 = lg2`,
  `pow = ex2(y·lg2 x)`, `tan = sin/cos`. The inverse trig (`asin acos atan atan2`) cannot be
  composed cheaply → they need libdevice even under `fast` (or hand-rolled polynomials).

Corrected PTX reality (per function × precision):

| precision | sin, cos              | exp, log, log2, pow, tan          | asin, acos, atan, atan2 |
|-----------|-----------------------|-----------------------------------|-------------------------|
| **fast**  | native `.approx` (no bc) | compose from ex2/lg2 (no bc) *or* `__nv_fast_*` | **libdevice `__nv_fast_*`** |
| **ieee**  | libdevice `__nv_*`    | libdevice `__nv_*`                | libdevice `__nv_*`      |

So the doc's "fast needs no libdevice" holds only for sin/cos (+ the composable set *if* we do
the composition work); the inverse trig always needs libdevice. **Open design fork (Phase 3):**
for `fast`, either (A) compose from primitives — libdevice-free for 7/11, more codegen, matches
the doc — or (B) just call libdevice `__nv_fast_*` uniformly — simpler, but then `fast` also
needs libdevice and the doc gets corrected. Leaning (B) for uniformity unless libdevice-free
`fast` is a hard requirement.

**Framing decision (was deferred to me): intrinsics on SPV, libdevice-symbol calls on PTX.**
Since PTX needs `__nv_*` *calls* (not intrinsics) for almost everything, PTX codegen is
essentially "emit a call to a libdevice symbol + link the .bc" — which is the FFI mechanism
under the hood. I'd implement it as *internal* codegen (not user-facing FFI) that reuses the
existing FFI `.bc`-linking plumbing (`link-foreign-bitcode` / `LLVMLinkModules2`). Not a new
user surface.

**Still unverified (needs the pod + `opt`/`llvm-link`, which the bundled bin/ lacks):** the
libdevice link + `NVVMReflect(__CUDA_FTZ)` mechanism itself. The pod is a CUDA *runtime*
container (no llvm-link/opt/nvcc on PATH). Deferred to Phase 4, where we wire the in-process
link (already done for FFI) and confirm NVVMReflect runs / whether llc's own nvptx pipeline
handles the reflect calls.


Refined phased plan (TDD)
=========================
Principle: do the locally-testable, high-confidence work first (SPV on BMG), batch the
RunPod-dependent PTX work, finish with the cross-cutting AD × precision matrix.

- **Phase 1 — SPV forward + AD, all 11 functions. DONE 2026-07-02.** 9 new functions wired
  (exp log log2 tan asin acos atan + binary pow atan2; sin/cos already existed): semantic node
  per fn (semantic.lisp), `def-unary-math-analyzer`/new `def-binary-math-analyzer` (ops.lisp),
  `def-unary-math-codegen`/new `def-binary-math-codegen` → `llvm.*` intrinsic (codegen.lisp),
  uniformity + `semantic-node-type`/`-source-location` etypecase cases + `%uni-analyze` op list
  (core.lisp), AD derivative rules in `%handle-math-and-trig-backward` + dispatch list + the
  `%active-scalar-vars` edge table (autodiff.lisp). Package plumbing: log2/pow/atan2 aren't CL
  symbols → interned/exported by crisp.compiler and imported into crisp-language (the other 8
  are cl-inherited). asin/acos derivatives use `pow(1-a²,-0.5)` (no sqrt op wired). Specs 01–11
  (`tests/spec/128-transcendentals/`), forward compile + `VERIFY-AUTODIFF` all green **on the
  BMG GPU** (incl. both partials of pow & atan2). Full regression 822/822 both ways, 253 unit,
  185 neg. ci-stop `128-transcendentals`. NOTE: SPV/default(ieee)-precision only so far — PTX +
  fast/precision variants are Phases 2–5.
- **Phase 2 — `fast` → OpenCL `native_*` on SPV. DONE 2026-07-02.** Under fast on SPV,
  transcendentals with a native variant (sin/cos/tan/exp/log/log2 + `powr` for pow) emit a
  call to the Itanium-mangled OpenCL builtin (`_Z10native_sinf`, …) instead of the `llvm.*`
  intrinsic; the LLVM→SPIR-V translator maps these to `native_*` OpenCL.std ExtInst — **but
  only when the module carries `!opencl.ocl.version`** (spike-proven: without it the mangled
  call becomes an imported OpFunctionCall → unresolved on L0). So `%emit-opencl-version-metadata`
  is injected in compile-to-spirv whenever `%module-uses-native-builtin-p`. asin/acos/atan/atan2
  have no native variant → precise ExtInst + FMF under fast. native is f32-only + SPV-only
  (f64 / PTX / no-variant fall back to precise, still FMF-stamped). Codegen macros now take an
  optional native-name and branch on `*math-precision*`/`*target-backend*`. Gotcha fixed: a
  `(return t)` in a helper hit the shadowed Crisp `return` (→ explicit-return) — use `some`.
  New `HOIST-PRECISION: fast|ieee` directive (mirrors HOIST-DENORMAL) forwards --math-precision
  to a hoist run. Spec 12-exp-fast-metal runs `native_exp` **on the BMG via L0** (res 2.71828).
  Regression 823/823 both ways, 253 unit, 185 neg. NOTE: pow→native_powr under fast requires
  base≥0 (document). Denormal-axis interaction with transcendentals: TODO (minor).
- **Phase 3 — PTX `fast`. DONE 2026-07-03 (hardware-verified).** Resolved fork = (B) reuse
  libdevice: under fast on PTX (f32), a transcendental with a fast variant emits libdevice's
  `__nv_fast_*f` instead of the precise `__nv_*f`. Spike-confirmed `__nv_fast_sinf` → `sin.approx.ftz.f32`
  (the .approx hardware path; ftz already driven by the nvvm-reflect-ftz flag from Phase 4).
  Fast variants exist for sin/cos/tan/exp/log/log2 + `__nv_fast_pow`; **asin/acos/atan/atan2 have
  no `__nv_fast_*`** → stay precise `__nv_*` under fast too. `%math-call-name` now 4-way:
  PTX-fast-f32 → __nv_fast_*; PTX → __nv_*; SPV-fast-f32 → native_*; else → llvm.*. Verified kernel
  `k` calls `__nv_fast_sinf` under fast vs `__nv_sinf` under ieee (atan `__nv_atanf` in both).
  **On-metal (RTX 2000 Ada):** fast (sin x) → __nv_fast_sinf → res 0.841471 = sin(1.0). Spec
  14-sin-fast-ptx-metal (FFI-LINK libdevice + HOIST-PRECISION fast + TEST-HOIST[CUDA]); the FFI
  harness now forwards --math-precision (HOIST-PRECISION bound in run-spec-ffi-runs). Regression
  825/825 both ways, 253 unit, 185 neg. Fast is libdevice-based (not the libdevice-free composition
  option A) — consistent with Phase 4, since PTX transcendentals need libdevice anyway.
- **Phase 4 — PTX transcendentals via libdevice. DONE 2026-07-03 (hardware-verified).**
  On PTX a transcendental is emitted as a libdevice `__nv_*f`/`__nv_*` call (all 11 got a
  `__nv_` base in the codegen macros via `%math-call-name`, gated on `*target-backend* = :ptx`).
  libdevice.10.bc is linked in-process (reusing the FFI `.bc` plumbing / `link-foreign-bitcode`;
  `FFI-LINK: $CUDA_HOME/nvvm/libdevice/libdevice.10.bc` supplies it in specs). `%ptx-finalize-libdevice`
  (in compile-to-ptx, post-link): (a) errors with a clear message if any `__nv_*` is still an
  undefined declaration (libdevice not linked), (b) sets the `nvvm-reflect-ftz` module flag from
  `*denormal-handling*`. **Spike-proven:** llc's NVPTX backend runs NVVMReflect automatically from
  that module flag — the 2217 `__nvvm_reflect` calls in the linked module → 0 in the PTX. Gotcha:
  `LLVMAddModuleFlag` takes the **C enum** (Override=**3**), not the IR encoding (4) the binding's
  comment lists — passing 4 made an Append flag → llc verifier error. **On-metal (RTX 2000 Ada, CUDA
  12.4):** `(sin x)` → `__nv_sinf` → libdevice → ptxas → nvcc-built driver host → **res 0.841471** =
  sin(1.0). Spec 13-sin-ptx-metal (FFI-LINK libdevice + TEST-HOIST[CUDA]). Missing-libdevice error
  verified manually (negative-runner can't inject --ir-target=ptx, so no auto CHECK-FAIL yet).
  Regression 824/824 both ways, 253 unit, 185 neg. NOTE: local (no `opt`) leaves libdevice
  un-inlined but ptxas-valid; the pod's opt-21 inlines + DCEs. Fast-PTX (native `.approx` / `__nv_fast_*`)
  is Phase 3.
- **Phase 5 — AD × precision × denormal. DONE 2026-07-03 (on-metal BMG). ENDEAVOR COMPLETE.**
  The dread was unfounded, exactly as predicted: the derivative rules are symbolic and exact, so
  AD is *correct* under any precision (chain rule is precision-independent — same lesson as 126-5b).
  Implementation was pure test-harness: added `precision=fast|ieee` + `denormal=ftz|preserve` tokens
  to the `VERIFY-AUTODIFF` directive (parser `*vad-reserved-keys*` + plist), threaded through
  `%vad-compile-spv` (forwards `--math-precision`/`--denormal-handling`) so the fwd + bwd kernels
  compile under the same FP mode. Specs 15-sin-ad-fast, 16-exp-ad-fast-ftz (both axes),
  17-pow-ad-fast (binary, native_powr + native_log in the backward) — all **verified on the BMG via
  L0**, gradients correct (sin' diff 3.8e-5, exp' 4.7e-5, pow ∂x=12.0/∂y=5.545). Looser atol under
  fast (native builtins are approximate) — though on BMG native is accurate enough that FD error
  dominates. **ftz gradient caveat** documented (tests.md): flush-to-zero can zero a denormal
  intermediate in `1/x` (log) / `1/√(1−x²)` (asin near ±1) — pick inputs off those boundaries.
  Regression 828/828 both ways, 253 unit, 185 neg.

---

**ENDEAVOR 128 COMPLETE (2026-07-02/03).** All 11 transcendentals (exp log log2 sin cos tan asin
acos atan pow atan2), forward + autodiff, across SPV (BMG/L0) and PTX (RTX 2000 Ada/CUDA), both
precisions (ieee precise / fast → native_* on SPV, __nv_fast_* on PTX) and denormal modes. Suite
828/828 both ways, 253 unit, 185 neg. ci-stop `128-transcendentals`.








Docs are below:



### Floating Point Only Operations ⚠️

Crisp provides the following operations for floating point numbers:

#### Unary Operations 📝

The Unary Operations take just a single argument.
Example:
```
(sqrt x)
```

- `sqrt`
- `rsqrt`
- `exp`   ; `(exp x)` calculates $e^x$
- `log`
- `log2`
- `sin`
- `cos`
- `tan`
- `asin`
- `acos`
- `atan`


#### Binary Operations  📝
- `pow`   => `(pow base exponent)`
- `atan2` => `(atan2 y x)`

### Transcendental Functions 📝

Crisp supports a standard set of transcendental functions. These are the floating-point unary and binary operations introduced above, called out separately here because they compile differently from ordinary arithmetic — and on the PTX target under `ieee` precision they carry one extra requirement (below).

**Unary**

| Function | Meaning        |
|----------|----------------|
| `exp`    | $e^x$          |
| `log`    | natural log    |
| `log2`   | base-2 log     |
| `sin`    | sine           |
| `cos`    | cosine         |
| `tan`    | tangent        |
| `asin`   | arcsine        |
| `acos`   | arccosine      |
| `atan`   | arctangent     |

**Binary**

| Function | Form                   | Meaning                   |
|----------|------------------------|---------------------------|
| `pow`    | `(pow base exponent)`  | $\text{base}^{\text{exponent}}$ |
| `atan2`  | `(atan2 y x)`          | two-argument arctangent   |

> `sqrt` and `rsqrt` are **not** transcendentals. They are algebraic and have IEEE-precise native instructions on every backend, so they compile like ordinary arithmetic and never trigger the libdevice requirement below.

#### Autodiff

All of the transcendentals are **differentiable** — their derivatives are built into Crisp's autodiff, so a kernel that uses them differentiates automatically under `--differentiate`. Unlike a foreign function (which needs a user-supplied VJP), you write `(sin x)` and the backward pass knows `d/dx sin = cos`, `d/dx exp = exp`, and so on, including both partials of the binary `pow` and `atan2`.

#### Precision behavior

Transcendentals honor the precision axis (`fast` vs `ieee`, chosen by `--math-precision`, `declaim`, or `with-precision`) like all FP math:

- **`fast`** — lowered to the backend's fast/approximate path: OpenCL `native_*` builtins on SPIR-V (no external dependencies), or NVIDIA's `__nv_fast_*` routines (the `.approx` hardware path) on PTX. **On PTX the fast routines come from libdevice too**, so the requirement below applies under `fast` as well.
- **`ieee`** — lowered to a correctly-rounded implementation. On some backends that implementation is not built into the hardware and must be supplied at compile time (see PTX below).

#### PTX: `libdevice.10.bc` required for transcendentals ⚠️

NVIDIA GPUs have no *native* instruction for the transcendentals — the hardware offers only a few approximate primitives. To compile a transcendental for `--ir-target=ptx`, Crisp links NVIDIA's math library, **`libdevice.10.bc`**, and specializes the routine into the kernel at compile time — the correctly-rounded `__nv_*` under `ieee`, or the approximate `__nv_fast_*` under `fast`. The emitted `.ptx` is self-contained; nothing special is needed at run time.

You supply `libdevice.10.bc` the same way as any foreign bitcode — as a positional argument on the command line:

```
crisp-compile --ir-target=ptx  $CUDA_HOME/nvvm/libdevice/libdevice.10.bc  my_kernel.crisp
```

**If a kernel uses a transcendental for the PTX target and `libdevice.10.bc` is not provided, compilation fails with an error.** The library ships with the CUDA Toolkit (under `nvvm/libdevice/`). The requirement applies whenever *both* hold: PTX target and at least one transcendental — **under either precision** (`fast` → `__nv_fast_*`, `ieee` → `__nv_*`; both live in libdevice). Pure arithmetic, `sqrt`/`rsqrt`, and division still compile without it. SPIR-V never needs it.

Denormal handling (`--denormal-handling`) is orthogonal: it selects the flush-to-zero vs preserve variant of the linked routines but never changes *whether* the library is needed.

#### Other targets

- **SPIR-V / Level-Zero / OpenCL** — transcendentals resolve through the platform's own math builtins, provided by the runtime. No user-supplied library is required, for either precision.
