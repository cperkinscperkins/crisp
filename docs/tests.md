# Crisp Testing Guide

## How to Run Tests

### All Tests (CI Mode)
```bash
# Run infrastructure unit tests + E2E spec tests
sbcl --script tests/run-ci.lisp
```

### E2E Spec Tests Only
```bash
# Runs E2E tests + co-located unit tests up to ci-stop.txt
sbcl --script tests/run-specs.lisp
```

### Infrastructure Unit Tests Only
```bash
# Traditional unit tests in tests/*.lisp
sbcl --script tests/run-ci.lisp  # (currently runs all tests)
```

### Single Test File
```bash
# E2E spec test
sbcl --load build/build.lisp --eval "(crisp.compiler:compile-file \"tests/spec/001-def-function/01-return_7.crisp\")"

# Unit test (must load Parachute first)
sbcl --eval "(ql:quickload :parachute)" --load tests/spec/001-def-function/signature-parsing.unit.lisp
```

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
- **Excluded:** Files in `errors/` subdirectories
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

## Test Directives (Future)

Header comment directives for test expectations (planned but not yet implemented):

```lisp
;; TEST-EXPECT: PASS
;; FAIL-WITH[--single-pass]: "Unsupported form"
;; TEST-WITH[--metadata]
;; CHECK-WARN: "Type inferred"

(def-function foo () ...)
```

See `docs/plan/scramble.md` section "Better Spine Testing" for details.

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
