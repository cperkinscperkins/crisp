Benchmarks
==========

We can now run benchmarks. This document is a placeholder, but the results of Crisp first comparison runs are below.

```
--- Step 5: Run benchmarks ---
=== Build phase ===
Building CUDA hand-written...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cuda/sum_reduce.cu -o /root/crisp/benchmarks/reduction/cuda/sum_reduce
  Compiled in 2.10s
Building CUB...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cub/sum_reduce_cub.cu -o /root/crisp/benchmarks/reduction/cub/sum_reduce_cub
  Compiled in 6.73s
Building Crisp (atomic-per-thread)...
  Crisp compile [sum-reduce.crisp]: /root/crisp/bin/crisp-compile --ir-target=ptx /root/crisp/benchmarks/reduction/crisp/sum-reduce.crisp
  Crisp compiled in 0.13s
  nvcc harness: nvcc -O3 /root/crisp/benchmarks/reduction/crisp/bench_harness.cu -lcuda -o /root/crisp/benchmarks/reduction/crisp/sum_reduce_crisp
Building Crisp (workgroup tree-reduce)...
  Crisp compile [sum-reduce-tree.crisp]: /root/crisp/bin/crisp-compile --ir-target=ptx /root/crisp/benchmarks/reduction/crisp/sum-reduce-tree.crisp
  Crisp compiled in 0.14s
  nvcc harness: nvcc -O3 /root/crisp/benchmarks/reduction/crisp/bench_harness_tree.cu -lcuda -o /root/crisp/benchmarks/reduction/crisp/sum_reduce_crisp_tree

=== Benchmark phase ===
  Running: cuda N=1000 ... 14.14 us (median)
  Running: cub N=1000 ... 5.66 us (median)
  Running: crisp N=1000 ... 109.95 us (median)
  Running: crisp_tree N=1000 ... 21.86 us (median)
  Running: cuda N=100000 ... 14.14 us (median)
  Running: cub N=100000 ... 9.25 us (median)
  Running: crisp N=100000 ... 110.02 us (median)
  Running: crisp_tree N=100000 ... 22.05 us (median)
  Running: cuda N=1000000 ... 22.69 us (median)
  Running: cub N=1000000 ... 10.46 us (median)
  Running: crisp N=1000000 ... 111.33 us (median)
  Running: crisp_tree N=1000000 ... 24.86 us (median)

============================================================
Compile Times
============================================================
     crisp: 0.13s
  crisp_tree: 0.14s
       cub: 6.73s
      cuda: 2.10s

====================================================================================================
Kernel Time (GPU hardware events, excludes host overhead)
====================================================================================================
         N      crisp (us)   crisp GB/s  crisp_tree (us)  crisp_tree GB/s        cub (us)     cub GB/s       cuda (us)    cuda GB/s
-----------------------------------------------------------------------------------------------------------------------------------
      1000          109.95         0.04           21.86         0.18            5.66         0.71           14.14         0.28
    100000          110.02         3.64           22.05        18.14            9.25        43.25           14.14        28.28
   1000000          111.33        35.93           24.86       160.88           10.46       382.26           22.69       176.30

======================================================================
Wall Time (includes kernel + sync + D→H readback)
======================================================================
         N      crisp (us)  crisp_tree (us)        cub (us)       cuda (us)
---------------------------------------------------------------------------
      1000          120.93           32.76           16.78           19.73
    100000          120.96           33.05           20.39           19.66
   1000000          122.35           35.78           21.43           28.18


=== Benchmark run complete ===
```