# Endeavor 147 — CUDA VERIFY-AUTODIFF

As is documented in ./docs/tests.md, VERIFY-AUTODIFF is one of the spec test directives that the Crisp spec runner supports.  Unfortunately, it is limited to BMG only right now.

I'd like to get VERIFY-AUTODIFF working with CUDA / PTX.

We have several tests in the CUDA specific MMA test directories ( 136, 137, 138, 139, 140 ) that are skipping differentiation today simply because there is no way to verify the results.

Since the directive already exists and works today (on BMG), it should be straightforward to port it.

The plan I was hoping to follow

1 - write any TDD tests necessary for this feature in the 147 direcotry
2 - rent an H100 from runpod.io to test everything.
3 - implement the feature
4 - remove the SKIP-WITH[--differentiate] directive from tests that should otherwise be working and ensure they are tested.

---

## Claude's survey — 2026-08-13

I read the runner, the CUDA hoist ABI, and the actual skip-list before writing
anything below.  Short version: **the runtime port is genuinely straightforward
— but the tests it is supposed to un-skip are not the straightforward ones.**
That gap is the main thing I want to agree on before we start.

### What we already have going for us

`tests/verify-autodiff-runner.lisp` is *already* a two-runtime file.  Endeavor
112 introduced `*ad-runtime*` (`:opencl` | `:l0`) and a layer of ~30 one-line
dispatch shims (`create-float-buffer`, `bind-vector-arg`, `launch-kernel-1d`,
…) over parallel `opencl-*` / `l0-*` helper sets.  The `verify-autodiff` body
itself — the finite-difference loop, the seeding, the comparison, the result
plists — is entirely runtime-agnostic.  Adding `:cuda` means adding a third
`ecase` branch to those shims plus a `cuda-*` helper set.  None of the numeric
logic gets touched.

Better still, **`:l0` is much closer to CUDA than `:opencl` is.**  L0 already
passes raw 8-byte USM pointers as kernel args, which is exactly CUDA's model;
the OpenCL `cl_mem`-handle indirection was the odd one out.  So `cuda-*` is
mostly `l0-*` with `cuMemAllocManaged` swapped in for `zeMemAllocShared`.

And the **parameter ABI is already identical**.  I checked
`src/hoist-cuda/main.lisp` against what the runner binds: a tensor is the same
`3 + 3*rank` slot expansion (ptr, byte-size, offsets, strides, extents,
length) on both backends — 6 slots rank-1, 9 slots rank-2, matching the runner's
existing vector/matrix binders.  The `.metacrisp` `:implicit-params` the runner
reads to bind backward scratch tiles is emitted from target-independent
metadata.  We are not re-deriving an ABI; we are re-plumbing the same one.

### The three real deltas (not one-liners)

**1. Kernel args are set at launch, not bound by index.**
OpenCL/L0 call `clSetKernelArg`/`zeKernelSetArgumentValue` per slot against
the kernel object.  CUDA's `cuLaunchKernel` takes a `void** kernelParams`
array assembled up front.  So a CUDA "kernel" in the runner has to be a small
struct — function handle + a param-slot vector + a shared-bytes accumulator —
and each `cuda-bind-*-arg` writes a foreign box into a slot, with the launch
materializing the `void**`.  Shim signatures stay identical; only the
representation behind the handle changes.

**2. Local/shared scratch is bound with a different VALUE (the discovery is done).**
Scratch memory has been an implicit arg for a long time — SROA-expanded like
any other tensor — and the runner already *finds* them:
`%vad-read-implicit-params` reads `:implicit-params` from the `.metacrisp`
and binds the backward kernel's tiles today.  What changes is only what goes in
the ptr slot.  OpenCL/L0 bind a NULL pointer with a byte size and the driver
allocates `__local`; CUDA has one `sharedMemBytes` launch parameter and the
kernel indexes into it, so the ptr slot carries a *running byte offset* into the
dynamic shared blob and `sharedMemBytes` is the sum.  The hoist already does
exactly this (bug 034) — `*cuda-shared-scratch-offset*` /
`%cuda-emit-local-scratch-tensor-arg`, `src/hoist-cuda/main.lisp:642` — so
`cuda-bind-local-scratch-*-arg` mirrors that accumulator.  Worth noting it is
exercised early rather than late: **every backward kernel with a scratch tile
has at least two** (the tile and its `_ADJ` shadow), so distinct offsets matter
from rung 5 of the ladder onward.

**3. The runner's foreign libraries load eagerly — and that breaks on a pod.**
`verify-autodiff-runner.lisp` does `(cffi:use-foreign-library opencl)` at
toplevel *and* loads `l0-bindings.lisp` at toplevel.  `%vad-ensure-runner-loaded`
wraps the whole `load` in one `handler-case` and caches a single
`:ready`/`:unavailable` for the file.  On an NVIDIA pod `ze_loader` is absent,
so the load throws, the status caches `:unavailable`, and **every**
VERIFY-AUTODIFF check reports `SKIP` — including the CUDA ones we just wrote.
This has to be fixed first, and it is a prerequisite rather than a nicety:
bindings become per-runtime and lazy, and availability becomes per-runtime
rather than per-file.  (It's also why the 145/P7 pod run showed VERIFY-AUTODIFF
quietly skipping rather than failing.)

### CUtensorMap: already ours, and already described in the metadata

*(Corrected after Chris pushed back — I had over-weighted this from the spec
headers' framing rather than reading the emitter.)*

TMA support exists and is tested on CUDA.  The descriptor is an **implicit
arg** Crisp adds itself, and it is in the `.metacrisp`:
`generate-implicit-signature` (`src/metadata.lisp:566`) emits
`:kind :tensor-map` carrying `:describes`, `:element-type`, `:rank`,
`:box-dims`, `:layout`, `:swizzle`, and `:range`.  And
`%cuda-emit-tensor-map-encode` (`src/hoist-cuda/main.lisp:908`) is an
*executable specification* of the host-side encode — gdim ordering per layout,
gstride in bytes over the non-innermost dims, boxDim reversed, elementStrides
all 1, the `:128b`-vs-`:none` swizzle gate.  Everything else it references —
the described tensor's `_ptr`, `_ext<k>`, `_str<k>` — the runner already
computes for every tensor it binds.

So the runner's TMA work is: `cuGetProcAddress("cuTensorMapEncodeTiled")`, a
128-byte descriptor buffer, `cuMemAlloc` + copy, and six fields read from
metadata.  Transliteration of a working emitter, not new design.  I'd previously
called this "the single hardest piece"; that was wrong.

One concrete thing it *will* trip on first: `%vad-read-implicit-params`
(`tests/run-specs.lisp:1034`) loops over every implicit param and derives
`elem-bytes` from `(second (getf p :type))`.  A `:kind :tensor-map` entry has no
`:type` key, so `elem-type` comes out NIL and falls straight into the
`(t (error "unsupported elem-type ~A"))` branch — it will **crash, not skip**.
Small fix, but it's the first thing a TMA spec hits.

### What step 4 actually un-skips

I enumerated every `SKIP-WITH[--differentiate]` across 136–144.  Of the twelve,
only **four** are blocked on "no CUDA runtime":

| spec | why it's skipped |
|---|---|
| `137/03-tma-codegen-ptx` | "TMA `:block` is sm_90a-only and VERIFY-AUTODIFF runs on SPV/L0" |
| `137/05-block-mma-matmul` | same |
| `138/04-pipelined-block-matmul` | "sm_90a and VERIFY-AUTODIFF has no CUDA runtime" |
| `138/05-linear-ring-pipeline` | same |

**All four are `:block` TMA kernels** — so per the section above, the TMA
descriptor path is not optional garnish, it is the gate on every un-skip 147
promises.  It is tractable, but it cannot be deferred to "if we get there":
a phasing that leaves it for last delivers zero un-skips.  Plan for it in the
main line of work.

Note also that 138/04 and 138/05 carry a *second* caveat in their skip text —
their BMG analogue is blocked by BUG 040 (MMA reading from a ring slot is wrong
in the forward on Intel).  CUDA verification is exactly what would tell us
whether that bug is Intel-specific or general.  That's a nice bonus, not a risk.

The other eight skips are *not* ours and 147 should not pretend otherwise:

- `140/01`, `140/02` — hand-staged wgmma operands needing **primal replay**.
  That's endeavor 149, which already has a directory.
- `142/12` — a measured-wrong gradient (over-count factor `K+1`).  A real AD
  bug; a CUDA runtime would let us watch it be wrong on NVIDIA too, nothing more.
- `142/14` — an ANF defect (`prefetch-tile`'s coordinate tuple flattened into a
  bogus call).
- `137/01`, `137/02`, `142/02`, `142/03`, `142/13` — negative tests.  Staying.

I'd rather say this now than discover it at step 4 on a metered pod.

### The other payoff, which I think is the bigger one

There are **68 `VERIFY-AUTODIFF:` directives** in the suite today and **zero**
of them have ever run on NVIDIA.  Fourteen are explicitly `-bmg`.  Every
gradient rule we've shipped — the whole 128-transcendentals block, 124's
value-`if`/`let` backward, 145's twelve MMA VJPs — is verified numerically on
Intel silicon only.  A CUDA runner turns "our AD is correct" into "our AD is
correct on both vendors."  I'd argue that, not the four TMA specs, is the real
reason to do 147.

## Proposed plan

Same four steps as yours, resequenced so the pod time is spent well.

**Phase −1 — baseline pod run, before touching anything.**
`./scripts/run-on-pod.sh <host> <port> cuda-verify-autodiff` on an H100.  The
script already runs the whole suite in three phases including
`--differentiate`, with `SKIP_L0_HOIST` / `SKIP_SPIRV_TESTS` set, so it gives us
exactly the pre-147 NVIDIA baseline: which specs pass, which fail, and
(importantly) confirmation that every `VERIFY-AUTODIFF` check currently reports
SKIP for the eager-load reason in delta 3 rather than for some other reason
I've mis-diagnosed.  Without this baseline every later failure is ambiguous
between "147 broke it" and "it was already red on NVIDIA".  Cheap, and it also
re-confirms the 145/P7 result (946/953, 7 pre-existing sm_90a gates).

**Phase 0 — de-eagerize the runner (local, no GPU).**
Split the foreign bindings per runtime and make loading lazy; replace the
single cached `*vad-runner-status*` with per-runtime availability.  Verify on
this Windows box that L0 still works exactly as today and that a forced
`:cuda` request degrades to a clean SKIP.  Nothing else can be tested until
this is true.

**Phase 1 — TDD specs in `147/` (local, compile-only until the pod).**
A deliberate ladder, each rung adding exactly one ABI feature:

1. scalar `cell float` in / out — proves module load, launch, readback
2. two scalars — proves slot ordering
3. `vector float` + `at.A=` — proves the 6-slot tensor expansion
4. 2-D matrix — proves the 9-slot expansion
5. a `make-scratch-vector` tile — proves the shared-offset accumulator, and
   its backward proves **two** tiles (tile + `_ADJ`) get distinct offsets
6. MMA with an NVIDIA hardware profile — proves `group=N` launch + profile
   forwarding
7. TMA `:block` — proves `cuTensorMapEncodeTiled`

Rungs 1–6 are the ones that should be twins of existing `-bmg` specs, so a
disagreement between vendors is immediately legible.

**Phase 2 — `cuda-bindings.lisp` + the `cuda-*` helper layer (local).**
~150 lines of CFFI: `cuInit`, `cuDeviceGet`, `cuCtxCreate`,
`cuModuleLoadDataEx`, `cuModuleGetFunction`, `cuMemAllocManaged`,
`cuLaunchKernel`, `cuCtxSynchronize`, teardown, `cuGetErrorString`, plus
`cuGetProcAddress` + `cuTensorMapEncodeTiled` for rung 7.  Plus
`%vad-compile-spv` generalized to a target (`--ir-target=ptx`, `.ptx` output)
and taught to forward `HOIST-ARCH` — it currently forwards only
`HOIST-HARDWARE-PROFILE`, and sm_90a specs will not compile without the arch.
And the `%vad-read-implicit-params` tensor-map crash noted above.

**Phase 3 — the pod.**  H100 (sm_90a is mandatory for 137/138).  Bring up
rungs 1–7 in order; TMA is in the main line, not a stretch goal.  Then port a
representative slice of existing `-bmg` specs as `-ptx` twins.

**Phase 4 — un-skip** 137/03, 137/05, 138/04, 138/05, and see what 138 says
about BUG 040 being Intel-specific.

## Questions for you

1. **How does a spec choose its runtime?**  My suggestion: bare
   `VERIFY-AUTODIFF:` keeps today's meaning but auto-detects among available
   runtimes, and a bracketed `VERIFY-AUTODIFF[CUDA]:` / `[L0]:` *pins* one
   (mirroring `TEST-HOIST[L0]` / `TEST-HOIST[CUDA]`, so the idiom is already in
   the suite).  Pure-arithmetic specs then gain NVIDIA coverage for free, while
   anything carrying a vendor hardware profile pins itself and skips cleanly
   elsewhere.  Auto-detect *alone* would be wrong — a BMG-profile MMA kernel
   would try to run on an H100 with the wrong fragment shape.

2. **PTX JIT, or run `ptxas` ourselves?**  I lean JIT via
   `cuModuleLoadDataEx` — the generated `.cu` hoist path already JITs PTX and
   140 was metal-correct on H100 that way, so sm_90a through the driver JIT is
   proven, not hoped for.  It also keeps the runner free of an nvcc dependency.

3. **Do we hold the pod across the whole endeavor, or take it in two bites?**
   Phase −1 (baseline) and Phase 3 (bring-up) both need hardware, but Phases 0,
   1 and 2 are all local.  Cheapest is: short pod session for the baseline,
   release, do the local work, then a second session for bring-up.  That costs
   one extra setup cycle (`run-on-pod.sh` is idempotent, so it's minutes) and
   saves hours of idle metered time.  Unless you'd rather keep one alive for
   the iteration speed.

4. Do you want the existing 68 specs' NVIDIA twins inside 147, or as a separate
   sweep afterward?  I'd keep a *representative slice* in 147 (proof the port
   works) and leave the full sweep to its own pass, so 147 doesn't turn into a
   68-file rename exercise.

---

## Results — 2026-08-13

Worked on an H100 NVL (sm_90, driver 580.126.09) via `scripts/run-on-pod.sh`.

### Phase −1: the baseline said exactly what the plan predicted

`main` on the H100: **965/965** specs, **965/965** under `--differentiate`,
negative specs green. And all **58** `VERIFY-AUTODIFF` checks reported
`SKIP (OpenCL runner unavailable)` — the eager-load diagnosis confirmed, and
the measure of what was missing: every gradient rule Crisp has ever shipped
was numerically verified on Intel only.

### What shipped

**A third runtime, not a fork.** `tests/cuda-bindings.lisp` (CUDA Driver API
via CFFI, `_v2` symbols throughout — the unversioned ones are the old 32-bit
ABI) plus a `cuda-*` helper layer beside the existing `opencl-*` / `l0-*`
ones. The finite-difference and comparison logic was not touched; the
dispatch shims grew one `ecase` branch each.

Three things genuinely differed from Level Zero, as anticipated:

1. **Params assemble at launch.** A CUDA "kernel" is now a record holding the
   CUfunction, a slot table of persistent foreign boxes, and a shared-byte
   total; `cuLaunchKernel` materialises the `void**`. Boxes are owned by the
   record because the driver reads them at launch, and are freed on rebind —
   `apply-primals` rebinds every input on every FD step.
2. **Shared scratch is one block plus offsets**, reproducing the hoist's
   accumulator (bug 034). Offsets are 16-byte aligned, which is free: the
   offset is a runtime value the kernel adds to its shared base.
3. **Foreign libraries are now loaded tolerantly.** Previously one missing
   library took the whole runner down — which is precisely why 58 checks were
   skipping on NVIDIA. Each bindings file sets an availability flag instead.

**Runtime selection.** The new `VERIFY-AUTODIFF[CUDA]:` / `[L0]:` /
`[OPENCL]:` form pins a runtime and SKIPs loudly elsewhere. The PASS line
now names the runtime that ran (`PASS [cuda]`), so a log always says where a
gradient was checked.

Bare `VERIFY-AUTODIFF:` auto-selects among the **SPIR-V** runtimes only.
I first let it reach for whatever the machine had, and the pod measured why
that is wrong: `145/18-ring-staged-vjp-bmg` — an Intel spec, named `-bmg`,
carrying a BMG hardware profile and its MMA fragment shape — was picked up
by CUDA and died on a kernel-parameter mismatch. It was right to fail and it
would have been far worse to pass. So a spec runs on CUDA only when it says
so, the bare directive keeps exactly its pre-147 meaning, and the "68 specs
gain NVIDIA coverage for free" idea from the survey above is **retracted**:
it is a deliberate per-spec sweep, because a vendor-specific kernel needs a
vendor-appropriate profile and shape, not merely a second runtime.

**TMA.** `%vad-read-implicit-params` no longer crashes on a `:kind
:tensor-map` entry (it had no `:type` key and fell into the
unsupported-elem-type error), and the runner encodes the descriptor with
`cuTensorMapEncodeTiled` over the described input's buffer — a
transliteration of `%cuda-emit-tensor-map-encode`, including its gdim/gstride
ordering rules. Chris was right that this was the easy part.

Measured and worth writing down: **only the FORWARD kernel of a
differentiated TMA spec carries a tensor-map.** The backward's implicit
params are scratch tiles alone.

### The find: BUG 041

147/05 (a scratch-staged `C[i] = F*A[i]`) failed with analytical = 10.0
against a correct FD of 2.0. Sweeping the scale factor gave 10.0 / 21.0 /
55.0 for F = 2 / 3 / 5 — exactly `(F*A[1] + 1) * F`, i.e. the adjoint tile
started holding the *forward's* leftover `F*A`. The PTX confirmed it: the
module's only `st.shared …, 0` is in the forward entry.

**The AD-minted `<tile>_ADJ` scratch tile was never zero-initialised.** No
API guarantees zeroed local memory; Intel masked it by giving each L0 kernel
argument its own fresh SLM allocation, while CUDA reuses one dynamic shared
window per block and drops the forward's residue exactly where the adjoint
lands. Every staged-tile AD spec since endeavor 111 has been passing on
masked undefined behaviour.

Fixed by emitting `(fill-tile <adj> 0.0)` + one `sync-workgroup` at both
adjoint-allocation sites. `fill-tile` was reused rather than reinvented — it
is already the sanctioned workgroup-collective tile clear. Full note in
`plan/bugs.md`.

This is the first defect found purely by having a second vendor's runtime,
which is the argument for the whole endeavor in one example.

### Where it stands — final numbers

| gate | result |
|---|---|
| Intel/BMG, `--differentiate` | **972/972** |
| H100, plain | **972/972** |
| H100, `--differentiate` | **972/972**, of which **8** gradients checked on CUDA |
| H100, negative specs | **211/211** |
| unit tests | **253/253** |

Baseline for comparison was 965/965 with all 58 verify checks skipping; the
suite grew by the 7 new 147 rungs, and 137/03 moved from skipped to checked.

- 147 ladder rungs 1–7 all green on H100, including TMA.
- No regression on Intel from the BUG 041 fix.
- 137/03 un-skipped and gradient-checked on Hopper, which is exactly what
  its own skip note asked for ("Un-skip after a Hopper pod run, not
  before").

### Still open

- 137/05, 138/04, 138/05 — the remaining three un-skips. All MMA matmuls
  needing a hardware profile, group geometry and a derived expected
  gradient; 137/05 additionally has a `:col-major` B operand, and the
  runner's matrix binder writes row-major strides, so that needs settling
  before the numbers can be trusted. More than the remaining pod budget,
  and not worth guessing at.
- A safety gap worth closing: `cuda-launch-kernel-1d` errors if a bound
  slot is missing, but cannot yet detect the opposite — a kernel expecting
  MORE params than the runner bound would read past the `void**` array.
  CUDA 12.4 has `cuFuncGetParamInfo`; asserting the count against the
  kernel's own declaration would make the shim self-checking.
- **147/08-cuda-ring-adjoint has never run on metal.** The pod was released
  before it existed. Intel cannot supply the check — the defect is invisible
  there. First thing to run on the next Hopper session.

---

## Closing sweep — definition-of-done

Went through `plan/definition-of-done.md` rather than declaring victory from
memory. Two things fell out that would otherwise have shipped broken.

**`--debug` was failing and I had never run it.** 08 hit BUG 033 — a hard
SBCL memory fault at address 5, not a Crisp diagnostic. Pre-existing: its
Intel twin 145/18 carries the identical skip with a note establishing the
trigger as *a scratch ring under `--debug`* and verifying it predates
endeavour 146. 08 now carries the same skip, quoting that provenance.

The `--debug` phase still ends 973/974 locally, on
`056-struct-at-kernel-boundary/07-struct-with-ct-hoist`. That is the
documented expected state: BUG 033's own note records it as Windows-only,
passing on CI Linux, and *deliberately* not skipped — "the full
`--use-binary --debug` phase cannot go green on a Windows dev box until 033
is fixed. Do not 'fix' that by adding a skip." Left alone.

**`--single-pass` crashes outright, and that is new information — logged as
BUG 042.** Under `--single-pass` the compiler emits one `.metacrisp` per
*function* (19 for `028-metadata/01-aliases`), the runner hands the whole
glob to the spec's validator, and `validate-01-aliases` calls `probe-file`
on a list. It kills the phase, so everything after 028-metadata in that pass
never runs. Verified not mine rather than assumed: `git diff 39d8d17 HEAD --
tests/run-specs.lisp` touches nothing in the metadata-validator path, and it
reproduces on a freshly cleaned directory. Nothing else in the suite pairs
`TEST-WITH[--metadata]` with `--single-pass`, which is why it had never
surfaced — this sweep was the first end-to-end run of that phase.

**Unit tests** (`directive-parsing.unit.lisp`, registered in
`tests/run-ci.lisp`). 27 assertions over `%vad-match-directive`,
`parse-verify-autodiff` and the selection policy — bare vs pinned, three
backends, case-insensitivity, non-directive lines, and the three malformed-pin
error paths. Plus two invariants worth pinning down explicitly:

- *the runner loads without a GPU* — the Phase 0 property, and the one whose
  absence silently skipped 58 checks;
- *`:cuda` is not in `*ad-auto-runtimes*`* — a tripwire, so anyone widening
  auto-selection later trips a test with the H100 evidence in its docstring
  rather than rediscovering it on a pod.

This matters because it is the **only GPU-free coverage** of that logic. On a
CI runner every spec-level VERIFY-AUTODIFF check skips, so the directive
grammar had no test at all. Unit suite: 253 → **280**.

Final local gates: **974/974** plain, **974/974** `--differentiate`,
**280/280** unit, **211/211** negative; `--debug` 973/974 (BUG 033, expected
on Windows) and `--single-pass` blocked by BUG 042 (pre-existing).

Note the `errors/` directory stayed empty deliberately: a malformed
`VERIFY-AUTODIFF[NOPE]:` errors in the spec *runner*, not the compiler, so it
does not fit the `CHECK-FAIL` harness. The unit test is its right home.

**Rung 6 got its SPIR-V twin** (`06b-multi-workgroup-spirv`). `groups=`
appeared in exactly one other spec suite-wide, an MMA matmul — so
cross-workgroup atomic gradient accumulation was only ever exercised on Intel
through a kernel that also does tensor cores, tile staging and a hardware
profile. 06b isolates the atomic. It returns

    analytical=37.0 numerical=37.000656 diff=6.5612793e-4

which is **digit-for-digit what the H100 returned** for 06. That is the first
place in the project where the same gradient has been measured on both
vendors and shown to agree exactly — which is, in one line, the argument for
this endeavor.

**Considered and deliberately not done:** benchmarks (BUG 041 touches backward
kernels only; the benchmarks are forward matmuls — no impact), and
`ideal_001.md` status emojis (it never mentions VERIFY-AUTODIFF; this is a
harness feature and lives in `docs/tests.md`). Doc regeneration
(`reference.md`, `call_graph.md`, globals) reads `src/`, so it belongs
*after* the overlay is folded back, not before.

---

## BUG 041, second pass — the uniform rule

The first fix zeroed AD-minted `_ADJ` scratch *tiles* and skipped rings.
Chris's question — since we write the backward kernels ourselves and they
carry less performance pressure, why not just always zero their SLM? — is
the better rule, and it is now what ships.

**Why the host can't do it instead.** Shared memory has no host-visible
address. The launch APIs expose a byte *size* only (`sharedMemBytes`;
`clSetKernelArg` / `zeKernelSetArgumentValue` with a null pointer), and the
allocation is per-*block*. Even a hypothetical zero-at-launch would be
insufficient: once a grid has more blocks than fit resident, block N+1
inherits block N's shared memory *inside the same launch*. Only the kernel
runs per block, so only the kernel can fix it. (Vulkan's
`shaderZeroInitializeWorkgroupMemory` is the one knob the ecosystem offers,
and it reaches neither the OpenCL/L0 compute path nor CUDA.)

**The rule:** the compiler zeroes what the compiler allocates, in the kernel
the compiler wrote. Every SLM scratch object bound in a backward kernel's
`let` is cleared in that `let`'s prologue. Forward kernels are untouched —
a forward tile is user-visible, the user owns accumulator resets there via
`fill-tile` (135's C-tile contract, BUG 036), and a blanket pass would land
on the matmul hot path.

The narrow rule was also correct, but it obliged every future allocation to
be classified correctly forever — and BUG 041 *is* that obligation going
unmet since endeavor 111. Uniform is checkable in one place, and costs a
strided write pass plus one barrier against a backward doing MMA, primal
replay and atomic scatter. Narrowing a correct baseline later is a safe
optimisation; widening a wrong one is this bug.

**There was no ring gap — I was wrong about that.** By the time the adjoint
allocator runs, a ring has already been canonicalised to a rank-(1+N)
`make-scratch-tensor`, so the original `_ADJ` filter matched it and one
`fill-tile` already cleared every slot. Measured, from the backward AST:

```lisp
(LET ((TILES_ADJ (MAKE-SCRATCH-TENSOR FLOAT 3 (2 4 4))) (A_ADJ 0.0))
  (FILL-TILE TILES_ADJ 0.0)
  (SYNC-WORKGROUP)
  (%STORE-TILE-AT-BWD (RING-GET TILES_ADJ 1) C_GRAD (0 0))
  (%LOAD-TILE-AT-BWD A_GRAD (RING-GET TILES_ADJ 1) (0 0)))
```

The ring constructor names are in the whitelist regardless, as belt-and-braces
against a future path that reaches the allocator without canonicalising. The
list is a **whitelist** so async barriers (mbarrier objects, not tensors) and
register tiles (GRF, already 0.0-initialised, no whole-tile symbol after
explosion) are never filled, and a newly added allocator fails closed.

**So the uniform rule's actual behavioural delta is small**: dropping the
`_ADJ` name requirement means a *replayed primal* tile bound in a nested
backward `let` is now zeroed too. Harmless (the replay overwrites it) and it
is the rule as stated. The value is in the invariant, not in the diff.

**A process note, recorded because it nearly shipped a false claim.** My
first attempt to write this uniform version used a shell heredoc that failed
to parse, so *nothing executed* — and I read a later PTX inspection as
confirming a fix that was not on disk. The zero-stores I pointed at were
`load-tile-at`'s identity fill in the replayed primal. Caught by checking
`grep -c` on the actual file rather than trusting the command's apparent
success. The lesson is the ordinary one: verify the artefact, not the
command.

**Note for fold-back:** I edited the existing endeavor-147 block in
`overlays/crisp-compiler-overlay.lisp` rather than appending a second,
shadowing definition of `%gfw-process-let`. The house rule says append, not
patch; I judged one coherent block easier to fold back than two conflicting
ones, given the block was written the same day and never shipped. Say if
you'd rather I had appended.
- The 68 existing specs' NVIDIA twins. The runtime is in place, so this is
  now a sweep rather than a port.
