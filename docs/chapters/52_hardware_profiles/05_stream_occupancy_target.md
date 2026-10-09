# `:stream-occupancy-target` ✅


`:stream-occupancy-target` is the number of threads per compute unit that kernels with a **stream
loop** (`loop-vector-stride`, and so `reduce-vec`) should aim for on this device.  It is applied
automatically, exactly as if each such kernel had declared `(occupancy-target N)` (see the
declaration under the kernel declarations); a kernel's own declaration always wins, and
`(occupancy-target nil)` opts a kernel out.

```
:stream-occupancy-target 1024
```

It is a MEASURED key: no query can answer it, so sweep it or leave it out.  Absent means no bound --
the backend compiler's default.  On an H100 SXM 1024 took every streaming reduction to 96-97% of the
measured read peak (last-man sum from 75%, argmax from 80%, Welford from 78%); see
`tests/spec/182-nvidia-register-budget/` for the sweep and `scripts/182-pod-budget.sh` for the method.

A profile is selected at the command line with
`--hardware-profile=<NAME>`, or named by a `compute-unit` in a
`def-topology` (see [`topology.md`](topology.md)).

