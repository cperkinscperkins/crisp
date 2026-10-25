# Endeavour 193 — logging-output

Make `die`, the runtime asserts and runtime logging real, using the cut-down API agreed on
2026-10-24. The design is in `docs/ideal_001.md`, "Logging and Debugging" (chapter 41). It
replaced a 345-line section that had six subdivision flags. This endeavour also fixes BUG 136:
`die` is a silent no-op on L0.

## Why

Before 193:
- `die` was `llvm.trap`. On CUDA that halts the kernel but poisons the context. On SPIR-V it
  became a bare `OpUnreachable`, which IGC deletes (BUG 136).
- That made `r-t-assert` and every `--runtime-checks` bounds check no-ops on L0 too. 078/21 never
  noticed, because it only looks for `llvm.trap` in the LLVM-IR.
- `r-t-assert` ignored its message, and `r-t-assert-0` was a plain alias for it.
- `r-t-output`, the log, `(is-logging?)` and `--logging-output` did not exist.

## Agreed API (2026-10-24, Chris; Gemini concurred)

| compiled with | `r-t-assert(-0)` | compiler bounds checks | `r-t-output(-0)` | `die` |
|---|---|---|---|---|
| (neither) | gone | gone | gone | halts, records its site |
| `--runtime-checks` | `(unless test (die))`, no message | on | gone | halts, records its site |
| `--logging-output` (implies `--runtime-checks`) | message goes into the log, then die | on | into the log | halts, records site + message |

- No flag means the `r-t-` form compiles away completely, test and arguments included.
- One `die`, and no separate halt.
- **The die record:** any kernel that can reach a `die` gets an implicit 16-byte argument
  holding `site_id`, `group_id` and `local_id`. "Can reach" includes through a callee or a
  runtime check. The first death wins, and site ids start at 1.
- **The log:** a header of `cursor`, `capacity` and `dropped`, then packets in the Runtime
  Strings format. It is first-N only.
- Dropped: the subdivision flags, `r-t-workgroup-*`, last-N, and the voting barrier.
- `--differentiate` ignores both flags.

## The halt mechanics (measured, not assumed)

Probes are in `put_temp_files_here/logging-probes/` (`FINDINGS.md`, plus `h100/`).

- **BMG:** a thread that returns early counts as arrived at later `ControlBarrier`s. This holds
  for part of a subgroup and for a whole subgroup. A negative control proved the probe could
  catch a missing barrier.
- **H100:**
  - `exit` is safe before `bar.sync 0` and before `bar.red.or`.
  - A counted named barrier is warp-granular: a whole-warp death hangs it unless the count is
    lowered. Crisp does not emit counted named barriers today.
  - An mbarrier wait on a dead producer hangs. A dead-flag check in the spin loop fixes it.
  - `trap` poisons the context, but a record written first to mapped host memory survives.
- **Lowering:**
  - PTX: claim the record with CAS, then `exit`.
  - SPIR-V: claim the record, then return, and every caller returns after it. SPIR-V compute
    has no thread-exit instruction.

## Plan

Each phase is red then green.

- **Phase A — die halts (BUG 136).** Specs 01–04. Lower `die` to exit/unwind instead of
  `llvm.trap`; `die` takes an optional constant string. Specs: thread halt, die in a callee
  (unwind), die before a barrier, die in a loop in a value-returning callee.
- **Phase B — the die record.** Specs 10–14. Add the implicit argument (side-channel, propagated
  up the call graph like scratch), the site table in the metadata, and the launcher report.
  - Report format: `DIE <file>:<line> group <g> local <l>: <message>`.
  - Both launchers (L0 and CUDA) read the record after synchronising.
- **Phase C — `--runtime-checks`.** Specs 20–24. `r-t-assert` compiles away without a flag;
  under the flag a failed assert becomes `(unless test (die))`. Implement `when-thread-is`
  (documented at ideal_001 "when-thread-is / abs-when-thread-is", never built). The `-0` forms
  guard on it, meaning global thread 0; spec 24 tells that apart from thread 0 of each group.
  Bounds checks halt on metal.
- **Phase D — `--logging-output`.** Specs 30–35. Add `r-t-output`, `r-t-output-0`, the log side
  channel, the packet writer (atomic add on `cursor`, and `dropped` on overflow), launcher
  decoding, `(is-logging?)` and `(is-runtime-checking?)`.
  - Report format: `LOG <file>:<line> group <g> local <l>: <message>`.
- **Phase E — warp specialization (later).** Add dead-flag checks to the wait loops Crisp
  generates in kernels that can die: mbarrier `try_wait`, last-man, CAS retry. The specs need the
  H100, with a dying producer whose consumer must bail out.
- **Negative tests:** `errors/01` (a non-constant die message) and `errors/02` (a vector argument
  to `r-t-output` under `--logging-output`).

## Infrastructure the specs need

- **A `HOIST-FLAGS:` header** (new). The specs in phases C and D need their hoist compile to run
  with `--runtime-checks` / `--logging-output`. Today `TEST-WITH[--runtime-checks]` only reaches
  an IR validator (`run-spec-runtime-checks-pass`), and the hoist path has no way to pass a flag.
- **A launcher that knows the log size.** The hoist picks a default, overridable, for the `dropped`
  spec that is still to be written.
- **CI coverage without a GPU.** CI has no GPU, so the metal specs only check that things compile
  there. A compile-level check for BUG 136 (no `OpUnreachable` on the die path in the `.spv`)
  belongs in a co-located `.unit.lisp`. Memory: target-pass validators get a `.spv` path, and
  claims about the LLVM-IR go in unit tests.

## Open questions (for Chris)

1. ~~What does `-0` mean?~~ **DECIDED 2026-10-24: global thread 0**, through `when-thread-is 0`.
   That matches the ~29 `r-t-assert-0` uses in the ideal_001 examples. There is no `-wg0` variant:
   write `(when-thread-in-group-is 0 (r-t-assert ...))` instead.
2. ~~Should an assert's constant strings go into the site table under `--runtime-checks`?~~
   **DECIDED 2026-10-24: yes, that was always the intent.** Under `--runtime-checks` the DIE line
   shows the compile-time strings; only runtime values need `--logging-output`. Specs 21 and 22
   expect `: lane check`.
3. **Line numbers in the DIE/LOG expectations** come from `put_temp_files_here/logging-probes/gen_specs.py`
   (the `;; site` marker). Hand-editing a spec above its site line breaks the expectation.

## Decisions log
- 2026-10-24 — API agreed; doc spliced and committed; BUG 136 filed; 20 specs + 2 negative
  written; ci-stop bumped to 193.
- 2026-10-24 — **Phase A green** (overlay only; `put_temp_files_here/193/phase-a*.lisp` are the
  appended blocks):
  - Specs 01–04 pass on BMG; spec 14's buffer (two dying threads) is right too. The SPIR-V and the
    pre-opt LLVM-IR were checked by hand. After inlining, the flag folds into plain branches with
    no `OpUnreachable`.
  - Decided with Chris: the die record is a module-scope global (`@__crisp_die_record`,
    `addrspace(1)`, Export), not an implicit argument. The unwind is the same on both backends.
  - Probe 4 (FINDINGS.md): llvm-spirv refuses a module-scope Private flag, so the flag is a kernel
    entry alloca passed as a trailing LLVM-only `ptr` parameter to may-die functions.
  - Single-pass bug found by `tests/test-runtime-checks.lisp`: the context's
    current-compiling-function is NIL there. Fixed with `*analyzing-function*`.
  - That test asserted `llvm.trap`; it now asserts the die-record CAS and no trap.
  - New `logging-output.unit.lisp` pins the lowering for CI.
  - Suites: unit 392/392; E2E 1536/1551 (the 15 failures are the not-yet-built 193 specs 10–14,
    21–24 and 30–35); negative 366/367 (193 `errors/02`, Phase D).
  - Not run locally (CI): `--single-pass`, `--debug`, `--differentiate`.
- 2026-10-24 — **Phase B green** (compiler overlay plus both hoist overlays; the blocks are
  `put_temp_files_here/193/phase-b*.lisp` and `hoist-{l0,cuda}-b.lisp`):
  - Specs 10–14 print their DIE lines on BMG.
  - Real lines come from a `(` reader wrapper that records cons -> (file . line) while
    crisp.main reads a file. The --debug location-map holds virtual lines.
  - `analyze-expression` tracks the enclosing site, so a die built by a macro takes the macro
    call's line.
  - The winner fills group/local ids. Their builtins are analysed under
    `*in-dispatch-context*` t, so a die in a def-function works (spec 13).
  - `.metacrisp` gains `(:die-sites :record ... :sites ((id file line msg) ...))`. A site keeps
    one id across a spv+ptx compile.
  - CUDA: all 9 launchers (01–04, 10–14) build with nvcc and all 9 PTX pass `ptxas -arch=sm_90a`
    in the nvidia/cuda:12.4.1 image. Not yet run on metal.
  - Suites: unit 392/392; E2E 1541/1551 (the failures are 21–24 and 30–35); negative 366/367
    (`errors/02`).
- 2026-10-24 — **Phase C green** (`put_temp_files_here/193/phase-c*.lisp`; spec-runner overlay):
  - Specs 20–24 pass on BMG, and their CUDA launchers/PTX build and pass `ptxas` in Docker.
  - `HOIST-FLAGS:` header (`parse-hoist-flags`, plus a script-extracted `run-spec-with-hoist` copy
    with one clause).
  - `when-thread-is` built: one id compares the global linear id, 2–3 ids compare per dimension
    against global-id minus offset. It is defined on the `crisp-language` symbol; FOLD it into the
    package exports.
  - `r-t-assert` / `r-t-assert-0` are overlay macros. They compile away without a flag. Under
    `--runtime-checks` they become `(unless test (die "joined strings"))`; the `-0` form is guarded
    by `(when-thread-is 0 ...)`.
  - The bounds checks lower through die: `%handle-die-intrinsic` replaced, and `:around` methods
    name the make-view / struct-update site. Under `--runtime-checks` every function gets the die
    flag, and a call passes it only when the callee's real LLVM signature has the parameter.
  - 078/21 and 079/06 pinned the BUG 136 lowering (`validate-has-llvm-trap`). They now use
    `validate-has-die-check`: the die-record CAS present, no `llvm.trap`. The old validator is
    unused; delete it at fold.
  - Suites: unit 392/392; E2E 1543/1551 → with the two respecified, 1545/1551 (only 30–35 left);
    negative 366/367 (`errors/02`).
  - The full E2E process exited 139 AFTER printing its summary. Filtered runs exit normally, and
    `%run-launcher-with-bin-on-path`'s docstring mentions an older "unexplained crash late in a
    full pass". Watch CI.
- 2026-10-25 — **H100 NVL** (driver 595.91.07, branch `debug-logging`, `run-on-pod.sh ... 193-logging-output`):
  - All 14 CUDA specs of Phases A–C ran and passed, with the same buffers and DIE lines as BMG.
  - Spec Summary 16/22: only 30–35 fail (Phase D).
  - Note: `run-on-pod.sh` relays only BUFFER lines to the local log. The DIE lines are in
    `/tmp/crisp-specs__binary_.log` on the pod.
- 2026-10-25 — **Decided with Chris: the log is option G**, a module-scope global `@__crisp_log`
  sized by `--logging-size=<bytes>` (K/M/G, default 4M), not an implicit argument. Adding logging
  needs no host-code change, and an undersized log needs a recompile under either option. Doc
  updated: The Log, Runtime Strings, the flags, the side-channel and marshall references, and the
  C API note. `CRISP_PURPOSE_DEBUG_LOG` in `c-api/include/crisp.h` is now unused; it was left alone
  because it is ABI.
- 2026-10-25 — **Phase D green** (`put_temp_files_here/193/phase-d*.lisp`; hoist overlays
  `hoist-log-common.lisp`, `hoist-{l0,cuda}-d.lisp`, `decode2.lisp`):
  - Specs 30–36 pass on BMG; their CUDA launchers/PTX build and pass `ptxas` in Docker.
  - `--logging-output` implies `--runtime-checks`; `--differentiate` clears both.
  - `is-logging?` / `is-runtime-checking?` are MACROS expanding to `(> 1 0)` / `(< 1 0)`, because
    `if+` analyses and folds its condition.
  - `r-t-output(-0)` expand to `%193-log-message`: an analyzer plus the codegen above. Under the
    flag, `r-t-assert` logs its message, values included, before it dies.
  - Packet: `[SITE][GROUP][LOCAL][lo][hi]...`, claimed with one relaxed 64-bit `atomicrmw add`; the
    cursor counts past the end, so the launcher prints `LOG FULL ... wanted N (recompile with
    --logging-size=...)`.
  - The `.metacrisp` gains `(:log-sites :record "__crisp_log" :capacity-words C :sites ((id file
    line pieces) ...))`.
  - New spec 36 (1K log, 64 loggers) keeps exactly 50 messages and prints the LOG FULL line.
  - `errors/02` gained `TEST-EXPECT: PASS`. The E2E runner compiles it without the flag, where
    `r-t-output` compiles away; the negative runner uses `CHECK-FAIL-FLAGS`.
  - Suites: unit 392/392; E2E 1551/1552 → 1552/1552 after the `errors/02` fix; negative 367/367.
- 2026-10-25 — **H100** (80GB HBM3, driver 595.91.07, branch `debug-logging` with Phase D):
  - 23/23 and all 21 CUDA launchers passed.
  - Every DIE/LOG line matches BMG.
  - Spec 36 kept 50 messages, in thread order, and printed LOG FULL with the 2K suggestion.
  - Phases A–D are verified on both backends.
- 2026-10-25 — **Phase E built** (`put_temp_files_here/193/phase-e.lisp`, plus a validator in the
  spec-runner overlay):
  - The only unbounded waits Crisp generates are the mbarrier try_wait spins of `await`. The CAS
    retry loops are bounded, and last-man does not spin.
  - In a module that can die, `%gen-nvvm-mbarrier-try-wait-parity` (wrapped) also does a relaxed
    load of the die record's site word. A may-die waiter unwinds (flag + return); any other waiter
    leaves the wait.
  - Spec 40: 139/06 with a dying producer. The PTX check passes locally, and its `--mma-test`
    CUDA harness builds in Docker. Awaiting the H100 to show it finishes instead of hanging.
  - Suites: unit 392/392, E2E 1553/1553, negative 367/367.
