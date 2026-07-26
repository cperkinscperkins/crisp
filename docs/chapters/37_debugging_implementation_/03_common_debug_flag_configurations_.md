# Common Debug Flag Configurations 📝


#### Default (Low Overhead):
- --logging-scope=spread
- --logging-target=workgroup

Result: The buffer is split evenly, giving every workgroup a small "first-N" log slot.

#### Focus on ONE Workgroup:
- --logging-scope=dedicated
- --logging-target=workgroup
- --logging-wg-index=42

Result: The entire buffer is given to workgroup 42 for a large "first-N" log.

#### Focus on ONE Warp:
- --logging-scope=dedicated
- --logging-target=warp
- --logging-wg-index=42
- --logging-warp-index=0

Result: The entire buffer is given to warp 0 of workgroup 42 for a "first-N" log.

#### "Last-N" (The Champagne Case):
- --logging-scope=dedicated
- --logging-target=warp
- --logging-wg-index="last"
- --logging-warp-index=0
- --logging-mode=last-n

Result: The entire buffer is given to warp 0 of the "last standing" workgroup, operating in "Last-N" (rolling) mode. This is safe because target=warp.

#### Call Sites
- --logging-scope=dedicated
- --logging-target=workgroup (or warp)
- --logging-wg-index=42
- --logging-subdivide-by-site

Result: The buffer for the dedicated target (WG 42) is subdivided, giving each log site its own "reserved" tile (running in "first-N" mode).





