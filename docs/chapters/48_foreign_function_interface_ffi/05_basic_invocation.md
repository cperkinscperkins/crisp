# basic invocation ✅

```
crisp-compile.exe <some.bc> <another.bc> <some.crisp> --ir-target=ptx|spv


$ crisp-compile.exe myLib.bc someKernel.crisp --ir-target=ptx
```
Just add your library .bc file as an argument to the compiler.  As a general rule, the compiler will need to know the `--ir-target` (ptx or spv, and NOT `llvmir`) to correctly lower and bind.

`--link-bitcode=myLib.bc` is another spelling of the same argument (repeatable), and the one the runtime compile API takes (with an absolute path) -- see "C API for Runtime Compilation".

Everything the library defines is linked with internal linkage: the optimizer inlines the functions your kernels call, and the rest are deleted, so the output carries only what is used.

