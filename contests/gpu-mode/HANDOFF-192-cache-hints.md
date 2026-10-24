# Handoff: cache hints (endeavour 192) for the GPU MODE entries

For AntiGravity, from the compiler side. Crisp can now declare cache hints, and two other things that
affect contest kernels changed. Nothing here has been run on NVIDIA hardware yet (no pod); everything
was assembled with CUDA 12.4 `ptxas` for sm_80 and sm_90 and runs correctly on BMG.

## 1. What changed in Crisp

**`:cache` on storage-handle types.** Add it to a `:global` type:

```lisp
(def-type in-vec (vector float :address-space :global :align :compact :cache :streaming))
(def-type in-vec (vector float :address-space :global :align :compact :cache (:streaming :prefetch 256)))
```

| Intent | PTX it emits | Use for |
|---|---|---|
| `:streaming` | `ld/st.global.cs` (evict-first, L1 + L2) | data touched once (vectorsum's input) |
| `:reused` | `.L2::cache_hint` + `createpolicy ... L2::evict_last` (sm_80+) | data re-read (matmul A / B) |
| `:no-l1` | `.cg` | skip L1, keep in L2 |
| `(INTENT :prefetch 64/128/256)` | adds `.L2::NB` to loads | bigger L2 fetch per miss |

Views (`make-vector ... float4`) and tile operations inherit the hint. `:cache` on a tile operation
itself is refused. Full description: `docs/ideal_001.md`, "Cache hints".

**BUG 134 fixed: float4 views keep the read-only path.** A kernel that reads the *lanes* of a float4
view (`x~ y~ z~ w~`) used to get plain `ld.global.v4` -- LLVM's -O3 dropped `!invariant.load`. It now
gets `ld.global.nc.v4`.

**Read-only needs `&out`.** Only tensors declared *before* `&out` are read-only. None of the current
vectorsum kernels has an `&out`, so none of them gets `.nc` at all. Write the outputs after `&out`:

```lisp
(def-kernel vectorsum_kernel (input &out partial ticket result)
  (declare #'(in-vec &out acc-cell ticket-cell out-cell => nil) ...)
```

## 2. What to try on vectorsum

Starting point: `contests/gpu-mode/02-vectorsum-v2/vectorsum_lastman_wg.crisp` (the current
leaderboard entry, `crisp_vectorsum_lastman_wg_occ1.py`). Hand-patched PTX measured on H100 (52M,
popcorn `benchmark` mode) is what motivated 192:

| Variant | H100 | B200 |
|---|---|---|
| current entry | 83-85 us | 43.0 us |
| `.cs` loads | 83.1-83.3 | 43.0 |
| `(unroll 8)` + read-only + `L1::no_allocate` + `L2::256B` | **80.8** | 43.5 |

So, in order:
1. `&out` signature (above) -- free `.nc`.
2. `:cache (:streaming :prefetch 256)` on `in-vec`, plus `(declare (unroll 8))` inside the
   `loop-vector-stride`. Note `:streaming` now emits `.cs`, not the `L1::no_allocate` of the hand
   patch (ptxas 12.4 refuses `L1::no_allocate.L2::evict_first`), so re-measure rather than assume 80.8.
3. Expect nothing on B200, and measure A100 / L4 -- never measured.

Leaderboard runs are the real check (they re-seed every repetition). The leaderboard score tracks the
52M case.

## 3. Packaging notes

- **Hints arrive as inline asm inside Crisp's PTX** (`ld.global.cs.nc.v4.f32 ...`, and for `:reused` a
  `{ .reg .b64 %crp; createpolicy...; ld...L2::cache_hint...; }` block). `contests/ptx_packager.py`
  handles both as is: the register-prefix regex does not touch `%crp`, and `%` is escaped generically.
  The PTX ISA version is set by nvcc's own module, which is new enough for these qualifiers.
- **`package_vectorsum.py` has two helpers you should adopt everywhere:**
  `compile_crisp_with_cuda_hoist` + `param_map_from_cuda_hoist` read the kernel ABI (including implicit
  scratch such as `reduce-workgroup`'s shared memory) from Crisp's own `--hoist=cuda` launcher, instead
  of a hand-written positional param map. `make_gpumode_vectorsum_lastman` shows the persistent
  16-byte scratch (double partial + ticket, reset by the kernel) that removes all per-call host work.
- **Rate limit:** 6 test / benchmark / profile submissions per hour. `--mode profile` was broken on
  GPU MODE's side on 2026-10-23 (`_posixsubprocess`).

## 4. For `plan/contest-bugs.md` (yours to edit)

BUG-002 resolution, as measured on 2026-10-23: the cause was thousands of FP32 atomics into one cell,
which fail rtol=1e-5 on ~6% of random inputs. Leaderboard mode re-seeds every timing repetition, so
it nearly always hit one. Per-thread FP32 accumulation is fine. The fix is FP32 per thread and FP64
only for the cross-thread sum (warp/workgroup reduce + atomic), plus a last-workgroup write of the
float. FP64 in the hot loop was never needed. Simulation: `put_temp_files_here/vectorsum_mc.c`.
