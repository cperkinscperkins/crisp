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
//                                would fail %check-mma-shape without it.  MUST also include the
//                                TYPED (:double 8 8 4) for fp64 — see the comment at the emit
//                                site; its absence is a SILENT miscompile, not an error.
//   :wgmma-shapes              — OPTIONAL (endeavor 161).  wgmma's m64nNk8 family does NOT
//                                consult :mma-shapes; %check-wgmma-shape reads this key, and
//                                when no profile declares it falls back to the generic sm_90a
//                                constraints.  So omitting it is safe, not broken.
//   :tile-visit-strip-width    — MEASURED, and measured HARMFUL on this part (-8.3% at W=4,
//                                degrading monotonically to -14.4% at W=16).  Omit it.
//
// EVERY EMITTED KEY IS TAGGED QUERIED / ARCH / MEASURED.  A hardware value without a provenance
// is how endeavor 144 twice adopted a plausible-looking assumption that was wrong.

#include <cstdio>
#include <cstring>
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

        // NAME THE PROFILE AFTER THE DEVICE, not after "h100".  SM count alone cannot separate
        // an SXM from an NVL (both 132), and this program used to emit the literal name `h100`
        // on every part -- so an H200 produced a form labelled `h100`, which is the exact
        // confusion the profile is supposed to end.  The device name is authoritative and is
        // also what the benchmark harness matches on, so the two agree by construction.
        char profName[128];
        {
            const char* s = p.name;
            if (std::strncmp(s, "NVIDIA ", 7) == 0) s += 7;   // drop the vendor prefix
            size_t o = 0;
            for (size_t i = 0; s[i] && o + 1 < sizeof(profName); ++i) {
                unsigned char c = (unsigned char)s[i];
                if (c >= 'A' && c <= 'Z') profName[o++] = (char)(c - 'A' + 'a');
                else if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) profName[o++] = (char)c;
                else if (o > 0 && profName[o - 1] != '-') profName[o++] = '-';
            }
            while (o > 0 && profName[o - 1] == '-') --o;        // no trailing separator
            profName[o] = 0;
            if (o == 0) { const char* f = "unknown-device"; std::strcpy(profName, f); }
        }
        std::printf("\n  -- proposed def-hardware-profile --\n");
        std::printf("(def-hardware-profile %s\n", profName);
        std::printf("  ;; queried on this device (%s, sm_%d%d)\n", variant, p.major, p.minor);
        std::printf("  ;; QUERIED = from this device.  ARCH = ISA fact, look it up.\n");
        std::printf("  ;; MEASURED = sweep it or omit it; a guess can be worse than nothing.\n");
        std::printf("  :simd-width %d                          ; QUERIED\n", p.warpSize);
        std::printf("  :compute-units %d                      ; QUERIED -- OVERRIDES the device SM\n",
                    p.multiProcessorCount);
        std::printf("                                         ;   query in the generated launch grid,\n");
        std::printf("                                         ;   so a wrong value mis-sizes EVERY\n");
        std::printf("                                         ;   dispatch.  PCIe 114 / SXM-NVL 132.\n");
        std::printf("  :max-registers-per-cu %d              ; QUERIED\n", p.regsPerMultiprocessor);
        std::printf("  :max-registers-per-thread 255          ; ARCH; a SCALAR on NVIDIA (D4) -- unlike\n");
        std::printf("                                         ;   Intel, the file is not a JIT choice.\n");
        std::printf("  :max-total-threads-per-block %d       ; QUERIED\n", p.maxThreadsPerBlock);
        std::printf("  :max-work-group-dims '(%d %d %d)     ; QUERIED\n",
                    p.maxThreadsDim[0], p.maxThreadsDim[1], p.maxThreadsDim[2]);
        std::printf("  :max-shared-memory-per-block %zuKB     ; QUERIED: the OPT-IN cap, NOT the 48KB\n",
                    p.sharedMemPerBlockOptin / 1024);
        std::printf("                                         ;   default.  Kernels over 48KB need it.\n");
        std::printf("  :l2-cache-size %dMB                     ; QUERIED\n",
                    (int)(p.l2CacheSize / (1024 * 1024)));
        std::printf("  :native-cache-line-size 128            ; ARCH\n");
        // THE TYPED fp64 ENTRY IS LOAD-BEARING, and omitting it fails SILENTLY -- which is why it
        // is emitted rather than left to the reader.  Without (:double 8 8 4), %mma-shape-for-elem
        // falls back to the width rule (K x element-bits is a constant fragment footprint) and
        // resolves `double` to (16 8 4).  That shape exists in the PTX ISA but is NOT an NVVM
        // intrinsic in LLVM 21.1.5: it assembles, and llc emits an `.extern .func` CALL with no
        // diagnostic at all.  fp64 has exactly ONE tensor-core shape, m8n8k4, and no rule can
        // infer that -- the profile has to say so outright.
        std::printf("  :mma-shapes '((16 8 8)                 ; ARCH: tf32 -- MANDATORY, see header\n");
        std::printf("                (16 8 4)                 ;   tf32 short-K\n");
        std::printf("                (16 8 16)                ;   fp16 / bf16\n");
        std::printf("                (:double 8 8 4))         ;   fp64 DMMA -- TYPED entry.  Omitting\n");
        std::printf("                                         ;   it makes `double` resolve to a\n");
        std::printf("                                         ;   non-intrinsic shape that emits an\n");
        std::printf("                                         ;   .extern .func call with NO error.\n");
        std::printf("  ; :wgmma-shapes                        ; OPTIONAL.  Absent => the generic sm_90a\n");
        std::printf("  ;                                      ;   constraints (M=64, N mult of 8 in\n");
        std::printf("  ;                                      ;   [8,256]) are enforced instead.\n");
        std::printf("  ; :tile-visit-strip-width <N>          ; MEASURED -- OMIT IT unless you have swept\n");
        std::printf("  ;                                      ;   it.  Measured HARMFUL on H100 (-8.3%% at\n");
        std::printf("  ;                                      ;   W=4, -14.4%% at W=16).  Absent => linear.\n");
        std::printf("  )\n\n");

        if (p.sharedMemPerBlockOptin % 1024 != 0)
            std::printf("  NOTE: sharedMemPerBlockOptin is not a whole number of KB (%zu B) — use the byte count.\n",
                        p.sharedMemPerBlockOptin);
    }
    return 0;
}
