# Clusters and Distributed Shared Memory


Workgroup clusters (NVIDIA Hopper `sm_90` and later) guarantee that a set of workgroups are
co-resident on the same GPC.  That enables **Distributed Shared Memory (DSMEM)** and **multicast
tile loads**, where a single `load-tile` populates the shared memory of several workgroups at
once.  A kernel asks for a cluster with the `cluster-size` declaration; this
section is about what the cluster then lets a load do.

*Larger clusters constrain the hardware scheduler.  Measured on an H100, a cluster of 2 costs
nothing (0.97–1.01× against the same kernel unclustered) while a cluster of 4 can cost as much as
0.58× where the grid exactly fills the machine — and that penalty is paid whether or not you
multicast anything.  Reach for 2 before 4.*

