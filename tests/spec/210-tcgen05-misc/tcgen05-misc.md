# Endeavour 210 — tcgen05 / benchmark follow-ups (branch `tcgen05-misc`)

Started 2026-11-08 after endeavour 209 closed.  Scope, agreed with Chris:

| # | Item | Source |
|---|---|---|
| 6 | CUDA TMA descriptors BY VALUE (`__grid_constant__`, option B) replace option A | reminder from 137 (2026-07-14) |
| 2 | `map-elements!` on a tcgen05 accumulator, so section 4 fused has a B200 Crisp row | F-209-2 |
| 4 | sec3's register growth (96 -> 164) since cc116e8c | F-209-8 |
| 3 | refresh the stale sec3 multicast report row (fenced `.cluster` numbers) | F-209-9 / D-209-14 |
| - | one H100 + one B200 rental at the end: metal proof of 6, benchmarks for 6 / 2 / 3 / 4 | |

F-209-1 was already resolved (D-209-9).  The Python wheel and FP8/FP4 are future work, not this branch.

## Steps

| Step | What | State |
|---|---|---|
| 1 | Item 6: by-value descriptor ABI, local | done 2026-11-08: suites green, PTX + ptxas + nvcc checked; metal pending (step 4) |
| 1b | Item 6 on an H100: metal specs + exact A/B + canonical sweep of 4 TMA chapters | done 2026-11-08 (9 min, ~$0.62, pod confirmed gone): all green, B = A within 1% |
| 1c | Item 6 on an H100: VERIFY-AUTODIFF[CUDA] TMA specs (only run under --differentiate) | done 2026-11-08 (3 attempts, ~$0.90 in all, every pod confirmed gone): all 6 PASS [cuda] -- item 6 metal-verified |
| 2 | Item 2: F-209-2 | not started |
| 3 | Item 4: F-209-8 | not started |
| 4 | Rentals: H100 (TMA families, 209/03, sec3 rows) + B200 (208/209 tcgen05 TMA specs, item 2 row) | not started |

## Item 6 — TMA descriptors by value

**Why.** The CUDA Programming Guide (Asynchronous Data Copies, TMA section) lists three homes for a
CUtensorMap: a `const __grid_constant__` kernel parameter ("the recommended approach"), `__constant__`
memory, or global memory.  For global memory it says the map "requires a fence in each thread block"
before use -- `fence.proxy.tensormap::generic.acquire`, `.sys` scope when the host wrote it -- and that
it "may be slower".  Option A (137) put the map in global memory and Crisp emitted no such fence.  That
is safe while every process is fresh (every spec and fixture run); a long-lived host that frees one
descriptor and gets a new one at the same address can be served the stale map from the TMA descriptor
cache.  JAX moved its descriptors to `__grid_constant__` parameters for concurrency reasons.

**Mechanism (LLVM 21.1.5, proven by hand first: put_temp_files_here/210/gc/gc_{attr,anno}.ll).**
- The kernel parameter is `ptr byval([128 x i8]) align 64`, and the kernel is named in
  `!nvvm.annotations` as `!{ptr @k, !"grid_constant", !{i32 <1-based positions>}}`.
- NVPTX then emits `.param .align 64 .b8 k_param_N[128]`, takes the address with
  `mov.b64 %rdA, k_param_N; cvta.param.u64 %rdB, %rdA;`, and passes that generic pointer to the TMA
  instruction and to helper functions.  No local copy; ptxas: 0-byte stack frame.
- **The `"nvvm.grid_constant"` PARAMETER attribute does not work in LLVM 21.1.5**: it is ignored, the
  byval bytes are copied into `.local` byte by byte, and TMA is handed a local address.  Only the
  annotation works.

**What changed (overlays; fold at endeavour end).**
- Compiler (crisp-compiler-overlay.lisp):
  - `resolve-type-to-llvm` wrapper: `(TENSOR-MAP SRC)` is a GENERIC i8 pointer (was addrspace 1).
  - `%tma-lookup-descriptor-ptr`: loads the descriptor as addrspace 0 (loading it as addrspace 1 would
    reinterpret a param-space address); the callers' casts to generic become no-ops.
  - `%210-mark-grid-constant-tensor-maps`, called from an `ensure-opencl-kernel-metadata` wrapper:
    byval + align 64 on each descriptor parameter plus the annotation.  It counts LLVM positions the way
    `%compute-kernel-cache-hints` does and ERRORS if the parameter there is not a pointer.
  - `generate-implicit-signature` wrapper: the metacrisp entry gains `:address-space :param
    :passing :by-value :bytes 128 :align 64`.
- Bindings (crisp-llvm-bindings-overlay.lisp): `LLVMCreateTypeAttribute`.
- CUDA hoist (hoist-cuda overlay, script-extracted copies): `CUtensorMap <name>;` at the ABI slot,
  encoded straight into it, `kernelParams[i] = &<name>`; option A's `cuMemAlloc` + `cuMemcpyHtoD` gone.
- Spec runner's in-process CUDA launcher (tests/verify-autodiff-runner.lisp, edited directly: it loads
  lazily, AFTER the spec-runner overlay, so an overlay copy would be overwritten): the slot holds the
  128 bytes.
- Bench fixture (benchmarks/matmul/crisp/bench_harness.cu): maps kept in a `std::deque`,
  `params[idx] = &map`; no device copy, no cuMemFree.
- New: spec 210/01 (137/04's sub-function TMA kernel) + `validate-ptx-tma-grid-constant`
  (spec-runner overlay).  Controls: passes 137/03, 137/04, sec3 multicast, chap7 tcgen05; FAILS option
  A's sec3 multicast PTX and the local-copy lowering.  `ci-stop.txt` -> 210.

**Local proof.**
- Unit 392/392, E2E 1808/1808, negative 492/492; 210/01 passes plain and `--differentiate`;
  `--differentiate` on 137 (5/5), 138 (11/11), 140 (8/8), 152 (23/23).
- PTX read by hand: 137/03 (param 0), 137/04 (param 9; helper inlined, the `.func` copy takes a generic
  pointer), sec3 multicast (two maps; the diff against step 11b's metal-verified PTX is the two
  parameters plus register renumbering), chap7 tcgen05 for sm_100a (two maps).  None has `__local_depot`.
- 137/04 hoisted: metacrisp `:range (9 9) :passing :by-value`, `kernelParams[9] = &src_tensormap_from_stage`.
- Docker (nvidia/cuda 12.4.1): ptxas sm_90a accepts the PTX; nvcc compiles the generated launcher and
  the bench fixture.

### Step 1b results — H100, 2026-11-08 (9 min, ~$0.62, pod confirmed gone)

Script: put_temp_files_here/210/step1b-on-pod.sh (the branch was pushed, so only the A/B apparatus was
shipped).  Outputs in put_temp_files_here/210/step1b/.

**Metal specs (hoisted CUDA, real launches): all pass.**  210 1/1, 137 5/5, 138 11/11, 140 7/7, 147 9/9,
209 3/3 (incl. 209/03 MMA_CORRECT), 139 12/12, 152 23/23 (the multicast ring and cluster launches ran on
CUDA), 154 3/3, 204 15/15; MMA_CORRECT reported by 137, 138, 139 (2), 140 (3), 154 (3), 204 (3), 209.
**Gap:** VERIFY-AUTODIFF runs only under `--differentiate`, so the spec runner's in-process descriptor
binding (tests/verify-autodiff-runner.lisp) was NOT exercised -> step 1c.

**Exact A/B** (put_temp_files_here/210/ab/; ab_probe.py).  A = option A: the same compiler with the four
item-6 overrides undone (twinA.lisp; its sec3 multicast PTX is byte-identical to step 11b's metal-verified
PTX), under the pre-210 fixture (815d8ac9).  B = option B under today's fixture.  TFLOPS, mean of 3,
every run verified:

| kernel | arm | 512 | 1024 | 2048 | 4096 | 8192 |
|---|---|---:|---:|---:|---:|---:|
| chap4 (1 TMA map pair) | A | 6.1 | 26.2 | 73.8 | 80.6 | 81.7 |
|  | B | 6.2 | 26.2 | 73.7 | 80.3 | 81.5 |
| chap6 tf32 | A | 10.8 | 45.9 | 78.7 | 82.6 | 82.3 |
|  | B | 10.9 | 45.6 | 79.3 | 82.7 | 82.2 |
| chap7 wgmma bf16 | A | 18.0 | 117.7 | 452.9 | 605.7 | 663.4 |
|  | B | 17.9 | 120.1 | 450.8 | 605.0 | 663.9 |
| sec3 multicast | A | 15.2 | 87.3 | 185.9 | 207.6 | 214.5 |
|  | B | 15.2 | 87.6 | 185.8 | 206.7 | 212.8 |

B = A within run-to-run noise everywhere except sec3 multicast at 4096 / 8192: -0.4% / -0.8%, tight
across its 3 runs (212.6-212.9 vs 214.4-214.5), so probably real but small.  Unexplained; candidates are
the descriptor fetch from param space vs global, or the PTX's register renumbering.  Not chased: well
under the per-pod spread, and option B is chosen for correctness (D-210-1), not speed.

**Canonical sweep** (fast precision, all verified), crisp_commit 02b25280: chap4 80 @ 8192, chap6 81,
chap7 bf16 642, sec3 cluster 225 / multicast 214 @ 8192 (206 @ 4096) -- the multicast row is now the
`.cta`-fence number (item 3 done).  Reports regenerated.

### Step 1c results — H100, 2026-11-08 (pod confirmed gone each time)

Script: put_temp_files_here/210/step1c-on-pod.sh (run-on-pod.sh with a filter for setup, then
`--differentiate` on 147 / 137 / 138).  Attempt 1: H100 SXM out of stock, no pod.  Attempt 2: a host that
took 10 min to boot and had no runpodctl, so the dead-man could not be armed and pod-session.sh refused
to run (released, confirmed gone; ~$0.70 of boot).  Attempt 3: ran (~3 min).

Every VERIFY-AUTODIFF[CUDA] spec with a TMA descriptor passes on CUDA, through the by-value binding in
tests/verify-autodiff-runner.lisp:

| spec | analytical | numerical |
|---|---:|---:|
| 137/03 tma-codegen-ptx | 1.0 | 1.0 |
| 137/05 block-mma-matmul | 0.28 | 0.27979 |
| 138/04 pipelined-block-matmul | 0.28 | 0.28027 |
| 138/05 linear-ring-pipeline | 0.28 | 0.28027 |
| 147/07 cuda-tma-tile | 1.0 | 1.0 |
| 147/08 cuda-ring-adjoint | 1.0 | 1.0 |

147: 8/9 -- the one failure, 06b-multi-workgroup-spirv, is a SPIR-V spec whose forward compile needs
`llvm-spirv`, which the pod does not have (exit 127).  No descriptor; unrelated.  137 5/5, 138 11/11.

**Item 6 is metal-verified on Hopper.**  The tcgen05 descriptor path (same code) is checked on the B200
with item 2.

**Fold-time notes** (comments only, no behaviour): src/api.lisp's `%api-param` ("one slot: a descriptor
pointer"), src/hoist/source-mode.lisp's `%hk-param-roles` (one VALUE slot -- now 128 bytes), the
`validate-ptx-tma-grid-constant` docstring's last bullet (garbled), docs/ideal_001.md's compile-API note
on TENSOR_MAP.  The compile API still reports descriptors without supporting them, as before.

## Decisions (D-210-n)

- **D-210-1.** (2026-11-08, Chris) Option B REPLACES option A; no flag to keep A.  Descriptors modified on
  the device (grouped GEMM, MoE) would be a separate feature with its own release / acquire fences.
- **D-210-2.** Inside the compiler the descriptor is a generic pointer everywhere; only the kernel
  parameter is by value.  The implicit-argument propagation through helper functions is untouched.
- **D-210-3.** The annotation, not the parameter attribute (the attribute is ignored by LLVM 21.1.5).
