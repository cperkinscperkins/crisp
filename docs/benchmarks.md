--- Step 5: Run benchmarks ---
=== Build phase ===
Building CUDA hand-written...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cuda/sum_reduce.cu -o /root/crisp/benchmarks/reduction/cuda/sum_reduce
  Compiled in 2.16s (device-only: 0.67s)
Building CUB...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cub/sum_reduce_cub.cu -o /root/crisp/benchmarks/reduction/cub/sum_reduce_cub
  Compiled in 6.90s (device-only: 2.49s)
Building Crisp...
  Crisp compile [sum-reduce.crisp]: /root/crisp/bin/crisp-compile --ir-target=ptx /root/crisp/benchmarks/reduction/crisp/sum-reduce.crisp
  Crisp compiled in 0.20s
  nvcc harness: nvcc -O3 /root/crisp/benchmarks/reduction/crisp/bench_harness.cu -lcuda -o /root/crisp/benchmarks/reduction/crisp/sum_reduce_crisp
  Total 3.07s (device-only: 0.20s + harness: 2.87s)

=== Benchmark phase ===

Occupancy: 0.15 (parsed from sum-reduce.crisp, applied to both crisp and cuda)
  Running: cuda N=1000 ... 8.0 us (median)
  Running: cub N=1000 ... 5.98 us (median)
  Running: crisp N=1000 ... 11.36 us (median)
  Running: cuda N=100000 ... 8.51 us (median)
  Running: cub N=100000 ... 9.38 us (median)
  Running: crisp N=100000 ... 12.1 us (median)
  Running: cuda N=1000000 ... 11.07 us (median)
  Running: cub N=1000000 ... 10.4 us (median)
  Running: crisp N=1000000 ... 21.7 us (median)

============================================================
Compile Times
============================================================
        impl     device (s)     end-to-end (s)
  ----------   ------------   ----------------
       crisp           0.20               3.07
         cub           2.49               6.90
        cuda           0.67               2.16

====================================================================================================
Kernel Time (GPU hardware events, excludes host overhead)
====================================================================================================
         N      crisp (us)   crisp GB/s        cub (us)     cub GB/s       cuda (us)    cuda GB/s
-------------------------------------------------------------------------------------------------
      1000           11.36         0.35            5.98         0.67            8.00         0.50
    100000           12.10        33.07            9.38        42.66            8.51        46.99
   1000000           21.70       184.37           10.40       384.62           11.07       361.27

======================================================================
Wall Time (includes kernel + sync + D→H readback)
======================================================================
         N      crisp (us)        cub (us)       cuda (us)
----------------------------------------------------------
      1000           23.60           18.22           20.33
    100000           24.45           21.71           20.95
   1000000           34.83           22.80           23.37


=== Benchmark run complete ===