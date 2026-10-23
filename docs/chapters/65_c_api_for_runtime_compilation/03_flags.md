# Flags ✅


`crisp_set_flags` takes the same flags as `crisp-compile`, as an array.  The compiler checks them,
so a bad one surfaces from `crisp_compile` as `CRISP_ERROR_INVALID_ARGUMENT` with a diagnostic
naming it.  Refused: unknown flags, bad values, `--ir-target` (fixed by the context),
`--hoist...`, `--metadata` (metadata is always produced; query it instead), and `--log-level`.

