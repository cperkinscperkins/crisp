# C API for Runtime Compilation ✅


The Crisp compiler can be easily and interactively invoked from other programs. Crisp has a simple C API for this and it accepts strings for kernel code.

This is incredibly powerul. Your running application can tailor or tune a kernel at the code level interactively, compile it, compile it's _derivative_ with the `--differentiate` flag, and run. 

If setting that up seems complex, don't worry. The Crisp hoist code can generate a demonstration for you. Use the `--hoist-kernel=source` flag so the hoisting code uses a string of the kernel, rather than the .ptx/.spv. 

Crisp kernels can be compiled from a running program: hand the compile API Crisp source as
strings, plus flags, and get back the compiled kernel (SPIR-V or PTX) and everything needed to
launch it -- the kernels in it, their arguments, and which argument slot each part of each
parameter goes in.  The caller brings its own enqueue code (Level Zero, CUDA, OpenCL ...).  The
intended callers are frameworks that need forward (and backward) kernels compiled interactively,
such as PyTorch, through any FFI.

The authoritative reference is the header, `c-api/include/crisp.h`.  This section is the overview.

