# What a caller can ask ✅


| About | Calls |
| --- | --- |
| the compile | `crisp_compile`, `crisp_status_string`, `crisp_diagnostic_*`, `crisp_diagnostics_text` |
| modules | `crisp_module_count`, `crisp_module_binary` (PTX is also NUL-terminated) |
| kernels | `crisp_kernel_count`, `crisp_kernel_name`, `crisp_kernel_grad_of` |
| physical argument slots | `crisp_slot_count`, `crisp_slot_type`, `crisp_slot_size`, `crisp_slot_address_space` |
| declared parameters | `crisp_param_count`, `crisp_param_name`, `crisp_param_kind_of`, `crisp_param_direction`, `crisp_param_element_type`, `crisp_param_rank`, `crisp_param_layout`, `crisp_param_address_space`, `crisp_param_adjoint_of` |
| where a part goes | `crisp_param_slot(ctx, m, k, p, ROLE, axis)` -- ROLE is VALUE, POINTER, BYTE_SIZE, OFFSET, STRIDE, EXTENT, LENGTH or FIELD |

A parameter is what the Crisp source declares; a SLOT is what the launch API receives.  A tensor
parameter becomes a pointer, a byte size, an offset / stride / extent per axis and a length.  The
caller asks by ROLE rather than learning that layout.  BYTE_SIZE is in bytes; offsets, strides,
extents and length are in elements.

`crisp_param_layout` matters to anyone holding a non-contiguous view: a `:compact` tensor kernel
reads neither offsets nor strides (the data must be dense and start at the pointer), a
`:compact-offset` one adds the offsets, and only a `:strided` one honours both.

For a `_grad` kernel, `crisp_kernel_grad_of` names its primal, and `crisp_param_adjoint_of` says
which primal parameter each adjoint belongs to.  An IN adjoint carries the incoming gradient of an
`&out`; an OUT adjoint receives the computed gradient of an input.  A scalar's gradient comes back
through memory, as an OUT cell.

Still to come, added as the dogfood launcher (below) needs them 📝: implicit parameters the caller
must supply (scratch buffers and their sizes, the debug log, tensor-map descriptors), and launch
geometry (global / local size and group counts, which can be derived from argument values).

