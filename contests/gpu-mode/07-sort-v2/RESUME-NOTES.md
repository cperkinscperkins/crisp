# sort_v2 resume (branch resume-gpumode, 2026-11-09) -- working notes

Decision (Chris): a GENERAL sort; no exploiting the contest generator's near-sortedness.

## B200 matmul (parked)
- v5 to B200 test: 969993 timed out (1555 s, 3 queued).  Pure torch.matmul control 970001 timed out
  (1760 s, 17 queued) -> GPU MODE's B200 runner, not us.
- crisp_matmul_v6.py (B200 -> transpose_b + matmul_b200_tcgen05.crisp) built, never run.
- package_matmul.py now parses BOTH descriptor ABIs (pre-210 device-memory, 210 by-value).

## Lever 1: 32-bit tile index math (v1d) -- H100 diag, 100M, per pass
| arm | downsweep | upsweep | scan | minmax | wall |
|---|---:|---:|---:|---:|---:|
| v1c (ranked, 970020) | 959 | 189 | 36 | 203 | 3790 |
| v1d (970021) | 803 | 189 | 37 | 207 | 3330 |

- SASS (ptxas sm_90a, docker), downsweep: 3368 -> 3056 instrs; IMAD 602 -> 442, PLOP3 229 -> 96.
  Regs 40 -> 56, still 4 blocks/SM (smem-bound, 53 KB).
- Gain (-16%) beat the SASS count (-9%).
- Shared-memory addresses are 64-bit in Crisp's PTX (generic 64-bit regs + cvt.u64.u32 per access);
  ptxas narrows most of it.

## v1e = v1d + 32-bit upsweep + 128-bit minmax loads (970022)
minmax 207 -> 171; upsweep unchanged (208 / 193 / 193); downsweep 803; wall 3330 -> 3290.  BMG bit-exact
incl. n mod 4 = 1, 2, 3.
- Upsweep at ~2.1 TB/s regardless of index width and of digit skew (pass 0 random low byte vs pass 2
  near-constant top byte: 208 vs 193) -> not atomic contention, not instructions.  Suspect: one 4096-key
  tile per 256-thread workgroup, 24K short-lived workgroups (launch / retire churn, load-then-atomics with
  nothing else in flight).  Candidate: several tiles per workgroup with the next tile's loads in flight.
- Budget now: 171 + 3 x (193 + 36 + 803) = 3267 us; downsweep = 74%.

## v1f = v1e with 8192-key tiles, 32 keys/thread (970024) -- REJECTED
downsweep 803 -> 970 (smem 53 -> 86 KB: 4 -> 2 workgroups/SM); upsweep 193 -> 157 (8 uint4 in flight per
thread); scan 36 -> 21; wall 3290 -> 3640.  Correct.  The downsweep needs its occupancy more than it needs
fewer per-tile fixed costs.  BMG harness: SORT_TILE=8192 env; negative control (4096) fails (-5).

## v1g = v1e + upsweep at 128 threads x 8 uint4 per 4096-key tile -- REJECTED
upsweep 193 -> 200-224; rest unchanged.  In-flight bytes per thread are NOT the upsweep's limit.
(The diag's occupancy line assumes 256 threads; its "8 blocks/SM" for the 128-thread upsweep is wrong.)

New theory: the per-tile histogram is written DIGIT-major (hist[d * nb + tile]) so each tile's 256
counts hit 256 different sectors: 24K tiles x 256 x 32 B = ~196 MB of write sectors vs 400 MB read.
v1f halved that (and the tile count) -> its 157.  Probe `_probe_hist/` (fenced, timing only): v1e upsweep
writing digit-major (control) / tile-major / nothing.
Probe 970026 (pass 0, 100M): digit-major 193 (= control), tile-major 150, no write 136.  CONFIRMED.

## v1h = v1e + tile-major hist/scanned + chunked two-kernel scan
hist[tile * 256 + d]; sort_scan_chunks (chunk = 128 tiles, thread = digit, per-chunk sums) and
sort_scan_tiles (base = sum of earlier chunk rows, then walk the chunk); the downsweep's scanned read is
coalesced too.  BMG bit-exact incl. 1 chunk exactly (524288), 1 chunk + 1 tile, 8 chunks partial.
Harness: SORT_SCAN2=1.  H100 runtime: custom_kernel override (build_diag_v1h.py SCAN2).
970037: 100M wall 3290 -> 3162; per pass upsweep 149, scan 22 + 28 (vs 36), downsweep 784 (vs 803).
BUT 10M 447 -> 530 and 1M 178 -> ~350: the fixed 128-tile chunks leave few long serial walks (scan
kernels 13-22 us each at 10M / 1M).

## v1i = v1h with ng = ceil(sqrt(tiles)) chunks, chunk derived in-kernel from the csum length
Empty / short last chunks are harmless (end = min(nb, t0 + chunk); the last group's run = total).
BMG bit-exact incl. 3/4/6/7/10-tile inputs (SORT_SCAN2=sqrt).
970038: 100M wall 3150 (per pass upsweep 150, scan 21 + 30, downsweep 783); 10M 449 (= v1e); 1M ~190
(v1e 178).  BEST.  Total vs ranked v1c: 3790 -> 3150 (-17%), all from data layout / index width.

## Summary at v1i (100M, per pass): minmax 171 once; upsweep 150; scan 51; downsweep 783 (77%).

## Tooling fixed
package_sort.submit_popcorn returned stdout only; popcorn's 429 "Try again in Ns" is on stderr, so
submit_queue.py never waited.  Now returns stdout + stderr.

## Folded (2026-11-10): sort_radix.crisp = v1i; package_sort.RUNTIME launches scan_chunks + scan_tiles
crisp_sort_v1.py / diag_sort_v1.py rebuilt: PTX + ABI byte-identical to the v1i diag.  BMG bit-exact (36 cases).
H100 test 970307 all pass.  Leaderboard 970308 H100 4058 / 970309 A100 7617 / 970310 L4 28000 (public us);
the 10-30 v1c ranked runs were 3749 / 8156 / 25319.

## Rotate probe (970311): four downsweep copies with a LITERAL shift (0/8/16/24), runtime picks per pass
Correct at 100M/10M/1M.  SASS 3056 -> 2608 (-15%), regs 56 -> 40.  100M: downsweep 783 -> ~690 per pass,
wall 3150 -> 2892 (-8%).  = the ceiling for a run-time rotate builtin (shf.r.wrap is one instruction).

## Same-machine A/B under eval.py's procedure (970313, diagab_lb.py): clear_l2 + events, mean of 8
| arm | FIX input | NEW input per rep |
|---|---:|---:|
| v1c | 4928 | 4922 |
| v1i | 4065 | 4063 |
| rotate probe | 3710 | 3711 |
| torch.sort (CUB) | 5326 | 5957 (first rep 10292) |
- v1i -17.5% vs v1c on ONE machine; fresh inputs change nothing (arg-cache theory refuted).
- That H100 is ~30% slower than the diag machines (v1c 4922 vs 3790; v1i 4063 vs 3150): H100 runners
  differ by ~30%, so a single LB score is mostly the node.  The LB keeps the best (v1c 3749, 10-30).
- Our general radix sort beats torch.sort (CUB) by 24% (v1i) / 30% (rotate probe).
