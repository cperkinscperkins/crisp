# Endeavour 201 -- `look-back-scan`: the decoupled look-back as a form

Status: design agreed with Chris 2026-10-30.  Phase 1 built 2026-10-30 (overlays; see "Phase 1 as built"
and decisions D-201-1..10 for review).  sort_onesweep.crisp ported; H100 run pending (GPU MODE returned 503).

## Why

BUG 148 closed `while` to authors.  The two kernels that used it (05-prefixsum-v2/prefixsum_lookback.crisp,
07-sort-v2/sort_onesweep.crisp) both do a decoupled look-back: a tile publishes its value, waits for its
predecessors to publish theirs, sums back to the nearest inclusive total, and publishes its own.  The outer
look-back is boundable; the WAIT is not -- it waits on another workgroup's progress.  Chris's rule: the
compiler may hide a `%while`, an author never writes one, and the form that hides it owns a VJP.

Why not last-man-standing: that gives ONE commutative total, to whoever finishes last.  A scan needs a
different prefix for EVERY tile, each before that tile can write its output.

## Decisions (Chris, 2026-10-30)

1. Names: `ordered-workgroup-id` and `look-back-scan`.
2. Compiler-owned status words, ticket and epoch -- the author passes no buffers.
3. One tile per workgroup.
4. 32-bit values first (uint / int / float packed with a tag in one 64-bit word); double second.  (Not a
   template question: a double + tag is 96 bits, more than one atomic -- it needs a value / fence / flag
   protocol, a second lowering.  A template can unify the surface once both exist.)
5. Scope: the forms, their VJPs, specs, then port the two kernels.

## Surface

    (ordered-workgroup-id)        -> ulong, in [0, NT), NT = the launch's workgroup count
    (look-back-scan VALUE TILE)   -> exclusive prefix, VALUE's type

* `ordered-workgroup-id`: an in-order ticket -- the first workgroup to START is 0.  That is what makes the
  look-back deadlock-free: every tile waited on has already started.  Workgroup-uniform (thread 0 takes it,
  broadcast through local scratch, so the form holds a barrier).
* `look-back-scan`, per THREAD, one lane per thread: thread i of tile t gets sum over u < t of thread i's
  VALUE in tile u (onesweep: 256 digits, one per thread).  Every thread of the workgroup must call it -- a
  thread that skips leaves its lane unpublished and later tiles wait forever -- so the expansion starts with a
  `sync-workgroup`, which makes the existing barrier checks refuse a divergent call site.
* A per-WORKGROUP mode (one value per tile; prefixsum) arrives with phase 2.

## Implementation plan (worked out 2026-10-30)

**Shared, compiler-owned state.**  Both forms must reach the SAME per-kernel buffers (the counter, the status
words).  A macro's `let`-scratch is unique per occurrence (`<binding>_FROM_<fn>_<n>`), so use the endeavour-199
pattern: a fixed-name implicit scratch per kernel (`__OWG_CTR_FROM_<FN>`, `__OWG_STATUS_FROM_<FN>`)
registered in a `scan-operator :before` method, looked up by name in codegen.  Wrap it in one small analyzed
form, `(%kernel-scratch NAME)`, that evaluates to the handle; the two public forms are then plain Crisp
macros (with `%while`) over it.  See memory: compiler-owned-smem-via-implicit-scratch,
scan-pass-names-implicit-scratch-args.

**Counter = epoch and ticket in one ulong** `(epoch << 32) | ticket`, one atomic per workgroup:
`w = atomic-add!(ctr, 1)`; ticket = low word, epoch = high word + 1.  The LAST tile (ticket NT-1), after
publishing its own inclusive total -- by then every tile has read the epoch -- adds `(1 << 32) - NT`, rolling
to `(epoch + 1) << 32 | 0`.  Any NT on the next launch works; status words are never re-zeroed (global
scratch is zeroed once per program).  Status word = `(tag << 32) | bits`, tags `epoch*4+1` (aggregate) and
`epoch*4+2` (inclusive); a stale epoch never matches.  `look-back-scan` needs the epoch: it rides in the
workgroup-local broadcast cell next to the ticket.

**Status sizing: NT x workgroup-size words.**  Only `:match-num-workgroups` (x1) exists today.  Add a
symbolic `:match-global-size` (workgroups x `(local-size :set-to N)`) wherever `:match-num-workgroups` is
resolved: src/hoist-cuda/main.lisp (12 refs), src/hoist-l0/main.lisp (7), src/analysis/ops.lisp (checks),
tests/run-specs.lisp, tests/verify-autodiff-runner.lisp (%vad-resolve-symbolic-size),
scripts/crisp_bench/metacrisp.py.

**Packages.**  The public names are defined on `crisp-language::` symbols from the overlay (no package.lisp
edit needed to test); FOLD = export from crisp.compiler in src/package.lisp.

**A|D.**
* Both forms stay unexpanded and opaque in ANF (`*anf-unexpanded-macros*`, `*anf-opaque-statement-names*`).
* `ordered-workgroup-id`: VJP inert.  In the BACKWARD kernel the replayed binding is rewritten (in the ANF
  wrapper) to the reversed ticket NT-1-k.
* `look-back-scan`, integer VALUE: VJP inert (phase 1).
* `look-back-scan`, float VALUE (phase 2):  excl(t) = sum_{u<t} v(u)  =>  v_adj(u) += sum_{t>u} excl_adj(t),
  a scan in the OPPOSITE order.  Emit `v_adj += (look-back-scan excl_adj (- NT 1 TILE))`; with the ticket
  reversed, NT-1-TILE is that workgroup's ticket, so every wait is on an earlier-started tile.  The backward
  kernel has its own implicit scratch, so its status words are fresh.
  LIMIT: the backward kernel replays bindings, and replaying the FORWARD scan there would wait on tiles that,
  reversed, start LATER -- deadlock.  So the float VJP is valid only when the backward never needs excl's
  primal value (excl used linearly: added, or scaled by inactive values -- the prefix-sum case).  Drop excl's
  binding from the replay and refuse, naming why, if the backward references it.
* Under --differentiate a float `look-back-scan` needs its TILE from `ordered-workgroup-id` (refuse
  otherwise).  Phase 1 refuses float outright ("phase 2").

## Phases

1. `%kernel-scratch`, `:match-global-size`, `ordered-workgroup-id`, `look-back-scan` (per-thread, 32-bit),
   integer VJP inert, float refused under --differentiate.  Port sort_onesweep.crisp (H100 via popcorn --
   the BMG does not launch it, BUG 147).
2. Float VJP with the linear-use rule; per-workgroup mode; port prefixsum_lookback.crisp.
3. double (value / fence / flag protocol).

## Specs (planned)

- 01 forward: 16 workgroups x 64 threads, uint, VALUE = workgroup id + thread id -> closed-form prefix;
  HOIST-EXPECT on BMG + CUDA.
- 02 tickets: `ordered-workgroup-id` is a permutation of 0..NT-1 and the scan follows the TICKET order.
- 03 relaunch: two launches in one program (epoch roll) -- check the hoist harness can launch twice first.
- 04 differentiate: a float kernel using an integer look-back-scan (inert) differentiates and VERIFY-AUTODIFFs.
- errors/01 look-back-scan under divergent control; errors/02 float look-back-scan under --differentiate
  (phase 1); later, a TILE not from ordered-workgroup-id.

## Phase 1 as built (2026-10-30)

The "Implementation plan" above was the starting point; building it simplified it (D-201-1).

* `ordered-workgroup-id` and `look-back-scan` are plain macros (overlays/crisp-compiler-overlay.lisp,
  defined on `crisp-language::` symbols).  Each expansion is a LET that owns its scratch, so Pass 1 names it
  `<binding>_FROM_<fn>_<n>` -- unique per occurrence.
  * ticket: `ticket-counter` (global ulong cell), `ticket-broadcast` (local ulong cell).  The workgroup that
    takes ticket NT-1 stores 0 back (every other workgroup already has its ticket).
  * scan: `look-back-status` (global ulong vector, `:match-global-size`), `look-back-epoch` (global uint
    cell).  Tags `epoch*4+1` / `epoch*4+2`; the last tile adds 1 to the epoch after a second barrier.
* Typed helpers the macro cannot do itself (analyzers, registered from `register-control-analyzers`):
  `(%lbs-to-bits V)` -> uint, `(%lbs-from-bits WITNESS BITS)` -> WITNESS's type, and
  `(%look-back-scan-integer-only V)` -- the phase-1 backward rule's check.
* `:match-global-size`: L0 + CUDA hoists (deferred like 181's `:match-num-workgroups`, times `wg_size` /
  the declared block), VERIFY-AUTODIFF's `%vad-resolve-symbolic-size`.  Not metacrisp.py (D-201-5).
* A|D: both names in `*anf-unexpanded-macros*` (not opaque: ANF lifts VALUE/TILE into temps and binds the
  call).  VJPs: `ordered-workgroup-id` inert; `look-back-scan` emits `(%look-back-scan-integer-only VALUE)`.
  The backward kernel replays both bindings and so runs its own scan, in the forward's order, on its own
  scratch -- fine for an integer scan.

Specs: 01 uint (metal BMG PASS), 02 int + float + ticket permutation (metal BMG PASS), 03 integer scan in a
differentiated kernel = the relaunch test (VERIFY-AUTODIFF BMG PASS, analytical 4.0 / numerical 4.028),
errors/01 divergent call, errors/02 float under --differentiate, errors/03 ulong VALUE.  The planned 03
(relaunch) and 04 (differentiate) merged: VERIFY-AUTODIFF relaunches the forward per probe without
re-zeroing (endeavour 179), so a broken epoch roll moves the numerical gradient.

Verified by hand: the PTX of 01 holds 3 bar.sync, one atom.add.u64 (ticket), one atom.add.u32 epoch roll,
ld.relaxed.b32 (epoch) + ld.relaxed.b64 (poll), 3 st.relaxed.b64 publishes + the ticket reset; 03's _grad
PTX holds the same set again for the replayed scan.  The L0 run dumps `look-back-epoch: 1` and
`ticket-counter: 0` after one launch.

## Decisions (phase 1, for review)

- **D-201-1 Each form owns its scratch; no `%kernel-scratch`.**  Only the epoch had to be shared, and it
  need not be: an epoch per look-back-scan occurrence works (every tile reads it before publishing, and the
  last tile's inclusive word is published after the whole chain), and the ticket counter resets itself.  No
  new analyzed form, codegen untouched.  Same surface.
- **D-201-2 Types via a witness.**  A macro cannot see VALUE's type; `%lbs-from-bits` takes VALUE as a
  witness and reinterprets the 32 status bits as its type.  uint / int / float accepted; anything else is
  refused by name (errors/03).
- **D-201-3 Phase-1 float refusal lives in the BACKWARD kernel's analysis.**  The VJP sees forms, not
  types, so it emits `(%look-back-scan-integer-only VALUE)`; its analyzer is a no-op for int/uint and the
  named refusal for float (errors/02).  A kernel with no float input never reaches it (02 has a float scan).
- **D-201-4 Scratch binding names are C identifiers.**  The hoists print a binding name straight into the
  launcher; `%lbs-st` produced `uint64_t* %lbs_st_...` (invalid C++).  Renamed to look-back-status /
  look-back-epoch / ticket-counter / ticket-broadcast (readable in the launcher, unlikely to collide).
- **D-201-5 `:match-global-size` hoist plumbing is an overlay wrapper + special var** binding the param's
  :size-expr; FOLD gives the two deferred-scratch helpers a SIZE-EXPR parameter.  metacrisp.py is NOT
  extended: crisp_bench's C fixture resolves `@groups` itself and would need `@groups*N`; nothing in phase 1
  benchmarks through crisp_bench, and it already refuses the size by name.
- **D-201-6 Specs 03 + 04 merged** (above).
- **D-201-7 tests/ci-stop.txt advanced to 201-look-back-scan** (the runner has no bypass flag).
- **D-201-8 package_sort.py allocates the compiler's global scratch.**  parse_abi recognises global scratch
  cells, local cells' `N * sizeof(T)` sizes and grid-sized deferred vectors (checked BEFORE the literal
  regex -- their placeholder fields are `0ULL` and would have been read as zeros); the runtime's `_scratch`
  zeroes each buffer once per (kernel, name), grows it with the group count and keeps outgrown buffers alive
  (cached launch args may point at them).  `_args` is keyed by group count too.  Regenerating rewrote the
  v1 / beauty / diag submissions -- runtime text only, their ABIs have no scratch.
- **D-201-9 The divergent-call refusal names sync-workgroup, not look-back-scan** (errors/01 matches
  "cannot appear inside a thread-divergent conditional").  Polish candidate: the message could add
  "(look-back-scan and ordered-workgroup-id hold one)" as it already does for sync-wait.
- **D-201-10 One look-back-scan call per occurrence per launch** (in a loop a fast tile would overwrite a
  slot a slow tile is still reading).  Documented in the docstring, not checked.  onesweep and prefixsum call
  it once.
