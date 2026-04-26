# Builtin GPU Functions


These GPU built-in functions help inspect the execution environment. Note that all of 
these are considered "grid level" operations and CANNOT appear in the body of a `def-function`.  They can only appear in `def-grid-function`, `def-kernel` or `def-kernel-exact` . 

Many of these functions are in pairs, like `get-local-id => ulong3` and `get-local-id n => ulong`.  For the variant that takes an `n` argument, `n` must be known at compile time. 
If you need to use a runtime `n`, get the vector `ulong3` and index it `(~ (get-local-id) n)`


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
| `local-barrier` | `void` | Synchronizes all threads within a workgroup. |
| `mem-fence` | `void` | Ensures memory ordering across threads (global + local). |

- get-timestamp   returns the high resolution clock counter. ( %clock64 register).

