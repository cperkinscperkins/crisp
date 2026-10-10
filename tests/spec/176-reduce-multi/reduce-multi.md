# Endeavor 176: reduce-multi

I'd like to add support for "multiple value reduction" to Crisp, as well as the "easy" `grid-reduce!` form.

The API is in `tests/spec/175-reductions/reductions-excerpt.md` (sections "Full Reductions Made Easy"
and "Reducing Several Variables at Once"). The multi-variable forms reuse the existing names
(`reduce-warp`, `reduce-workgroup`, `grid-reduce!`); there are no `...-multi` constructs.

Out of scope: `reduce-vec` (endeavor 177), and a `:second-stage` strategy for `grid-reduce!`
(it would change the set of kernels the host has to launch; `grid-reduce-second-stage!` stays the explicit tool).


## Scoreboard

Each cell: forward / autodiff / on-metal.

|                 | reduce-warp | reduce-workgroup | grid-reduce! |
| ----------------| ------------| -----------------|--------------|
| single variable | OK          | OK               |              |
| independent     |             |                  |              |
| dependent       |             |                  |              |


## Design review

- [x] review the API in reductions-excerpt.md
- [x] the "possible implementations" sections are gone
- [x] multi-variable API: per-variable clauses; shared combiner up front for the dependent form;
      per-variable resources in the clause, per-reduction resources as trailing keys
- [x] `&out` is never written at a call site; destinations are positional (in the clause at grid level)
- [x] float `type-min`/`type-max` are the FINITE extremes in every precision context; infinities are
      `(type-infinity T)`, `:ieee` only
- [x] dependent form is `:last-man-standing` only (a Crisp limitation, not a hardware one)
- [x] implicit scratch (2026-09-30): the element type comes from the IDENTITY, read at scan time
      (literals incl. suffixed ones, `(type-min/max/infinity T)`, `(- X)`, `(to-T x)`). A shared
      expansion wraps the reduction in a `let` of `make-scratch-*`, scanned in Pass 1 by a
      `scan-operator` method and analyzed in Pass 2 -- so the existing implicit-param plumbing does
      the rest. The identity must be typed ON ITS FACE when scratch is left out; an untyped identity,
      or one whose type differs from the variable's, is a loud error. (Softening via the variable's
      own `let` binding: deferred until real code keeps hitting it.)
- [x] scratch defaults in &optional / &key variants (g-p1a) are part of 176 ("in for a penny").
- [ ] where do `type-min`/`type-max`/`type-infinity` live in the design doc?
- [x] last-man's `num_workgroups <= local_work_size` limit: keep and document it, or make the final
      sweep a strided loop? It matters because last-man is the `grid-reduce!` default.
      RESOLVED by endeavour 181 (2026-10-08): strided sweep, partials sized :match-num-workgroups.
- [ ] dependent-form autodiff: special-case argmax/argmin? require a user-registered combiner VJP?
      declare it unsupported? Whatever we pick, it must fail LOUDLY -- a VJP that declines looks
      exactly like a zero gradient.


## Phase 0: prerequisites

Every later phase uses at least one of these.

- [ ] implicit scratch for the reductions (design above)
- - [x] TDD tests: every existing reduction with its scratch keys left out -- reduce-workgroup,
        grid-reduce-atomic!, -cas!, -last-man!, -second-stage! -- on metal
        (175/54-62: 54-58 metal, 59 CUDA twin, 60 `0ul` identity, 61 inside a def-grid-function,
        62 two reductions of two types in one kernel; explicit-scratch controls for 60-62 pass on BMG)
- - [x] RETIRED 175/errors/08-second-stage-no-scratch (deleted 2026-09-30)
- - [x] negative tests: untyped identity; identity type != variable type (175/errors/15, 16)
- - [x] identity-type reader (scan time; mirror the analyzer's literal typing)
- - [x] shared expansion: one `let` of scratch per variable; for last-man also the global scratch,
        and ONE counter + ONE election flag per call (single-variable done; multi-variable is Phase 2/3)
- - [x] `scan-operator` methods for each reduction; analyzer check that var type = identity type
- - [x] last-man's global partials: sized :match-workgroup-size (safe under last-man's
        num_workgroups <= local_work_size limit); needed symbolic GLOBAL scratch in the L0 hoister
        (BUG 094, overlays/hoist-l0). CUDA already handled it.
- - [x] all in the overlays 2026-09-30: unit 341/341, E2E 1287/1288 (only 016/10), negative 283/283
- - [ ] audit the `.metacrisp`: the implicit scratch params appear, with their sizes still symbolic
- - [ ] audit the hoisted code (L0 and CUDA): the buffers are allocated and sized, and `:message` reaches it
- - [ ] update documentation (the "required, allocated by the CALLER" paragraphs; the identity rule)
- [ ] scratch defaults in &optional / &key variants (g-p1a: "Missing implicit argument")
- - [x] TDD test: a def-grid-function wrapper with `&optional (sv (make-scratch-vector ...))`, on metal
        (016/10)
- - [x] Pass 1 scans the DEFAULT forms of a generic function's &optional / &key params and registers
        their scratch for the base function (<PARAM>-DEFAULT_FROM_<fn>_1, private counter); a variant
        inherits the base implicits and binds a scratch default to the implicit param (no allocation
        in the variant). Overlay 2026-09-30; full suite 1288/1288, unit 341, negative 283.
- - [x] scratch in the BODY of a generic function (016/11, two variants): fixed -- Pass 1 records each
        generic body's scratch-counter range; the skip point advances the counter; variants are generated
        with the BASE name + replayed counter. BMG: outa 32640, outb 32896.
- - [x] --single-pass: 016/10 FAILED there; fixed -- the generic skip point scans body + scratch defaults
        in single-pass mode. Local --single-pass: 016 19/19, 175 77/77. Full default suite 1289/1289.
- - [ ] the design-doc template example (`21_template_types.md:44`) is exactly this shape
- [x] `type-min` and `type-max`
- - [x] TDD tests, under both math-precision `ieee` and `fast` (046/03, 04, 06; errors/02)
- - [x] implementation (overlay 2026-09-30: analyzers -> typed literals; E2E 1295/1295, negative 285/285)
- - [x] documentation (in the excerpt)
- [x] `type-infinity`
- - [x] TDD tests (046/04, 05 -- incl. the finite-vs-infinite identity pitfall; errors/01); the :fast
        behaviour waits on the decision below
- - [x] DECIDED 2026-09-30: a WARNING, checked at codegen (046/07 flag, 046/08 with-precision region).
        (Note that the region can be set
        by flag, `declaim`, or `with-precision`, and `--force-math-precision` can override the
        source -- an error would make a file's validity depend on a command-line flag.)
- - [x] implementation (overlay; needed unary minus, BUG 095, for its negation)
- - [ ] documentation
- [x] Phase 0 bugs, found 2026-09-28, lock-down specs written, fixed in the overlay 2026-09-30
      (full suite 1277/1277). See plan/bugs.md and put_temp_files_here/176/FINDINGS.md.
- - [x] 090 &optional / &key variants never code-generated (+ keyword variants collided)
- - [x] 091 params after `&out ... &optional` treated as &out
- - [x] 092 `(and X Y)` / a value IF with no else left its false path unstored (tile bounds too)
- - [x] 093 an IF whose branches each `(return a b)` was typed as its FIRST value
- - [x] overlays FOLDED into src/ and emptied 2026-09-30 (everything through type-* and BUG 095):
        unit 341/341, E2E 1295/1295, negative 285/285; --single-pass 016 19/19, 046 8/8, 175 77/77
- [x] `reduce-warp`: lanes past `active-threads` DO get the result (175/04 verifies it on BMG)


## Phase 1: single-variable `grid-reduce!`

Sugar over the existing grid-level constructs, and the first real use of Phase 0's defaults.

- [x] TDD tests: `:atomic`, `:cas`, `:last-man-standing`, and the default (176/03-08 incl. CUDA twin
      and VERIFY-AUTODIFF; errors/01-03 bogus strategy, non-literal strategy, :atomic + custom op)
- [x] return-cell OR length-1 vector: both already work -- (~ cell 0) is accepted (BMG-verified)
- [x] `grid-reduce!` must expand into the existing ANALYZED forms, not into their lowering,
      or the VJP registry never sees them -- a macro to grid-reduce-atomic!/-cas!/-last-man!
- [x] autodiff: free from the existing VJPs -- 176/08 VERIFY-AUTODIFF analytical=1.0 numerical=1.0 (BMG);
      needed a runner fix for symbolic scratch sizes (spec-runner overlay)
- [x] on metal: 176/03-06 on BMG (32640 default / :atomic / :cas; 255 ulong max); 07 CUDA compiles.
      Decisions: put_temp_files_here/176/PHASE1-DECISIONS.md


## Phase 2: independent

- [x] TDD tests: `reduce-warp`, then `reduce-workgroup`, then `grid-reduce!` (176/09-14, errors/04-08,
      independent-fusion.unit.lisp)
- [x] 2a: per-clause expansion -- correct, AD for free (all metal specs + VERIFY-AUTODIFF passed here)
- [x] 2b: FUSED forward lowering (analyzers + Pass-1 scanner see the same fused form); the AD path (ANF)
      keeps the per-clause SPLIT, so backward uses the existing per-variable VJPs -- no new VJP
- [x] IR check: one shuffle sweep and one barrier serve all the clauses
- [x] IR check: a k-clause last-man call draws ONE atomic ticket, not k (unfused: 2 tickets / 10 barriers /
      8 loops; fused 2-clause = 1-clause: 1 / 5 / 4)
- [x] autodiff: per-clause VJPs; 176/14 VERIFY-AUTODIFF analytical=1.0 numerical=1.0 (BMG)
- [x] on metal: 176/09-13 on BMG


## Phase 3: dependent

- [x] TDD tests: `reduce-warp`, then `reduce-workgroup`, then `grid-reduce!` (176/15-18 argmax with ties,
      errors/09-11)
- [x] type check: the combiner is `#'(T1..Tk T1..Tk => T1..Tk)`, matching the clause types in order
      (%check-dependent-combiner, in the warp analyzer every dependent path reaches)
- [x] autodiff: DECIDED 2026-10-01 -- refused loudly for now (BUG 098); positive specs carry SKIP-WITH
      LIFTED by endeavour 177 (2026-10-02) for reduce-warp and reduce-workgroup, through a (declare
      (reduction-vjp f)) on the combiner; the dependent grid-reduce! remains refused (BUG 102).
      naming it; errors/11 pins the refusal.  Regroup on a user-registered combiner VJP.
- [x] on metal: argmax with ties (lower index wins) and with padding lanes -- 15 (4 / 4 20 36 52),
      16 (7 / 7 23 39 55), 17 (9 / 9), 18 (99 / 99), all BMG
- [x] lowered FUSED from the start (one combiner call per step, multi-value LET); last-man only
- [x] verified 2026-10-01: unit 341/341, E2E 1324/1324, negative 296/296, --differentiate 175 77/77 and
      176 29/29, --single-pass 176 29/29


## Negative tests (errors/)

- [ ] dependent form with `:atomic` or `:cas`
- [ ] independent `:atomic` clause whose function has no hardware atomic
- [ ] the same variable in two clauses
- [ ] combiner arity or types don't match the clauses
- [ ] identity of the wrong type
- [ ] malformed clause (wrong number of elements, unknown clause key)
- [ ] `type-infinity` under `:fast`, if we decide it is an error


## Phase 4: docs and wrap-up

- [x] return-vec -> return-cell for the Phase 2 reductions; `single-result` / "vector of size 1" language gone
      (a length-1 vector is still accepted; accumulate-vs-write stated per strategy)
- [x] single-variable `grid-reduce!` signature: all keys listed (Phase 1)
- [x] Binop-Type section: commutative AND associative (+ float last-bits note, dependent combiner signature)
- [x] "Matchy Matchy": rewritten to combos that can be written (grid-reduce! default / :atomic; reduce-warp)
- [x] typos: "muust", "indeterminant", camelCase scratch names, the duplicate `def-enum`
- [x] "Required, allocated by the CALLER" paragraphs -> optional (implicit scratch); :message marked reserved
- [x] reduce-warp: lanes past active-threads hold the result; reduce-workgroup: every thread holds the partial
- [x] fold the excerpt into the design doc: docs/ideal_001.md reductions section replaced; chapters regenerated
      (199 pure renames from renumbering; new: type-limits, full-reductions, several-variables, vector-api)
- [x] type-min/max/infinity documented: new "Type Limits" subsection after Base Numeric Types
- [x] overlays folded into src/ + tests/run-specs.lisp and EMPTIED (2026-10-01); grid-reduce! exported via package.lisp
- [x] regenerate reference.md / call graph / globals table (definition of done)
- [x] ci.yml / run-all-tests.bat need nothing: both run the whole spine to ci-stop in every mode
- [x] verified on folded src, overlays empty (2026-10-01): unit 341, E2E 1324/1324, negative 296/296,
      --differentiate 006/016/175/176, --single-pass 016/046/176 -- all clean
- [ ] `plan/definition-of-done.md` walk-through; CUDA on metal (pod) for 176/07, 175/59
- [x] `ci-stop.txt` -> 176
