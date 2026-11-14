# Endeavour 217 -- XOR-swizzled scratch tiles for ldmatrix (compiler-owned, no syntax)

2026-11-12, branch gpumode-shore (opened right after 216).  **Status: PLANNED -- TDD specs written, red.**
`tests/ci-stop.txt` stays at `216-ldmatrix` until this goes green.

## Why
216 put every 16-bit `mma.sync` fragment behind `ldmatrix`, and that exposed the next wall: **shared-memory
bank conflicts**.  An ldmatrix phase reads 8 rows x 16 bytes.  Today's tiles are plain row-major, so at a
64-byte pitch rows r and r+2 hit the same banks (4-way), and at 128 / 256 bytes every row starts in the same
bank group (8-way).  Per K32 stage of the contest kernel that is ~1500 shared-memory wavefronts against ~320
conflict-free, behind ~512 tensor-core clocks of MMA.

**Priced before opening (step 1 probe, `put_temp_files_here/217/swz.lisp`, diag 971027, A100):**

| shape | ring kernel today | swizzled (probe) | torch |
|---|---:|---:|---:|
| 4096x5120x4096 (scored) | 3554.3 us, bad = 0 | **2228.2 us, bad = 0** | 752.6 |
| 2048x3072x2048 | 623.6 | **405.5** | 137.2 |

-37% / -35%, bit-exact; PTX identical to today's but for 48 `xor.b64`.  (A100 matmul_v2 board: v10 3555 us.)
This is for NVIDIA `mma.sync` everywhere -- A100, L4, consumer RTX, and Hopper / Blackwell kernels that use
mma.sync rather than wgmma / tcgen05.  Intel / SPIR-V is untouched.

## What
A scratch tile that is **swizzle-eligible** keeps its logical shape, pitch and size; only where each 16-byte
chunk lives changes.  Byte offset OFF from the tile's (or ring slot's) base becomes

    OFF' = OFF xor (((OFF >> S) & 7) << 4)        S = max(7, log2 PITCH)

- Only bits 4-6 move, so a 16-byte chunk stays whole: a cp.async 16-byte write and an ldmatrix 16-byte row
  read each touch exactly one chunk, and a single 16-bit element access lands inside its chunk.
- It is a bijection inside every aligned 2^(S+3)-byte block, so a tile that is a whole number of blocks maps
  onto itself.  Relative to the slot base, so ring slots need no alignment beyond what they have.
- Every ldmatrix phase (rows r0..r0+7, r0 a multiple of 8, column a multiple of 8 halves) then hits 8
  different bank groups; every 128-byte run of cp.async writes still does too.
- PITCH is the row pitch in bytes, a power of two >= 32; the tile must be a whole number of blocks.
  At 16 bytes the 8 rows already span 8 bank groups, so there is nothing to fix.

All of this is checked as arithmetic in spec 01 (62434 assertions against a reference implementation; the
identity map -- today's layout -- fails the conflict tests).

**Nothing leaks.**  Shared memory is private to the block and gone when it exits: no caller, hoist, harness or
metadata can observe the permutation, and the byte size is unchanged, so the hoist's smem budget is too.
This is the 216 posture -- the compiler picks the better instruction / layout when it is provably the same
computation.  (Hopper's `wgmma-accumulate ... :swizzle :128b` IS user-visible, because there the author picks
the K-block the descriptor swizzle is tied to; mma.sync has no such choice.)

## The one hard rule
**Every access to a swizzled tile uses the same map, or the tile is not swizzled.**  A missed accessor is a
silent wrong answer, not a compile error.  The probe swizzled exactly two paths (196's 16-byte cp.async
copies and 216's ldmatrix) and was right only because the diag's shapes never reached the others.

### Inventory (step 2 -- to be completed and checked before any codegen change)
What is known now (PTX target):

| access | address computed by | swizzle plan |
|---|---|---|
| load-tile, vectorized cp.async (196) | `%aref-tensor-ir` (the copy-elem reuses the aref's element pointer) | via the aref path |
| load-tile, vec nest's per-element fallback + zero fill (`SET!`) | `%aref-tensor-ir` | via the aref path -- the probe's hole |
| load-tile, per-element cp.async (136; `:transpose`, non-vec) | `%aref-tensor-ir` | via the aref path |
| load-tile without a barrier (sync staging) | `%aref-tensor-ir` (set!) -- confirmed (rung 2) | via the aref path |
| load-tile `:block` (TMA bulk copy) | the TMA engine | **refuse**: the tile is not swizzled |
| ldmatrix (216) | `%216-shared-elem-ptr` | explicit |
| per-element fragment loads (216-ineligible readers) | `%aref-tensor-ir` -- confirmed (rung 2) | via the aref path |
| user `(~ tile r c)`, `store-tile` / `store-tile-at` from scratch | `%aref-tensor-ir` | via the aref path (spec 04) |
| ring-get slot | slot base = ring base + slot x slot-bytes | swizzle is slot-relative |
| `transpose` / sub-tile views, a tile passed to a `def-function`, wgmma / tcgen05 descriptors, stmatrix staging | own addressing | **refuse** (not swizzled) |
| `%coop-*` (`%coop-tensor-ptr+stride`) | Intel / SPIR-V only | n/a |

The claim to PROVE in step 2: *on PTX every element address of a `:local` tensor is computed by
`%aref-tensor-ir` or `%216-shared-elem-ptr`*.  Method: grep + instrument (log every addrspace(3) GEP's
origin while compiling the corpus; anything not from those two is a new row above).

**Result (rung 2, 2026-11-13): the claim HOLDS.**  `put_temp_files_here/217/inventory.lisp` wraps the LLVM
builders (GEP / struct-GEP / ptrtoint / addrspacecast / load / store / atomics / call args): a pointer GEP'd
inside `%aref-tensor-ir` or `%216-shared-elem-ptr` is blessed; every other use of an addrspace(3) pointer is
recorded with the semantic node being generated and the pointer's LLVM name.  Corpus: every non-error spec,
with its own PTX TEST-WITH flags (else sm_80), plain and `--differentiate` -- 2268 compiles (370 do not build
for those flags: SPIR-V-only or arch-gated features).  Every other use falls into one of these buckets
(`inv-full.out`):

| bucket | rows (pointer / node) | why it is not a tile element access |
|---|---|---|
| base plumbing | `__crisp_dynamic_smem` ptrtoint at entry; `mv_src_ptr` GEPs in `semantic-make-view` (ring-get slots and views); `ADDRESS_val` call args (scratch storage threaded down calls) | builds a tile's BASE, never an element; ring slots are whole swizzle blocks (slot-relative), other views are refused by the scan |
| compiler-owned shared memory | `__crisp_mbar_*`, `sig_mbar`, `tc_mbar`, `__crisp_wgu_*` (to-workgroup-uniform), `__crisp_tmem_slot`, `tma_stage_field` / `tc_stage_field` | not scratch tiles |
| TMA / tcgen05 / wgmma | `semantic-nvvm-tma-tile-copy` (`tma_mbar`, `tma_box`), `semantic-nvvm-tma-wait`, `semantic-tcgen05-op`, `semantic-wgmma-tma-store` | refused uses (the scan's whitelist; plus a loud guard on the TMA load-tile analyzer) |
| scratch CELLS | `base_ptr` / `final_ptr_i8` in `semantic-aref` / `semantic-set!` (`%aref-cell-ir`) | a cell is never swizzled |

No row is an element address of a scratch TENSOR outside the two paths.  There is no address-of operator
(`get-pointer` takes an FFI c-handle only), and atomics on tensor elements produced no stranger rows: they
take their pointer from the aref.

Diag 3's mystery (216: a padded pitch passed through the hoist literals broke the one-stage kernel -- some
accessor folds the STATIC pitch) does not affect the swizzle, which never changes the pitch.  It is still
worth naming in the inventory.

## Design decisions
Chris agreed D-217-1..5 as recommended on 2026-11-13 (the "T" was the option's letter, not a template
parameter: nothing is author-visible).  **D-217-1 then changed at rung 2 -- see D-217-6; awaiting Chris's
review.**

- **D-217-6 (rung 2, 2026-11-13) -- D-217-1's (T) replaced by a scoped name list with alias propagation.**
  Reading the code for (T) found that a scratch tile's canonical type IS its implicit kernel parameter's type
  (`analyze-scratch-tensor-expression` registers it in `*implicit-arg-map*` at pass 1): a new `:align` value
  would mint a new tensor template instance, flow into the hoist's scratch arguments and the `.metacrisp`,
  and need the let's binding and the implicit parameter to agree -- a wider change than estimated, and it
  would LEAK (metadata).  And (T)'s "safe failure direction" was only half true: a view constructor builds a
  fresh `:strided` type, so a view would silently DROP the marker and read the plain layout.
  What is implemented instead (`put_temp_files_here/217/impl.lisp`, prototype; same properties as (T), none
  of its footprint):
  1. **decide** at the scratch `let` (`analyze-let-with-tile-explosion`, which already publishes the tile
     dims): a whole-body scan with a WHITELIST of uses; anything else refuses (logged);
  2. **propagate** through `let` aliases -- a binding whose init is a swizzled name or `(ring-get NAME i)` is
     swizzled; exactly the `*194-lane-index-names*` pattern already in `analyze-let-expression`.  This is
     what reaches the gensyms inside load-tile / mma expansions, with no hand-tagging (B's weakness);
  3. **tag** at analysis: an aref of a swizzled tile records S on its array node, an ldmatrix on its hw-op;
  4. **address** at codegen in the two choke points.
  Views are not "safe by default" here either -- they are REFUSED by the scan (not whitelisted).
- **D-217-1 (superseded by D-217-6) -- where "this tile is swizzled" lives.**
  - **(T) a type marker (recommended).**  The scratch binding's canonical tensor type carries it (e.g. a new
    value in the alignment slot, next to `:compact` / `:strided`).  It then flows by itself through `let`s,
    the gensyms inside load-tile expansions, `ring-get`, and into anything the tile is passed to.  The
    failure direction is safe: a consumer that does not know the marker treats the tile as not-compact and
    falls to its generic per-element path -- which is the aref path, which swizzles.  A declared function
    parameter type would not match: a loud compile error, not a wrong answer.  Cost: touches type
    canonicalization; step 2 counts the consumers of the alignment slot to size it.
  - **(B) a binding table** (like `*mma-scratch-tile-dims*`, published by the scratch `let`, resolved by a
    `%198-tile-static-dims`-style helper).  Smaller change, mirrors 196 / 198 -- but the arefs inside our own
    expansions see a GENSYM, not the binding, and must be tagged by hand (the probe did); one forgotten
    expansion = silent corruption.
- **D-217-2 -- a second reader keeps the swizzle (recommended).**  Because the aref path is swizzle-aware, a
  tile that is also read element-wise (spec 04: `store-tile` echoes A-TILE) stays swizzled.  The conservative
  alternative -- any non-ldmatrix use un-swizzles the tile -- is simpler to argue but leaves performance on
  the table for kernels that inspect a tile; it would flip spec 04 to "no xor".
- **D-217-3 -- swizzle only tiles that an ldmatrix reads (recommended).**  A tile no ldmatrix touches gains
  nothing (its readers are per-element) and would only pay the xor.  So eligibility = PTX + an ldmatrix
  reader (216-eligible source of load-fragment-a/b, i.e. mma-accumulate-via-tile) + the shape rule + no
  refused use (TMA fill, view, escape to a function, wgmma / tcgen05 descriptor).
- **D-217-4 -- no syntax, no opt-out.**  `*217-swizzle*` (defvar) NIL turns it off for twin builds, as
  `*216-ldmatrix*` does.  If an author ever needs the plain layout (inspecting shared memory from a debugger,
  say), that is a later conversation.
- **D-217-5 -- PTX only.**  SPIR-V has no ldmatrix here and Intel's SLM story is dead (memory); nothing changes.

## Specs (TDD -- written 2026-11-12, red as expected)
| # | spec | claim | today |
|---|---|---|---|
| 01 | `01-swizzle-math.unit.lisp` | the rule: shift table, chunk-preserving bijection, conflict-free ldmatrix phases and cp.async runs (with a positive control) | FAIL -- functions undefined |
| 02 | `02-swizzle-ldmatrix-k32.crisp` | 1 warp, K32, A 64x32 + B 32x64 both swizzled: 8 x4, 16 x2.trans, 64 MMAs, 0 ld.shared.b16, `xor.b` present; differentiates | FAIL -- no xor |
| 03 | `03-swizzle-ring.crisp` | the contest ring kernel: swizzled ring slots (S = 7 and 8), wait_group 4, `xor.b` present | FAIL -- no xor |
| 04 | `04-swizzle-second-reader.crisp` | D-217-2: A-TILE also echoed by store-tile, still swizzled, echo still reads shared | FAIL -- no xor |
| 05 | `05-no-swizzle-odd-shapes.crisp` | refusal: 48x16 (not whole blocks) and 16x48 (96-byte pitch) stay plain, still ldmatrix, NO xor (forward and backward) | PASS (stays green) |

Validators: `overlays/spec-runner-overlay.lisp` (fold target `tests/run-specs.lisp`), differentiate-aware
(02 / 04 / 05 pin counts only in the plain pass).  Every spec compiles today, plain and `--differentiate`
(03 keeps 216's real D-196-12 skip; 04's first draft carried a SKIP-WITH -- removed after trying the flag).

**A PTX validator can see THAT addresses are swizzled, never that writer and reader agree.**  Agreement is a
metal claim -- see step 7.  `xor.b` as the signal is deliberately loose (width not pinned); if LLVM ever folds
the xor into an add on disjoint bits, the validators must change, not the feature.

## Plan (rungs)
1. **The rule** -- `%217-swizzle-shift` / `%217-swizzle-offset` (src/mma.lisp).  Spec 01 green.
2. **Inventory** -- complete the table above, prove the "two address paths" claim, count the alignment-slot
   consumers (sizes D-217-1).  Write the result here.  **Chris decides D-217-1..3 here.**
3. **Eligibility + marker** -- decide per scratch binding (and per scratch ring) at its `let`; log every
   decision and every refusal with its reason (216 style).
4. **Swizzle the two address paths** -- `%aref-tensor-ir` and `%216-shared-elem-ptr`, keyed off the marker.
   Specs 02, 04 green; 05 still green.
5. **Ring slots** -- spec 03 green (slot-relative; should fall out of 4).
6. **--differentiate** -- the backward's materialized transposes / staged dC are scratch tiles too: they swizzle
   or not by the same rule.  One filtered `--differentiate` run on 216 + 217 (memory: don't defer it to CI).
7. **Metal (popcorn, A100 first; no pod needed)** --
   - a twin A/B in one diag submission: `*217-swizzle*` on / off for the ring kernel (repeat of the probe,
     now with the real implementation);
   - a correctness diag: spec-04's echo kernel (AECHO must equal A's tiles) and the K32 kernel;
   - matmul_v2 **test** mode on A100 with a v11 -- its ragged test shapes are what reach the per-element
     fallback and zero fill the probe never touched;
   - then leaderboard A100, and L4 straight to leaderboard (L4 test mode times out -- memory).
8. **Definition of done** -- plan/definition-of-done.md; reference.md; the full suites (unit / E2E / negative,
   plus one filtered --differentiate); bump `tests/ci-stop.txt` to `217-swizzle` (CRLF); fold after review.

## Status (2026-11-13)
Implementation: `overlays/crisp-compiler-overlay.lisp`, the "Endeavour 217" block at the end (the rule
functions, then rungs 3-5 per D-217-6).  `tests/ci-stop.txt` = `217-swizzle`.

| rung | result |
|---|---|
| 1 rule | spec 01 green: 62434 assertions |
| 2 inventory | the two-path claim holds (table above); D-217-1 -> D-217-6 |
| 3-5 decide / tag / address | specs 02, 03, 04 green (xor present, ldmatrix / mma counts unchanged: 02 = 24 ldmatrix / 64 mma, 03 = 93 / 256); 05 green (no xor).  PTX check by hand: the cp.async destination is `off ^ ((off >> 7 & 7) << 4)` -- writer and reader share the map |
| 6 --differentiate | 216 and 217 filtered: 4/4 each.  The BACKWARD kernel's tiles are refused (their uses include `store-fragment` / `workgroup-stride`, not whitelisted), so they stay plain -- safe, and a later widening if the backward ever matters |
| suites | unit all pass; E2E 1856/1856; negative 507/507 |
| 7 metal | see below |

**Metal, A100 (popcorn).**
- Diag 971121 (`build_diag_ampere_217b.py`, ring kernel, today vs the real swizzle, every arm checked against
  the reference):

  | shape | today | swizzled |
  |---|---|---|
  | 4096x5120x4096 | 2886.7 us exact | **1640.4 us exact** (-43%) |
  | 2048x3072x2048 | 506.9 us exact | **293.9 us exact** (-42%) |
  | 127x257x96 (ragged M, N: per-element fallback + zero fill) | 174.1 exact | 172.0 exact |
  | 1000x1100x1030 | wrong | wrong, same count -- CONTROL fails too: the ring walks K / 32 whole stages (v10's dispatch requires K % 32) |
- v11 (`build_v11.py`: v10 rebuilt; H100 / B200 / small PTX byte-identical to v10, only the ring changed):
  **test mode passed** (971122).  Note: test mode's ragged shapes dispatch to the SMALL kernel, whose
  tiles (16x16, 16x8 half) the rule refuses -- so the swizzled per-element fallback's metal evidence is the
  diag's 127x257x96 row, not test mode.
- **A100 leaderboard: v11 = 2029.6 us** (971123; v10 was 3555).
- **L4: v11 does NOT pass.**  971129 hard timeout (~1555 s, empty queue); 971140 "ranked validation failed on
  L4; submission will not appear on the leaderboard" (no detail given).  Control: v10 on L4 leaderboard passed
  in ~215 s (971139, 4808 us), so the runner was healthy.  An L4 diag cannot run (test mode hits the hard
  timeout: 971141).  Open -- see F-217-2.
- **Not yet on metal: a second reader** (spec 04's `store-tile` echo of a swizzled tile).  Its PTX carries the
  xor and the inventory puts it on the aref path; no GPU run reads it back yet.

## Risks
- **A missed accessor** (the hard rule).  Mitigations: the step-2 proof, D-217-1 (T)'s safe failure
  direction, refusing every use not in the table, and metal shapes chosen to reach every path.
- **216 specs change shape**: 216/01's tiles (64x16, 16x64 half) are eligible, so they gain xor; their
  validators pin ldmatrix / mma / ld.shared.b16 counts, not xor, so they should stay green -- check, don't assume.
- **Ragged tiles**: a partial edge tile is written per element with zero fill; it must swizzle the same way
  (aref path) -- this is exactly what matmul_v2 test mode exercises.

## Findings (not 217's to fix)
- **F-217-1 -- 22 unit files may never execute.**  `run-specs` runs only `crisp.compiler::crisp.tests`
  (173-shuffles/warp-size.unit.lisp documents this); a `define-test` without that parent loads, prints PASS
  and is never run.  30 of the 43 `.unit.lisp` files have no `:parent`; 8 of those run their own suite at load
  (the loader checks the output), leaving 22 that look dead -- list in
  `put_temp_files_here/217/dead-units.txt` (006, 049, 052, 120, 123, 147, 167, 176-184, 186, 190, 193,
  195/07).  217's own first draft had the same bug (caught: it printed PASS before the feature existed).
  NOT verified file by file -- a top-level assertion at load would also count.  To check: drop a deliberate
  failure into one and see whether the spec run notices.
- **F-217-2 -- the ring `await` is steady-state only (HYPOTHESIS for the L4 failure, not confirmed).**  `await`
  on a `:linear` ring lowers to ONE static `cp.async.wait_group N`, N = (ring-count - 1) x arrivals
  (`barrier-ring-count-of`; 4 for the contest ring).  CUTLASS keeps that N valid by committing a group every
  iteration, empty or not; the contest kernel issues its loads under `(when more? ..)`, so in the last two K
  iterations (and from the start when K / 32 < 3) the group count drops and `wait_group 4` waits for NOTHING
  -- the stage about to be read is among the 4 allowed to be pending.  On metal it does not show on A100:
  diag 971150 (K = 64 / 96 at 8192^2, plain and swizzled, 3-4 checks each) is exact everywhere.  L4 has
  ~1/5 of A100's DRAM bandwidth, and the swizzle made the reads faster, which is the shape of a window
  closing -- but that is an argument, not evidence.  Candidate fixes (decision for Chris): the compiler
  commits an empty group where a ring load-tile is skipped / the kernel drops `(when more? ..)` and lets an
  out-of-range load-tile zero-fill and commit; or per-slot mbarrier tracking (cp.async.mbarrier.arrive).

  **L4 pod, 2026-11-13 (pod-session, ~5 min; batch in put_temp_files_here/217/l4/, results_run2/).**  stress.py
  calls each submission's `custom_kernel` with a fresh seed per rep (what eval.py leaderboard does: recheck
  every rep, up to 100 reps per benchmark -- test mode checks each case ONCE, which is why v11 passed test and
  failed ranked).  On L4 all 8 benchmarks dispatch to the ring.

  | shape | v11 (swizzled) bad reps | v10 (plain) bad reps |
  |---|---|---|
  | 128^3, 256^3, 512^3 | 0 / 300 | 0 / 150 |
  | 1024 x 1536 x 1024 | **46 / 300** | 0 / 150 |
  | 2048 x 3072 x 2048 | 0 / 300 | 0 / 150 |
  | 4096 x 5120 x 4096 (scored) | **260 / 300** | 0 / 150 |
  | 4096^2 x 64, 4096^2 x 96, 8192^2 x 64 | 0 / 300 | 0 / 150 |
  | 1024^3, 2048^3 | 300 / 300 | 150 / 150 -- identical 1-ulp mismatches in both: the pod's torch 2.4.1 cuBLAS, not ours |

  v11's failures are 1-20 whole 128 x 128 output tiles (or a 32-column strip of one) per rep, max rel error
  0.3-1.1 %, median ~0.1 %.  That is the size of ONE K slice replaced by stale data: a stale slot holds the
  slice from 3 iterations earlier, so the error is the difference of two random 32-term slices (sd ~1.8 on
  a sum of ~1024 -> median ~0.12 %, max ~0.6 % predicted at the scored shape; 0.096 % / 0.64 % observed).
  The PTX agrees with the mechanism: in both v10 and v11 the refill's two `commit_group`s sit on the
  `more?` branch, and the loop's only wait is `cp.async.wait_group 4`.  Not yet explained: why the K = 64 / 96
  shapes (where the FIRST iteration under-waits) are clean.

  **CONFIRMED (L4 pod run 4, torch 2.8 / CUDA 12.8 image; results_run4 = results/).**  v11w0 = v11 with ONE PTX
  line changed, the ring's `cp.async.wait_group 4` -> `wait_group 0` (every ldmatrix address, swizzle
  included, unchanged).  300 fresh-seed reps each:

  | shape | v11 | v11w0 | v10 |
  |---|---|---|---|
  | 1024 x 1536 x 1024 | 86 bad | **0** | 0 |
  | 4096 x 5120 x 4096 (scored) | 239 bad | **0** | 0 |
  | 2048 x 3072 x 2048 | 1 bad | 0 | 0 |
  | 1024^3 / 2048^3 (pod cuBLAS 1 ulp off everyone) | 83.9 M / 168.61 M bad elems | 64,657,935 / 168,564,935 | **identical** to v11w0 |

  So the swizzle map is exonerated -- v11w0's output is bit-identical to v10's wherever both can be compared
  -- and F-217-2 is a bug in the ring's `await` lowering that v10 carries too (its passing L4 is a timing
  margin the faster swizzled loop removed).  Price of the blunt wait on the scored shape (L4, min of 300):
  v11 3108 us (wrong), v11w0 3199 us, v10 3824 us -- even fully serialized the swizzled ring beats v10 by 16 %.
  Still unexplained: why K = 64 / 96 (first iteration under-waits) never failed.  The pod's reference
  disagreeing at 1024^3 / 2048^3 is the pod's cuBLAS (both torch 2.4.1 and 2.8.0), not GPU MODE's: v10
  passed ranked there (971139).

  **FIXED (2026-11-13, Chris chose the count-correct await; overlay block "Endeavour 217 F-217-2").**  Each
  :linear ring keeps a per-thread i32 of its committed-not-yet-awaited groups (an entry-block alloca, so a
  register after mem2reg): a ring load-tile's commit adds 1; an await sets NEWER = pending - arrivals,
  waits for the largest multiple of arrivals <= NEWER, capped at the old depth (wait_group takes an
  immediate, so it is a compare chain: 4 / 2 / 0 here), and leaves pending = max(NEWER, 0).  Awaits are
  taken in load order (the ring's FIFO, which the static depth already assumed); another ring's groups are
  not counted, so two rings only ever over-wait.  Warp-specialized awaits and non-ring barriers keep their
  static wait.  `*217-count-await*` NIL restores the old lowering for a twin.  The contest kernel's PTX:
  `mov 0` at entry, `add 2` at each stage's commit, the 4 / 2 / 0 chain, `max.s32` retire (hand-read).
  Spec 06 (`06-ring-tail-await.crisp`) pins the chain; red before, green after.

  Metal, v12 = v11 rebuilt (only the ring's PTX differs; the other four kernels byte-identical):

  | run | result |
  |---|---|
  | L4 pod, 300 reps x 11 shapes (8 benchmarks + K = 64 / 96 tails) | v12 **0 bad** everywhere checkable; at 1024^3 / 2048^3 bit-identical to the wait_group 0 twin.  Same session: v11 117 / 300 and 244 / 300 (the race was live) |
  | L4 pod speed, scored shape (min of 300) | v12 3098 us = v11 3022 (wrong) ~ wait_group 0 3115; 1024 x 1536 x 1024 median v12 94.3 vs wait_group 0 111.6 -- the overlap is kept |
  | GPU MODE L4 leaderboard 971198 | **passed, 3518.9 us** (v10 4808) |
  | GPU MODE A100 leaderboard 971199 | **passed, 2016.3 us** (v11 2029.6, v10 3555) |
