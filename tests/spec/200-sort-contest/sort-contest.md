# Endeavour 200 -- GPU MODE `sort_v2` (leaderboard #542)

Branch `matmul-contest`, 2026-10-29/30.  Chris stepped away ("give it your best shot"); every call below
was made without him and is listed under **Decisions** for review.

## The problem

`sort_v2`: sort a 1-D fp32 tensor ascending into `output`; must equal `torch.sort` exactly.  Ranked on the
LAST benchmark only: **100,000,000 floats, seed 6252**.  The data is a ~square matrix whose row `i` is
`randn + seed + i`, flattened -- values 6252 .. 16251, nearly sorted by row.  Board on 2026-10-29: H100 #1
129.7 us (below the ~240 us it takes just to read 400 MB and write 400 MB -- it must exploit the input),
median 2,083 us.

## Design

Files: `contests/gpu-mode/07-sort-v2/`.

**Keys.**  A float's bits become an order-preserving uint key (positive: flip the sign bit; negative: flip
all bits).  One min/max pass finds `kmin` / `kmax`; every pass sorts `key - kmin`, so only
`ceil(bits(kmax - kmin) / 8)` 8-bit passes are needed: 3 for the contest's data (the values differ in
their low 24 bits), never more than 4, for any input.  The host reads `kmin` / `kmax` once (the only
sync) to choose the pass count.

**v1 `sort_radix.crisp` -- reduce-then-scan LSD radix**, tiles of 4096 keys, one 256-thread workgroup per tile:
`sort_minmax`; then per pass `sort_upsweep` (per-tile 256-bin histogram), `sort_digit_scan` (one
workgroup per digit scans its row of tile counts), `sort_downsweep` (stable local sort of the tile in
shared memory by two 4-bit counting splits, then each digit's run is written to
`digit-base + scanned[digit][tile] + rank`).

**v2 `sort_onesweep.crisp` -- onesweep (decoupled look-back)**: `sort_minmax_hist` reads the input ONCE for
kmin/kmax AND pass 0's histogram (`(key - kmin) mod 256` is the raw low byte rotated by kmin); then ONE
`sort_onesweep` launch per pass: in-order tile ticket, local sort, publish 256 digit counts in
epoch-tagged 64-bit status words, per-digit look-back, scatter -- and the tile adds its NEXT digit's
counts to the global histogram, so the next pass needs no separate histogram read.

Shared-memory layouts (both): logical tile position `p` lives at word `(p mod 16) * 257 + p / 16`; counter
`c = digit * 256 + thread` at word `c + c / 32` -- conflict-free for the counting reads and the scan.

Portable: the warp logic follows `(warp-size)`, so the same source runs on the BMG (16-wide) -- that is
how every version was verified before any H100 time was spent (`put_temp_files_here/sort/cl_sort.py`:
stdlib-only OpenCL harness running the hoisted kernels on the Arc B580, bit-exact against Python's sort
of the same float32 values: partial tiles, mixed signs, few distinct values, all-equal, a 60-decade range,
up to 4M keys).

## Measurements (H100, popcorn)

All at 100M (the scored case), per-launch CUDA-event timings from the test-mode diagnostics; every run also
checked `torch.equal` against `torch.sort` at 100M / 10M / 1M (all True).

| version | wall | per pass (us) | change |
|---|---|---|---|
| v1  | 4.10 ms | upsweep ~255, scan 36, downsweep ~1000 | first cut, correct first time on BMG and H100 |
| v1b | 3.95 ms | upsweep ~190, scan 36, downsweep ~1010 | packed register counters + uint4 loads (only the upsweep moved) |
| v2 onesweep | 4.10 ms | onesweep ~1330 | look-back replaces upsweep + scan: SLOWER than v1b's 1236 |
| **v1c** | **3.78 ms** | upsweep ~190, scan 36, downsweep ~958 | keys rotated so the digit is the low byte |

Ranked (crisp_sort_v1.py = v1c): **H100 3749.5 us #19/30** (median 2093.7, #1 129.7), **A100 8155.7 us
#24/33** (median 3427.7), **L4 25318.7 us #16/20** (median 15382.9).  B200 not submitted (the B200 queue was
broken on GPU MODE's side the day before).  Beauty (bitonic, crisp_sort_beauty.py): passes the H100 tests,
68.9 ms on the scored case (benchmark 968685).  Reports: contests/gpu-mode/REPORT-sort_v2.md.

Probes (fenced, `put_temp_files_here/sort/probes/`, timing only), the downsweep at 100M:
- round 1 (writes left scattered): removing the local sort makes it SLOWER (2.9 ms) -- the sort is what makes
  the writes coalesce.
- round 2 (writes forced coalesced): load + bookkeeping + write 490; + one split 831; + both 1001.
- round 3: packed register counters 1008 vs shared-memory counters 785-806 -- the "shared-memory RMW chain"
  theory was WRONG; a literal shift instead of the run-time one saves 200 (1008 -> 806): the generic
  branch-free `ash` with a run-time count is ~10 instructions, 64-bit ones more.  Rotating the key once
  per load / write (v1c) recovered ~50 of those 200.

Where it stands: ~38K cycles per 4096-key tile, ~90-190 instructions per key per pass; the floor is ~270 us
per pass.  The remaining gap is instruction count (index math, two 4-bit splits, the per-key neighbour scan
for run starts) and barriers, not memory.  Next levers, in order of expected value: a ballot / match
builtin (warp-level multisplit, one 8-bit ranking pass instead of two 4-bit splits -- needs a compiler
feature, so it is Chris's call); 32-bit index math in the tile (everything is ulong today); more keys per
thread.

## Bugs found and fixed

- **BUG 138** (filed 2026-10-25): `ash` / `popcount` lowered to noinline helper CALLS on PTX too -- the
  BMG workaround (BUG 120 family) applied to every backend.  66 `call.uni __crisp_ash_*` in the sort's PTX.
  Fixed: noinline only on SPIR-V (`%185-helper-call`, overlay).  Spec `01-ash-popcount-inline-on-ptx-metal`.
- **BUG 145** (new): `semantic-while` missing from `semantic-node-type` / `semantic-node-source-location`;
  a `while` as the last form of a `let` body died with a raw ETYPECASE dump of the whole semantic tree.
  Fixed by wrapper (overlay).  Found through an author-written `while` -- which BUG 148 then closed; its spec
  was deleted with it.
- **BUG 148** (Chris, reviewing): an author could write `while`.  Crisp is not Turing-complete; the analyzer
  exists for the compiler's own spin in `sync-wait` but was also registered for the language's `while`.
  I had used it in the onesweep look-back AND written it into `writing-crisp.md` as a feature -- reversing
  a rule the guide had right.  Now `while` is the internal `%while`; an author's `while` is refused
  ("every Crisp loop is bounded"), and ANF refuses it the same way under `--differentiate`.  Specs
  `errors/01-unbounded-loop-refused`, `errors/02-unbounded-loop-refused-differentiate`.
- **BUG 149**: an arrival sync could not be differentiated -- never tried, since every arrival-sync spec
  skipped `--differentiate`.  Three causes: ANF dropped `make-scratch-cell`'s `:address-space` (every global
  scratch cell, every differentiated kernel); the handle's `%construct-struct` was walked as a
  differentiable struct; `sync-arrive` / `sync-wait` were expanded by ANF.  Now they are opaque in ANF with
  VJPs: the backward mirrors an arrive with a wait and a wait with an arrive.  Spec
  `02-arrival-sync-differentiates-metal` (VERIFY-AUTODIFF on BMG across two workgroups: 12.0 vs 12.02).
- **BUG 146** (new, OPEN, BMG): a `ulong` loop counter accumulated through `(to-uint k)` returns garbage in
  the high bits on the BMG -- `while` and `dotimes` alike; the IR is correct (BUG 120 family).  Found
  because spec 02's first draft used a ulong counter; it now uses a uint one.
- **BUG 147** (new, OPEN, BMG): `sort_onesweep` will not launch on the BMG (CL_OUT_OF_RESOURCES); any one
  group of its global atomics launches, the full set does not.  Onesweep was verified on the H100 instead.
- Spec validators first failed for a silly reason worth remembering: they were appended with a bash heredoc,
  which collapsed `\\` to `\` in the regex strings.  Fixed with Edit.

All suites with every overlay in place (re-run after the last change): unit pass, E2E 1622/1622 (the two
200 specs included, BMG metal), negative 403/403.

## Documentation gaps found (fixed in docs/writing-crisp.md)

- A helper holding a barrier must be `def-grid-function` (a `def-function` is refused: "only valid inside
  a kernel"), and a grid function returns nothing -- results go through shared scratch.
- A collective under `(when (= wid 0ul) ...)` with `wid` computed from the local id is refused; gate on
  `(warp-id)` (warp-uniform) instead.
- ~~`while` exists (the guide said it does not).~~  WRONG, and reverted: the guide was right.  The compiler
  accepted an author's `while` only because of BUG 148.
- `crisp-compile` must be run from the repository root; run elsewhere it fails, and a script that ignores
  the exit code then reads the PREVIOUS `.ptx` (cost me a confusing half hour).

## Decisions (for review)

- **D-200-1  Radix, not merge / bitonic.**  Exact match is natural, and it reuses the histogram and
  prefix-sum contest work.  The distribution-exploiting route the leaders take is phase 2, not day one.
- **D-200-2  Range reduction (`key - kmin`)** with one host sync for the pass count: 3 passes not 4 at
  the scored size; correct for any input (0 passes = all equal = a copy).
- **D-200-3  ctypes driver API, no load_inline** in the submission: nothing compiles on the judge, every
  Crisp parameter is a u64 so one ctypes array covers the ABI.  Launch arguments are cached per pointer set.
- **D-200-4  Fixed BUG 138 in an overlay** (Chris: "if you encounter any bugs working on sort, feel free to
  fix them").  It changes PTX for every kernel using ash / popcount -- verified by the suites, not just
  the sort.
- **D-200-5  BUG 145 fixed by WRAPPERS** around the two etypecase functions (not 80-line copies); fold =
  add the two clauses.
- **D-200-6  ci-stop moved to `200-sort-contest`** so the two new specs run.
- **D-200-7  The sort kernels live in contests/, not tests/spec/**: like the other contest entries; the
  BMG harness is the correctness test.  The two specs cover the compiler fixes.

Agreed with Chris after review (2026-10-30): the compiler may hide a `while` in rare cases, an author may
never write one, and a form that hides one needs a VJP.

- **D-200-8  `%while`, not `while`**: the analyzer is registered only under the internal name, rather than
  rejecting `crisp-language::while` while keeping `crisp.compiler::while` -- no compile path that reads
  source in the compiler package can then let an author's `while` through.
- **D-200-9  A `%while` reaching ANF is an internal error**, not a case to normalize: a form that hides a
  spin must be opaque to ANF and own a VJP.  The old ANF `WHILE` clause is dead.
- **D-200-10  The arrival-sync VJP swaps roles** (wait -> arrive, arrive -> wait) with the forward's count.
  Valid because both forms are refused under divergent control, so the arrivers and the waiters are the same
  threads.  The backward replays bindings, not statements, so its handle is a fresh counter.
- **D-200-11  An arrival handle's construction is inert** via a `%construct-struct` VJP that declines for
  every other struct -- narrower than teaching the walk that integer-only structs are inactive.  The
  int counter cell still gets a paired float scratch adjoint (as every int scratch cell does) -- harmless,
  one wasted global cell.
