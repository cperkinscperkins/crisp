# Deferred: cluster-scale topology (`def-topology` / `def-orchestration`)


Everything above targets **one** GPU.  A larger design — `def-topology` describing a multi-device
mesh or fabric, `def-orchestration` placing data across it with `:distribution` / `:location`, and
cross-device transfers over a `:p2p` / `:pcie` / `:pgas-fabric` barrier — is **set aside for now**
and lives in [`topology.md`](topology.md).  It remains the intended direction for multi-GPU,
cluster and out-of-core work.

Nothing above depends on it.  The single-GPU MMA optimization arcs stand on their own, and
`make-async-barrier` no longer takes the cross-device `:type` key that design assumed.


