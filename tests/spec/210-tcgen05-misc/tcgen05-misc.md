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

**Not yet verified:** metal.  Step 4 runs the CUDA TMA spec families on an H100 and the tcgen05 ones on
a B200, and a before/after benchmark of chap7 / sec3 (small and large N).

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
