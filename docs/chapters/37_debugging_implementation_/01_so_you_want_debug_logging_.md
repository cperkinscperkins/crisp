# So You Want Debug Logging ✅


#### `--logging-output`  Master Switch.

The `--logging-output` flag turns ON debug logging when it is present, or off when it is not.

When the `--logging-output` flag is set then the compiler alters the compilation in several ways:
- an additional `debug-vector-type` argument is added to the Kernel in the first argument position
- every `r-t-assert` and `r-t-output` variant is actually enabled and compiled, rather than being
  stripped out
- `maybe` `Err:` string expressions are compiled to output as well
- those function call paths to those outputting forms ALSO have their params modified such that
the debug vector is now in the first param position
- `(is-logging?)` expression evaluates to T at compile time.

The debug output vector base type is a `(vector ulong :align :compact :address-space :global)` and it must
be setup by the host. In this part of the document we refer to this vector as "the debug buffer" or 
just "the buffer". 

