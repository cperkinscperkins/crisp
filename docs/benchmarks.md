Benchmarks
==========

We can now run benchmarks. This document is a placeholder, but the results of Crisp first comparison runs are below.

```
--- Step 5: Run benchmarks ---
=== Build phase ===
Building CUDA hand-written...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cuda/sum_reduce.cu -o /root/crisp/benchmarks/reduction/cuda/sum_reduce
  Compiled in 2.00s
Building CUB...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cub/sum_reduce_cub.cu -o /root/crisp/benchmarks/reduction/cub/sum_reduce_cub
  Compiled in 6.47s
Building Crisp (atomic-per-thread)...
  Crisp compile [sum-reduce.crisp]: /root/crisp/bin/crisp-compile --ir-target=ptx /root/crisp/benchmarks/reduction/crisp/sum-reduce.crisp
  Crisp compiled in 0.11s
  nvcc harness: nvcc -O3 /root/crisp/benchmarks/reduction/crisp/bench_harness.cu -lcuda -o /root/crisp/benchmarks/reduction/crisp/sum_reduce_crisp
Building Crisp (workgroup tree-reduce)...
  Crisp compile [sum-reduce-tree.crisp]: /root/crisp/bin/crisp-compile --ir-target=ptx /root/crisp/benchmarks/reduction/crisp/sum-reduce-tree.crisp
  Crisp compiled in 0.14s
  nvcc harness: nvcc -O3 /root/crisp/benchmarks/reduction/crisp/bench_harness_tree.cu -lcuda -o /root/crisp/benchmarks/reduction/crisp/sum_reduce_crisp_tree

=== Benchmark phase ===

crisp_tree occupancy: 0.15 (parsed from sum-reduce-tree.crisp)
  Running: cuda N=1000 ... 19.07 us (median)
  Running: cub N=1000 ... 7.65 us (median)
  Running: crisp N=1000 ... 132.64 us (median)
  Running: crisp_tree N=1000 ... 16.96 us (median)
  Running: cuda N=100000 ... 19.14 us (median)
  Running: cub N=100000 ... 11.71 us (median)
  Running: crisp N=100000 ... 134.27 us (median)
  Running: crisp_tree N=100000 ... 17.66 us (median)
  Running: cuda N=1000000 ... 27.9 us (median)
  Running: cub N=1000000 ... 11.46 us (median)
  Running: crisp N=1000000 ... 134.05 us (median)
  Running: crisp_tree N=1000000 ... 26.05 us (median)

============================================================
Compile Times
============================================================
     crisp: 0.11s
  crisp_tree: 0.14s
       cub: 6.47s
      cuda: 2.00s

====================================================================================================
Kernel Time (GPU hardware events, excludes host overhead)
====================================================================================================
         N      crisp (us)   crisp GB/s  crisp_tree (us)  crisp_tree GB/s        cub (us)     cub GB/s       cuda (us)    cuda GB/s
-----------------------------------------------------------------------------------------------------------------------------------
      1000          132.64         0.03           16.96         0.24            7.65         0.52           19.07         0.21
    100000          134.27         2.98           17.66        22.64           11.71        34.15           19.14        20.90
   1000000          134.05        29.84           26.05       153.56           11.46       349.16           27.90       143.35

======================================================================
Wall Time (includes kernel + sync + D→H readback)
======================================================================
         N      crisp (us)  crisp_tree (us)        cub (us)       cuda (us)
---------------------------------------------------------------------------
      1000          147.37           33.94           24.52           27.48
    100000          151.54           34.35           28.54           27.56
   1000000          148.71           40.66           28.01           36.36


=== Benchmark run complete ===
```