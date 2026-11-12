# Endeavour 216 -- ldmatrix for 16-bit mma.sync fragments (the A100 / L4 matmul lever)

2026-11-12, branch gpumode-shore.  Overlay (not folded).  Done while Chris was away: every decision is
listed under **Decisions for review** at the end.

## Why
matmul_v2 on GPU MODE: A100 #56 / 57 at 12.2% of #1 (cuBLAS, ~596 us), L4 #21 / 21 at 29.9%.  The
4-warp Ampere kernel read every 16-bit fragment element from shared memory with its own `ld.shared.b16`
-- 8 per A fragment, 4 per B fragment, 616 for 256 MMAs per K32 stage -- and then re-packed them in pairs
for the MMA (src/mma.lisp: "ldmatrix is a later perf optimization").  plan/scramble.md listed it.

## What
`analyze-load-fragment-a` / `-b` (src/mma.lisp) are wrapped.  A 16-bit fragment on PTX whose source is an
ELIGIBLE matrix becomes ONE `semantic-hw-op` (endeavour 170's node -- no new struct, no etypecase edits):

| operand | instruction | lane L supplies the row address |
|---|---|---|
| A (16x16) | `ldmatrix.sync.aligned.m8n8.x4.shared.b16` | row 16 TY + L%8 + 8((L/8)%2), col 16 TK + 8(L/16) |
| B (16x8 of a row-major (K N) tile) | `ldmatrix.sync.aligned.m8n8.x2.trans.shared.b16` | row 16 TK + L%8 + 8((L/8)%2), col 8 TX |

The matrices come back in the mma operand order (A: Ra0..Ra3 = rows +0/+8 x cols +0/+8; B: K +0 / +8), and
ldmatrix's per-lane pair (row L/4, cols 2(L%4), 2(L%4)+1 -- .trans: rows 2(L%4), +1 of col L/4) IS the mma
pair, lower index in the low half.  `%216-ldmatrix-lower` splits each .b32 into the record's two 16-bit
fields; `%emit-nvvm-mma` re-packs them; LLVM folds both away.  NVVM: `llvm.nvvm.ldmatrix.sync.aligned.
m8n8.{x4,x2.trans}.b16.p3` (LLVM 21; probed with clang first).

**Eligible** (`%216-ldmatrix-eligible-p`): PTX; 16-bit element (fp16 / bf16); the source's canonical type is
`:local` (shared), `:compact` and `:last` (row-major); its static (ROWS COLS) are known
(`%198-tile-static-dims`: a scratch binding or a ring-get of a scratch ring); and its row is a multiple of
16 bytes.  Anything else keeps the per-element reads, which are right for any layout.  `*216-ldmatrix*`
NIL turns it off (the twin-PTX switch: `put_temp_files_here/216/cc.lisp --off`).

`:compact` is checked separately because a `(transpose X)` view keeps X's `:last` and marks only its
alignment slot `:strided` (today such a view also has no static dims, so it was refused anyway).

The backward is covered by the same path: under `--differentiate` the backward MMAs read materialized
transposes (`A-TILE_BWT`, `B-TILE_BWT`) and a staged dC (`C-TILE_BWDC`), all compact row-major shared tiles
(traced, `put_temp_files_here/216/trace.lisp`), so they are ldmatrix too.

## Specs
| spec | checks |
|---|---|
| 01-ldmatrix-fp16 | 1 warp, 64x64 tile, K16: 32 fp16 MMAs, 4 `x4`, 8 `x2.trans`, 0 `ld.shared.b16`; float C so it differentiates |
| 02-ldmatrix-bf16 | the same for bf16 |
| 03-ldmatrix-ring | the contest ring kernel: ldmatrix from `ring-get`, 0 `ld.shared.b16`, `cp.async.wait_group 4` (counts not pinned: LLVM merges warp branches) |
| 04-global-fragment-no-ldmatrix | a fragment from GLOBAL memory: 1 MMA, 0 ldmatrix, 12 `ld.global.nc.b16` |
Validators: overlays/spec-runner-overlay.lisp (fold target tests/run-specs.lisp).  Needles are whole
instruction spellings -- "ldmatrix" alone matched the kernel names (renamed frag_fp16 etc.).

## Metal (popcorn; matmul_v2 requires an exact match against cuBLAS)
All arms exact (bad = 0) unless noted.  Times are medians of 15 with L2 flushed; only arms inside ONE
submission compare -- runners differ (diag 3 landed on an A100-SXM4 where k32ldm took 3704 us vs 3037 on the
PCIe runner of diag 2).

**Diag 1** (970853, A100 80GB PCIe; `build_diag_ampere_216.py`): the twin A/B, same compiler with
`*216-ldmatrix*` off for the `off` arm.
| arm | 4096 x 5120 x 4096 (scored) | 2048 x 3072 x 2048 |
|---|---:|---:|
| K32, per-element reads (`--off` twin) | 4203.5 | 724.0 |
| **K32, ldmatrix** | **3032.1** | **539.6** |
| K16, ldmatrix | 3013.6 | 523.3 |
| torch (cuBLAS) | 641.0 | 114.7 |

**Diag 2** (970856 A100 PCIe, 970860 L4; `build_diag_ampere_216b.py`): the 3-slot cp.async ring
(`matmul_ampere_4w_ring.crisp`) against the one-stage K32 kernel, both ldmatrix.
| arm | A100 scored | A100 2048 | L4 scored | L4 2048 |
|---|---:|---:|---:|---:|
| K32 ldmatrix | 3037.2 | 548.9 | 4520.9 | 1218.6 |
| **ring3 ldmatrix** | **2897.9** | **514.0** | **4355.1** | **843.8** |
| torch | 635.9 | 113.7 | 2384.9 | 369.7 |
For reference, the boards before 216: A100 v5 4863 us, L4 v8 6662 us.

**Diag 3** (970863, A100-SXM4; `build_diag_ampere_216c.py`) tried to PRICE the bank conflicts with no
compiler change, by widening the scratch row pitch through the hoist's literals (A 32 -> 40, B 128 -> 136
halves).  It does not work, and that is the finding: `k32pad` came back WRONG (20.8M bad), so some accessor
(endeavour 213's typed-GEP addressing is the suspect) folds the pitch from static dims while ldmatrix follows
the run-time stride; `ring3pad` was exact and exactly as fast as `ring3` (3564 vs 3555), i.e. ring slots
ignore the literal strides altogether.  A padded scratch needs real compiler support -- D-216-5.

**v10** (`crisp_matmul_v10.py`, `package_matmul.build_v10`): v9 with the A100 / L4 lane on the ring kernel.
A100 test 970864 passed (every test shape, exact -- including the small fallback, which is ldmatrix too);
**leaderboard 970869: 3555.3 us** public (secret 3556.0), v5's 4863 before -> 16.8% of #1 (was 12.2%); still
#56 / 57, the field being cuBLAS at ~600-700 us.  L4: test 970865 and retry 970870 both hit GPU MODE's hard
timeout (so did diag 3's L4 half, 970866, and every B200 job tonight), so v10 is NOT on the L4 board yet;
diag 2 measured it there at 4355 us vs v8's 6662.  A 4th L4 test (970880, after the B200 runner recovered) timed out too;
a plain `torch.matmul` control (970884, `baseline_torch_matmul.py`) then SUCCEEDED -- but only after 1510 s end
to end, just under the ~1555 s hard timeout, behind a 3-job L4 queue.  So the L4 timeouts are consistent with
queue congestion, not a hang; not proven, since the A100 test (970864) only shows the same sm_80 PTX is right
on sm_80.  A 5th L4 test (970965) timed out with 0 queued jobs: on L4, TEST mode itself runs at the limit (torch
1510 s), while leaderboard mode is far shorter (A100 v10: test 800 s, leaderboard 195 s).  So v10 went straight
to the L4 leaderboard: **970973 passed in 140 s, 4359.2 us public (secret 4929.7), v8's 6662 before -> 45.6% of
#1 (was 29.9%)**; still #21 / 21.

## Decisions for review
- **D-216-1 -- a wrapped analyzer and a `semantic-hw-op`, no new node.**  `analyze-load-fragment-a/-b` are
  wrapped (`*216-orig-analyze-load-fragment-a/-b*` hold the src originals) and the ldmatrix is endeavour 170's
  hw-op with two new `%hw-lower` methods.  So nothing in src needed patching (no struct, no etypecase), and
  ANF / AD never see a new form: they work on source forms, and this exists only as a node.  Fold target:
  src/mma.lisp next to the analyzers; the wrappers then become the analyzers' first branch.
- **D-216-2 -- it applies to EVERY eligible 16-bit mma.sync fragment, no opt-in.**  Including the small
  fallback kernel and the backward GEMMs under --differentiate.  `*216-ldmatrix*` is a defvar for twin builds,
  not a user flag.  Correctness rests on eligibility (shared, compact, row-major, static dims, 16-byte pitch);
  anything else keeps the per-element reads.
- **D-216-3 -- B is one `x2.trans` per 16x8 fragment.**  `x4.trans` could load two adjacent N fragments in one
  instruction (half the B ldmatrix count), but %emit-per-frag-accumulate loads fragments one at a time; pairing
  them is a change there.  Not done.
- **D-216-4 -- specs 01 / 02 store a float C** so they differentiate (a `(to-half C-tile)` store hits D-196-12,
  which is real).  Spec 03 keeps the contest's to-half store and that skip.  Spec 04's first draft claimed a
  fragment MMA was not differentiable -- wrong (145/07 says it is), removed after trying the flag.
- **D-216-5 -- NO padding / swizzle.  This is the open question for Chris.**  Arithmetic says bank conflicts
  are now the A100 limit: per K32 stage the 4 warps issue 256 MMAs (~512 tensor-core clocks) but the ldmatrix
  reads are 4-way (A, 64 B pitch) and 8-way (B, 256 B pitch) conflicted, ~1500 shared-memory wavefronts vs ~320
  conflict-free.  The ring's small gain (-5%) fits: latency was not the wall.  Options: (a) `make-scratch-matrix
  ... :pad N` (language surface -- your call), (b) a compiler-owned padded pitch for scratch tiles only read by
  ldmatrix / written by load-tile (no syntax, but +25% smem for A at K32: the 3-slot ring would leave 48 KB),
  (c) an XOR swizzle in both cp.async and ldmatrix addressing (no smem cost, every accessor must agree).  Diag 3
  shows the run-time stride is NOT what every accessor uses (see above), so any of these is a real change.
- **D-216-6 -- the contest kernel keeps the existing `:warps` split: each warp owns 128 x 32.**  A 64 x 64 warp
  tile would read A half as often (8 A x4 + 16 B x2 per warp-stage instead of 16 + 8).  Not explored.
- **D-216-7 -- v10 is a separate file and build function** (`package_matmul.build_v10`); v9 stays as
  submitted.  Its H100 / B200 PTX is byte-identical to v9's (compared); only the Ampere lane (ring) and the small
  fallback changed.  Submitted to A100 and L4 only.
- **D-216-8 -- validators in overlays/spec-runner-overlay.lisp, --differentiate-aware** (01 / 02 count forward
  + dA + dB: 96 MMAs, 24 x4, 48 x2.trans).  Positive control: the `--off` twin of spec 01 has 0 ldmatrix and 64
  `ld.shared.b16`, so the validator fails it.  tests/ci-stop.txt bumped to 216-ldmatrix (CRLF kept).
- **F-216-1 (found, not caused) -- `--use-binary` cannot find SPIR-V validators.**  tests/run-specs.lisp ~2585
  (the binary-mode SPV path) looks the validator up only in :crisp.compiler; validate-spv-relaxed-load-store,
  -200-helpers-noinline, -211-helpers-noinline and -212-vote live in the runner's package.  So CI step 11's
  command (`--use-binary --differentiate --skip-unit-tests`), run LOCALLY, fails 195/01, 200/01, 211/04, 212/05
  with "Validator fn ... not found" (1848 / 1852; every MMA spec passes).  **FIXED 2026-11-12** (Chris OK'd a
  direct edit): plain `--use-binary` failed too (195/01 + 195/03, 200/01, 211/04, 212/05), so CI's E2E steps
  were likely red since 195.  New `%resolve-spec-validator` (symbol as read, then :crisp.spec-runner, then
  :crisp.compiler) serves the binary path and the live in-process path.  Binary, binary --differentiate and
  in-process suites: 1852 / 1852 each.
- **F-216-2 -- the GPU MODE B200 runner hard-timed-out every job tonight**, including a plain `torch.sort`
  control (970861), so sort_v2 on B200 timed out (970852 test, 970857 leaderboard).  A retry after the runner recovered passed: **sort_v2 B200 leaderboard 2533.6 us, #18 / 30**.
