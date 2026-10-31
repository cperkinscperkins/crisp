# Endeavour 201 -- `look-back-scan`: the decoupled look-back as a form

Status: design agreed with Chris 2026-10-30; nothing implemented yet.

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
