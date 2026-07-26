# deferred invocation 📝

NOTE: deferred FFI binding is not supported yet.

The library binding can be left unresolved and then someone needs to use nvlink (or whatever) to link cuBlas.a against someKernel.ptx 

```
crisp-compile.exe someKernel.crisp --ir-target=spv
```

