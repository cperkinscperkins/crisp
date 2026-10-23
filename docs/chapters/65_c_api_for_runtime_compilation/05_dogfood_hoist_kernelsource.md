# Dogfood: `--hoist-kernel=source` ✅


`crisp-compile --hoist=l0 --hoist-kernel=source` generates a launcher that holds the `.crisp`
source and the compile flags as strings, compiles them at run time through this API, and takes
every argument slot from the API's answers instead of indices baked in at hoist time.  It is the
test that the API is enough to launch a kernel (the spec runner's `--hoist-kernel=source` option
runs every L0 hoist spec that way, against the same expectations).  L0 only, for now.

