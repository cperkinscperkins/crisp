# Quarantined: 44 SYCL-TLA sweeps, 247 points — all invalid

Moved here 2026-08-28. **Not deleted**, because they are the evidence for what went wrong.

## Why they are invalid

The SYCL-TLA harness hardcoded its own verdict:

```c
printf("  \"correct\": true,\n  \"max_abs_err\": 0.0,\n");
```

It asserted a correctness it never checked. `scripts/crisp_bench/matmul.py`'s `run_sweep` has
always dropped any point whose harness reports `correct=false` — **that gate was working the
whole time; it was being lied to.**

When a real check was added (A=B=1.0, so every element of D must equal K — the same oracle the
Crisp fixture uses), the output matrix turned out to be **entirely zero**: `sum(D) = 0` over all
M*N elements, against an expected 1.07e9 at N=1024. Every TFLOPS figure in these files is
`2*M*N*K / time` over work that never landed, which is why the peer appeared roughly twice as
fast as Intel's own oneMKL.

## Why it happens — six hypotheses, all falsified by measurement

| tried | result |
|---|---|
| our harness is wrong | their own unmodified `examples/00_bmg_gemm` fails identically |
| library version | v0.7, v0.8, v0.9, v0.9.1, v0.9.2 and main (Jan–Aug 2026) all fail |
| our shallow/bind-mounted checkout | clean full clone inside the container fails too |
| compilation mode | JIT (`spir64`) and AOT (`spir64_gen -device bmg-g21`) both fail |
| backend | Level Zero and OpenCL both fail |
| Xe path disabled / `sm_count` / `run()` status | macros enabled, sm_count=20, run() returns Success |

Environment verified working throughout: `Intel(R) Graphics [0xe20b]` (BMG) over Level Zero,
driver 20.1.0 / `1.6.33578+15`, icpx oneAPI 2025.3, and a plain SYCL kernel computes correctly
on the GPU. B580 is on SYCL-TLA's own supported-hardware list.

**What DOES work here is its LEGACY builtin path** (`MainloopIntelXeXMX16` +
`CUTLASS_SYCL_BUILTIN_ENABLE`), which passes verification at ~9.5–11.9 TFLOPS. That path is a
pre-2025.2 compatibility fallback, not a peer, so it is deliberately NOT wired into the suite.
The modern path (`MainloopXeL1Staged`, inline vISA asm) is the peer, and it is broken on this
driver.

## Status

The harness still builds and runs the REAL SYCL-TLA. It now reports its own verdict honestly, so
on this machine every point is dropped and the peer column is empty. On a machine where the
modern path works, points will record normally with no further change.
