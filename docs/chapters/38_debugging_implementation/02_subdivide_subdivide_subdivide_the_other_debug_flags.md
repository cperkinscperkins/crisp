## Subdivide Subdivide Subdivide - the "other" debug flags


Three debug flags govern subdivision by scope, target, and call site. Two more flags
let you select which workgroups or warps are participating in the logging, and the
logging mode.  That's a lot of terms, but the whole system is pretty straightforward.

### --logging-scope

`--logging-scope=spread|dedicated`

If the scope is "dedicated" then the entirety of the logging buffer will be available
to one "target" which is either a workgroup or a warp (selected by target and index flags).  
But if the scope is "spread", then the buffer is evenly split by the number of workgroups.

Default is `spread`.

### --logging-target

`--logging-target=workgroup|warp`

If the scope was `dedicated` then this simply specifies workgroup vs warp.
If the scope was `spread` and `warp` is chosen, that means only one warp per workgroup
will be enabled for logging, and each takes the full share set aside for its parent workgroup.
If scope was `spread` and the target is `workgroup` then each workgroup gets an equal share 
of the buffer.

Default is `workgroup`

### --logging-by-call-site

`--logging-by-call-site`

This option is ONLY available with dedicated debug logging scope ( `--logging-log-scope=dedicated` ).
With this option all the possible debug "call sites" (ie the lines that use `(maybe)` constructs
or call `r-t-assert` etc ) up and down the call chain of the kernel are identified and counted.
Then the debug output buffer is subdivided by call sites.  Thus each one get a little reserved
output area for itself.

### --logging-mode

`--logging-mode=first-n|last-n`

When set to `first-n` then the messages are output into the buffer subdivision until it is full, then
they stop. When set to `last-n`, then the buffer subdivision is treated as a circular buffer and the
later entries overwrite the earlier ones. 
IMPORTANT NOTE: `last-n` mode requires the debug log target be warp (`--logging-target=warp`).

Defaults to `first-n`

### --logging-wg-index

`--logging-wg-index=0-N`

This flag is only relevant if the scope is set to dedicated (`--logging-scope=dedicated`).

When using dedicated scope Crisp needs to know which workgroup. This flag can be given
a group number (from 0 up to the number of workgroups).

### --logging-warp-index

`--logging-warp-index=0-N`

This flag is relevant whenever the debug target has been set to `warp` (in BOTH `spread` and `dedicated` scopes).

Select which warp in a workgroup should perform debug logging to the buffer. It can be the warp number (from 0 to the max number of warps, ie 32) 

