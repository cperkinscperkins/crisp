# Quarantined: 44 SYCL-TLA sweeps, 247 points — all invalid

Moved here 2026-08-28. **Not deleted**, because they are the evidence for what went wrong.

**RESOLVED the same day.** The cause was found, and it was not any of the six things this file
originally suspected. Root cause and fix are in "What it actually was" below; the original
investigation is kept verbatim underneath it, because how it went wrong is the useful part.

**The data in this directory stays invalid** and is never read by the report. It was produced by a
harness that asserted its own correctness *and* on a runtime that miscompiled the kernel — two
independent reasons, either one sufficient. The peer column is refilled by re-measuring, never by
rehabilitating these files.

---

## What it actually was

**The container's Intel compute runtime was too old, and it silently miscompiled SYCL-TLA's modern
collective.**

Single-variable proof — same fresh clone (`91e5bd7`), same CMake configuration, same
`icpx 2025.3.0`, same container, same host driver, same GPU. Only the runtime moved:

| | fails | passes |
|---|---|---|
| Compute runtime (NEO) | 25.18.33578 | **26.27.39122.11** |
| Level Zero driver | 1.6.33578+15 | **1.15.39122+11** |
| IGC | 2.11.12 | **2.38.2** |

On 25.18, upstream's own unmodified `00_bmg_gemm` reports `Disposition: Failed` /
`Error Internal at: 437`. On 26.27 it reports `Disposition: Passed` at every size, running the
**modern** `MainloopXeL1Staged<2, KernelXe>` collective — the inline-vISA path, not the legacy
builtin fallback. Our own peer harness then verifies with `max_abs_err` **exactly 0**.

### Why the container was on a 14-month-old runtime

`scripts/Dockerfile.bench-intel` provisioned its Intel GPU stack from
`repositories.intel.com/gpu/ubuntu noble`, whose newest build is **25.18.33578** (May 2025).
SYCL-TLA's upstream CI runs BMG against **25.48+**. So the documented Intel apt repository for
Ubuntu 24.04 lands you *below* the floor SYCL-TLA requires, with no diagnostic of any kind — the
packages were simply "latest available from the configured source." Newer runtimes exist only as
GitHub release debs, which is why the Dockerfile now pins them explicitly.

**It was never WSL2, and never a SYCL-TLA bug.** The Windows host driver was current throughout
(`32.0.101.8974`, 2026-08-10). Item 5 below — the native-Linux live USB, called "the definitive
test" — was unnecessary: the office Linux machine that worked was not different because it was
Linux, it was different because it shipped a 14-month-newer runtime (26.27.39122.12).

### Why six correct-looking hypotheses all missed it

Every one of them varied something **SYCL-TLA-side**: our harness, the library version, the
checkout, JIT vs AOT, Level Zero vs OpenCL, build macros. The runtime was never a variable, because
it had been reasonably established as good — **Crisp's own `Subgroup2DBlockLoadINTEL` and
`SubgroupMatrixMultiplyAccumulateINTEL` kernels ran correct through that exact driver at 108.9
TFLOPS.**

That evidence was true and still misleading. Crisp emits SPIR-V instructions; the modern collective
emits inline vISA `lsc_load_block2d` with address payloads. Only the latter was miscompiled. "2D
block IO and DPAS work here" was a sound observation about a *different code path* — and it is what
kept the runtime off the suspect list.

The original appendix's closing hypothesis had the mechanism right ("the stack miscompiles or
mishandles SYCL-TLA's inline vISA `lsc_load_block2d` with address payloads, silently, producing no
fault") and the blame wrong (it blamed WSL/IGC-on-WSL rather than IGC-version).

**Generalisable lesson.** When a component is ruled out because *our* code exercises it correctly,
check that our code exercises the *same path*. Shared hardware and a shared driver are not a shared
code path. See also `bug-sweep-030-lessons`: a bug report's observations outlive its stated cause.

### A second error, found while confirming the fix

With the runtime fixed the peer was correct but reported **12.6 TFLOPS at N=4096**. That is also
wrong, in the opposite direction: `matmul.py` built the peer without
`-ze-opt-large-register-file`, so its mainloop spilled ~131 registers. With 256-GRF the spill goes
to **zero** and the same source reads **81.3 TFLOPS** — 6.5x. Publishing the unflagged figure would
have understated the peer by more than six-fold, which is the same integrity failure as the
hardcoded `correct=true`, merely pointing the other way. Fixed in `matmul.py`'s `sycl_tla_flags`.

### Should Intel hear about it?

The miscompile itself is already fixed by IGC 2.38.2, so a report against it has little value
without a bisect of the exact fix boundary (25.18 → 26.27 was taken in one hop; 25.48 / 26.01 /
26.14 were not tried). What *is* worth reporting upstream is that **SYCL-TLA has no minimum-runtime
guard**: it builds clean, launches clean, returns `Success`, and computes a wrong answer, with no
message naming the runtime — combined with Intel's own Ubuntu 24.04 apt repo capping below the
floor its CI requires.

---

## Original investigation (2026-08-28, kept verbatim)

> Retained because the observations are all accurate and reproducible. Only the CAUSE was wrong.

### Why they are invalid

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

### Why it happens — six hypotheses, all falsified by measurement

> All six are genuine negative results. None of them varied the compute runtime, which is what it
> actually was.

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

*(That "verified working" line is precisely the trap: `1.6.33578` was the too-old runtime.)*

**What DOES work here is its LEGACY builtin path** (`MainloopIntelXeXMX16` +
`CUTLASS_SYCL_BUILTIN_ENABLE`), which passes verification at ~9.5–11.9 TFLOPS. That path is a
pre-2025.2 compatibility fallback, not a peer, so it is deliberately NOT wired into the suite.
The modern path (`MainloopXeL1Staged`, inline vISA asm) is the peer, and it is broken on this
driver.

*(Correct, and the sharpest clue in the file: the legacy path avoided the miscompiled
instruction sequence. It was read as "the modern path is broken" when it meant "this IGC breaks
the modern path.")*

### Status

*(Superseded — the harness now reports honestly AND the runtime is fixed, so points record
normally on this machine.)*

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
| 3 | Missing Large-GRF (256 register) flag | **CLOSED — not the cause** *of the wrong answer.* Rebuilt AOT with `-device bmg-g21 -options -ze-opt-large-register-file`; builds clean, still `Disposition: Failed`. **But see above:** once the runtime was fixed, this flag turned out to be worth **6.5x** on the peer's throughput. It was correctly excluded as the correctness cause and wrongly forgotten as a performance requirement. |
| 4 | IGC / Level Zero debug env vars | **Done — useful negative.** See row 1; the run is fault-free. |
| 5 | Native Linux live USB to separate upstream bug from WSL2 bug | **Not run — and it is the definitive test.** Requires host access; Chris's call. *(Superseded: not needed. The Linux machine differed by runtime version, not by kernel. Upgrading the runtime inside the container reproduced its success.)* |

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

*(Confirmed as to mechanism, corrected as to blame: it was the IGC **version**, not WSL. The
three-way split above is exactly right and was one question away from the answer — "what else
differs between the machine where the modern path works and this one?" The answer was the
runtime.)*
