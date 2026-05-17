# Crisp Testing Guide

## How to Run Tests


### E2E Spec Tests Only
```bash
# Runs E2E tests + co-located unit tests up to ci-stop.txt
sbcl --script tests/run-specs.lisp --log-level=off
```

#### Specs can be run individually
```bash
sbcl --script tests/run-specs.lisp  --filter=<spec-name>
```

#### Flags for run-specs.lisp

- `--filter=<spec-name>`
- `--keep-work`
- `--log-level=off`
- `--single-pass`
- `--debug`
- `--only-unit-tests`
- `--use-binary`
- `--differentiate`

The file `tests/ci-stop.txt` controls "how far" the spec runner goes. It lists the last directory (inclusive) to test.  Everything "after" is assumed to be future TDD planning.

### Infrastructure Unit Tests Only
```bash
# Traditional unit tests in tests/*.lisp
sbcl --script tests/run-ci.lisp --log-level=off
```


### Note About Logging: off recommended
The logging is EXTENSIVE.  It is highly recommended to use `--log-level=off` except when running individual spec tests.

### Single Test File
```bash
# E2E spec test
.\bin\crisp-compile.exe tests/spec/001-def-function/01-return_7.crisp --log-level=off 
# or
sbcl --script tests/run-specs.lisp  --filter=01-return_7
```

Running the compiler alone is very useful for debugging. But the spec runner can perform
additional validation like 
- verifying the LLVM-IR using llc.exe
- running a "validator" if a spec test requests one
- following test directives (like `;; TEST-WITH[--metadata]` or `;; TEST-HOIST[L0]`)


### Hoisting and Intermediate Files

Now that we have hoisting support, some of the spect tests generate a lot of intermediate files. .metacrisp, .cpp, .spv, .ll, .ptx and even .exe files.  The spec runner will clean these up after any successful test.  Failed tests leave their intermediate files behind.

If you WANT the intermediate files, use the `--keep-work` flag.


### IMPORTANT NOTE
 The spec runner is nice because it validates the LLVM-iR using llc.exe and it will also run a "validator" if a spec test requests one (see below).
 BUT it probably should not be the first line tool for you when debugging.  Better results are had just invoking the compiler directly on a file.  So after a change  - build the compiler, then invoke it on some spec test (or some temporary .crisp if that suits you), and there is even a --log-level flag that can be used for the compiler.   Once THAT is working , then use the spec runner.

## Test System Architecture

### Hybrid Approach

Crisp uses a **hybrid test system** with two types of tests:

1. **Infrastructure Tests** (`tests/*.lisp`)
   - Cross-cutting concerns (build system, LLVM bindings, compiler infrastructure)
   - Traditional Parachute unit tests
   - Managed by `tests/all-tests.lisp` and `tests/run-ci.lisp`

2. **Feature Tests** (`tests/spec/**/*.crisp` and `tests/spec/**/*.unit.lisp`)
   - Feature-specific E2E and unit tests co-located with spec tests
   - Organized by feature dependency order (001-def-function, 002-type-conversion, etc.)
   - Managed by `tests/run-specs.lisp`

### Test Discovery

#### E2E Tests
- **Pattern:** `tests/spec/**/*.crisp`
- **Stop Target:** Tests run up to directory specified in `tests/ci-stop.txt`

#### Unit Tests (Co-located)
- **Pattern:** `tests/spec/**/*.unit.lisp`
- **Naming:** `feature-name.unit.lisp`
- **Framework:** Parachute
- **Location:** Can appear in any spec directory

### The "Spine" System

The spec tree is organized in **dependency order** with numbered directories:

```
tests/spec/
  001-def-function/       # Functions first
    01-return_7.crisp
    signature-parsing.unit.lisp
  002-type-conversion/    # Then type conversions
  003-def-struct/         # Structs depend on types
  ...
  024-ptx/                # Latest features
```

**TDD Workflow:**
1. Add new feature tests to next numbered directory
2. Update `tests/ci-stop.txt` to point to previous directory
3. New tests fail (expected) but don't break CI
4. Implement feature until tests pass
5. Update `ci-stop.txt` to include new directory
6. CI now validates new feature

## Writing Unit Tests in Spec Tree

### Template

```lisp
;; tests/spec/NNN-feature-name/feature-name.unit.lisp
(in-package :cl-user)

(defpackage :crisp.test.feature-name
  (:use :cl :parachute)
  ;; IMPORTANT: Use :import-from, NOT :use for crisp.compiler
  (:import-from :crisp.compiler
                #:function-you-need
                #:another-function))

(in-package :crisp.test.feature-name)

(define-test feature-name)

(define-test (feature-name specific-test)
  "Test description"
  (is = 2 (+ 1 1)))

;; Run tests - Parachute will error if any fail
(test 'feature-name)
```

### Package Gotchas ⚠️

#### **DO NOT** use `:crisp.compiler` directly

```lisp
;; ❌ WRONG - Symbol conflicts!
(defpackage :crisp.test.my-test
  (:use :cl :parachute :crisp.compiler))  ; WILL BREAK!
```

**Problem:** Both `:cl` and `:crisp.compiler` export conflicting symbols:
- `float`, `double`, `char`, `short` (type names)
- `let`, `return`, `truncate`, `floor`, `ceil`, `round` (shadowed forms)
- `when`, `unless`, `cond` (control flow)

#### **DO** use `:import-from` instead

```lisp
;; ✅ CORRECT - Import only what you need
(defpackage :crisp.test.my-test
  (:use :cl :parachute)
  (:import-from :crisp.compiler
                #:parse-function-declarations
                #:make-parameter-def))
```

#### **IF** you need many compiler symbols, shadow explicitly

```lisp
;; ✅ CORRECT - Explicit shadowing (like tests/all-tests.lisp)
(defpackage :crisp.test.my-test
  (:use :cl :crisp.compiler :parachute)
  (:shadowing-import-from :crisp.compiler
                          #:float #:double #:char #:short
                          #:let #:return
                          #:truncate #:floor #:ceil #:round)
  (:shadowing-import-from :common-lisp 
                          #:cond #:when #:unless))
```

### Common Patterns

#### Testing Compiler Internals
Use `crisp.compiler::` to access non-exported symbols:

```lisp
(crisp.compiler::parse-function-declarations '(a b)
                                             '((function (int int => int))))
```

#### Checking Results
Let Parachute handle failures - don't manually check:

```lisp
;; ✅ CORRECT - Parachute errors on failure
(test 'my-test-suite)

;; ❌ WRONG - Manual checking unnecessary
(let ((results (test 'my-test-suite)))
  (when (some-failed-p results)
    (error "Tests failed")))
```

#### Multiple Value Returns
Use `multiple-value-bind` for functions returning multiple values:

```lisp
(multiple-value-bind (env return-types optional-idx)
    (parse-function-declarations params declarations)
  (is = 4 (length env))
  (is = 2 optional-idx))
```

## Test Directives

Header comment directives for test expectations:

```lisp
;; These are implemented now:
;; TEST-EXPECT: PASS
;; FAIL-WITH[--single-pass]: "Unsupported form"
;; TEST-WITH[--metadata] : validate-metacrisp
;; TEST-HOIST[L0]: validate-l0-compile-only
;; VERIFY-AUTODIFF: x=3.0 atol=1e-3      <-- on-metal AD check; see below
;; CHECK-FAIL: "message"   <-- for the negative tests in errors
;; SKIP-WITH[--flag]: "reason for skipping" <-- for tests that should be skipped

;; These are not implemented yet:
;; CHECK-WARN: "Type inferred"

(def-function foo () ...)
```

See `docs/plan/scramble.md` section "Better Spine Testing" for details.

## On-Metal AD Verification (`VERIFY-AUTODIFF`)

The `;; VERIFY-AUTODIFF: …` directive (endeavor 103) runs a tagged spec's
backward kernel on a real OpenCL device and checks that the analytical
gradient matches a central-difference numerical gradient computed by
running the forward kernel at `x ± h`. This catches arithmetic bugs that
IR-level and metadata-level checks miss.

### When it runs

Only under `--differentiate`. The directive is parsed but skipped during
the default pass, so the cost is opt-in.

```bash
# Tagged tests get a (Verify-Autodiff) extra check appended:
sbcl --script tests/run-specs.lisp --filter=044-autodiff-execution --differentiate
```

### Directive grammar

Body is whitespace-separated `key=value` tokens. Reserved keys:

| Key                       | Meaning                                                            |
| ------------------------- | ------------------------------------------------------------------ |
| `atol=<float>`            | **Required.** Absolute tolerance for FD vs analytical comparison.  |
| `h=<float>`               | Optional FD step size (default 1e-3).                              |
| `seed-grad=<float>`       | Optional output gradient seed (default 1.0).                       |
| `<name>=<float>`          | Scalar input value (kernel takes a `cell float`).                  |
| `<name>=<integer>`        | Scalar input value (kernel takes a plain `ulong`).                 |
| `<name>=[v0 v1 v2 ...]`   | 1D vector input (kernel takes a `vector float`).                   |
| `at.<name>=<int>`         | Index in vector `<name>` to perturb / compare.                     |
| `expect.<name>=<float>`   | Optional explicit expected analytical gradient. Compared with same `atol`. |

Examples:

```lisp
;; Scalar in/out
;; VERIFY-AUTODIFF: x=3.0 atol=1e-3 expect.x=6.0

;; Two scalar inputs
;; VERIFY-AUTODIFF: x=3.0 y=4.0 atol=1e-3 expect.x=4.0 expect.y=3.0

;; 1D vector input, compare gradient at element 2
;; VERIFY-AUTODIFF: A=[1.0 2.0 3.0 4.0] atol=1e-3 at.A=2 expect.A=6.0
```

Per-spec there is at most one `VERIFY-AUTODIFF:` line. Missing `atol`,
malformed tokens, or duplicate directives all produce clear parse errors.

### What gets verified

For each *perturbable* input (`<name>=<float>` scalars and vector inputs
that have an `at.<name>=<int>`):

1. The forward kernel is run at `x ± h` to produce a central-difference
   numerical gradient.
2. The backward kernel is run once with all primals + `seed-grad`, and the
   per-input analytical gradient is read back (full cell for scalar inputs,
   `at.<name>` element for vector inputs).
3. `|analytical − numerical| < atol` is required.
4. If `expect.<name>=<float>` is given, the analytical gradient is *also*
   compared against the explicit expected value with the same tolerance.

Plain `ulong` scalar inputs participate in the kernel call but are not
finite-differenced (integer indices have no meaningful gradient).

Output looks like:

```
Running Spec: 01-square (Verify-Autodiff)... PASS (x: analytical=6.0 numerical=5.9995646 diff=4.35e-4)
Running Spec: 02-product (Verify-Autodiff)... PASS (x: analytical=4.0 numerical=3.9997 diff=2.9e-4; y: analytical=3.0 numerical=3.0003 diff=2.6e-4)
```

### Requirements

- An OpenCL ICD on `PATH` (`OpenCL.dll` on Windows, `libOpenCL.so` on
  Linux). If loading fails, the check reports `SKIP (OpenCL runner
  unavailable)` and counts as a pass — non-GPU CI does not fail.
- The kernel must compile under `--differentiate` (otherwise the verify
  step fails at the compile sub-step before reaching the device).

### Output file cleanup

The verify pass compiles fresh `<basename>.spv` and `<basename>_grad.spv`
into the spec's directory, then deletes them on completion (success or
failure). `--keep-work` preserves them for inspection.

### Current scope

- Inputs: scalar `cell float`, plain `ulong`, and 1D contiguous-compact
  `vector float`.
- Output: a single `cell float`.
- Multi-dim tensors, records, structs, and multi-output kernels are not
  yet supported.

### Implementation pointers

- Directive parser: `tests/verify-autodiff-parse.lisp` (pure CL, no
  foreign deps; safe to load on hosts without OpenCL).
- OpenCL runner: `tests/verify-autodiff-runner.lisp` (loaded lazily on
  first use; load failure cached and reported once).
- Spec-runner integration: see `run-verify-autodiff-pass` in
  `tests/run-specs.lisp`.
- Ad-hoc one-off run: `scripts/verify_autodiff.lisp`.

## Best Practices

1. **Co-locate unit tests** with their E2E specs when testing feature-specific compiler behavior
2. **Use infrastructure tests** for cross-cutting concerns (build, LLVM, utilities)
3. **Import selectively** - Don't `:use :crisp.compiler` unless you shadow conflicts
4. **Name clearly** - `feature-name.unit.lisp` makes purpose obvious
5. **Test one thing** - Each test case should validate a single behavior
6. **Document tests** - Add docstrings to `define-test` forms

## Examples

See:
- `tests/spec/001-def-function/signature-parsing.unit.lisp` - Feature-specific unit test
- `tests/all-tests.lisp` - Infrastructure unit tests with full shadowing
- `tests/run-specs.lisp` - Test runner implementation
