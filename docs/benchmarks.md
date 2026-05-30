--- Step 5: Run benchmarks ---
=== Build phase ===
Building CUDA hand-written...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cuda/sum_reduce.cu -o /root/crisp/benchmarks/reduction/cuda/sum_reduce
  Compiled in 2.24s
Building CUB...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cub/sum_reduce_cub.cu -o /root/crisp/benchmarks/reduction/cub/sum_reduce_cub
  Compiled in 7.35s
Building Crisp (atomic-per-thread)...
  Crisp compile [sum-reduce.crisp]: /root/crisp/bin/crisp-compile --ir-target=ptx /root/crisp/benchmarks/reduction/crisp/sum-reduce.crisp
  Crisp compiled in 0.21s
  nvcc harness: nvcc -O3 /root/crisp/benchmarks/reduction/crisp/bench_harness.cu -lcuda -o /root/crisp/benchmarks/reduction/crisp/sum_reduce_crisp
Building Crisp (workgroup tree-reduce)...
  Crisp compile [sum-reduce-tree.crisp]: /root/crisp/bin/crisp-compile --ir-target=ptx /root/crisp/benchmarks/reduction/crisp/sum-reduce-tree.crisp
  Crisp compiled in 0.19s
  nvcc harness: nvcc -O3 /root/crisp/benchmarks/reduction/crisp/bench_harness_tree.cu -lcuda -o /root/crisp/benchmarks/reduction/crisp/sum_reduce_crisp_tree

=== Benchmark phase ===

Occupancy: 0.15 (parsed from sum-reduce-tree.crisp, applied to both crisp_tree and cuda)
  Running: cuda N=1000 ... 8.77 us (median)
  Running: cub N=1000 ... 6.88 us (median)
  Running: crisp N=1000 ... 132.9 us (median)
  Running: crisp_tree N=1000 ... 12.61 us (median)
  Running: cuda N=100000 ... 8.93 us (median)
  Running: cub N=100000 ... 10.88 us (median)
  Running: crisp N=100000 ... 133.31 us (median)
  Running: crisp_tree N=100000 ... 13.28 us (median)
  Running: cuda N=1000000 ... 10.62 us (median)
  Running: cub N=1000000 ... 11.2 us (median)
  Running: crisp N=1000000 ... 133.22 us (median)
  Running: crisp_tree N=1000000 ... 20.83 us (median)

============================================================
Compile Times
============================================================
     crisp: 0.21s
  crisp_tree: 0.19s
       cub: 7.35s
      cuda: 2.24s

====================================================================================================
Kernel Time (GPU hardware events, excludes host overhead)
====================================================================================================
         N      crisp (us)   crisp GB/s  crisp_tree (us)  crisp_tree GB/s        cub (us)     cub GB/s       cuda (us)    cuda GB/s
-----------------------------------------------------------------------------------------------------------------------------------
      1000          132.90         0.03           12.61         0.32            6.88         0.58            8.77         0.46
    100000          133.31         3.00           13.28        30.12           10.88        36.76            8.93        44.80
   1000000          133.22        30.03           20.83       192.01           11.20       357.14           10.62       376.51

======================================================================
Wall Time (includes kernel + sync + D→H readback)
======================================================================
         N      crisp (us)  crisp_tree (us)        cub (us)       cuda (us)
---------------------------------------------------------------------------
      1000          146.54           26.05           20.75           22.76
    100000          147.20           26.86           24.82           22.47
   1000000          145.44           33.15           25.81           23.03


=== Benchmark run complete ===