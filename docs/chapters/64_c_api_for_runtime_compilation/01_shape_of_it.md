# Shape of it ✅


The following C code demonstrates how to use the Crisp Compilation API. 

```c
crisp_context* ctx = NULL;
crisp_context_create("spv", &ctx);                       /* one target per context: "spv" or "ptx" */
const char* flags[] = { "--hardware-profile=bmg", "--differentiate" };
crisp_set_flags(ctx, flags, 2);                          /* replaces, not additive */
crisp_add_source(ctx, my_source_text, "my_kernel.crisp"); /* several sources compile as one file */
if (crisp_compile(ctx) != CRISP_OK)
    fputs(crisp_diagnostics_text(ctx), stderr);

const void* bin; size_t size;
crisp_module_binary(ctx, 0, &bin, &size);                /* -> zeModuleCreate / cuModuleLoadData */
const char* entry = crisp_kernel_name(ctx, 0, 0);        /* -> zeKernelCreate / cuModuleGetFunction */
size_t s = crisp_param_slot(ctx, 0, 0, /*param*/ 0, CRISP_ROLE_STRIDE, 1);  /* where axis 1's stride goes */
crisp_context_destroy(ctx);
```

- **Strings in, bytes out.**  Inputs are copied during each call.  Everything returned is owned by
  the context and stays valid until the next compile, `crisp_clear_sources` or
  `crisp_context_destroy`.
- **One target per context.**  A second target is a second context.
- **Results are plural.**  A compile yields modules (exactly one today; `def-orchestration` will
  make it N), each holding kernels.  Under `--differentiate` a module holds each primal kernel
  followed by its `<name>_grad` kernel.
- **Facts come from small getters, one value per call**, not from structs: easy from any FFI, and a
  new fact is a new function, so adding one never breaks the ABI.  A bad index gets the getter's
  "nothing" value (0, NULL, the enum's `*_INVALID`, or `CRISP_NO_SLOT`).
- **Diagnostics** are structured (severity, message, file, line, column) and also available as one
  block of text.  Line and column are 0 today: Crisp locates errors by form path. 📝

