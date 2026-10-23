# What a caller can ask ✅


| About | Calls |
| --- | --- |
| the compile | `crisp_compile`, `crisp_status_string`, `crisp_diagnostic_*`, `crisp_diagnostics_text` |
| modules | `crisp_module_count`, `crisp_module_binary` (PTX is also NUL-terminated) |
| kernels | `crisp_kernel_count`, `crisp_kernel_name`, `crisp_kernel_grad_of` |
| physical argument slots | `crisp_slot_count`, `crisp_slot_type`, `crisp_slot_size`, `crisp_slot_address_space` |
| parameters (declared and implicit) | `crisp_param_count`, `crisp_param_name`, `crisp_param_purpose`, `crisp_param_kind_of`, `crisp_param_direction`, `crisp_param_element_type`, `crisp_param_rank`, `crisp_param_layout`, `crisp_param_address_space`, `crisp_param_adjoint_of`, `crisp_param_zero_before_launch` |
| where a part goes | `crisp_param_slot(ctx, m, k, p, ROLE, axis)` -- ROLE is VALUE, POINTER, BYTE_SIZE, OFFSET, STRIDE, EXTENT, LENGTH or FIELD |
| launching | `crisp_launch_create`, `crisp_launch_set_extent` / `_scalar` / `_resident_groups` / `_warp_size` / `_max_group_count`, `crisp_launch_compute`, `crisp_launch_local_size`, `crisp_launch_group_count`, `crisp_launch_param_bytes`, `crisp_launch_shared_bytes` |

A parameter is what the Crisp source declares; a SLOT is what the launch API receives.  A tensor
parameter becomes a pointer, a byte size, an offset / stride / extent per axis and a length.  The
caller asks by ROLE rather than learning that layout.  BYTE_SIZE is in bytes; offsets, strides,
extents and length are in elements.  A `def-record` or a fixed `(array T N)` parameter is split,
one slot per field or element in order -- FIELD 0, FIELD 1, ... (an array member of a record counts
as N fields).  A `def-struct` is ONE slot, passed by value: `CRISP_TYPE_AGGREGATE`, `crisp_slot_size`
bytes in C layout.

`crisp_param_layout` reports the alignment the kernel's author declared for each tensor (`:align`
in its `def-type`), which tells the caller what data it may pass.  A `:compact` tensor is the fast
path: the kernel indexes by extents alone, with no offset or stride reads, so it must be given
dense, row-major data starting at the pointer (in PyTorch terms, a contiguous tensor; call
`.contiguous()` on a view first).  `:compact-offset` adds the per-axis offsets.  A `:strided`
tensor honours offsets and strides, so a view's strides and storage offset pass straight through
with no copy; write the kernel that way to accept arbitrary views.  The choice stays with the
kernel's author; the API only stops the caller from guessing.

For a `_grad` kernel, `crisp_kernel_grad_of` names its primal, and `crisp_param_adjoint_of` says
which primal parameter each adjoint belongs to.  An IN adjoint carries the incoming gradient of an
`&out`; an OUT adjoint receives the computed gradient of an input.  A scalar's gradient comes back
through memory, as an OUT cell.

**Implicit parameters** ✅ -- scratch buffers the compiler added (`make-scratch-vector`,
`make-scratch-cell` ...) -- are in the same parameter list, in slot order, with
`crisp_param_purpose` = SCRATCH.  The caller allocates and binds them like any other parameter and
never reads them back.  `crisp_param_zero_before_launch` marks the ones that must be zeroed before
EVERY launch: global scratch, where reductions keep counters the kernel leaves non-zero.
Workgroup-local scratch is bound per runtime -- on Level Zero, its pointer slot gets (size = bytes,
value = NULL).  The debug log and CUDA tensor-map descriptors are reported (purpose DEBUG_LOG /
TENSOR_MAP) but not yet supported 📝.

**Launching** ✅.  A kernel's geometry declarations are often rules over launch-time values -- one
thread per element of tensor `x`, in groups of 64.  A launch object does that arithmetic: the caller
supplies the values the declarations name (tensor extents with `crisp_launch_set_extent`, scalars
with `crisp_launch_set_scalar`), and `crisp_launch_compute` returns the workgroup size, the group
counts and every scratch buffer's byte size (symbolic sizes such as `:match-num-warps-per-workgroup`
resolved).  It runs inside the library, with no compiler round trip.  The rules are the L0 hoister's:
a `:tile-shape` grid (one group per tile; past the device's `crisp_launch_set_max_group_count`
limits it is clamped under `:strided`, an error under `:exact`); `:strided` sized by occupancy,
which only the runtime knows, so the caller passes `crisp_launch_set_resident_groups` (CUDA:
`cuOccupancyMaxActiveBlocksPerMultiprocessor` x SMs; Level Zero: hardware threads / threads per
group) and a declared `:occupancy` is applied to it; `:exact`, `:one-thread-per` and `:set-to`.  A
kernel that declares no geometry gets 1 x 1 x 1 and `crisp_launch_declared` = 0: choosing a grid is
then the caller's business.  PTX local scratch (offsets into the dynamic shared block) is not yet
done 📝.

