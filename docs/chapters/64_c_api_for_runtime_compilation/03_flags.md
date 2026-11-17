# Flags ✅


`crisp_set_flags` takes the same flags as `crisp-compile`, as an array.  The compiler checks them,
so a bad one surfaces from `crisp_compile` as `CRISP_ERROR_INVALID_ARGUMENT` with a diagnostic
naming it.  Refused: unknown flags, bad values, `--ir-target` (fixed by the context),
`--hoist...`, `--metadata` (metadata is always produced; query it instead), and `--log-level`.

Bitcode libraries -- NVIDIA's `libdevice.10.bc` for PTX transcendentals, or a foreign-function
library -- are linked with `--link-bitcode=PATH`, once per library.  PATH must be ABSOLUTE (the
compiler runs in its own directory, not the caller's) and must exist; a library that cannot be read,
parsed or linked fails that compile with a diagnostic.  The Python layer finds libdevice by itself
and makes `--link-bitcode=` paths absolute.

