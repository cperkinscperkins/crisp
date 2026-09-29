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
- [ ] is `grid-reduce!` sugar, or does it need the Pass-1 scanner to learn about analyzer-introduced
      scratch? Answered by the Phase 0 elided-`&key` tests.
- [ ] where do `type-min`/`type-max`/`type-infinity` live in the design doc?
- [ ] last-man's `num_workgroups <= local_work_size` limit: keep and document it, or make the final
      sweep a strided loop? It matters because last-man is the `grid-reduce!` default.
- [ ] dependent-form autodiff: special-case argmax/argmin? require a user-registered combiner VJP?
      declare it unsupported? Whatever we pick, it must fail LOUDLY -- a VJP that declines looks
      exactly like a zero gradient.


## Phase 0: prerequisites

Every later phase uses at least one of these.

- [ ] TDD tests for elided `&key` arguments to the existing Phase 1 and Phase 2 reductions.
  In theory, something like this should work already today:
  `... &key (someKey (make-scratch-vector :num-workgroups))`
- - [ ] make sure the defaults are working right
- - [ ] audit the `.metacrisp`: the implicit scratch params appear, with their sizes still symbolic
- - [ ] audit the hoisted code (L0 and CUDA): the buffers are allocated and sized, and `:message` reaches it
- - [ ] update documentation (the "required, allocated by the CALLER" paragraphs)
- [ ] `type-min` and `type-max`
- - [ ] TDD tests, under both math-precision `ieee` and `fast`
- - [ ] implementation
- - [x] documentation (in the excerpt)
- [ ] `type-infinity`
- - [ ] TDD tests, both math-precisions
- - [ ] decide what `:fast` does with it: error, or warning? (Note that the region can be set
        by flag, `declaim`, or `with-precision`, and `--force-math-precision` can override the
        source -- an error would make a file's validity depend on a command-line flag.)
- - [ ] implementation
- - [ ] documentation
- [ ] multi-value combiners: reproduce the two defects the 176 probe found
      (`01-probe-mv-binop-butterfly-metal.crisp`, lines 38-40), then file or fix them
- - [ ] an `if` whose branches each `(return a b)` is typed as its FIRST value -> invalid IR
- - [ ] `(and X Y)` with X false leaves the result slot unstored; -O3 then drops X
- [ ] `reduce-warp`: check `%reduce-warp-expand` -- do lanes at or past `active-threads` really end
      up with the reduced value, as the docs promise?


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
