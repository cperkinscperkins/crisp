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

---

## Appendix — external suggestions, triaged 2026-08-28

A second opinion (Gemini) proposed five avenues. Its core intuition — that the fault is in the
**inline vISA / LSC 2D block** path used by the modern collective and not by the legacy one — is
the best-supported theory we have, and the evidence below narrows it further. The specific
mechanisms it proposed, however, are mostly ruled out:

| # | suggestion | verdict |
|---|---|---|
| 1 | WSL2 `dxgkrnl` drops LSC descriptors; look for a GPU fault / TDR | **Mechanism not supported.** `ZE_DEBUG=4` + `NEOReadDebugKeys=1` + `PrintDebugMessages=1` report **no** device-lost, **no** memory violation, **no** page fault — the kernel runs cleanly and computes the wrong answer. A TDR would surface as `ZE_RESULT_ERROR_DEVICE_LOST`. `dmesg` is unavailable in the container; the Windows Event Viewer check is still worth 30 seconds on the host. |
| 2 | Base-pointer / pitch alignment for 2D block transfers | **CLOSED — not the cause.** CUTLASS device allocations come back **2 MB-aligned** (`0x…e00000`, so 64/128/256B all satisfied), and A/B/D pitches are 64-byte multiples at N = 1024 / 4096 / 8192. |
| 3 | Missing Large-GRF (256 register) flag | **CLOSED — not the cause.** Rebuilt AOT with `-device bmg-g21 -options -ze-opt-large-register-file`; builds clean, still `Disposition: Failed`. |
| 4 | IGC / Level Zero debug env vars | **Done — useful negative.** See row 1; the run is fault-free. |
| 5 | Native Linux live USB to separate upstream bug from WSL2 bug | **Not run — and it is the definitive test.** Requires host access; Chris's call. |

### The evidence that narrows it, which the external suggestion did not have

**Crisp's own kernels use `SPV_INTEL_2d_block_io` (`Subgroup2DBlockLoadINTEL`,
`Subgroup2DBlockLoadTransformINTEL`) and `SubgroupMatrixMultiplyAccumulateINTEL` through this
exact driver, and verify correct at every size — 108.9 TFLOPS at N=8192.**

So 2D block IO and DPAS are **not** broken through WSL. What separates the two SYCL-TLA paths is
narrower than "LSC 2D block":

* modern `MainloopXeL1Staged` — **inline vISA assembly** (`asm("lsc_load_block2d…")`) plus
  `__builtin_IB_subgroup_createBlock2DAddressPayload` / `setBlock2DAddressPayloadBlockX/Y`
* legacy `MainloopIntelXeXMX16` — `__builtin_IB_*` builtins, no inline asm  → **works**
* Crisp — SPIR-V instructions for the same operations                      → **works**

Note also that `-DCUTLASS_SYCL_BUILTIN_ENABLE` does **not** rescue the modern path: that flag
gates the *legacy* headers (`copy_xe_legacy.hpp`, `mma_xe_legacy.hpp`), which only the legacy
collective consumes. Consistent with the observation that the modern example still failed with
it set.

**Best remaining hypothesis:** the WSL/IGC stack miscompiles or mishandles SYCL-TLA's inline vISA
`lsc_load_block2d` with address payloads, silently, producing no fault. The decisive next steps
are a minimal standalone repro of that instruction sequence, or item 5 above.
