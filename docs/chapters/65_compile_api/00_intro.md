# Compile API ✅


Crisp kernels can be compiled from a running program: hand the compile API Crisp source as
strings, plus flags, and get back the compiled kernel (SPIR-V or PTX) and everything needed to
launch it -- the kernels in it, their arguments, and which argument slot each part of each
parameter goes in.  The caller brings its own enqueue code (Level Zero, CUDA, OpenCL ...).  The
intended callers are frameworks that need forward (and backward) kernels compiled interactively,
such as PyTorch, through any FFI.

The authoritative reference is the header, `c-api/include/crisp.h`.  This section is the overview.

