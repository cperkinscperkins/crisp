# Memory


Memory cannot be allocated by the kernel itself. Only the host or the compiler can do so.

There are five different categories we need to consider:
- **Global:** Set up by the host. This is your main communication channel for large data sets. Slow.  This memory CAN be set up by the compiled code of the kernel, but that is an anti-pattern. A bad idea. 
- **Local (Shared):** Set up by the host via kernel arguments. This is for fast, on-chip sharing among threads in a workgroup.  This memory CAN be set up by the compiled code of the kernel as well. 
- **Constant:** Set up by the host. This is for read-only data that's broadcast to all threads.  This memory CAN be set up by the compiled code of the kernel as well -- but MUST be done BEFORE the kernel executes. 
- **Registers:** Managed automatically by the compiler. This is for variables that need to be accessed quickly and frequently.

- **Private:** Managed by the compiler. This is for per-thread variables, analogous to a CPU stack.


-->
