--- Step 5: Run benchmarks ---
=== Build phase ===
Building CUDA hand-written...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cuda/sum_reduce.cu -o /root/crisp/benchmarks/reduction/cuda/sum_reduce
  Compiled in 2.24s
Building CUB...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cub/sum_reduce_cub.cu -o /root/crisp/benchmarks/reduction/cub/sum_reduce_cub
  Compiled in 6.95s
Building Crisp (atomic-per-thread)...
  Crisp compile [sum-reduce.crisp]: /root/crisp/bin/crisp-compile --ir-target=ptx /root/crisp/benchmarks/reduction/crisp/sum-reduce.crisp
  Crisp compiled in 0.12s
  nvcc harness: nvcc -O3 /root/crisp/benchmarks/reduction/crisp/bench_harness.cu -lcuda -o /root/crisp/benchmarks/reduction/crisp/sum_reduce_crisp
Building Crisp (workgroup tree-reduce)...
  Crisp compile [sum-reduce-tree.crisp]: /root/crisp/bin/crisp-compile --ir-target=ptx /root/crisp/benchmarks/reduction/crisp/sum-reduce-tree.crisp
  Crisp compiled in 0.14s
  nvcc harness: nvcc -O3 /root/crisp/benchmarks/reduction/crisp/bench_harness_tree.cu -lcuda -o /root/crisp/benchmarks/reduction/crisp/sum_reduce_crisp_tree

=== Benchmark phase ===

Occupancy: 0.15 (parsed from sum-reduce-tree.crisp, applied to both crisp_tree and cuda)
  Running: cuda N=1000 ... 7.81 us (median)
  Running: cub N=1000 ... 6.08 us (median)
  Running: crisp N=1000 ... 131.84 us (median)
  Running: crisp_tree N=1000 ... 12.83 us (median)
  Running: cuda N=100000 ... 8.35 us (median)
  Running: cub N=100000 ... 9.28 us (median)
  Running: crisp N=100000 ... 131.97 us (median)
  Running: crisp_tree N=100000 ... 13.76 us (median)
  Running: cuda N=1000000 ... 10.78 us (median)
  Running: cub N=1000000 ... 10.43 us (median)
  Running: crisp N=1000000 ... 133.28 us (median)
  Running: crisp_tree N=1000000 ... 23.84 us (median)

============================================================
Compile Times
============================================================
     crisp: 0.12s
  crisp_tree: 0.14s
       cub: 6.95s
      cuda: 2.24s

====================================================================================================
Kernel Time (GPU hardware events, excludes host overhead)
====================================================================================================
         N      crisp (us)   crisp GB/s  crisp_tree (us)  crisp_tree GB/s        cub (us)     cub GB/s       cuda (us)    cuda GB/s
-----------------------------------------------------------------------------------------------------------------------------------
      1000          131.84         0.03           12.83         0.31            6.08         0.66            7.81         0.51
    100000          131.97         3.03           13.76        29.07            9.28        43.10            8.35        47.89
   1000000          133.28        30.01           23.84       167.79           10.43       383.44           10.78       370.92

======================================================================
Wall Time (includes kernel + sync + D→H readback)
======================================================================
         N      crisp (us)  crisp_tree (us)        cub (us)       cuda (us)
---------------------------------------------------------------------------
      1000          144.14           25.07           18.39           20.12
    100000          144.24           25.88           21.48           20.65
   1000000          145.45           36.09           22.82           23.11


=== Benchmark run complete ===