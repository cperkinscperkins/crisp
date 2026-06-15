# 087 — GPU Built-in Functions

## Scope

Support for the GPU built-in functions that let a kernel understand its execution
environment: thread indices, workgroup sizes, grid dimensions, barriers, and the clock.

There are OTHER GPU built-in functions (shuffle, ballot, reductions, etc.) — those
are out of scope here.

---

## Design Decisions

### `--ir-target` requirement

Several of these builtins lower to completely different LLVM calls depending on the
backend (SPIR-V uses `@llvm.spirv.BuiltIn.*` intrinsics; PTX uses
`@llvm.nvvm.read.ptx.sreg.*` or inline PTX).  There is no meaningful generic IR.

**Rule**: using any GPU built-in when `*target-backend*` is `:generic` is a
compile-time error with a clear message:

> "GPU built-in 'get-global-id' requires a target. Use --ir-target=spv or --ir-target=ptx."

**Inference**: if the user passes `--hoist=L0` (or any L0 hoist flag), the compiler
can infer `--ir-target=spv` and no error is needed.

**Phase 1 target**: SPIR-V.  PTX stubs emit a compile-time error "NYI on PTX" until
Phase 2.

### Scalar (`n`) dimension argument

Functions listed with both a 3D and a scalar-by-dimension form (e.g. `get-global-id`
and `get-global-id n`) are implemented as a **single custom expression analyzer** that
dispatches on argument count:

- `(get-global-id)` → `ulong3`
- `(get-global-id 0)` → `ulong`

The dimension argument `n` must be a **compile-time integer constant** (0, 1, or 2).
Using a runtime value is a compile-time error.

### Linear / product variants

`get-local-linear-size`, `get-global-linear-size`, `get-total-threads`, and
`get-total-groups` have no direct SPIR-V built-in — they are synthesized as products
of the corresponding 3D built-ins at compile time (constant folding if possible,
otherwise runtime arithmetic).

### Phase split

**Phase 1** — standard execution-environment functions, no subgroup extensions needed.
**Phase 2** — warp/subgroup functions requiring SPIR-V 1.3 subgroup extensions or
PTX-specific registers.

---

## Phase 1 — Built-in Functions

| Function | Return Type | Description |
| :--- | :--- | :--- |
| `get-work-dim` | `uint` | Number of dimensions the kernel was launched with (1, 2, or 3). **SPV only** — implemented as a hidden kernel parameter via the `WorkDim` built-in (SPIR-V value 40). No PTX equivalent; emits NYI error on PTX. |
| `get-local-id` | `ulong3` | 3D thread index inside the workgroup. |
| `get-local-id n` | `ulong` | Scalar thread index inside workgroup for compile-time dimension `n`. |
| `get-local-work-size` | `ulong3` | Total size of the workgroup in 3 dimensions. |
| `get-local-work-size n` | `ulong` | Scalar workgroup size for compile-time dimension `n`. |
| `get-workgroup-id` | `ulong3` | 3D index of the workgroup within the grid. |
| `get-workgroup-id n` | `ulong` | Scalar workgroup index for compile-time dimension `n`. |
| `get-num-groups` | `ulong3` | Total number of workgroups in the grid across 3 dimensions. |
| `get-num-groups n` | `ulong` | Scalar group count for compile-time dimension `n`. |
| `get-total-groups` | `ulong` | Total number of workgroups as a scalar (product of the grid dimensions). Synthesized from `get-num-groups`. |
| `get-global-id` | `ulong3` | 3D thread index within the entire grid (always starts at 0). |
| `get-global-id n` | `ulong` | Scalar global thread index for compile-time dimension `n`. |
| `get-global-id-abs` | `ulong3` | Absolute thread index: `get-global-id` + `get-global-offset`. |
| `get-global-id-abs n` | `ulong` | Scalar absolute thread index for compile-time dimension `n`. |
| `get-global-work-size` | `ulong3` | Total number of threads in the grid across 3 dimensions. |
| `get-global-work-size n` | `ulong` | Scalar global work size for copmile-time dimension `n`. |
| `get-total-threads` | `ulong` | Total number of threads as a scalar (product of the grid). Synthesized from `get-global-work-size`. |
| `get-global-offset` | `ulong3` | The starting offset of the grid in 3 dimensions. |
| `get-global-offset n` | `ulong` | Scalar global offset for compile-time dimension `n`. |
| `get-local-linear-id` | `ulong` | Flattened 1D index of the thread within its workgroup. Synthesized: `z*lws.y*lws.x + y*lws.x + x`. |
| `get-local-linear-size` | `ulong` | Total number of threads in a single workgroup. Alias: `get-local-work-size 0 * 1 * 2`. |
| `get-global-linear-id` | `ulong` | Flattened 1D index of the thread within the entire grid. |
| `get-global-linear-size` | `ulong` | Total threads in the grid. Alias of `get-total-threads`. |
| `sync-workgroup` | `void` | Synchronizes all threads within a workgroup. |
| `mem-fence` | `void` | Ensures memory ordering across threads (global + local). |

Dropped from original list:
- **`get-enqueued-local-size`**: Level Zero has no path to the OpenCL 2.0
  `EnqueuedWorkgroupSize` built-in; CUDA has no equivalent concept. Dropped.

---

## Phase 2 — Warp/Subgroup Functions

These require SPIR-V 1.3 subgroup extensions (`SPV_KHR_shader_ballot`, etc.) on the
SPV path, and PTX-specific registers/instructions on the CUDA path.  Deferred.

| Function | Return Type | Description |
| :--- | :--- | :--- |
| `get-warp-size` | `uint` | The **current** execution width (SIMD8, 16, or 32). SPV: `SubgroupSize`. PTX: `%warpsize`. |
| `get-max-warp-size` | `uint` | Maximum architectural warp width (e.g. 32). |
| `get-num-warps` | `uint` | Number of warps in the current workgroup. Synthesized: `ceil(get-local-linear-size / get-warp-size)`. |
| `get-warp-id` | `uint` | Index of the warp within its workgroup. SPV: `SubgroupId`. PTX: no direct register; computed. |
| `get-lane-id` | `uint` | Thread index within the warp. SPV: `SubgroupLocalInvocationId`. PTX: `%laneid`. |
| `get-active-lane-mask` | `ulong` | Bitmask of currently active lanes. SPV: ballot extension. PTX: `activemask`. |
| `sync-warp` | `void` | Synchronizes threads within a single warp. SPV: subgroup barrier. PTX: `bar.warp.sync`. |
| `get-timestamp` | `ulong` | High-resolution 64-bit clock counter. SPV: `ClockRealtimeKHR`. PTX: `%clock64`. |

---

## Implementation Notes

### SPIR-V lowering (Phase 1)

Each built-in maps to an `@llvm.spirv.BuiltIn.X` intrinsic call, where `X` is the
SPIR-V built-in name.  The `llvm-spirv` translator recognizes these and emits the
correct `OpLoad` from an `Input`-decorated variable.

Example mappings:
- `get-global-id` → `GlobalInvocationId` (built-in 28)
- `get-local-id` → `LocalInvocationId` (built-in 27)
- `get-workgroup-id` → `WorkgroupId` (built-in 26)
- `get-local-work-size` → `WorkgroupSize` (built-in 38)
- `get-num-groups` → `NumWorkgroups` (built-in 24)
- `get-global-offset` → `GlobalOffset` (built-in 74)
- `get-work-dim` → `WorkDim` (built-in 40, hidden kernel param)
- `sync-workgroup` → `OpControlBarrier` (workgroup scope)
- `mem-fence` → `OpMemoryBarrier`

The 3D forms return `<3 x i64>` (LLVM vector), which maps naturally to Crisp's
`ulong3` device-vector type.  The scalar-`n` forms extract element `n` with
`extractelement`.

### Synthesized functions

`get-local-linear-id`, `get-global-linear-id`, `get-local-linear-size`,
`get-global-linear-size`, `get-total-threads`, and `get-total-groups` are emitted as
inline arithmetic using the primitive built-ins.  No separate SPIR-V built-in needed.

### Context restriction

All GPU built-in functions are only valid inside `def-kernel` or `def-grid-function`
bodies (dispatch context).  Using them inside a plain `def-function` is a
compile-time error.  This aligns with the thread/grid/dispatch context model in the
design doc.
