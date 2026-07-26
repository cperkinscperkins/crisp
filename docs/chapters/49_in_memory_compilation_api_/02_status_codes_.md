# Status Codes ✅


When using the In Memory Compilation API in conjunction with the "tree shaking cache" <!-- RENAME -->
it is important to preserve the API between the host and the kernels it may be enqueuing.

For example, if some kernel in the cache required only 1000 bytes of scratch memory, but 
after recompilation by In Memory Compilation API it now requires 10,000 bytes, that would
be a breaking change.  The kernel, if enqueued as before, would no longer function correctly.

Other changes could result in even more severe API breakage. Query the metadata to see
if the kernel you intend to call was effected and how before attempting to use it.


```
typedef enum {
    /* The kernel compiled successfully and is compatible with the previous
        hoisting/launch requirements from the cache. */
    SUCCESS_COMPATIBLE = 0,

    /* The kernel compiled successfully, BUT its hoisting/launch requirements
        (e.g., arguments, scratch sizes) have changed. The host MUST
        re-query the kernel metadata before launching. */
    SUCCESS_BREAKING_CHANGE = 1,

    /* The kernel failed to compile.  Use get_compilation_error_code() to retrieve the actual ec.*/
    ERROR_COMPILE_FAILURE = -1,

}
```


