# basic invocation ✅

```
crisp-compile.exe <some.bc> <another.bc> <some.crisp> --ir-target=ptx|spv


$ crisp-compile.exe myLib.bc someKernel.crisp --ir-target=ptx
```
Just add your library .bc file as an argument to the compiler.  As a general rule, the compiler will need to know the `--ir-target` (ptx or spv, and NOT `llvmir`) to correctly lower and bind.

