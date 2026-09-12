# `def-hardware-profile`  ✅

```
(def-hardware-profile <name> <profile-proplist...>)
```

`def-hardware-profile` just associates a `<name>` with a profile property list. The `<name>` can then be used as the value for the `--hardware-profile` compilation flag, or used with `:profile` value in a `compute-unit` member of a `def-topology` (see below)

```
(def-hardware-profile nvidia-h100-sxm

  ;; --- Compute & Vector Core Mechanics ---
  :simd-width 32
  :compute-units 132
  :max-registers-per-cu 65536
  :max-registers-per-thread 255

  ;; --- Local Memory Hierarchy ---
  :max-shared-memory-per-block 227KB
  :l2-cache-size 50MB
  :native-cache-line-size 128
  :tile-visit-strip-width 16

  ;; --- Execution & Work-Group Bounds ---
  :max-work-group-dims '(1024 1024 64)
  :max-total-threads-per-block 1024
  :max-concurrent-kernels 128

  ;; matrix units
  :mma-shapes '((16 8 16) (8 8 8))  ; list of (M N K) triples
  :wgmma-shapes '((16 8 16) (8 8 8))
  :mma-lowerings  '(:coop-matrix :xe-native))
```

Missing Keys: an incomplete `def-hardware-profile`, one without the full set of keys as illustrated above, is fine.
However any optimizations that depend on it will simply not be taken. 

Unknown Keys: a `def-hardware-profile` sporting any key outside the ones listed above will result in a compilation error.

