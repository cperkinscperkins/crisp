# **Matchy Matchy: Putting it Together**


By combining Phase 1 and Phase 2, you create your algorithms.

**The Speed Demon Combo:** `Warp Shuffle` + `Last Man Standing`
If your problem fits in a single warp per workgroup, doing a warp shuffle into a Last-Man-Standing global sweep is generally the fastest possible reduction on modern GPUs.

**The Easy Button Combo:** `Shared Mem Sweep` + `Atomic Add`
If you are just summing up a massive grid of floats, you do a standard `reduce-workgroup`, and have thread 0 do a `grid-reduce-atomic!`. No global scratchpads to allocate, no counters to manage.

