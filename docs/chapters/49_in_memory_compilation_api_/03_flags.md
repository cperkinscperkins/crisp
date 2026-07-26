# Flags

If using the `set_tree_shake_directory()` call, then the compilation environment will
load the flags from the record there.  This ensures maximum reuse of the .crisp_lib files
that are there and keeps compilation speed at its highest.

If you need to override or change, use the `set_flags()` call.  But note that
this call is singular and should be complete. The flags set with this call are
not "additive".  Any call to `set_flags()` should include ALL the relevant flags
you want on the next call to `compile()`.

However, nearly all flags are ignored by the In Memory Compilation API. 
The only flags it respects are

- `--single-pass`
- `--no-inference`
- `--skip-c-t-checks`
- `--no-static-analysis`
- `-D`
- `--math-precision` (and `--force-math-precision` but discouraged)
- flags governing errors and warnings (TBD)

> NOTE: revisit the above assertion about "only" flags. We have added some, like --denormal-handling. Why are most flags ignored anyway? The destination and target ones make sense to skip. What about --debug , logging, log-level ?


