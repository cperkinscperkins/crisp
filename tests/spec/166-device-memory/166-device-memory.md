# Endeavour 166 — Device Memory

**Status:** the switch is DONE. Hoist-L0 and the matmul bench harness both emit device
memory; 1073/1073 specs, 291 unit, 235 negative; on-metal verified on BMG.
**Opened:** 2026-09-08, from `main` @ b51c3fe.

Direction taken (Chris, 2026-09-08): move to device memory outright, no flag. Shared makes
performance unpredictable. A `--shared` opt-in for hoisting may come later and is low
priority; when out-of-core lands it will be device-memory-only, with the swaps exposed
directly and predictably in the API. Sections 5 and 6 below record what was built; the
flag-gated staging described in the original plan was dropped as unnecessary.

---

## 1. What prompted this

The observation was that `benchmarks/matmul/crisp/bench_harness_l0.cpp` allocates with
`zeMemAllocShared` rather than device memory, with three worries attached: that the `.cu`
harnesses do the same, that the *hoisting code Crisp generates* defaults to shared, and that
shared becomes a liability at large matrices and under out-of-core execution.

One of those three is true. The audit and the probe below say which, and how much it costs.

---

## 2. Audit — what actually allocates what

### NVIDIA / CUDA: already device memory. Nothing to fix.

| Where | Call |
|---|---|
| `benchmarks/matmul/crisp/bench_harness.cu` | `cuMemAlloc` (8 sites) |
| `src/hoist-cuda/main.lisp` | `cuMemAlloc` + explicit `cuMemcpyHtoD` / `cuMemcpyDtoH` |
| every contender (`cublas_ceiling`, `cutlass_peer`, `cuda_control`, `cuda_apples`, cub) | `cudaMalloc` |

`cudaMallocManaged` appears nowhere in the repository. The suspicion about the `.cu` harnesses
was wrong; the CUDA arm has been explicitly staged all along.

### Intel / Level Zero: shared everywhere.

| Where | Call |
|---|---|
| `benchmarks/matmul/crisp/bench_harness_l0.cpp:237-239` | `zeMemAllocShared` x3 |
| `src/hoist-l0/main.lisp:1351` (`%l0-emit-cell-arg`) | `zeMemAllocShared` |
| `src/hoist-l0/main.lisp:1495` (`%l0-emit-global-scratch-tensor-arg`) | `zeMemAllocShared` |
| `src/hoist-l0/main.lisp:1603` (`%l0-emit-tensor-arg`) | `zeMemAllocShared` |

Those three emission sites cover every parameter of every Crisp-generated L0 host program. The
suspicion about the hoisting default was right, and it is total.

### Third finding, not looked for: the Intel contender field disagrees with itself.

`onemkl_*`, `onednn_*`, and the bf16/fp16 `sycl_control`s use `malloc_device`. But the
`sycl_apples` mirrors for chap1–chap5 and both `sec4_*` dirs, plus `sec2_top/sycl_control.cpp`,
use `malloc_shared` — while `chap0_naive/sycl_apples.cpp` uses `malloc_device`. So within one
Intel section the SYCL mirror changes allocation class depending on which chapter you read. That
is a comparability defect on its own terms, independent of whether shared is slow.

---

## 3. The probe

**Apparatus.** `put_temp_files_here/usm_probe/probe_usm_l0.cpp`, *generated* from the shipped
`bench_harness_l0.cpp` by `make_probe.py` so it cannot drift from the harness it stands in for.
The only change is one env knob, `CRISP_MATMUL_MEM`:

- `shared` — `zeMemAllocShared`, host fills the kernel's own pointer. What ships today.
- `shared_prefetch` — the same, plus `zeCommandListAppendMemoryPrefetch` on A/B/C before warmup.
- `device` — `zeMemAllocDevice`, pinned-host staging buffers, explicit H2D before warmup and
  D2H of C before verification.

The `shared_prefetch` arm exists because a bare device-vs-shared delta cannot say *which* of two
different things it measured — "shared is slower" or "shared's pages were not resident yet". With
the third arm those separate.

**Kernel.** `benchmarks/matmul/sec2_top/matmul_bmg.crisp`, the shipped Intel f32 top kernel —
tile 32x64, local-size 16, tf32 DPAS, `-ze-opt-large-register-file`. Compiled
`--hardware-profile=bmg --math-precision=fast --denormal-handling=ftz`. Every run verified.

**Platform.** BMG (Arc B580) via the `crisp-bench-intel` container, `--device=/dev/dxg`. Docker
rather than Windows-native, per the platform-divergence rule.

### Result 1 — hot loop, warmup 20 / iters 50, arms interleaved

| N | shared | shared_prefetch | device | device vs shared |
|---:|---:|---:|---:|---:|
| 1024 | 66.9 µs | 66.9 µs | 66.7 µs | 1.00x |
| 2048 | 586.9 µs | 588.0 µs | 549.0 µs | **1.07x** |
| 4096 | 6151.9 µs | 6180.7 µs | 6199.1 µs | 0.99x |

### Result 2 — N=2048 only, 5 reps each

| arm | median | min | max | spread |
|---|---:|---:|---:|---:|
| shared | 597.9 µs | 593.9 | 601.5 | 1.3% |
| device | 549.0 µs | 543.2 | 557.0 | 2.5% |

**device is 1.089x shared, and the ranges do not overlap** (shared's best is worse than device's
worst). This is not noise.

### Result 3 — cold: warmup 0, iters 1, nothing resident

| N | shared | device | cold vs hot |
|---:|---:|---:|---:|
| 1024 | 66.8 µs | 67.2 µs | 1.00x both |
| 2048 | 593.1 µs | 557.8 µs | 0.99x / 0.93x |
| 4096 | 6096.8 µs | 6176.5 µs | 0.99x / 1.00x |

### What the probe settled

**FALSIFIED — the migration hypothesis.** The concern was that shared USM might be host-mapped
and streamed over PCIe, which would present exactly as the "load-bound, loads = 95% of runtime"
picture the roofline probe reported. It is not happening:

- `shared_prefetch` is indistinguishable from `shared` at every size. The prefetch was *accepted*
  by the driver (no "not honoured" note was emitted), so it had nothing to migrate.
- The cold arm shows **no first-launch penalty at all** — a single launch with nothing warmed is
  the same speed as the 50th. If pages were faulting in during the kernel, the cold number would
  be the one that showed it.

So the published Intel numbers are **not** distorted by an allocation class making operands come
from host memory. That was the big worry and it is retired.

**SURVIVED — a real, repeatable 8.9% at N=2048, and only there.** Device is faster, and steadier.
Cold shows the same delta, so it is not a warm-up or residency effect. Mechanism unknown. The
working sets are 12.6 MB at 1024, 50 MB at 2048, 201 MB at 4096, so "shared allocations get a
different cacheability policy, which is decisive only while the operand reuse still lands in L2"
is a plausible story — but it is a story, not a measurement, and it should be labelled as one
until somebody checks it. **N=2048 is a published sweep size**, so Crisp's Intel row there is
currently ~9% understated relative to what device memory would give it. The bias runs against
Crisp, which is the harmless direction, but it is systematic.

---

## 4. The liabilities, ranked

**(a) Benchmark comparability — real but small, and now quantified.** Crisp-on-shared is compared
against oneMKL-on-device, and the SYCL mirrors flip between the two. Worth ~9% at one size, ~0
elsewhere. This is a tidiness-and-honesty item, not an emergency.

**(b) The hoist ABI — the one that actually matters.** Shared memory hides a bug class: a kernel
that reads a host-written buffer with no explicit copy works under shared and breaks under
device. Every L0 host program Crisp emits currently has that property, so we have no evidence
the generated code would survive a real device-memory integration, and no test that would catch
it if it didn't. This is about what Crisp *ships*, not about what it measures.

**(c) Out-of-core — the framing needs correcting before it becomes a plan.** Shared USM is the
mechanism that *permits* oversubscription; device memory hard-fails past VRAM, and we already hit
a wall on the device path (`ZE_RESULT_ERROR_UNSUPPORTED_SIZE` at a 2 GiB single allocation, which
`bench_harness_l0.cpp:224-233` documents as a *per-allocation* cap rather than capacity). So
"shared can't do big matrices" is not the problem. The real liability is that shared does the
migration *for* you, at page-fault granularity, on a schedule you don't control and can't overlap
with compute or see in a timing. A genuine out-of-core story is explicit device tiles plus staged
async copies that Crisp schedules — a *language* question. Moving the allocator is a precondition
for that work, not the work itself, and it should not be sold as delivering it.

---

## 5. What was built

**`overlays/hoist-l0/crisp-hoist-l0-overlay.lisp`** — every kernel parameter is now

    X_ptr    zeMemAllocDevice   what the kernel sees
    X_host   zeMemAllocHost     what the host fills, and reads back into

Five redefinitions and three new helpers:

| function | change |
|---|---|
| `%l0-emit-staged-alloc` (new) | device alloc + pinned-host mirror; records the pair, and forms the byte size ONCE so the copy and the allocation cannot disagree |
| `%l0-emit-h2d-staging` (new) | one staging command list for every buffer |
| `%l0-emit-d2h-readback` (new) | copies a buffer back into its mirror for printing |
| `%l0-emit-cell-arg` | global branch staged; local branch untouched (local memory is never host-visible) |
| `%l0-emit-tensor-arg` | all four fills (MMA A/B, MMA C, pad-with, iota) write the mirror |
| `%l0-emit-global-scratch-tensor-arg` | zero-init writes the mirror and is staged |
| `generate-kernel-arguments-with-usm` | binds `*l0-staging*`, emits the staging block after the parameter walk |
| `generate-cpp-main` | buffer print reads the mirror, after a D2H inside the existing `size <= 512` guard |

Two decisions worth keeping:

- **Staging is its own command list, not an append to `cmdList`.** `cmdList` is re-executed by
  the `--mma-bench` loop, so staging appended there would be re-run and *timed* on every
  benchmark iteration — it would have shown up as kernel time with nothing to say why. A
  launcher pays for one extra queue at startup instead.
- **The mirrors are `zeMemAllocHost`, not `malloc`.** An unpinned staging buffer makes the
  driver copy through a bounce buffer of its own.

`%l0-emit-mma-reference` needed no change: it already copies C back itself and *recomputes*
A and B rather than reading them, so it works against a device pointer exactly as it did
against a shared one.

**`benchmarks/matmul/crisp/bench_harness_l0.cpp`** — the same transformation, minus the probe's
knob. Device A/B/C with pinned-host mirrors, one staging copy before warmup, C copied back
before verification, and `"mem": "device"` recorded in the JSON so a results file says which
allocation class produced it. Verified on BMG against the same kernel and sizes as the probe:

| N | shipped harness (device) | probe device | probe shared |
|---:|---:|---:|---:|
| 1024 | 66.8 µs | 67.0 | 66.9 |
| 2048 | **557.5 µs** | 549.0 | 597.9 |
| 4096 | 6144.0 µs | 6208.2 | 6176.0 |

`verified: true` at every size. The harness reproduces the probe's device arm, so the 8.9% at
2048 is now the number the benchmark reports.

**Stale text fixed.** `089-strategy/16-hoist-exact-tiled-oversubscribe` asserted the old ABI in
its own `STRATEGY-EXPECT` lines and was the suite's single failure — it now expects
`zeMemAllocDevice` and the mirror's memset. Four comments in `076-scratch-tensor-hoist` that
described the launcher as allocating shared USM were corrected.

### Results

| suite | result |
|---|---|
| `run-specs.lisp` | **1073/1073** |
| `run-ci.lisp` (unit) | **291/291** |
| `run-error-specs.lisp` | **235/235** |

`tests/ci-stop.txt` moved to `166-device-memory`.

### What is NOT done

- **The published Intel benchmark numbers have not been re-run.** The harness changed, so
  every Crisp row in the Intel section was measured with the old allocator. Expect ~+9% at
  2048 and ~0 elsewhere on this kernel; other kernels are unmeasured.
- **`sycl_apples` / `sycl_control` still mix `malloc_shared` and `malloc_device`** (section 2).
  Eight one-line changes, but they move published peer numbers, so they want their own pass
  with a re-run rather than a drive-by edit.
- **The CUDA tripwire has not actually run.** Specs 01–03 carry `TEST-HOIST[CUDA]:
  validate-cuda-host-run`, but nvcc is absent on this machine and all three SKIPped. CI or a
  pod will be the first thing to execute them. The CUDA path itself was not modified.
- **`docs/reference.md` was not regenerated.** It scans `src/**` only, so the new functions —
  which live in the overlay — would not appear. Regenerating belongs with the fold into
  `src/hoist-l0/main.lisp`, not before it. `scripts/call-graph.lisp` explicitly excludes
  `hoist`/`hoist-l0`, so it needs nothing. `docs/ideal_001.md` never described this layer.
- **Out-of-core.** Section 4(c). Its own endeavour, after a language design conversation.

## 6. The tests

Three specs, each carrying both an L0 text check and an on-metal run, because they fail for
different reasons and both must hold — a launcher that allocates device memory and never
fills it satisfies the first and not the second.

| spec | emission site it pins |
|---|---|
| `01-tensor-device-memory` | `%l0-emit-tensor-arg` |
| `02-cell-device-memory` | `%l0-emit-cell-arg` |
| `03-global-scratch-device-memory` | `%l0-emit-global-scratch-tensor-arg` |

`validate-l0-device-memory` (new, in `overlays/spec-runner-overlay.lisp`) asserts three things
as text, so it runs with no GPU: no `zeMemAllocShared`, at least one `zeMemAllocDevice`, at
least one `zeCommandListAppendMemoryCopy`. A launcher that allocates nothing passes trivially
— failing it would push future specs into adding a dummy buffer to satisfy the validator.

The TDD order held: before the implementation all three failed on all three clauses, and
`validate-l0-host-run` passed, which is what pinned the behaviour that had to survive.

Two things from the original plan were dropped as unnecessary once the flag went away: a
`04-shared-mem-still-works` spec (there is no shared path left to keep working) and a negative
test for a bad `--hoist-mem` value (there is no such flag). The CUDA tripwire did not need its
own file — specs 01–03 carry the `TEST-HOIST[CUDA]` directive.

**The real regression net was the existing suite**, as predicted: 90 `TEST-HOIST[L0]` specs and
119 `HOIST-EXPECT` assertions already exercised the print path, which is exactly what had to
learn to stage D2H. They caught the one thing that broke.

## 7. Artifacts

- `put_temp_files_here/usm_probe/make_probe.py` — generated the probe from the harness as it
  was BEFORE this endeavour. It no longer applies: the harness it patches is now the device
  one. Re-running the shared-vs-device comparison means checking out the harness at b51c3fe.
- `put_temp_files_here/usm_probe/probe_usm_l0.cpp` — the three-arm probe, generated.
- `put_temp_files_here/usm_probe/run_probe.sh`, `run_probe2.sh` — in-container probe arms.
- `put_temp_files_here/usm_probe/results.jsonl`, `results_2048.jsonl`, `results_cold.jsonl`.
- `put_temp_files_here/usm_probe/apply_harness.py` — the edit applied to the shipped harness.
- `put_temp_files_here/usm_probe/verify_harness.sh`, `results_harness.jsonl` — the shipped
  harness re-measured on BMG after the change (section 5).

Reproduce:

```
docker run --rm --device=/dev/dxg -v /usr/lib/wsl:/usr/lib/wsl -v "<repo>:/workspace" \
  -w /workspace -e SPV=benchmarks/matmul/sec2_top/matmul_bmg.spv \
  crisp-bench-intel:latest bash put_temp_files_here/usm_probe/run_probe.sh
```
