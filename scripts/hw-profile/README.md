Hardware-profile query tools
============================

Three small standalone programs for writing a `def-hardware-profile` from **measured** device
values instead of a spec sheet, and for inspecting what the JIT actually did with a kernel.

They exist because endeavor 144 twice found that a plausible-looking assumption about the
hardware was wrong, and both times a two-minute query settled it:

- `:compute-units` **114 on H100 PCIe vs 132 on SXM** — and that value overrides the device SM
  query in the generated CUDA launch grid, so guessing it mis-sizes every dispatch.
- Shared memory has **two different numbers** on NVIDIA: `sharedMemPerBlock` is the 48 KB
  default, `sharedMemPerBlockOptin` the real ~227 KB cap.  Kernels that exceed 48 KB need the
  latter.
- Every shipped Intel benchmark kernel was **spilling registers**, invisibly, for months.


## `query-l0.cpp` — Level Zero device query (Intel)

```
clang++ query-l0.cpp -I <level-zero>/include <ze_loader lib> -static -o query-l0
./query-l0
```

Dumps every property that maps onto a profile key and prints a paste-ready
`def-hardware-profile` form.  Also reports the EU hierarchy explicitly
(`slices × subslices × EUs × threads`), which is what the L0 launcher's occupancy formula uses.

Not queryable via L0, so taken from the ISA: cache-line size, GRF size, MMA shapes.


## `query-cuda.cu` — CUDA device query (NVIDIA)

```
nvcc query-cuda.cu -o query-cuda && ./query-cuda
```

The NVIDIA twin.  Labels `multiProcessorCount` as PCIe (114) vs SXM (132) so the variant is
self-identifying, and calls out the shared-memory default-vs-optin trap above.

Note: on typical cloud images `nvcc` is **not** on `PATH` — it lives at `/usr/local/cuda/bin`.


## `kernel-probe-l0.cpp` — what the JIT did to your kernel (Intel)

```
clang++ kernel-probe-l0.cpp -I <level-zero>/include <ze_loader lib> -static -o kernel-probe-l0
./kernel-probe-l0 kernel.spv [more.spv ...]
```

Loads each `.spv` and reports `ze_kernel_properties_t` — **`spillMemSize`**, private memory,
SLM, and the subgroup/workgroup requirements — **under each register-file mode** (default GRF
and `-ze-opt-large-register-file`).

This is the oracle for register-pressure work.  It is how endeavor 144 discovered that all
three shipped BMG matmul kernels spilled (1792 / 2560 / 2752 bytes) and that asking IGC for the
larger register file took every one of them to zero, worth up to 2.01x.

**Reading it:** spill is necessary but *not sufficient* evidence for widening the register file.
Two of those three kernels spill and are made **slower** by the larger allocation, because it
halves threads-per-EU and they are occupancy-bound rather than register-bound.  Compare both
columns and measure; do not treat `spillMemSize > 0` as an instruction.


## Provenance

The profiles these produced are checked in as the compiler's builtin `bmg` and `h100`
(`register-builtin-hardware-profiles`).  Full measurements and the reasoning are in
`tests/spec/144-mma-hardware-profile/results.md`; the portable lessons are in that directory's
`FINDINGS.md`.
