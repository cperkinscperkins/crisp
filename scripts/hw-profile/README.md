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


## Every emitted key is tagged with its provenance

A hardware value without a provenance is how those wrong assumptions got adopted, so both
query programs label each key they emit:

| tier | meaning | what to do |
|---|---|---|
| **QUERIED** | read off the device by this program | trust it |
| **ARCH** | an ISA fact, not a device property | look it up **for your part** — the emitted value is the reference part's |
| **MEASURED** | only a sweep can answer it | **omit it**; absent falls back to safe behaviour |

The MEASURED tier is the one that punishes guessing. `:tile-visit-strip-width 4` is **+63% on
BMG at N=2048** and **−14.4% on H100 at W=16** — no query and no amount of reasoning can tell
you which, so a wrong guess costs more than leaving it out. Neither program ever emits a value
for it; they only name the key.

Two ARCH keys are easy to get subtly wrong, and both fail *silently*:

- **`:max-registers-per-thread` is a LIST on Intel** — `(128 256)`, ascending selectable GRF
  modes, because the register file is a JIT-time choice. Collapsing it to a scalar forfeits
  large-GRF, worth **1.55–2.01x** on BMG. On NVIDIA it is correctly a scalar (255).
- **`:mma-shapes` must list every element width the part supports.** `%check-mma-shape` is a
  hard compile error on an unlisted shape, so emitting only the tf32 triple refuses every
  bf16 / fp16 / int8 MMA kernel. On NVIDIA the **typed** `(:double 8 8 4)` entry is required
  for fp64: without it `double` resolves via the width rule to `(16 8 4)`, which is in the PTX
  ISA but is *not* an NVVM intrinsic in LLVM 21.1.5 — it assembles and emits an
  `.extern .func` call **with no diagnostic**.


## `query-l0.cpp` — Level Zero device query (Intel)

```
clang++ query-l0.cpp -I <level-zero>/include <ze_loader lib> -static -o query-l0
./query-l0
```

Dumps every property that maps onto a profile key and prints a paste-ready
`def-hardware-profile` form.  Also reports the EU hierarchy explicitly
(`slices × subslices × EUs × threads`), which is what the L0 launcher's occupancy formula uses.

Not queryable via L0, so taken from the ISA: cache-line size, GRF modes, MMA shapes, and
`:mma-lowerings` (a capability claim the program cannot verify — it emits the portable
`:coop-matrix` and *names* `:xe-native` for Xe2+ rather than asserting it).

`:l2-cache-size` **is** emitted, taken as the largest cache `zeDeviceGetCacheProperties`
reports.  Verified on an Arc B580: every queried value reproduces the checked-in `bmg`
profile, including 18MB L2.

The profile name is left as `<name>` — L0 device names are not stable enough to derive one.


## `query-cuda.cu` — CUDA device query (NVIDIA)

```
nvcc query-cuda.cu -o query-cuda && ./query-cuda
```

The NVIDIA twin.  Labels `multiProcessorCount` as PCIe (114) vs SXM (132) so the variant is
self-identifying, and calls out the shared-memory default-vs-optin trap above.

**It names the profile after the device**, sanitized from `cudaDeviceProp::name` — an H100 NVL
emits `(def-hardware-profile h100-nvl …)`, an H200 emits `h200`.  It used to emit the literal
name `h100` on every part, which is precisely the confusion a profile exists to end: SM count
alone cannot separate an SXM from an NVL (both 132).  The benchmark harness matches on the same
device string, so the two agree by construction.

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
