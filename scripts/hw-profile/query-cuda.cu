// Endeavor 144 Phase 0 — CUDA hardware-profile query.  NVIDIA twin of query.cpp (Level Zero).
//
// Dumps every device property that maps onto a Crisp `def-hardware-profile` key, then prints
// a paste-ready profile form.  The point is to write the `h100` profile from MEASURED values
// rather than a spec sheet — :compute-units especially, since it now OVERRIDES the device SM
// query in the generated CUDA launch grid (hoist-cuda/main.lisp:1296), so a wrong value
// directly mis-sizes every grid.  H100 PCIe is 114 SMs; SXM is 132; topology.md's example
// profile says 132.  Do not guess.
//
// Build & run on the pod:
//   nvcc query_cuda.cu -o query_cuda && ./query_cuda
//
// Keys CUDA does NOT expose, and where the value must come from instead:
//   :max-registers-per-thread  — architectural, not in cudaDeviceProp.  255 on all
//                                sm_5x..sm_9x.  Per endeavor 144 decision D4 this stays a
//                                SCALAR on NVIDIA (one fixed allocation); the ascending-list
//                                form is for Intel, whose register file is a JIT-time mode.
//   :native-cache-line-size    — architectural: 128 B on NVIDIA.
//   :max-concurrent-kernels    — `concurrentKernels` is a BOOLEAN capability, not a count.
//                                Endeavor 144 scopes this key out; see the plan doc.
//   :mma-shapes                — an ISA fact, not a device property.  MUST include (16 8 8):
//                                chap0 / chap1 / chap1.5 / chap2 all pass that tf32 shape and
//                                would fail %check-mma-shape without it.  (wgmma's m64nNk8
//                                family is validated separately by %check-wgmma-shape and does
//                                NOT consult :mma-shapes.)

#include <cstdio>
#include <cuda_runtime.h>

#define CK(x) do { cudaError_t _e = (x); if (_e != cudaSuccess) { \
    std::printf("FAIL %s -> %s\n", #x, cudaGetErrorString(_e)); return 1; } } while (0)

int main() {
    int n = 0;
    CK(cudaGetDeviceCount(&n));
    if (n == 0) { std::printf("FAIL no CUDA devices\n"); return 1; }

    for (int d = 0; d < n; ++d) {
        cudaDeviceProp p{};
        CK(cudaGetDeviceProperties(&p, d));

        std::printf("=====================================================\n");
        std::printf("device %d : %s\n", d, p.name);
        std::printf("=====================================================\n");
        std::printf("  compute capability       sm_%d%d\n", p.major, p.minor);
        std::printf("  clockRate                %.0f MHz\n", p.clockRate / 1000.0);

        std::printf("\n  -- compute (feeds :compute-units, :simd-width) --\n");
        std::printf("  multiProcessorCount      %d   (:compute-units)  <<< 114=PCIe 132=SXM\n",
                    p.multiProcessorCount);
        std::printf("  warpSize                 %d   (:simd-width)\n", p.warpSize);
        std::printf("  maxBlocksPerMultiProcessor %d\n", p.maxBlocksPerMultiProcessor);

        std::printf("\n  -- registers (feeds :max-registers-per-cu) --\n");
        std::printf("  regsPerMultiprocessor    %d   (:max-registers-per-cu)\n",
                    p.regsPerMultiprocessor);
        std::printf("  regsPerBlock             %d\n", p.regsPerBlock);
        std::printf("  (max registers/thread is architectural: 255 — not queryable)\n");

        std::printf("\n  -- workgroup bounds --\n");
        std::printf("  maxThreadsPerBlock       %d   (:max-total-threads-per-block)\n",
                    p.maxThreadsPerBlock);
        std::printf("  maxThreadsDim            %d %d %d   (:max-work-group-dims)\n",
                    p.maxThreadsDim[0], p.maxThreadsDim[1], p.maxThreadsDim[2]);
        std::printf("  maxGridSize              %d %d %d\n",
                    p.maxGridSize[0], p.maxGridSize[1], p.maxGridSize[2]);

        std::printf("\n  -- shared memory (NOTE: two different numbers) --\n");
        std::printf("  sharedMemPerBlock        %zu bytes (%.0f KB)   <- DEFAULT limit\n",
                    p.sharedMemPerBlock, p.sharedMemPerBlock / 1024.0);
        std::printf("  sharedMemPerBlockOptin   %zu bytes (%.0f KB)   <- USE THIS for :max-shared-memory-per-block\n",
                    p.sharedMemPerBlockOptin, p.sharedMemPerBlockOptin / 1024.0);
        std::printf("  sharedMemPerMultiprocessor %zu bytes (%.0f KB)\n",
                    p.sharedMemPerMultiprocessor, p.sharedMemPerMultiprocessor / 1024.0);
        std::printf("  (chap2/chap3 exceed the 48 KB default, so the opt-in figure is the real cap)\n");

        std::printf("\n  -- caches (feeds :l2-cache-size — PHASE 1 depends on this) --\n");
        std::printf("  l2CacheSize              %d bytes (%.1f MB)   (:l2-cache-size)\n",
                    p.l2CacheSize, p.l2CacheSize / (1024.0 * 1024.0));
        std::printf("  persistingL2CacheMaxSize %d bytes (%.1f MB)\n",
                    p.persistingL2CacheMaxSize, p.persistingL2CacheMaxSize / (1024.0 * 1024.0));
        std::printf("  (cache line is architectural: 128 B — not queryable)\n");

        std::printf("\n  -- memory --\n");
        std::printf("  totalGlobalMem           %.1f GB\n",
                    p.totalGlobalMem / (1024.0 * 1024.0 * 1024.0));
        std::printf("  memoryBusWidth           %d bits\n", p.memoryBusWidth);
        std::printf("  memoryClockRate          %.0f MHz\n", p.memoryClockRate / 1000.0);
        std::printf("  concurrentKernels        %d   (a BOOLEAN capability, not a count)\n",
                    p.concurrentKernels);
        std::printf("  asyncEngineCount         %d\n", p.asyncEngineCount);

        // ---- paste-ready profile ----
        const char* variant = (p.multiProcessorCount == 132) ? "sxm"
                            : (p.multiProcessorCount == 114) ? "pcie" : "unknown-variant";
        std::printf("\n  -- proposed def-hardware-profile --\n");
        std::printf("(def-hardware-profile h100\n");
        std::printf("  ;; queried on this device (%s, sm_%d%d)\n", variant, p.major, p.minor);
        std::printf("  :simd-width %d\n", p.warpSize);
        std::printf("  :compute-units %d\n", p.multiProcessorCount);
        std::printf("  :max-registers-per-cu %d\n", p.regsPerMultiprocessor);
        std::printf("  :max-registers-per-thread 255          ; architectural; SCALAR on NVIDIA (D4)\n");
        std::printf("  :max-total-threads-per-block %d\n", p.maxThreadsPerBlock);
        std::printf("  :max-work-group-dims '(%d %d %d)\n",
                    p.maxThreadsDim[0], p.maxThreadsDim[1], p.maxThreadsDim[2]);
        std::printf("  :max-shared-memory-per-block %zuKB      ; the OPT-IN cap, not the 48KB default\n",
                    p.sharedMemPerBlockOptin / 1024);
        std::printf("  :l2-cache-size %dMB\n", (int)(p.l2CacheSize / (1024 * 1024)));
        std::printf("  :native-cache-line-size 128            ; architectural\n");
        std::printf("  :mma-shapes '((16 8 8) (16 8 4) (16 8 16)))  ; (16 8 8) is MANDATORY — see header\n\n");

        if (p.sharedMemPerBlockOptin % 1024 != 0)
            std::printf("  NOTE: sharedMemPerBlockOptin is not a whole number of KB (%zu B) — use the byte count.\n",
                        p.sharedMemPerBlockOptin);
    }
    return 0;
}
