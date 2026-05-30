--- Step 5: Run benchmarks ---
=== Build phase ===
Building CUDA hand-written...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cuda/sum_reduce.cu -o /root/crisp/benchmarks/reduction/cuda/sum_reduce
  Compiled in 2.16s (device-only: 0.66s)
Building CUB...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cub/sum_reduce_cub.cu -o /root/crisp/benchmarks/reduction/cub/sum_reduce_cub
  Compiled in 7.05s (device-only: 2.47s)
Building Crisp...
  Crisp compile [sum-reduce.crisp]: /root/crisp/bin/crisp-compile --ir-target=ptx /root/crisp/benchmarks/reduction/crisp/sum-reduce.crisp
  Crisp compiled in 0.21s
  nvcc harness: nvcc -O3 /root/crisp/benchmarks/reduction/crisp/bench_harness.cu -lcuda -o /root/crisp/benchmarks/reduction/crisp/sum_reduce_crisp
  Total 3.12s (device-only: 0.21s + harness: 2.91s)

=== Benchmark phase ===

Occupancy: 0.15 (parsed from sum-reduce.crisp, applied to both crisp and cuda)
  Running: cuda N=1000 ... 8.13 us (median)
  Running: cub N=1000 ... 6.05 us (median)
  Running: crisp N=1000 ... 11.58 us (median)
  Running: cuda N=100000 ... 8.58 us (median)
  Running: cub N=100000 ... 9.22 us (median)
  Running: crisp N=100000 ... 12.13 us (median)
  Running: cuda N=1000000 ... 10.94 us (median)
  Running: cub N=1000000 ... 10.46 us (median)
  Running: crisp N=1000000 ... 13.95 us (median)

============================================================
Compile Times
============================================================
        impl     device (s)     end-to-end (s)
  ----------   ------------   ----------------
       crisp           0.21               3.12
         cub           2.47               7.05
        cuda           0.66               2.16

====================================================================================================
Kernel Time (GPU hardware events, excludes host overhead)
====================================================================================================
         N      crisp (us)   crisp GB/s        cub (us)     cub GB/s       cuda (us)    cuda GB/s
-------------------------------------------------------------------------------------------------
      1000           11.58         0.35            6.05         0.66            8.13         0.49
    100000           12.13        32.98            9.22        43.40            8.58        46.64
   1000000           13.95       286.70           10.46       382.26           10.94       365.50

======================================================================
Wall Time (includes kernel + sync + D→H readback)
======================================================================
         N      crisp (us)        cub (us)       cuda (us)
----------------------------------------------------------
      1000           23.75           18.51           20.29
    100000           24.38           21.78           20.91
   1000000           26.17           22.88           23.32


=== Benchmark run complete ===