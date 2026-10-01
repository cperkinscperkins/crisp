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
- [ ] last-man's `num_workgroups <= local_work_size` limit: keep and document it, or make the final
      sweep a strided loop? It matters because last-man is the `grid-reduce!` default.
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
- [ ] `type-infinity`
- - [x] TDD tests (046/04, 05 -- incl. the finite-vs-infinite identity pitfall; errors/01); the :fast
        behaviour waits on the decision below
- - [ ] decide what `:fast` does with it: error, or warning? (Note that the region can be set
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

- [ ] TDD tests: `:atomic`, `:cas`, `:last-man-standing`, and the default
- [ ] `grid-reduce!` must expand into the existing ANALYZED forms, not into their lowering,
      or the VJP registry never sees them
- [ ] autodiff: should come for free from the existing VJPs; confirm with `VERIFY-AUTODIFF`
- [ ] on metal: `TEST-HOIST[L0]` / `HOIST-EXPECT`


## Phase 2: independent

- [ ] TDD tests: `reduce-warp`, then `reduce-workgroup`, then `grid-reduce!`
- [ ] IR check: one shuffle sweep and one barrier serve all the clauses
- [ ] IR check: a k-clause last-man call draws ONE atomic ticket, not k
- [ ] autodiff: compose the existing per-clause VJPs; `VERIFY-AUTODIFF`
- [ ] on metal: `TEST-HOIST[L0]` / `HOIST-EXPECT` for the grid-level form


## Phase 3: dependent

- [ ] TDD tests: `reduce-warp`, then `reduce-workgroup`, then `grid-reduce!`
- [ ] type check: the combiner is `#'(T1..Tk T1..Tk => T1..Tk)`, matching the clause types in order
- [ ] autodiff: per the design-review decision above
- [ ] on metal: argmax with ties (lower index wins) and with padding lanes


## Negative tests (errors/)

- [ ] dependent form with `:atomic` or `:cas`
- [ ] independent `:atomic` clause whose function has no hardware atomic
- [ ] the same variable in two clauses
- [ ] combiner arity or types don't match the clauses
- [ ] identity of the wrong type
- [ ] malformed clause (wrong number of elements, unknown clause key)
- [ ] `type-infinity` under `:fast`, if we decide it is an error


## Phase 4: docs and wrap-up

- [ ] return-vec -> return-cell for the Phase 2 reductions; drop the `single-result` / "vector of size 1" language
- [ ] single-variable `grid-reduce!` signature: add `:atomic-counter` and `:election-flag-cell`
- [ ] Binop-Type section: commutative AND associative
- [ ] "Matchy Matchy": both combos, as written, can't be expressed
- [ ] typos: "muust", "indeterminant", camelCase scratch names, the `def-enum` defined twice
- [ ] fold the excerpt into the design doc (`ideal_001.md` and `docs/chapters/`)
- [ ] `ci-stop.txt` -> 176
- [ ] `plan/definition-of-done.md`
