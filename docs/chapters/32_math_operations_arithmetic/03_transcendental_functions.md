# Transcendental Functions ✅


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
| `tanh`   | hyperbolic tangent |
| `erf`    | error function |
| `exp2`   | $2^x$          |

**Binary**

| Function | Form                   | Meaning                   |
|----------|------------------------|---------------------------|
| `pow`    | `(pow base exponent)`  | $\text{base}^{\text{exponent}}$ |
| `atan2`  | `(atan2 y x)`          | two-argument arctangent   |

> `sqrt` and `rsqrt` are **not** transcendentals. They are algebraic and have IEEE-precise native instructions on every backend, so they compile like ordinary arithmetic and never trigger the libdevice requirement below.

#### Autodiff ✅

All of the transcendentals are **differentiable** — their derivatives are built into Crisp's autodiff, so a kernel that uses them differentiates automatically under `--differentiate`. Unlike a foreign function (which needs a user-supplied VJP), you write `(sin x)` and the backward pass knows `d/dx sin = cos`, `d/dx exp = exp`, and so on, including both partials of the binary `pow` and `atan2`.

#### Precision behavior ✅

Transcendentals honor the precision axis (`fast` vs `ieee`, chosen by `--math-precision`, `declaim`, or `with-precision`) like all FP math:

- **`fast`** — lowered to the backend's fast/approximate path: OpenCL `native_*` builtins on SPIR-V (no external dependencies), or NVIDIA's `__nv_fast_*` routines (the `.approx` hardware path) on PTX. **On PTX the fast routines come from libdevice too**, so the requirement below applies under `fast` as well.
- **`ieee`** — lowered to a correctly-rounded implementation. On some backends that implementation is not built into the hardware and must be supplied at compile time (see PTX below).

#### PTX: `libdevice.10.bc` required for transcendentals 

NVIDIA GPUs have no *native* instruction for the transcendentals — the hardware offers only a few approximate primitives. To compile a transcendental for `--ir-target=ptx`, Crisp links NVIDIA's math library, **`libdevice.10.bc`**, and specializes the routine into the kernel at compile time — the correctly-rounded `__nv_*` under `ieee`, or the approximate `__nv_fast_*` under `fast`. The emitted `.ptx` is self-contained; nothing special is needed at run time.

You supply `libdevice.10.bc` the same way as any foreign bitcode — as a positional argument on the command line, or with `--link-bitcode=` (the same thing; the only spelling the runtime compile API accepts, where the path must be absolute):

```
crisp-compile --ir-target=ptx  $CUDA_HOME/nvvm/libdevice/libdevice.10.bc  my_kernel.crisp
crisp-compile --ir-target=ptx  --link-bitcode=$CUDA_HOME/nvvm/libdevice/libdevice.10.bc  my_kernel.crisp
```

From Python, `crisp_gpu.compile` finds a libdevice by itself (`$CRISP_LIBDEVICE`, the CUDA Toolkit, or the copy Triton ships with PyTorch) and links it for every PTX compile.

Only the routines a kernel actually calls end up in the PTX: everything a linked library defines is given internal linkage, so the optimizer inlines what is used, and whatever is unused is deleted at link time. Linking libdevice into a kernel that uses no transcendental therefore changes nothing — the PTX is byte-identical to compiling without it.

**If a kernel uses a transcendental for the PTX target and `libdevice.10.bc` is not provided, compilation fails with an error.** The library ships with the CUDA Toolkit (under `nvvm/libdevice/`). The requirement applies whenever *both* hold: PTX target and at least one transcendental — **under either precision** (`fast` → `__nv_fast_*`, `ieee` → `__nv_*`; both live in libdevice). Pure arithmetic, `sqrt`/`rsqrt`, and division still compile without it. SPIR-V never needs it.

Denormal handling (`--denormal-handling`) is orthogonal: it selects the flush-to-zero vs preserve variant of the linked routines but never changes *whether* the library is needed.

#### Other targets

- **SPIR-V / Level-Zero / OpenCL** — transcendentals resolve through the platform's own math builtins, provided by the runtime. No user-supplied library is required, for either precision.

