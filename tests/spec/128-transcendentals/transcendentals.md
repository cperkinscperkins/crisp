Transcendentals
===============
- [ ] across both precisions
- [ ] and both subnormal handling (when ieee)
- [ ] and auto differentiation for each. ?
- [ ] error when transcendentals and ieee and no ilbdevice.bc when outputting PTX.
- [ ] other errors?


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
- **Phase 2 — precision × denormal on the SPV path.** fast vs ieee for transcendentals
  (precise ExtInst vs `native_*`/FMF) + denormal interaction. TDD locally.
- **Phase 3 — PTX `fast`.** Resolve fork (A)/(B); native `.approx` for sin/cos + the chosen
  path for the rest. IR/ptx-check locally, on-metal CUDA (pod).
- **Phase 4 — PTX `ieee` + libdevice.** In-process libdevice link (reuse FFI plumbing; note
  `FFI-LINK` already resolves `$CUDA_HOME/.../libdevice.10.bc`), NVVMReflect driven by the
  denormal axis, the **missing-libdevice error + negative test**, `run-on-pod.sh` update.
  On-metal CUDA.
- **Phase 5 — AD × precision × denormal (the "dread", de-dreaded).** The derivative rules are
  symbolic and exact, so AD is *correct* under any precision (precision is transparent to the
  derivative structure — same lesson as 126-5b). The only real work is **precision-aware
  VERIFY-AUTODIFF tolerances** (widen atol under fast) + documenting the one genuine gotcha:
  ftz can flush denormal intermediates in gradients like `1/x` (log) or `1/√(1−x²)` (asin near
  ±1) to zero — pick test inputs away from those boundaries. Consistency rule: the backward
  kernel's forward-recompute must use the same precision as the forward.








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

#### Precision behavior

Transcendentals honor the precision axis (`fast` vs `ieee`, chosen by `--math-precision`, `declaim`, or `with-precision`) like all FP math:

- **`fast`** — lowered to the backend's fast/approximate hardware path (e.g. the PTX `.approx` instructions, or relaxed SPIR-V math). No external dependencies.
- **`ieee`** — lowered to a correctly-rounded implementation. On some backends that implementation is not built into the hardware and must be supplied at compile time (see PTX below).

#### PTX: `libdevice.10.bc` required for `ieee` transcendentals ⚠️

NVIDIA GPUs have no IEEE-precise *native* instruction for the transcendentals — the hardware offers only fast approximate forms. To compile a transcendental under `ieee` precision for `--ir-target=ptx`, Crisp links NVIDIA's math library, **`libdevice.10.bc`**, and specializes the correctly-rounded routine into the kernel at compile time. The emitted `.ptx` is self-contained; nothing special is needed at run time.

You supply `libdevice.10.bc` the same way as any foreign bitcode — as a positional argument on the command line:

```
crisp-compile --ir-target=ptx  $CUDA_HOME/nvvm/libdevice/libdevice.10.bc  my_kernel.crisp
```

**If a kernel uses an `ieee` transcendental for the PTX target and `libdevice.10.bc` is not provided, compilation fails with an error.** The library ships with the CUDA Toolkit (under `nvvm/libdevice/`). The requirement applies only when *all three* hold: PTX target, `ieee` precision, and at least one transcendental. Pure arithmetic, `sqrt`/`rsqrt`, division, or *any* math under `fast` compiles without it.

Denormal handling (`--denormal-handling`) is orthogonal: it selects the flush-to-zero vs preserve variant of the linked routines but never changes *whether* the library is needed.

#### Other targets

- **SPIR-V / Level-Zero / OpenCL** — transcendentals resolve through the platform's own math builtins, provided by the runtime. No user-supplied library is required, for either precision.
