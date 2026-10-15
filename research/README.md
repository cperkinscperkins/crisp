# research/

Small, self-contained evidence that comments in `src/` and the docs cite: minimal
reproducers and probe kernels from past investigations.  Nothing here is built or run by CI.

| Directory | What it shows | Cited from |
|---|---|---|
| `igc-sroa-alias-030/` | Minimal Level Zero reproducer for the Intel IGC SROA-aliasing miscompile (BUG 030): two sibling `float` allocas, wrong output on Arc. `README.md` explains it, `loader.cpp` runs it. | `src/analysis/core.lisp`, `src/llvm-bindings.lisp` |
| `spv-call-conv-bisect/` | The InstCombine bisect that pinned the SPIR-V `-O3` call-convention bug on a hand-written module with no aggregates (needs oneAPI `opt`). | `src/compiler.lisp` |
| `165-f64-mma-probe/` | The 165 probe kernels (f64 vs f32 MMA tile shapes, store-only controls). Compile with `--ir-target=ptx` to regenerate the `.ptx` files. | `src/mma.lisp` |
