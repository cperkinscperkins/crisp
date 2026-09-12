// Endeavor 144 Phase 0 — Level Zero hardware-profile query.
//
// Dumps every device property that maps onto a Crisp `def-hardware-profile` key, then
// prints a ready-to-paste profile form.  Written to nail down the real `bmg` numbers
// instead of sourcing them from spec sheets (see the endeavor's D2 / --verify-hardware-profile
// cross-cutting task).
//
// Build (matches tests/run-specs.lisp validate-l0-host-run):
//   clang++ query.cpp -I C:/Users/cperk/Documents/level-zero/include \
//           C:/Windows/System32/ze_loader.dll -static -o query.exe
//
// EVERY EMITTED KEY IS TAGGED WITH ITS PROVENANCE — QUERIED / ARCH / MEASURED — because a
// hardware value without a provenance is how endeavor 144 twice adopted a plausible-looking
// assumption that turned out to be wrong.  The tiers are not cosmetic:
//
//   QUERIED    this program read it off the device.  Trust it.
//   ARCH       an ISA fact, not a device property.  Look it up for YOUR part; the emitted
//              value is Xe2's and is a starting point, not an answer.
//   MEASURED   only a sweep can answer it.  OMIT rather than guess — :tile-visit-strip-width 4
//              is +63% on BMG at N=2048 and -14% on H100, so a wrong guess costs more than the
//              omission, and absent means the safe linear behaviour.
//
// Keys L0 does NOT expose, and where the value has to come from instead:
//   :native-cache-line-size    — not in the L0 API.  Xe2 LSC cache line is 64B.
//   :max-registers-per-thread  — GRF size is not queryable.  Xe2: 128 regs x 32B
//                                (default) or 256 (large-GRF mode).  Emitted as an ascending
//                                LIST because the register file is a JIT-time choice; a scalar
//                                silently forfeits large-GRF, worth 1.55-2.01x on BMG.
//   :max-registers-per-cu      — likewise not queryable; derive as GRF-per-thread x
//                                numThreadsPerEU x numEUsPerSubslice if we want it.
//   :mma-shapes                — an ISA fact, not a device property.  ALL supported element
//                                widths must be listed: %check-mma-shape is a hard compile
//                                error on an unlisted shape, so emitting only the tf32 triple
//                                (8 16 8) refuses every bf16 / fp16 / int8 MMA kernel.
//   :mma-lowerings             — a capability claim this program cannot verify, so it emits
//                                only the portable :coop-matrix and names :xe-native (Xe2+).
//   :tile-visit-strip-width    — MEASURED.  Named but never emitted; see above.

#include <ze_api.h>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define CHECK(x) do { ze_result_t _r = (x); if (_r != ZE_RESULT_SUCCESS) { \
    std::printf("FAIL %s -> 0x%x\n", #x, (unsigned)_r); return 1; } } while (0)

static const char* cache_scope(ze_device_cache_property_flags_t f) {
    if (f & ZE_DEVICE_CACHE_PROPERTY_FLAG_USER_CONTROL) return "user-control";
    return "default";
}

int main() {
    CHECK(zeInit(0));

    uint32_t driverCount = 0;
    CHECK(zeDriverGet(&driverCount, nullptr));
    if (driverCount == 0) { std::printf("FAIL no L0 drivers\n"); return 1; }
    std::vector<ze_driver_handle_t> drivers(driverCount);
    CHECK(zeDriverGet(&driverCount, drivers.data()));

    for (uint32_t di = 0; di < driverCount; ++di) {
        uint32_t devCount = 0;
        CHECK(zeDeviceGet(drivers[di], &devCount, nullptr));
        std::vector<ze_device_handle_t> devs(devCount);
        CHECK(zeDeviceGet(drivers[di], &devCount, devs.data()));

        for (uint32_t i = 0; i < devCount; ++i) {
            ze_device_handle_t dev = devs[i];

            ze_device_properties_t props = {};
            props.stype = ZE_STRUCTURE_TYPE_DEVICE_PROPERTIES;
            CHECK(zeDeviceGetProperties(dev, &props));

            if (props.type != ZE_DEVICE_TYPE_GPU) continue;

            ze_device_compute_properties_t comp = {};
            comp.stype = ZE_STRUCTURE_TYPE_DEVICE_COMPUTE_PROPERTIES;
            CHECK(zeDeviceGetComputeProperties(dev, &comp));

            std::printf("=====================================================\n");
            std::printf("driver %u device %u : %s\n", di, i, props.name);
            std::printf("=====================================================\n");
            std::printf("  deviceId                 0x%04x\n", props.deviceId);
            std::printf("  vendorId                 0x%04x\n", props.vendorId);
            std::printf("  coreClockRate            %u MHz\n", props.coreClockRate);
            std::printf("\n  -- EU hierarchy (feeds :compute-units) --\n");
            std::printf("  numSlices                %u\n", props.numSlices);
            std::printf("  numSubslicesPerSlice     %u\n", props.numSubslicesPerSlice);
            std::printf("  numEUsPerSubslice        %u\n", props.numEUsPerSubslice);
            std::printf("  numThreadsPerEU          %u\n", props.numThreadsPerEU);
            std::printf("  => Xe-cores (slices*subslices)      %u\n",
                        props.numSlices * props.numSubslicesPerSlice);
            std::printf("  => total EUs                       %u\n",
                        props.numSlices * props.numSubslicesPerSlice * props.numEUsPerSubslice);
            std::printf("  => _hw_threads (the L0 hoist formula) %u\n",
                        props.numSlices * props.numSubslicesPerSlice *
                        props.numEUsPerSubslice * props.numThreadsPerEU);
            std::printf("  physicalEUSimdWidth      %u   (feeds :simd-width)\n",
                        props.physicalEUSimdWidth);

            std::printf("\n  -- workgroup bounds --\n");
            std::printf("  maxTotalGroupSize        %u   (:max-total-threads-per-block)\n",
                        comp.maxTotalGroupSize);
            std::printf("  maxGroupSizeX/Y/Z        %u %u %u   (:max-work-group-dims)\n",
                        comp.maxGroupSizeX, comp.maxGroupSizeY, comp.maxGroupSizeZ);
            std::printf("  maxGroupCountX/Y/Z       %u %u %u\n",
                        comp.maxGroupCountX, comp.maxGroupCountY, comp.maxGroupCountZ);
            std::printf("  maxSharedLocalMemory     %u bytes (%.1f KB)  (:max-shared-memory-per-block)\n",
                        comp.maxSharedLocalMemory, comp.maxSharedLocalMemory / 1024.0);
            std::printf("  numSubGroupSizes         %u  ->", comp.numSubGroupSizes);
            for (uint32_t s = 0; s < comp.numSubGroupSizes && s < ZE_SUBGROUPSIZE_COUNT; ++s)
                std::printf(" %u", comp.subGroupSizes[s]);
            std::printf("   (subgroup = SIMD width choices)\n");

            std::printf("\n  -- caches (feeds :l2-cache-size) --\n");
            // Tracked so :l2-cache-size can be EMITTED rather than left as a
            // "<from cache[] above>" placeholder the reader has to resolve by hand.
            unsigned long long largestCacheBytes = 0;
            uint32_t cacheCount = 0;
            if (zeDeviceGetCacheProperties(dev, &cacheCount, nullptr) == ZE_RESULT_SUCCESS
                && cacheCount > 0) {
                std::vector<ze_device_cache_properties_t> caches(cacheCount);
                for (auto& c : caches) c.stype = ZE_STRUCTURE_TYPE_DEVICE_CACHE_PROPERTIES;
                if (zeDeviceGetCacheProperties(dev, &cacheCount, caches.data()) == ZE_RESULT_SUCCESS) {
                    for (uint32_t c = 0; c < cacheCount; ++c) {
                        std::printf("  cache[%u] size %llu bytes (%.1f MB)  scope=%s\n", c,
                                    (unsigned long long)caches[c].cacheSize,
                                    caches[c].cacheSize / (1024.0 * 1024.0),
                                    cache_scope(caches[c].flags));
                        if ((unsigned long long)caches[c].cacheSize > largestCacheBytes)
                            largestCacheBytes = (unsigned long long)caches[c].cacheSize;
                    }
                }
            } else {
                std::printf("  (no cache properties reported)\n");
            }

            std::printf("\n  -- memory --\n");
            std::printf("  maxMemAllocSize          %llu bytes (%.1f GB)\n",
                        (unsigned long long)props.maxMemAllocSize,
                        props.maxMemAllocSize / (1024.0 * 1024.0 * 1024.0));
            uint32_t memCount = 0;
            if (zeDeviceGetMemoryProperties(dev, &memCount, nullptr) == ZE_RESULT_SUCCESS
                && memCount > 0) {
                std::vector<ze_device_memory_properties_t> mems(memCount);
                for (auto& m : mems) m.stype = ZE_STRUCTURE_TYPE_DEVICE_MEMORY_PROPERTIES;
                if (zeDeviceGetMemoryProperties(dev, &memCount, mems.data()) == ZE_RESULT_SUCCESS) {
                    for (uint32_t m = 0; m < memCount; ++m)
                        std::printf("  mem[%u] '%s' totalSize %.1f GB busWidth %u maxClock %u\n",
                                    m, mems[m].name,
                                    mems[m].totalSize / (1024.0 * 1024.0 * 1024.0),
                                    mems[m].maxBusWidth, mems[m].maxClockRate);
                }
            }

            std::printf("\n  -- queues (feeds :max-concurrent-kernels) --\n");
            uint32_t qCount = 0;
            if (zeDeviceGetCommandQueueGroupProperties(dev, &qCount, nullptr) == ZE_RESULT_SUCCESS
                && qCount > 0) {
                std::vector<ze_command_queue_group_properties_t> qs(qCount);
                for (auto& q : qs) q.stype = ZE_STRUCTURE_TYPE_COMMAND_QUEUE_GROUP_PROPERTIES;
                if (zeDeviceGetCommandQueueGroupProperties(dev, &qCount, qs.data()) == ZE_RESULT_SUCCESS) {
                    for (uint32_t q = 0; q < qCount; ++q)
                        std::printf("  queueGroup[%u] numQueues %u compute=%d\n", q,
                                    qs[q].numQueues,
                                    (qs[q].flags & ZE_COMMAND_QUEUE_GROUP_PROPERTY_FLAG_COMPUTE) ? 1 : 0);
                }
            }

            // ---- the paste-ready profile ----
            //
            // THE THREE TIERS ARE LABELLED, AND THAT IS THE POINT.  A profile key is either
            // QUERIED (this program knows it), ARCHITECTURAL (an ISA fact -- look it up), or
            // MEASURED (only a sweep can answer it).  Endeavor 144 twice adopted a
            // plausible-looking hardware assumption that was wrong, so a value's PROVENANCE is
            // part of the value.  Guessing on the MEASURED tier is actively harmful: strip
            // width 4 is +63% on BMG at N=2048 and -14% on H100, so a wrong guess costs more
            // than the omission does.  Absent MEASURED keys fall back to safe behaviour.
            std::printf("\n  -- proposed def-hardware-profile --\n");
            std::printf("  ;; QUERIED = from this device.  ARCH = ISA fact, look it up.\n");
            std::printf("  ;; MEASURED = sweep it or omit it; a guess can be worse than nothing.\n");
            std::printf("(def-hardware-profile <name>\n");
            std::printf("  :simd-width %u                       ; QUERIED\n",
                        comp.numSubGroupSizes > 0 ? comp.subGroupSizes[0] : props.physicalEUSimdWidth);
            std::printf("  :compute-units %u                    ; QUERIED (Xe-cores)\n",
                        props.numSlices * props.numSubslicesPerSlice);
            std::printf("  :max-total-threads-per-block %u     ; QUERIED\n", comp.maxTotalGroupSize);
            std::printf("  :max-work-group-dims '(%u %u %u)  ; QUERIED\n",
                        comp.maxGroupSizeX, comp.maxGroupSizeY, comp.maxGroupSizeZ);
            std::printf("  :max-shared-memory-per-block %uKB    ; QUERIED\n",
                        comp.maxSharedLocalMemory / 1024);
            if (largestCacheBytes > 0)
                std::printf("  :l2-cache-size %lluMB                 ; QUERIED (largest cache reported)\n",
                            largestCacheBytes / (1024ULL * 1024ULL));
            else
                std::printf("  ; :l2-cache-size <MB>               ; no cache properties reported\n");
            std::printf("  :native-cache-line-size 64           ; ARCH: Xe2 LSC line is 64B; CHECK for your part\n");
            // :max-registers-per-thread IS A LIST ON INTEL, and getting that wrong is the most
            // expensive easy mistake here.  The GRF file is a JIT-time choice, so the key takes
            // ascending SELECTABLE MODES; collapsing it to a scalar silently forfeits large-GRF,
            // which measured 1.55-2.01x on BMG.  Not queryable through L0 at all.
            std::printf("  :max-registers-per-thread '(128 256) ; ARCH: Xe2 GRF modes (32B each).\n");
            std::printf("                                       ;   A LIST, not a scalar -- ascending selectable\n");
            std::printf("                                       ;   modes.  A scalar forfeits large-GRF (worth\n");
            std::printf("                                       ;   1.55-2.01x on BMG).  CHECK for your part.\n");
            // :mma-shapes must carry EVERY element width the part supports: %check-mma-shape is a
            // hard compile error on a shape the profile does not list, so shipping only the tf32
            // triple refuses every bf16 / fp16 / int8 MMA kernel.
            std::printf("  :mma-shapes '((8 16 8)               ; ARCH: tf32 XMX\n");
            std::printf("                (8 16 16)              ;   bf16 / fp16 -- OMITTING THIS REFUSES\n");
            std::printf("                (8 16 32))             ;   int8         every 16-bit MMA kernel\n");
            // :mma-lowerings is a CAPABILITY CLAIM this program cannot verify, so it emits only the
            // portable path and names the alternative rather than asserting it.
            std::printf("  :mma-lowerings '(:coop-matrix)        ; ARCH: portable path, valid everywhere.\n");
            std::printf("                                       ;   Xe2/BMG also offers :xe-native -- add it\n");
            std::printf("                                       ;   ONLY if your part supports DPAS + Block2D.\n");
            std::printf("  ; :tile-visit-strip-width <N>        ; MEASURED -- OMIT IT unless you have swept it.\n");
            std::printf("  ;                                    ;   Absent => linear, which is safe.\n");
            std::printf("  ; :max-registers-per-cu <N>          ; not queryable; derive as GRF/thread x\n");
            std::printf("  ;                                    ;   numThreadsPerEU x numEUsPerSubslice\n");
            std::printf("  ; :wgmma-shapes                      ; N/A on Intel (no warpgroup MMA)\n");
            std::printf("  )\n\n");
        }
    }
    return 0;
}
