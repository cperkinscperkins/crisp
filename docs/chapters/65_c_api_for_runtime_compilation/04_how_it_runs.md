# How it runs ✅


The library (`crisp.dll` / `libcrisp.so`) is small and written in C: no Lisp and no LLVM are loaded
into the caller's process.  Compiles are done by `crisp-compile --serve` helper processes, started
on the first compile and kept in a small pool shared by all contexts, so different contexts compile
in parallel.  A helper that dies costs that one compile (`CRISP_ERROR_COMPILER_PROCESS`); the next
compile starts a fresh one.  `crisp_shutdown()` stops them early.

Install layout: the library sits in `<root>/bin/` beside `crisp-compile` and the LLVM tools, and
finds them there.  `CRISP_HOME` (the `<root>`) or `CRISP_COMPILE_EXE` (the full path) override.
`build/build.lisp` builds the library whenever a C compiler (`$CC`, `gcc` or `clang`) is on PATH.

A warm compile of a small kernel takes about 250 ms (Windows); most of that is the LLVM back end,
not Crisp.

