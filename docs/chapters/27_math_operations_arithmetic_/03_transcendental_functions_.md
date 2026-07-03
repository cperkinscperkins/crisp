# Transcendental Functions 📝


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

