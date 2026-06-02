# Compiliation Flags ✅


#### `-D`

Used to define parameter values ( see `def-parameter`)
Example: `crisp.exe -DSTART_INDEX=20` 

#### Math Flags `--math-precision` 

The `--math-precision` flag can be set to `fast` or `ieee`. But note that Crisp supports
in-file precision election. See the section on [Math Precision](#precision) above.

Also, there is a `--force-math-precision` flag that can override, but its use is discouraged.
It is intended for testing and validation and shouldn't be used generally.

#### Math Flags: `--denormal-handling`
Subnormal numbers (floats very very close to 0) sometimes have a 10x or 100x speed penalty for proper handling with floats when abiding by the IEEE standard.

If you need IEEE precision but don't want the trouble of subnormals, use the `--denormal-handling` flag.  This flag effects any block of Crisp code that is being compiled with IEEE precision. It has no effect on blocks of code marked as `fast`, regardless of its value. 

If unset, the default is `ieee`. 

When set to `flush` then subnormals are "flushed to 0"

`--denormal-handling [ieee | flush]`
Default: Linked to the precision mode (i.e., precision: `fast` implies `flush`, precision: `ieee` implies `ieee`).
Override: A user can run `--math-precision ieee --denormal-handling flush`.


