# Reduction benchmark — running commentary

## 2026-05-30 — RTX PRO 4500 Blackwell

Latest run (raw transcript below).  Notable:

**N=1M kernel-time, crisp/cuda ratio across GPUs we've measured:**

| GPU | crisp GB/s | cuda GB/s | ratio |
|---|---|---|---|
| RTX 4090 (Ada) | 286.70 | 365.50 | 78.4% |
| A40 (Ampere) | 292.06 | 388.20 | 75.2% |
| **RTX PRO 4500 (Blackwell)** | **426.62** | **486.38** | **87.7%** |

Best ratio we've measured.  Worth flagging that the jump is partly
architectural — Blackwell's L2/SM layout shifts what's expensive.
Crisp's larger param-load footprint, longer-tail bookkeeping in PTX,
etc., matter less when the hardware's memory subsystem is wider.
Same kernel, different ceiling.

A couple of other things in this run:

- **N=1K**: crisp 6.88us vs cuda 6.21us → essentially tied with
  hand-written CUDA at small N for the first time.  We've been
  trailing here.
- **N=1M**: CUB (550 GB/s) now beats CUDA (486 GB/s).  CUB's at
  ~55% of Blackwell's ~1 TB/s peak; the kernel's tail recursion /
  device-wide reduce strategy benefits from Blackwell's wider mem
  path more than the simple grid-stride does.
- **Wall times** are tight: crisp 19us / cub 17us / cuda 18us at
  N=1M.  From a "user-feels-it" perspective, all three are
  indistinguishable.
- **Compile times** unchanged story — Crisp's device-only 0.18s vs
  nvcc's 0.56s (cuda) / 2.16s (cub) stays our biggest lead.

---

=== Crisp Benchmark Runner ===
  Host:   213.173.108.110:47263
  Branch: shore-up-benchmark
  Sizes:  1K,100K,1M
  Iters:  100

--- Step 1: Verify GPU ---
NVIDIA RTX PRO 4500 Blackwell, 12.0, 32623 MiB


--- Step 5: Run benchmarks ---
=== Build phase ===
Building CUDA hand-written...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cuda/sum_reduce.cu -o /root/crisp/benchmarks/reduction/cuda/sum_reduce
  Compiled in 1.88s (device-only: 0.56s)
Building CUB...
  Building: nvcc -O3 /root/crisp/benchmarks/reduction/cub/sum_reduce_cub.cu -o /root/crisp/benchmarks/reduction/cub/sum_reduce_cub
  Compiled in 5.91s (device-only: 2.16s)
Building Crisp...
  Crisp compile [sum-reduce.crisp]: /root/crisp/bin/crisp-compile --ir-target=ptx /root/crisp/benchmarks/reduction/crisp/sum-reduce.crisp
  Crisp compiled in 0.18s
  nvcc harness: nvcc -O3 /root/crisp/benchmarks/reduction/crisp/bench_harness.cu -lcuda -o /root/crisp/benchmarks/reduction/crisp/sum_reduce_crisp
  Total 2.65s (device-only: 0.18s + harness: 2.47s)

=== Benchmark phase ===

Occupancy: 0.15 (parsed from sum-reduce.crisp, applied to both crisp and cuda)
  Running: cuda N=1000 ... 6.21 us (median)
  Running: cub N=1000 ... 3.39 us (median)
  Running: crisp N=1000 ... 6.88 us (median)
  Running: cuda N=100000 ... 5.86 us (median)
  Running: cub N=100000 ... 6.85 us (median)
  Running: crisp N=100000 ... 8.61 us (median)
  Running: cuda N=1000000 ... 8.22 us (median)
  Running: cub N=1000000 ... 7.26 us (median)
  Running: crisp N=1000000 ... 9.38 us (median)

============================================================
Compile Times
============================================================
        impl     device (s)     end-to-end (s)
  ----------   ------------   ----------------
       crisp           0.18               2.65
         cub           2.16               5.91
        cuda           0.56               1.88

====================================================================================================
Kernel Time (GPU hardware events, excludes host overhead)
====================================================================================================
         N      crisp (us)   crisp GB/s        cub (us)     cub GB/s       cuda (us)    cuda GB/s
-------------------------------------------------------------------------------------------------
      1000            6.88         0.58            3.39         1.18            6.21         0.64
    100000            8.61        46.47            6.85        58.41            5.86        68.31
   1000000            9.38       426.62            7.26       550.66            8.22       486.38

======================================================================
Wall Time (includes kernel + sync + D→H readback)
======================================================================
         N      crisp (us)        cub (us)       cuda (us)
----------------------------------------------------------
      1000           16.20           12.88           15.97
    100000           18.05           16.66           16.00
   1000000           19.04           16.97           18.05


=== Benchmark run complete ===